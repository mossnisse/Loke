// The compile-time engine: a tree-walking interpreter over the typed AST, with
// value operations shared through `const_ops.odin`. Values are mutable while a
// procedure runs and are frozen into `Const_Value`s on the way out.
package lokec

import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Documented ceilings; exceeding one is a diagnostic.
EVAL_MAX_STEPS  :: 1_000_000
EVAL_MAX_DEPTH  :: 256
EVAL_MAX_MEMORY :: 64 * 1024 * 1024

// Measured rather than counted: the evaluator recurses on the host stack, where
// one call costs 16-53 KB, and it may start deep inside the checker. It stops
// with this much of `COMPILER_STACK` left, for reporting and unwinding.
EVAL_STACK_MARGIN :: 1024 * 1024

// `Fail` means a diagnostic was reported and evaluation is over.
Eval_Flow :: enum {
	Normal,
	Break,
	Continue,
	Return,
	Fail,
}

// A value being computed. Aggregates keep mutable elements; a pointer is
// `target` and a procedure value `proc_value`.
Eval_Value :: struct {
	// Its `aggregate` stays nil: `elements` are the parts.
	using constant: Const_Value,
	type:       Type_Id,
	// A union's variant; `elements[0]` is its payload, `Invalid` when none.
	variant:    int,
	elements:   []Eval_Value,
	// What `elements`' block holds, when a container grew it (`eval_splice`).
	capacity:   int,
	target:     ^Eval_Value,
	proc_value: Symbol_Id,
}

Eval_Frame :: struct {
	symbol:       Symbol_Id,
	site:         Span,
	locals:       map[Symbol_Id]^Eval_Value,
	defers:       [dynamic]^Stmt_Defer,
	result:       Eval_Value,
	// `INVALID_TYPE` means no result.
	result_type:  Type_Id,
	// The storage a `return inout` named (design.md "`inout` results").
	result_place: ^Eval_Value,
	// Set by a failing `or_return` or an `or_else` exit; the enclosing statement
	// turns it into this flow.
	exiting:      Eval_Flow,
}

Evaluator :: struct {
	k:      ^Checker,
	storage: Eval_Storage,
	alloc:  mem.Allocator,
	frames: [dynamic]^Eval_Frame,
	steps:  int,
	failed: bool,
	// The context that required this evaluation, where the diagnostic points.
	origin: Span,
	what:   string,
	// The error each `or_return` mapper is called with, in the arena.
	propagated: map[^Expr_Postfix]Eval_Value,
}

// Every compile-time-required context comes through here. `code` names the
// context in the fallback diagnostic for a failure nothing else reported.
require_const :: proc(k: ^Checker, e: Expr, what: string, code := "L0340") -> (out: Const_Value, success: bool) {
	base := expr_base(e)
	if base == nil || base.type == INVALID_TYPE {
		return Const_Value{}, false
	}
	if base_is_const(base) {
		return base.const_value, true
	}
	ev := Evaluator{k = k, origin = expr_span(e), what = what}
	defer eval_storage_destroy(&ev.storage)
	value := eval_root(&ev, e, code, "%s must be a compile-time constant") or_return
	frozen := freeze_result(&ev, value) or_return
	base.const_value = frozen
	return frozen, true
}

// Static `foreach`: each element freezes on its own, so the container never
// escapes evaluation. The result is the caller's to reorder. A constant is
// already frozen, and reading its parts runs nothing.
evaluate_static_elements :: proc(k: ^Checker, e: Expr, what: string) -> (out: []Const_Value, success: bool) {
	if base := expr_base(e); base.const_value.aggregate != nil {
		out = slice.clone(base.const_value.aggregate.elements, k.c.semantic_allocator)
		return out, true
	}
	ev := Evaluator{k = k, origin = expr_span(e), what = what}
	defer eval_storage_destroy(&ev.storage)
	value := eval_root(&ev, e, "L0454", "%s must be compile-time evaluable") or_return
	out = make([]Const_Value, len(value.elements), k.c.semantic_allocator)
	for element, index in value.elements {
		out[index] = freeze_result(&ev, element) or_return
	}
	return out, true
}

// Runs `e` in a fresh evaluator, reporting `format` (with `what`) for a failure
// nothing else reported.
@(private = "file")
eval_root :: proc(ev: ^Evaluator, e: Expr, code, format: string) -> (Eval_Value, bool) {
	init_evaluator(ev)
	value, ok := eval_expr(ev, e)
	if !eval_memory_ok(ev) || !ok {
		if !ev.failed {
			eval_fail(ev, expr_span(e), code, format, ev.what)
		}
		return Eval_Value{}, false
	}
	return value, true
}

// Checks a procedure on demand, so a constant may call one not reached yet.
@(private = "file")
ensure_proc_typed_for_eval :: proc(k: ^Checker, symbol_id: Symbol_Id) -> bool {
	// Executing a declaration is a real use, even from a `where` predicate.
	saved_speculation := begin_commit(k.c)
	// The same holds for what the check reports: a passing `where` bound rolls
	// back everything after its mark, and this body is never checked again.
	mark := len(k.c.diagnostics)
	defer {
		hold_diagnostics(k.c, mark)
		end_commit(k.c, saved_speculation)
	}
	if instance, found := k.c.procedure_instances[symbol_id]; found {
		promote_generic_instance(k, instance, NO_SPAN)
	}
	symbol := symbol_of(k.c, symbol_id)
	if symbol == nil || symbol.kind != .Proc {
		return false
	}
	d := symbol.decl
	if d == nil {
		return symbol.proc_type != INVALID_TYPE // a hoisted literal, checked in place
	}
	if d.check_state == .Checked {
		return true
	}
	if d.check_state == .Checking || d.sig_state == .Checking {
		return false // the caller reports the dependency path
	}

	outer_location := k.location
	defer k.location = outer_location
	// A member of an instantiated generic block is checked inside it, where its
	// `where` clause has the block's parameters in scope.
	if !enter_instance_impl_member(k, symbol) {
		enter_symbol_location(k, symbol)
	}
	k.body = {}

	resolve_declaration_signature(k, d)
	check_decl(k, d)
	return d.check_state == .Checked
}

// The primary diagnostic names the required context; notes name the failing
// operation and every frame in between.
@(private = "file")
eval_fail :: proc(ev: ^Evaluator, span: Span, code: string, format: string, args: ..any) -> bool {
	if ev.failed {
		return false
	}
	ev.failed = true
	c := ev.k.c
	if ev.storage.exhausted {
		errorf(c, ev.origin, "L0342", "compile-time evaluation exceeded %d bytes of scratch memory", EVAL_MAX_MEMORY)
	} else {
		errorf(c, ev.origin, code, format, ..args)
	}
	if ev.what != "" {
		add_notef(c, ev.origin, "%s is required at compile time", ev.what)
	}
	if span.file != NO_FILE && (span.file != ev.origin.file || span.lo != ev.origin.lo) {
		add_notef(c, span, "evaluation stopped here")
	}
	for index := len(ev.frames) - 1; index >= 0; index -= 1 {
		frame := ev.frames[index]
		add_notef(c, frame.site, "in `%s`, called here", eval_proc_name(c, frame.symbol))
	}
	return false
}

@(private = "file")
eval_proc_name :: proc(c: ^Compiler, symbol_id: Symbol_Id) -> string {
	symbol := symbol_of(c, symbol_id)
	if symbol == nil {
		return "<procedure>"
	}
	return identifier_text(c, symbol.name)
}

@(private = "file")
eval_step :: proc(ev: ^Evaluator, span: Span) -> bool {
	if ev.failed || !eval_memory_ok(ev) { return false }
	if stack_remaining() < EVAL_STACK_MARGIN {
		return eval_fail(ev, span, "L0342", "compile-time evaluation ran out of stack: it recurses or nests too deeply here")
	}
	ev.steps += 1
	if ev.steps > EVAL_MAX_STEPS {
		return eval_fail(ev, span, "L0342", "compile-time evaluation exceeded %d steps", EVAL_MAX_STEPS)
	}
	return true
}

@(private = "file")
init_evaluator :: proc(ev: ^Evaluator) {
	ev.alloc = mem.Allocator{eval_allocator_proc, &ev.storage}
	ev.frames = make([dynamic]^Eval_Frame, 0, 8, ev.alloc)
}

// Reported outside the allocator, since reporting allocates too. `eval_fail`
// words an exhausted memory itself.
@(private = "file")
eval_memory_ok :: proc(ev: ^Evaluator) -> bool {
	if !ev.storage.exhausted { return true }
	return eval_fail(ev, ev.origin, "L0342", "")
}

@(private = "file")
eval_slot :: proc(ev: ^Evaluator, value: Eval_Value) -> (^Eval_Value, bool) {
	slot := new(Eval_Value, ev.alloc)
	if slot == nil { return nil, false }
	slot^ = value
	return slot, true
}

@(private = "file")
eval_elements :: proc(ev: ^Evaluator, count: int) -> ([]Eval_Value, bool) {
	if count < 0 || count > (EVAL_MAX_MEMORY - ev.storage.bytes) / size_of(Eval_Value) {
		ev.storage.exhausted = true
		return nil, eval_memory_ok(ev)
	}
	elements, err := make([]Eval_Value, count, ev.alloc)
	return elements, err == nil
}

@(private = "file")
element_type_at :: proc(c: ^Compiler, type: Type_Id, index, variant: int) -> Type_Id {
	info := underlying_info(c, type)
	if info == nil {
		return INVALID_TYPE
	}
	#partial switch info.kind {
	case .Array, .Simd, .Slice:
		return info.element
	case .Union:
		return union_variant_payload(c, type, variant)
	case .Struct:
		if index < len(info.fields) {
			if symbol := symbol_of(c, info.fields[index]); symbol != nil {
				return symbol.type
			}
		}
	}
	return INVALID_TYPE
}

@(private = "file")
value_from_const :: proc(ev: ^Evaluator, cv: Const_Value, type: Type_Id) -> (out: Eval_Value, success: bool) {
	value := scalar(cv, type)
	// A container's all-zero header reads back as the empty container.
	if type_is_container(ev.k.c, type) {
		return Eval_Value{kind = .Aggregate, type = type}, true
	}
	if cv.kind == .Aggregate && cv.aggregate != nil {
		holder := type != INVALID_TYPE ? type : cv.aggregate.type
		value.type = holder
		value.variant = cv.aggregate.variant
		value.elements = eval_elements(ev, len(cv.aggregate.elements)) or_return
		for element, index in cv.aggregate.elements {
			member := element_type_at(ev.k.c, holder, index, cv.aggregate.variant)
			value.elements[index] = value_from_const(ev, element, member) or_return
		}
	}
	return value, true
}

// A deep copy, so an assigned aggregate never aliases its source. A slice is
// a view, and a copy of it views the same elements.
@(private = "file")
copy_value :: proc(ev: ^Evaluator, v: Eval_Value) -> (out: Eval_Value, success: bool) {
	if v.elements == nil || underlying_kind(ev.k.c, v.type) == .Slice {
		return v, true
	}
	out = v
	out.capacity = 0
	out.elements = eval_elements(ev, len(v.elements)) or_return
	for element, index in v.elements {
		out.elements[index] = copy_value(ev, element) or_return
	}
	return out, true
}

// Evaluates `e`, then copies the value before anything later can change its source.
@(private = "file")
eval_copied :: proc(ev: ^Evaluator, e: Expr) -> (out: Eval_Value, success: bool) {
	value := eval_expr(ev, e) or_return
	return copy_value(ev, value)
}

// What evaluation hands the program. design.md "Compile-time procedure
// evaluation": a capture literal's record is used only while evaluation runs,
// so neither it nor a value holding one is a result.
@(private = "file")
freeze_result :: proc(ev: ^Evaluator, v: Eval_Value) -> (Const_Value, bool) {
	if eval_holds_capture(ev.k.c, v) {
		eval_fail(
			ev, ev.origin, "L0341",
			"a capture literal is a runtime value: it may be made and called during compile-time evaluation, but cannot be its result",
		)
		return Const_Value{}, false
	}
	return freeze(ev, v)
}

@(private = "file")
eval_holds_capture :: proc(c: ^Compiler, v: Eval_Value) -> bool {
	if type_is_capture_record(c, type_underlying(c, v.type)) {
		return true
	}
	for element in v.elements {
		if eval_holds_capture(c, element) {
			return true
		}
	}
	return false
}

// Into immutable compilation storage; a pointer cannot make the trip.
@(private = "file")
freeze :: proc(ev: ^Evaluator, v: Eval_Value, allocator: mem.Allocator = {}) -> (out: Const_Value, success: bool) {
	storage := value_allocator(ev.k.c, allocator)
	if v.target != nil || v.proc_value != INVALID_SYMBOL {
		eval_fail(ev, ev.origin, "L0341", "a pointer cannot escape compile-time evaluation")
		return Const_Value{}, false
	}
	// design.md "Compile-time procedure evaluation": a box owns an allocation the
	// generated program would have to release.
	if type_is_box(ev.k.c, v.type) {
		eval_fail(ev, ev.origin, "L0594", "a `%s` cannot escape compile-time evaluation", type_name(ev.k.c, v.type))
		return Const_Value{}, false
	}
	// design.md: a container's only constant is the empty one.
	if type_is_container(ev.k.c, v.type) {
		if len(v.elements) > 0 {
			eval_fail(
				ev, ev.origin, "L0594",
				"a `%s` cannot escape compile-time evaluation: its only constant value is the empty one",
				type_name(ev.k.c, v.type),
			)
			return Const_Value{}, false
		}
		return zero_const(ev.k.c, v.type)
	}
	cv := const_of(v)
	// A bit-cast `typeid` keeps its number there too (`typeid_number_const`).
	if v.kind == .Integer || v.kind == .Rune || (v.kind == .Type && !bi_is_zero(v.integer)) {
		cv.integer = bi_clone(storage, v.integer)
	} else if v.kind == .String {
		cv.text = strings.clone(v.text, storage)
	}
	if v.kind == .Aggregate {
		elements, err := make([]Const_Value, len(v.elements), storage)
		if err != nil { return Const_Value{}, false }
		for element, index in v.elements {
			frozen := freeze(ev, element, storage) or_return
			elements[index] = frozen
		}
		aggregate := new(Const_Aggregate, storage)
		if aggregate == nil { return Const_Value{}, false }
		aggregate.type = v.type
		aggregate.elements = elements
		aggregate.variant = v.variant
		cv.aggregate = aggregate
	}
	return cv, true
}

// A constant built in evaluator storage has served its purpose: an evaluated
// value holds its integers and strings, never these tables.
@(private = "file")
eval_release_tables :: proc(ev: ^Evaluator, value: Const_Value) {
	if value.kind != .Aggregate || value.aggregate == nil {
		return
	}
	for element in value.aggregate.elements {
		eval_release_tables(ev, element)
	}
	delete(value.aggregate.elements, ev.alloc)
	free(value.aggregate, ev.alloc)
}

@(private = "file")
const_of :: proc(v: Eval_Value) -> Const_Value {
	return v.constant
}

@(private = "file")
scalar :: proc(cv: Const_Value, type: Type_Id) -> Eval_Value {
	value := Eval_Value{constant = cv, type = type}
	value.aggregate = nil
	return value
}

@(private = "file")
zero_value :: proc(ev: ^Evaluator, type: Type_Id) -> (out: Eval_Value, success: bool) {
	if type_is_pointer(ev.k.c, type) {
		return Eval_Value{kind = .Nil, type = type}, true
	}
	// design.md: a container's zero value is empty.
	if type_is_container(ev.k.c, type) {
		return Eval_Value{kind = .Aggregate, type = type}, true
	}
	// A box has no zero; this is the inert value `drop` and `move` leave behind.
	if type_is_box(ev.k.c, type) {
		return Eval_Value{kind = .Invalid, type = type}, true
	}
	// Nor has a `type` or a descriptor; this is what a compile-time-only
	// procedure's result holds until its `return`.
	if type_is_compile_time_only(ev.k.c, type) {
		return Eval_Value{kind = .Invalid, type = type}, true
	}
	// design.md "Empty slices": a slice's zero value is the empty view.
	if type_is_slice(ev.k.c, type) {
		return Eval_Value{kind = .Nil, type = type}, true
	}
	info := underlying_info(ev.k.c, type)
	if info == nil { return Eval_Value{}, false }
	#partial switch info.kind {
	case .Int, .Enum, .Rune:
		return Eval_Value{kind = info.kind == .Rune ? .Rune : .Integer, type = type, integer = bi_zero(ev.alloc)}, true
	case .Array, .Struct, .Dyn:
		count := info.kind == .Array ? int(info.count) : len(info.fields)
		kind, element, fields := info.kind, info.element, info.fields
		elements := eval_elements(ev, count) or_return
		for index in 0 ..< count {
			element_type := element
			field: ^Symbol
			if kind != .Array {
				field = symbol_of(ev.k.c, fields[index])
				if field == nil { return Eval_Value{}, false }
				element_type = field.type
			}
			if field != nil && field.initialized_by != INVALID_SYMBOL {
				value := value_from_const(ev, capacity_const(ev.k.c, field.type), field.type) or_return
				elements[index] = value
				continue
			}
			value := zero_value(ev, element_type) or_return
			elements[index] = value
		}
		return Eval_Value{kind = .Aggregate, type = type, elements = elements}, true
	}
	zero, ok := zero_const(ev.k.c, type)
	if !ok {
		return Eval_Value{kind = .Invalid, type = type}, false
	}
	return value_from_const(ev, zero, type)
}

// design.md "Compile-time procedure evaluation": a record with a hook is rejected
// where it is made. A zero holds one only in a record, a fixed array, or a union's
// zero variant.
@(private = "file")
eval_hooks_supported :: proc(ev: ^Evaluator, type: Type_Id, site: Span) -> bool {
	info := underlying_info(ev.k.c, type)
	if info == nil {
		return true
	}
	#partial switch info.kind {
	case .Array:
		return eval_hooks_supported(ev, info.element, site)
	case .Union:
		return !info.zero_designated || eval_hooks_supported(ev, info.variants[0], site)
	case .Struct:
		if !eval_record_hooks_supported(ev, type, site) {
			return false
		}
		for field in info.fields {
			if symbol := symbol_of(ev.k.c, field); symbol != nil && !eval_hooks_supported(ev, symbol.type, site) {
				return false
			}
		}
	}
	return true
}

// A folded constant arrives whole, so it is checked by what it holds: a union
// by the payload of its variant, which its type alone does not say.
@(private = "file")
eval_constant_hooks_supported :: proc(ev: ^Evaluator, cv: Const_Value, type: Type_Id, site: Span) -> bool {
	c := ev.k.c
	if underlying_kind(c, type) == .Struct && !eval_record_hooks_supported(ev, type, site) {
		return false
	}
	if cv.kind != .Aggregate || cv.aggregate == nil || type_is_container(c, type) {
		return true
	}
	for element, index in cv.aggregate.elements {
		member := element_type_at(c, type, index, cv.aggregate.variant)
		if !eval_constant_hooks_supported(ev, element, member, site) {
			return false
		}
	}
	return true
}

@(private = "file")
eval_record_hooks_supported :: proc(ev: ^Evaluator, type: Type_Id, site: Span) -> bool {
	lifecycle := lifecycle_of(ev.k.c, type)
	if lifecycle.custom_drop == INVALID_SYMBOL && lifecycle.custom_try_clone == INVALID_SYMBOL {
		return true
	}
	return eval_fail(
		ev, site, "L0341", "`%s` has a `hook(%s)`, and compile-time evaluation runs no lifecycle hook",
		type_name(ev.k.c, type), lifecycle.custom_drop != INVALID_SYMBOL ? "drop" : "copy",
	)
}

@(private = "file")
current_frame :: proc(ev: ^Evaluator) -> ^Eval_Frame {
	if len(ev.frames) == 0 {
		return nil
	}
	return ev.frames[len(ev.frames) - 1]
}

@(private = "file")
eval_expr :: proc(ev: ^Evaluator, e: Expr) -> (out: Eval_Value, success: bool) {
	base := expr_base(e)
	if base == nil {
		return Eval_Value{}, false
	}
	// design.md "Borrowed callable views" and "Variadic parameters": a view is
	// built at run time.
	if base.erased_from != INVALID_TYPE && type_is_dyn(ev.k.c, base.type) {
		eval_fail(
			ev, expr_span(e), "L0341", "a `%s` view has no compile-time value",
			dyn_proc_signature(ev.k.c, base.type) != INVALID_TYPE ? "dyn proc" : "dyn",
		)
		return Eval_Value{}, false
	}
	// design.md "Owned values": a box lent as the `^T` of its payload.
	if base.view_from != INVALID_TYPE && underlying_kind(ev.k.c, base.view_from) == .Box &&
	   underlying_kind(ev.k.c, base.type) == .Pointer {
		payload := eval_box_payload(ev, e, expr_span(e)) or_return
		return Eval_Value{kind = .Nil, type = base.type, target = payload}, true
	}
	// design.md "Widening by label": the same payload under the wider tag.
	if base.widened_from != INVALID_TYPE {
		value := eval_value_unviewed(ev, e) or_return
		return widen_eval_value(ev.k.c, value, base.widened_from, base.type), true
	}
	return eval_value_unviewed(ev, e)
}

@(private = "file")
widen_eval_value :: proc(c: ^Compiler, value: Eval_Value, from, to: Type_Id) -> Eval_Value {
	widened := value
	widened.type = to
	widened.variant = widened_variant(c, from, to, value.variant)
	return widened
}

// `eval_expr` before an implicit loan recorded on the node itself.
@(private = "file")
eval_value_unviewed :: proc(ev: ^Evaluator, e: Expr) -> (out: Eval_Value, success: bool) {
	defer { if !eval_memory_ok(ev) { success = false } }
	if e == nil {
		return Eval_Value{}, false
	}
	eval_step(ev, expr_span(e)) or_return
	base := expr_base(e)
	if base == nil || base.type == INVALID_TYPE {
		return Eval_Value{}, false
	}
	if base_is_const(base) {
		// A folded record literal is made here as well.
		if base.const_value.kind == .Aggregate {
			eval_constant_hooks_supported(ev, base.const_value, base.type, expr_span(e)) or_return
		}
		return value_from_const(ev, base.const_value, base.type)
	}

	switch v in e {
	case ^Expr_Ident:
		return eval_ident(ev, v)

	case ^Expr_Selector:
		return eval_selector(ev, v)

	case ^Expr_Index:
		return eval_index(ev, v)

	case ^Expr_Postfix:
		return eval_postfix(ev, v)

	case ^Expr_Propagated_Error:
		if error, ok := ev.propagated[v.owner]; ok {
			return error, true
		}
		eval_fail(ev, v.span, "L0341", "this `or_return` has no compile-time target")
		return Eval_Value{}, false

	case ^Expr_Unary:
		return eval_unary(ev, v)

	case ^Expr_Binary:
		return eval_binary(ev, v)

	case ^Expr_Cond:
		cond := eval_expr(ev, v.cond) or_return
		return eval_expr(ev, cond.boolean ? v.then : v.otherwise)

	case ^Expr_Call:
		if v.dispatch != nil {
			return eval_dispatch(ev, v.dispatch)
		}
		return eval_call(ev, v)

	case ^Expr_Composite:
		return eval_composite(ev, v)

	case ^Expr_Range:
		return eval_range(ev, v)

	case ^Expr_Proc:
		return Eval_Value{kind = .Nil, type = v.type, proc_value = v.symbol}, true

	case ^Expr_Or_Else:
		return eval_or_else(ev, v)

	case ^Expr_Slice:
		return eval_slice(ev, v)

	case ^Expr_Move:
		return eval_move(ev, v)

	case ^Expr_Error, ^Expr_Literal,
	     ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_C_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Anon_Record, ^Type_Anon_Union, ^Type_Enum, ^Type_Interface:
	}
	eval_fail(ev, expr_span(e), "L0341", "this expression has no compile-time meaning")
	return Eval_Value{}, false
}

@(private = "file")
eval_selector :: proc(ev: ^Evaluator, v: ^Expr_Selector) -> (out: Eval_Value, success: bool) {
	// `Type.method` or `U.name` naming a procedure, as a value.
	if sym := symbol_of(ev.k.c, v.resolution.symbol); v.resolution.kind == .Value && sym != nil && sym.kind == .Proc {
		return Eval_Value{kind = .Nil, type = v.type, proc_value = v.resolution.symbol}, true
	}
	if table := eval_folded_table(ev, v.operand); table != nil {
		at := eval_field_index(ev, v, len(table.elements)) or_return
		return eval_folded_element(ev, v.operand, table, at)
	}
	// A value, not a place: `f().field` selects out of a temporary.
	operand := eval_aggregate_value(ev, v.operand) or_return
	field := eval_field(ev, v, operand.elements) or_return
	return field^, true
}

@(private = "file")
eval_index :: proc(ev: ^Evaluator, v: ^Expr_Index) -> (out: Eval_Value, success: bool) {
	// design.md "Indexing and slicing": a user `operator([])` is called with
	// the arguments the checker bound, receiver first.
	if v.resolution.kind == .User_Operator {
		return eval_operator_call(ev, v.resolution.symbol, v.bound, v.span)
	}
	if table := eval_folded_table(ev, v.operand); table != nil {
		at := eval_index_value(ev, v.indices[0], len(table.elements)) or_return
		return eval_folded_element(ev, v.operand, table, at)
	}
	operand := eval_aggregate_value(ev, v.operand) or_return
	// design.md "Maps": a read never inserts.
	if type_is_map(ev.k.c, operand.type) {
		key := eval_expr(ev, v.indices[0]) or_return
		entry := eval_map_entry(ev, &operand, key, v.span) or_return
		return entry^, true
	}
	at := eval_index_value(ev, v.indices[0], len(operand.elements)) or_return
	return operand.elements[at], true
}

// A constant the checker folded, of which a read makes only the part it selects,
// so a loop over a table does not rebuild the table per read.
@(private = "file")
eval_folded_table :: proc(ev: ^Evaluator, operand: Expr) -> ^Const_Aggregate {
	base := expr_base(operand)
	if base == nil || base.const_value.kind != .Aggregate || type_is_container(ev.k.c, base.type) {
		return nil
	}
	return base.const_value.aggregate
}

@(private = "file")
eval_folded_element :: proc(ev: ^Evaluator, operand: Expr, table: ^Const_Aggregate, at: int) -> (out: Eval_Value, success: bool) {
	member := element_type_at(ev.k.c, expr_base(operand).type, at, table.variant)
	eval_constant_hooks_supported(ev, table.elements[at], member, expr_span(operand)) or_return
	return value_from_const(ev, table.elements[at], member)
}

// An index expression's value, within `count` elements.
@(private = "file")
eval_index_value :: proc(ev: ^Evaluator, index: Expr, count: int) -> (out: int, success: bool) {
	value := eval_expr(ev, index) or_return
	at, fits := bi_to_i64(ev.alloc, value.integer)
	if !fits || at < 0 || int(at) >= count {
		eval_fail(ev, expr_span(index), "L0361", "index %s is out of range", bi_text(ev.alloc, value.integer))
		return 0, false
	}
	return int(at), true
}

@(private = "file")
eval_postfix :: proc(ev: ^Evaluator, v: ^Expr_Postfix) -> (out: Eval_Value, success: bool) {
	if v.op == .Or_Return {
		return eval_or_return(ev, v)
	}
	if v.boxed {
		return eval_unbox(ev, v.operand, v.span)
	}
	pointer := eval_expr(ev, v.operand) or_return
	target := eval_deref(ev, pointer, v.op_span) or_return
	return target^, true
}

// design.md "Owned values": the payload is the box's one element.
@(private = "file")
eval_box_element :: proc(ev: ^Evaluator, holder: ^Eval_Value, span: Span) -> (^Eval_Value, bool) {
	if len(holder.elements) != 1 {
		return nil, eval_fail(ev, span, "L0341", "this box holds no value")
	}
	return &holder.elements[0], true
}

// The payload's storage, of the box `operand` denotes or of a temporary one.
@(private = "file")
eval_box_payload :: proc(ev: ^Evaluator, operand: Expr, span: Span) -> (out: ^Eval_Value, success: bool) {
	holder: ^Eval_Value
	if expr_base(operand).addressable {
		holder = eval_place(ev, operand) or_return
	} else {
		value := eval_value_unviewed(ev, operand) or_return
		holder = eval_slot(ev, value) or_return
	}
	return eval_box_element(ev, holder, span)
}

@(private = "file")
eval_unbox :: proc(ev: ^Evaluator, operand: Expr, span: Span) -> (out: Eval_Value, success: bool) {
	boxed := eval_expr(ev, operand) or_return
	payload := eval_box_element(ev, &boxed, span) or_return
	return payload^, true
}

@(private = "file")
eval_range :: proc(ev: ^Evaluator, v: ^Expr_Range) -> (out: Eval_Value, success: bool) {
	low := eval_expr(ev, v.lo) or_return
	high := eval_expr(ev, v.hi) or_return
	elements := eval_elements(ev, 3) or_return
	elements[RANGE_LOW] = low
	elements[RANGE_HIGH] = high
	elements[RANGE_CLOSED] = Eval_Value{
		kind = .Boolean, type = TYPE_BOOL, boolean = v.op == .Range_Incl,
	}
	return Eval_Value{kind = .Aggregate, type = v.type, elements = elements}, true
}

// The value leaves its place, which is left inert as at run time.
@(private = "file")
eval_move :: proc(ev: ^Evaluator, v: ^Expr_Move) -> (out: Eval_Value, success: bool) {
	place := eval_place(ev, v.value) or_return
	value := place^
	if zeroed, made := zero_value(ev, place.type); made {
		place^ = zeroed
	} else {
		place^ = Eval_Value{kind = .Invalid, type = value.type}
	}
	return value, true
}

@(private = "file")
eval_ident :: proc(ev: ^Evaluator, v: ^Expr_Ident) -> (Eval_Value, bool) {
	if frame := current_frame(ev); frame != nil {
		if slot, ok := frame.locals[v.symbol]; ok {
			return slot^, true
		}
	}
	symbol := symbol_of(ev.k.c, v.symbol)
	if symbol == nil {
		return Eval_Value{}, false
	}
	#partial switch symbol.kind {
	case .Const, .Enum_Member:
		return value_from_const(ev, symbol.const_value, v.type)
	case .Proc:
		if !ensure_proc_typed_for_eval(ev.k, v.symbol) {
			eval_fail(ev, v.span, "L0344", "`%s` cannot be evaluated: its declaration is still being checked", v.name)
			return Eval_Value{}, false
		}
		return Eval_Value{kind = .Nil, type = v.type, proc_value = v.symbol}, true
	case .Var:
		eval_fail(ev, v.span, "L0341", "`%s` is a mutable variable and cannot be read at compile time", v.name)
		return Eval_Value{}, false
	}
	eval_fail(ev, v.span, "L0341", "`%s` has no compile-time value", v.name)
	return Eval_Value{}, false
}

@(private = "file")
eval_unary :: proc(ev: ^Evaluator, v: ^Expr_Unary) -> (out: Eval_Value, success: bool) {
	// design.md "Operator declarations": a user operator is an ordinary call.
	if v.resolution.kind == .User_Operator {
		operands := [1]Expr{v.operand}
		return eval_operator_call(ev, v.resolution.symbol, operands[:], v.op_span)
	}
	if v.op == .Amp {
		slot := eval_place(ev, v.operand) or_return
		return Eval_Value{kind = .Nil, type = v.type, target = slot}, true
	}
	operand := eval_expr(ev, v.operand) or_return
	// design.md "SIMD vectors": lane-wise.
	if type_is_simd(ev.k.c, v.type) {
		return eval_simd_unary(ev, v.op, v.op_span, v.type, operand)
	}
	return eval_unary_value(ev, v.op, v.op_span, const_of(operand), v.type)
}

// A scalar unary operation on a folded operand of `type`; a delegated operator
// applies it to the unwrapped value too.
@(private = "file")
eval_unary_value :: proc(ev: ^Evaluator, op: Token_Kind, site: Span, value: Const_Value, type: Type_Id) -> (Eval_Value, bool) {
	#partial switch op {
	case .Plus, .Minus, .Tilde, .Not:
	case:
		eval_fail(ev, site, "L0341", "`%s` has no compile-time meaning", operator_text(op))
		return Eval_Value{}, false
	}
	folded, ok := fold_unary(ev.k.c, op, site, value, type, ev.alloc)
	if !ok {
		eval_fold_failed(ev)
		return Eval_Value{}, false
	}
	return scalar(folded, type), true
}

@(private = "file")
eval_binary :: proc(ev: ^Evaluator, v: ^Expr_Binary) -> (out: Eval_Value, success: bool) {
	// design.md "Operator declarations": a user operator is an ordinary call,
	// and `!=` without its own overload negates the user `==`.
	if v.resolution.kind == .User_Operator {
		operands := [2]Expr{v.lhs, v.rhs}
		result := eval_operator_call(ev, v.resolution.symbol, operands[:], v.op_span) or_return
		if !v.negated {
			return result, true
		}
		return scalar(bool_const(!result.boolean), v.type), true
	}
	#partial switch v.op {
	case .In:
		return eval_in(ev, v)
	case .And_And, .Or_Or:
		left := eval_expr(ev, v.lhs) or_return
		if (v.op == .And_And) != left.boolean {
			return scalar(bool_const(v.op == .Or_Or), v.type), true
		}
		right := eval_expr(ev, v.rhs) or_return
		return scalar(bool_const(right.boolean), v.type), true
	}

	left := eval_expr(ev, v.lhs) or_return
	right := eval_expr(ev, v.rhs) or_return

	// design.md "SIMD vectors": lane-wise, since `const_of` carries no lanes.
	if type_is_simd(ev.k.c, v.type) {
		return eval_simd_binary_values(ev, v.op, v.op_span, v.type, left, right)
	}
	#partial switch v.op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		result := eval_compare_at(ev, v.op, left, right, v.op_span) or_return
		return scalar(bool_const(result), v.type), true
	}

	folded, ok := fold_arithmetic(ev.k.c, v.op, v.op_span, const_of(left), const_of(right), v.type, ev.alloc)
	if !ok {
		eval_fold_failed(ev)
		return Eval_Value{}, false
	}
	return scalar(folded, v.type), true
}

// `-v` and `~v`, one lane at a time. `+v` is the operand.
@(private = "file")
eval_simd_unary :: proc(
	ev: ^Evaluator, op: Token_Kind, op_span: Span, type: Type_Id, operand: Eval_Value,
) -> (out: Eval_Value, success: bool) {
	if op == .Plus {
		return operand, true
	}
	info := underlying_info(ev.k.c, type)
	if info == nil {
		return Eval_Value{}, false
	}
	elements := eval_elements(ev, int(info.count)) or_return
	for index in 0 ..< int(info.count) {
		lane := const_of(eval_simd_lane(operand, index))
		elements[index] = eval_unary_value(ev, op, op_span, lane, info.element) or_return
	}
	return Eval_Value{kind = .Aggregate, type = type, elements = elements}, true
}

// One lane at a time; either operand may be a splatted scalar.
@(private = "file")
eval_simd_binary_values :: proc(
	ev: ^Evaluator, op: Token_Kind, op_span: Span, type: Type_Id, left, right: Eval_Value,
) -> (out: Eval_Value, success: bool) {
	info := underlying_info(ev.k.c, type)
	if info == nil {
		return Eval_Value{}, false
	}
	comparison := false
	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		comparison = true
	}
	// A comparison's lanes are `bool`, unlike its operands'.
	source := underlying_info(ev.k.c, type_is_simd(ev.k.c, left.type) ? left.type : right.type)
	elements := eval_elements(ev, int(info.count)) or_return
	for index in 0 ..< int(info.count) {
		a, b := eval_simd_lane(left, index), eval_simd_lane(right, index)
		if comparison {
			result := eval_compare_at(ev, op, a, b, op_span) or_return
			elements[index] = scalar(bool_const(result), info.element)
			continue
		}
		folded, ok := fold_arithmetic(
			ev.k.c, op, op_span, const_of(a), const_of(b), source.element, ev.alloc,
		)
		if !ok {
			eval_fold_failed(ev)
			return Eval_Value{}, false
		}
		elements[index] = scalar(folded, source.element)
	}
	return Eval_Value{kind = .Aggregate, type = type, elements = elements}, true
}

@(private = "file")
eval_simd_lane :: proc(value: Eval_Value, index: int) -> Eval_Value {
	if value.kind != .Aggregate || index >= len(value.elements) {
		return value
	}
	return value.elements[index]
}

// standard-library.md "`core:simd`": a fold from lane 0, left to right, as the emitted
// ordered reduction does. A float sum or product needs no `-0.0` or `1.0` seed
// here, because the seed combined with lane 0 is lane 0. `reduce_min` and
// `reduce_max` skip NaN lanes, so only an all-NaN vector answers NaN.
@(private = "file")
eval_simd_reduce :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (out: Eval_Value, success: bool) {
	vector := eval_expr(ev, v.bound[0]) or_return
	info := underlying_info(ev.k.c, expr_base(v.bound[0]).type)
	fold := v.operation.(Call_Simd_Reduce).fold
	result := eval_simd_lane(vector, 0)
	for index in 1 ..< int(info.count) {
		lane := eval_simd_lane(vector, index)
		switch fold {
		case .Any:
			result.boolean = result.boolean || lane.boolean
		case .All:
			result.boolean = result.boolean && lane.boolean
		case .Add, .Mul:
			folded, folded_ok := fold_arithmetic(
				ev.k.c, fold == .Add ? .Plus : .Star, v.span, const_of(result), const_of(lane), info.element, ev.alloc,
			)
			if !folded_ok {
				eval_fold_failed(ev)
				return Eval_Value{}, false
			}
			result = scalar(folded, info.element)
		case .Min, .Max:
			if lane.kind == .Float && lane.float != lane.float {
				continue
			}
			better := eval_compare_at(ev, fold == .Min ? .Lt : .Gt, lane, result, v.span) or_return
			if better || (result.kind == .Float && result.float != result.float) {
				result = lane
			}
		}
	}
	result.type = v.type
	return result, true
}

// `fold_arithmetic` reported its own failure, unless memory ran out.
@(private = "file")
eval_fold_failed :: proc(ev: ^Evaluator) {
	if eval_memory_ok(ev) {
		ev.failed = true
	}
}

// Pointer and procedure identity are the evaluator's own.
@(private = "file")
eval_compare :: proc(ev: ^Evaluator, op: Token_Kind, a, b: Eval_Value) -> (out: bool, success: bool) {
	if a.target != nil || b.target != nil || a.proc_value != INVALID_SYMBOL || b.proc_value != INVALID_SYMBOL ||
	   (a.kind == .Nil && b.kind == .Nil) {
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		equal := a.target == b.target && a.proc_value == b.proc_value
		return equal == (op == .Eq_Eq), true
	}
	// design.md "Comparison operators": a part with its own `==` runs it, a
	// scalar `distinct` one as much as a record.
	if op == .Eq_Eq || op == .Not_Eq {
		if equal := type_own_equality(ev.k.c, a.type); equal != INVALID_SYMBOL {
			if !ensure_proc_typed_for_eval(ev.k, equal) {
				return false, eval_fail(ev, ev.origin, "L0341", "this equality cannot be evaluated")
			}
			result, ok := eval_invoke(ev, equal, nil, ev.origin, []Eval_Value{a, b})
			if !ok || result.kind != .Boolean {
				return false, false
			}
			return result.boolean == (op == .Eq_Eq), true
		}
	}
	if a.kind == .Aggregate && b.kind == .Aggregate {
		// design.md "Comparison operators": an anonymous record orders by its
		// first unequal field, and equal records answer `<=` and `>=`.
		if op != .Eq_Eq && op != .Not_Eq {
			if len(a.elements) != len(b.elements) || !type_is_ordered(ev.k.c, a.type) {
				return false, false
			}
			for element, index in a.elements {
				other := b.elements[index]
				equal := eval_compare(ev, .Eq_Eq, element, other) or_return
				if equal {
					continue
				}
				if op == .Gt || op == .Gt_Eq {
					return eval_compare(ev, .Lt, other, element)
				}
				return eval_compare(ev, .Lt, element, other)
			}
			return op == .Lt_Eq || op == .Gt_Eq, true
		}
		// As `aggregate_equal`: counts match, and a union's variants too.
		if len(a.elements) != len(b.elements) {
			return op == .Not_Eq, true
		}
		if type_is_union(ev.k.c, a.type) {
			if a.variant != b.variant {
				return op == .Not_Eq, true
			}
			if union_variant_payload(ev.k.c, a.type, a.variant) == TYPE_VOID {
				return op == .Eq_Eq, true
			}
		}
		known := true
		info := underlying_info(ev.k.c, a.type)
		for element, index in a.elements {
			other := b.elements[index]
			field := info != nil && info.kind == .Struct ? symbol_of(ev.k.c, info.fields[index]) : nil
			counter := field != nil ? symbol_of(ev.k.c, field.initialized_by) : nil
			if counter == nil {
				if !eval_part_equal(ev, element, other, &known) {
					return op == .Not_Eq, !ev.failed
				}
				continue
			}
			count, in_range := common_live_count(
				ev.alloc, a.elements[counter.index].integer, b.elements[counter.index].integer,
				len(element.elements), len(other.elements),
			)
			if !in_range {
				eval_fail(ev, ev.origin, "L0343", "an initialized prefix count is out of range")
				return false, false
			}
			for at in 0 ..< count {
				if !eval_part_equal(ev, element.elements[at], other.elements[at], &known) {
					return op == .Not_Eq, !ev.failed
				}
			}
		}
		return op == .Eq_Eq, known
	}
	return fold_comparison(ev.k.c, op, const_of(a), const_of(b), ev.alloc)
}

// Whether two parts can still be equal. As in `aggregate_equal`, a part with no
// compile-time comparison makes the answer unknown unless another part differs.
@(private = "file")
eval_part_equal :: proc(ev: ^Evaluator, a, b: Eval_Value, known: ^bool) -> bool {
	same, ok := eval_compare(ev, .Eq_Eq, a, b)
	if !ok {
		known^ = false
		return !ev.failed
	}
	return same
}

@(private = "file")
eval_compare_at :: proc(ev: ^Evaluator, op: Token_Kind, a, b: Eval_Value, span: Span) -> (out: bool, success: bool) {
	out, success = eval_compare(ev, op, a, b)
	if !success {
		eval_fail(ev, span, "L0341", "this comparison has no compile-time meaning")
	}
	return
}

// design.md "Capture literals": a capture literal is its record's literal, whose
// elements are the captures as their modes take them.
@(private = "file")
eval_composite :: proc(ev: ^Evaluator, v: ^Expr_Composite) -> (out: Eval_Value, success: bool) {
	// design.md "Slice literals": a slice's constant is its elements in order.
	if type_is_container(ev.k.c, v.type) || type_is_slice(ev.k.c, v.type) {
		return eval_container_literal(ev, v)
	}
	eval_hooks_supported(ev, v.type, v.span) or_return
	value := zero_value(ev, v.type) or_return
	if value.kind != .Aggregate {
		eval_fail(ev, v.span, "L0341", "this literal has no compile-time value")
		return Eval_Value{}, false
	}
	info := underlying_info(ev.k.c, v.type)
	if info == nil {
		return Eval_Value{}, false
	}
	for element, index in v.elements {
		slot, end := composite_element_slots(v, index)
		if info.kind == .Struct {
			slot = index < len(v.field_indices) ? v.field_indices[index] : -1
			end = slot + 1
		}
		if slot < 0 || end > len(value.elements) {
			eval_fail(ev, v.span, "L0405", "a literal element has no checked field")
			return Eval_Value{}, false
		}
		computed := eval_expr(ev, element.value) or_return
		// A designated index range fills each of its slots with a copy.
		for target in slot ..< end {
			copied := copy_value(ev, computed) or_return
			value.elements[target] = copied
		}
	}
	return value, true
}

// A compile-time container is only its contents: a `[dynamic]T`'s elements, or a
// map's key/value pairs in insertion order. Capacity and map iteration order
// have no compile-time answer and are rejected, never approximated.

// The key and value halves of a map entry live at `2i` and `2i+1`.
@(private = "file")
MAP_ENTRY_KEY :: 0
@(private = "file")
MAP_ENTRY_VALUE :: 1

@(private = "file")
eval_container_literal :: proc(ev: ^Evaluator, v: ^Expr_Composite) -> (out: Eval_Value, success: bool) {
	is_map := type_is_map(ev.k.c, v.type)
	elements := eval_elements(ev, len(v.elements) * (is_map ? 2 : 1)) or_return
	// A map entry's key is evaluated before its value (design.md "Evaluation
	// order"), and each is copied before later elements can change its source.
	for element, index in v.elements {
		if !is_map {
			elements[index] = eval_copied(ev, element.value) or_return
			continue
		}
		elements[2 * index + MAP_ENTRY_KEY] = eval_copied(ev, element.key) or_return
		elements[2 * index + MAP_ENTRY_VALUE] = eval_copied(ev, element.value) or_return
	}
	literal := Eval_Value{kind = .Aggregate, type = v.type, elements = elements}
	if is_map {
		return map_deduplicate(ev, literal)
	}
	return literal, true
}

// A repeated key keeps the last value, as at run time. Entries move down within
// the literal's own block.
@(private = "file")
map_deduplicate :: proc(ev: ^Evaluator, m: Eval_Value) -> (out: Eval_Value, success: bool) {
	out = m
	out.elements = m.elements[:0]
	for index := 0; index < len(m.elements); index += 2 {
		at := map_find(ev, &out, m.elements[index]) or_return
		if at >= 0 {
			out.elements[at + MAP_ENTRY_VALUE] = m.elements[index + MAP_ENTRY_VALUE]
			continue
		}
		kept := len(out.elements)
		m.elements[kept + MAP_ENTRY_KEY] = m.elements[index + MAP_ENTRY_KEY]
		m.elements[kept + MAP_ENTRY_VALUE] = m.elements[index + MAP_ENTRY_VALUE]
		out.elements = m.elements[:kept + 2]
	}
	return out, true
}

// The entry index of `key`, or -1. A linear scan: each comparison costs a step, so
// the step limit stops a map at about 1400 keys, too few to want a hash index.
@(private = "file")
map_find :: proc(ev: ^Evaluator, m: ^Eval_Value, key: Eval_Value) -> (out: int, success: bool) {
	for index := 0; index < len(m.elements); index += 2 {
		same := eval_map_key_equal(ev, m.type, m.elements[index], key) or_return
		if same {
			return index, true
		}
	}
	return -1, true
}

// The runtime's key policy; structural equality only for the built-in one.
@(private = "file")
eval_map_key_equal :: proc(ev: ^Evaluator, map_type: Type_Id, a, b: Eval_Value) -> (out: bool, success: bool) {
	eval_step(ev, ev.origin) or_return
	policy := ev.k.c.map_key_policies[container_key(ev.k.c, map_type)]
	if !key_policy_settled(policy) {
		return false, eval_fail(ev, ev.origin, "L0405", "a map key operation was not resolved during checking")
	}
	if policy.kind == .Builtin {
		return eval_compare(ev, .Eq_Eq, a, b)
	}
	if policy.equal == INVALID_SYMBOL || !ensure_proc_typed_for_eval(ev.k, policy.equal) {
		return false, eval_fail(ev, ev.origin, "L0341", "the map key's equality cannot be evaluated")
	}
	result := eval_invoke(ev, policy.equal, nil, ev.origin, []Eval_Value{a, b}) or_return
	if result.kind != .Boolean {
		return false, eval_fail(ev, ev.origin, "L0341", "the map key's equality must return a boolean")
	}
	return result.boolean, true
}

// The value slot of `key`, which must be there.
@(private = "file")
eval_map_entry :: proc(ev: ^Evaluator, m: ^Eval_Value, key: Eval_Value, span: Span) -> (out: ^Eval_Value, success: bool) {
	at := map_find(ev, m, key) or_return
	if at < 0 {
		// What panics at run time is a compile-time error.
		eval_fail(ev, span, "L0343", "this key is not in the map")
		return nil, false
	}
	return &m.elements[at + MAP_ENTRY_VALUE], true
}

// The value slot for `key`, adding a placeholder entry when it is missing. A new
// entry keeps `key` as it is, so the caller has copied it.
@(private = "file")
map_entry_place :: proc(ev: ^Evaluator, m: ^Eval_Value, key: Eval_Value) -> (out: ^Eval_Value, success: bool) {
	at := map_find(ev, m, key) or_return
	if at >= 0 {
		return &m.elements[at + MAP_ENTRY_VALUE], true
	}
	zero := zero_value(ev, container_element(ev.k.c, m.type)) or_return
	eval_splice(ev, m, len(m.elements), 0, key, zero) or_return
	return &m.elements[len(m.elements) - 1], true
}

// Replaces `removed` elements at `at` with `inserted`, in the block `self` has when
// they fit. A new block has room to spare, so a container that grows one element
// at a time costs memory in proportion to its size.
@(private = "file")
eval_splice :: proc(ev: ^Evaluator, self: ^Eval_Value, at, removed: int, inserted: ..Eval_Value) -> bool {
	count := len(self.elements) - removed + len(inserted)
	room := max(self.capacity, len(self.elements))
	block := raw_data(self.elements)[:room]
	if count > room {
		block = eval_elements(ev, max(count, 2 * room, 8)) or_return
		self.capacity = len(block)
		copy(block, self.elements[:at])
	}
	copy(block[at + len(inserted):], self.elements[at + removed:])
	copy(block[at:], inserted)
	self.elements = block[:count]
	return true
}

// The element's ordering: its own `<` when it has one (standard-library.md "Sorting
// slices"), otherwise the built-in comparison.
@(private = "file")
eval_less :: proc(ev: ^Evaluator, span: Span, less: Symbol_Id, a, b: Eval_Value) -> (bool, bool) {
	if less == INVALID_SYMBOL {
		return eval_compare(ev, .Lt, a, b)
	}
	result, ok := eval_operator_call(ev, less, nil, span, []Eval_Value{a, b})
	return result.boolean, ok
}

// A stable merge sort; each comparison costs a step.
@(private = "file")
eval_sort :: proc(ev: ^Evaluator, span: Span, elements: []Eval_Value, descending: bool, less: Symbol_Id) -> bool {
	if len(elements) < 2 {
		return true
	}
	scratch, err := make([]Eval_Value, len(elements), ev.alloc)
	if err != nil {
		return false
	}
	from, to := elements, scratch
	for width := 1; width < len(elements); width *= 2 {
		for lo := 0; lo < len(elements); lo += 2 * width {
			middle := min(lo + width, len(elements))
			hi := min(lo + 2 * width, len(elements))
			left, right, out := lo, middle, lo
			for left < middle && right < hi {
				if !eval_step(ev, span) {
					return false
				}
				a, b := from[right], from[left]
				// The right run's element goes first only when strictly before.
				before, ok := eval_less(ev, span, less, descending ? b : a, descending ? a : b)
				if !ok {
					return false
				}
				if before {
					to[out] = from[right]
					right += 1
				} else {
					to[out] = from[left]
					left += 1
				}
				out += 1
			}
			copy(to[out:], from[left:middle])
			copy(to[out + middle - left:], from[right:hi])
		}
		from, to = to, from
	}
	if raw_data(from) != raw_data(elements) {
		copy(elements, from)
	}
	return true
}

// A mutating operation needs a place; a read can take any value.
@(private = "file")
eval_container_op :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol) -> (out: Eval_Value, success: bool) {
	defer { if !eval_memory_ok(ev) { success = false } }
	if len(v.bound) == 0 || v.bound[0] == nil {
		return Eval_Value{}, false
	}
	receiver: Eval_Value
	self := &receiver
	if symbol.receiver == .Inout {
		self = eval_place(ev, v.bound[0]) or_return
	} else {
		receiver = eval_expr(ev, v.bound[0]) or_return
	}
	element := sequence_element(ev.k.c, self.type)

	switch symbol.container_op {
	case .None:
		eval_fail(ev, v.span, "L0405", "a container call has no operation")
		return Eval_Value{}, false

	case .Append:
		added := eval_appended(ev, v) or_return
		defer delete(added, ev.alloc)
		eval_splice(ev, self, len(self.elements), 0, ..added) or_return
		return eval_alloc_ok(ev, symbol)

	case .Sort, .Reverse_Sort:
		// A dynamic array is sorted as its place. A slice's receiver is a copy of
		// its header, but the header's elements are the viewed storage itself
		// (`eval_slice`), so sorting them sorts what the slice views (standard-library.md
		// "Sorting slices").
		if symbol.receiver != .Inout && underlying_kind(ev.k.c, self.type) != .Slice {
			eval_fail(ev, v.span, "L0341", "this value cannot be sorted at compile time")
			return Eval_Value{}, false
		}
		less := INVALID_SYMBOL
		if policy := resolved_element_order_policy(ev.k.c, element); policy.kind == .Inherent {
			less = policy.less
		}
		eval_sort(ev, v.span, self.elements, symbol.container_op == .Reverse_Sort, less) or_return
		return eval_void(), true

	case .Swap:
		// As for `sort`: a slice swaps the elements it views (standard-library.md
		// "Swapping elements").
		if symbol.receiver != .Inout && underlying_kind(ev.k.c, self.type) != .Slice {
			eval_fail(ev, v.span, "L0341", "this value cannot be rearranged at compile time")
			return Eval_Value{}, false
		}
		left := eval_count_argument(ev, v, 1) or_return
		right := eval_count_argument(ev, v, 2) or_return
		for at in ([2]int{left, right}) {
			if at >= len(self.elements) {
				eval_fail(ev, v.span, "L0361", "index %d is out of range", at)
				return Eval_Value{}, false
			}
		}
		self.elements[left], self.elements[right] = self.elements[right], self.elements[left]
		return eval_void(), true

	case .Chunks_Mut:
		// Its chunks are handed out by a protocol iterator, which compile-time
		// evaluation does not run.
		eval_fail(ev, v.span, "L0341", "`chunks_mut` has no compile-time meaning yet")
		return Eval_Value{}, false

	case .Split_At_Mut:
		// Both halves view the receiver's elements (standard-library.md "Splitting a
		// mutable slice").
		mid := eval_count_argument(ev, v, 1) or_return
		if mid > len(self.elements) {
			eval_fail(ev, v.span, "L0361", "split index %d is out of range for length %d", mid, len(self.elements))
			return Eval_Value{}, false
		}
		halves := eval_elements(ev, 2) or_return
		halves[0] = Eval_Value{kind = .Aggregate, type = self.type, elements = self.elements[:mid]}
		halves[1] = Eval_Value{kind = .Aggregate, type = self.type, elements = self.elements[mid:]}
		return Eval_Value{kind = .Aggregate, type = symbol.result, elements = halves}, true

	case .Insert:
		at := eval_count_argument(ev, v, 1) or_return
		value := eval_copied(ev, v.bound[2]) or_return
		if at > len(self.elements) {
			eval_fail(ev, v.span, "L0361", "index %d is out of range", at)
			return Eval_Value{}, false
		}
		eval_splice(ev, self, at, 0, value) or_return
		return eval_alloc_ok(ev, symbol)

	case .Pop:
		if len(self.elements) == 0 {
			return eval_option(ev, symbol.result, Eval_Value{}, false)
		}
		last := self.elements[len(self.elements) - 1]
		self.elements = self.elements[:len(self.elements) - 1]
		return eval_option(ev, symbol.result, last, true)

	case .Remove, .Remove_Unordered:
		at := eval_count_argument(ev, v, 1) or_return
		if at >= len(self.elements) {
			eval_fail(ev, v.span, "L0361", "index %d is out of range", at)
			return Eval_Value{}, false
		}
		taken := self.elements[at]
		if symbol.container_op == .Remove {
			eval_splice(ev, self, at, 1) or_return
		} else {
			// The last element moves into the hole.
			self.elements[at] = self.elements[len(self.elements) - 1]
			self.elements = self.elements[:len(self.elements) - 1]
		}
		return taken, true

	case .Clear, .Map_Clear:
		self.elements = self.elements[:0]
		return eval_void(), true

	case .Resize:
		size := eval_count_argument(ev, v, 1) or_return
		if size <= len(self.elements) {
			self.elements = self.elements[:size]
			return eval_alloc_ok(ev, symbol)
		}
		eval_hooks_supported(ev, element, v.span) or_return
		for len(self.elements) < size {
			zero := zero_value(ev, element) or_return
			eval_splice(ev, self, len(self.elements), 0, zero) or_return
		}
		return eval_alloc_ok(ev, symbol)

	case .Reserve, .Shrink, .Map_Reserve,
	     .Map_Shrink:
		// No allocation here, so these do nothing observable.
		eval_count_argument(ev, v, 1) or_return
		return eval_alloc_ok(ev, symbol)

	case .Map_Entries, .Map_Keys, .Map_Values,
	     .Map_Lookup_Value, .Map_Find, .Map_Remove,
	     .Map_Find_Or_Insert, .Map_Try_Insert:
		return eval_map_op(ev, v, symbol, self)
	}
	return Eval_Value{}, false
}

@(private = "file")
eval_map_op :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol, self: ^Eval_Value) -> (out: Eval_Value, success: bool) {
	#partial switch symbol.container_op {
	case .Map_Entries, .Map_Keys, .Map_Values:
		eval_fail(ev, v.span, "L0341", "a map view has no compile-time meaning; iterate the map itself")
		return Eval_Value{}, false

	case .Map_Lookup_Value, .Map_Find, .Map_Remove:
		key := eval_expr(ev, v.bound[1]) or_return
		at := map_find(ev, self, key) or_return
		if at < 0 {
			return eval_option(ev, symbol.result, Eval_Value{}, false)
		}
		entry := &self.elements[at + MAP_ENTRY_VALUE]
		#partial switch symbol.container_op {
		case .Map_Find:
			pointer := Eval_Value {
				kind   = .Nil,
				type   = union_variant_payload(ev.k.c, symbol.result, union_index_of(ev.k.c, symbol.result, "some")),
				target = entry,
			}
			return eval_option(ev, symbol.result, pointer, true)
		case .Map_Remove:
			taken := entry^
			eval_splice(ev, self, at, 2) or_return
			return eval_option(ev, symbol.result, taken, true)
		}
		copied := copy_value(ev, entry^) or_return
		return eval_option(ev, symbol.result, copied, true)

	case .Map_Find_Or_Insert, .Map_Try_Insert:
		key := eval_copied(ev, v.bound[1]) or_return
		value := eval_copied(ev, v.bound[2]) or_return
		before := len(self.elements)
		slot := map_entry_place(ev, self, key) or_return
		if symbol.container_op == .Map_Try_Insert {
			slot^ = value
			return eval_alloc_ok(ev, symbol)
		}
		// design.md "Map container operations": `elem` is stored only for a new key.
		if len(self.elements) > before {
			slot^ = value
		}
		return eval_map_slot(ev, symbol, slot)
	}
	return Eval_Value{}, false
}

// An `int` argument, with the negative-count fault the runtime raises.
@(private = "file")
eval_count_argument :: proc(ev: ^Evaluator, v: ^Expr_Call, index: int) -> (out: int, success: bool) {
	value := eval_expr(ev, v.bound[index]) or_return
	number, fits := bi_to_i64(ev.alloc, value.integer)
	if !fits || number < 0 {
		eval_fail(ev, expr_span(v.bound[index]), "L0343", "a container count cannot be negative")
		return 0, false
	}
	return int(number), true
}

// What `append` adds, in written order; a spread adds a copy of each element it
// views (design.md "Variadic parameters").
@(private = "file")
eval_appended :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (out: []Eval_Value, success: bool) {
	added := make([dynamic]Eval_Value, 0, len(v.variadic_elements), ev.alloc)
	if v.variadic_forwards {
		eval_append_spread(ev, &added, v.bound[v.variadic_slot]) or_return
		return added[:], true
	}
	cursor: Call_Pack_Cursor
	for operand, is_spread in call_pack_next(v, &cursor) {
		if is_spread {
			eval_append_spread(ev, &added, operand) or_return
			continue
		}
		copied := eval_copied(ev, operand) or_return
		append(&added, copied)
	}
	return added[:], true
}

@(private = "file")
eval_append_spread :: proc(ev: ^Evaluator, added: ^[dynamic]Eval_Value, spread: Expr) -> bool {
	viewed := eval_expr(ev, spread) or_return
	for element in viewed.elements {
		copied := copy_value(ev, element) or_return
		append(added, copied)
	}
	return true
}

@(private = "file")
eval_void :: proc() -> Eval_Value {
	return Eval_Value{kind = .Invalid, type = TYPE_VOID}
}

// What an operation that might allocate answers when it had nothing to allocate:
// nothing, or `.ok` carrying `Unit` for the `try_` spelling.
@(private = "file")
eval_alloc_ok :: proc(ev: ^Evaluator, symbol: ^Symbol) -> (out: Eval_Value, success: bool) {
	if !container_member_is_try(ev.k.c, symbol) {
		return eval_void(), true
	}
	unit := zero_value(ev, ev.k.c.unit_type) or_return
	return eval_named_union(ev, symbol.result, "ok", unit)
}

// `find_or_insert`'s `^mut V`, wrapped in `.ok` for the `try_` spelling.
@(private = "file")
eval_map_slot :: proc(ev: ^Evaluator, symbol: ^Symbol, slot: ^Eval_Value) -> (Eval_Value, bool) {
	if container_member_is_try(ev.k.c, symbol) {
		payload := union_variant_payload(ev.k.c, symbol.result, union_index_of(ev.k.c, symbol.result, "ok"))
		return eval_named_union(ev, symbol.result, "ok", Eval_Value{kind = .Nil, type = payload, target = slot})
	}
	return Eval_Value{kind = .Nil, type = symbol.result, target = slot}, true
}

// `key in m`, or `x in r` (design.md "Ranges").
@(private = "file")
eval_in :: proc(ev: ^Evaluator, v: ^Expr_Binary) -> (out: Eval_Value, success: bool) {
	// A failing `or_return` in the key leaves before the subject is evaluated.
	key := eval_expr(ev, v.lhs) or_return
	subject := eval_expr(ev, v.rhs) or_return
	present: bool
	if info := type_of(ev.k.c, subject.type); info != nil && info.is_range &&
	   subject.kind == .Aggregate && len(subject.elements) == 3 {
		present = eval_range_contains(ev, subject, key) or_return
	} else {
		at := map_find(ev, &subject, key) or_return
		present = at >= 0
	}
	return Eval_Value{kind = .Boolean, type = TYPE_BOOL, boolean = present}, true
}

@(private = "file")
eval_range_contains :: proc(ev: ^Evaluator, range, key: Eval_Value) -> (out: bool, success: bool) {
	above := eval_compare(ev, .Lt_Eq, range.elements[RANGE_LOW], key) or_return
	below := eval_compare(ev, .Lt, key, range.elements[RANGE_HIGH]) or_return
	at := eval_compare(ev, .Eq_Eq, key, range.elements[RANGE_HIGH]) or_return
	return above && (below || (range.elements[RANGE_CLOSED].boolean && at)), true
}

// The storage an expression denotes, for assignment, `&`, and `inout`.
@(private = "file")
eval_place :: proc(ev: ^Evaluator, e: Expr) -> (out: ^Eval_Value, success: bool) {
	if e == nil {
		return nil, false
	}
	eval_step(ev, expr_span(e)) or_return
	#partial switch v in e {
	case ^Expr_Ident:
		if v.name == "_" {
			return eval_slot(ev, Eval_Value{}) // a discard still needs storage
		}
		if frame := current_frame(ev); frame != nil {
			if slot, ok := frame.locals[v.symbol]; ok {
				return slot, true
			}
		}
		symbol := symbol_of(ev.k.c, v.symbol)
		if symbol != nil && symbol.kind == .Var {
			eval_fail(ev, v.span, "L0341", "`%s` is a mutable variable and cannot be written at compile time", v.name)
			return nil, false
		}
		eval_fail(ev, v.span, "L0341", "`%s` is not compile-time storage", v.name)
		return nil, false

	case ^Expr_Selector:
		base := eval_aggregate_place(ev, v.operand) or_return
		return eval_field(ev, v, base.elements)

	case ^Expr_Call:
		if _, reflected := v.operation.(Call_Reflect); reflected {
			return eval_reflected_field(ev, v)
		}
		target := eval_call_target(ev, v) or_return
		return eval_call_place(ev, target, v.bound, v.span, v.bound_order)

	case ^Expr_Index:
		if v.resolution.kind == .User_Operator {
			return eval_call_place(ev, v.resolution.symbol, v.bound, v.span)
		}
		base := eval_aggregate_place(ev, v.operand) or_return
		// design.md: only `m[key] = elem` inserts (`map_inserts`).
		if type_is_map(ev.k.c, base.type) {
			key := eval_expr(ev, v.indices[0]) or_return
			if !v.map_inserts {
				return eval_map_entry(ev, base, key, v.span)
			}
			key = copy_value(ev, key) or_return
			return map_entry_place(ev, base, key)
		}
		at := eval_index_value(ev, v.indices[0], len(base.elements)) or_return
		return &base.elements[at], true

	case ^Expr_Postfix:
		if v.boxed {
			return eval_box_payload(ev, v.operand, v.span)
		}
		pointer := eval_expr(ev, v.operand) or_return
		return eval_deref(ev, pointer, v.op_span)

	case ^Expr_Composite:
		value := eval_composite(ev, v) or_return
		return eval_slot(ev, value)
	}
	eval_fail(ev, expr_span(e), "L0341", "this expression is not compile-time storage")
	return nil, false
}

// design.md "Slices": a slice views the elements of what it slices, so a write
// through a `[]mut T` reaches the original, and text slices by byte offsets.
@(private = "file")
eval_slice :: proc(ev: ^Evaluator, v: ^Expr_Slice) -> (out: Eval_Value, success: bool) {
	// A user `operator([:])` is called with the arguments the checker bound.
	if v.resolution.kind == .User_Operator {
		return eval_operator_call(ev, v.resolution.symbol, v.bound, v.span)
	}
	operand: Eval_Value
	base := expr_base(v.operand)
	#partial switch underlying_kind(ev.k.c, base.type) {
	case .Array, .Dynamic_Array:
		if base.addressable {
			place := eval_place(ev, v.operand) or_return
			operand = place^
			break
		}
		fallthrough
	case .Slice, .String, .String_View:
		value := eval_expr(ev, v.operand) or_return
		operand = value
	case:
		eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
		return Eval_Value{}, false
	}
	length := operand.kind == .String ? len(operand.text) : len(operand.elements)
	bounds := [2]i64{0, i64(length)}
	for endpoint, index in ([2]Expr{v.lo, v.hi}) {
		if endpoint == nil {
			continue
		}
		value := eval_expr(ev, endpoint) or_return
		fits: bool
		if bounds[index], fits = bi_to_i64(ev.alloc, value.integer); !fits {
			bounds[index] = -1
		}
	}
	low, high := bounds[0], bounds[1]
	if low < 0 || low > high || high > i64(length) {
		eval_fail(ev, v.span, "L0361", "slice bounds %d:%d are out of range for length %d", low, high, length)
		return Eval_Value{}, false
	}
	if operand.kind == .String {
		text := operand.text[low:high]
		// An empty slice still needs its bound at a sequence start or the end.
		split := low < i64(len(operand.text)) && !utf8.rune_start(operand.text[low])
		if split || !utf8.valid_string(text) {
			eval_fail(ev, v.span, "L0343", "string slice bounds split a code point")
			return Eval_Value{}, false
		}
		return Eval_Value{kind = .String, type = v.type, text = text}, true
	}
	return Eval_Value{kind = .Aggregate, type = v.type, elements = operand.elements[low:high]}, true
}

@(private = "file")
eval_deref :: proc(ev: ^Evaluator, pointer: Eval_Value, span: Span) -> (^Eval_Value, bool) {
	if pointer.target == nil {
		eval_fail(ev, span, "L0343", "this dereferences a nil pointer")
		return nil, false
	}
	return pointer.target, true
}

@(private = "file")
eval_field_index :: proc(ev: ^Evaluator, v: ^Expr_Selector, count: int) -> (int, bool) {
	field := symbol_of(ev.k.c, v.resolution.symbol)
	if field == nil || int(field.index) >= count {
		return 0, eval_fail(ev, v.span, "L0341", "`%s` has no compile-time value here", v.name.text)
	}
	return int(field.index), true
}

@(private = "file")
eval_field :: proc(ev: ^Evaluator, v: ^Expr_Selector, elements: []Eval_Value) -> (out: ^Eval_Value, success: bool) {
	at := eval_field_index(ev, v, len(elements)) or_return
	return &elements[at], true
}

// design.md "Compile-time reflection": `field.get(value)` is the reflected field
// of the record `value` points to, and `field.pointer(value)` its address.
@(private = "file")
eval_reflected_field :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (out: ^Eval_Value, success: bool) {
	subject := eval_expr(ev, v.bound[0]) or_return
	record := eval_deref(ev, subject, expr_span(v.bound[0])) or_return
	field := symbol_of(ev.k.c, v.operation.(Call_Reflect).field)
	if field == nil || int(field.index) >= len(record.elements) {
		eval_fail(ev, v.span, "L0341", "this field has no compile-time value here")
		return nil, false
	}
	return &record.elements[field.index], true
}

// The aggregate a selection reads, where `p.f` means `p^.f`.
@(private = "file")
eval_aggregate_value :: proc(ev: ^Evaluator, operand: Expr) -> (out: Eval_Value, success: bool) {
	value := eval_expr(ev, operand) or_return
	if type_is_pointer(ev.k.c, expr_base(operand).type) {
		target := eval_deref(ev, value, expr_span(operand)) or_return
		return target^, true
	}
	return value, true
}

// The storage a selection writes through, where `p.f` means `p^.f`. A slice made on
// the spot still views the storage it was made from.
@(private = "file")
eval_aggregate_place :: proc(ev: ^Evaluator, operand: Expr) -> (out: ^Eval_Value, success: bool) {
	base := expr_base(operand)
	if type_is_pointer(ev.k.c, base.type) {
		pointer := eval_expr(ev, operand) or_return
		return eval_deref(ev, pointer, expr_span(operand))
	}
	if type_is_slice(ev.k.c, base.type) && !base.addressable {
		view := eval_expr(ev, operand) or_return
		return eval_slot(ev, view)
	}
	return eval_place(ev, operand)
}

// A payloadless variant keeps an `Invalid` payload, so every arm has one element.
@(private = "file")
eval_union :: proc(ev: ^Evaluator, type: Type_Id, variant: int, payload: Eval_Value) -> (out: Eval_Value, success: bool) {
	elements := eval_elements(ev, 1) or_return
	elements[0] = payload
	return Eval_Value{kind = .Aggregate, type = type, variant = variant, elements = elements}, true
}

@(private = "file")
eval_named_union :: proc(ev: ^Evaluator, type: Type_Id, name: string, payload: Eval_Value) -> (Eval_Value, bool) {
	return eval_union(ev, type, union_index_of(ev.k.c, type, name), payload)
}

// The fallback is evaluated only on failure, as at run time.
@(private = "file")
eval_or_else :: proc(ev: ^Evaluator, v: ^Expr_Or_Else) -> (out: Eval_Value, success: bool) {
	value := eval_expr(ev, v.value) or_return
	shape, fallible := fallible_of(ev.k.c, expr_base(v.value).type)
	if !fallible {
		eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
		return Eval_Value{}, false
	}
	if value.variant != shape.failure {
		return eval_success_payload(ev, value, shape)
	}
	if v.exit == nil {
		return eval_expr(ev, v.fallback)
	}
	// Every statement evaluated runs in a frame, and only this exit can reach one
	// from a constant initialiser.
	frame := current_frame(ev)
	if frame == nil {
		eval_fail(ev, v.span, "L0341", "this `or_else` has no compile-time target")
		return Eval_Value{}, false
	}
	// design.md "or_else expression": run the exit, then unwind to the
	// enclosing statement as a failing `or_return` does.
	if flow := eval_stmt(ev, v.exit); flow != .Fail {
		frame.exiting = flow
	}
	return Eval_Value{}, false
}

// On failure this returns false without setting `ev.failed`; the statement
// turns that into `.Return`.
@(private = "file")
eval_or_return :: proc(ev: ^Evaluator, v: ^Expr_Postfix) -> (out: Eval_Value, success: bool) {
	value := eval_expr(ev, v.operand) or_return
	shape, fallible := fallible_of(ev.k.c, expr_base(v.operand).type)
	frame := current_frame(ev)
	if !fallible || frame == nil || frame.result_type == INVALID_TYPE {
		eval_fail(ev, v.op_span, "L0341", "this `or_return` has no compile-time target")
		return Eval_Value{}, false
	}
	if value.variant != shape.failure {
		return eval_success_payload(ev, value, shape)
	}
	// design.md "or_return operator": the failure operand runs only here, as an
	// `or_else` exit does.
	if v.failure_exit != nil {
		if v.failure_maps {
			error := copy_value(ev, eval_union_payload(value)) or_return
			if ev.propagated == nil {
				ev.propagated = make(map[^Expr_Postfix]Eval_Value, 4, ev.alloc)
			}
			ev.propagated[v] = error
		}
		if eval_stmt(ev, v.failure_exit) != .Fail {
			frame.exiting = .Return
		}
		return Eval_Value{}, false
	}

	target, target_ok := fallible_of(ev.k.c, frame.result_type)
	if !target_ok {
		eval_fail(ev, v.op_span, "L0341", "this `or_return` has no compile-time target")
		return Eval_Value{}, false
	}
	payload := eval_union_payload(value)
	into := target.failure_type
	if into != TYPE_VOID {
		payload = copy_value(ev, payload) or_return
		if from := shape.failure_type; union_widens_to(ev.k.c, from, into) {
			payload = widen_eval_value(ev.k.c, payload, from, into)
		}
		payload.type = into
	} else {
		payload = Eval_Value{kind = .Invalid, type = TYPE_VOID}
	}
	frame.result = eval_union(ev, frame.result_type, target.failure, payload) or_return
	frame.exiting = .Return
	return Eval_Value{}, false
}

// What a fallible value yields on success: `Unit` when its success is void,
// otherwise the payload.
@(private = "file")
eval_success_payload :: proc(ev: ^Evaluator, value: Eval_Value, shape: Fallible) -> (Eval_Value, bool) {
	if shape.success_type == TYPE_VOID {
		return zero_value(ev, ev.k.c.unit_type)
	}
	return eval_union_payload(value), true
}

// `.some(payload)` or `.none`, for a container read that may find nothing.
@(private = "file")
eval_option :: proc(ev: ^Evaluator, type: Type_Id, payload: Eval_Value, present: bool) -> (Eval_Value, bool) {
	if !present {
		return eval_named_union(ev, type, "none", Eval_Value{})
	}
	return eval_named_union(ev, type, "some", payload)
}

// `argument`, copied, as variant `variant` of `type`.
@(private = "file")
eval_union_of :: proc(ev: ^Evaluator, type: Type_Id, variant: int, argument: Expr) -> (out: Eval_Value, success: bool) {
	payload := eval_copied(ev, argument) or_return
	return eval_union(ev, type, variant, payload)
}

// The payload of `value`, if it has one.
@(private = "file")
eval_union_payload :: proc(value: Eval_Value) -> Eval_Value {
	if len(value.elements) == 0 {
		return value
	}
	return value.elements[0]
}

@(private = "file")
eval_call :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (out: Eval_Value, success: bool) {
	#partial switch operation in v.operation {
	case Call_Enum_From_Int:
		value := eval_expr(ev, v.bound[0]) or_return
		candidate := Const_Value{kind = .Integer, integer = value.integer}
		value.type = operation.type
		return eval_option(ev, v.type, value, enum_member_by_value(ev.k.c, operation.type, candidate) != INVALID_SYMBOL)
	case Call_Box_Unbox:
		return eval_unbox(ev, v.bound[0], v.span)
	case Call_Union_As:
		value := eval_expr(ev, v.bound[0]) or_return
		if value.variant != operation.index {
			return eval_option(ev, v.type, Eval_Value{}, false)
		}
		payload: Eval_Value
		if union_variant_payload(ev.k.c, expr_base(v.bound[0]).type, operation.index) == TYPE_VOID {
			payload = zero_value(ev, ev.k.c.unit_type) or_return
		} else {
			payload = copy_value(ev, value.elements[0]) or_return
		}
		return eval_option(ev, v.type, payload, true)
	case Call_Conversion, Call_Dyn_Conversion:
		return eval_conversion(ev, v)
	case Call_Union_Construct:
		if len(v.bound) != 1 || v.bound[0] == nil {
			eval_fail(ev, v.span, "L0341", "a union construction needs its payload")
			return Eval_Value{}, false
		}
		return eval_union_of(ev, v.type, operation.index, v.bound[0])
	case Call_Text:
		return eval_text_op(ev, v)
	case Call_Reflect:
		field := eval_reflected_field(ev, v) or_return
		if operation.op == .Field_Pointer {
			return Eval_Value{kind = .Nil, type = v.type, target = field}, true
		}
		return field^, true
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Sort_By, Call_Simd_Reduce:
		callee := symbol_of(ev.k.c, v.resolution.symbol)
		if callee != nil && callee.kind == .Builtin { return eval_builtin(ev, v, callee) }
	case nil:
		eval_fail(ev, v.span, "L0341", "an unchecked call has no compile-time meaning")
		return Eval_Value{}, false
	}
	// Compiler-written members run directly.
	if chosen := symbol_of(ev.k.c, v.resolution.chosen_overload); chosen != nil {
		#partial switch chosen.synth {
		case .Standard_Len, .Standard_Cap, .Standard_Hash:
			return eval_standard_customization(ev, v, chosen)
		case .Container_Op:
			return eval_container_op(ev, v, chosen)
		}
	}

	target := eval_call_target(ev, v) or_return
	if sym := symbol_of(ev.k.c, target); sym != nil {
		#partial switch sym.synth {
		// A generated `clone` is the evaluator's own deep copy.
		case .Clone:
			if len(v.bound) >= 1 {
				return eval_copied(ev, v.bound[0])
			}
		// A variant constructor has no body: its payload becomes the variant.
		case .Variant_Construct:
			if len(v.bound) == 1 {
				return eval_union_of(ev, sym.result, union_variant_index(ev.k.c, sym.result, sym.name), v.bound[0])
			}
		}
	}

	result := eval_invoke(ev, target, v.bound, v.span, order = v.bound_order) or_return
	if result.type == INVALID_TYPE {
		return eval_void(), true
	}
	return result, true
}

// design.md "String iteration": the views copy nothing.
@(private = "file")
eval_text_op :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (out: Eval_Value, success: bool) {
	if len(v.bound) == 0 || v.bound[0] == nil {
		eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
		return Eval_Value{}, false
	}
	subject := eval_expr(ev, v.bound[0]) or_return
	#partial switch v.operation.(Call_Text).op {
	case .Byte_Len:
		return eval_count_value(ev, len(subject.text)), true

	case .Rune_Count:
		return eval_count_value(ev, utf8.rune_count_in_string(subject.text)), true

	case .Bytes:
		elements := eval_elements(ev, len(subject.text)) or_return
		for byte_value, index in transmute([]u8)subject.text {
			elements[index] = Eval_Value{
				kind    = .Integer,
				type    = TYPE_U8,
				integer = bi_from_i64(ev.alloc, i64(byte_value)),
			}
		}
		return Eval_Value{kind = .Aggregate, type = v.type, elements = elements}, true

	case .Runes:
		return Eval_Value{kind = .String, type = v.type, text = subject.text}, true
	}
	eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
	return Eval_Value{}, false
}

@(private = "file")
eval_standard_customization :: proc(ev: ^Evaluator, v: ^Expr_Call, chosen: ^Symbol) -> (out: Eval_Value, success: bool) {
	#partial switch chosen.synth {
	case .Standard_Len:
		subject := eval_expr(ev, v.bound[0]) or_return
		count := len(subject.elements)
		if subject.kind == .String {
			count = len(subject.text)
		} else if type_is_map(ev.k.c, subject.type) {
			count /= 2
		}
		return eval_count_value(ev, count), true

	case .Standard_Hash:
		operands: [2]Eval_Value
		eval_operands(ev, v.bound, operands[:]) or_return
		start := eval_wrap_u64(ev, operands[1].integer)
		mixed := eval_hash(ev, operands[0], expr_base(v.bound[0]).type, start, v.span) or_return
		return eval_uint_value(ev, mixed), true
	}
	eval_fail(ev, v.span, "L0595", "`cap` has no compile-time meaning: a capacity is a property of an allocation, and there is none here")
	return Eval_Value{}, false
}

// Operands in order, stopping at the first that fails.
@(private = "file")
eval_operands :: proc(ev: ^Evaluator, bound: []Expr, operands: []Eval_Value) -> bool {
	for &operand, index in operands {
		operand = eval_expr(ev, bound[index]) or_return
	}
	return true
}

@(private = "file")
eval_uint_value :: proc(ev: ^Evaluator, value: u64) -> Eval_Value {
	return Eval_Value{kind = .Integer, type = TYPE_UINT, integer = bi_from_u64(ev.alloc, value)}
}

@(private = "file")
eval_wrap_u64 :: proc(ev: ^Evaluator, integer: Big_Int) -> u64 {
	wrapped, _ := bi_to_u64(ev.alloc, bi_wrap(ev.alloc, integer, 64, false))
	return wrapped
}

// The same mix the backend's `emit_hash_value` makes: a part with its own `==`
// by its own `hash`, a record's fields and an array's elements in order, a
// union's tag and then its payload, and a scalar as `hash_const` does.
@(private = "file")
eval_hash :: proc(ev: ^Evaluator, value: Eval_Value, type: Type_Id, seed: u64, span: Span) -> (out: u64, success: bool) {
	c := ev.k.c
	if own := part_own_hash(c, type); own != INVALID_SYMBOL {
		result := eval_invoke(ev, own, nil, span, []Eval_Value{value, eval_uint_value(ev, seed)}) or_return
		if result.kind != .Integer {
			return 0, false
		}
		return eval_wrap_u64(ev, result.integer), true
	}
	info := underlying_info(c, type)
	if info != nil && value.kind == .Aggregate {
		#partial switch info.kind {
		case .Struct:
			current := seed
			for field, index in info.fields {
				sym := symbol_of(c, field)
				if sym == nil || index >= len(value.elements) {
					return 0, eval_fail(ev, span, "L0341", "this value cannot be hashed at compile time")
				}
				current = eval_hash(ev, value.elements[index], sym.type, current, span) or_return
			}
			return current, true
		case .Array:
			current := seed
			for element in value.elements {
				current = eval_hash(ev, element, info.element, current, span) or_return
			}
			return current, true
		case .Union:
			tagged := hash_mix(seed, u64(value.variant))
			if value.variant < 0 || value.variant >= len(info.variants) {
				return 0, eval_fail(ev, span, "L0341", "this value cannot be hashed at compile time")
			}
			payload := info.variants[value.variant]
			if payload == TYPE_VOID || len(value.elements) == 0 {
				return tagged, true
			}
			return eval_hash(ev, value.elements[0], payload, tagged, span)
		}
	}
	frozen := freeze(ev, value, ev.alloc) or_return
	// design.md "`type` and `typeid`": a `typeid_of(T)` has no number yet.
	if underlying_kind(c, type) == .Typeid {
		if _, known := typeid_const_number(c, frozen); !known {
			return 0, eval_fail(ev, span, "L0341", "`typeid_of` has no number at compile time, so it cannot be hashed there")
		}
	}
	return hash_const(c, frozen, type, seed, ev.alloc), true
}

// Direct and indirect calls alike.
@(private = "file")
eval_call_target :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (out: Symbol_Id, success: bool) {
	if v.resolution.symbol != INVALID_SYMBOL {
		return v.resolution.symbol, true
	}
	value := eval_expr(ev, v.callee) or_return
	if value.proc_value == INVALID_SYMBOL {
		eval_fail(ev, expr_span(v.callee), "L0343", "this calls a nil procedure value")
		return INVALID_SYMBOL, false
	}
	return value.proc_value, true
}

// Hands back the one declared result, or an invalid value when the procedure has
// none.
@(private = "file")
eval_invoke :: proc(
	ev: ^Evaluator, symbol_id: Symbol_Id, args: []Expr, site: Span, values: []Eval_Value = nil, order: []int = nil,
	result_place: ^^Eval_Value = nil,
) -> (out: Eval_Value, success: bool) {
	defer { if !eval_memory_ok(ev) { success = false } }
	// An operator is reached through its resolution, not by name, and a member
	// of an instantiated generic block is checked only after its package, so
	// the body may not have been checked yet.
	if !ensure_proc_typed_for_eval(ev.k, symbol_id) {
		eval_fail(
			ev, site, "L0344", "`%s` cannot be called at compile time: its body is still being checked",
			eval_proc_name(ev.k.c, symbol_id),
		)
		return Eval_Value{}, false
	}
	symbol := symbol_of(ev.k.c, symbol_id)
	literal := eval_proc_literal(symbol)
	if literal == nil || literal.body == nil {
		eval_fail(ev, site, "L0341", "`%s` has no body to evaluate", eval_proc_name(ev.k.c, symbol_id))
		return Eval_Value{}, false
	}
	if len(ev.frames) >= EVAL_MAX_DEPTH {
		eval_fail(ev, site, "L0342", "compile-time evaluation exceeded a call depth of %d", EVAL_MAX_DEPTH)
		return Eval_Value{}, false
	}
	// Its errors are already reported; running it would trip over nodes the
	// checker gave up on.
	if symbol.decl != nil && symbol.decl.check_failed {
		eval_fail(ev, site, "L0344", "`%s` cannot be called at compile time: its body has errors", eval_proc_name(ev.k.c, symbol_id))
		return Eval_Value{}, false
	}

	frame := eval_push_frame(ev, symbol_id, site) or_return
	defer pop(&ev.frames)
	eval_bind_arguments(ev, frame, symbol, args, values, order) or_return

	// Zero until a `return` or `or_return` sets it.
	if symbol.result != INVALID_TYPE {
		eval_hooks_supported(ev, symbol.result, site) or_return
		frame.result = zero_value(ev, symbol.result) or_return
		frame.result_type = symbol.result
	}

	flow := eval_block(ev, literal.body)
	result, place := frame.result, frame.result_place
	eval_release_frame(ev, frame)
	if flow == .Fail {
		return Eval_Value{}, false
	}
	if result_place != nil {
		result_place^ = place
	}
	return result, true
}

@(private = "file")
eval_push_frame :: proc(ev: ^Evaluator, symbol: Symbol_Id, site: Span) -> (^Eval_Frame, bool) {
	frame := new(Eval_Frame, ev.alloc)
	if frame == nil { return nil, false }
	frame.symbol = symbol
	frame.site = site
	frame.locals = make(map[Symbol_Id]^Eval_Value, 8, ev.alloc)
	frame.defers = make([dynamic]^Stmt_Defer, 0, 4, ev.alloc)
	if !eval_memory_ok(ev) { return nil, false }
	append(&ev.frames, frame)
	return frame, eval_memory_ok(ev)
}

// A default runs in the callee's frame, since it may name an earlier parameter; a
// written argument runs in the caller's. design.md "Evaluation order": `order` is
// the schedule when named arguments reorder it.
@(private = "file")
eval_bind_arguments :: proc(ev: ^Evaluator, frame: ^Eval_Frame, symbol: ^Symbol, args: []Expr, values: []Eval_Value, order: []int) -> bool {
	for step in 0 ..< max(len(args), len(values)) {
		index := step
		if step < len(order) {
			index = order[step]
		}
		if index >= len(symbol.param_symbols) {
			continue
		}
		argument := index < len(args) ? args[index] : Expr(nil)
		is_default := argument != nil && symbol.param_defaults != nil && index < len(symbol.param_defaults) &&
			argument == symbol.param_defaults[index]

		if !is_default {
			pop(&ev.frames)
		}
		slot, ok := eval_argument_slot(ev, symbol, index, argument, values)
		if !is_default {
			append(&ev.frames, frame)
		}
		if !ok {
			return false
		}
		if binding := symbol.param_symbols[index]; binding != INVALID_SYMBOL {
			frame.locals[binding] = slot
		}
	}
	return true
}

@(private = "file")
eval_argument_slot :: proc(ev: ^Evaluator, symbol: ^Symbol, index: int, argument: Expr, values: []Eval_Value) -> (out: ^Eval_Value, success: bool) {
	info := type_of(ev.k.c, symbol.proc_type)
	mode := info != nil && index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
	slot: ^Eval_Value
	if values != nil {
		copied := copy_value(ev, values[index]) or_return
		slot = eval_slot(ev, copied) or_return
	} else if mode == .Inout || (mode == .Borrow && argument != nil && expr_base(argument).addressable) {
		slot = eval_place(ev, argument) or_return
	} else {
		copied := eval_copied(ev, argument) or_return
		slot = eval_slot(ev, copied) or_return
	}
	// `self: ^Self` binds a pointer to the receiver.
	if bound := symbol_of(ev.k.c, symbol.param_symbols[index]); mode == .Borrow && bound != nil && bound.type != symbol.params[index] {
		return eval_slot(ev, Eval_Value{kind = .Nil, type = bound.type, target = slot})
	}
	return slot, true
}

// A returned frame's table, `defer` list, and record are the evaluator's own,
// which nothing else points at. Its slots stay: a value may still point at one.
@(private = "file")
eval_release_frame :: proc(ev: ^Evaluator, frame: ^Eval_Frame) {
	delete(frame.locals)
	delete(frame.defers)
	free(frame, ev.alloc)
}

// design.md "Delegating operators": a forwarding overload calls what it
// forwards to, and one with no overload behind it applies the underlying type's
// built-in operation, as `emit_delegated` does. `values`, when given, are the
// operands already evaluated.
@(private = "file")
eval_operator_call :: proc(
	ev: ^Evaluator, symbol_id: Symbol_Id, args: []Expr, site: Span, values: []Eval_Value = nil,
) -> (out: Eval_Value, success: bool) {
	symbol := symbol_of(ev.k.c, symbol_id)
	if symbol == nil || !symbol.delegated {
		return eval_invoke(ev, symbol_id, args, site, values)
	}
	if symbol.delegate_target != INVALID_SYMBOL {
		return eval_operator_call(ev, symbol.delegate_target, args, site, values)
	}
	operands: [2]Eval_Value
	count := min(max(len(args), len(values)), len(operands))
	for index in 0 ..< count {
		if index < len(values) {
			operands[index] = values[index]
			continue
		}
		operand := eval_expr(ev, args[index]) or_return
		operands[index] = operand
	}
	op := operator_token(symbol.operator)
	if type_is_simd(ev.k.c, symbol.delegate_underlying) {
		if count == 1 {
			return eval_simd_unary(ev, op, site, symbol.result, operands[0])
		}
		return eval_simd_binary_values(ev, op, site, symbol.result, operands[0], operands[1])
	}
	if count == 1 {
		applied := eval_unary_value(ev, op, site, const_of(operands[0]), symbol.delegate_underlying) or_return
		return scalar(const_of(applied), symbol.result), true
	}
	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		result := eval_compare_at(ev, op, operands[0], operands[1], site) or_return
		return scalar(bool_const(result), symbol.result), true
	}
	folded, ok := fold_arithmetic(
		ev.k.c, op, site, const_of(operands[0]), const_of(operands[1]), symbol.delegate_underlying, ev.alloc,
	)
	if !ok {
		eval_fold_failed(ev)
		return Eval_Value{}, false
	}
	return scalar(folded, symbol.result), true
}

// design.md "`inout` results": a call returning `inout T` is a place, the
// storage its `return inout` named.
@(private = "file")
eval_call_place :: proc(ev: ^Evaluator, target: Symbol_Id, args: []Expr, site: Span, order: []int = nil) -> (out: ^Eval_Value, success: bool) {
	if symbol := symbol_of(ev.k.c, target); symbol == nil || !symbol.result_inout {
		eval_fail(ev, site, "L0341", "this expression is not compile-time storage")
		return nil, false
	}
	place: ^Eval_Value
	eval_invoke(ev, target, args, site, order = order, result_place = &place) or_return
	if place == nil {
		eval_fail(ev, site, "L0341", "this call returned no storage")
		return nil, false
	}
	return place, true
}

@(private = "file")
eval_proc_literal :: proc(symbol: ^Symbol) -> ^Expr_Proc {
	if symbol.decl != nil {
		return decl_proc_literal(symbol.decl)
	}
	return symbol.proc_literal
}

@(private = "file")
eval_conversion :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (out: Eval_Value, success: bool) {
	source := eval_expr(ev, v.bound[0]) or_return
	c := ev.k.c
	// A distinct type and what it wraps share a representation.
	if type_underlying(c, expr_base(v.bound[0]).type) == type_underlying(c, v.type) {
		retyped := source
		retyped.type = v.type
		return retyped, true
	}
	if from := expr_base(v.bound[0]).type; union_widens_to(c, from, v.type) {
		return widen_eval_value(c, source, from, v.type), true
	}
	if source.target != nil || source.proc_value != INVALID_SYMBOL {
		if type_is_pointer(c, v.type) {
			retyped := source
			retyped.type = v.type
			return retyped, true
		}
		eval_fail(ev, v.span, "L0341", "a pointer's address cannot be observed at compile time")
		return Eval_Value{}, false
	}
	// An aggregate is frozen so the shared conversion sees its lanes.
	operand := const_of(source)
	if source.kind == .Aggregate {
		frozen := freeze(ev, source, ev.alloc) or_return
		operand = frozen
	}
	converted, fits := convert_const(c, operand, v.type, true, ev.alloc)
	if !fits && (operand.kind == .Integer || operand.kind == .Rune) && (type_is_integer(c, v.type) || type_is_rune(c, v.type)) {
		// design.md "Type conversion": where a run would panic.
		eval_fail(
			ev, v.span, "L0712", "the value %s does not fit `%s`; `math.wrap` keeps its low bits",
			bi_text(ev.alloc, operand.integer), type_name(c, v.type),
		)
		return Eval_Value{}, false
	}
	if !fits {
		eval_fail(ev, v.span, "L0341", "this conversion has no compile-time value")
		return Eval_Value{}, false
	}
	if converted.kind == .Aggregate {
		return value_from_const(ev, converted, v.type)
	}
	return scalar(converted, v.type), true
}

@(private = "file")
eval_builtin :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol) -> (out: Eval_Value, success: bool) {
	#partial switch symbol.builtin {
	case .Assert:
		condition := eval_expr(ev, v.bound[0]) or_return
		if condition.boolean {
			return eval_void(), true
		}
		eval_fail(ev, v.span, "L0343", "compile-time assertion failed%s", eval_message(ev, v, 1))
		return Eval_Value{}, false

	case .Panic:
		eval_fail(ev, v.span, "L0343", "compile-time panic%s", eval_message(ev, v, 0))
		return Eval_Value{}, false

	case .Drop:
		// Nothing to release here; only the zero write applies.
		slot := eval_place(ev, v.bound[0]) or_return
		slot^ = zero_value(ev, slot.type) or_return
		return eval_void(), true

	case .Box_New, .Try_Box:
		// design.md "Owned values": a box is one value held apart, so the
		// evaluator keeps it as a one-element aggregate with value semantics.
		payload := eval_expr(ev, v.bound[0]) or_return
		if expression_is_borrowed_place(v.bound[0]) {
			payload = copy_value(ev, payload) or_return
		}
		// The allocator argument runs for its effects; the evaluator's box holds
		// no storage of its own to take from it.
		if len(v.bound) > 1 && v.bound[1] != nil {
			eval_expr(ev, v.bound[1]) or_return
		}
		elements := eval_elements(ev, 1) or_return
		elements[0] = payload
		checked := v.operation.(Call_Allocation)
		boxed := Eval_Value{kind = .Aggregate, type = box_of(ev.k.c, checked.type), elements = elements}
		if checked.fallible {
			return eval_named_union(ev, v.type, "ok", boxed)
		}
		return boxed, true

	case .Unsafe_Take, .Unsafe_Write, .Unsafe_Forget, .Unsafe_Transmute:
		return eval_unsafe_builtin(ev, v, symbol)

	case .Math_Wrap, .Math_Fma_Available, .Math_Fma_Instruction, .Math_Sqrt_Instruction,
	     .Math_Floor_Instruction, .Math_Ceil_Instruction, .Math_Trunc_Instruction, .Math_Round_Instruction,
	     .Math_Mod_Instruction, .Math_Rotate_Left, .Math_Rotate_Right,
	     .Math_Count_Ones, .Math_Leading_Zeros, .Math_Trailing_Zeros, .Math_Bit_Width,
	     .Math_Reverse_Bits, .Math_Is_Power_Of_Two, .Math_Next_Power_Of_Two, .Math_Checked_Next_Power_Of_Two:
		return eval_math_builtin(ev, v, symbol)

	case .Simd_Cast, .Simd_Select, .Simd_Reduce:
		return eval_simd_builtin(ev, v, symbol)
	}
	eval_fail(ev, v.span, "L0341", "`%s` has no compile-time meaning", identifier_text(ev.k.c, symbol.name))
	return Eval_Value{}, false
}

@(private = "file")
eval_unsafe_builtin :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol) -> (out: Eval_Value, success: bool) {
	#partial switch symbol.builtin {
	case .Unsafe_Take:
		place := eval_place(ev, v.bound[0]) or_return
		value := place^
		place^ = Eval_Value{kind = .Invalid, type = value.type}
		return value, true

	case .Unsafe_Write:
		place := eval_place(ev, v.bound[0]) or_return
		value := eval_expr(ev, v.bound[1]) or_return
		if expression_is_borrowed_place(v.bound[1]) {
			value = copy_value(ev, value) or_return
		}
		value.type = place.type
		place^ = value
		return eval_void(), true

	case .Unsafe_Forget:
		// No hook runs; a moved slot is left inert.
		eval_expr(ev, v.bound[0]) or_return
		return eval_void(), true
	}

	// `.Unsafe_Transmute`: the checker's fold, for an operand that is a local.
	operand := eval_expr(ev, v.bound[0]) or_return
	frozen := freeze(ev, operand, ev.alloc) or_return
	source := expr_base(v.bound[0]).type
	result, status := transmute_const(ev.k.c, frozen, source, v.type, ev.alloc)
	defer {
		eval_release_tables(ev, frozen)
		eval_release_tables(ev, result)
	}
	switch status {
	case .Folded:
		return value_from_const(ev, result, v.type)
	case .Invalid:
		eval_fail(
			ev, v.span, "L0688",
			"this bit pattern is not a valid `%s`", type_name(ev.k.c, v.type),
		)
	case .Padding:
		eval_fail(
			ev, v.span, "L0688",
			"`unsafe.transmute` reads the padding of `%s` into `%s`, and padding has no compile-time value",
			type_name(ev.k.c, source), type_name(ev.k.c, v.type),
		)
	case .Unfoldable:
		eval_fail(
			ev, v.span, "L0688",
			"`unsafe.transmute` has no compile-time meaning from `%s` to `%s`",
			type_name(ev.k.c, source), type_name(ev.k.c, v.type),
		)
	}
	return Eval_Value{}, false
}

@(private = "file")
eval_math_builtin :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol) -> (out: Eval_Value, success: bool) {
	#partial switch symbol.builtin {
	case .Math_Wrap:
		operand := eval_expr(ev, v.bound[0]) or_return
		// design.md "Type conversion": a vector wraps lane by lane.
		if info := underlying_info(ev.k.c, v.type); info != nil && info.kind == .Simd {
			elements := eval_elements(ev, int(info.count)) or_return
			for index in 0 ..< int(info.count) {
				lane := const_of(eval_simd_lane(operand, index))
				lane.integer = wrap_to_type(ev.k.c, lane.integer, info.element, ev.alloc)
				elements[index] = scalar(lane, info.element)
			}
			return Eval_Value{kind = .Aggregate, type = v.type, elements = elements}, true
		}
		if operand.kind != .Integer && operand.kind != .Rune {
			eval_fail(ev, v.span, "L0341", "this conversion has no compile-time value")
			return Eval_Value{}, false
		}
		wrapped := const_of(operand)
		wrapped.kind = type_is_rune(ev.k.c, v.type) ? .Rune : .Integer
		wrapped.integer = wrap_to_type(ev.k.c, wrapped.integer, v.type, ev.alloc)
		return scalar(wrapped, v.type), true

	// A compile-time value is the build's: no copy of a procedure for another
	// level is evaluated (design.md "@(cpu_dispatch=<string>)").
	case .Math_Fma_Available:
		return scalar(bool_const(cpu_has_fma(ev.k.c.target.cpu)), TYPE_BOOL), true

	// Rounded once from the exact value, as the instruction does, rather than
	// by the host's arithmetic or its C library.
	case .Math_Fma_Instruction:
		operands: [3]Eval_Value
		eval_operands(ev, v.bound, operands[:]) or_return
		bits := operands[0].float_bits
		fused := exact_fma(ev.alloc, operands[0].float, operands[1].float, operands[2].float, bits)
		return scalar(float_const(fused, bits), v.type), true

	case .Math_Sqrt_Instruction:
		operand := eval_expr(ev, v.bound[0]) or_return
		return scalar(exact_sqrt(const_of(operand)), v.type), true

	case .Math_Floor_Instruction, .Math_Ceil_Instruction, .Math_Trunc_Instruction, .Math_Round_Instruction:
		operand := eval_expr(ev, v.bound[0]) or_return
		return scalar(exact_integral(const_of(operand), symbol.builtin), v.type), true

	case .Math_Mod_Instruction:
		operands: [2]Eval_Value
		eval_operands(ev, v.bound, operands[:]) or_return
		return scalar(exact_mod(const_of(operands[0]), const_of(operands[1])), v.type), true

	case .Math_Rotate_Left, .Math_Rotate_Right:
		operands: [2]Eval_Value
		eval_operands(ev, v.bound, operands[:]) or_return
		rotated := rotate_const(ev.k.c, operands[0].integer, operands[1].integer, v.type, symbol.builtin, ev.alloc)
		return scalar(integer_const(rotated), v.type), true

	case .Math_Count_Ones, .Math_Leading_Zeros, .Math_Trailing_Zeros, .Math_Bit_Width:
		operand := eval_expr(ev, v.bound[0]) or_return
		source := expr_base(v.bound[0]).type
		count := bit_count(operand.integer, type_bits(ev.k.c, source), symbol.builtin)
		return scalar(integer_const(bi_from_i64(ev.alloc, i64(count))), TYPE_INT), true
	}

	// design.md "Integer overflow": a `next_power_of_two` that would panic at
	// run time is a compile-time diagnostic, as a checked `+` is, and the
	// checked form's `.none`.
	operand := eval_expr(ev, v.bound[0]) or_return
	source := expr_base(v.bound[0]).type
	if symbol.builtin == .Math_Checked_Next_Power_Of_Two {
		power, fits := bit_value_const(ev.k.c, operand.integer, source, .Math_Next_Power_Of_Two, ev.alloc)
		return eval_option(ev, v.type, scalar(power, source), fits)
	}
	result, fits := bit_value_const(ev.k.c, operand.integer, source, symbol.builtin, ev.alloc)
	if !fits {
		report_integer_overflow(ev.k.c, v.span, result.integer, source, ev.alloc)
		eval_fold_failed(ev)
		return Eval_Value{}, false
	}
	return scalar(result, v.type), true
}

@(private = "file")
eval_simd_builtin :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol) -> (out: Eval_Value, success: bool) {
	#partial switch symbol.builtin {
	// standard-library.md "`core:simd`": a vector and its array have the same lanes in the
	// same order, so the conversion only retypes them.
	case .Simd_Cast:
		out = eval_copied(ev, v.bound[0]) or_return
		out.type = v.type
		return out, true

	case .Simd_Select:
		operands: [3]Eval_Value
		eval_operands(ev, v.bound, operands[:]) or_return
		count := int(underlying_info(ev.k.c, v.type).count)
		elements := eval_elements(ev, count) or_return
		for index in 0 ..< count {
			chosen := operands[1] if eval_simd_lane(operands[0], index).boolean else operands[2]
			elements[index] = eval_simd_lane(chosen, index)
		}
		return Eval_Value{kind = .Aggregate, type = v.type, elements = elements}, true
	}
	return eval_simd_reduce(ev, v)
}

// The constant message of `assert`/`panic` and its arguments; a non-scalar prints
// as `<value>`.
@(private = "file")
eval_message :: proc(ev: ^Evaluator, v: ^Expr_Call, index: int) -> string {
	if index >= len(v.bound) || v.bound[index] == nil {
		return ""
	}
	base := expr_base(v.bound[index])
	if base == nil || base.const_value.kind != .String {
		return ""
	}
	b := strings.builder_make(ev.k.c.semantic_allocator)
	strings.write_string(&b, ": ")
	strings.write_string(&b, base.const_value.text)
	for arg in v.bound[index + 1:] {
		text := "<value>"
		if value, ok := eval_expr(ev, arg); ok {
			text = const_display_text(ev.k.c, const_of(value))
		}
		strings.write_byte(&b, ' ')
		strings.write_string(&b, text)
	}
	return strings.to_string(b)
}

@(private = "file")
eval_block :: proc(ev: ^Evaluator, b: ^Block) -> Eval_Flow {
	return b == nil ? .Normal : eval_stmts(ev, b.stmts, true)
}

// Runs `stmts` until one leaves; a scope then runs the `defer`s it registered,
// in reverse.
@(private = "file")
eval_stmts :: proc(ev: ^Evaluator, stmts: []Stmt, scope: bool) -> Eval_Flow {
	frame := current_frame(ev)
	mark := len(frame.defers)
	flow := Eval_Flow.Normal
	for stmt in stmts {
		flow = eval_stmt(ev, stmt)
		if flow != .Normal {
			break
		}
	}
	if scope {
		flow = run_defers(ev, frame, mark, flow)
	}
	return flow
}

// An `errdefer` runs only when the scope is left by returning the failure
// variant (design.md "defer statement").
@(private = "file")
run_defers :: proc(ev: ^Evaluator, frame: ^Eval_Frame, mark: int, flow: Eval_Flow) -> Eval_Flow {
	result := flow
	failing := false
	if flow == .Return && frame.result_type != INVALID_TYPE {
		if shape, fallible := fallible_of(ev.k.c, frame.result_type); fallible {
			failing = frame.result.variant == shape.failure
		}
	}
	for index := len(frame.defers) - 1; index >= mark; index -= 1 {
		deferred := frame.defers[index]
		if deferred.on_failure && !failing {
			continue
		}
		if eval_stmt(ev, deferred.stmt) == .Fail {
			result = .Fail
		}
	}
	resize(&frame.defers, mark)
	return result
}

@(private = "file")
eval_stmt :: proc(ev: ^Evaluator, stmt: Stmt) -> Eval_Flow {
	result := eval_stmt_inner(ev, stmt)
	if !eval_memory_ok(ev) {
		return .Fail
	}
	// The signal of an `or_return` or an `or_else` exit is spent here, so a later
	// failure is not one (design.md "or_else expression").
	if frame := current_frame(ev); result == .Fail && frame.exiting != .Normal && !ev.failed {
		flow := frame.exiting
		frame.exiting = .Normal
		return flow
	}
	return result
}

@(private = "file")
eval_stmt_inner :: proc(ev: ^Evaluator, stmt: Stmt) -> Eval_Flow {
	if !eval_step(ev, stmt_span(stmt)) {
		return .Fail
	}
	switch s in stmt {
	case ^Stmt_Error:
		return .Normal

	case ^Item_Impl:
		return .Normal

	case ^Decl:
		return eval_local_decl(ev, s)

	case ^Stmt_Expr:
		for expr in s.exprs {
			if _, ok := eval_expr(ev, expr); !ok {
				return .Fail
			}
		}
		return .Normal

	case ^Stmt_Assign:
		return eval_assign(ev, s)

	case ^Stmt_If:
		if s.init != nil {
			if flow := eval_stmt(ev, s.init); flow != .Normal {
				return flow
			}
		}
		cond, ok := eval_expr(ev, s.cond)
		if !ok {
			return .Fail
		}
		if cond.boolean {
			return eval_block(ev, s.then)
		}
		if s.otherwise != nil {
			return eval_stmt(ev, s.otherwise)
		}
		return .Normal

	case ^Stmt_For:
		return eval_for(ev, s)

	case ^Stmt_Switch:
		return eval_switch(ev, s)

	case ^Stmt_Defer:
		append(&current_frame(ev).defers, s)
		return .Normal

	case ^Stmt_Return:
		return eval_return(ev, s)

	case ^Stmt_Branch:
		return s.kind == .Break ? .Break : .Continue

	case ^Block:
		return eval_block(ev, s)

	case ^Stmt_When:
		// Not a scope: its `defer`s belong to the surrounding one.
		return s.selected == nil ? .Normal : eval_stmts(ev, s.selected.stmts, false)

	case ^Stmt_Foreach:
		return eval_foreach(ev, s)

	case ^Stmt_Parallel:
		// design.md "Parallel blocks": running the tasks serially would
		// not be a faithful substitute.
		eval_fail(ev, s.keyword, "L0341", "a `parallel` block cannot run during compile-time evaluation")
		return .Fail

	case ^Stmt_Spawn:
	}
	eval_fail(ev, stmt_span(stmt), "L0341", "this statement has no compile-time meaning")
	return .Fail
}

@(private = "file")
eval_local_decl :: proc(ev: ^Evaluator, d: ^Decl) -> Eval_Flow {
	frame := current_frame(ev)
	// design.md "Storage modifiers": the storage persists between calls, so it
	// is runtime state that evaluation can neither read nor modify.
	if d.duration != .None {
		eval_fail(
			ev, d.span, "L0341", "a `%s` local has no compile-time meaning",
			d.duration == .Static ? "static" : "thread_local",
		)
		return .Fail
	}
	if d.destructure.active {
		values, ok := eval_destructure(ev, &d.destructure, d.values[0])
		if !ok {
			return .Fail
		}
		for symbol_id, index in d.symbols {
			if !eval_bind_local(ev, frame, symbol_id, values[index]) {
				return .Fail
			}
		}
		return .Normal
	}
	for symbol_id, index in d.symbols {
		symbol := symbol_of(ev.k.c, symbol_id)
		// A body-local type holds no value.
		if symbol != nil && symbol.kind == .Type {
			continue
		}
		// Only a declaration without an initializer needs its type's zero; an
		// unfixed constant such as `N :: 3` has none, and `_: T` binds nothing.
		value: Eval_Value
		ok: bool
		if index < len(d.values) && d.values[index] != nil {
			value, ok = eval_copied(ev, d.values[index])
		} else if symbol == nil {
			continue
		} else {
			ok = eval_hooks_supported(ev, symbol.type, d.span)
			if ok {
				value, ok = zero_value(ev, symbol.type)
			}
		}
		if !ok || !eval_bind_local(ev, frame, symbol_id, value) {
			return .Fail
		}
	}
	return .Normal
}

@(private = "file")
eval_bind_local :: proc(ev: ^Evaluator, frame: ^Eval_Frame, symbol_id: Symbol_Id, value: Eval_Value) -> bool {
	if symbol_id == INVALID_SYMBOL {
		return true
	}
	// A fresh slot per declaration, so each loop iteration has its own.
	slot, ok := eval_slot(ev, value)
	if !ok {
		return false
	}
	frame.locals[symbol_id] = slot
	return true
}

// design.md "Destructuring": one evaluation; fields of a place are copied.
@(private = "file")
eval_destructure :: proc(ev: ^Evaluator, plan: ^Destructure, operand: Expr) -> (out: []Eval_Value, success: bool) {
	record := eval_expr(ev, operand) or_return
	if record.kind != .Aggregate || len(record.elements) < len(plan.fields) {
		eval_fail(ev, expr_span(operand), "L0341", "this value has no compile-time fields to destructure")
		return nil, false
	}
	values, err := make([]Eval_Value, len(plan.fields), ev.alloc)
	if err != nil {
		return nil, false
	}
	for index in 0 ..< len(plan.fields) {
		if index < len(plan.retained) && !plan.retained[index] {
			continue
		}
		// A padding field fills no binding, so the field's own slot is read.
		slot := int(symbol_of(ev.k.c, plan.fields[index]).index)
		if !plan.from_place {
			values[index] = record.elements[slot]
			continue
		}
		copied := copy_value(ev, record.elements[slot]) or_return
		values[index] = copied
	}
	return values, true
}

@(private = "file")
eval_assign :: proc(ev: ^Evaluator, s: ^Stmt_Assign) -> Eval_Flow {
	if s.lowered != nil {
		return eval_block(ev, s.lowered)
	}
	// design.md "Indexing and slicing": `grid[x, y] = v` calls `operator([]=)`
	// with the arguments the checker bound.
	if s.place_setter != INVALID_SYMBOL {
		_, ok := eval_operator_call(ev, s.place_setter, s.setter_bound, s.op_span)
		return ok ? .Normal : .Fail
	}
	if s.op != .Assign {
		return eval_compound_assign(ev, s)
	}
	if s.destructure.active {
		values, ok := eval_destructure(ev, &s.destructure, s.rhs[0])
		if !ok {
			return .Fail
		}
		defer delete(values, ev.alloc)
		// design.md "Destructuring": a narrower union widens to its destination's.
		for target, index in s.lhs {
			from, to := symbol_of(ev.k.c, s.destructure.fields[index]).type, expr_base(target).type
			if !is_discard(target) && union_widens_to(ev.k.c, from, to) {
				values[index] = widen_eval_value(ev.k.c, values[index], from, to)
			}
		}
		return eval_write_targets(ev, s.lhs, values)
	}
	// The array is scratch: each write copies a value out.
	values, value_err := make([]Eval_Value, len(s.rhs), ev.alloc)
	if value_err != nil { return .Fail }
	defer delete(values, ev.alloc)
	for value, index in s.rhs {
		copied, ok := eval_copied(ev, value)
		if !ok {
			return .Fail
		}
		values[index] = copied
	}
	return eval_write_targets(ev, s.lhs, values)
}

// design.md "Assignment statements": values, then destinations, then writes.
@(private = "file")
eval_write_targets :: proc(ev: ^Evaluator, targets: []Expr, values: []Eval_Value) -> Eval_Flow {
	destinations, err := make([]Eval_Destination, len(targets), ev.alloc)
	if err != nil { return .Fail }
	defer delete(destinations, ev.alloc)
	for target, index in targets {
		destination, ok := eval_destination(ev, target)
		if !ok {
			return .Fail
		}
		destinations[index] = destination
	}
	for destination, index in destinations {
		slot, ok := destination_slot(ev, destination)
		if !ok {
			return .Fail
		}
		retyped := values[index]
		retyped.type = slot.type != INVALID_TYPE ? slot.type : retyped.type
		slot^ = retyped
	}
	return .Normal
}

// A prepared assignment destination. `m[key] = elem` keeps its map and key and
// inserts in the write phase, as at run time, so the insertion cannot move an
// entry that another destination already names.
@(private = "file")
Eval_Destination :: struct {
	slot:   ^Eval_Value,
	map_of: ^Eval_Value,
	key:    Eval_Value,
}

@(private = "file")
eval_destination :: proc(ev: ^Evaluator, target: Expr) -> (out: Eval_Destination, success: bool) {
	if index, is_index := target.(^Expr_Index); is_index && index.map_inserts {
		base := eval_aggregate_place(ev, index.operand) or_return
		if type_is_map(ev.k.c, base.type) {
			key := eval_copied(ev, index.indices[0]) or_return
			return Eval_Destination{map_of = base, key = key}, true
		}
	}
	slot := eval_place(ev, target) or_return
	return Eval_Destination{slot = slot}, true
}

@(private = "file")
destination_slot :: proc(ev: ^Evaluator, destination: Eval_Destination) -> (^Eval_Value, bool) {
	if destination.map_of != nil {
		return map_entry_place(ev, destination.map_of, destination.key)
	}
	return destination.slot, true
}

@(private = "file")
eval_compound_assign :: proc(ev: ^Evaluator, s: ^Stmt_Assign) -> Eval_Flow {
	// A direct user `+=` writes through its `inout` destination.
	if s.operator != INVALID_SYMBOL && s.operator_direct {
		operands := [2]Expr{s.lhs[0], s.rhs[0]}
		_, ok := eval_operator_call(ev, s.operator, operands[:], s.op_span)
		return ok ? .Normal : .Fail
	}
	slot, ok := eval_place(ev, s.lhs[0])
	if !ok {
		return .Fail
	}
	operand, operand_ok := eval_expr(ev, s.rhs[0])
	if !operand_ok {
		return .Fail
	}
	// The user `+` it falls back to, its destination evaluated once, then a
	// replacing write.
	if s.operator != INVALID_SYMBOL {
		result, called := eval_operator_call(ev, s.operator, nil, s.op_span, []Eval_Value{slot^, operand})
		if !called {
			return .Fail
		}
		slot^ = result
		return .Normal
	}
	op := compound_operator(s.op)
	type := slot.type
	// design.md "Evaluation order": the destination is read after the right operand.
	// SIMD folds lane-wise, since `const_of` carries no lanes.
	if type_is_simd(ev.k.c, type) {
		result, lanes_ok := eval_simd_binary_values(ev, op, s.op_span, type, slot^, operand)
		if !lanes_ok {
			return .Fail
		}
		slot^ = result
		return .Normal
	}
	folded, folded_ok := fold_arithmetic(ev.k.c, op, s.op_span, const_of(slot^), const_of(operand), type, ev.alloc)
	if !folded_ok {
		eval_fold_failed(ev)
		return .Fail
	}
	slot^ = scalar(folded, type)
	return .Normal
}

@(private = "file")
eval_for :: proc(ev: ^Evaluator, s: ^Stmt_For) -> Eval_Flow {
	if s.init != nil {
		if flow := eval_stmt(ev, s.init); flow != .Normal {
			return flow
		}
	}
	for {
		if !eval_step(ev, s.span) {
			return .Fail
		}
		if s.cond != nil {
			cond, ok := eval_expr(ev, s.cond)
			if !ok {
				return .Fail
			}
			if !cond.boolean {
				return .Normal
			}
		}
		flow := eval_block(ev, s.body)
		#partial switch flow {
		case .Fail, .Return:
			return flow
		case .Break:
			return .Normal
		}
		if s.post != nil {
			// An `or_return` in the post statement leaves the loop too.
			if post := eval_stmt(ev, s.post); post != .Normal {
				return post
			}
		}
	}
}

// design.md "foreach statement": a range walks its endpoints; other kinds
// already hold their elements.
@(private = "file")
eval_foreach :: proc(ev: ^Evaluator, s: ^Stmt_Foreach) -> Eval_Flow {
	#partial switch s.kind {
	case .Static:
		// The checked copies run in order.
		for copy_block in s.expansion {
			if flow := eval_block(ev, copy_block); flow != .Normal {
				return flow
			}
		}
		return .Normal

	case .Range, .Stored_Range:
		return eval_range_foreach(ev, s)

	case .Array, .Slice, .Dynamic:
		// A `&mut` loop needs the container's own storage, and so does a
		// borrowed binding over a place (design.md "Borrowing iteration"). A
		// slice is a view of that storage, whichever expression made it.
		if s.kind != .Slice && (foreach_is_place_loop(s) || s.borrows && eval_frame_place(ev, s.iterable)) {
			container, ok := eval_place(ev, s.iterable)
			if !ok {
				return .Fail
			}
			return eval_sequence_foreach(ev, s, container.elements)
		}
		container, ok := eval_expr(ev, s.iterable)
		if !ok {
			return .Fail
		}
		return eval_sequence_foreach(ev, s, container.elements)

	case .Text:
		return eval_text_foreach(ev, s)

	case .Map:
		// design.md "Maps": the order is unspecified.
		eval_fail(
			ev, s.span, "L0593",
			"a map cannot be iterated at compile time: its iteration order is unspecified",
		)
		return .Fail

	case .Protocol:
		eval_fail(ev, s.span, "L0341", "a user iterator has no compile-time meaning yet")
		return .Fail
	}
	eval_fail(ev, s.span, "L0341", "this `foreach` has no compile-time meaning")
	return .Fail
}

// Counts out from the low end, so `..= max` needs no `max + 1`. `reversed()`
// mirrors the value; `indexed()` still counts up (design.md "Reverse iteration").
@(private = "file")
eval_range_foreach :: proc(ev: ^Evaluator, s: ^Stmt_Foreach) -> Eval_Flow {
	lo, hi: Eval_Value
	closed := false
	if written, is_range := s.iterable.(^Expr_Range); is_range {
		low, low_ok := eval_expr(ev, written.lo)
		if !low_ok { return .Fail }
		high, high_ok := eval_expr(ev, written.hi)
		if !high_ok { return .Fail }
		lo, hi = low, high
		closed = written.op == .Range_Incl
	} else {
		stored, ok := eval_expr(ev, s.iterable)
		if !ok { return .Fail }
		if stored.kind != .Aggregate || len(stored.elements) <= RANGE_CLOSED || stored.elements[RANGE_CLOSED].kind != .Boolean {
			eval_fail(ev, expr_span(s.iterable), "L0341", "this range has no compile-time meaning")
			return .Fail
		}
		lo = stored.elements[RANGE_LOW]
		hi = stored.elements[RANGE_HIGH]
		closed = stored.elements[RANGE_CLOSED].boolean
	}
	if lo.kind != .Integer && lo.kind != .Rune {
		eval_fail(ev, expr_span(s.iterable), "L0341", "this range has no compile-time meaning")
		return .Fail
	}
	span := bi_sub(ev.alloc, hi.integer, lo.integer)
	if closed {
		span = bi_add(ev.alloc, span, bi_from_i64(ev.alloc, 1))
	}
	last := bi_sub(ev.alloc, span, bi_from_i64(ev.alloc, 1))
	count, fits := bi_to_i64(ev.alloc, span)
	if !fits {
		// A high endpoint far below the low one yields nothing; the step limit
		// ends a very long range first.
		count = bi_sign(span) < 0 ? 0 : max(i64)
	}
	for index in 0 ..< int(min(count, i64(max(int)))) {
		offset := bi_from_i64(ev.alloc, i64(index))
		if s.reversed {
			offset = bi_sub(ev.alloc, last, offset)
		}
		value := lo
		value.integer = bi_add(ev.alloc, lo.integer, offset)
		flow := eval_foreach_step(ev, s, &value, index)
		if flow != .Normal {
			return flow == .Break ? .Normal : flow
		}
	}
	return .Normal
}

// design.md "String iteration": yields Unicode scalar values.
@(private = "file")
eval_text_foreach :: proc(ev: ^Evaluator, s: ^Stmt_Foreach) -> Eval_Flow {
	subject, ok := eval_expr(ev, s.iterable)
	if !ok {
		return .Fail
	}
	elements, allocated := eval_elements(ev, utf8.rune_count_in_string(subject.text))
	if !allocated {
		return .Fail
	}
	next := 0
	for point in subject.text {
		elements[next] = Eval_Value{
			kind    = .Rune,
			type    = TYPE_RUNE,
			integer = bi_from_i64(ev.alloc, i64(point)),
		}
		next += 1
	}
	return eval_sequence_foreach(ev, s, elements)
}

@(private = "file")
eval_sequence_foreach :: proc(ev: ^Evaluator, s: ^Stmt_Foreach, elements: []Eval_Value) -> Eval_Flow {
	for index in 0 ..< len(elements) {
		at := s.reversed ? len(elements) - 1 - index : index
		flow := eval_foreach_step(ev, s, &elements[at], index)
		if flow != .Normal {
			return flow == .Break ? .Normal : flow
		}
	}
	return .Normal
}

// `continue` ends only the step.
@(private = "file")
eval_foreach_step :: proc(ev: ^Evaluator, s: ^Stmt_Foreach, element: ^Eval_Value, index: int) -> Eval_Flow {
	if !eval_step(ev, s.span) {
		return .Fail
	}
	if !bind_foreach_element(ev, s, element, index) {
		return .Fail
	}
	flow := eval_block(ev, s.body)
	return flow == .Continue ? .Normal : flow
}

// design.md "Element bindings": an owned binding copies; a borrowed or `&mut`
// binding is the container's storage. A single name over a lent `indexed()`
// record receives a fresh record whose `value` points at the element.
@(private = "file")
bind_foreach_element :: proc(ev: ^Evaluator, s: ^Stmt_Foreach, element: ^Eval_Value, index: int) -> bool {
	frame := current_frame(ev)
	if foreach_is_place_loop(s) || s.borrows && (!s.indexed || len(s.bindings) == 2) {
		if s.indexed && len(s.bindings) == 2 {
			bind_eval_pattern(ev, frame, s.bindings[:1], element, s.span) or_return
			return eval_bind_local(ev, frame, s.bindings[1].symbol, eval_count_value(ev, index))
		}
		return bind_eval_pattern(ev, frame, s.bindings, element, s.span)
	}
	value: Eval_Value
	if s.borrows {
		pointer := element_type_at(ev.k.c, s.element_type, ELEMENT_FIRST, 0)
		value = Eval_Value{kind = .Nil, type = pointer, target = element}
	} else {
		value = copy_value(ev, element^) or_return
	}
	if s.indexed {
		pair := eval_elements(ev, 2) or_return
		pair[ELEMENT_FIRST] = value
		pair[ELEMENT_SECOND] = eval_count_value(ev, index)
		value = Eval_Value{kind = .Aggregate, type = s.element_type, elements = pair}
	}
	slot := eval_slot(ev, value) or_return
	return bind_eval_pattern(ev, frame, s.bindings, slot, s.span)
}

// Each name is the part of `value` it destructures.
@(private = "file")
bind_eval_pattern :: proc(
	ev: ^Evaluator, frame: ^Eval_Frame, bindings: []Foreach_Binding, value: ^Eval_Value, span: Span,
) -> bool {
	if len(bindings) == 1 {
		if len(bindings[0].group) > 0 {
			return bind_eval_pattern(ev, frame, bindings[0].group, value, span)
		}
		if bindings[0].symbol != INVALID_SYMBOL {
			frame.locals[bindings[0].symbol] = value
		}
		return true
	}
	if value.kind != .Aggregate || len(value.elements) != len(bindings) {
		return eval_fail(ev, span, "L0341", "this element has no compile-time fields to destructure")
	}
	for slot in 0 ..< len(bindings) {
		bind_eval_pattern(ev, frame, bindings[slot:][:1], &value.elements[slot], span) or_return
	}
	return true
}

@(private = "file")
eval_count_value :: proc(ev: ^Evaluator, count: int) -> Eval_Value {
	return Eval_Value{kind = .Integer, type = TYPE_INT, integer = bi_from_i64(ev.alloc, i64(count))}
}

@(private = "file")
eval_switch :: proc(ev: ^Evaluator, s: ^Stmt_Switch) -> Eval_Flow {
	if s.init != nil {
		if flow := eval_stmt(ev, s.init); flow != .Normal {
			return flow
		}
	}
	// A `.name(&mut binding)` case binds the payload in the subject's own storage,
	// and so does any binding over a place (design.md "Switch ownership").
	if switch_binds_place(s) || s.kind == .Pattern && eval_frame_place(ev, s.subject) {
		place, ok := eval_place(ev, s.subject)
		if !ok {
			return .Fail
		}
		return eval_variant_switch(ev, s, place^, place)
	}
	subject, ok := eval_expr(ev, s.subject)
	if !ok {
		return .Fail
	}
	if s.kind == .Pattern {
		return eval_variant_switch(ev, s, subject)
	}
	default_index := -1
	for entry, index in s.cases {
		if len(entry.values) == 0 {
			default_index = index
			continue
		}
		for value in entry.values {
			matched, match_ok := eval_case_matches(ev, subject, value)
			if !match_ok {
				return .Fail
			}
			if matched {
				return eval_stmts(ev, s.cases[index].stmts, true)
			}
		}
	}
	if default_index >= 0 {
		return eval_stmts(ev, s.cases[default_index].stmts, true)
	}
	return .Normal
}

// Dispatches on the variant index, as the emitter compares the tag.
@(private = "file")
eval_variant_switch :: proc(ev: ^Evaluator, s: ^Stmt_Switch, subject: Eval_Value, place: ^Eval_Value = nil) -> Eval_Flow {
	chosen := -1
	fallback := -1
	for entry, index in s.cases {
		if len(entry.variant_indices) == 0 {
			fallback = index
			continue
		}
		if slice.contains(entry.variant_indices, subject.variant) {
			chosen = index
			break
		}
	}
	if chosen < 0 {
		chosen = fallback
	}
	if chosen < 0 {
		return .Normal
	}
	entry := s.cases[chosen]
	if len(entry.fields) > 0 {
		return eval_case_fields(ev, s, entry, subject, place)
	}
	if entry.binding_symbol != INVALID_SYMBOL && !eval_bind_case_payload(ev, current_frame(ev), entry, subject, place) {
		return .Fail
	}
	return eval_stmts(ev, entry.stmts, true)
}

// design.md "Switch ownership": a binding over a place names the payload in the
// subject's storage, and any other binding owns a copy.
@(private = "file")
eval_bind_case_payload :: proc(
	ev: ^Evaluator, frame: ^Eval_Frame, entry: Switch_Case, subject: Eval_Value, place: ^Eval_Value,
) -> bool {
	if place != nil && len(place.elements) > 0 {
		frame.locals[entry.binding_symbol] = &place.elements[0]
		return true
	}
	bound, copied := copy_value(ev, eval_union_payload(subject))
	return copied && eval_bind_local(ev, frame, entry.binding_symbol, bound)
}

// design.md "Union argument expansion": the arm for the subject's variant, with
// the payload bound as the switch it stands for binds it.
@(private = "file")
eval_dispatch :: proc(ev: ^Evaluator, s: ^Stmt_Switch) -> (out: Eval_Value, success: bool) {
	subject: Eval_Value
	place: ^Eval_Value
	if eval_frame_place(ev, s.subject) {
		found := eval_place(ev, s.subject) or_return
		subject, place = found^, found
	} else {
		value := eval_expr(ev, s.subject) or_return
		subject = value
	}
	for entry in s.cases {
		if len(entry.variant_indices) != 1 || entry.variant_indices[0] != subject.variant {
			continue
		}
		if entry.binding_symbol == INVALID_SYMBOL {
			return eval_expr(ev, entry.arm)
		}
		// A constant initialiser has no frame, so the payload gets one of its own.
		frame := current_frame(ev)
		own_frame := frame == nil
		if own_frame {
			frame = eval_push_frame(ev, INVALID_SYMBOL, s.span) or_return
		}
		defer if own_frame { pop(&ev.frames) }
		eval_bind_case_payload(ev, frame, entry, subject, place) or_return
		return eval_expr(ev, entry.arm)
	}
	eval_fail(ev, s.span, "L0341", "this union value has no variant to dispatch")
	return Eval_Value{}, false
}

// Whether `subject` is a place rooted in this frame's storage, which a binding then
// names rather than copies.
@(private = "file")
eval_frame_place :: proc(ev: ^Evaluator, subject: Expr) -> bool {
	if !expression_is_borrowed_place(subject) {
		return false
	}
	frame := current_frame(ev)
	if frame == nil {
		return false
	}
	cur := subject
	for {
		#partial switch v in cur {
		case ^Expr_Ident:
			_, local := frame.locals[v.symbol]
			return local
		case ^Expr_Selector:
			if v.operand == nil || type_is_pointer(ev.k.c, expr_base(v.operand).type) {
				return false
			}
			cur = v.operand
		case ^Expr_Index:
			if v.resolution.kind == .User_Operator || underlying_kind(ev.k.c, expr_base(v.operand).type) != .Array {
				return false
			}
			cur = v.operand
		case ^Expr_Postfix:
			// A pointer's target is storage wherever it lives; a box's payload is
			// its own.
			if v.op != .Caret {
				return false
			}
			if !v.boxed {
				return true
			}
			cur = v.operand
		case:
			return false
		}
	}
}

// design.md "Inspecting a union": each field binding names its field of the
// payload in the subject's storage when the subject is a place, and reads a
// copy otherwise.
@(private = "file")
eval_case_fields :: proc(ev: ^Evaluator, s: ^Stmt_Switch, entry: Switch_Case, subject: Eval_Value, place: ^Eval_Value) -> Eval_Flow {
	frame := current_frame(ev)
	payload := place != nil && len(place.elements) > 0 ? &place.elements[0] : nil
	record := payload^ if payload != nil else eval_union_payload(subject)
	for field in entry.fields {
		if field.symbol == INVALID_SYMBOL {
			continue
		}
		if record.kind != .Aggregate || field.slot >= len(record.elements) {
			eval_fail(ev, s.span, "L0341", "this payload has no compile-time fields to bind")
			return .Fail
		}
		if payload != nil {
			frame.locals[field.symbol] = &payload.elements[field.slot]
			continue
		}
		bound, copied := copy_value(ev, record.elements[field.slot])
		if !copied || !eval_bind_local(ev, frame, field.symbol, bound) {
			return .Fail
		}
	}
	return eval_stmts(ev, entry.stmts, true)
}

@(private = "file")
eval_case_matches :: proc(ev: ^Evaluator, subject: Eval_Value, value: Expr) -> (out: bool, success: bool) {
	if range, is_range := value.(^Expr_Range); is_range {
		lo := eval_expr(ev, range.lo) or_return
		hi := eval_expr(ev, range.hi) or_return
		above, above_ok := eval_compare(ev, .Gt_Eq, subject, lo)
		below, below_ok := eval_compare(ev, range.op == .Range_Excl ? .Lt : .Lt_Eq, subject, hi)
		if !above_ok || !below_ok {
			return false, eval_fail(ev, expr_span(value), "L0341", "this case has no compile-time meaning")
		}
		return above && below, true
	}
	other := eval_expr(ev, value) or_return
	matched, compare_ok := eval_compare(ev, .Eq_Eq, subject, other)
	if !compare_ok {
		return false, eval_fail(ev, expr_span(value), "L0341", "this case has no compile-time meaning")
	}
	return matched, true
}

@(private = "file")
eval_return :: proc(ev: ^Evaluator, s: ^Stmt_Return) -> Eval_Flow {
	frame := current_frame(ev)
	if s.value == nil {
		return .Return
	}
	computed: Eval_Value
	if s.value.is_inout {
		place, place_ok := eval_place(ev, s.value.expr)
		if !place_ok {
			return .Fail
		}
		frame.result_place = place
		computed = place^
	} else {
		value, ok := eval_expr(ev, s.value.expr)
		if !ok {
			return .Fail
		}
		computed = value
	}
	copied, copied_ok := copy_value(ev, computed)
	if !copied_ok {
		return .Fail
	}
	frame.result = copied
	return .Return
}
