// The compile-time engine: a tree-walking interpreter over the typed AST, with
// value operations shared through `const_ops.odin`. Values are mutable while a
// procedure runs and are frozen into `Const_Value`s on the way out.
package lokec

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
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
	kind:       Const_Kind,
	type:       Type_Id,
	// A union's variant; `elements[0]` is its payload, `Invalid` when none.
	variant:    int,
	integer:    Big_Int,
	float:      f64,
	float_bits: u16,
	float_raw:  u64,
	boolean:    bool,
	text:       string,
	type_value: Type_Id,
	elements:   []Eval_Value,
	target:     ^Eval_Value,
	proc_value: Symbol_Id,
}

Eval_Frame :: struct {
	symbol:       Symbol_Id,
	site:         Span,
	locals:       map[Symbol_Id]^Eval_Value,
	defers:       [dynamic]Stmt,
	// A nil slot means no result.
	result:      Eval_Value,
	result_slot: ^Eval_Value,
	// Set by a failing `or_return`; the enclosing statement turns it into `.Return`.
	returning:    bool,
}

Evaluator :: struct {
	k:      ^Checker,
	arena:  virtual.Arena,
	alloc:  mem.Allocator,
	frames: [dynamic]^Eval_Frame,
	steps:  int,
	bytes:  int,
	memory_error: mem.Allocator_Error,
	failed: bool,
	// The context that required this evaluation, where the diagnostic points.
	origin: Span,
	what:   string,
}

// Every compile-time-required context comes through here. `code` names the
// context in the fallback diagnostic for a failure nothing else reported.
require_const :: proc(k: ^Checker, e: Expr, what: string, code := "L0340") -> (Const_Value, bool) {
	base := expr_base(e)
	if base == nil || base.type == INVALID_TYPE {
		return Const_Value{}, false
	}
	if base.is_const && base.const_value.kind != .Invalid {
		return base.const_value, true
	}
	ev := Evaluator{k = k, origin = expr_span(e), what = what}
	defer virtual.arena_destroy(&ev.arena)
	value, ok := eval_root(&ev, e, code, "%s must be a compile-time constant")
	if !ok {
		return Const_Value{}, false
	}
	frozen, froze := freeze(&ev, value)
	if !froze {
		return Const_Value{}, false
	}
	base.is_const = true
	base.const_value = frozen
	return frozen, true
}

// Static `foreach`: each element freezes on its own, so the container never
// escapes evaluation.
evaluate_static_elements :: proc(k: ^Checker, e: Expr, what: string, code := "L0454") -> ([]Const_Value, bool) {
	ev := Evaluator{k = k, origin = expr_span(e), what = what}
	defer virtual.arena_destroy(&ev.arena)
	value, ok := eval_root(&ev, e, code, "%s must be compile-time evaluable")
	if !ok {
		return nil, false
	}
	out := make([]Const_Value, len(value.elements), k.c.semantic_allocator)
	for element, index in value.elements {
		frozen, froze := freeze(&ev, element)
		if !froze {
			return nil, false
		}
		out[index] = frozen
	}
	return out, true
}

// Runs `e` in a fresh evaluator, reporting `format` (with `what`) for a failure
// nothing else reported.
@(private = "file")
eval_root :: proc(ev: ^Evaluator, e: Expr, code, format: string) -> (Eval_Value, bool) {
	if !init_evaluator(ev) {
		return Eval_Value{}, false
	}
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
ensure_proc_typed_for_eval :: proc(k: ^Checker, symbol_id: Symbol_Id) -> bool {
	// Executing a declaration is a real use, even from a `where` predicate.
	saved_speculation := k.c.speculation_depth
	k.c.speculation_depth = 0
	// The same holds for what the check reports: a passing `where` bound rolls
	// back everything after its mark, and this body is never checked again.
	mark := len(k.c.diagnostics)
	defer {
		hold_diagnostics(k.c, mark)
		k.c.speculation_depth = saved_speculation
	}
	if instance, found := k.c.procedure_instances[symbol_id]; found {
		promote_generic_instance(k, instance, no_span())
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

	outer_location := save_checker_location(k)
	outer_proc, outer_result := k.proc_literal, k.result_type
	outer_loop, outer_defer := k.loop_depth, k.in_defer
	outer_slots := k.defer_slots
	defer {
		restore_checker_location(k, outer_location)
		k.proc_literal, k.result_type = outer_proc, outer_result
		k.loop_depth, k.in_defer = outer_loop, outer_defer
		k.defer_slots = outer_slots
	}
	enter_symbol_location(k, symbol)
	k.proc_literal = nil
	k.result_type = INVALID_TYPE
	k.loop_depth, k.in_defer = 0, false

	resolve_declaration_signature(k, d)
	check_decl(k, d)
	return d.check_state == .Checked
}

// The primary diagnostic names the required context; notes name the failing
// operation and every frame in between.
eval_fail :: proc(ev: ^Evaluator, span: Span, code: string, format: string, args: ..any) -> bool {
	if ev.failed {
		return false
	}
	ev.failed = true
	c := ev.k.c
	if ev.memory_error != nil {
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
init_evaluator :: proc(ev: ^Evaluator) -> bool {
	if err := virtual.arena_init_growing(&ev.arena); err != nil {
		return eval_fail(ev, ev.origin, "L0342", "cannot reserve compile-time scratch memory")
	}
	ev.alloc = mem.Allocator{eval_allocator_proc, ev}
	ev.frames = make([dynamic]^Eval_Frame, 0, 8, ev.alloc)
	return true
}

// All execution storage is charged here; frees reclaim nothing and a resize is
// charged in full.
@(private = "file")
eval_allocator_proc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location,
) -> ([]u8, mem.Allocator_Error) {
	ev := (^Evaluator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		padding := max(alignment - 1, 0)
		if ev.memory_error != nil || size < 0 || padding > EVAL_MAX_MEMORY - ev.bytes ||
		   size > EVAL_MAX_MEMORY - ev.bytes - padding {
			ev.memory_error = .Out_Of_Memory
			return nil, .Out_Of_Memory
		}
		ev.bytes += size + padding
	case .Free:
		return nil, nil
	case .Free_All:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		if features := (^mem.Allocator_Mode_Set)(old_memory); features != nil {
			features^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
	}
	backing := virtual.arena_allocator(&ev.arena)
	result, err := backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location)
	if err != nil && err != .Mode_Not_Implemented { ev.memory_error = err }
	return result, err
}

// Reported outside the allocator, since reporting allocates too.
@(private = "file")
eval_memory_ok :: proc(ev: ^Evaluator) -> bool {
	if ev.memory_error == nil { return true }
	return eval_fail(ev, ev.origin, "L0342", "compile-time evaluation exceeded %d bytes of scratch memory", EVAL_MAX_MEMORY)
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
	if count < 0 || count > (EVAL_MAX_MEMORY - ev.bytes) / size_of(Eval_Value) {
		eval_fail(
			ev,
			ev.origin,
			"L0342",
			"compile-time evaluation exceeded %d bytes of scratch memory",
			EVAL_MAX_MEMORY,
		)
		return nil, false
	}
	elements, err := make([]Eval_Value, count, ev.alloc)
	return elements, err == nil
}

// The declared type of one element of an aggregate type.
@(private = "file")
element_type_at :: proc(c: ^Compiler, type: Type_Id, index: int) -> Type_Id {
	info := underlying_info(c, type)
	if info == nil {
		return INVALID_TYPE
	}
	#partial switch info.kind {
	case .Array, .Simd, .Slice:
		return info.element
	case .Struct:
		if index < len(info.fields) {
			if symbol := symbol_of(c, info.fields[index]); symbol != nil {
				return symbol.type
			}
		}
	case .Union:
		// A union constant holds one element, its active variant's payload.
		return INVALID_TYPE
	}
	return INVALID_TYPE
}

@(private = "file")
value_from_const :: proc(ev: ^Evaluator, cv: Const_Value, type: Type_Id) -> (Eval_Value, bool) {
	value := scalar(cv, type)
	// A container's all-zero header reads back as the empty container.
	if type_is_container(ev.k.c, type) {
		return Eval_Value{kind = .Aggregate, type = type}, true
	}
	if cv.kind == .Aggregate && cv.aggregate != nil {
		holder := type != INVALID_TYPE ? type : cv.aggregate.type
		value.type = holder
		value.variant = cv.aggregate.variant
		is_union := type_is_union(ev.k.c, type_underlying(ev.k.c, holder))
		elements, allocated := eval_elements(ev, len(cv.aggregate.elements))
		if !allocated {
			return Eval_Value{}, false
		}
		value.elements = elements
		for element, index in cv.aggregate.elements {
			member := is_union ? union_variant_payload(ev.k.c, holder, cv.aggregate.variant) : element_type_at(ev.k.c, holder, index)
			converted, ok := value_from_const(ev, element, member)
			if !ok {
				return Eval_Value{}, false
			}
			value.elements[index] = converted
		}
	}
	return value, true
}

// A deep copy, so an assigned aggregate never aliases its source.
@(private = "file")
copy_value :: proc(ev: ^Evaluator, v: Eval_Value) -> (Eval_Value, bool) {
	if v.elements == nil {
		return v, true
	}
	out := v
	elements, allocated := eval_elements(ev, len(v.elements))
	if !allocated {
		return Eval_Value{}, false
	}
	out.elements = elements
	for element, index in v.elements {
		copied, ok := copy_value(ev, element)
		if !ok {
			return Eval_Value{}, false
		}
		out.elements[index] = copied
	}
	return out, true
}

// Into immutable compilation storage; a pointer cannot make the trip.
freeze :: proc(ev: ^Evaluator, v: Eval_Value, allocator: mem.Allocator = {}) -> (Const_Value, bool) {
	storage := value_allocator(ev.k.c, allocator)
	if v.target != nil || v.proc_value != INVALID_SYMBOL {
		eval_fail(ev, ev.origin, "L0341", "a pointer cannot escape compile-time evaluation")
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
		zero, ok := zero_const(ev.k.c, v.type)
		return zero, ok
	}
	cv := const_of(v)
	if v.kind == .Integer || v.kind == .Rune {
		cv.integer = bi_clone(storage, v.integer)
	} else if v.kind == .String {
		cv.text = strings.clone(v.text, storage)
	}
	if v.kind == .Aggregate {
		elements, err := make([]Const_Value, len(v.elements), storage)
		if err != nil { return Const_Value{}, false }
		for element, index in v.elements {
			frozen, ok := freeze(ev, element, storage)
			if !ok {
				return Const_Value{}, false
			}
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

@(private = "file")
const_of :: proc(v: Eval_Value) -> Const_Value {
	return Const_Value {
		kind       = v.kind,
		integer    = v.integer,
		float      = v.float,
		float_bits = v.float_bits,
		float_raw  = v.float_raw,
		boolean    = v.boolean,
		text       = v.text,
		type_value = v.type_value,
	}
}

@(private = "file")
scalar :: proc(cv: Const_Value, type: Type_Id) -> Eval_Value {
	return Eval_Value {
		kind       = cv.kind,
		type       = type,
		integer    = cv.integer,
		float      = cv.float,
		float_bits = cv.float_bits,
		float_raw  = cv.float_raw,
		boolean    = cv.boolean,
		text       = cv.text,
		type_value = cv.type_value,
	}
}

@(private = "file")
zero_value :: proc(ev: ^Evaluator, type: Type_Id) -> (Eval_Value, bool) {
	if type_is_pointer(ev.k.c, type) {
		return Eval_Value{kind = .Nil, type = type}, true
	}
	// design.md: a container's zero value is empty.
	if type_is_container(ev.k.c, type) {
		return Eval_Value{kind = .Aggregate, type = type}, true
	}
	// design.md "Nil slices": a slice's zero value is nil.
	if type_is_slice(ev.k.c, type) {
		return Eval_Value{kind = .Nil, type = type}, true
	}
	under := type_underlying(ev.k.c, type)
	info := type_of(ev.k.c, under)
	if info == nil { return Eval_Value{}, false }
	#partial switch info.kind {
	case .Int, .Enum, .Rune:
		return Eval_Value{kind = info.kind == .Rune ? .Rune : .Integer, type = type, integer = bi_zero(ev.alloc)}, true
	case .Array, .Struct, .Any_View, .Dyn:
		count := info.kind == .Array ? int(info.count) : len(info.fields)
		kind, element, fields := info.kind, info.element, info.fields
		elements, allocated := eval_elements(ev, count)
		if !allocated { return Eval_Value{}, false }
		for index in 0 ..< count {
			element_type := element
			field: ^Symbol
			if kind != .Array {
				field = symbol_of(ev.k.c, fields[index])
				if field == nil { return Eval_Value{}, false }
				element_type = field.type
			}
			if field != nil && field.initialized_by != INVALID_SYMBOL {
				value, ok := value_from_const(ev, capacity_const(ev.k.c, field.type), field.type)
				if !ok { return Eval_Value{}, false }
				elements[index] = value
				continue
			}
			value, ok := zero_value(ev, element_type)
			if !ok { return Eval_Value{}, false }
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

@(private = "file")
current_frame :: proc(ev: ^Evaluator) -> ^Eval_Frame {
	if len(ev.frames) == 0 {
		return nil
	}
	return ev.frames[len(ev.frames) - 1]
}

eval_expr :: proc(ev: ^Evaluator, e: Expr) -> (result: Eval_Value, success: bool) {
	defer { if !eval_memory_ok(ev) { success = false } }
	if e == nil {
		return Eval_Value{}, false
	}
	if !eval_step(ev, expr_span(e)) {
		return Eval_Value{}, false
	}
	base := expr_base(e)
	if base == nil || base.type == INVALID_TYPE {
		return Eval_Value{}, false
	}
	if base.is_const && base.const_value.kind != .Invalid {
		return value_from_const(ev, base.const_value, base.type)
	}

	switch v in e {
	case ^Expr_Ident:
		return eval_ident(ev, v)

	case ^Expr_Selector:
		// `Type.method` or `U.name` naming a procedure, as a value.
		if sym := symbol_of(ev.k.c, v.resolution.symbol); v.resolution.kind == .Value && sym != nil && sym.kind == .Proc {
			return Eval_Value{kind = .Nil, type = v.type, proc_value = v.resolution.symbol}, true
		}
		// A value, not a place: `f().field` selects out of a temporary.
		operand, ok := eval_aggregate_value(ev, v.operand)
		if !ok {
			return Eval_Value{}, false
		}
		field, found := eval_field(ev, v, operand.elements)
		if !found {
			return Eval_Value{}, false
		}
		return field^, true

	case ^Expr_Index:
		operand, ok := eval_aggregate_value(ev, v.operand)
		if !ok {
			return Eval_Value{}, false
		}
		// design.md "Maps": a read never inserts.
		if type_is_map(ev.k.c, operand.type) {
			return eval_map_read(ev, v, &operand)
		}
		index_value, index_ok := eval_expr(ev, v.indices[0])
		if !index_ok {
			return Eval_Value{}, false
		}
		index, fits := bi_to_i64(ev.alloc, index_value.integer)
		if !fits || index < 0 || int(index) >= len(operand.elements) {
			eval_fail(ev, expr_span(v.indices[0]), "L0361", "index %s is out of range", bi_text(ev.alloc, index_value.integer))
			return Eval_Value{}, false
		}
		return operand.elements[index], true

	case ^Expr_Postfix:
		if v.op == .Or_Return {
			return eval_or_return(ev, v)
		}
		pointer, ok := eval_expr(ev, v.operand)
		if !ok {
			return Eval_Value{}, false
		}
		target, live := eval_deref(ev, pointer, v.op_span)
		if !live {
			return Eval_Value{}, false
		}
		return target^, true

	case ^Expr_Unary:
		return eval_unary(ev, v)

	case ^Expr_Binary:
		return eval_binary(ev, v)

	case ^Expr_Cond:
		cond, ok := eval_expr(ev, v.cond)
		if !ok {
			return Eval_Value{}, false
		}
		return eval_expr(ev, cond.boolean ? v.then : v.otherwise)

	case ^Expr_Call:
		return eval_call(ev, v)

	case ^Expr_Composite:
		return eval_composite(ev, v)

	case ^Expr_Range:
		low, low_ok := eval_expr(ev, v.lo)
		if !low_ok { return Eval_Value{}, false }
		high, high_ok := eval_expr(ev, v.hi)
		if !high_ok { return Eval_Value{}, false }
		elements, allocated := eval_elements(ev, 3)
		if !allocated { return Eval_Value{}, false }
		elements[RANGE_LOW] = low
		elements[RANGE_HIGH] = high
		elements[RANGE_CLOSED] = Eval_Value{
			kind = .Boolean, type = TYPE_BOOL, boolean = v.op == .Range_Incl,
		}
		return Eval_Value{kind = .Aggregate, type = v.type, elements = elements}, true

	case ^Expr_Proc:
		return Eval_Value{kind = .Nil, type = v.type, proc_value = v.symbol}, true

	case ^Expr_Or_Else:
		return eval_or_else(ev, v)

	case ^Expr_Error, ^Expr_Literal, ^Expr_Checked_Extract, ^Expr_Slice,
	     ^Expr_Move, ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_C_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Anon_Record, ^Type_Enum, ^Type_Interface:
	}
	eval_fail(ev, expr_span(e), "L0341", "this expression has no compile-time meaning")
	return Eval_Value{}, false
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
eval_unary :: proc(ev: ^Evaluator, v: ^Expr_Unary) -> (Eval_Value, bool) {
	if v.resolution.kind == .User_Operator {
		eval_fail(ev, v.op_span, "L0341", "a user operator has no compile-time meaning yet")
		return Eval_Value{}, false
	}
	if v.op == .Amp {
		slot, ok := eval_place(ev, v.operand)
		if !ok {
			return Eval_Value{}, false
		}
		return Eval_Value{kind = .Nil, type = v.type, target = slot}, true
	}
	operand, ok := eval_expr(ev, v.operand)
	if !ok {
		return Eval_Value{}, false
	}
	// design.md "SIMD vectors": lane-wise.
	if type_is_simd(ev.k.c, v.type) {
		return eval_simd_unary(ev, v, operand)
	}
	value := const_of(operand)
	folded: Const_Value
	#partial switch v.op {
	case .Plus:
		folded = value
	case .Minus:
		if value.kind == .Float {
			folded = float_const(-value.float, value.float_bits)
		} else {
			folded = Const_Value{kind = value.kind, integer = bi_neg(ev.alloc, value.integer)}
		}
	case .Tilde:
		folded = Const_Value{kind = value.kind, integer = bi_not(ev.alloc, value.integer)}
	case .Not:
		folded = bool_const(!value.boolean)
	case:
		eval_fail(ev, v.op_span, "L0341", "`%s` has no compile-time meaning", operator_text(v.op))
		return Eval_Value{}, false
	}
	if folded.kind == .Integer || folded.kind == .Rune {
		folded.integer = wrap_to_type(ev.k.c, folded.integer, v.type, ev.alloc)
	}
	return scalar(folded, v.type), true
}

@(private = "file")
eval_binary :: proc(ev: ^Evaluator, v: ^Expr_Binary) -> (Eval_Value, bool) {
	if v.resolution.kind == .User_Operator {
		eval_fail(ev, v.op_span, "L0341", "a user operator has no compile-time meaning yet")
		return Eval_Value{}, false
	}
	// design.md "Maps": `key in m`.
	if v.op == .In {
		return eval_map_membership(ev, v)
	}
	#partial switch v.op {
	case .And_And, .Or_Or:
		left, ok := eval_expr(ev, v.lhs)
		if !ok {
			return Eval_Value{}, false
		}
		if (v.op == .And_And) != left.boolean {
			return scalar(bool_const(v.op == .Or_Or), v.type), true
		}
		right, right_ok := eval_expr(ev, v.rhs)
		if !right_ok {
			return Eval_Value{}, false
		}
		return scalar(bool_const(right.boolean), v.type), true
	}

	left, left_ok := eval_expr(ev, v.lhs)
	if !left_ok {
		return Eval_Value{}, false
	}
	right, right_ok := eval_expr(ev, v.rhs)
	if !right_ok {
		return Eval_Value{}, false
	}

	// design.md "SIMD vectors": lane-wise, since `const_of` carries no lanes.
	if type_is_simd(ev.k.c, v.type) || type_is_simd(ev.k.c, left.type) {
		return eval_simd_binary_values(ev, v.op, v.op_span, v.type, left, right)
	}
	#partial switch v.op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		result, ok := eval_compare(ev, v.op, left, right)
		if !ok {
			eval_fail(ev, v.op_span, "L0341", "this comparison has no compile-time meaning")
			return Eval_Value{}, false
		}
		return scalar(bool_const(result), v.type), true
	}

	folded, ok := fold_arithmetic(ev.k.c, v.op, v.op_span, const_of(left), const_of(right), v.type, ev.alloc)
	if !ok {
		eval_fold_failed(ev)
		return Eval_Value{}, false
	}
	// A lane-wise fold answers with an aggregate.
	if folded.kind == .Aggregate {
		return value_from_const(ev, folded, v.type)
	}
	return scalar(folded, v.type), true
}

// `-v` and `~v`, one lane at a time. `+v` is the operand.
@(private = "file")
eval_simd_unary :: proc(ev: ^Evaluator, v: ^Expr_Unary, operand: Eval_Value) -> (Eval_Value, bool) {
	if v.op == .Plus {
		return operand, true
	}
	info := underlying_info(ev.k.c, v.type)
	if info == nil {
		return Eval_Value{}, false
	}
	elements, allocated := eval_elements(ev, int(info.count))
	if !allocated {
		return Eval_Value{}, false
	}
	for index in 0 ..< int(info.count) {
		lane := const_of(eval_simd_lane(operand, index))
		folded: Const_Value
		#partial switch v.op {
		case .Minus:
			if lane.kind == .Float {
				folded = float_const(-lane.float, lane.float_bits)
			} else {
				folded = Const_Value{kind = lane.kind, integer = bi_neg(ev.alloc, lane.integer)}
			}
		case .Tilde:
			if lane.kind == .Boolean {
				folded = bool_const(!lane.boolean)
			} else {
				folded = Const_Value{kind = lane.kind, integer = bi_not(ev.alloc, lane.integer)}
			}
		case:
			eval_fail(ev, v.op_span, "L0341", "this operator has no compile-time meaning")
			return Eval_Value{}, false
		}
		if folded.kind == .Integer || folded.kind == .Rune {
			folded.integer = wrap_to_type(ev.k.c, folded.integer, info.element, ev.alloc)
		}
		elements[index] = scalar(folded, info.element)
	}
	return Eval_Value{kind = .Aggregate, type = v.type, elements = elements}, true
}

// One lane at a time; either operand may be a splatted scalar.
@(private = "file")
eval_simd_binary_values :: proc(
	ev: ^Evaluator, op: Token_Kind, op_span: Span, type: Type_Id, left, right: Eval_Value,
) -> (Eval_Value, bool) {
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
	elements, allocated := eval_elements(ev, int(info.count))
	if !allocated {
		return Eval_Value{}, false
	}
	for index in 0 ..< int(info.count) {
		a, b := eval_simd_lane(left, index), eval_simd_lane(right, index)
		if comparison {
			result, ok := eval_compare(ev, op, a, b)
			if !ok {
				eval_fail(ev, op_span, "L0341", "this comparison has no compile-time meaning")
				return Eval_Value{}, false
			}
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

// design.md "`core:simd`": a fold from lane 0, left to right, as the emitted
// ordered reduction does. A float sum or product needs no `-0.0` or `1.0` seed
// here, because the seed combined with lane 0 is lane 0. `reduce_min` and
// `reduce_max` skip NaN lanes, so only an all-NaN vector answers NaN.
@(private = "file")
eval_simd_reduce :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (Eval_Value, bool) {
	vector, ok := eval_expr(ev, v.bound[0])
	if !ok {
		return Eval_Value{}, false
	}
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
			better, compared := eval_compare(ev, fold == .Min ? .Lt : .Gt, lane, result)
			if !compared {
				eval_fail(ev, v.span, "L0341", "this comparison has no compile-time meaning")
				return Eval_Value{}, false
			}
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
eval_compare :: proc(ev: ^Evaluator, op: Token_Kind, a, b: Eval_Value) -> (bool, bool) {
	if a.target != nil || b.target != nil || a.proc_value != INVALID_SYMBOL || b.proc_value != INVALID_SYMBOL ||
	   (a.kind == .Nil && b.kind == .Nil) {
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		equal := a.target == b.target && a.proc_value == b.proc_value
		return equal == (op == .Eq_Eq), true
	}
	if a.kind == .Aggregate && b.kind == .Aggregate {
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		// As `aggregate_equal`: counts match, and a union's variants too.
		equal := len(a.elements) == len(b.elements)
		if type_is_union(ev.k.c, a.type) {
			if a.variant != b.variant {
				equal = false
			} else if union_variant_payload(ev.k.c, a.type, a.variant) == TYPE_VOID {
				return op == .Eq_Eq, true
			}
		}
		info := underlying_info(ev.k.c, a.type)
		for element, index in a.elements {
			if !equal {
				break
			}
			field := info != nil && info.kind == .Struct ? symbol_of(ev.k.c, info.fields[index]) : nil
			counter := field != nil ? symbol_of(ev.k.c, field.initialized_by) : nil
			if counter == nil {
				same, ok := eval_compare(ev, .Eq_Eq, element, b.elements[index])
				equal = ok && same
				continue
			}
			left_count, left_ok := bi_to_i64(ev.alloc, a.elements[counter.index].integer)
			right_count, right_ok := bi_to_i64(ev.alloc, b.elements[counter.index].integer)
			count := min(left_count, right_count)
			if !left_ok || !right_ok || count < 0 || count > i64(len(element.elements)) ||
			   count > i64(len(b.elements[index].elements)) {
				eval_fail(ev, ev.origin, "L0343", "an initialized prefix count is out of range")
				return false, false
			}
			for at in 0 ..< int(count) {
				same, ok := eval_compare(ev, .Eq_Eq, element.elements[at], b.elements[index].elements[at])
				if !ok || !same {
					equal = false
					break
				}
			}
		}
		return equal == (op == .Eq_Eq), true
	}
	return fold_comparison(ev.k.c, op, const_of(a), const_of(b), ev.alloc)
}

@(private = "file")
eval_composite :: proc(ev: ^Evaluator, v: ^Expr_Composite) -> (Eval_Value, bool) {
	// design.md "Slice literals": a slice's constant is its elements in order.
	if type_is_container(ev.k.c, v.type) || type_is_slice(ev.k.c, v.type) {
		return eval_container_literal(ev, v)
	}
	value, zeroed := zero_value(ev, v.type)
	if !zeroed {
		return Eval_Value{}, false
	}
	if value.kind != .Aggregate {
		eval_fail(ev, v.span, "L0341", "this literal has no compile-time value")
		return Eval_Value{}, false
	}
	info := underlying_info(ev.k.c, v.type)
	if info == nil {
		return Eval_Value{}, false
	}
	for element, index in v.elements {
		slot := index
		if info.kind == .Struct {
			slot = index < len(v.field_indices) ? v.field_indices[index] : -1
		}
		if slot < 0 || slot >= len(value.elements) {
			eval_fail(ev, v.span, "L0405", "a literal element has no checked field")
			return Eval_Value{}, false
		}
		computed, ok := eval_expr(ev, element.value)
		if !ok {
			return Eval_Value{}, false
		}
		copied, copied_ok := copy_value(ev, computed)
		if !copied_ok {
			return Eval_Value{}, false
		}
		value.elements[slot] = copied
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

// Replaces a container's contents with `next`, charging the new storage.
@(private = "file")
set_contents :: proc(ev: ^Evaluator, slot: ^Eval_Value, next: []Eval_Value) -> bool {
	elements, allocated := eval_elements(ev, len(next))
	if !allocated {
		return false
	}
	copy(elements, next)
	slot.elements = elements
	return true
}

@(private = "file")
eval_container_literal :: proc(ev: ^Evaluator, v: ^Expr_Composite) -> (Eval_Value, bool) {
	out := Eval_Value{kind = .Aggregate, type = v.type}
	is_map := type_is_map(ev.k.c, v.type)
	count := len(v.elements) * (is_map ? 2 : 1)
	elements, allocated := eval_elements(ev, count)
	if !allocated {
		return Eval_Value{}, false
	}
	written := 0
	for element in v.elements {
		value, ok := eval_expr(ev, element.value)
		if !ok {
			return Eval_Value{}, false
		}
		copied, copied_ok := copy_value(ev, value)
		if !copied_ok {
			return Eval_Value{}, false
		}
		if !is_map {
			elements[written] = copied
			written += 1
			continue
		}
		key, key_ok := eval_expr(ev, element.key)
		if !key_ok {
			return Eval_Value{}, false
		}
		key_copy, key_copied := copy_value(ev, key)
		if !key_copied {
			return Eval_Value{}, false
		}
		elements[written + MAP_ENTRY_KEY] = key_copy
		elements[written + MAP_ENTRY_VALUE] = copied
		written += 2
	}
	out.elements = elements[:written]
	if is_map {
		// A repeated key keeps the last value, as at run time.
		deduped, ok := map_deduplicate(ev, out)
		if !ok {
			return Eval_Value{}, false
		}
		out = deduped
	}
	return out, true
}

@(private = "file")
map_deduplicate :: proc(ev: ^Evaluator, m: Eval_Value) -> (Eval_Value, bool) {
	out := m
	kept, err := make([dynamic]Eval_Value, 0, len(m.elements), ev.alloc)
	if err != nil { return Eval_Value{}, false }
	for index := 0; index < len(m.elements); index += 2 {
		found := -1
		for other := 0; other < len(kept); other += 2 {
			same, ok := eval_map_key_equal(ev, m.type, kept[other], m.elements[index])
			if !ok {
				return Eval_Value{}, false
			}
			if same {
				found = other
				break
			}
		}
		if found >= 0 {
			kept[found + MAP_ENTRY_VALUE] = m.elements[index + MAP_ENTRY_VALUE]
			continue
		}
		append(&kept, m.elements[index], m.elements[index + MAP_ENTRY_VALUE])
	}
	if !set_contents(ev, &out, kept[:]) {
		return Eval_Value{}, false
	}
	return out, true
}

// The entry index of `key`, or -1.
// ponytail: linear search; the step limit bounds a compile-time map.
@(private = "file")
map_find :: proc(ev: ^Evaluator, m: ^Eval_Value, key: Eval_Value) -> (int, bool) {
	for index := 0; index < len(m.elements); index += 2 {
		same, ok := eval_map_key_equal(ev, m.type, m.elements[index], key)
		if !ok {
			return -1, false
		}
		if same {
			return index, true
		}
	}
	return -1, true
}

// The runtime's key policy; structural equality only for the built-in one.
@(private = "file")
eval_map_key_equal :: proc(ev: ^Evaluator, map_type: Type_Id, a, b: Eval_Value) -> (bool, bool) {
	if !eval_step(ev, ev.origin) { return false, false }
	policy := ev.k.c.map_key_policies[container_key(ev.k.c, map_type)]
	if policy.kind == .Unresolved {
		return false, eval_fail(ev, ev.origin, "L0405", "a map key operation was not resolved during checking")
	}
	if policy.kind == .Builtin {
		return eval_compare(ev, .Eq_Eq, a, b)
	}
	if policy.equal == INVALID_SYMBOL || !ensure_proc_typed_for_eval(ev.k, policy.equal) {
		return false, eval_fail(ev, ev.origin, "L0341", "the map key's equality cannot be evaluated")
	}
	result, ok := eval_invoke(ev, policy.equal, nil, ev.origin, []Eval_Value{a, b})
	if !ok { return false, false }
	if result.kind != .Boolean {
		return false, eval_fail(ev, ev.origin, "L0341", "the map key's equality must return a boolean")
	}
	return result.boolean, true
}

// The value slot for `key`, adding a placeholder entry when it is missing.
@(private = "file")
map_entry_place :: proc(ev: ^Evaluator, m: ^Eval_Value, key: Eval_Value) -> (^Eval_Value, bool) {
	at, ok := map_find(ev, m, key)
	if !ok {
		return nil, false
	}
	if at >= 0 {
		return &m.elements[at + MAP_ENTRY_VALUE], true
	}
	zero, zeroed := zero_value(ev, container_element(ev.k.c, m.type))
	if !zeroed {
		return nil, false
	}
	key_copy, copied := copy_value(ev, key)
	if !copied {
		return nil, false
	}
	grown, err := make([dynamic]Eval_Value, 0, len(m.elements) + 2, ev.alloc)
	if err != nil { return nil, false }
	append(&grown, ..m.elements)
	append(&grown, key_copy, zero)
	if !set_contents(ev, m, grown[:]) {
		return nil, false
	}
	return &m.elements[len(m.elements) - 1], true
}

// ponytail: insertion sort, for the small arrays constants build.
@(private = "file")
eval_sort :: proc(ev: ^Evaluator, elements: []Eval_Value, descending: bool) -> bool {
	for i in 1 ..< len(elements) {
		for j := i; j > 0; j -= 1 {
			left, right := elements[j], elements[j - 1]
			before, ok := eval_compare(ev, .Lt, descending ? right : left, descending ? left : right)
			if !ok {
				return false
			}
			if !before {
				break
			}
			elements[j], elements[j - 1] = elements[j - 1], elements[j]
		}
	}
	return true
}

// A mutating operation needs a place; a read can take any value.
eval_container_op :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol) -> (out: []Eval_Value, success: bool) {
	defer { if !eval_memory_ok(ev) { success = false } }
	if len(v.bound) == 0 || v.bound[0] == nil {
		return nil, false
	}
	self: ^Eval_Value
	if symbol.receiver == .Inout {
		place, ok := eval_place(ev, v.bound[0])
		if !ok { return nil, false }
		self = place
	} else {
		value, ok := eval_expr(ev, v.bound[0])
		if !ok { return nil, false }
		place, allocated := eval_slot(ev, value)
		if !allocated { return nil, false }
		self = place
	}
	element := container_element(ev.k.c, self.type)
	none: []Eval_Value

	results :: proc(ev: ^Evaluator, values: ..Eval_Value) -> []Eval_Value {
		out, err := make([]Eval_Value, len(values), ev.alloc)
		if err != nil { return nil }
		copy(out, values)
		return out
	}

	argument :: proc(ev: ^Evaluator, v: ^Expr_Call, index: int) -> (Eval_Value, bool) {
		if index >= len(v.bound) || v.bound[index] == nil {
			return Eval_Value{}, false
		}
		value, ok := eval_expr(ev, v.bound[index])
		if !ok {
			return Eval_Value{}, false
		}
		return copy_value(ev, value)
	}

	// An `int` argument, with the negative-count fault the runtime raises.
	count_argument :: proc(ev: ^Evaluator, v: ^Expr_Call, index: int) -> (int, bool) {
		value, ok := eval_expr(ev, v.bound[index])
		if !ok {
			return 0, false
		}
		number, fits := bi_to_i64(ev.alloc, value.integer)
		if !fits || number < 0 {
			eval_fail(ev, expr_span(v.bound[index]), "L0343", "a container count cannot be negative")
			return 0, false
		}
		return int(number), true
	}

	fallible := symbol.result == ev.k.c.alloc_result_type
	switch symbol.container_op {
	case .None:
		eval_fail(ev, v.span, "L0405", "a container call has no operation")
		return nil, false

	case .Append:
		if len(v.variadic_spreads) > 0 {
			eval_fail(ev, v.span, "L0341", "a `..` spread has no compile-time meaning")
			return nil, false
		}
		grown, err := make([dynamic]Eval_Value, 0, len(self.elements) + len(v.variadic_elements), ev.alloc)
		if err != nil { return nil, false }
		append(&grown, ..self.elements)
		for written in v.variadic_elements {
			value, value_ok := eval_expr(ev, written)
			if !value_ok {
				return nil, false
			}
			copied, copied_ok := copy_value(ev, value)
			if !copied_ok {
				return nil, false
			}
			append(&grown, copied)
		}
		if !set_contents(ev, self, grown[:]) {
			return nil, false
		}
		if !fallible { return none, true }
		return eval_one(ev, eval_alloc_ok(ev, symbol.result))

	case .Sort, .Reverse_Sort:
		// A slice's receiver is a borrowed header; only a dynamic array is a place.
		if symbol.receiver != .Inout {
			eval_fail(ev, v.span, "L0341", "a slice cannot be sorted at compile time")
			return nil, false
		}
		if resolved_element_order_policy(ev.k.c, element).kind == .Inherent {
			eval_fail(
				ev, v.span, "L0341",
				"a compile-time sort compares with the built-in `<`, and `%s` has its own",
				type_name(ev.k.c, element),
			)
			return nil, false
		}
		if !eval_sort(ev, self.elements, symbol.container_op == .Reverse_Sort) {
			return nil, false
		}
		return none, true

	case .Swap:
		if symbol.receiver != .Inout {
			eval_fail(ev, v.span, "L0341", "a slice cannot be rearranged at compile time")
			return nil, false
		}
		left, left_ok := count_argument(ev, v, 1)
		right, right_ok := count_argument(ev, v, 2)
		if !left_ok || !right_ok {
			return nil, false
		}
		for at in ([2]int{left, right}) {
			if at >= len(self.elements) {
				eval_fail(ev, v.span, "L0361", "index %d is out of range", at)
				return nil, false
			}
		}
		self.elements[left], self.elements[right] = self.elements[right], self.elements[left]
		return none, true

	case .Insert:
		at, at_ok := count_argument(ev, v, 1)
		value, value_ok := argument(ev, v, 2)
		if !at_ok || !value_ok {
			return nil, false
		}
		if at > len(self.elements) {
			eval_fail(ev, v.span, "L0361", "index %d is out of range", at)
			return nil, false
		}
		grown, err := make([dynamic]Eval_Value, 0, len(self.elements) + 1, ev.alloc)
		if err != nil { return nil, false }
		append(&grown, ..self.elements[:at])
		append(&grown, value)
		append(&grown, ..self.elements[at:])
		if !set_contents(ev, self, grown[:]) {
			return nil, false
		}
		if !fallible { return none, true }
		return eval_one(ev, eval_alloc_ok(ev, symbol.result))

	case .Pop:
		if len(self.elements) == 0 {
			return eval_one(ev, eval_option(ev, symbol.result, Eval_Value{}, false))
		}
		last := self.elements[len(self.elements) - 1]
		self.elements = self.elements[:len(self.elements) - 1]
		return eval_one(ev, eval_option(ev, symbol.result, last, true))

	case .Remove, .Remove_Unordered:
		at, at_ok := count_argument(ev, v, 1)
		if !at_ok {
			return nil, false
		}
		if at >= len(self.elements) {
			eval_fail(ev, v.span, "L0361", "index %d is out of range", at)
			return nil, false
		}
		taken := self.elements[at]
		kept, err := make([dynamic]Eval_Value, 0, len(self.elements) - 1, ev.alloc)
		if err != nil { return nil, false }
		if symbol.container_op == .Remove_Unordered {
			// The last element moves into the hole.
			append(&kept, ..self.elements[:len(self.elements) - 1])
			if at < len(kept) {
				kept[at] = self.elements[len(self.elements) - 1]
			}
		} else {
			append(&kept, ..self.elements[:at])
			append(&kept, ..self.elements[at + 1:])
		}
		if !set_contents(ev, self, kept[:]) {
			return nil, false
		}
		return results(ev, taken), true

	case .Clear, .Map_Clear:
		self.elements = nil
		return none, true

	case .Resize:
		size, size_ok := count_argument(ev, v, 1)
		if !size_ok {
			return nil, false
		}
		next, err := make([dynamic]Eval_Value, 0, size, ev.alloc)
		if err != nil { return nil, false }
		for index in 0 ..< size {
			if index < len(self.elements) {
				append(&next, self.elements[index])
				continue
			}
			zero, zeroed := zero_value(ev, element)
			if !zeroed {
				return nil, false
			}
			append(&next, zero)
		}
		if !set_contents(ev, self, next[:]) {
			return nil, false
		}
		if !fallible { return none, true }
		return eval_one(ev, eval_alloc_ok(ev, symbol.result))

	case .Reserve, .Shrink, .Map_Reserve,
	     .Map_Shrink:
		// No allocation here, so these do nothing observable.
		if _, ok := count_argument(ev, v, 1); !ok {
			return nil, false
		}
		if !fallible { return none, true }
		return eval_one(ev, eval_alloc_ok(ev, symbol.result))

	case .Map_Entries, .Map_Keys, .Map_Values:
		eval_fail(ev, v.span, "L0341", "a map view has no compile-time meaning; iterate the map itself")
		return nil, false

	case .Map_Lookup_Value:
		key, key_ok := argument(ev, v, 1)
		if !key_ok {
			return nil, false
		}
		at, found_ok := map_find(ev, self, key)
		if !found_ok {
			return nil, false
		}
		if at < 0 {
			return eval_one(ev, eval_option(ev, symbol.result, Eval_Value{}, false))
		}
		copied, copied_ok := copy_value(ev, self.elements[at + MAP_ENTRY_VALUE])
		if !copied_ok {
			return nil, false
		}
		return eval_one(ev, eval_option(ev, symbol.result, copied, true))

	case .Map_Find:
		key, key_ok := argument(ev, v, 1)
		if !key_ok {
			return nil, false
		}
		at, found_ok := map_find(ev, self, key)
		if !found_ok {
			return nil, false
		}
		if at < 0 {
			return eval_one(ev, eval_option(ev, symbol.result, Eval_Value{}, false))
		}
		pointer := Eval_Value {
			kind   = .Nil,
			type   = union_variant_payload(ev.k.c, symbol.result, union_index_of(ev.k.c, symbol.result, "some")),
			target = &self.elements[at + MAP_ENTRY_VALUE],
		}
		return eval_one(ev, eval_option(ev, symbol.result, pointer, true))

	// design.md "Map container operations": `elem` is stored only for a new key.
	case .Map_Find_Or_Insert:
		key, key_ok := argument(ev, v, 1)
		value, value_ok := argument(ev, v, 2)
		if !key_ok || !value_ok {
			return nil, false
		}
		before := len(self.elements)
		slot, slot_ok := map_entry_place(ev, self, key)
		if !slot_ok {
			return nil, false
		}
		if len(self.elements) > before {
			slot^ = value
		}
		return eval_one(ev, eval_map_slot(ev, symbol.result, slot))

	case .Map_Try_Insert:
		key, key_ok := argument(ev, v, 1)
		value, value_ok := argument(ev, v, 2)
		if !key_ok || !value_ok {
			return nil, false
		}
		slot, slot_ok := map_entry_place(ev, self, key)
		if !slot_ok {
			return nil, false
		}
		slot^ = value
		return eval_one(ev, eval_alloc_ok(ev, symbol.result))

	case .Map_Remove:
		key, key_ok := argument(ev, v, 1)
		if !key_ok {
			return nil, false
		}
		at, found_ok := map_find(ev, self, key)
		if !found_ok {
			return nil, false
		}
		if at < 0 {
			return eval_one(ev, eval_option(ev, symbol.result, Eval_Value{}, false))
		}
		taken := self.elements[at + MAP_ENTRY_VALUE]
		kept, err := make([dynamic]Eval_Value, 0, len(self.elements) - 2, ev.alloc)
		if err != nil { return nil, false }
		append(&kept, ..self.elements[:at])
		append(&kept, ..self.elements[at + 2:])
		if !set_contents(ev, self, kept[:]) {
			return nil, false
		}
		return eval_one(ev, eval_option(ev, symbol.result, taken, true))
	}
	return nil, false
}

@(private = "file")
eval_map_read :: proc(ev: ^Evaluator, v: ^Expr_Index, m: ^Eval_Value) -> (Eval_Value, bool) {
	key, key_ok := eval_expr(ev, v.indices[0])
	if !key_ok {
		return Eval_Value{}, false
	}
	at, found := map_find(ev, m, key)
	if !found {
		return Eval_Value{}, false
	}
	if at >= 0 {
		return m.elements[at + MAP_ENTRY_VALUE], true
	}
	// What panics at run time is a compile-time error.
	eval_fail(ev, v.span, "L0343", "this key is not in the map")
	return Eval_Value{}, false
}

// `key in m`.
@(private = "file")
eval_map_membership :: proc(ev: ^Evaluator, v: ^Expr_Binary) -> (Eval_Value, bool) {
	key, key_ok := eval_expr(ev, v.lhs)
	subject, subject_ok := eval_expr(ev, v.rhs)
	if !key_ok || !subject_ok {
		return Eval_Value{}, false
	}
	at, found := map_find(ev, &subject, key)
	if !found {
		return Eval_Value{}, false
	}
	present := at >= 0
	return Eval_Value{kind = .Boolean, type = TYPE_BOOL, boolean = present}, true
}

// The storage an expression denotes, for assignment, `&`, and `inout`.
eval_place :: proc(ev: ^Evaluator, e: Expr) -> (^Eval_Value, bool) {
	if e == nil {
		return nil, false
	}
	if !eval_step(ev, expr_span(e)) {
		return nil, false
	}
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
		base, ok := eval_aggregate_place(ev, v.operand)
		if !ok {
			return nil, false
		}
		return eval_field(ev, v, base.elements)

	case ^Expr_Index:
		base, ok := eval_aggregate_place(ev, v.operand)
		if !ok {
			return nil, false
		}
		// design.md: only `m[key] = elem` inserts (`map_inserts`).
		if type_is_map(ev.k.c, base.type) {
			key, key_ok := eval_expr(ev, v.indices[0])
			if !key_ok {
				return nil, false
			}
			if !v.map_inserts {
				at, found := map_find(ev, base, key)
				if !found {
					return nil, false
				}
				if at < 0 {
					eval_fail(ev, v.span, "L0343", "this key is not in the map")
					return nil, false
				}
				return &base.elements[at + MAP_ENTRY_VALUE], true
			}
			return map_entry_place(ev, base, key)
		}
		index_value, index_ok := eval_expr(ev, v.indices[0])
		if !index_ok {
			return nil, false
		}
		index, fits := bi_to_i64(ev.alloc, index_value.integer)
		if !fits || index < 0 || int(index) >= len(base.elements) {
			eval_fail(ev, expr_span(v.indices[0]), "L0361", "index %s is out of range", bi_text(ev.alloc, index_value.integer))
			return nil, false
		}
		return &base.elements[index], true

	case ^Expr_Postfix:
		pointer, ok := eval_expr(ev, v.operand)
		if !ok {
			return nil, false
		}
		return eval_deref(ev, pointer, v.op_span)

	case ^Expr_Composite:
		value, ok := eval_composite(ev, v)
		if !ok {
			return nil, false
		}
		return eval_slot(ev, value)
	}
	eval_fail(ev, expr_span(e), "L0341", "this expression is not compile-time storage")
	return nil, false
}

@(private = "file")
eval_deref :: proc(ev: ^Evaluator, pointer: Eval_Value, span: Span) -> (^Eval_Value, bool) {
	if pointer.target == nil {
		eval_fail(ev, span, "L0343", "this dereferences a nil pointer")
		return nil, false
	}
	return pointer.target, true
}

// The selected field among an aggregate's elements.
@(private = "file")
eval_field :: proc(ev: ^Evaluator, v: ^Expr_Selector, elements: []Eval_Value) -> (^Eval_Value, bool) {
	field := symbol_of(ev.k.c, v.resolution.symbol)
	if field == nil || int(field.index) >= len(elements) {
		eval_fail(ev, v.span, "L0341", "`%s` has no compile-time value here", v.name.text)
		return nil, false
	}
	return &elements[field.index], true
}

// The aggregate a selection reads, where `p.f` means `p^.f`.
@(private = "file")
eval_aggregate_value :: proc(ev: ^Evaluator, operand: Expr) -> (Eval_Value, bool) {
	value, ok := eval_expr(ev, operand)
	if !ok {
		return Eval_Value{}, false
	}
	if type_is_pointer(ev.k.c, expr_base(operand).type) {
		target, live := eval_deref(ev, value, expr_span(operand))
		if !live {
			return Eval_Value{}, false
		}
		return target^, true
	}
	return value, true
}

// The storage a selection writes through, where `p.f` means `p^.f`.
@(private = "file")
eval_aggregate_place :: proc(ev: ^Evaluator, operand: Expr) -> (^Eval_Value, bool) {
	if type_is_pointer(ev.k.c, expr_base(operand).type) {
		pointer, ok := eval_expr(ev, operand)
		if !ok {
			return nil, false
		}
		return eval_deref(ev, pointer, expr_span(operand))
	}
	return eval_place(ev, operand)
}

// A payloadless variant keeps an `Invalid` payload, so every arm has one element.
@(private = "file")
eval_union :: proc(ev: ^Evaluator, type: Type_Id, variant: int, payload: Eval_Value) -> (Eval_Value, bool) {
	elements, allocated := eval_elements(ev, 1)
	if !allocated {
		return Eval_Value{}, false
	}
	elements[0] = payload
	return Eval_Value{kind = .Aggregate, type = type, variant = variant, elements = elements}, true
}

@(private = "file")
eval_named_union :: proc(ev: ^Evaluator, type: Type_Id, name: string, payload: Eval_Value) -> (Eval_Value, bool) {
	return eval_union(ev, type, union_index_of(ev.k.c, type, name), payload)
}

// The fallback is evaluated only on failure, as at run time.
@(private = "file")
eval_or_else :: proc(ev: ^Evaluator, v: ^Expr_Or_Else) -> (Eval_Value, bool) {
	value, ok := eval_expr(ev, v.value)
	if !ok {
		return Eval_Value{}, false
	}
	shape, fallible := fallible_of(ev.k, expr_base(v.value).type)
	if !fallible {
		eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
		return Eval_Value{}, false
	}
	if value.variant == shape.failure {
		return eval_expr(ev, v.fallback)
	}
	return eval_union_payload(value, INVALID_TYPE), true
}

// On failure this returns false without setting `ev.failed`; the statement
// turns that into `.Return`.
@(private = "file")
eval_or_return :: proc(ev: ^Evaluator, v: ^Expr_Postfix) -> (Eval_Value, bool) {
	value, ok := eval_expr(ev, v.operand)
	if !ok {
		return Eval_Value{}, false
	}
	shape, fallible := fallible_of(ev.k, expr_base(v.operand).type)
	frame := current_frame(ev)
	if !fallible || frame == nil || frame.result_slot == nil {
		eval_fail(ev, v.op_span, "L0341", "this `or_return` has no compile-time target")
		return Eval_Value{}, false
	}
	if value.variant != shape.failure {
		if shape.info.variants[shape.success] == TYPE_VOID {
			return zero_value(ev, ev.k.c.unit_type)
		}
		return eval_union_payload(value, INVALID_TYPE), true
	}

	target, target_ok := fallible_of(ev.k, frame.result_slot.type)
	if !target_ok {
		eval_fail(ev, v.op_span, "L0341", "this `or_return` has no compile-time target")
		return Eval_Value{}, false
	}
	payload := eval_union_payload(value, INVALID_TYPE)
	into := target.info.variants[target.failure]
	if into != TYPE_VOID {
		payload, ok = copy_value(ev, payload)
		if !ok {
			return Eval_Value{}, false
		}
		payload.type = into
	} else {
		payload = Eval_Value{kind = .Invalid, type = TYPE_VOID}
	}
	wrapped, wrapped_ok := eval_union(ev, frame.result_slot.type, target.failure, payload)
	if !wrapped_ok {
		return Eval_Value{}, false
	}
	frame.result = wrapped
	frame.returning = true
	return Eval_Value{}, false
}

// `.ok(Unit{})`: an allocating container operation that had nothing to allocate.
@(private = "file")
eval_alloc_ok :: proc(ev: ^Evaluator, type: Type_Id) -> (Eval_Value, bool) {
	return eval_named_union(ev, type, "ok", Eval_Value{kind = .Aggregate, type = ev.k.c.unit_type})
}

// `find_or_insert`'s `^mut V`, wrapped in `.ok` for the `try_` spelling.
@(private = "file")
eval_map_slot :: proc(ev: ^Evaluator, result: Type_Id, slot: ^Eval_Value) -> (Eval_Value, bool) {
	if type_is_union(ev.k.c, result) {
		payload := union_variant_payload(ev.k.c, result, union_index_of(ev.k.c, result, "ok"))
		return eval_named_union(ev, result, "ok", Eval_Value{kind = .Nil, type = payload, target = slot})
	}
	return Eval_Value{kind = .Nil, type = result, target = slot}, true
}

// `.some(payload)` or `.none`, for a container read that may find nothing.
@(private = "file")
eval_option :: proc(ev: ^Evaluator, type: Type_Id, payload: Eval_Value, present: bool) -> (Eval_Value, bool) {
	if !present {
		return eval_named_union(ev, type, "none", Eval_Value{})
	}
	return eval_named_union(ev, type, "some", payload)
}

// One result, in the evaluator's arena so it outlives this frame.
@(private = "file")
eval_one :: proc(ev: ^Evaluator, value: Eval_Value, built := true) -> ([]Eval_Value, bool) {
	if !built {
		return nil, false
	}
	out, err := make([]Eval_Value, 1, ev.alloc)
	if err != nil {
		return nil, false
	}
	out[0] = value
	return out, true
}

@(private = "file")
eval_union_construct :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (Eval_Value, bool) {
	if len(v.bound) != 1 || v.bound[0] == nil {
		eval_fail(ev, v.span, "L0341", "a union construction needs its payload")
		return Eval_Value{}, false
	}
	payload, ok := eval_expr(ev, v.bound[0])
	if !ok {
		return Eval_Value{}, false
	}
	copied, copied_ok := copy_value(ev, payload)
	if !copied_ok {
		return Eval_Value{}, false
	}
	return eval_union(ev, v.type, v.operation.(Call_Union_Construct).index, copied)
}

// The payload of `value`, or the whole union when the case binds the union
// type itself (a grouped or default case).
@(private = "file")
eval_union_payload :: proc(value: Eval_Value, binding_type: Type_Id) -> Eval_Value {
	if binding_type == value.type || len(value.elements) == 0 {
		return value
	}
	return value.elements[0]
}

@(private = "file")
eval_call :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (Eval_Value, bool) {
	#partial switch operation in v.operation {
	case Call_Enum_From_Int:
		value, ok := eval_expr(ev, v.bound[0])
		if !ok { return Eval_Value{}, false }
		candidate := Const_Value{kind = .Integer, integer = value.integer}
		if enum_member_by_value(ev.k.c, operation.type, candidate) == INVALID_SYMBOL {
			return eval_named_union(ev, v.type, "none", Eval_Value{})
		}
		value.type = operation.type
		return eval_named_union(ev, v.type, "some", value)
	case Call_Conversion, Call_Dyn_Conversion:
		return eval_conversion(ev, v)
	case Call_Union_Construct:
		return eval_union_construct(ev, v)
	case Call_Extract:
		eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
		return Eval_Value{}, false
	case Call_Text:
		return eval_text_op(ev, v)
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Sort_By, Call_Simd_Reduce:
		callee := symbol_of(ev.k.c, v.resolution.symbol)
		if callee != nil && callee.kind == .Builtin { return eval_builtin(ev, v, callee) }
	case nil:
		eval_fail(ev, v.span, "L0341", "an unchecked call has no compile-time meaning")
		return Eval_Value{}, false
	}
	// Compiler-written members run directly.
	if chosen := symbol_of(ev.k.c, v.resolution.chosen_overload); chosen != nil &&
	   (chosen.synth == .Standard_Len || chosen.synth == .Standard_Cap || chosen.synth == .Standard_Hash) {
		return eval_standard_customization(ev, v, chosen)
	}
	if chosen := symbol_of(ev.k.c, v.resolution.chosen_overload); chosen != nil && chosen.synth == .Container_Op {
		results, ok := eval_container_op(ev, v, chosen)
		if !ok {
			return Eval_Value{}, false
		}
		if len(results) == 0 {
			return Eval_Value{kind = .Invalid, type = TYPE_VOID}, true
		}
		return results[0], true
	}

	target, target_ok := eval_call_target(ev, v)
	if !target_ok {
		return Eval_Value{}, false
	}
	// A variant constructor has no body: its payload becomes the variant.
	if sym := symbol_of(ev.k.c, target); sym != nil && sym.synth == .Variant_Construct && len(v.bound) == 1 {
		payload, payload_ok := eval_expr(ev, v.bound[0])
		if !payload_ok {
			return Eval_Value{}, false
		}
		return eval_union(ev, sym.result, union_variant_index(ev.k.c, sym.result, sym.name), payload)
	}

	result, ok := eval_invoke(ev, target, v.bound, v.span, order = v.bound_order)
	if !ok {
		return Eval_Value{}, false
	}
	if result.type == INVALID_TYPE {
		return Eval_Value{kind = .Invalid, type = TYPE_VOID}, true
	}
	return result, true
}

// design.md "String iteration": the views copy nothing.
@(private = "file")
eval_text_op :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (Eval_Value, bool) {
	if len(v.bound) == 0 || v.bound[0] == nil {
		eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
		return Eval_Value{}, false
	}
	subject, ok := eval_expr(ev, v.bound[0])
	if !ok {
		return Eval_Value{}, false
	}
	#partial switch v.operation.(Call_Text).op {
	case .Byte_Len:
		return eval_count_value(ev, len(subject.text)), true

	case .Rune_Count:
		return eval_count_value(ev, utf8.rune_count_in_string(subject.text)), true

	case .Bytes:
		elements, allocated := eval_elements(ev, len(subject.text))
		if !allocated {
			return Eval_Value{}, false
		}
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
eval_standard_customization :: proc(ev: ^Evaluator, v: ^Expr_Call, chosen: ^Symbol) -> (Eval_Value, bool) {
	#partial switch chosen.synth {
	case .Standard_Len:
		subject, ok := eval_expr(ev, v.bound[0])
		if !ok { return Eval_Value{}, false }
		count := len(subject.elements)
		if subject.kind == .String {
			count = len(subject.text)
		} else if type_is_map(ev.k.c, subject.type) {
			count /= 2
		}
		return Eval_Value{kind = .Integer, type = TYPE_INT, integer = bi_from_i64(ev.alloc, i64(count))}, true

	case .Standard_Cap:
		eval_fail(ev, v.span, "L0595", "`cap` has no compile-time meaning: a capacity is a property of an allocation, and there is none here")
		return Eval_Value{}, false

	case .Standard_Hash:
		value, value_ok := eval_expr(ev, v.bound[0])
		seed, seed_ok := eval_expr(ev, v.bound[1])
		if !value_ok || !seed_ok { return Eval_Value{}, false }
		frozen_value, froze_value := freeze(ev, value, ev.alloc)
		frozen_seed, froze_seed := freeze(ev, seed, ev.alloc)
		if !froze_value || !froze_seed { return Eval_Value{}, false }
		start, _ := bi_to_u64(ev.alloc, bi_wrap(ev.alloc, frozen_seed.integer, 64, false))
		mixed := hash_const(ev.k.c, frozen_value, expr_base(v.bound[0]).type, start, ev.alloc)
		return Eval_Value{kind = .Integer, type = TYPE_UINT, integer = bi_from_u64(ev.alloc, mixed)}, true

	case:
		eval_fail(ev, v.span, "L0341", "`%s` has no compile-time meaning", identifier_text(ev.k.c, chosen.name))
		return Eval_Value{}, false
	}
}

// Direct and indirect calls alike.
@(private = "file")
eval_call_target :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (Symbol_Id, bool) {
	target := v.resolution.symbol
	if target == INVALID_SYMBOL {
		value, ok := eval_expr(ev, v.callee)
		if !ok {
			return INVALID_SYMBOL, false
		}
		if value.proc_value == INVALID_SYMBOL {
			eval_fail(ev, expr_span(v.callee), "L0343", "this calls a nil procedure value")
			return INVALID_SYMBOL, false
		}
		target = value.proc_value
	}
	if !ensure_proc_typed_for_eval(ev.k, target) {
		eval_fail(
			ev,
			v.span,
			"L0344",
			"`%s` cannot be called at compile time: its body is still being checked",
			eval_proc_name(ev.k.c, target),
		)
		return INVALID_SYMBOL, false
	}
	return target, true
}

// Binds arguments, runs the body, unwinds `defer`, and hands back the one
// declared result, or an invalid value when the procedure has none.
@(private = "file")
eval_invoke :: proc(ev: ^Evaluator, symbol_id: Symbol_Id, args: []Expr, site: Span, values: []Eval_Value = nil, order: []int = nil) -> (out: Eval_Value, success: bool) {
	defer { if !eval_memory_ok(ev) { success = false } }
	symbol := symbol_of(ev.k.c, symbol_id)
	if symbol == nil {
		return Eval_Value{}, false
	}
	literal := eval_proc_literal(symbol)
	if literal == nil || literal.body == nil {
		eval_fail(ev, site, "L0341", "`%s` has no body to evaluate", eval_proc_name(ev.k.c, symbol_id))
		return Eval_Value{}, false
	}
	if len(ev.frames) >= EVAL_MAX_DEPTH {
		eval_fail(ev, site, "L0342", "compile-time evaluation exceeded a call depth of %d", EVAL_MAX_DEPTH)
		return Eval_Value{}, false
	}

	frame := new(Eval_Frame, ev.alloc)
	if frame == nil { return Eval_Value{}, false }
	frame.symbol = symbol_id
	frame.site = site
	frame.locals = make(map[Symbol_Id]^Eval_Value, 8, ev.alloc)
	frame.defers = make([dynamic]Stmt, 0, 4, ev.alloc)
	if !eval_memory_ok(ev) { return Eval_Value{}, false }

	info := type_of(ev.k.c, symbol.proc_type)
	// A default runs in the callee's frame, since it may name an earlier
	// parameter; a written argument runs in the caller's.
	append(&ev.frames, frame)
	if !eval_memory_ok(ev) { return Eval_Value{}, false }
	// design.md "Evaluation order": `order` is the schedule when named
	// arguments reorder it.
	for step in 0 ..< max(len(args), len(values)) {
		index := step
		if step < len(order) {
			index = order[step]
		}
		argument := index < len(args) ? args[index] : Expr(nil)
		if index >= len(symbol.param_symbols) {
			continue
		}
		binding := symbol.param_symbols[index]
		mode := info != nil && index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		is_default := argument != nil && symbol.param_defaults != nil && index < len(symbol.param_defaults) &&
			argument == symbol.param_defaults[index]

		if !is_default {
			pop(&ev.frames)
		}
		slot: ^Eval_Value
		ok := true
		if values != nil {
			copied: Eval_Value
			copied, ok = copy_value(ev, values[index])
			if ok { slot, ok = eval_slot(ev, copied) }
		} else if mode == .Inout || (mode == .Borrow && argument != nil && expr_base(argument).addressable) {
			slot, ok = eval_place(ev, argument)
		} else {
			value: Eval_Value
			value, ok = eval_expr(ev, argument)
			if ok {
				copied: Eval_Value
				copied, ok = copy_value(ev, value)
				if ok {
					slot, ok = eval_slot(ev, copied)
				}
			}
		}
		// `self: ^Self` binds a pointer to the receiver.
		if bound := symbol_of(ev.k.c, binding); ok && mode == .Borrow && bound != nil && bound.type != symbol.params[index] {
			slot, ok = eval_slot(ev, Eval_Value{kind = .Nil, type = bound.type, target = slot})
		}
		if !is_default {
			append(&ev.frames, frame)
		}
		if !ok {
			pop(&ev.frames)
			return Eval_Value{}, false
		}
		if binding != INVALID_SYMBOL {
			frame.locals[binding] = slot
		}
	}

	// Zeroed, so `or_return` can publish into it.
	if symbol.result != INVALID_TYPE {
		value, zeroed := zero_value(ev, symbol.result)
		if !zeroed {
			pop(&ev.frames)
			return Eval_Value{}, false
		}
		slot, allocated := eval_slot(ev, value)
		if !allocated {
			pop(&ev.frames)
			return Eval_Value{}, false
		}
		frame.result_slot = slot
		frame.result = value
	}

	flow := eval_block(ev, literal.body)
	pop(&ev.frames)
	if flow == .Fail {
		return Eval_Value{}, false
	}
	return frame.result, true
}

@(private = "file")
eval_proc_literal :: proc(symbol: ^Symbol) -> ^Expr_Proc {
	if symbol.decl != nil {
		return decl_proc_literal(symbol.decl)
	}
	return symbol.proc_literal
}

@(private = "file")
eval_conversion :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (Eval_Value, bool) {
	source, ok := eval_expr(ev, v.bound[0])
	if !ok {
		return Eval_Value{}, false
	}
	c := ev.k.c
	// A distinct type and what it wraps share a representation.
	if type_underlying(c, expr_base(v.bound[0]).type) == type_underlying(c, v.type) {
		retyped := source
		retyped.type = v.type
		return retyped, true
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
		frozen, froze := freeze(ev, source, ev.alloc)
		if !froze {
			return Eval_Value{}, false
		}
		operand = frozen
	}
	converted, fits := convert_const(c, operand, v.type, true, ev.alloc)
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
eval_builtin :: proc(ev: ^Evaluator, v: ^Expr_Call, symbol: ^Symbol) -> (Eval_Value, bool) {
	void := Eval_Value{kind = .Invalid, type = TYPE_VOID}
	#partial switch symbol.builtin {
	case .Assert:
		condition, ok := eval_expr(ev, v.bound[0])
		if !ok {
			return Eval_Value{}, false
		}
		if condition.boolean {
			return void, true
		}
		eval_fail(ev, v.span, "L0343", "compile-time assertion failed%s", eval_message(ev, v, 1))
		return Eval_Value{}, false

	case .Panic:
		eval_fail(ev, v.span, "L0343", "compile-time panic%s", eval_message(ev, v, 0))
		return Eval_Value{}, false

	case .Drop:
		// Nothing to release here; only the zero write applies.
		slot, ok := eval_place(ev, v.bound[0])
		if !ok {
			return Eval_Value{}, false
		}
		zeroed, made := zero_value(ev, slot.type)
		if !made {
			return Eval_Value{}, false
		}
		slot^ = zeroed
		return void, true

	case .Unsafe_Take:
		place, ok := eval_place(ev, v.bound[0])
		if !ok {
			return Eval_Value{}, false
		}
		value := place^
		place^ = Eval_Value{kind = .Invalid, type = value.type}
		return value, true

	case .Unsafe_Write:
		place, ok := eval_place(ev, v.bound[0])
		if !ok {
			return Eval_Value{}, false
		}
		value: Eval_Value
		if moved, is_move := v.bound[1].(^Expr_Move); is_move {
			source, source_ok := eval_place(ev, moved.value)
			if !source_ok {
				return Eval_Value{}, false
			}
			value = source^
			source^ = Eval_Value{kind = .Invalid, type = value.type}
		} else {
			computed, computed_ok := eval_expr(ev, v.bound[1])
			if !computed_ok {
				return Eval_Value{}, false
			}
			value = computed
			if expression_is_borrowed_place(v.bound[1]) {
				value, computed_ok = copy_value(ev, computed)
				if !computed_ok {
					return Eval_Value{}, false
				}
			}
		}
		value.type = place.type
		place^ = value
		return void, true

	case .Unsafe_Forget:
		// No hook runs; the slot is left inert.
		if moved, is_move := v.bound[0].(^Expr_Move); is_move {
			slot, ok := eval_place(ev, moved.value)
			if !ok {
				return Eval_Value{}, false
			}
			if zeroed, made := zero_value(ev, slot.type); made {
				slot^ = zeroed
			}
			return void, true
		}
		if _, ok := eval_expr(ev, v.bound[0]); !ok {
			return Eval_Value{}, false
		}
		return void, true

	case .Unsafe_Transmute:
		// The checker's fold, for an operand that is a local.
		operand, ok := eval_expr(ev, v.bound[0])
		if !ok {
			return Eval_Value{}, false
		}
		frozen, froze := freeze(ev, operand, ev.alloc)
		if !froze {
			return Eval_Value{}, false
		}
		source := expr_base(v.bound[0]).type
		raw, encoded := const_scalar_pattern(ev.k.c, frozen, source)
		result, status := Const_Value{}, Const_Pattern.Unfoldable
		if encoded {
			result, status = const_from_pattern(ev.k.c, raw, v.type)
		}
		switch status {
		case .Folded:
			return scalar(result, v.type), true
		case .Invalid:
			eval_fail(
				ev, v.span, "L0688",
				"this bit pattern is not a valid `%s`", type_name(ev.k.c, v.type),
			)
		case .Unfoldable:
			eval_fail(
				ev, v.span, "L0688",
				"`unsafe.transmute` has no compile-time meaning from `%s` to `%s`",
				type_name(ev.k.c, source), type_name(ev.k.c, v.type),
			)
		}
		return Eval_Value{}, false

	// design.md "`core:simd`": a vector and its array have the same lanes in the
	// same order, so the conversion only retypes them.
	case .Simd_Cast:
		operand, ok := eval_expr(ev, v.bound[0])
		if !ok {
			return Eval_Value{}, false
		}
		out, copied := copy_value(ev, operand)
		out.type = v.type
		return out, copied

	case .Simd_Select:
		mask, mask_ok := eval_expr(ev, v.bound[0])
		left, left_ok := eval_expr(ev, v.bound[1])
		right, right_ok := eval_expr(ev, v.bound[2])
		if !mask_ok || !left_ok || !right_ok {
			return Eval_Value{}, false
		}
		count := int(underlying_info(ev.k.c, v.type).count)
		elements, allocated := eval_elements(ev, count)
		if !allocated {
			return Eval_Value{}, false
		}
		for index in 0 ..< count {
			chosen := left if eval_simd_lane(mask, index).boolean else right
			elements[index] = eval_simd_lane(chosen, index)
		}
		return Eval_Value{kind = .Aggregate, type = v.type, elements = elements}, true

	case .Simd_Reduce:
		return eval_simd_reduce(ev, v)
	}
	eval_fail(
		ev,
		v.span,
		"L0341",
		"`%s` has no compile-time meaning",
		identifier_text(ev.k.c, symbol.name),
	)
	return Eval_Value{}, false
}

// The optional constant message of `assert`/`panic`.
@(private = "file")
eval_message :: proc(ev: ^Evaluator, v: ^Expr_Call, index: int) -> string {
	if index >= len(v.bound) || v.bound[index] == nil {
		return ""
	}
	base := expr_base(v.bound[index])
	if base == nil || !base.is_const || base.const_value.kind != .String {
		return ""
	}
	return fmt.aprintf(": %s", base.const_value.text, allocator = ev.k.c.semantic_allocator)
}

eval_block :: proc(ev: ^Evaluator, b: ^Block) -> Eval_Flow {
	return b == nil ? .Normal : eval_stmts(ev, b.stmts, true)
}

// Runs `stmts` until one leaves; a scope then runs the `defer`s it registered,
// in reverse.
@(private = "file")
eval_stmts :: proc(ev: ^Evaluator, stmts: []Stmt, scope: bool) -> Eval_Flow {
	frame := current_frame(ev)
	mark := frame == nil ? 0 : len(frame.defers)
	flow := Eval_Flow.Normal
	for stmt in stmts {
		flow = eval_stmt(ev, stmt)
		if flow != .Normal {
			break
		}
	}
	if scope && frame != nil {
		flow = run_defers(ev, frame, mark, flow)
	}
	return flow
}

@(private = "file")
run_defers :: proc(ev: ^Evaluator, frame: ^Eval_Frame, mark: int, flow: Eval_Flow) -> Eval_Flow {
	result := flow
	for index := len(frame.defers) - 1; index >= mark; index -= 1 {
		if eval_stmt(ev, frame.defers[index]) == .Fail {
			result = .Fail
		}
	}
	resize(&frame.defers, mark)
	return result
}

eval_stmt :: proc(ev: ^Evaluator, stmt: Stmt) -> Eval_Flow {
	result := eval_stmt_inner(ev, stmt)
	if !eval_memory_ok(ev) {
		return .Fail
	}
	if result == .Fail {
		// An `or_return`'s signal is spent here, so a later failure is not a return.
		if frame := current_frame(ev); frame != nil && frame.returning && !ev.failed {
			frame.returning = false
			return .Return
		}
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
		if frame := current_frame(ev); frame != nil {
			append(&frame.defers, s.stmt)
		}
		return .Normal

	case ^Stmt_Return:
		return eval_return(ev, s)

	case ^Stmt_Branch:
		return s.kind == .Break ? .Break : .Continue

	case ^Block:
		return eval_block(ev, s)

	case ^Stmt_When:
		// Not a scope: its `defer`s belong to the surrounding one.
		selected := when_selected_block(s)
		return selected == nil ? .Normal : eval_stmts(ev, selected.stmts, false)

	case ^Stmt_Foreach:
		return eval_foreach(ev, s)
	}
	eval_fail(ev, stmt_span(stmt), "L0341", "this statement has no compile-time meaning")
	return .Fail
}

@(private = "file")
eval_local_decl :: proc(ev: ^Evaluator, d: ^Decl) -> Eval_Flow {
	frame := current_frame(ev)
	if frame == nil {
		eval_fail(ev, d.span, "L0341", "a declaration needs a compile-time frame")
		return .Fail
	}
	if d.destructure.active {
		values, ok := eval_destructure(ev, &d.destructure, d.values[0])
		if !ok {
			return .Fail
		}
		for symbol_id, index in d.symbols {
			if !bind_local(ev, frame, symbol_id, values[index]) {
				return .Fail
			}
		}
		return .Normal
	}
	for symbol_id, index in d.symbols {
		symbol := symbol_of(ev.k.c, symbol_id)
		type := symbol == nil ? INVALID_TYPE : symbol.type
		value, zeroed := zero_value(ev, type)
		if !zeroed {
			return .Fail
		}
		if index < len(d.values) && d.values[index] != nil {
			computed, ok := eval_expr(ev, d.values[index])
			if !ok {
				return .Fail
			}
			value, ok = copy_value(ev, computed)
			if !ok {
				return .Fail
			}
		}
		if !bind_local(ev, frame, symbol_id, value) {
			return .Fail
		}
	}
	return .Normal
}

@(private = "file")
bind_local :: proc(ev: ^Evaluator, frame: ^Eval_Frame, symbol_id: Symbol_Id, value: Eval_Value) -> bool {
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
eval_destructure :: proc(ev: ^Evaluator, plan: ^Destructure, operand: Expr) -> ([]Eval_Value, bool) {
	record, ok := eval_expr(ev, operand)
	if !ok {
		return nil, false
	}
	if record.kind != .Aggregate || len(record.elements) != len(plan.fields) {
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
		if !plan.from_place {
			values[index] = record.elements[index]
			continue
		}
		copied, copied_ok := copy_value(ev, record.elements[index])
		if !copied_ok {
			return nil, false
		}
		values[index] = copied
	}
	return values, true
}

@(private = "file")
eval_assign :: proc(ev: ^Evaluator, s: ^Stmt_Assign) -> Eval_Flow {
	if s.operator != INVALID_SYMBOL || s.place_setter != INVALID_SYMBOL {
		eval_fail(ev, s.op_span, "L0341", "a user operator has no compile-time meaning yet")
		return .Fail
	}
	if s.op != .Assign {
		return eval_compound_assign(ev, s)
	}
	if s.destructure.active {
		values, ok := eval_destructure(ev, &s.destructure, s.rhs[0])
		if !ok {
			return .Fail
		}
		// design.md "Assignment statements": values, then destinations, then writes.
		slots, slot_err := make([]^Eval_Value, len(s.lhs), ev.alloc)
		if slot_err != nil {
			return .Fail
		}
		for target, index in s.lhs {
			if is_discard(target) {
				continue
			}
			slot, place_ok := eval_place(ev, target)
			if !place_ok {
				return .Fail
			}
			slots[index] = slot
		}
		for slot, index in slots {
			if slot != nil {
				slot^ = values[index]
			}
		}
		return .Normal
	}
	values, value_err := make([]Eval_Value, len(s.rhs), ev.alloc)
	if value_err != nil { return .Fail }
	for value, index in s.rhs {
		computed, ok := eval_expr(ev, value)
		if !ok {
			return .Fail
		}
		copied, copied_ok := copy_value(ev, computed)
		if !copied_ok {
			return .Fail
		}
		values[index] = copied
	}
	slots, slot_err := make([]^Eval_Value, len(s.lhs), ev.alloc)
	if slot_err != nil { return .Fail }
	for target, index in s.lhs {
		slot, ok := eval_place(ev, target)
		if !ok {
			return .Fail
		}
		slots[index] = slot
	}
	for slot, index in slots {
		if index < len(values) {
			retyped := values[index]
			retyped.type = slot.type != INVALID_TYPE ? slot.type : retyped.type
			slot^ = retyped
		}
	}
	return .Normal
}

@(private = "file")
eval_compound_assign :: proc(ev: ^Evaluator, s: ^Stmt_Assign) -> Eval_Flow {
	slot, ok := eval_place(ev, s.lhs[0])
	if !ok {
		return .Fail
	}
	operand, operand_ok := eval_expr(ev, s.rhs[0])
	if !operand_ok {
		return .Fail
	}
	op := compound_operator(s.op)
	type := slot.type
	// design.md: the destination is read after the right operand. SIMD folds
	// lane-wise, since `const_of` carries no lanes.
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
		// A `&` loop needs the container's own storage.
		if foreach_is_place_loop(s) {
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
		// The step limit ends the loop first.
		count = max(i64)
	}
	for index in 0 ..< int(min(count, i64(max(int)))) {
		offset := bi_from_i64(ev.alloc, i64(index))
		if s.adapter == .Reversed {
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
		at := s.adapter == .Reversed ? len(elements) - 1 - index : index
		flow := eval_foreach_step(ev, s, &elements[at], index)
		if flow != .Normal {
			return flow == .Break ? .Normal : flow
		}
	}
	return .Normal
}

// One step: bind the element, run the body. `continue` ends only the step.
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

// design.md "Element bindings": a value binding copies; a `&` binding is the
// container's storage.
@(private = "file")
bind_foreach_element :: proc(ev: ^Evaluator, s: ^Stmt_Foreach, element: ^Eval_Value, index: int) -> bool {
	frame := current_frame(ev)
	if frame == nil {
		eval_fail(ev, s.span, "L0341", "a `foreach` needs a compile-time frame")
		return false
	}
	if foreach_is_place_loop(s) {
		if s.indexed && len(s.bindings) == 2 {
			if !bind_eval_place_pattern(ev, frame, []Foreach_Binding{s.bindings[0]}, element) { return false }
			return bind_local(ev, frame, s.bindings[1].symbol, eval_count_value(ev, index))
		}
		return bind_eval_place_pattern(ev, frame, s.bindings, element)
	}
	value, copied := copy_value(ev, element^)
	if !copied {
		return false
	}
	if s.indexed {
		pair, allocated := eval_elements(ev, 2)
		if !allocated {
			return false
		}
		pair[ELEMENT_FIRST] = value
		pair[ELEMENT_SECOND] = eval_count_value(ev, index)
		value = Eval_Value{kind = .Aggregate, type = s.element_type, elements = pair}
	}
	return bind_eval_value_pattern(ev, frame, s.bindings, value, s.span)
}

@(private = "file")
bind_eval_value_pattern :: proc(
	ev: ^Evaluator, frame: ^Eval_Frame, bindings: []Foreach_Binding, value: Eval_Value, span: Span,
) -> bool {
	if len(bindings) == 1 && len(bindings[0].group) > 0 {
		return bind_eval_value_pattern(ev, frame, bindings[0].group, value, span)
	}
	if len(bindings) == 1 && len(bindings[0].group) == 0 {
		return bind_local(ev, frame, bindings[0].symbol, value)
	}
	if value.kind != .Aggregate || len(value.elements) != len(bindings) {
		eval_fail(ev, span, "L0341", "this element has no compile-time fields to destructure")
		return false
	}
	for binding, slot in bindings {
		if len(binding.group) > 0 {
			if !bind_eval_value_pattern(ev, frame, binding.group, value.elements[slot], span) { return false }
		} else if !bind_local(ev, frame, binding.symbol, value.elements[slot]) {
			return false
		}
	}
	return true
}

@(private = "file")
bind_eval_place_pattern :: proc(
	ev: ^Evaluator, frame: ^Eval_Frame, bindings: []Foreach_Binding, value: ^Eval_Value,
) -> bool {
	if len(bindings) == 1 && len(bindings[0].group) > 0 {
		return bind_eval_place_pattern(ev, frame, bindings[0].group, value)
	}
	if len(bindings) == 1 && len(bindings[0].group) == 0 {
		if bindings[0].symbol != INVALID_SYMBOL { frame.locals[bindings[0].symbol] = value }
		return true
	}
	if value.kind != .Aggregate || len(value.elements) != len(bindings) {
		eval_fail(ev, no_span(), "L0341", "this element has no compile-time fields to destructure")
		return false
	}
	for binding, slot in bindings {
		part := &value.elements[slot]
		if len(binding.group) > 0 {
			if !bind_eval_place_pattern(ev, frame, binding.group, part) { return false }
		} else if binding.symbol != INVALID_SYMBOL {
			frame.locals[binding.symbol] = part
		}
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
	subject, ok := eval_expr(ev, s.subject)
	if !ok {
		return .Fail
	}
	if s.kind != .Value && type_is_union(ev.k.c, type_underlying(ev.k.c, expr_base(s.subject).type)) {
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
eval_variant_switch :: proc(ev: ^Evaluator, s: ^Stmt_Switch, subject: Eval_Value) -> Eval_Flow {
	chosen := -1
	fallback := -1
	for entry, index in s.cases {
		if len(entry.variant_indices) == 0 {
			fallback = index
			continue
		}
		for variant in entry.variant_indices {
			if variant == subject.variant {
				chosen = index
				break
			}
		}
		if chosen >= 0 {
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
	if entry.binding_symbol != INVALID_SYMBOL {
		frame := current_frame(ev)
		if frame == nil {
			eval_fail(ev, s.span, "L0341", "a case binding needs a compile-time frame")
			return .Fail
		}
		bound, copied := copy_value(ev, eval_union_payload(subject, entry.binding_type))
		if !copied || !bind_local(ev, frame, entry.binding_symbol, bound) {
			return .Fail
		}
	}
	return eval_stmts(ev, entry.stmts, true)
}

@(private = "file")
eval_case_matches :: proc(ev: ^Evaluator, subject: Eval_Value, value: Expr) -> (bool, bool) {
	if range, is_range := value.(^Expr_Range); is_range {
		lo, lo_ok := eval_expr(ev, range.lo)
		if !lo_ok {
			return false, false
		}
		hi, hi_ok := eval_expr(ev, range.hi)
		if !hi_ok {
			return false, false
		}
		above, above_ok := eval_compare(ev, .Gt_Eq, subject, lo)
		below, below_ok := eval_compare(ev, range.op == .Range_Excl ? .Lt : .Lt_Eq, subject, hi)
		if !above_ok || !below_ok {
			return false, eval_fail(ev, expr_span(value), "L0341", "this case has no compile-time meaning")
		}
		return above && below, true
	}
	other, ok := eval_expr(ev, value)
	if !ok {
		return false, false
	}
	matched, compare_ok := eval_compare(ev, .Eq_Eq, subject, other)
	if !compare_ok {
		return false, eval_fail(ev, expr_span(value), "L0341", "this case has no compile-time meaning")
	}
	return matched, true
}

@(private = "file")
eval_return :: proc(ev: ^Evaluator, s: ^Stmt_Return) -> Eval_Flow {
	frame := current_frame(ev)
	if frame == nil {
		eval_fail(ev, s.span, "L0341", "`return` needs a compile-time frame")
		return .Fail
	}
	if s.value == nil {
		return .Return
	}
	computed, ok := eval_expr(ev, s.value.expr)
	if !ok {
		return .Fail
	}
	copied, copied_ok := copy_value(ev, computed)
	if !copied_ok {
		return .Fail
	}
	frame.result = copied
	return .Return
}
