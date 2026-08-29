// The compile-time engine (compiler-plan B10).
//
// One tree-walking interpreter over the *typed* AST. It is not a second
// checker: every node it visits has already been name-resolved, typed, and — in
// the easy cases — folded, and every value operation it performs is the shared
// one in `const_ops.odin`. What it adds over folding is execution: frames,
// locals, mutation, loops, `defer`, and calls.
//
// Values are evaluator-owned and mutable while a procedure runs, then frozen
// into immutable compilation-arena `Const_Value`s on the way back into
// semantic state.
package lokec

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

// Documented ceilings. Exceeding one is a diagnostic, never a silent fallback
// to generating runtime code.
EVAL_MAX_STEPS  :: 1_000_000
EVAL_MAX_DEPTH  :: 256
EVAL_MAX_MEMORY :: 64 * 1024 * 1024

// What finishing a statement did to control flow. `Fail` means a diagnostic has
// already been reported and the whole evaluation is over.
Eval_Flow :: enum {
	Normal,
	Break,
	Continue,
	Return,
	Fail,
}

// A value while it is being computed. Scalars mirror `Const_Value`; aggregates
// keep a mutable element slice so `a[i] = v` inside an evaluated procedure is a
// write, not a rebuild. A pointer is `target`, a procedure value is
// `proc_value`; both are null when neither is set.
Eval_Value :: struct {
	kind:       Const_Kind,
	type:       Type_Id,
	// For a union value: the variant it holds, with `elements[0]` its payload
	// (an `Invalid` value for a payloadless variant). Unread otherwise.
	variant:    int,
	integer:    Big_Int,
	float:      f64,
	float_bits: u16,
	boolean:    bool,
	text:       string,
	type_value: Type_Id,
	elements:   []Eval_Value,
	target:     ^Eval_Value,
	proc_value: Symbol_Id,
}

// One explicit call frame. Recursion and the call-stack notes are limits on
// this stack, not on Odin's.
Eval_Frame :: struct {
	symbol:       Symbol_Id,
	site:         Span,
	locals:       map[Symbol_Id]^Eval_Value,
	defers:       [dynamic]Stmt,
	results:      []Eval_Value,
	result_slots: []^Eval_Value,
	// Set by a failing `or_return`. Expression evaluation then bubbles `false`
	// to the statement boundary, which turns it into ordinary return flow so
	// block defers still run in their normal order.
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
	// The compile-time-required context that forced this evaluation, and how to
	// name it. The primary diagnostic points here.
	origin: Span,
	what:   string,
}

// ------------------------------------------------------------ entry points --

// The single funnel every compile-time-required context goes through. An
// already folded expression is accepted as is; anything else is executed.
require_const :: proc(k: ^Checker, e: Expr, what: string, code := "L0340") -> (Const_Value, bool) {
	base := expr_base(e)
	if base == nil || base.type == INVALID_TYPE {
		return Const_Value{}, false
	}
	if base.is_const && base.const_value.kind != .Invalid {
		return base.const_value, true
	}

	ev := Evaluator {
		k      = k,
		origin = expr_span(e),
		what   = what,
	}
	if !init_evaluator(&ev) {
		return Const_Value{}, false
	}
	defer virtual.arena_destroy(&ev.arena)

	value, ok := eval_expr(&ev, e)
	if !eval_memory_ok(&ev) || !ok {
		if !ev.failed {
			eval_fail(&ev, expr_span(e), code, "%s must be a compile-time constant", what)
		}
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

// Static `foreach` may consume a finite evaluator-owned array without asking
// the container itself to escape evaluation. Each yielded element is frozen
// independently into semantic storage while the evaluator arena is still live.
evaluate_static_elements :: proc(
	k: ^Checker,
	e: Expr,
	what: string,
	code := "L0454",
) -> ([]Const_Value, bool) {
	ev := Evaluator {
		k      = k,
		origin = expr_span(e),
		what   = what,
	}
	if !init_evaluator(&ev) {
		return nil, false
	}
	defer virtual.arena_destroy(&ev.arena)

	value, ok := eval_expr(&ev, e)
	if !eval_memory_ok(&ev) || !ok {
		if !ev.failed {
			eval_fail(&ev, expr_span(e), code, "%s must be compile-time evaluable", what)
		}
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

// Checks a procedure's signature and body on demand, so an array length or enum
// value may call a procedure the ordinary phase order has not reached yet.
ensure_proc_typed_for_eval :: proc(k: ^Checker, symbol_id: Symbol_Id) -> bool {
	// Executing a declaration is a real use, even when a `where` predicate
	// requested it. Its persistent body must retain all runtime dependencies;
	// only the surrounding hypothetical expression suppresses registration.
	saved_speculation := k.c.speculation_depth
	k.c.speculation_depth = 0
	defer k.c.speculation_depth = saved_speculation
	if instance, found := k.c.procedure_instances[symbol_id]; found {
		promote_generic_instance(k, instance)
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
	outer_proc, outer_results := k.proc_literal, k.result_types
	outer_result_symbols, outer_named := k.result_symbols, k.named_results
	outer_loop, outer_switch, outer_defer := k.loop_depth, k.switch_depth, k.in_defer
	outer_slots := k.defer_slots
	defer {
		restore_checker_location(k, outer_location)
		k.proc_literal, k.result_types = outer_proc, outer_results
		k.result_symbols, k.named_results = outer_result_symbols, outer_named
		k.loop_depth, k.switch_depth, k.in_defer = outer_loop, outer_switch, outer_defer
		k.defer_slots = outer_slots
	}
	enter_symbol_location(k, symbol)
	k.proc_literal = nil
	k.result_types, k.result_symbols, k.named_results = nil, nil, false
	k.loop_depth, k.switch_depth, k.in_defer = 0, 0, false

	resolve_declaration_signature(k, d)
	check_decl(k, d)
	return d.check_state == .Checked
}

// ------------------------------------------------------------- diagnostics --

// The primary diagnostic names the required context; notes identify the failing
// operation and every evaluator frame between it and here.
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
	ev.steps += 1
	if ev.steps > EVAL_MAX_STEPS {
		return eval_fail(ev, span, "L0342", "compile-time evaluation exceeded %d steps", EVAL_MAX_STEPS)
	}
	return true
}

// ---------------------------------------------------------------- storage --

@(private = "file")
init_evaluator :: proc(ev: ^Evaluator) -> bool {
	if err := virtual.arena_init_growing(&ev.arena); err != nil {
		return eval_fail(ev, ev.origin, "L0342", "cannot reserve compile-time scratch memory")
	}
	ev.alloc = mem.Allocator{eval_allocator_proc, ev}
	ev.frames = make([dynamic]^Eval_Frame, 0, 8, ev.alloc)
	return true
}

// All execution storage, including arithmetic and library-internal temporary
// allocations, passes through this budget. Arena frees do not reclaim bytes;
// resizes conservatively charge the complete replacement allocation.
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

// Report outside the allocator callback: formatting a diagnostic may itself
// allocate, and must never recurse through an exhausted scratch allocator.
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
	case .Array:
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
	value := Eval_Value {
		kind       = cv.kind,
		type       = type,
		integer    = cv.integer,
		float      = cv.float,
		float_bits = cv.float_bits,
		boolean    = cv.boolean,
		text       = cv.text,
		type_value = cv.type_value,
	}
	// The all-zero header is the *empty container*, not a four-element record:
	// compile-time evaluation has no allocation, no capacity and no provider to
	// carry, so reading the constant back has to produce the same emptiness
	// `zero_value` makes.
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
			member := is_union 				? union_variant_payload(ev.k.c, holder, cv.aggregate.variant) 				: element_type_at(ev.k.c, holder, index)
			converted, ok := value_from_const(ev, element, member)
			if !ok {
				return Eval_Value{}, false
			}
			value.elements[index] = converted
		}
	}
	return value, true
}

// A deep copy: assignment of an aggregate is a value copy, so the source and
// destination cannot alias afterwards.
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

// Crossing back into semantic state: the result becomes immutable and
// compilation-arena owned. A pointer cannot make that trip.
freeze :: proc(ev: ^Evaluator, v: Eval_Value, allocator: mem.Allocator = {}) -> (Const_Value, bool) {
	storage := value_allocator(ev.k.c, allocator)
	if v.target != nil || v.proc_value != INVALID_SYMBOL {
		eval_fail(ev, ev.origin, "L0341", "a pointer cannot escape compile-time evaluation")
		return Const_Value{}, false
	}
	// design.md: a container's only constant is the all-zero header, because
	// anything else would need an allocation that no constant can own. So a
	// compile-time container is a *temporary*: usable while the evaluation runs,
	// and never the thing it produces.
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
	cv := Const_Value {
		kind       = v.kind,
		integer    = v.integer,
		float      = v.float,
		float_bits = v.float_bits,
		boolean    = v.boolean,
		text       = v.text,
		type_value = v.type_value,
	}
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
	// A container's zero value is empty, allocator-unbound, constant, and
	// immediately usable (design.md). Here that is simply no elements: the
	// four-word header models an allocation, and compile-time evaluation has none.
	if type_is_container(ev.k.c, type) {
		return Eval_Value{kind = .Aggregate, type = type}, true
	}
	under := type_underlying(ev.k.c, type)
	info := type_of(ev.k.c, under)
	if info == nil { return Eval_Value{}, false }
	#partial switch info.kind {
	case .Int, .Enum, .Rune:
		return Eval_Value{kind = info.kind == .Rune ? .Rune : .Integer, type = type, integer = bi_zero(ev.alloc)}, true
	case .Array, .Struct, .Any_View, .Dyn, .Slice:
		ensure_slice_fields(ev.k.c, under)
		info = type_of(ev.k.c, under)
		count := info.kind == .Array ? int(info.count) : len(info.fields)
		kind, element, fields := info.kind, info.element, info.fields
		elements, allocated := eval_elements(ev, count)
		if !allocated { return Eval_Value{}, false }
		for index in 0 ..< count {
			element_type := kind == .Array ? element : symbol_of(ev.k.c, fields[index]).type
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

// --------------------------------------------------------------- expressions --

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
	// Anything the checker already folded is finished work.
	if base.is_const && base.const_value.kind != .Invalid {
		return value_from_const(ev, base.const_value, base.type)
	}

	switch v in e {
	case ^Expr_Ident:
		return eval_ident(ev, v)

	case ^Expr_Selector:
		// Reading needs a value, not storage: `f().field` selects out of a
		// temporary that has no place at all.
		field := symbol_of(ev.k.c, v.resolution.symbol)
		if field == nil {
			return Eval_Value{}, false
		}
		operand, ok := eval_aggregate_value(ev, v.operand)
		if !ok || int(field.index) >= len(operand.elements) {
			return Eval_Value{}, false
		}
		return operand.elements[field.index], true

	case ^Expr_Index:
		operand, ok := eval_aggregate_value(ev, v.operand)
		if !ok {
			return Eval_Value{}, false
		}
		// design.md "Maps": a read never inserts and answers the zero value for a
		// missing key. It is a value position, so it does not need the place.
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
		if pointer.target == nil {
			eval_fail(ev, v.op_span, "L0343", "this dereferences a nil pointer")
			return Eval_Value{}, false
		}
		return pointer.target^, true

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

	case ^Expr_Proc:
		return Eval_Value{kind = .Nil, type = v.type, proc_value = v.symbol}, true

	case ^Expr_Or_Else:
		return eval_or_else(ev, v)

	case ^Expr_Error, ^Expr_Literal, ^Expr_Checked_Extract, ^Expr_Slice, ^Expr_Range,
	     ^Expr_Move, ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_Multi_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
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
	// A user operator is an ordinary call, but its operands are user values the
	// evaluator has no representation for yet. Reporting is the honest answer;
	// applying the built-in table would compute something the program does not
	// mean.
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
	// `ok := key in m` (design.md "Maps") -- the right operand settles the key's
	// type, so this is not an ordinary unified binary operation.
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

	#partial switch v.op {
	case .Shl, .Shr:
		count, fits := bi_to_u64(ev.alloc, right.integer)
		if !fits || count > 1 << 20 {
			eval_fail(ev, expr_span(v.rhs), "L0356", "shift count %s is too large", bi_text(ev.alloc, right.integer))
			return Eval_Value{}, false
		}
		shifted := v.op == .Shl ? bi_shl(ev.alloc, left.integer, int(count)) : bi_shr(ev.alloc, left.integer, int(count))
		return scalar(Const_Value{kind = left.kind, integer = wrap_to_type(ev.k.c, shifted, v.type, ev.alloc)}, v.type), true

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
		// `fold_arithmetic` already reported the reason (division by zero, or an
		// operator that does not apply).
		if !eval_memory_ok(ev) { return Eval_Value{}, false }
		ev.failed = true
		return Eval_Value{}, false
	}
	return scalar(folded, v.type), true
}

// Pointer and procedure identity are the evaluator's own, so they cannot be
// answered by the shared constant comparison.
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
		equal := true
		for element, index in a.elements {
			if index >= len(b.elements) {
				equal = false
				break
			}
			same, ok := eval_compare(ev, .Eq_Eq, element, b.elements[index])
			if !ok || !same {
				equal = false
				break
			}
		}
		return equal == (op == .Eq_Eq), true
	}
	return fold_comparison(ev.k.c, op, const_of(a), const_of(b), ev.alloc)
}

@(private = "file")
eval_composite :: proc(ev: ^Evaluator, v: ^Expr_Composite) -> (Eval_Value, bool) {
	if type_is_container(ev.k.c, v.type) {
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
		if element.key != nil {
			key, is_ident := element.key.(^Expr_Ident)
			if !is_ident {
				return Eval_Value{}, false
			}
			field := struct_field(ev.k.c, v.type, intern_identifier(ev.k.c, key.name))
			symbol := symbol_of(ev.k.c, field)
			if symbol == nil {
				return Eval_Value{}, false
			}
			slot = int(symbol.index)
		}
		if slot >= len(value.elements) {
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

// -------------------------------------------------------------- containers --

// design.md's containers, at compile time.
//
// A compile-time container is its live contents and nothing else: a `[dynamic]T`
// holds its elements in order, and a `map[K]V` holds alternating key/value pairs
// in insertion order. There is no allocation to model, no provider to bind, and
// no address to hand out, so the runtime's four-word header has no compile-time
// meaning — which is why `zero_value` and `value_from_const` both answer the
// *empty container* rather than a four-element record.
//
// Two things are therefore *not* observable here, and both are rejected rather
// than approximated: a capacity, which is a property of an allocation; and a
// map's iteration order, which design.md leaves unspecified. Approximating
// either would let a constant folded at compile time differ from what the same
// code computes at run time.
//
// Memory is charged through `eval_elements` exactly as every other aggregate is,
// so a container that grows without bound reaches `EVAL_MAX_MEMORY` on the same
// counter as everything else. Failure is a diagnostic, and the whole evaluation
// stops: there is no partially built value to clean up, because the evaluator's
// arena is discarded whole.

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
		// design.md "Maps": a literal writes each entry `key = value`.
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
		// A repeated key in a literal keeps the last value, exactly as the runtime
		// table does, so the two agree on a source the checker permits.
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

// The entry index of `key`, or -1. Linear: a compile-time map is bounded by the
// step limit, and a hash table here would only add a second hash implementation
// to keep coherent with the runtime one.
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

// Both lookup and literal deduplication use the same inherent key policy as
// the runtime's operation table. Structural equality is only the built-in case.
@(private = "file")
eval_map_key_equal :: proc(ev: ^Evaluator, map_type: Type_Id, a, b: Eval_Value) -> (bool, bool) {
	if !eval_step(ev, ev.origin) { return false, false }
	policy := resolved_map_key_policy(ev.k.c, container_key(ev.k.c, map_type))
	if policy.kind == .Unresolved {
		return false, eval_fail(ev, ev.origin, "L0405", "a map key operation was not resolved during checking")
	}
	if policy.kind == .Builtin {
		return eval_compare(ev, .Eq_Eq, a, b)
	}
	if policy.equal == INVALID_SYMBOL || !ensure_proc_typed_for_eval(ev.k, policy.equal) {
		return false, eval_fail(ev, ev.origin, "L0341", "the map key's equality cannot be evaluated")
	}
	results, ok := eval_invoke(ev, policy.equal, nil, ev.origin, []Eval_Value{a, b})
	if !ok { return false, false }
	if len(results) != 1 || results[0].kind != .Boolean {
		return false, eval_fail(ev, ev.origin, "L0341", "the map key's equality must return a boolean")
	}
	return results[0].boolean, true
}

// The stored value slot for `key`, inserting a zero entry when it is missing.
// design.md: `m[key] = v` and every chain rooted in one is an inserting place.
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

// Mutating container operations need a place; immutable receivers can also be
// procedure results, constants, and other temporary values.
@(private = "file")
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
	no_error := Eval_Value{kind = .Nil, type = TYPE_ALLOCATOR_ERROR}
	none: []Eval_Value

	// Results outlive this frame, so they are built in the evaluator's arena.
	results :: proc(ev: ^Evaluator, values: ..Eval_Value) -> []Eval_Value {
		out, err := make([]Eval_Value, len(values), ev.alloc)
		if err != nil { return nil }
		copy(out, values)
		return out
	}
	yes := Eval_Value{kind = .Boolean, type = TYPE_BOOL, boolean = true}
	no := Eval_Value{kind = .Boolean, type = TYPE_BOOL}

	// The argument at `index`, already evaluated and deep-copied.
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

	fallible := len(symbol.results) == 1 && symbol.results[0] == ev.k.c.alloc_result_type
	switch symbol.container_op {
	case .None:
		return nil, false

	case .Append, .Try_Append:
		// design.md "Variadic parameters": the pack is a read-only slice, and a
		// `..slice` spread needs a compile-time slice value, which the evaluator
		// does not have. The written elements are what it can run.
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
		return eval_one(ev, eval_alloc_ok(ev, symbol.results[0]))

	case .Insert, .Try_Insert:
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
		return eval_one(ev, eval_alloc_ok(ev, symbol.results[0]))

	case .Pop:
		// An empty container has nothing to pop, and says so with `.none`.
		if len(self.elements) == 0 {
			return eval_one(ev, eval_option(ev, symbol.results[0], Eval_Value{}, false))
		}
		last := self.elements[len(self.elements) - 1]
		self.elements = self.elements[:len(self.elements) - 1]
		return eval_one(ev, eval_option(ev, symbol.results[0], last, true))

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
			// O(1): the last element moves into the hole, and the tail shortens.
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

	case .Resize, .Try_Resize:
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
		return eval_one(ev, eval_alloc_ok(ev, symbol.results[0]))

	case .Reserve, .Try_Reserve, .Shrink, .Try_Shrink, .Map_Reserve, .Map_Try_Reserve,
	     .Map_Shrink, .Map_Try_Shrink:
		// Capacity is a property of an allocation, and there is none here. Reserving
		// or shrinking is therefore observably nothing, which is exactly what makes
		// `cap` answer the length.
		if _, ok := count_argument(ev, v, 1); !ok {
			return nil, false
		}
		if !fallible { return none, true }
		return eval_one(ev, eval_alloc_ok(ev, symbol.results[0]))

	case .Map_Lookup_Value:
		// The copying read: one probe, no insertion, and an independently owned
		// payload on a hit — the same single clone the backend performs.
		key, key_ok := argument(ev, v, 1)
		if !key_ok {
			return nil, false
		}
		at, found_ok := map_find(ev, self, key)
		if !found_ok {
			return nil, false
		}
		if at < 0 {
			return eval_one(ev, eval_option(ev, symbol.results[0], Eval_Value{}, false))
		}
		copied, copied_ok := copy_value(ev, self.elements[at + MAP_ENTRY_VALUE])
		if !copied_ok {
			return nil, false
		}
		return eval_one(ev, eval_option(ev, symbol.results[0], copied, true))

	case .Map_Find:
		// `find` answers with a pointer to the existing value, or `.none` — it
		// never inserts (design.md).
		key, key_ok := argument(ev, v, 1)
		if !key_ok {
			return nil, false
		}
		at, found_ok := map_find(ev, self, key)
		if !found_ok {
			return nil, false
		}
		if at < 0 {
			return eval_one(ev, eval_option(ev, symbol.results[0], Eval_Value{}, false))
		}
		pointer := Eval_Value {
			kind   = .Nil,
			type   = union_variant_payload(ev.k.c, symbol.results[0], union_index_of(ev.k.c, symbol.results[0], "some")),
			target = &self.elements[at + MAP_ENTRY_VALUE],
		}
		return eval_one(ev, eval_option(ev, symbol.results[0], pointer, true))

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
		return eval_one(ev, eval_alloc_ok(ev, symbol.results[0]))

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
			return eval_one(ev, eval_option(ev, symbol.results[0], Eval_Value{}, false))
		}
		taken := self.elements[at + MAP_ENTRY_VALUE]
		kept, err := make([dynamic]Eval_Value, 0, len(self.elements) - 2, ev.alloc)
		if err != nil { return nil, false }
		append(&kept, ..self.elements[:at])
		append(&kept, ..self.elements[at + 2:])
		if !set_contents(ev, self, kept[:]) {
			return nil, false
		}
		return eval_one(ev, eval_option(ev, symbol.results[0], taken, true))
	}
	return nil, false
}

// Reading a key that is not present yields the zero value and does not insert
// (design.md "Maps"). The comma-ok form adds whether it was there.
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
	return zero_value(ev, container_element(ev.k.c, m.type))
}

// `key in m`, and its negation.
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

// How many entries a container holds. A map stores two slots per entry.
@(private = "file")
container_length :: proc(c: ^Compiler, v: Eval_Value) -> int {
	return type_is_map(c, v.type) ? len(v.elements) / 2 : len(v.elements)
}

// ------------------------------------------------------------------ places --

// The storage an expression denotes. Assignment, `&`, and `inout` binding all
// need one; nothing else does.
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
		field := symbol_of(ev.k.c, v.resolution.symbol)
		if field == nil {
			return nil, false
		}
		base, ok := eval_aggregate_place(ev, v.operand)
		if !ok {
			return nil, false
		}
		if int(field.index) >= len(base.elements) {
			return nil, false
		}
		return &base.elements[field.index], true

	case ^Expr_Index:
		base, ok := eval_aggregate_place(ev, v.operand)
		if !ok {
			return nil, false
		}
		// design.md: the same syntax as an assignment target *inserts*, and so does
		// every field or index chain rooted in one. `map_inserts` is the checker's
		// answer to which position this is.
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
		if pointer.target == nil {
			eval_fail(ev, v.op_span, "L0343", "this dereferences a nil pointer")
			return nil, false
		}
		return pointer.target, true

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

// The aggregate a selection reads out of, following one pointer edge the way
// `p.f` means `p^.f`.
@(private = "file")
eval_aggregate_value :: proc(ev: ^Evaluator, operand: Expr) -> (Eval_Value, bool) {
	value, ok := eval_expr(ev, operand)
	if !ok {
		return Eval_Value{}, false
	}
	if type_is_pointer(ev.k.c, expr_base(operand).type) {
		if value.target == nil {
			eval_fail(ev, expr_span(operand), "L0343", "this dereferences a nil pointer")
			return Eval_Value{}, false
		}
		return value.target^, true
	}
	return value, true
}

// The storage a field or element selection writes through: `p.f` on a pointer is
// the same selection as `p^.f`.
@(private = "file")
eval_aggregate_place :: proc(ev: ^Evaluator, operand: Expr) -> (^Eval_Value, bool) {
	if type_is_pointer(ev.k.c, expr_base(operand).type) {
		pointer, ok := eval_expr(ev, operand)
		if !ok {
			return nil, false
		}
		if pointer.target == nil {
			eval_fail(ev, expr_span(operand), "L0343", "this dereferences a nil pointer")
			return nil, false
		}
		return pointer.target, true
	}
	return eval_place(ev, operand)
}

// ------------------------------------------------------------------ unions --

// A union value: `variant` names the arm and `elements[0]` holds its payload.
// A payloadless variant keeps an `Invalid` element, which is what makes the
// element count the same for every arm.
@(private = "file")
eval_union :: proc(ev: ^Evaluator, type: Type_Id, variant: int, payload: Eval_Value) -> (Eval_Value, bool) {
	elements, allocated := eval_elements(ev, 1)
	if !allocated {
		return Eval_Value{}, false
	}
	elements[0] = payload
	return Eval_Value{kind = .Aggregate, type = type, variant = variant, elements = elements}, true
}

// The variant named in compiler-owned code, so nothing here hard-codes a tag.
@(private = "file")
eval_named_union :: proc(ev: ^Evaluator, type: Type_Id, name: string, payload: Eval_Value) -> (Eval_Value, bool) {
	return eval_union(ev, type, union_index_of(ev.k.c, type, name), payload)
}

// `value or_else fallback`: the success payload, or the fallback when the
// value carries its designated failure variant. The fallback is not evaluated
// on the success path, exactly as the backend branches around it.
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

// `or_return` uses false as an internal expression-unwind signal. The current
// statement translates that signal to `.Return`; it is not an evaluation
// failure and does not set `ev.failed`.
@(private = "file")
eval_or_return :: proc(ev: ^Evaluator, v: ^Expr_Postfix) -> (Eval_Value, bool) {
	value, ok := eval_expr(ev, v.operand)
	if !ok {
		return Eval_Value{}, false
	}
	shape, fallible := fallible_of(ev.k, expr_base(v.operand).type)
	frame := current_frame(ev)
	if !fallible || frame == nil || len(frame.results) == 0 {
		eval_fail(ev, v.op_span, "L0341", "this `or_return` has no compile-time target")
		return Eval_Value{}, false
	}
	if value.variant != shape.failure {
		if shape.info.variants[shape.success] == TYPE_VOID {
			return zero_value(ev, unit_type(ev.k.c))
		}
		return eval_union_payload(value, INVALID_TYPE), true
	}

	last := len(frame.results) - 1
	for slot, index in frame.result_slots {
		if index == last {
			continue
		}
		copied, copied_ok := copy_value(ev, slot^)
		if !copied_ok {
			return Eval_Value{}, false
		}
		frame.results[index] = copied
	}
	target, target_ok := fallible_of(ev.k, frame.result_slots[last].type)
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
		// The evaluator's string/string_view carriers share their textual value;
		// the other representation-preserving assignment conversions likewise
		// only need the destination type here.
		payload.type = into
	} else {
		payload = Eval_Value{kind = .Invalid, type = TYPE_VOID}
	}
	wrapped, wrapped_ok := eval_union(ev, frame.result_slots[last].type, target.failure, payload)
	if !wrapped_ok {
		return Eval_Value{}, false
	}
	frame.results[last] = wrapped
	frame.returning = true
	return Eval_Value{}, false
}

// `.ok(Unit{})`: an allocating container operation that had nothing to allocate.
@(private = "file")
eval_alloc_ok :: proc(ev: ^Evaluator, type: Type_Id) -> (Eval_Value, bool) {
	return eval_named_union(ev, type, "ok", Eval_Value{kind = .Aggregate, type = unit_type(ev.k.c)})
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
	return eval_union(ev, v.type, v.variant_index, copied)
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

// ------------------------------------------------------------------- calls --

@(private = "file")
eval_call :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (Eval_Value, bool) {
	if v.resolution.kind == .Conversion {
		return eval_conversion(ev, v)
	}
	if v.union_op == .Construct {
		return eval_union_construct(ev, v)
	}
	// `value.as(T)` is an extraction, and an extraction has no compile-time
	// meaning yet. Say so here rather than treating it as an unresolved call.
	if v.union_op == .Extract {
		eval_fail(ev, v.span, "L0341", "this expression has no compile-time meaning")
		return Eval_Value{}, false
	}
	callee := symbol_of(ev.k.c, v.resolution.symbol)
	if callee != nil && callee.kind == .Builtin {
		return eval_builtin(ev, v, callee)
	}
	// Standard built-in customization members likewise have compiler-written
	// bodies. Execute the operation directly during compile-time evaluation.
	if chosen := symbol_of(ev.k.c, v.resolution.chosen_overload); chosen != nil &&
	   (chosen.synth == .Standard_Len || chosen.synth == .Standard_Cap || chosen.synth == .Standard_Hash) {
		return eval_standard_customization(ev, v, chosen)
	}
	// A contributed container operation has no body to walk: the backend writes
	// one and the evaluator performs one, from the same `container_op`.
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

	results, ok := eval_invoke(ev, target, v.bound, v.span)
	if !ok {
		return Eval_Value{}, false
	}
	if len(results) == 0 {
		return Eval_Value{kind = .Invalid, type = TYPE_VOID}, true
	}
	return results[0], true
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
		return Eval_Value{}, false
	}
}

// Resolve direct and indirect calls through one path. Multi-result contexts use
// this too, so `a, b := f()` evaluates `f` exactly as an ordinary call does.
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

// Binds arguments, runs the body, unwinds `defer`, and hands back one value per
// declared result.
@(private = "file")
eval_invoke :: proc(ev: ^Evaluator, symbol_id: Symbol_Id, args: []Expr, site: Span, values: []Eval_Value = nil) -> (out: []Eval_Value, success: bool) {
	defer { if !eval_memory_ok(ev) { success = false } }
	symbol := symbol_of(ev.k.c, symbol_id)
	if symbol == nil {
		return nil, false
	}
	literal := eval_proc_literal(symbol)
	if literal == nil || literal.body == nil {
		eval_fail(ev, site, "L0341", "`%s` has no body to evaluate", eval_proc_name(ev.k.c, symbol_id))
		return nil, false
	}
	if len(ev.frames) >= EVAL_MAX_DEPTH {
		eval_fail(ev, site, "L0342", "compile-time evaluation exceeded a call depth of %d", EVAL_MAX_DEPTH)
		return nil, false
	}

	frame := new(Eval_Frame, ev.alloc)
	if frame == nil { return nil, false }
	frame.symbol = symbol_id
	frame.site = site
	frame.locals = make(map[Symbol_Id]^Eval_Value, 8, ev.alloc)
	frame.defers = make([dynamic]Stmt, 0, 4, ev.alloc)
	frame.results = make([]Eval_Value, len(symbol.results), ev.alloc)
	frame.result_slots = make([]^Eval_Value, len(symbol.results), ev.alloc)
	if !eval_memory_ok(ev) { return nil, false }

	info := type_of(ev.k.c, symbol.proc_type)
	// A default argument may name a parameter to its left, so it is evaluated
	// with the callee's frame current while every written argument is evaluated
	// in the caller's.
	append(&ev.frames, frame)
	if !eval_memory_ok(ev) { return nil, false }
	for index in 0 ..< max(len(args), len(values)) {
		argument := index < len(args) ? args[index] : Expr(nil)
		if index >= len(symbol.param_symbols) {
			break
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
		} else if mode == .Inout {
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
		if !is_default {
			append(&ev.frames, frame)
		}
		if !ok {
			pop(&ev.frames)
			return nil, false
		}
		if binding != INVALID_SYMBOL {
			frame.locals[binding] = slot
		}
	}

	// Named results start at their zero value (design.md "Named results").
	for result, index in symbol.results {
		value, zeroed := zero_value(ev, result)
		if !zeroed {
			pop(&ev.frames)
			return nil, false
		}
		slot, allocated := eval_slot(ev, value)
		if !allocated {
			pop(&ev.frames)
			return nil, false
		}
		frame.result_slots[index] = slot
		if index < len(symbol.result_symbols) && symbol.result_symbols[index] != INVALID_SYMBOL {
			frame.locals[symbol.result_symbols[index]] = slot
		}
	}

	flow := eval_block(ev, literal.body)
	if flow != .Fail {
		// A `return` with no values, or falling out of a procedure with named
		// results, hands back whatever the result slots hold.
		if flow != .Return || frame.results == nil {
			for slot, index in frame.result_slots {
				frame.results[index] = slot^
			}
		}
	}
	pop(&ev.frames)
	if flow == .Fail {
		return nil, false
	}
	return frame.results, true
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
	// Between a distinct type and what it wraps the representation is identical,
	// so the value only changes its type.
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
	converted, fits := convert_const(c, const_of(source), v.type, true, ev.alloc)
	if !fits {
		eval_fail(ev, v.span, "L0341", "this conversion has no compile-time value")
		return Eval_Value{}, false
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

	case .Cap:
		// A capacity is a property of an allocation, and compile-time evaluation
		// has none. Answering the length instead would let a constant folded here
		// differ from what the same code computes at run time, which is the same
		// objection that closes compile-time map iteration.
		eval_fail(
			ev, v.span, "L0595",
			"`cap` has no compile-time meaning: a capacity is a property of an allocation, and there is none here",
		)
		return Eval_Value{}, false

	case .Len:
		// A fixed array's `len` folds long before this. What reaches here is a
		// container, whose length is a fact the evaluator holds.
		subject, ok := eval_expr(ev, v.bound[0])
		if !ok {
			return Eval_Value{}, false
		}
		return Eval_Value {
			kind    = .Integer,
			type    = TYPE_INT,
			integer = bi_from_i64(ev.alloc, i64(container_length(ev.k.c, subject))),
		}, true

	case .Drop:
		// `drop` runs the cleanup operation, writes the inert zero representation,
		// and marks the variable dead (design.md). The evaluator has no storage to
		// release, so what is left is the zero representation.
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

	case .Hash:
		// The compile-time half of the compiler-contributed `hash`: the same two
		// steps the backend emits, so a folded hash and a runtime one agree.
		value, value_ok := eval_expr(ev, v.bound[0])
		seed, seed_ok := eval_expr(ev, v.bound[1])
		if !value_ok || !seed_ok {
			return Eval_Value{}, false
		}
		frozen_value, froze_value := freeze(ev, value, ev.alloc)
		frozen_seed, froze_seed := freeze(ev, seed, ev.alloc)
		if !froze_value || !froze_seed {
			return Eval_Value{}, false
		}
		start, _ := bi_to_u64(ev.alloc, bi_wrap(ev.alloc, frozen_seed.integer, 64, false))
		mixed := hash_const(ev.k.c, frozen_value, expr_base(v.bound[0]).type, start, ev.alloc)
		return Eval_Value {
			kind    = .Integer,
			type    = TYPE_UINT,
			integer = bi_from_u64(ev.alloc, mixed),
		}, true
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

// The optional trailing message of `assert`/`panic`, already required to be a
// compile-time string by the checker.
@(private = "file")
eval_message :: proc(ev: ^Evaluator, v: ^Expr_Call, index: int) -> string {
	if index >= len(v.bound) || v.bound[index] == nil {
		return ""
	}
	base := expr_base(v.bound[index])
	if base == nil || !base.is_const || base.const_value.kind != .String {
		return ""
	}
	return fmt.aprintf(": %s", base.const_value.text)
}

// -------------------------------------------------------------- statements --

// A block owns the `defer`s written directly in it: they run on the way out,
// innermost scope first and in reverse registration order.
eval_block :: proc(ev: ^Evaluator, b: ^Block) -> Eval_Flow {
	if b == nil {
		return .Normal
	}
	frame := current_frame(ev)
	mark := frame == nil ? 0 : len(frame.defers)
	flow := Eval_Flow.Normal
	for stmt in b.stmts {
		flow = eval_stmt(ev, stmt)
		if flow != .Normal {
			break
		}
	}
	if frame != nil {
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
		if frame := current_frame(ev); frame != nil && frame.returning && !ev.failed {
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
		// The selected branch runs in place: it is not a scope, so its `defer`s
		// belong to the surrounding one.
		selected := when_selected_block(s)
		if selected == nil {
			return .Normal
		}
		flow := Eval_Flow.Normal
		for inner in selected.stmts {
			flow = eval_stmt(ev, inner)
			if flow != .Normal {
				break
			}
		}
		return flow

	case ^Stmt_Foreach:
		// Map iteration order is unspecified (design.md "Maps"). The evaluator has
		// one definite order — insertion — and exposing it would make a
		// compile-time answer depend on something the language refuses to promise,
		// and disagree with the same loop at run time. Rejected by its own reason
		// rather than by the general one below, so the case stays closed when
		// `foreach` does become evaluable.
		if s.kind == .Map {
			eval_fail(
				ev, s.span, "L0593",
				"a map cannot be iterated at compile time: its iteration order is unspecified",
			)
			return .Fail
		}
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
	// One call filling several names evaluates once.
	if len(d.values) == 1 && len(d.symbols) > 1 {
		if call, is_call := d.values[0].(^Expr_Call); is_call && len(call.result_types) == len(d.symbols) {
			results, ok := eval_call_results(ev, call)
			if !ok {
				return .Fail
			}
			for symbol_id, index in d.symbols {
				copied, copied_ok := copy_value(ev, results[index])
				if !copied_ok || !bind_local(ev, frame, symbol_id, copied) {
					return .Fail
				}
			}
			return .Normal
		}
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
	// A fresh slot per declaration, so a loop body's local is a new binding each
	// iteration and a pointer taken to the previous one is unaffected.
	slot, ok := eval_slot(ev, value)
	if !ok {
		return false
	}
	frame.locals[symbol_id] = slot
	return true
}

@(private = "file")
eval_call_results :: proc(ev: ^Evaluator, call: ^Expr_Call) -> ([]Eval_Value, bool) {
	// `n, ok := v.as(T)` is an extraction, which has no compile-time meaning yet.
	// Say so here as well as in `eval_call`, so both arities report it.
	if call.union_op == .Extract {
		eval_fail(ev, call.span, "L0341", "this expression has no compile-time meaning")
		return nil, false
	}
	// `taken, removed := xs.remove(0)` reaches the operation the same way a
	// single-value call does.
	if chosen := symbol_of(ev.k.c, call.resolution.chosen_overload); chosen != nil && chosen.synth == .Container_Op {
		return eval_container_op(ev, call, chosen)
	}
	target, ok := eval_call_target(ev, call)
	if !ok {
		return nil, false
	}
	return eval_invoke(ev, target, call.bound, call.span)
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
	// `a, b = f()`: one call filling several destinations.
	if len(s.rhs) == 1 && len(s.lhs) > 1 {
		if call, is_call := s.rhs[0].(^Expr_Call); is_call && len(call.result_types) == len(s.lhs) {
			results, ok := eval_call_results(ev, call)
			if !ok {
				return .Fail
			}
			for target, index in s.lhs {
				slot, place_ok := eval_place(ev, target)
				if !place_ok {
					return .Fail
				}
				copied, copied_ok := copy_value(ev, results[index])
				if !copied_ok {
					return .Fail
				}
				slot^ = copied
			}
			return .Normal
		}
	}
	// design.md "Assignment statements": every right side is evaluated, then
	// every destination address, then the writes happen.
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
	#partial switch op {
	case .Shl, .Shr:
		count, fits := bi_to_u64(ev.alloc, operand.integer)
		if !fits || count > 1 << 20 {
			eval_fail(ev, s.op_span, "L0356", "shift count %s is too large", bi_text(ev.alloc, operand.integer))
			return .Fail
		}
		shifted := op == .Shl ? bi_shl(ev.alloc, slot.integer, int(count)) : bi_shr(ev.alloc, slot.integer, int(count))
		slot^ = scalar(Const_Value{kind = slot.kind, integer = wrap_to_type(ev.k.c, shifted, type, ev.alloc)}, type)
		return .Normal
	}
	folded, folded_ok := fold_arithmetic(ev.k.c, op, s.op_span, const_of(slot^), const_of(operand), type, ev.alloc)
	if !folded_ok {
		if !eval_memory_ok(ev) { return .Fail }
		ev.failed = true
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
			if post := eval_stmt(ev, s.post); post == .Fail {
				return .Fail
			}
		}
	}
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
	if s.kind == .Type && type_is_union(ev.k.c, type_underlying(ev.k.c, expr_base(s.subject).type)) {
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
				return eval_case_body(ev, s.cases[index].stmts)
			}
		}
	}
	if default_index >= 0 {
		return eval_case_body(ev, s.cases[default_index].stmts)
	}
	return .Normal
}

// A variant switch dispatches on the value's own variant index and binds the
// case's name to the payload — the same identity the emitter compares a tag
// against, so both agree without either consulting a payload type.
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
	return eval_case_body(ev, entry.stmts)
}

@(private = "file")
eval_case_body :: proc(ev: ^Evaluator, stmts: []Stmt) -> Eval_Flow {
	frame := current_frame(ev)
	mark := frame == nil ? 0 : len(frame.defers)
	flow := Eval_Flow.Normal
	for stmt in stmts {
		flow = eval_stmt(ev, stmt)
		if flow != .Normal {
			break
		}
	}
	if frame != nil {
		flow = run_defers(ev, frame, mark, flow)
	}
	// A `break` leaves the switch, and nothing beyond it.
	return flow == .Break ? .Normal : flow
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
			return false, false
		}
		return above && below, true
	}
	other, ok := eval_expr(ev, value)
	if !ok {
		return false, false
	}
	matched, compare_ok := eval_compare(ev, .Eq_Eq, subject, other)
	return matched, compare_ok
}

@(private = "file")
eval_return :: proc(ev: ^Evaluator, s: ^Stmt_Return) -> Eval_Flow {
	frame := current_frame(ev)
	if frame == nil {
		eval_fail(ev, s.span, "L0341", "`return` needs a compile-time frame")
		return .Fail
	}
	if len(s.values) == 0 {
		// Named results keep whatever their slots hold.
		for slot, index in frame.result_slots {
			frame.results[index] = slot^
		}
		return .Return
	}
	// `return f()` filling every result at once.
	if len(s.values) == 1 && len(frame.results) > 1 {
		if call, is_call := s.values[0].expr.(^Expr_Call); is_call && len(call.result_types) == len(frame.results) {
			results, ok := eval_call_results(ev, call)
			if !ok {
				return .Fail
			}
			for value, index in results {
				copied, copied_ok := copy_value(ev, value)
				if !copied_ok {
					return .Fail
				}
				frame.results[index] = copied
			}
			return .Return
		}
	}
	for value, index in s.values {
		if index >= len(frame.results) {
			break
		}
		computed, ok := eval_expr(ev, value.expr)
		if !ok {
			return .Fail
		}
		copied, copied_ok := copy_value(ev, computed)
		if !copied_ok {
			return .Fail
		}
		frame.results[index] = copied
	}
	return .Return
}
