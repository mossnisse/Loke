// The compile-time engine (compiler-plan B10, m3-plan step 1).
//
// One tree-walking interpreter over the *typed* AST. It is not a second
// checker: every node it visits has already been name-resolved, typed, and — in
// the easy cases — folded, and every value operation it performs is the shared
// one in `const_ops.odin`. What it adds over folding is execution: frames,
// locals, mutation, loops, `defer`, and calls.
//
// Values are evaluator-owned and mutable while a procedure runs, then frozen
// into immutable compilation-arena `Const_Value`s on the way back into semantic
// state (m3-plan decision "Evaluator values").
package lokec

import "core:fmt"
import "core:mem"
import "core:mem/virtual"

// Documented ceilings. Exceeding one is a diagnostic, never a silent fallback
// to generating runtime code (m3-plan decision "Limits").
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
// this stack, not on Odin's (m3-plan decision "Frames").
Eval_Frame :: struct {
	symbol:       Symbol_Id,
	site:         Span,
	locals:       map[Symbol_Id]^Eval_Value,
	defers:       [dynamic]Stmt,
	results:      []Eval_Value,
	result_slots: []^Eval_Value,
}

Evaluator :: struct {
	k:      ^Checker,
	arena:  virtual.Arena,
	alloc:  mem.Allocator,
	frames: [dynamic]^Eval_Frame,
	steps:  int,
	bytes:  int,
	failed: bool,
	// The compile-time-required context that forced this evaluation, and how to
	// name it. The primary diagnostic points here (m3-plan "Failure origin").
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
		frames = make([dynamic]^Eval_Frame, 0, 8, context.temp_allocator),
		origin = expr_span(e),
		what   = what,
	}
	if err := virtual.arena_init_growing(&ev.arena); err != nil {
		errorf(k.c, expr_span(e), "L0342", "cannot reserve compile-time scratch memory")
		return Const_Value{}, false
	}
	ev.alloc = virtual.arena_allocator(&ev.arena)
	defer virtual.arena_destroy(&ev.arena)

	value, ok := eval_expr(&ev, e)
	if !ok {
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

// Checks a procedure's signature and body on demand, so an array length or enum
// value may call a procedure the ordinary phase order has not reached yet
// (m3-plan decision "Evaluation readiness").
ensure_proc_typed_for_eval :: proc(k: ^Checker, symbol_id: Symbol_Id) -> bool {
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

	outer_scope, outer_pkg, outer_file := k.scope, k.pkg, k.file
	outer_proc, outer_results := k.proc_literal, k.result_types
	outer_result_symbols, outer_named := k.result_symbols, k.named_results
	outer_loop, outer_switch, outer_defer := k.loop_depth, k.switch_depth, k.in_defer
	outer_slots := k.defer_slots
	defer {
		k.scope, k.pkg, k.file = outer_scope, outer_pkg, outer_file
		k.proc_literal, k.result_types = outer_proc, outer_results
		k.result_symbols, k.named_results = outer_result_symbols, outer_named
		k.loop_depth, k.switch_depth, k.in_defer = outer_loop, outer_switch, outer_defer
		k.defer_slots = outer_slots
	}
	if pkg := package_of(k.c, symbol.pkg); pkg != nil && pkg.scope != nil {
		k.scope = pkg.scope
		k.pkg = symbol.pkg
	}
	k.file = d.span.file
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
	errorf(c, ev.origin, code, format, ..args)
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
	ev.steps += 1
	if ev.steps > EVAL_MAX_STEPS {
		return eval_fail(ev, span, "L0342", "compile-time evaluation exceeded %d steps", EVAL_MAX_STEPS)
	}
	if ev.bytes > EVAL_MAX_MEMORY {
		return eval_fail(ev, span, "L0342", "compile-time evaluation exceeded %d bytes of scratch memory", EVAL_MAX_MEMORY)
	}
	return true
}

// ---------------------------------------------------------------- storage --

@(private = "file")
eval_charge :: proc(ev: ^Evaluator, amount: int) -> bool {
	if amount < 0 || amount > EVAL_MAX_MEMORY - ev.bytes {
		return eval_fail(
			ev,
			ev.origin,
			"L0342",
			"compile-time evaluation exceeded %d bytes of scratch memory",
			EVAL_MAX_MEMORY,
		)
	}
	ev.bytes += amount
	return true
}

@(private = "file")
eval_slot :: proc(ev: ^Evaluator, value: Eval_Value) -> (^Eval_Value, bool) {
	if !eval_charge(ev, size_of(Eval_Value)) {
		return nil, false
	}
	slot := new(Eval_Value, ev.alloc)
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
	if !eval_charge(ev, count * size_of(Eval_Value)) {
		return nil, false
	}
	return make([]Eval_Value, count, ev.alloc), true
}

// The declared type of one element of an aggregate type.
@(private = "file")
element_type_at :: proc(c: ^Compiler, type: Type_Id, index: int) -> Type_Id {
	info := type_of(c, type_underlying(c, type))
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
	if cv.kind == .Aggregate && cv.aggregate != nil {
		holder := type != INVALID_TYPE ? type : cv.aggregate.type
		value.type = holder
		elements, allocated := eval_elements(ev, len(cv.aggregate.elements))
		if !allocated {
			return Eval_Value{}, false
		}
		value.elements = elements
		for element, index in cv.aggregate.elements {
			converted, ok := value_from_const(ev, element, element_type_at(ev.k.c, holder, index))
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
freeze :: proc(ev: ^Evaluator, v: Eval_Value) -> (Const_Value, bool) {
	if v.target != nil || v.proc_value != INVALID_SYMBOL {
		eval_fail(ev, ev.origin, "L0341", "a pointer cannot escape compile-time evaluation")
		return Const_Value{}, false
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
	if v.kind == .Aggregate {
		elements := make([]Const_Value, len(v.elements), ev.k.c.semantic_allocator)
		for element, index in v.elements {
			frozen, ok := freeze(ev, element)
			if !ok {
				return Const_Value{}, false
			}
			elements[index] = frozen
		}
		aggregate := new(Const_Aggregate, ev.k.c.semantic_allocator)
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

eval_expr :: proc(ev: ^Evaluator, e: Expr) -> (Eval_Value, bool) {
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
		index_value, index_ok := eval_expr(ev, v.indices[0])
		if !index_ok {
			return Eval_Value{}, false
		}
		index, fits := bi_to_i64(ev.k.c, index_value.integer)
		if !fits || index < 0 || int(index) >= len(operand.elements) {
			eval_fail(ev, expr_span(v.indices[0]), "L0361", "index %s is out of range", bi_text(ev.k.c, index_value.integer))
			return Eval_Value{}, false
		}
		return operand.elements[index], true

	case ^Expr_Postfix:
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

	case ^Expr_Error, ^Expr_Literal, ^Expr_Type_Assert, ^Expr_Slice, ^Expr_Range,
	     ^Expr_Or_Else, ^Expr_Move, ^Expr_Hash, ^Expr_Proc_Group, ^Expr_Operator,
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
			folded = Const_Value{kind = value.kind, integer = bi_neg(ev.k.c, value.integer)}
		}
	case .Tilde:
		folded = Const_Value{kind = value.kind, integer = bi_not(ev.k.c, value.integer)}
	case .Not:
		folded = bool_const(!value.boolean)
	case:
		eval_fail(ev, v.op_span, "L0341", "`%s` has no compile-time meaning", operator_text(v.op))
		return Eval_Value{}, false
	}
	if folded.kind == .Integer || folded.kind == .Rune {
		folded.integer = wrap_to_type(ev.k.c, folded.integer, v.type)
	}
	return scalar(folded, v.type), true
}

@(private = "file")
eval_binary :: proc(ev: ^Evaluator, v: ^Expr_Binary) -> (Eval_Value, bool) {
	if v.resolution.kind == .User_Operator {
		eval_fail(ev, v.op_span, "L0341", "a user operator has no compile-time meaning yet")
		return Eval_Value{}, false
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
		count, fits := bi_to_u64(ev.k.c, right.integer)
		if !fits || count > 1 << 20 {
			eval_fail(ev, expr_span(v.rhs), "L0356", "shift count %s is too large", bi_text(ev.k.c, right.integer))
			return Eval_Value{}, false
		}
		shifted := v.op == .Shl ? bi_shl(ev.k.c, left.integer, int(count)) : bi_shr(ev.k.c, left.integer, int(count))
		return scalar(Const_Value{kind = left.kind, integer = wrap_to_type(ev.k.c, shifted, v.type)}, v.type), true

	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		result, ok := eval_compare(ev, v.op, left, right)
		if !ok {
			eval_fail(ev, v.op_span, "L0341", "this comparison has no compile-time meaning")
			return Eval_Value{}, false
		}
		return scalar(bool_const(result), v.type), true
	}

	folded, ok := fold_arithmetic(ev.k.c, v.op, v.op_span, const_of(left), const_of(right), v.type)
	if !ok {
		// `fold_arithmetic` already reported the reason (division by zero, or an
		// operator that does not apply).
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
	return fold_comparison(ev.k.c, op, const_of(a), const_of(b))
}

@(private = "file")
eval_composite :: proc(ev: ^Evaluator, v: ^Expr_Composite) -> (Eval_Value, bool) {
	value, zeroed := zero_value(ev, v.type)
	if !zeroed {
		return Eval_Value{}, false
	}
	if value.kind != .Aggregate {
		eval_fail(ev, v.span, "L0341", "this literal has no compile-time value")
		return Eval_Value{}, false
	}
	info := type_of(ev.k.c, type_underlying(ev.k.c, v.type))
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
		index_value, index_ok := eval_expr(ev, v.indices[0])
		if !index_ok {
			return nil, false
		}
		index, fits := bi_to_i64(ev.k.c, index_value.integer)
		if !fits || index < 0 || int(index) >= len(base.elements) {
			eval_fail(ev, expr_span(v.indices[0]), "L0361", "index %s is out of range", bi_text(ev.k.c, index_value.integer))
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

// ------------------------------------------------------------------- calls --

@(private = "file")
eval_call :: proc(ev: ^Evaluator, v: ^Expr_Call) -> (Eval_Value, bool) {
	if v.resolution.kind == .Conversion {
		return eval_conversion(ev, v)
	}
	callee := symbol_of(ev.k.c, v.resolution.symbol)
	if callee != nil && callee.kind == .Builtin {
		return eval_builtin(ev, v, callee)
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
eval_invoke :: proc(ev: ^Evaluator, symbol_id: Symbol_Id, args: []Expr, site: Span) -> ([]Eval_Value, bool) {
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

	frame := new(Eval_Frame, context.temp_allocator)
	frame.symbol = symbol_id
	frame.site = site
	frame.locals = make(map[Symbol_Id]^Eval_Value, 8, context.temp_allocator)
	frame.defers = make([dynamic]Stmt, 0, 4, context.temp_allocator)
	frame.results = make([]Eval_Value, len(symbol.results), context.temp_allocator)
	frame.result_slots = make([]^Eval_Value, len(symbol.results), context.temp_allocator)

	info := type_of(ev.k.c, symbol.proc_type)
	// A default argument may name a parameter to its left, so it is evaluated
	// with the callee's frame current while every written argument is evaluated
	// in the caller's.
	append(&ev.frames, frame)
	for argument, index in args {
		if index >= len(symbol.param_symbols) {
			break
		}
		binding := symbol.param_symbols[index]
		mode := info != nil && index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		is_default := symbol.param_defaults != nil && index < len(symbol.param_defaults) &&
			argument == symbol.param_defaults[index]

		if !is_default {
			pop(&ev.frames)
		}
		slot: ^Eval_Value
		ok := true
		if mode == .Inout {
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
		return decl_proc(symbol.decl)
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
	converted, fits := convert_const(c, const_of(source), v.type, true)
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
	values := make([]Eval_Value, len(s.rhs), context.temp_allocator)
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
	slots := make([]^Eval_Value, len(s.lhs), context.temp_allocator)
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
	op := eval_compound_operator(s.op)
	type := slot.type
	#partial switch op {
	case .Shl, .Shr:
		count, fits := bi_to_u64(ev.k.c, operand.integer)
		if !fits || count > 1 << 20 {
			eval_fail(ev, s.op_span, "L0356", "shift count %s is too large", bi_text(ev.k.c, operand.integer))
			return .Fail
		}
		shifted := op == .Shl ? bi_shl(ev.k.c, slot.integer, int(count)) : bi_shr(ev.k.c, slot.integer, int(count))
		slot^ = scalar(Const_Value{kind = slot.kind, integer = wrap_to_type(ev.k.c, shifted, type)}, type)
		return .Normal
	}
	folded, folded_ok := fold_arithmetic(ev.k.c, op, s.op_span, const_of(slot^), const_of(operand), type)
	if !folded_ok {
		ev.failed = true
		return .Fail
	}
	slot^ = scalar(folded, type)
	return .Normal
}

@(private = "file")
eval_compound_operator :: proc(op: Token_Kind) -> Token_Kind {
	#partial switch op {
	case .Plus_Eq:      return .Plus
	case .Minus_Eq:     return .Minus
	case .Star_Eq:      return .Star
	case .Slash_Eq:     return .Slash
	case .Percent_Eq:   return .Percent
	case .Pipe_Eq:      return .Pipe
	case .Tilde_Eq:     return .Tilde
	case .Amp_Eq:       return .Amp
	case .Amp_Tilde_Eq: return .Amp_Tilde
	case .Shl_Eq:       return .Shl
	case .Shr_Eq:       return .Shr
	}
	return .EOF
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
