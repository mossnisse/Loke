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

// What evaluating `e` still charges to its storage when it ends: the unit
// tests' view of what an evaluation releases.
@(private)
eval_held_bytes :: proc(k: ^Checker, e: Expr) -> (held: int, ok: bool) {
	ev := Evaluator{k = k, origin = expr_span(e), what = "a measured value"}
	defer eval_storage_destroy(&ev.storage)
	_, ok = eval_root(&ev, e, "L0340", "%s must be a compile-time constant")
	return ev.storage.bytes, ok
}

// Checks a procedure on demand, so a constant may call one not reached yet.
@(private)
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
@(private)
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

@(private)
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
@(private)
eval_memory_ok :: proc(ev: ^Evaluator) -> bool {
	if !ev.storage.exhausted { return true }
	return eval_fail(ev, ev.origin, "L0342", "")
}

@(private)
eval_slot :: proc(ev: ^Evaluator, value: Eval_Value) -> (^Eval_Value, bool) {
	slot := new(Eval_Value, ev.alloc)
	if slot == nil { return nil, false }
	slot^ = value
	return slot, true
}

@(private)
eval_elements :: proc(ev: ^Evaluator, count: int) -> ([]Eval_Value, bool) {
	if count < 0 || count > (EVAL_MAX_MEMORY - ev.storage.bytes) / size_of(Eval_Value) {
		ev.storage.exhausted = true
		return nil, eval_memory_ok(ev)
	}
	elements, err := make([]Eval_Value, count, ev.alloc)
	return elements, err == nil
}

@(private)
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
@(private)
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
@(private)
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
		return {}, eval_fail(
			ev, ev.origin, "L0341",
			"a capture literal is a runtime value: it may be made and called during compile-time evaluation, but cannot be its result",
		)
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
		return {}, eval_fail(ev, ev.origin, "L0341", "a pointer cannot escape compile-time evaluation")
	}
	// design.md "Compile-time procedure evaluation": a box owns an allocation the
	// generated program would have to release.
	if type_is_box(ev.k.c, v.type) {
		return {}, eval_fail(ev, ev.origin, "L0594", "a `%s` cannot escape compile-time evaluation", type_name(ev.k.c, v.type))
	}
	// design.md: a container's only constant is the empty one.
	if type_is_container(ev.k.c, v.type) {
		if len(v.elements) > 0 {
			return {}, eval_fail(
				ev, ev.origin, "L0594",
				"a `%s` cannot escape compile-time evaluation: its only constant value is the empty one",
				type_name(ev.k.c, v.type),
			)
		}
		return zero_const(ev.k.c, v.type)
	}
	cv := v.constant
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
scalar :: proc(cv: Const_Value, type: Type_Id) -> Eval_Value {
	value := Eval_Value{constant = cv, type = type}
	value.aggregate = nil
	return value
}

@(private)
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
		// design.md "Uninitialized capacity": an `Uninit(T)`'s storage is no value.
		if type_info_is_uninit(ev.k.c, info) {
			return value_from_const(ev, uninit_const(ev.k.c, type), type)
		}
		elements := eval_elements(ev, count) or_return
		for index in 0 ..< count {
			element_type := element
			if kind != .Array {
				field := symbol_of(ev.k.c, fields[index])
				if field == nil { return Eval_Value{}, false }
				element_type = field.type
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
@(private)
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

@(private)
current_frame :: proc(ev: ^Evaluator) -> ^Eval_Frame {
	if len(ev.frames) == 0 {
		return nil
	}
	return ev.frames[len(ev.frames) - 1]
}

@(private)
eval_expr :: proc(ev: ^Evaluator, e: Expr) -> (out: Eval_Value, success: bool) {
	base := expr_base(e)
	if base == nil {
		return Eval_Value{}, false
	}
	// design.md "Borrowed callable views" and "Variadic parameters": a view is
	// built at run time.
	if base.erased_from != INVALID_TYPE && type_is_dyn(ev.k.c, base.type) {
		return {}, eval_fail(
			ev, expr_span(e), "L0341", "a `%s` view has no compile-time value",
			dyn_proc_signature(ev.k.c, base.type) != INVALID_TYPE ? "dyn proc" : "dyn",
		)
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

@(private)
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
		return {}, eval_fail(ev, v.span, "L0341", "this `or_return` has no compile-time target")

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
	return {}, eval_fail(ev, expr_span(e), "L0341", "this expression has no compile-time meaning")
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
		return 0, eval_fail(ev, expr_span(index), "L0361", "index %s is out of range", bi_text(ev.alloc, value.integer))
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
			return {}, eval_fail(ev, v.span, "L0344", "`%s` cannot be evaluated: its declaration is still being checked", v.name)
		}
		return Eval_Value{kind = .Nil, type = v.type, proc_value = v.symbol}, true
	case .Var:
		return {}, eval_fail(ev, v.span, "L0341", "`%s` is a mutable variable and cannot be read at compile time", v.name)
	}
	return {}, eval_fail(ev, v.span, "L0341", "`%s` has no compile-time value", v.name)
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
	return eval_unary_value(ev, v.op, v.op_span, operand.constant, v.type)
}

// A scalar unary operation on a folded operand of `type`; a delegated operator
// applies it to the unwrapped value too.
@(private = "file")
eval_unary_value :: proc(ev: ^Evaluator, op: Token_Kind, site: Span, value: Const_Value, type: Type_Id) -> (Eval_Value, bool) {
	#partial switch op {
	case .Plus, .Minus, .Tilde, .Not:
	case:
		return {}, eval_fail(ev, site, "L0341", "`%s` has no compile-time meaning", operator_text(op))
	}
	folded, ok := fold_unary(ev.k.c, op, site, value, type, ev.alloc)
	return eval_folded(ev, folded, ok, type)
}

@(private = "file")
eval_binary :: proc(ev: ^Evaluator, v: ^Expr_Binary) -> (out: Eval_Value, success: bool) {
	// design.md "Operator declarations": a user operator is an ordinary call,
	// and one that falls back to `==` or `<` negates the result.
	if v.resolution.kind == .User_Operator {
		operands, order := binary_operator_operands(v)
		result := eval_operator_call(ev, v.resolution.symbol, operands[:], v.op_span, order = order) or_return
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

	// design.md "SIMD vectors": lane-wise, since `constant` carries no lanes.
	if type_is_simd(ev.k.c, v.type) {
		return eval_simd_binary_values(ev, v.op, v.op_span, v.type, left, right)
	}
	return eval_scalar_binary(ev, v.op, v.op_span, left, right, v.type, v.type)
}

// A built-in binary operation on scalars: a comparison answers a `result`
// boolean, and arithmetic folds in `operand`, giving a `result`.
@(private)
eval_scalar_binary :: proc(ev: ^Evaluator, op: Token_Kind, site: Span, a, b: Eval_Value, operand, result: Type_Id) -> (out: Eval_Value, success: bool) {
	if comparison_operator(op) {
		answer := eval_compare_at(ev, op, a, b, site) or_return
		return scalar(bool_const(answer), result), true
	}
	folded, ok := fold_arithmetic(ev.k.c, op, site, a.constant, b.constant, operand, ev.alloc)
	return eval_folded(ev, folded, ok, result)
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
		lane := eval_simd_lane(operand, index).constant
		elements[index] = eval_unary_value(ev, op, op_span, lane, info.element) or_return
	}
	return Eval_Value{kind = .Aggregate, type = type, elements = elements}, true
}

// One lane at a time; either operand may be a splatted scalar.
@(private)
eval_simd_binary_values :: proc(
	ev: ^Evaluator, op: Token_Kind, op_span: Span, type: Type_Id, left, right: Eval_Value,
) -> (out: Eval_Value, success: bool) {
	info := underlying_info(ev.k.c, type)
	if info == nil {
		return Eval_Value{}, false
	}
	// A comparison's lanes are `bool`, unlike its operands'.
	source := underlying_info(ev.k.c, type_is_simd(ev.k.c, left.type) ? left.type : right.type)
	lane_type := comparison_operator(op) ? info.element : source.element
	elements := eval_elements(ev, int(info.count)) or_return
	for index in 0 ..< int(info.count) {
		a, b := eval_simd_lane(left, index), eval_simd_lane(right, index)
		elements[index] = eval_scalar_binary(ev, op, op_span, a, b, source.element, lane_type) or_return
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
			op: Token_Kind = fold == .Add ? .Plus : .Star
			result = eval_scalar_binary(ev, op, v.span, result, lane, info.element, info.element) or_return
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

// A fold's result as a value of `type`. A failed fold reported its own failure,
// unless memory ran out.
@(private = "file")
eval_folded :: proc(ev: ^Evaluator, folded: Const_Value, ok: bool, type: Type_Id) -> (Eval_Value, bool) {
	if !ok {
		if eval_memory_ok(ev) {
			ev.failed = true
		}
		return {}, false
	}
	return scalar(folded, type), true
}

// Pointer and procedure identity are the evaluator's own.
@(private)
eval_compare :: proc(ev: ^Evaluator, op: Token_Kind, a, b: Eval_Value) -> (out: bool, success: bool) {
	if a.target != nil || b.target != nil || a.proc_value != INVALID_SYMBOL || b.proc_value != INVALID_SYMBOL {
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		equal := a.target == b.target && a.proc_value == b.proc_value
		return equal == (op == .Eq_Eq), true
	}
	// Two null addresses compare as the constants do, ordering included.
	if a.kind == .Nil && b.kind == .Nil {
		return fold_comparison(ev.k.c, op, a.constant, b.constant, ev.alloc)
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
		// design.md "Comparison operators": the first unequal part ends the
		// comparison. As in `aggregate_equal`, a part with no compile-time
		// comparison makes the answer unknown unless a later part differs, but
		// only where no part's own `==` could run: whether a later one would is
		// unknown.
		known := true
		for element, index in a.elements {
			same, ok := eval_compare(ev, .Eq_Eq, element, b.elements[index])
			switch {
			case ev.failed:
				return false, false
			case !ok:
				if comparison_runs_own_equality(ev.k.c, a.type) {
					return false, false
				}
				known = false
			case !same:
				return op == .Not_Eq, true
			}
		}
		return op == .Eq_Eq, known
	}
	return fold_comparison(ev.k.c, op, a.constant, b.constant, ev.alloc)
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
		return {}, eval_fail(ev, v.span, "L0341", "this literal has no compile-time value")
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
			return {}, eval_fail(ev, v.span, "L0405", "a literal element has no checked field")
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

@(private)
eval_void :: proc() -> Eval_Value {
	return Eval_Value{kind = .Invalid, type = TYPE_VOID}
}

// The storage an expression denotes, for assignment, `&`, and `inout`.
@(private)
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
			return nil, eval_fail(ev, v.span, "L0341", "`%s` is a mutable variable and cannot be written at compile time", v.name)
		}
		return nil, eval_fail(ev, v.span, "L0341", "`%s` is not compile-time storage", v.name)

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
	return nil, eval_fail(ev, expr_span(e), "L0341", "this expression is not compile-time storage")
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
		return {}, eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
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
		return {}, eval_fail(ev, v.span, "L0361", "slice bounds %d:%d are out of range for length %d", low, high, length)
	}
	if operand.kind == .String {
		text := operand.text[low:high]
		// An empty slice still needs its bound at a sequence start or the end.
		split := low < i64(len(operand.text)) && !utf8.rune_start(operand.text[low])
		if split || !utf8.valid_string(text) {
			return {}, eval_fail(ev, v.span, "L0343", "string slice bounds split a code point")
		}
		return Eval_Value{kind = .String, type = v.type, text = text}, true
	}
	return Eval_Value{kind = .Aggregate, type = v.type, elements = operand.elements[low:high]}, true
}

@(private = "file")
eval_deref :: proc(ev: ^Evaluator, pointer: Eval_Value, span: Span) -> (^Eval_Value, bool) {
	if pointer.target == nil {
		return nil, eval_fail(ev, span, "L0343", "this dereferences a nil pointer")
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
		return nil, eval_fail(ev, v.span, "L0341", "this field has no compile-time value here")
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
@(private)
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

@(private)
eval_named_union :: proc(ev: ^Evaluator, type: Type_Id, name: string, payload: Eval_Value) -> (Eval_Value, bool) {
	return eval_union(ev, type, union_index_of(ev.k.c, type, name), payload)
}

// The fallback is evaluated only on failure, as at run time.
@(private = "file")
eval_or_else :: proc(ev: ^Evaluator, v: ^Expr_Or_Else) -> (out: Eval_Value, success: bool) {
	value := eval_expr(ev, v.value) or_return
	shape, fallible := fallible_of(ev.k.c, expr_base(v.value).type)
	if !fallible {
		return {}, eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
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
		return {}, eval_fail(ev, v.span, "L0341", "this `or_else` has no compile-time target")
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
		return {}, eval_fail(ev, v.op_span, "L0341", "this `or_return` has no compile-time target")
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
		return {}, eval_fail(ev, v.op_span, "L0341", "this `or_return` has no compile-time target")
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
@(private)
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
@(private)
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
			return {}, eval_fail(ev, v.span, "L0341", "a union construction needs its payload")
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
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Simd_Reduce:
		callee := symbol_of(ev.k.c, v.resolution.symbol)
		if callee != nil && callee.kind == .Builtin { return eval_builtin(ev, v, callee) }
	case nil:
		return {}, eval_fail(ev, v.span, "L0341", "an unchecked call has no compile-time meaning")
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
		return {}, eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
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
	return {}, eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
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
	return {}, eval_fail(ev, v.span, "L0595", "`cap` has no compile-time meaning: a capacity is a property of an allocation, and there is none here")
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
	return hash_const(c, frozen, type, seed), true
}

// Direct and indirect calls alike.
@(private = "file")
eval_call_target :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (out: Symbol_Id, success: bool) {
	if v.resolution.symbol != INVALID_SYMBOL {
		return v.resolution.symbol, true
	}
	value := eval_expr(ev, v.callee) or_return
	if value.proc_value == INVALID_SYMBOL {
		return INVALID_SYMBOL, eval_fail(ev, expr_span(v.callee), "L0343", "this calls a nil procedure value")
	}
	return value.proc_value, true
}

// Hands back the one declared result, or an invalid value when the procedure has
// none.
@(private)
eval_invoke :: proc(
	ev: ^Evaluator, symbol_id: Symbol_Id, args: []Expr, site: Span, values: []Eval_Value = nil, order: []int = nil,
	result_place: ^^Eval_Value = nil,
) -> (out: Eval_Value, success: bool) {
	defer { if !eval_memory_ok(ev) { success = false } }
	// An operator is reached through its resolution, not by name, and a member
	// of an instantiated generic block is checked only after its package, so
	// the body may not have been checked yet.
	if !ensure_proc_typed_for_eval(ev.k, symbol_id) {
		return {}, eval_fail(
			ev, site, "L0344", "`%s` cannot be called at compile time: its body is still being checked",
			eval_proc_name(ev.k.c, symbol_id),
		)
	}
	symbol := symbol_of(ev.k.c, symbol_id)
	literal := eval_proc_literal(symbol)
	if literal == nil || literal.body == nil {
		return {}, eval_fail(ev, site, "L0341", "`%s` has no body to evaluate", eval_proc_name(ev.k.c, symbol_id))
	}
	if len(ev.frames) >= EVAL_MAX_DEPTH {
		return {}, eval_fail(ev, site, "L0342", "compile-time evaluation exceeded a call depth of %d", EVAL_MAX_DEPTH)
	}
	// Its errors are already reported; running it would trip over nodes the
	// checker gave up on.
	if symbol.decl != nil && symbol.decl.check_failed {
		return {}, eval_fail(ev, site, "L0344", "`%s` cannot be called at compile time: its body has errors", eval_proc_name(ev.k.c, symbol_id))
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

@(private)
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
	mode := param_mode_at(info, index)
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
@(private)
eval_release_frame :: proc(ev: ^Evaluator, frame: ^Eval_Frame) {
	delete(frame.locals)
	delete(frame.defers)
	free(frame, ev.alloc)
}

// design.md "Delegating operators": a forwarding overload calls what it
// forwards to, and one with no overload behind it applies the underlying type's
// built-in operation, as `emit_delegated` does. `values`, when given, are the
// operands already evaluated, and `order` the slots of `args` in evaluation
// order where that is not their own.
@(private)
eval_operator_call :: proc(
	ev: ^Evaluator, symbol_id: Symbol_Id, args: []Expr, site: Span, values: []Eval_Value = nil, order: []int = nil,
) -> (out: Eval_Value, success: bool) {
	symbol := symbol_of(ev.k.c, symbol_id)
	if symbol == nil || !symbol.delegated {
		return eval_invoke(ev, symbol_id, args, site, values, order)
	}
	if symbol.delegate_target != INVALID_SYMBOL {
		return eval_operator_call(ev, symbol.delegate_target, args, site, values, order)
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
		applied := eval_unary_value(ev, op, site, operands[0].constant, symbol.delegate_underlying) or_return
		return scalar(applied.constant, symbol.result), true
	}
	return eval_scalar_binary(ev, op, site, operands[0], operands[1], symbol.delegate_underlying, symbol.result)
}

// design.md "`inout` results": a call returning `inout T` is a place, the
// storage its `return inout` named.
@(private = "file")
eval_call_place :: proc(ev: ^Evaluator, target: Symbol_Id, args: []Expr, site: Span, order: []int = nil) -> (out: ^Eval_Value, success: bool) {
	if symbol := symbol_of(ev.k.c, target); symbol == nil || !symbol.result_inout {
		return nil, eval_fail(ev, site, "L0341", "this expression is not compile-time storage")
	}
	place: ^Eval_Value
	eval_invoke(ev, target, args, site, order = order, result_place = &place) or_return
	if place == nil {
		return nil, eval_fail(ev, site, "L0341", "this call returned no storage")
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
		return {}, eval_fail(ev, v.span, "L0341", "a pointer's address cannot be observed at compile time")
	}
	// An aggregate is frozen so the shared conversion sees its lanes.
	operand := source.constant
	if source.kind == .Aggregate {
		frozen := freeze(ev, source, ev.alloc) or_return
		operand = frozen
	}
	converted, fits := convert_const(c, operand, v.type, true, ev.alloc)
	if !fits && (operand.kind == .Integer || operand.kind == .Rune) && (type_is_integer(c, v.type) || type_is_rune(c, v.type)) {
		// design.md "Type conversion": where a run would panic.
		return {}, eval_fail(
			ev, v.span, "L0712", "the value %s does not fit `%s`; `math.wrap` keeps its low bits",
			bi_text(ev.alloc, operand.integer), type_name(c, v.type),
		)
	}
	if !fits {
		return {}, eval_fail(ev, v.span, "L0341", "this conversion has no compile-time value")
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
		return {}, eval_fail(ev, v.span, "L0343", "compile-time assertion failed%s", eval_message(ev, v, 1))

	case .Panic:
		return {}, eval_fail(ev, v.span, "L0343", "compile-time panic%s", eval_message(ev, v, 0))

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

	case .Unsafe_Storage:
		// The borrow the checker bound.
		return eval_expr(ev, v.bound[0])

	case .Math_Wrap ..= .Math_Checked_Next_Power_Of_Two:
		return eval_math_builtin(ev, v, symbol)

	case .Simd_Select, .Simd_Reduce:
		return eval_simd_builtin(ev, v, symbol)
	}
	return {}, eval_fail(ev, v.span, "L0341", "`%s` has no compile-time meaning", identifier_text(ev.k.c, symbol.name))
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

	// `.Unsafe_Transmute`. A vector and its array have the same lanes in the same
	// order (standard-library.md "`core:simd`"), so the value is only retyped.
	source := expr_base(v.bound[0]).type
	if vector_and_its_array(ev.k.c, source, v.type) {
		out = eval_copied(ev, v.bound[0]) or_return
		out.type = v.type
		return out, true
	}
	// Otherwise the checker's fold, for an operand that is a local.
	operand := eval_expr(ev, v.bound[0]) or_return
	frozen := freeze(ev, operand, ev.alloc) or_return
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
				lane := eval_simd_lane(operand, index).constant
				lane.integer = wrap_to_type(ev.k.c, lane.integer, info.element, ev.alloc)
				elements[index] = scalar(lane, info.element)
			}
			return Eval_Value{kind = .Aggregate, type = v.type, elements = elements}, true
		}
		if operand.kind != .Integer && operand.kind != .Rune {
			return {}, eval_fail(ev, v.span, "L0341", "this conversion has no compile-time value")
		}
		wrapped := operand.constant
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
		return scalar(exact_sqrt(operand.constant), v.type), true

	case .Math_Floor_Instruction, .Math_Ceil_Instruction, .Math_Trunc_Instruction, .Math_Round_Instruction:
		operand := eval_expr(ev, v.bound[0]) or_return
		return scalar(exact_integral(operand.constant, symbol.builtin), v.type), true

	case .Math_Mod_Instruction:
		operands: [2]Eval_Value
		eval_operands(ev, v.bound, operands[:]) or_return
		return scalar(exact_mod(operands[0].constant, operands[1].constant), v.type), true

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
	}
	return eval_folded(ev, result, fits, v.type)
}

@(private = "file")
eval_simd_builtin :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol) -> (out: Eval_Value, success: bool) {
	#partial switch symbol.builtin {
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
	// Only the diagnostic keeps the text, and it formats its own copy.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ": ")
	strings.write_string(&b, base.const_value.text)
	for arg in v.bound[index + 1:] {
		text := "<value>"
		if value, ok := eval_expr(ev, arg); ok {
			text = const_display_text(ev.k.c, value.constant)
		}
		strings.write_byte(&b, ' ')
		strings.write_string(&b, text)
	}
	return strings.to_string(b)
}

@(private)
eval_count_value :: proc(ev: ^Evaluator, count: int) -> Eval_Value {
	return Eval_Value{kind = .Integer, type = TYPE_INT, integer = bi_from_i64(ev.alloc, i64(count))}
}
