// Checking for the built-ins whose argument rules are the compiler's own. A
// built-in call is an ordinary `Expr_Call` whose callee names a `.Builtin`
// symbol, annotated like any other call.
package lokec

check_builtin_call :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, symbol_id: Symbol_Id, expected: Type_Id) {
	sym := symbol_of(k.c, symbol_id)
	ident.symbol = symbol_id
	ident.resolution = Resolution{kind = .Value, symbol = symbol_id}
	ident.type = sym.proc_type
	v.resolution = Resolution{kind = .Call, symbol = symbol_id, chosen_overload = symbol_id}
	v.operation = Call_Builtin{}

	// Exhaustive, so a new built-in cannot go unchecked.
	switch sym.builtin {
	case .Assert, .Panic:
		check_assert_or_panic(k, v, ident, sym.builtin)
	case .Static_Assert:
		check_static_assert(k, v)
	case .Build_Config:
		check_config(k, v)
	case .Source_Location, .Caller_Location:
		check_location(k, v, ident, sym.builtin)
	case .Size_Of, .Align_Of, .Offset_Of:
		check_layout_builtin(k, v, ident, sym.builtin)
	case .Is_Copyable, .Is_Union:
		check_type_predicate_builtin(k, v, ident, sym.builtin)
	case .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of, .Variants_Of:
		check_reflection_builtin(k, v, ident, sym.builtin)
	case .Make, .Try_Make:
		check_make_builtin(k, v, sym.builtin == .Try_Make)
	case .Simd_Cast, .Simd_Select, .Simd_Reduce:
		check_simd_builtin(k, v, ident, sym.builtin)
	case .Unsafe_Free, .Free_All:
		check_allocation_builtin(k, v, ident, sym.builtin)
	case .Box_New, .Try_Box, .Unsafe_New, .Unsafe_Try_New:
		check_box_builtin(k, v, ident, sym.builtin, expected)
	case .Drop:
		check_drop_builtin(k, v)
	case .Exchange:
		check_exchange_builtin(k, v)
	case .Unsafe_Raw_Data, .Unsafe_String_View, .Unsafe_C_String_View:
		check_unsafe_builtin(k, v, ident, sym.builtin)
	case .Unsafe_Forget:
		check_forget_builtin(k, v)
	case .Unsafe_Take, .Unsafe_Write:
		check_capacity_builtin(k, v, sym.builtin)
	case .Unsafe_Transmute:
		check_transmute_builtin(k, v, ident)
	case .Math_Wrap:
		check_wrap_builtin(k, v)
	case .Math_Fma_Available:
		// A `bool` each emitted copy of its procedure answers for itself
		// (design.md "@(cpu_dispatch=<string>)"), so no constant.
		if builtin_arity_ok(k, v, ident, "L0738", 0) {
			v.type = TYPE_BOOL
		}
	case .Math_Fma_Instruction, .Math_Sqrt_Instruction, .Math_Floor_Instruction, .Math_Ceil_Instruction,
	     .Math_Trunc_Instruction, .Math_Round_Instruction, .Math_Mod_Instruction:
		check_float_instruction_builtin(k, v, ident, sym.builtin)
	case .Math_Count_Ones, .Math_Leading_Zeros, .Math_Trailing_Zeros, .Math_Bit_Width:
		check_bit_count_builtin(k, v, ident, sym.builtin)
	case .Math_Reverse_Bits, .Math_Is_Power_Of_Two, .Math_Next_Power_Of_Two, .Math_Checked_Next_Power_Of_Two:
		check_bit_value_builtin(k, v, ident, sym.builtin)
	case .Math_Rotate_Left, .Math_Rotate_Right:
		check_rotate_builtin(k, v, ident, sym.builtin)
	case .Type_Info_Of:
		check_type_info_of(k, v, ident)
	case .Strings_Allocate:
		check_strings_allocate(k, v, ident)
	case .Allocation_Failed:
		check_allocation_failed(k, v, ident)
	case .Slice_Sort_By:
		check_slice_sort_by(k, v, ident)
	case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
	     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
		check_atomic_builtin(k, v, ident, sym.builtin)
	case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes:
		check_fmt_builtin(k, v, ident, sym.builtin)
	case .Default_Allocator:
		if len(v.args) != 0 {
			errorf(k.c, v.span, "L0490", "`default_allocator` takes no arguments")
			v.type = INVALID_TYPE
			return
		}
		v.type = TYPE_ALLOCATOR
	case .None:
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
	}
}

// `allocation_failed(error, allocator)`: an `Allocator_Error` and the allocator
// whose policy answers it. Like `panic`, its call is `void` and diverges.
@(private = "file")
check_allocation_failed :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.type = INVALID_TYPE
	if len(v.args) != 2 {
		errorf(
			k.c, v.span, "L0322", "`%s` takes an `Allocator_Error` and an `Allocator`, found %d argument%s",
			ident.name, len(v.args), len(v.args) == 1 ? "" : "s",
		)
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	bound := make([]Expr, 2, k.c.semantic_allocator)
	for target, index in ([]Type_Id{TYPE_ALLOCATOR_ERROR, TYPE_ALLOCATOR}) {
		value, passed := check_argument_value(k, v.args[index].value, target)
		bound[index] = value
		if !passed {
			return
		}
	}
	v.bound = bound
	v.type = TYPE_VOID
}

// A built-in has no declaration to name a parameter and no `inout`/`move`/spread
// position to fill.
reject_builtin_argument_shape :: proc(k: ^Checker, arg: Argument) {
	if arg.name.text != "" {
		errorf(k.c, arg.span, "L0371", "a built-in takes positional arguments only")
		return
	}
	errorf(k.c, arg.span, "L0370", "a built-in takes value arguments only")
}

builtin_arguments_ok :: proc(k: ^Checker, v: ^Expr_Call) -> bool {
	for arg in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			reject_builtin_argument_shape(k, arg)
			return false
		}
	}
	return true
}

// One value, written by position with no marker.
has_one_plain_argument :: proc(v: ^Expr_Call) -> bool {
	return len(v.args) == 1 && v.args[0].name.text == "" && v.args[0].mode == .Value
}

// Whether the call passes exactly `wanted` positional values, reporting the
// first thing wrong. The call stays invalid until the caller sets its result type.
builtin_arity_ok :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, code: string, wanted: int) -> bool {
	v.type = INVALID_TYPE
	if len(v.args) != wanted {
		errorf(
			k.c, v.span, code, "`%s` takes %d argument%s, found %d",
			ident.name, wanted, wanted == 1 ? "" : "s", len(v.args),
		)
		return false
	}
	return builtin_arguments_ok(k, v)
}

// A call's operands, in the order the backend reads them.
bound_exprs :: proc(k: ^Checker, operands: ..Expr) -> []Expr {
	bound := make([]Expr, len(operands), k.c.semantic_allocator)
	copy(bound, operands)
	return bound
}

// A value operand's type, an untyped constant taking its default type. `nil`
// has none to take.
@(private = "file")
check_defaulted_operand :: proc(k: ^Checker, e: Expr) -> (type: Type_Id, ok: bool) {
	type = check_single_expr(k, e)
	if type == INVALID_TYPE {
		return INVALID_TYPE, false
	}
	typed := default_type(k.c, type)
	if typed == INVALID_TYPE {
		errorf(k.c, expr_span(e), "L0310", "`nil` has no type to infer here")
		return INVALID_TYPE, false
	}
	if !materialize(k, e, typed) {
		return INVALID_TYPE, false
	}
	return expr_base(e).type, true
}

// `assert(condition[, message, ..args])` and `panic([message, ..args])`. Neither
// folds: the evaluator diagnoses a compile-time occurrence and the backend
// lowers the rest. Each argument after the message prints as its type does.
@(private = "file")
check_assert_or_panic :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.type = INVALID_TYPE
	first := kind == .Assert ? 1 : 0
	if len(v.args) < first {
		errorf(
			k.c,
			v.span,
			"L0322",
			"`%s` takes %s, found %d",
			ident.name,
			kind == .Assert ? "a condition and an optional message" : "an optional message",
			len(v.args),
		)
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	bound := make([]Expr, len(v.args), k.c.semantic_allocator)
	for arg, index in v.args {
		bound[index] = arg.value
		switch {
		case index < first:
			check_condition(k, arg.value)
		case index == first:
			check_message_arg(k, arg.value, formatted = true)
		case:
			check_printed_argument(k, arg.value)
			if committing(k.c) {
				k.c.format_requested = true
			}
		}
	}
	v.bound = bound
	v.type = TYPE_VOID
}

// An `assert`/`panic`/`static_assert` message is a compile-time string. The
// `formatted` ones may be followed by runtime values.
@(private = "file")
check_message_arg :: proc(k: ^Checker, e: Expr, formatted: bool) {
	if check_single_expr(k, e) == INVALID_TYPE {
		return
	}
	base := expr_base(e)
	if !base.is_const || base.const_value.kind != .String {
		errorf(k.c, expr_span(e), "L0345", "this message must be a compile-time string")
		if formatted {
			add_notef(k.c, expr_span(e), "print a runtime value after a constant message: `panic(\"failed:\", value)`")
		}
	}
}

// design.md "Built-in procedures": a value an `assert` or `panic` prints after
// its message, borrowed for the report and printed as its type prints. An
// untyped constant takes its default type.
@(private = "file")
check_printed_argument :: proc(k: ^Checker, e: Expr) {
	type := check_single_expr(k, e)
	if type == INVALID_TYPE {
		return
	}
	if type == TYPE_UNTYPED_NIL {
		errorf(k.c, expr_span(e), "L0310", "`nil` has no type, so it has no printed form")
		return
	}
	if type_is_untyped(k.c, type) {
		if !materialize(k, e, default_type(k.c, type)) {
			return
		}
		type = expr_base(e).type
	}
	// design.md "Zero values": a `type` or descriptor exists only while
	// compiling, so there is nothing at run time to print.
	if offender := compile_time_only_component(k.c, type); offender != INVALID_TYPE {
		report_compile_time_only(k, offender, expr_span(e))
		return
	}
	// design.md "Capture literals": a callable has no printed form.
	if !type_is_printable(k.c, type) {
		errorf(k.c, expr_span(e), "L0310", "`%s` has no printed form", type_name(k.c, type))
		return
	}
	request_typeid(k.c, type)
}

// `static_assert(condition[, message])` answers here, whatever phase surrounds it.
@(private = "file")
check_static_assert :: proc(k: ^Checker, v: ^Expr_Call) {
	v.type = INVALID_TYPE
	if len(v.args) < 1 || len(v.args) > 2 {
		errorf(k.c, v.span, "L0387", "`static_assert` takes a condition and an optional message")
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	v.type = TYPE_VOID
	check_condition(k, v.args[0].value)
	message := ""
	if len(v.args) == 2 {
		check_message_arg(k, v.args[1].value, formatted = false)
		if base := expr_base(v.args[1].value); base.const_value.kind == .String {
			message = base.const_value.text
		}
	}
	folded, evaluated := require_const(k, v.args[0].value, "a `static_assert` condition", "L0387")
	if !evaluated {
		v.type = INVALID_TYPE
		return
	}
	if folded.kind == .Boolean && !folded.boolean {
		// design.md "Interface bodies": a failed interface application names the
		// requirement, not a bare "static assertion failed".
		if report_failed_interface_bound(k, v.args[0].value, v.span) {
			if message != "" {
				add_notef(k.c, v.span, "%s", message)
			}
			return
		}
		errorf(
			k.c,
			v.span,
			"L0387",
			"static assertion failed%s",
			message == "" ? "" : concat(k.c, ": ", message),
		)
	}
}

// `build_config(NAME, default)`: the name is a token, and the default fixes the
// result's type and what an override may say.
@(private = "file")
check_config :: proc(k: ^Checker, v: ^Expr_Call) {
	v.type = INVALID_TYPE
	if len(v.args) != 2 {
		errorf(k.c, v.span, "L0388", "`build_config` takes a name and a default value")
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	name, is_ident := v.args[0].value.(^Expr_Ident)
	if !is_ident {
		errorf(k.c, expr_span(v.args[0].value), "L0388", "`build_config` needs a name")
		return
	}
	if check_single_expr(k, v.args[1].value) == INVALID_TYPE {
		return
	}
	fallback, evaluated := require_const(k, v.args[1].value, "a `build_config` default", "L0388")
	if !evaluated {
		return
	}
	#partial switch fallback.kind {
	case .Boolean, .Integer, .String:
	case:
		errorf(k.c, expr_span(v.args[1].value), "L0388", "a `build_config` default must be a boolean, an integer, or a string")
		return
	}

	v.type = expr_base(v.args[1].value).type
	v.is_const = true
	v.const_value = fallback
	override, defined := k.c.defines[name.name]
	if !defined {
		return
	}
	if override.kind != fallback.kind {
		errorf(
			k.c,
			v.span,
			"L0388",
			"`-define:%s` gives %s, but this `build_config` defaults to %s",
			name.name,
			const_kind_name(override.kind),
			const_kind_name(fallback.kind),
		)
		return
	}
	if fallback.kind == .Integer && !type_is_untyped(k.c, v.type) {
		if !bi_fits(k.c, override.integer, type_bits(k.c, v.type), type_signed(k.c, v.type)) {
			errorf(
				k.c,
				v.span,
				"L0388",
				"`-define:%s=%s` is not representable by `%s`",
				name.name,
				bi_text(k.c, override.integer),
				type_name(k.c, v.type),
			)
			return
		}
		// design.md "Invalid representations": checked code never makes a
		// non-member.
		if type_is_enum(k.c, v.type) && enum_member_by_value(k.c, v.type, override) == INVALID_SYMBOL {
			errorf(
				k.c,
				v.span,
				"L0388",
				"`-define:%s=%s` names no variant of `%s`",
				name.name,
				bi_text(k.c, override.integer),
				type_name(k.c, v.type),
			)
			return
		}
	}
	v.const_value = override
}

@(private = "file")
const_kind_name :: proc(kind: Const_Kind) -> string {
	#partial switch kind {
	case .Boolean:
		return "a boolean"
	case .Integer:
		return "an integer"
	case .String:
		return "a string"
	}
	return "a value"
}

// `size_of`, `align_of`, and `offset_of` inspect their operand's type and fold;
// the operand is never evaluated.
@(private = "file")
check_layout_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	if !builtin_arity_ok(k, v, ident, "L0322", kind == .Offset_Of ? 2 : 1) {
		return
	}

	operand := operand_type(k, v.args[0].value, ident.name, true)
	if operand == INVALID_TYPE || !gate_type(k, operand, expr_span(v.args[0].value)) {
		return
	}

	result := u64(0)
	#partial switch kind {
	case .Size_Of:
		result = type_size(k.c, operand, expr_span(v.args[0].value))
	case .Align_Of:
		result = type_align(k.c, operand, expr_span(v.args[0].value))
	case .Offset_Of:
		// A member name, not a value: resolving it would find a same-named variable.
		name, is_ident := v.args[1].value.(^Expr_Ident)
		if !is_ident {
			errorf(k.c, expr_span(v.args[1].value), "L0386", "`offset_of` needs a field name")
			return
		}
		field := struct_field(k.c, operand, intern_identifier(k.c, name.name))
		if field == INVALID_SYMBOL {
			errorf(k.c, name.span, "L0363", "`%s` has no field `%s`", type_name(k.c, operand), name.name)
			return
		}
		if !require_visible_field(k, name.span, operand, field, "L0472", "measured with `offset_of`") {
			return
		}
		name.symbol = field
		name.resolution = Resolution{kind = .Field, symbol = field}
		result = type_field_offset(k.c, operand, int(symbol_of(k.c, field).index), name.span)
	}
	v.type = TYPE_INT
	v.is_const = true
	v.const_value = int_const(k.c, i64(result))
}

// design.md "Built-in procedures": `is_copyable(T)` is false exactly when `T` is
// move-only, the same question the move-only diagnostics ask. `is_union(T)` asks
// what per-variant expansion asks of its subject. Neither evaluates its operand.
@(private = "file")
check_type_predicate_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, builtin: Builtin_Kind) {
	if !builtin_arity_ok(k, v, ident, "L0322", 1) {
		return
	}
	operand := operand_type(k, v.args[0].value, ident.name, true)
	if operand == INVALID_TYPE {
		return
	}
	// A kind needs no runtime storage, so a reflection descriptor or an
	// interface is simply not a union. Copying asks about runtime values.
	if builtin == .Is_Copyable && !gate_type(k, operand, expr_span(v.args[0].value)) {
		return
	}
	v.type = TYPE_BOOL
	v.is_const = true
	// design.md "Distinct types": a distinct type over a union is not one here.
	holds := builtin == .Is_Union ? type_kind(k.c, operand) == .Union : !type_clone_disabled(k.c, operand)
	v.const_value = bool_const(holds)
}

// The type an operand denotes, checked once and never evaluated. Only
// `accepts_value` built-ins take a value's type, defaulting an untyped constant
// as a declaration would.
operand_type :: proc(k: ^Checker, e: Expr, builtin: string, accepts_value: bool) -> Type_Id {
	// The type reading comes first. It is silent for non-type syntax, so an
	// error means broken type syntax, which the value reading would report again.
	before := k.c.error_count
	if denoted := resolve_type_syntax(k, e); denoted != INVALID_TYPE {
		return denoted
	}
	if k.c.error_count != before || check_single_expr(k, e) == INVALID_TYPE {
		return INVALID_TYPE
	}
	base := expr_base(e)
	if base.value_category == .Type {
		return base.denoted_type
	}
	if !accepts_value {
		errorf(k.c, expr_span(e), "L0386", "`%s` needs a type, found a value of type `%s`", builtin, type_name(k.c, base.type))
		return INVALID_TYPE
	}
	if !type_is_untyped(k.c, base.type) {
		return base.type
	}
	typed := default_type(k.c, base.type)
	if typed == INVALID_TYPE {
		errorf(k.c, expr_span(e), "L0386", "`%s` needs a typed value, found `%s`", builtin, type_name(k.c, base.type))
		return INVALID_TYPE
	}
	return materialize(k, e, typed) ? typed : INVALID_TYPE
}

// design.md "Allocators": `free_all(allocator)`, and design.md "The `unsafe`
// package": `unsafe.free(pointer[, allocator])`. Neither returns anything, and
// an omitted allocator is the default.
@(private = "file")
check_allocation_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.type = INVALID_TYPE
	arity_high := kind == .Free_All ? 1 : 2
	if len(v.args) < 1 || len(v.args) > arity_high {
		errorf(
			k.c,
			v.span,
			"L0490",
			"`%s` takes %s",
			ident.name,
			arity_high == 1 ? "one argument" : "an operand and an optional allocator",
		)
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}

	#partial switch kind {
	case .Unsafe_Free:
		pointer := check_single_expr(k, v.args[0].value)
		// `unsafe.free` is spelled through its package, whose import is the gate.
		if pointer == INVALID_TYPE || !check_free_operand(k, v.args[0].value, pointer) {
			return
		}

	case .Free_All:
		// Whether the reset is allowed is region provenance (`src/borrow.odin`).
		allocator := check_single_expr(k, v.args[0].value, TYPE_ALLOCATOR)
		if allocator == INVALID_TYPE {
			return
		}
		if type_underlying(k.c, allocator) != TYPE_ALLOCATOR {
			errorf(k.c, expr_span(v.args[0].value), "L0490", "`free_all` names the allocator being reset, found `%s`", type_name(k.c, allocator))
			return
		}
	}

	bound := make([]Expr, len(v.args), k.c.semantic_allocator)
	bound[0] = v.args[0].value
	// The allocator stays bound, so the backend never re-derives it.
	if len(v.args) == 2 {
		allocator := check_single_expr(k, v.args[1].value, TYPE_ALLOCATOR)
		if allocator == INVALID_TYPE {
			return
		}
		if type_underlying(k.c, allocator) != TYPE_ALLOCATOR {
			errorf(
				k.c,
				expr_span(v.args[1].value),
				"L0490",
				"an allocator argument is an `Allocator`, found `%s`",
				type_name(k.c, allocator),
			)
			return
		}
		bound[1] = v.args[1].value
	}
	v.bound = bound
	v.type = TYPE_VOID
}

// `unsafe.free` releases the allocation a typed address names: a `[^]T` from
// `unsafe.new`, or a `^mut T` the caller rebuilt. The element type is what the
// allocator is told the size of.
@(private = "file")
check_free_operand :: proc(k: ^Checker, e: Expr, pointer: Type_Id) -> bool {
	info := underlying_info(k.c, pointer)
	if info != nil && (info.kind == .C_Pointer || (info.kind == .Pointer && info.mutable)) {
		return true
	}
	errorf(
		k.c, expr_span(e), "L0493",
		"`unsafe.free` takes the `[^]T` or `^mut T` of an allocation, found `%s`", type_name(k.c, pointer),
	)
	return false
}

// The written destination type of `unsafe.transmute` or `math.wrap`: a variable
// here is a mistake, not `type_of(x)`. An error from the reading itself is the
// report; otherwise this wasn't type syntax at all.
@(private = "file")
check_destination_type :: proc(k: ^Checker, e: Expr, code, builtin: string) -> Type_Id {
	before := k.c.error_count
	target := resolve_type_syntax(k, e)
	if target == INVALID_TYPE && k.c.error_count == before {
		errorf(k.c, expr_span(e), code, "`%s` names the destination type first", builtin)
	}
	return target
}

// design.md "`unsafe.transmute`": reads `value`'s storage as a `T`. Only equal
// size and trivial lifecycles are checked; the meaning is the caller's.
@(private = "file")
check_transmute_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.type = INVALID_TYPE
	if len(v.args) != 2 {
		errorf(
			k.c, v.span, "L0688",
			"`unsafe.%s` takes a destination type and a value, found %d argument%s",
			ident.name, len(v.args), len(v.args) == 1 ? "" : "s",
		)
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	target := check_destination_type(k, v.args[0].value, "L0688", "unsafe.transmute")
	if target == INVALID_TYPE || !gate_type(k, target, expr_span(v.args[0].value)) {
		return
	}
	source, ok := check_defaulted_operand(k, v.args[1].value)
	if !ok {
		return
	}
	if !transmute_side_ok(k, source, expr_span(v.args[1].value), "source") ||
	   !transmute_side_ok(k, target, expr_span(v.args[0].value), "destination") {
		return
	}
	if type_size(k.c, source) != type_size(k.c, target) {
		errorf(
			k.c, v.span, "L0688",
			"`unsafe.transmute` needs equal sizes: `%s` is %d byte%s and `%s` is %d byte%s",
			type_name(k.c, source), type_size(k.c, source), type_size(k.c, source) == 1 ? "" : "s",
			type_name(k.c, target), type_size(k.c, target), type_size(k.c, target) == 1 ? "" : "s",
		)
		return
	}
	v.bound = bound_exprs(k, v.args[1].value)
	v.type = target
	fold_transmute(k, v, source, target)
}

// A managed side could duplicate or forge an owner, and a borrow carrier a loan
// the analysis never saw. `rawptr` and `[^]T` carry neither. A type written where
// the value goes is compile-time only, with no storage to read.
@(private = "file")
transmute_side_ok :: proc(k: ^Checker, type: Type_Id, span: Span, side: string) -> bool {
	reason := ""
	switch {
	case compile_time_only_component(k.c, type) != INVALID_TYPE:
		reason = "exists only during compilation"
	case type_is_managed(k.c, type):
		reason = "has a non-trivial lifecycle"
	case type_carries_borrow(k.c, type).any:
		reason = "is or contains a reference"
	case underlying_kind(k.c, type) == .Void:
		reason = "has no storage"
	}
	if reason == "" {
		return true
	}
	errorf(
		k.c, span, "L0688",
		"an `unsafe.transmute` %s type must be bitwise-copyable: `%s` %s",
		side, type_name(k.c, type), reason,
	)
	return false
}

// A scalar bit cast of a constant folds, which is how `core:math` spells an
// infinity or a NaN as a constant. An aggregate result is left to the
// evaluator, which a compile-time context asks.
@(private = "file")
fold_transmute :: proc(k: ^Checker, v: ^Expr_Call, source, target: Type_Id) {
	base := expr_base(v.args[1].value)
	if !base.is_const {
		return
	}
	#partial switch underlying_kind(k.c, target) {
	case .Float, .Bool, .Int, .Rune, .Enum, .Typeid:
	case:
		return
	}
	folded, status := transmute_const(k.c, base.const_value, source, target)
	#partial switch status {
	case .Invalid:
		// A `bool` outside {0, 1}, or an enum with no such member.
		errorf(
			k.c, v.span, "L0688",
			"this bit pattern is not a valid `%s`", type_name(k.c, target),
		)
		v.type = INVALID_TYPE
	case .Folded:
		v.is_const = true
		v.const_value = folded
		v.bound = nil
	}
}

// design.md "Type conversion": `math.wrap(T, value)` converts between integer
// types, or between integer vectors of one lane count, keeping the low bits.
@(private = "file")
check_wrap_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
	v.type = INVALID_TYPE
	if len(v.args) != 2 {
		errorf(
			k.c, v.span, "L0712",
			"`math.wrap` takes a destination type and a value, found %d argument%s",
			len(v.args), len(v.args) == 1 ? "" : "s",
		)
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	target := check_destination_type(k, v.args[0].value, "L0712", "math.wrap")
	if target == INVALID_TYPE {
		return
	}
	source, ok := check_defaulted_operand(k, v.args[1].value)
	if !ok {
		return
	}
	if !wrap_operands_ok(k.c, source, target) {
		errorf(
			k.c, v.span, "L0712",
			"`math.wrap` converts an integer to an integer type; found `%s` to `%s`",
			type_name(k.c, source), type_name(k.c, target),
		)
		return
	}
	v.bound = bound_exprs(k, v.args[1].value)
	v.type = target
	if base := expr_base(v.args[1].value); base.is_const && (base.const_value.kind == .Integer || base.const_value.kind == .Rune) {
		v.is_const = true
		v.const_value = base.const_value
		v.const_value.kind = type_is_rune(k.c, target) ? .Rune : .Integer
		v.const_value.integer = wrap_to_type(k.c, base.const_value.integer, target)
		v.bound = nil
	}
}

// An enum source wraps its backing value; a destination is a plain integer.
@(private = "file")
wrap_operands_ok :: proc(c: ^Compiler, source, target: Type_Id) -> bool {
	from, to := type_underlying(c, source), type_underlying(c, target)
	if type_is_simd(c, from) && type_is_simd(c, to) {
		left, right := type_of(c, from), type_of(c, to)
		if left.count != right.count {
			return false
		}
		from, to = type_underlying(c, left.element), type_underlying(c, right.element)
	}
	integral := type_is_integer(c, from) || type_is_rune(c, from) || underlying_kind(c, from) == .Enum
	return integral && (type_is_integer(c, to) || type_is_rune(c, to))
}

// A copy of `fma_instruction` without the instruction traps on it rather than
// calling LLVM's libcall, the C library's `fma`.
@(private = "file")
check_float_instruction_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	wanted, shape := 1, "an `f32` or `f64` operand"
	#partial switch kind {
	case .Math_Mod_Instruction:
		wanted, shape = 2, "two `f32` or two `f64` operands"
	case .Math_Fma_Instruction:
		wanted, shape = 3, "three `f32` or three `f64` operands"
	}
	if !builtin_arity_ok(k, v, ident, "L0738", wanted) {
		return
	}
	bound := make([]Expr, wanted, k.c.semantic_allocator)
	operand := INVALID_TYPE
	for arg, index in v.args {
		type, ok := check_defaulted_operand(k, arg.value)
		if !ok {
			return
		}
		if (type != TYPE_F32 && type != TYPE_F64) || (operand != INVALID_TYPE && type != operand) {
			errorf(k.c, expr_span(arg.value), "L0738", "`%s` takes %s; found `%s`", ident.name, shape, type_name(k.c, type))
			return
		}
		operand = type
		bound[index] = arg.value
	}
	v.bound = bound
	v.type = operand
}

// The count is an `int` whatever the operand's width, as a length is. A vector
// is refused: the lane-wise forms are not specified.
@(private = "file")
check_bit_count_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	arg, type, ok := check_bit_operand(k, v, ident)
	if !ok {
		return
	}
	v.type = TYPE_INT
	if base := expr_base(arg); base.is_const && base.const_value.kind == .Integer {
		count := bit_count(base.const_value.integer, type_bits(k.c, type), kind)
		v.is_const = true
		v.const_value = int_const(k.c, i64(count))
	}
}

// A constant `next_power_of_two` that does not fit is design.md "Integer
// overflow"'s compile-time diagnostic. An `Option` is not a constant, so the
// checked form folds only by evaluation.
@(private = "file")
check_bit_value_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	arg, type, ok := check_bit_operand(k, v, ident)
	if !ok {
		return
	}
	if kind == .Math_Checked_Next_Power_Of_Two {
		v.type = option_type(k, type, v.span)
		return
	}
	v.type = kind == .Math_Is_Power_Of_Two ? TYPE_BOOL : type
	base := expr_base(arg)
	if !base.is_const || base.const_value.kind != .Integer {
		return
	}
	result, fits := bit_value_const(k.c, base.const_value.integer, type, kind)
	if !fits {
		report_integer_overflow(k.c, v.span, result.integer, type)
		v.type = INVALID_TYPE
		return
	}
	v.is_const = true
	v.const_value = result
}

// The call stays invalid until the caller sets its result type.
@(private = "file")
check_bit_operand :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) -> (arg: Expr, type: Type_Id, ok: bool) {
	if !builtin_arity_ok(k, v, ident, "L0738", 1) {
		return
	}
	arg = v.args[0].value
	type, ok = check_integer_operand(k, arg, ident)
	if !ok {
		return
	}
	v.bound = bound_exprs(k, arg)
	return arg, type, true
}

// A value of an integer type, distinct ones included; an unfixed constant is an
// `int`.
@(private = "file")
check_integer_operand :: proc(k: ^Checker, e: Expr, ident: ^Expr_Ident) -> (type: Type_Id, ok: bool) {
	type, ok = check_defaulted_operand(k, e)
	if !ok {
		return
	}
	if !type_is_integer(k.c, type) {
		errorf(k.c, expr_span(e), "L0738", "`%s` takes a value of an integer type; found `%s`", ident.name, type_name(k.c, type))
		return type, false
	}
	return type, true
}

@(private = "file")
check_rotate_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	if !builtin_arity_ok(k, v, ident, "L0738", 2) {
		return
	}
	value, count := v.args[0].value, v.args[1].value
	type, ok := check_integer_operand(k, value, ident)
	if !ok {
		return
	}
	count_type := check_single_expr(k, count)
	if count_type == INVALID_TYPE {
		return
	}
	if count_type != TYPE_INT && !type_is_untyped(k.c, count_type) {
		errorf(k.c, expr_span(count), "L0738", "`%s` takes an `int` count; found `%s`", ident.name, type_name(k.c, count_type))
		return
	}
	if !materialize(k, count, TYPE_INT) {
		return
	}
	v.bound = bound_exprs(k, value, count)
	v.type = type
	base, by := expr_base(value), expr_base(count)
	if base.is_const && base.const_value.kind == .Integer && by.is_const && by.const_value.kind == .Integer {
		v.is_const = true
		v.const_value = integer_const(rotate_const(k.c, base.const_value.integer, by.const_value.integer, type, kind))
	}
}

// ------------------------------------------------------- source locations --

// design.md "`source_location() or source_location(<entity>)`" and
// "`caller_location()`": a constant `runtime.Source_Code_Location` for the call,
// or for a named entity's declaration. A `caller_location()` default is folded
// again at every call that omits it, by `substitute_caller_location`.
@(private = "file")
check_location :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.type = INVALID_TYPE
	// Positional value arguments only (design.md "Parameters").
	if !builtin_arguments_ok(k, v) {
		return
	}
	type, resolved := runtime_type_named(k, "Source_Code_Location", SOURCE_CODE_LOCATION_LAYOUT[:])
	if !resolved {
		errorf(
			k.c, v.span, "L0573",
			"`%s` produces a `runtime.Source_Code_Location`, and this program's `base:runtime` declares none",
			ident.name,
		)
		return
	}
	span, procedure := v.span, proc_literal_name(k.c, k.proc_literal)
	switch {
	case len(v.args) == 0:
	case kind == .Caller_Location:
		errorf(k.c, v.span, "L0573", "`caller_location` takes no arguments, found %d", len(v.args))
		return
	case len(v.args) > 1:
		errorf(k.c, v.span, "L0573", "`source_location` takes at most one name, found %d", len(v.args))
		return
	case:
		ok: bool
		span, procedure, ok = entity_declaration(k, v.args[0].value)
		if !ok {
			return
		}
	}
	if type == INVALID_TYPE {
		return
	}
	v.type = type
	v.is_const = true
	v.const_value = source_location_const(k, type, span, procedure)
}

// `{file, procedure: string_view, line, column: int}`, over the type this
// package's `base:runtime` declares.
@(private = "file")
source_location_const :: proc(k: ^Checker, type: Type_Id, span: Span, procedure: string) -> Const_Value {
	file, line, column := "", 0, 0
	if span.file != NO_FILE && int(span.file) < len(k.c.sources) {
		source := &k.c.sources[span.file]
		file = source.path
		line, column = line_col(source, span.lo)
	}
	elements := make([]Const_Value, 4, k.c.semantic_allocator)
	elements[0] = Const_Value{kind = .String, text = file}
	elements[1] = Const_Value{kind = .String, text = procedure}
	elements[2] = int_const(k.c, i64(line))
	elements[3] = int_const(k.c, i64(column))
	aggregate := new(Const_Aggregate, k.c.semantic_allocator)
	aggregate.type = type
	aggregate.elements = elements
	return Const_Value{kind = .Aggregate, aggregate = aggregate}
}

@(private = "file")
proc_literal_name :: proc(c: ^Compiler, literal: ^Expr_Proc) -> string {
	if literal != nil && literal.symbol != INVALID_SYMBOL {
		if sym := symbol_of(c, literal.symbol); sym != nil {
			return identifier_text(c, sym.name)
		}
	}
	return ""
}

// Where a named variable or procedure is declared, and the procedure that
// declaration belongs to: a procedure's own, or for a variable the one around
// it, if any.
@(private = "file")
entity_declaration :: proc(k: ^Checker, e: Expr) -> (span: Span, procedure: string, ok: bool) {
	if ident, is_ident := e.(^Expr_Ident); is_ident {
		symbol_id, scope := lookup_symbol_with_scope(k.scope, identifier_of(k.c, ident))
		if sym := symbol_of(k.c, symbol_id); sym != nil {
			// design.md "Test procedures": naming a test is an error here too.
			if reject_test_procedure_use(k, sym, ident.name, ident.span) {
				return
			}
			#partial switch sym.kind {
			case .Proc, .Proc_Group:
				return sym.span, identifier_text(k.c, sym.name), true
			case .Var, .Parameter:
				return sym.span, proc_literal_name(k.c, (^Expr_Proc)(scope.owner_proc)), true
			}
		}
	}
	errorf(k.c, expr_span(e), "L0573", "`source_location` takes the name of a variable or a procedure")
	return
}

// An omitted argument whose default is `caller_location()`, folded for *this*
// call. Any other default passes through untouched.
substitute_caller_location :: proc(k: ^Checker, default: Expr, at: Span) -> Expr {
	call, is_call := default.(^Expr_Call)
	if !is_call || call.type == INVALID_TYPE {
		return default
	}
	sym := symbol_of(k.c, call.resolution.symbol)
	if sym == nil || sym.kind != .Builtin || sym.builtin != .Caller_Location {
		return default
	}
	substituted := new(Expr_Call, k.c.semantic_allocator)
	substituted^ = call^
	substituted.span = at
	substituted.const_value = source_location_const(k, call.type, at, proc_literal_name(k.c, k.proc_literal))
	return substituted
}

// ------------------------------------------------------ runtime metadata --

// design.md "`type` and `typeid`": `type_info_of(id)` maps a runtime `typeid` to
// a read-only `^runtime.Type_Info` from a shared static table, nil for any id
// without an entry, since a `typeid` can be forged.
@(private = "file")
check_type_info_of :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	if !builtin_arity_ok(k, v, ident, "L0322", 1) {
		return
	}
	record, resolved := runtime_type_named(k, "Type_Info", TYPE_INFO_LAYOUT[:])
	// The table's member record is resolved with it, not on first use.
	members, members_resolved := runtime_type_named(k, "Member_Info", MEMBER_INFO_LAYOUT[:])
	if !resolved || !members_resolved {
		errorf(
			k.c, v.span, "L0575",
			"`type_info_of` produces a `^runtime.Type_Info`, and this program's `base:runtime` declares none",
		)
		return
	}
	if record == INVALID_TYPE || members == INVALID_TYPE {
		return
	}
	operand := check_single_expr(k, v.args[0].value, TYPE_TYPEID)
	if operand == INVALID_TYPE {
		return
	}
	if type_underlying(k.c, operand) != TYPE_TYPEID {
		errorf(
			k.c, expr_span(v.args[0].value), "L0575",
			"`type_info_of` takes a `typeid`, found `%s`", type_name(k.c, operand),
		)
		return
	}
	if committing(k.c) {
		k.c.type_info_requested = true
	}
	v.bound = bound_exprs(k, v.args[0].value)
	v.type = pointer_to(k.c, record, false)
}
