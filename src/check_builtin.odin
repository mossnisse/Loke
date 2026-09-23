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
	case .Is_Copyable:
		check_is_copyable_builtin(k, v, ident)
	case .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of:
		check_reflection_builtin(k, v, ident, sym.builtin)
	case .Make:
		check_make_builtin(k, v)
	case .Simd_Cast, .Simd_Select, .Simd_Reduce:
		check_simd_builtin(k, v, ident, sym.builtin)
	case .New, .New_Clone, .Free, .Unsafe_Free, .Free_All:
		check_allocation_builtin(k, v, ident, sym.builtin)
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
	case .Type_Info_Of:
		check_type_info_of(k, v)
	case .Strings_Allocate:
		check_strings_allocate(k, v, ident)
	case .Slice_Sort_By:
		check_slice_sort_by(k, v, ident)
	case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
	     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
		check_atomic_builtin(k, v, ident, sym.builtin)
	case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes, .Fmt_Format_Any:
		check_fmt_builtin(k, v, ident, sym.builtin)
	case .Default_Allocator:
		if len(v.args) != 0 {
			errorf(k.c, v.span, "L0490", "`default_allocator` takes no arguments")
			v.type = INVALID_TYPE
			return
		}
		v.bound = nil
		v.type = TYPE_ALLOCATOR
	case .None:
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
	}
}

// `core:slice.sort_by_intrinsic(values, &comparator)`. The public wrapper already
// requires `slice.Comparator(C, T)`; this records the exact `call` method for
// lowering and guards against a malformed replacement standard package.
@(private = "file")
check_slice_sort_by :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
	v.type = INVALID_TYPE
	if len(v.args) != 2 {
		errorf(k.c, v.span, "L0322", "`%s` takes 2 arguments, found %d", ident.name, len(v.args))
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}

	values := check_single_expr(k, v.args[0].value)
	values_info := underlying_info(k.c, values)
	if values_info == nil || values_info.kind != .Slice || !values_info.mutable {
		errorf(
			k.c, expr_span(v.args[0].value), "L0651",
			"`%s` needs a mutable slice, found `%s`", ident.name, type_name(k.c, values),
		)
		return
	}

	ctx := check_single_expr(k, v.args[1].value)
	context_info := underlying_info(k.c, ctx)
	if context_info == nil || context_info.kind != .Pointer {
		errorf(
			k.c, expr_span(v.args[1].value), "L0651",
			"`%s` needs a pointer to its comparator, found `%s`", ident.name, type_name(k.c, ctx),
		)
		return
	}

	element := values_info.element
	comparator := context_info.element
	name := intern_identifier(k.c, "call")
	match := INVALID_SYMBOL
	matches := 0
	for candidate in method_candidates(k, comparator, name) {
		sym := symbol_of(k.c, candidate)
		if sym != nil && slot_matches(
			k, sym,
			[]Type_Id{comparator, element, element},
			[]Param_Mode{.Borrow, .Value, .Value},
			TYPE_BOOL, false,
		) {
			match = candidate
			matches += 1
		}
	}
	if matches != 1 {
		errorf(
			k.c, v.span, "L0651",
			"`%s` must provide exactly one `call(self, left: %s, right: %s) -> bool` method for sorting",
			type_name(k.c, comparator), type_name(k.c, element), type_name(k.c, element),
		)
		return
	}

	v.bound = make([]Expr, 2, k.c.semantic_allocator)
	v.bound[0] = v.args[0].value
	v.bound[1] = v.args[1].value
	v.operation = Call_Sort_By{comparator = match}
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

// Whether every argument is a positional value, reporting the first that isn't.
@(private = "file")
builtin_arguments_ok :: proc(k: ^Checker, v: ^Expr_Call) -> bool {
	for arg in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			reject_builtin_argument_shape(k, arg)
			return false
		}
	}
	return true
}

// `assert(condition[, message])` and `panic([message])`. Neither folds: the
// evaluator diagnoses a compile-time occurrence and the backend lowers the rest.
@(private = "file")
check_assert_or_panic :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.type = INVALID_TYPE
	first := kind == .Assert ? 1 : 0
	if len(v.args) < first || len(v.args) > first + 1 {
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
		if kind == .Assert && index == 0 {
			check_condition(k, arg.value)
		} else {
			check_message_arg(k, arg.value)
		}
	}
	v.bound = bound
	v.type = TYPE_VOID
}

// `static_assert(condition[, message])` answers here, whatever phase surrounds it.
@(private = "file")
check_static_assert :: proc(k: ^Checker, v: ^Expr_Call) {
	v.type = INVALID_TYPE
	v.value_category = .Value
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
		check_message_arg(k, v.args[1].value)
		if base := expr_base(v.args[1].value); base != nil && base.const_value.kind == .String {
			message = base.const_value.text
		}
	}
	folded, evaluated := require_const(k, v.args[0].value, "a `static_assert` condition", "L0387")
	if !evaluated {
		v.type = INVALID_TYPE
		return
	}
	if folded.kind == .Boolean && !folded.boolean {
		// design.md: a failed interface application names the requirement, not a
		// bare "static assertion failed".
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
	v.value_category = .Value
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
	v.type = INVALID_TYPE
	arity := kind == .Offset_Of ? 2 : 1
	if len(v.args) != arity {
		errorf(
			k.c,
			v.span,
			"L0322",
			"`%s` takes %d argument%s, found %d",
			ident.name,
			arity,
			arity == 1 ? "" : "s",
			len(v.args),
		)
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	// Folded, so nothing is bound for the backend to emit.
	v.bound = nil

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
// move-only, the same question the move-only diagnostics ask.
@(private = "file")
check_is_copyable_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.type = INVALID_TYPE
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0322", "`%s` takes 1 argument, found %d", ident.name, len(v.args))
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	operand := operand_type(k, v.args[0].value, ident.name, true)
	if operand == INVALID_TYPE || !gate_type(k, operand, expr_span(v.args[0].value)) {
		return
	}
	v.type = TYPE_BOOL
	v.is_const = true
	v.const_value = bool_const(!type_clone_disabled(k.c, operand))
}

// The type an operand denotes, checked once and never evaluated. Only
// `accepts_value` built-ins take a value's type, defaulting an untyped constant
// as a declaration would.
@(private = "file")
operand_type :: proc(k: ^Checker, e: Expr, builtin: string, accepts_value: bool) -> Type_Id {
	if e == nil {
		return INVALID_TYPE
	}
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

// design.md "Allocators": `new(T[, allocator])` and `new_clone(value[, allocator])`
// return their `Allocator_Error`; `free(pointer[, allocator])` and
// `free_all(allocator)` return nothing. An omitted allocator is the default.
@(private = "file")
check_allocation_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
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
		v.type = INVALID_TYPE
		return
	}
	if !builtin_arguments_ok(k, v) {
		v.type = INVALID_TYPE
		return
	}

	bound := make([dynamic]Expr, 0, 2, k.c.semantic_allocator)
	#partial switch kind {
	case .New:
		element := operand_type(k, v.args[0].value, ident.name, false)
		if element == INVALID_TYPE || !gate_type(k, element, expr_span(v.args[0].value)) {
			v.type = INVALID_TYPE
			return
		}
		if type_is_compile_time_only(k.c, element) {
			errorf(k.c, expr_span(v.args[0].value), "L0490", "`new` needs a runtime type, found `%s`", type_name(k.c, element))
			v.type = INVALID_TYPE
			return
		}
		if !require_type_has_zero(k, element, v.span, "`new`, which zeroes the allocation") {
			v.type = INVALID_TYPE
			return
		}
		v.operation = Call_Allocation{type = element}
		set_allocation_results(k, v, pointer_to(k.c, element, true))

	case .New_Clone:
		value := check_single_expr(k, v.args[0].value)
		if value == INVALID_TYPE || !gate_type(k, value, expr_span(v.args[0].value)) {
			v.type = INVALID_TYPE
			return
		}
		// An untyped constant is allocated at its default type.
		if type_is_untyped(k.c, value) {
			value = default_type(k.c, value)
			if value == INVALID_TYPE || !materialize(k, v.args[0].value, value) {
				v.type = INVALID_TYPE
				return
			}
		}
		append(&bound, v.args[0].value)
		v.operation = Call_Allocation{type = value}
		contribute_lifecycle_members(k, value)
		// The result shape is settled first, so a destructuring still knows its
		// arity and the move-only failure is reported once.
		set_allocation_results(k, v, pointer_to(k.c, value, true))
		if type_clone_disabled(k.c, value) {
			errorf(
				k.c,
				expr_span(v.args[0].value),
				"L0491",
				"`%s` is move-only, so it cannot be cloned into a new allocation",
				type_name(k.c, value),
			)
		}

	case .Free, .Unsafe_Free:
		pointer := check_single_expr(k, v.args[0].value)
		if pointer == INVALID_TYPE ||
		   !check_free_operand(k, v.args[0].value, pointer, kind == .Unsafe_Free ? "unsafe.free" : "free") {
			v.type = INVALID_TYPE
			return
		}
		append(&bound, v.args[0].value)
		v.type = TYPE_VOID

	case .Free_All:
		// Whether the reset is allowed is region provenance (`src/borrow.odin`).
		allocator := check_single_expr(k, v.args[0].value, TYPE_ALLOCATOR)
		if allocator == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		if type_underlying(k.c, allocator) != TYPE_ALLOCATOR {
			errorf(k.c, expr_span(v.args[0].value), "L0490", "`free_all` names the allocator being reset, found `%s`", type_name(k.c, allocator))
			v.type = INVALID_TYPE
			return
		}
		append(&bound, v.args[0].value)
		v.type = TYPE_VOID
	}

	// The allocator stays bound, so the backend never re-derives it.
	if len(v.args) == 2 {
		allocator := check_single_expr(k, v.args[1].value, TYPE_ALLOCATOR)
		if allocator != INVALID_TYPE && type_underlying(k.c, allocator) != TYPE_ALLOCATOR {
			errorf(
				k.c,
				expr_span(v.args[1].value),
				"L0490",
				"an allocator argument is an `Allocator`, found `%s`",
				type_name(k.c, allocator),
			)
			v.type = INVALID_TYPE
			return
		}
		append(&bound, v.args[1].value)
	}
	v.bound = bound[:]
}

// design.md "Dynamic arrays" and "Maps":
//
//   make([dynamic]T, len: int = 0, cap: int = len, allocator = default)
//   make(map[K]V, reservation: int = 0, allocator = default)
//
// both returning `(container, Allocator_Error)`. `Allocator` is a distinct type,
// so the trailing allocator is recognised by its type rather than its position.
@(private = "file")
check_make_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
	v.value_category = .Value
	v.type = INVALID_TYPE
	if len(v.args) == 0 {
		errorf(k.c, v.span, "L0579", "`make` names the container type to create")
		return
	}
	if !builtin_arguments_ok(k, v) {
		return
	}
	container := operand_type(k, v.args[0].value, "make", false)
	if container == INVALID_TYPE || !gate_type(k, container, expr_span(v.args[0].value)) {
		return
	}
	if !type_is_container(k.c, container) {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0579",
			"`make` creates a `[dynamic]T` or a `map[K]V`, found `%s`",
			type_name(k.c, container),
		)
		return
	}
	// A move-only element has no clone, but `make` never copies one.
	contribute_lifecycle_members(k, container)

	is_map := type_is_map(k.c, container)
	max_counts := is_map ? 1 : 2
	counts := make([dynamic]Expr, 0, 2, k.c.semantic_allocator)
	allocator: Expr
	for index in 1 ..< len(v.args) {
		argument := v.args[index].value
		// Only the last argument may be the allocator, so the others expect `int`.
		hint := index == len(v.args) - 1 ? INVALID_TYPE : TYPE_INT
		if check_single_expr(k, argument, hint) == INVALID_TYPE {
			return
		}
		if type_underlying(k.c, expr_base(argument).type) == TYPE_ALLOCATOR {
			if index != len(v.args) - 1 {
				errorf(k.c, expr_span(argument), "L0579", "the allocator is `make`'s last argument")
				return
			}
			allocator = argument
			continue
		}
		if len(counts) == max_counts {
			shape := is_map ? "a map, an optional reservation, and an optional allocator" :
				"a dynamic array type, an optional length and capacity, and an optional allocator"
			errorf(k.c, expr_span(argument), "L0579", "`make` takes %s", shape)
			return
		}
		if !materialize(k, argument, TYPE_INT) || type_underlying(k.c, expr_base(argument).type) != TYPE_INT {
			errorf(
				k.c,
				expr_span(argument),
				"L0579",
				"a `make` %s is an `int`, found `%s`",
				is_map ? "reservation" : "length or capacity",
				type_name(k.c, expr_base(argument).type),
			)
			return
		}
		append(&counts, argument)
	}

	// Fixed shape: the counts in written order, then the allocator or nil.
	bound := make([]Expr, max_counts + 1, k.c.semantic_allocator)
	for count, index in counts {
		bound[index] = count
	}
	bound[max_counts] = allocator
	v.bound = bound
	v.operation = Call_Allocation{type = container}
	// design.md "Zero values": only a length fills slots with zeroes, and a
	// constant `0` fills none.
	if !is_map && len(counts) > 0 && !is_constant_zero(counts[0]) {
		if !require_type_has_zero(
			k, container_element(k.c, container), expr_span(counts[0]), "a `make` length",
		) {
			return
		}
	}

	v.type = result_type(k, container, TYPE_ALLOCATOR_ERROR)
}

// design.md "`unsafe.transmute`": reads `value`'s storage as a `T`. Only equal
// size and trivial lifecycles are checked; the meaning is the caller's.
@(private = "file")
check_transmute_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
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
	// A written type only: a variable here is a mistake, not `type_of(x)`.
	target := resolve_type_syntax(k, v.args[0].value)
	if target == INVALID_TYPE {
		errorf(
			k.c, expr_span(v.args[0].value), "L0688",
			"`unsafe.transmute` names the destination type first",
		)
		return
	}
	if !gate_type(k, target, expr_span(v.args[0].value)) {
		return
	}
	source := check_single_expr(k, v.args[1].value)
	if source == INVALID_TYPE || !materialize(k, v.args[1].value, default_type(k.c, source)) {
		return
	}
	source = expr_base(v.args[1].value).type
	if source == INVALID_TYPE {
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
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[1].value
	v.bound = bound
	v.type = target
	fold_transmute(k, v, source, target)
}

// A managed side could duplicate or forge an owner, and a borrow carrier a loan
// the analysis never saw. `rawptr` and `[^]T` carry neither.
@(private = "file")
transmute_side_ok :: proc(k: ^Checker, type: Type_Id, span: Span, side: string) -> bool {
	reason := ""
	switch {
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
// infinity or a NaN as a constant.
@(private = "file")
fold_transmute :: proc(k: ^Checker, v: ^Expr_Call, source, target: Type_Id) {
	base := expr_base(v.args[1].value)
	if base == nil || !base.is_const || type_size(k.c, target) > 8 {
		return
	}
	raw, encoded := const_scalar_pattern(k.c, base.const_value, source)
	if !encoded {
		return
	}
	folded, status := const_from_pattern(k.c, raw, target)
	switch status {
	case .Unfoldable:
		return
	case .Invalid:
		// A `bool` outside {0, 1}, a non-rune, or an enum with no such member.
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

Const_Pattern :: enum {
	Folded,
	// Not a value of the type at all.
	Invalid,
	// Valid, but with no constant spelling (a pointer or an aggregate).
	Unfoldable,
}

// A scalar constant's storage bits, if it has any.
const_scalar_pattern :: proc(c: ^Compiler, value: Const_Value, type: Type_Id) -> (u64, bool) {
	info := underlying_info(c, type)
	if info == nil {
		return 0, false
	}
	#partial switch info.kind {
	case .Float:
		if value.kind != .Float {
			return 0, false
		}
		return const_float_pattern(value, info.bits), true
	case .Bool:
		if value.kind != .Boolean {
			return 0, false
		}
		return value.boolean ? 1 : 0, true
	case .Int, .Rune, .Enum:
		if value.kind != .Integer && value.kind != .Rune {
			return 0, false
		}
		bits := info.kind == .Rune ? u16(32) : info.bits
		signed := info.kind == .Rune ? true : info.signed
		pattern, ok := bi_to_u64(c, bi_wrap(c, value.integer, int(bits), signed))
		return pattern, ok
	}
	return 0, false
}

// The constant a bit pattern denotes in `type`.
const_from_pattern :: proc(c: ^Compiler, raw: u64, type: Type_Id) -> (Const_Value, Const_Pattern) {
	info := underlying_info(c, type)
	if info == nil {
		return {}, .Unfoldable
	}
	#partial switch info.kind {
	case .Float:
		return float_bits_const(raw, info.bits), .Folded
	case .Bool:
		if raw > 1 {
			return {}, .Invalid
		}
		return bool_const(raw == 1), .Folded
	case .Int:
		return integer_const(bi_wrap(c, bi_from_u64(c, raw), int(info.bits), info.signed)), .Folded
	case .Rune:
		wrapped := bi_wrap(c, bi_from_u64(c, raw), 32, true)
		// design.md: a `rune` excludes surrogates and anything above U+10FFFF.
		if point, fits := bi_to_i64(c, wrapped); !fits || point < 0 || point > 0x10ffff ||
		   (point >= 0xd800 && point <= 0xdfff) {
			return {}, .Invalid
		}
		return rune_const(wrapped), .Folded
	case .Enum:
		wrapped := bi_wrap(c, bi_from_u64(c, raw), int(info.bits), info.signed)
		candidate := integer_const(wrapped)
		if enum_member_by_value(c, type, candidate) == INVALID_SYMBOL {
			return {}, .Invalid
		}
		return candidate, .Folded
	}
	return {}, .Unfoldable
}

@(private = "file")
is_constant_zero :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base.is_const && base.const_value.kind == .Integer && bi_is_zero(base.const_value.integer)
}

@(private = "file")
set_allocation_results :: proc(k: ^Checker, v: ^Expr_Call, pointer: Type_Id) {
	v.type = result_type(k, pointer, TYPE_ALLOCATOR_ERROR)
	v.value_category = .Value
}

// `free` needs a `^mut T`; whether it is really an allocation base, and not yet
// released, is root provenance (`src/borrow.odin`). `unsafe.free` shares the
// shape under its own name.
@(private = "file")
check_free_operand :: proc(k: ^Checker, e: Expr, pointer: Type_Id, form: string) -> bool {
	if underlying_kind(k.c, pointer) != .Pointer {
		errorf(k.c, expr_span(e), "L0493", "`%s` takes an allocation pointer, found `%s`", form, type_name(k.c, pointer))
		return false
	}
	if !pointer_is_mutable(k.c, pointer) {
		errorf(
			k.c, expr_span(e), "L0639",
			"`%s` needs a mutable allocation pointer, found `%s`", form, type_name(k.c, pointer),
		)
		return false
	}
	return true
}

// An `assert`/`panic` message is a compile-time string.
@(private = "file")
check_message_arg :: proc(k: ^Checker, e: Expr) {
	if check_single_expr(k, e) == INVALID_TYPE {
		return
	}
	base := expr_base(e)
	if !base.is_const || base.const_value.kind != .String {
		errorf(k.c, expr_span(e), "L0345", "this message must be a compile-time string")
	}
}

// ------------------------------------------------------- source locations --

// design.md "`source_location() or source_location(<entity>)`" and
// "`caller_location()`": a constant `runtime.Source_Code_Location` for the call,
// or for a named entity's declaration. A `caller_location()` default is folded
// again at every call that omits it, by `substitute_caller_location`.
check_location :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.value_category = .Value
	type, resolved := runtime_type_named(k, "Source_Code_Location")
	if !resolved {
		errorf(
			k.c, v.span, "L0573",
			"`%s` produces a `runtime.Source_Code_Location`, and this program's `base:runtime` declares none",
			ident.name,
		)
		v.type = INVALID_TYPE
		return
	}
	span := v.span
	switch {
	case len(v.args) == 0:
	case kind == .Caller_Location:
		errorf(k.c, v.span, "L0573", "`caller_location` takes no arguments, found %d", len(v.args))
		v.type = INVALID_TYPE
		return
	case len(v.args) > 1:
		errorf(k.c, v.span, "L0573", "`source_location` takes at most one name, found %d", len(v.args))
		v.type = INVALID_TYPE
		return
	case:
		declared, found := entity_declaration_span(k, v.args[0].value)
		if !found {
			errorf(k.c, expr_span(v.args[0].value), "L0573", "`source_location` takes a declared name")
			v.type = INVALID_TYPE
			return
		}
		span = declared
	}
	if type == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	v.type = type
	v.is_const = true
	v.const_value = source_location_const(k, type, span)
}

// `{file, procedure: string_view, line, column: int}`, over the type this
// package's `base:runtime` declares.
@(private = "file")
source_location_const :: proc(k: ^Checker, type: Type_Id, span: Span) -> Const_Value {
	file, line, column := "", 0, 0
	if span.file != NO_FILE && int(span.file) < len(k.c.sources) {
		source := &k.c.sources[span.file]
		file = source.path
		line, column = line_col(source, span.lo)
	}
	elements := make([]Const_Value, 4, k.c.semantic_allocator)
	elements[0] = Const_Value{kind = .String, text = file}
	elements[1] = Const_Value{kind = .String, text = enclosing_procedure_name(k)}
	elements[2] = int_const(k.c, i64(line))
	elements[3] = int_const(k.c, i64(column))
	aggregate := new(Const_Aggregate, k.c.semantic_allocator)
	aggregate.type = type
	aggregate.elements = elements
	return Const_Value{kind = .Aggregate, aggregate = aggregate}
}

@(private = "file")
enclosing_procedure_name :: proc(k: ^Checker) -> string {
	if k.proc_literal != nil && k.proc_literal.symbol != INVALID_SYMBOL {
		if sym := symbol_of(k.c, k.proc_literal.symbol); sym != nil {
			return identifier_text(k.c, sym.name)
		}
	}
	return ""
}

@(private = "file")
entity_declaration_span :: proc(k: ^Checker, e: Expr) -> (Span, bool) {
	ident, is_ident := e.(^Expr_Ident)
	if !is_ident {
		return no_span(), false
	}
	sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
	if sym == nil {
		return no_span(), false
	}
	return sym.span, true
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
	substituted.const_value = source_location_const(k, call.type, at)
	return substituted
}

// ------------------------------------------------------ runtime metadata --

// design.md "`type` and `typeid`": `type_info_of(id)` maps a runtime `typeid` to
// a read-only `^runtime.Type_Info` from a shared static table, nil for any id
// without an entry, since a `typeid` can be forged.
check_type_info_of :: proc(k: ^Checker, v: ^Expr_Call) {
	v.value_category = .Value
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0322", "`type_info_of` takes 1 argument, found %d", len(v.args))
		v.type = INVALID_TYPE
		return
	}
	record, resolved := runtime_type_named(k, "Type_Info")
	// The table's member record is resolved with it, not on first use.
	members, members_resolved := runtime_type_named(k, "Member_Info")
	if resolved && members_resolved && (record == INVALID_TYPE || members == INVALID_TYPE) {
		v.type = INVALID_TYPE
		return
	}
	if !resolved || !members_resolved {
		errorf(
			k.c, v.span, "L0575",
			"`type_info_of` produces a `^runtime.Type_Info`, and this program's `base:runtime` declares none",
		)
		v.type = INVALID_TYPE
		return
	}
	operand := check_single_expr(k, v.args[0].value, TYPE_TYPEID)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if type_underlying(k.c, operand) != TYPE_TYPEID {
		errorf(
			k.c, expr_span(v.args[0].value), "L0575",
			"`type_info_of` takes a `typeid`, found `%s`", type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return
	}
	if k.c.speculation_depth == 0 {
		k.c.type_info_requested = true
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
	v.type = pointer_to(k.c, record, false)
}

// A type declared by `base:runtime`, recorded for the emitter's metadata tables.
// The runtime is loaded for every program, so a builtin producing one of its
// types needs no import, as `Option` and `Result` need none (design.md). The compiler writes these records field by field
// and their enums as numbers, so the declaration is checked against that once:
// a mismatch is reported and gives INVALID_TYPE, still `resolved`.
@(private = "file")
runtime_type_named :: proc(k: ^Checker, name: string) -> (Type_Id, bool) {
	for index in 1 ..< len(k.c.packages) {
		target := &k.c.packages[index]
		if target.key != STD_RUNTIME || target.scope == nil {
			continue
		}
		symbol_id := target.scope.names[intern_identifier(k.c, name)] or_else INVALID_SYMBOL
		// Checked before any package importing it only if something imports it.
		if found := symbol_of(k.c, symbol_id); found != nil && found.kind == .Type {
			resolve_symbol_signature_in_place(k, symbol_id)
		}
		symbol := symbol_of(k.c, symbol_id)
		if symbol == nil || symbol.kind != .Type || symbol.type == INVALID_TYPE {
			continue
		}
		if recorded, checked := k.c.runtime_types[name]; checked {
			return recorded, true
		}
		type := symbol.type
		if !runtime_layout_matches(k, symbol_id, name) {
			errorf(
				k.c, symbol.span, "L0704",
				"`runtime.%s` does not have the layout the compiler writes: the same fields, in the same order, with the same types, and enum members in design.md's order",
				name,
			)
			// A speculative check's diagnostic is rolled back, so only a real one
			// may settle the answer.
			if k.c.speculation_depth > 0 {
				return INVALID_TYPE, true
			}
			type = INVALID_TYPE
		}
		k.c.runtime_types[name] = type
		return type, true
	}
	return INVALID_TYPE, false
}

// The public `Type_Kind` and `Member_Kind`, in the order `base:runtime`
// declares them. The emitter writes their values as these indices.
Runtime_Type_Kind :: enum {
	Invalid, Void, Bool, Signed_Int, Unsigned_Int, Float, Rune,
	Raw_Pointer, Pointer, C_Pointer, Array, Slice, Dynamic_Array, Map,
	Struct, Enum, Union, Proc, String, String_View, CString_View,
	Typeid, Any_View, Dyn, Distinct, Simd, Allocator, Allocator_Error,
}

Runtime_Member_Kind :: enum { Field, Enum_Value, Union_Variant, Parameter, Result }

@(private = "file")
Runtime_Field :: struct {
	name, type: string,
}

@(private = "file")
SOURCE_CODE_LOCATION_LAYOUT := [?]Runtime_Field {
	{"file", "string_view"}, {"procedure", "string_view"}, {"line", "int"}, {"column", "int"},
}

@(private = "file")
TYPE_INFO_LAYOUT := [?]Runtime_Field {
	{"id", "typeid"}, {"kind", "Type_Kind"}, {"name", "string_view"}, {"size", "int"},
	{"align", "int"}, {"bits", "int"}, {"signed", "bool"}, {"element", "typeid"},
	{"key", "typeid"}, {"count", "int"}, {"members", "[]Member_Info"},
}

@(private = "file")
MEMBER_INFO_LAYOUT := [?]Runtime_Field {
	{"kind", "Member_Kind"}, {"name", "string_view"}, {"type", "typeid"},
	{"offset", "int"}, {"value_low", "u64"}, {"value_high", "u64"},
}

@(private = "file")
runtime_layout_matches :: proc(k: ^Checker, symbol_id: Symbol_Id, name: string) -> bool {
	c := k.c
	// The fields and enum members are read here, possibly before anything else
	// asked for them.
	resolve_symbol_signature_in_place(k, symbol_id)
	type := symbol_of(c, symbol_id).type
	layout: []Runtime_Field
	switch name {
	case "Source_Code_Location": layout = SOURCE_CODE_LOCATION_LAYOUT[:]
	case "Type_Info":            layout = TYPE_INFO_LAYOUT[:]
	case "Member_Info":          layout = MEMBER_INFO_LAYOUT[:]
	}
	info := type_of(c, type)
	if info == nil || info.kind != .Struct || len(info.fields) != len(layout) {
		return false
	}
	for field, index in info.fields {
		sym := symbol_of(c, field)
		if identifier_text(c, sym.name) != layout[index].name || type_name(c, sym.type) != layout[index].type {
			return false
		}
		if kind := type_of(c, sym.type); kind != nil && kind.kind == .Enum {
			resolve_symbol_signature_in_place(k, kind.symbol)
		}
		switch layout[index].type {
		case "Type_Kind":
			if !runtime_enum_matches(c, sym.type, Runtime_Type_Kind) {
				return false
			}
		case "Member_Kind":
			if !runtime_enum_matches(c, sym.type, Runtime_Member_Kind) {
				return false
			}
		}
	}
	return true
}
