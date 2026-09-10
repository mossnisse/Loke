// Built-in call checking.
//
// Every predeclared and `core:`-contributed built-in whose rules are the
// compiler's own: `assert`/`panic`, `static_assert`, the build-configuration
// and layout queries, allocation, `make`, `unsafe.transmute`, and the standard
// aliases. Split from `check_expr.odin` for the same reason `simd.odin`,
// `atomics.odin`, `format.odin`, and `reflect.odin` are separate — a built-in
// family owns its own argument rules, and ordinary expression checking should
// not have to be read past them.
//
// Everything here still resolves through the ordinary checker: a built-in call
// is an `Expr_Call` whose callee names a `.Builtin` symbol, and the result is
// recorded on the same annotations any other call writes.
package lokec

check_builtin_call :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, symbol_id: Symbol_Id, expected: Type_Id) {
	sym := symbol_of(k.c, symbol_id)
	ident.symbol = symbol_id
	ident.resolution = Resolution{kind = .Value, symbol = symbol_id}
	ident.type = sym.proc_type
	v.resolution = Resolution{kind = .Call, symbol = symbol_id, chosen_overload = symbol_id}

	// Exhaustive on purpose: a built-in with no arm here would fall through to
	// the ordinary parameter path and be called as if it were declared there.
	switch sym.builtin {
	case .Assert, .Panic:
		check_assert_or_panic(k, v, ident, sym.builtin)
		return
	case .Static_Assert:
		check_static_assert(k, v)
		return
	case .Build_Config:
		check_config(k, v)
		return
	case .Source_Location:
		check_location(k, v, ident)
		return
	case .Caller_Location:
		check_caller_location(k, v, ident)
		return
	case .Size_Of, .Align_Of, .Offset_Of:
		check_layout_builtin(k, v, ident, sym.builtin, expected)
		return
	case .Is_Copyable:
		check_is_copyable_builtin(k, v, ident)
		return
	case .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of:
		check_reflection_builtin(k, v, ident, sym.builtin)
		return
	case .Make:
		check_make_builtin(k, v, ident)
		return
	case .Simd_Cast, .Simd_Select, .Simd_Reduce:
		check_simd_builtin(k, v, ident, sym.builtin)
		return
	case .New, .New_Clone, .Free, .Unsafe_Free, .Free_All:
		check_allocation_builtin(k, v, ident, sym.builtin)
		return
	case .Drop:
		check_drop_builtin(k, v, ident)
		return
	case .Exchange:
		check_exchange_builtin(k, v, ident)
		return
	case .Unsafe_Raw_Data, .Unsafe_String_View, .Unsafe_C_String_View:
		check_unsafe_builtin(k, v, ident, sym.builtin)
		return
	case .Unsafe_Forget:
		check_forget_builtin(k, v, ident)
		return
	case .Unsafe_Transmute:
		check_transmute_builtin(k, v, ident)
		return
	case .Type_Info_Of:
		check_type_info_of(k, v)
		return
	case .Strings_Allocate:
		check_strings_allocate(k, v, ident)
		return
	case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
	     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
		check_atomic_builtin(k, v, ident, sym.builtin)
		return
	case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes, .Fmt_Format_Any:
		check_fmt_builtin(k, v, ident, sym.builtin)
		return
	case .Default_Allocator:
		if len(v.args) != 0 {
			errorf(k.c, v.span, "L0490", "`default_allocator` takes no arguments")
			v.type = INVALID_TYPE
			return
		}
		v.bound = nil
		v.type = TYPE_ALLOCATOR
		return
	case .None:
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
		return
	}

	if len(v.args) != len(sym.params) {
		errorf(
			k.c,
			v.span,
			"L0322",
			"`%s` takes %d argument%s, found %d",
			ident.name,
			len(sym.params),
			len(sym.params) == 1 ? "" : "s",
			len(v.args),
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, len(sym.params), k.c.semantic_allocator)
	for arg, index in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			reject_builtin_argument_shape(k, arg)
			continue
		}
		bound[index] = arg.value
		check_value_expr(k, arg.value, sym.params[index], "pass")
	}
	v.bound = bound
	v.type = sym.type
}

// A built-in takes positional value arguments and nothing else: it has no
// declaration to name a parameter, and no `inout`/`move`/spread position to
// fill. Both are permanent properties rather than an unimplemented milestone
//.
reject_builtin_argument_shape :: proc(k: ^Checker, arg: Argument) {
	if arg.name.text != "" {
		errorf(k.c, arg.span, "L0371", "a built-in takes positional arguments only")
		return
	}
	errorf(k.c, arg.span, "L0370", "a built-in takes value arguments only")
}

// `assert(condition[, message])` and `panic([message])`. Both produce no value
// and both are legal in either phase, so neither is folded here: the evaluator
// diagnoses the compile-time occurrence and the backend lowers the runtime one
// to the trap seam.
@(private = "file")
check_assert_or_panic :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.type = TYPE_VOID
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
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, len(v.args), k.c.semantic_allocator)
	for arg, index in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			reject_builtin_argument_shape(k, arg)
			continue
		}
		bound[index] = arg.value
		if kind == .Assert && index == 0 {
			check_condition(k, arg.value)
			continue
		}
		check_message_arg(k, arg.value)
	}
	v.bound = bound
}

// `static_assert(condition[, message])`. It requires its condition at compile
// time whatever phase surrounds it, so it answers here and leaves nothing for
// the backend.
@(private = "file")
check_static_assert :: proc(k: ^Checker, v: ^Expr_Call) {
	v.type = TYPE_VOID
	v.value_category = .Value
	if len(v.args) < 1 || len(v.args) > 2 {
		errorf(k.c, v.span, "L0387", "`static_assert` takes a condition and an optional message")
		v.type = INVALID_TYPE
		return
	}
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
		// design.md: a positively required interface application must name the
		// requirement that failed, never a bare "static assertion failed". A
		// negated or otherwise combined condition is not a bare application, so
		// the adapter declines it and the assertion reports itself.
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

// `build_config(NAME, default)`: the name is a token, not a lexical value, and
// the default fixes both the result's type and what an override may say.
@(private = "file")
check_config :: proc(k: ^Checker, v: ^Expr_Call) {
	v.value_category = .Value
	if len(v.args) != 2 {
		errorf(k.c, v.span, "L0388", "`build_config` takes a name and a default value")
		v.type = INVALID_TYPE
		return
	}
	name, is_ident := v.args[0].value.(^Expr_Ident)
	if !is_ident {
		errorf(k.c, expr_span(v.args[0].value), "L0388", "`build_config` needs a name")
		v.type = INVALID_TYPE
		return
	}
	if check_single_expr(k, v.args[1].value) == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	fallback, evaluated := require_const(k, v.args[1].value, "a `build_config` default", "L0388")
	if !evaluated {
		v.type = INVALID_TYPE
		return
	}
	#partial switch fallback.kind {
	case .Boolean, .Integer, .String:
	case:
		errorf(k.c, expr_span(v.args[1].value), "L0388", "a `build_config` default must be a boolean, an integer, or a string")
		v.type = INVALID_TYPE
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
			"`-define:%s=` gives %s, but this `build_config` defaults to %s",
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

// `size_of`, `align_of`, `offset_of`, and `len`. Every one of these inspects
// static type or declaration information, so nothing here is evaluated: the
// operand is resolved and type-checked, never read, and never required to be
// live.
@(private = "file")
check_layout_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind, expected: Type_Id) {
	v.type = TYPE_INT
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
		v.type = INVALID_TYPE
		return
	}
	for arg in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			reject_builtin_argument_shape(k, arg)
			v.type = INVALID_TYPE
			return
		}
	}
	// The call is folded, so nothing here reaches the backend; binding the
	// operand would only invite it to be emitted.
	v.bound = nil

	operand := layout_operand_type(k, v.args[0].value, kind)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if !gate_type(k, operand, expr_span(v.args[0].value)) {
		v.type = INVALID_TYPE
		return
	}

	result := u64(0)
	switch kind {
	case .Size_Of:
		result = type_size(k.c, operand)
	case .Align_Of:
		result = type_align(k.c, operand)
	case .Offset_Of:
		// The second operand is a member name, not a lexical value expression:
		// resolving it as one would find an unrelated variable of the same name.
		name, is_ident := v.args[1].value.(^Expr_Ident)
		if !is_ident {
			errorf(k.c, expr_span(v.args[1].value), "L0386", "`offset_of` needs a field name")
			v.type = INVALID_TYPE
			return
		}
		field := struct_field(k.c, operand, intern_identifier(k.c, name.name))
		if field == INVALID_SYMBOL {
			errorf(k.c, name.span, "L0363", "`%s` has no field `%s`", type_name(k.c, operand), name.name)
			v.type = INVALID_TYPE
			return
		}
		if !require_visible_field(k, name.span, operand, field, "L0472", "measured with `offset_of`") {
			v.type = INVALID_TYPE
			return
		}
		symbol := symbol_of(k.c, field)
		name.symbol = field
		name.resolution = Resolution{kind = .Field, symbol = field}
		result = type_field_offset(k.c, operand, int(symbol.index))
	case .Static_Assert, .Build_Config, .Source_Location, .Caller_Location,
	     .New, .New_Clone, .Free, .Unsafe_Free, .Free_All, .Make, .Default_Allocator, .Drop, .Exchange,
	     .Simd_Cast, .Simd_Select, .Simd_Reduce,
	     .Unsafe_Raw_Data, .Unsafe_String_View, .Unsafe_C_String_View, .Unsafe_Forget,
	     .Unsafe_Transmute, .Type_Info_Of,
	     .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes, .Fmt_Format_Any,
	     .Strings_Allocate, .None, .Assert, .Panic, .Is_Copyable,
	     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of,
	     .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
	     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
		return
	}
	v.is_const = true
	v.const_value = int_const(k.c, i64(result))
}

// design.md "Built-in procedures": `is_copyable(T)` folds to `false` exactly
// when `T` is move-only, structurally included -- the same question the
// move-only diagnostics ask, so a `where` bound and the error it avoids cannot
// disagree. Its operand is inspected, not evaluated, like the layout queries.
@(private = "file")
check_is_copyable_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.type = TYPE_BOOL
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0322", "`%s` takes 1 argument, found %d", ident.name, len(v.args))
		v.type = INVALID_TYPE
		return
	}
	if v.args[0].name.text != "" || v.args[0].mode != .Value {
		reject_builtin_argument_shape(k, v.args[0])
		v.type = INVALID_TYPE
		return
	}
	operand := layout_operand_type(k, v.args[0].value, .Is_Copyable)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if !gate_type(k, operand, expr_span(v.args[0].value)) {
		v.type = INVALID_TYPE
		return
	}
	v.is_const = true
	v.const_value = bool_const(!type_clone_disabled(k.c, operand))
}

// The type a layout operand denotes: a written type, or the type of an
// expression that is checked exactly once and never evaluated. `len` keeps an
// untyped string as itself, because the length is in the value.
@(private = "file")
layout_operand_type :: proc(k: ^Checker, e: Expr, kind: Builtin_Kind) -> Type_Id {
	if e == nil {
		return INVALID_TYPE
	}
	// Types and expressions share one node domain, so which reading applies is not
	// a question the syntax answers: the type reading is tried first and the value
	// reading is the fallback. `resolve_type_syntax` stays silent for a node that
	// simply is not type syntax, so a complaint means it *was* type syntax and was
	// broken -- and reading the same node again as a value would find the same
	// thing and say it twice. `size_of([BAD]i32)` reported the unknown length
	// once per reading, because the array case checks the length expression.
	before := k.c.error_count
	if denoted := resolve_type_syntax(k, e); denoted != INVALID_TYPE {
		return denoted
	}
	if k.c.error_count != before {
		return INVALID_TYPE
	}
	if check_single_expr(k, e) == INVALID_TYPE {
		return INVALID_TYPE
	}
	base := expr_base(e)
	if base.value_category == .Type {
		return base.denoted_type
	}
	return base.type
}

// design.md "Allocators" and "Allocation failure". `new` and `new_clone` are
// explicitly fallible and always return their error rather than invoking a
// failure policy; `free` returns no status.
//
//   new(T)             -> (^T, Allocator_Error)
//   new(T, allocator)  -> (^T, Allocator_Error)
//   new_clone(value)   -> (^T, Allocator_Error)
//   free(pointer)
//   free(pointer, allocator)
//   free_all(allocator)
//
// An omitted allocator argument is the default provider: the same symbol
// `mem.default_allocator()` names.
@(private = "file")
check_allocation_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	arity_low, arity_high := 1, 2
	if kind == .Free_All {
		arity_high = 1
	}
	if len(v.args) < arity_low || len(v.args) > arity_high {
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
	for arg in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			reject_builtin_argument_shape(k, arg)
			v.type = INVALID_TYPE
			return
		}
	}

	bound := make([dynamic]Expr, 0, 2, k.c.semantic_allocator)
	switch kind {
	case .New:
		// The operand is a type, inspected rather than evaluated, exactly as the
		// layout built-ins treat theirs.
		element := layout_operand_type(k, v.args[0].value, kind)
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
		v.alloc_type = element
		// A fresh allocation is the caller's to write and to free, so `new` and
		// `new_clone` hand back `^mut T`.
		set_allocation_results(k, v, pointer_to(k.c, element, true))

	case .New_Clone:
		value := check_single_expr(k, v.args[0].value)
		if value == INVALID_TYPE || !gate_type(k, value, expr_span(v.args[0].value)) {
			v.type = INVALID_TYPE
			return
		}
		// An untyped constant operand has no representation to allocate for, so it
		// takes its default type first. Without this the allocation is sized from
		// the untyped type and comes out zero.
		if type_is_untyped(k.c, value) {
			value = default_type(k.c, value)
			if value == INVALID_TYPE || !materialize(k, v.args[0].value, value) {
				v.type = INVALID_TYPE
				return
			}
		}
		append(&bound, v.args[0].value)
		v.alloc_type = value
		// `new_clone` creates a new allocation root containing a clone of the
		// value (design.md), so the operand's own copy hook has to exist by
		// emission.
		contribute_lifecycle_members(k, value)
		// The result shape is settled before the copyability complaint, so a
		// `p, err := new_clone(x)` destructuring still knows its arity and the
		// failure is reported once.
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
		if pointer == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		if !check_free_operand(k, v.args[0].value, pointer, kind == .Unsafe_Free ? "unsafe.free" : "free") {
			v.type = INVALID_TYPE
			return
		}
		append(&bound, v.args[0].value)
		v.type = TYPE_VOID

	case .Free_All:
		allocator := check_single_expr(k, v.args[0].value, TYPE_ALLOCATOR)
		if allocator == INVALID_TYPE || type_underlying(k.c, allocator) != TYPE_ALLOCATOR {
			errorf(k.c, expr_span(v.args[0].value), "L0490", "`free_all` names the allocator being reset, found `%s`", type_name(k.c, allocator))
			v.type = INVALID_TYPE
			return
		}
		// The compiler rejects `free_all`, or any call with the same
		// allocator-reset effect, while a live owning value or
		// borrow still refers to storage from that allocator (design.md). That is
		// region provenance, in `src/borrow.odin`; what is left here is the shape.
		append(&bound, v.args[0].value)
		v.bound = bound[:]
		v.type = TYPE_VOID
		return

	case .Simd_Cast, .Simd_Select, .Simd_Reduce,
	     .None, .Assert, .Panic, .Size_Of, .Align_Of, .Offset_Of, .Is_Copyable, .Make,
	     .Static_Assert, .Build_Config, .Source_Location, .Caller_Location,
	     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of, .Default_Allocator, .Drop,
	     .Exchange, .Unsafe_Raw_Data, .Unsafe_String_View, .Unsafe_C_String_View, .Unsafe_Forget,
	     .Unsafe_Transmute, .Type_Info_Of,
	     .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes, .Fmt_Format_Any,
	     .Strings_Allocate,
	     .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
	     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
		return
	}

	// The allocator argument, written or supplied. Keeping it bound means the
	// backend never has to re-derive which provider a call selected.
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

// design.md "Dynamic arrays" and "Maps": `make` creates a container bound to the
// selected allocator.
//
//   make([dynamic]T, len: int = 0, cap: int = len, allocator = default)
//       -> ([dynamic]T, Allocator_Error)
//   make(map[K]V, reservation: int = 0, allocator = default)
//       -> (map[K]V, Allocator_Error)
//
// The result is bound to its allocator even when empty, so `make` is also how
// a program chooses a provider for a container it then fills. The counts are
// ordinary runtime `int` expressions; `len > cap` and a negative count are
// program faults, not allocation failures, checked where the allocation is made.
//
// The trailing allocator is recognised by its type rather than by position:
// `Allocator` is a distinct nominal type, so no count can be mistaken for one
// and `make([dynamic]int, arena.allocator())` needs no written parameter name.
@(private = "file")
check_make_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
	if len(v.args) == 0 {
		errorf(k.c, v.span, "L0579", "`make` names the container type to create")
		v.type = INVALID_TYPE
		return
	}
	for arg in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			reject_builtin_argument_shape(k, arg)
			v.type = INVALID_TYPE
			return
		}
	}
	container := layout_operand_type(k, v.args[0].value, .Make)
	if container == INVALID_TYPE || !gate_type(k, container, expr_span(v.args[0].value)) {
		v.type = INVALID_TYPE
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
		v.type = INVALID_TYPE
		return
	}
	// A container of a move-only element has no clone, but it can still be
	// created: what `make` produces is empty or zero-filled, never a copy.
	contribute_lifecycle_members(k, container)

	is_map := type_is_map(k.c, container)
	max_counts := is_map ? 1 : 2
	counts := make([dynamic]Expr, 0, 2, k.c.semantic_allocator)
	allocator: Expr
	for index in 1 ..< len(v.args) {
		argument := v.args[index].value
		if check_single_expr(k, argument, allocator_hint(k, index, len(v.args))) == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		if type_underlying(k.c, expr_base(argument).type) == TYPE_ALLOCATOR {
			if index != len(v.args) - 1 {
				errorf(k.c, expr_span(argument), "L0579", "the allocator is `make`'s last argument")
				v.type = INVALID_TYPE
				return
			}
			allocator = argument
			continue
		}
		if len(counts) == max_counts {
			shape := is_map ? "a map, an optional reservation, and an optional allocator" :
				"a dynamic array type, an optional length and capacity, and an optional allocator"
			errorf(k.c, expr_span(argument), "L0579", "`make` takes %s", shape)
			v.type = INVALID_TYPE
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
			v.type = INVALID_TYPE
			return
		}
		append(&counts, argument)
	}

	// Bound in a fixed shape the backend never has to re-derive: the counts in
	// written order, then the allocator, which is nil when it was omitted.
	bound := make([]Expr, max_counts + 1, k.c.semantic_allocator)
	for count, index in counts {
		bound[index] = count
	}
	bound[max_counts] = allocator
	v.bound = bound
	v.alloc_type = container
	// design.md "Zero values": a written *length* fills that many slots with the
	// element's zero. A capacity or a map reservation is raw storage and fills
	// nothing, and neither does a length written as the constant `0` — which is
	// how `make(T, 0, capacity)` reserves storage for a no-zero element.
	if !is_map && len(counts) > 0 && !is_constant_zero(k, counts[0]) {
		if !require_type_has_zero(
			k, container_element(k.c, container), expr_span(counts[0]), "a `make` length",
		) {
			v.type = INVALID_TYPE
			return
		}
	}

	v.type = result_type(k, container, TYPE_ALLOCATOR_ERROR)
}

// design.md "`unsafe.transmute`": `unsafe.transmute(T, value)` reads the
// storage of `value` as a `T`. It is a `core:unsafe` built-in rather than a
// predeclared one because reinterpreting bits is not a universally valid
// conversion — only the equal size and the trivial lifecycle are checked, and
// what the resulting representation *means* is the caller's obligation.
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
	for arg in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			reject_builtin_argument_shape(k, arg)
			return
		}
	}
	// The destination is a written type, never an expression whose type is taken:
	// `unsafe.transmute(x, y)` naming a variable is a mistake worth reporting as
	// one, not a silent `type_of(x)`.
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
	if source == INVALID_TYPE {
		return
	}
	if !materialize(k, v.args[1].value, default_type(k.c, source)) {
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
			"`unsafe.transmute` needs equal sizes: `%s` is %d byte%s and `%s` is %d",
			type_name(k.c, source), type_size(k.c, source), type_size(k.c, source) == 1 ? "" : "s",
			type_name(k.c, target), type_size(k.c, target),
		)
		return
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[1].value
	v.bound = bound
	v.type = target
	fold_transmute(k, v, source, target)
}

// Both sides of a bit cast. A managed value would let the cast duplicate an
// owning representation or manufacture one whose cleanup invariant was never
// established; a borrow carrier — `^T`, a slice, a view, a `dyn` — would hand
// back a reference the borrow analysis never saw loaned. `rawptr` and `[^]T`
// carry neither, which is why they are the pointer shapes a bit cast may name;
// dereferencing the result is valid only when the bits already describe
// suitably aligned, live storage.
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

// A scalar bit cast of a constant answers at compile time, which is what lets
// `core:math` build an infinity or a NaN — neither of which has a literal
// spelling — as a constant rather than a runtime call. An aggregate or a wider
// value is left to the backend.
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
		return // a pointer or an aggregate: still a valid cast, just not a constant
	case .Invalid:
		// A `bool` outside {0, 1}, or an enum with no member for the pattern: the
		// value would be invalid the moment anything read it, and unlike a runtime
		// result there is nothing left to be the caller's obligation.
		errorf(
			k.c, v.span, "L0688",
			"this bit pattern is not a valid `%s`", type_name(k.c, target),
		)
		v.type = INVALID_TYPE
		return
	case .Folded:
		v.is_const = true
		v.const_value = folded
		v.bound = nil
	}
}

// Whether a pattern became a constant of the destination type, could not be one
// at all, or simply has no constant spelling there.
Const_Pattern :: enum {
	Folded,
	Invalid,
	Unfoldable,
}

// A scalar constant's storage bits, and whether it has any: an aggregate, a
// string, or a `nil` does not answer here.
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

// The inverse: the constant a pattern denotes in `type`, or `false` when the
// pattern is not a value of that type at all.
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
		return integer_const(c, bi_wrap(c, bi_from_u64(c, raw), int(info.bits), info.signed)), .Folded
	case .Rune:
		wrapped := bi_wrap(c, bi_from_u64(c, raw), 32, true)
		// design.md: a `rune` is a scalar Unicode value, so the surrogate range and
		// anything above U+10FFFF are not runes however the bits were produced.
		if point, fits := bi_to_i64(c, wrapped); !fits || point < 0 || point > 0x10ffff ||
		   (point >= 0xd800 && point <= 0xdfff) {
			return {}, .Invalid
		}
		return rune_const(c, wrapped), .Folded
	case .Enum:
		wrapped := bi_wrap(c, bi_from_u64(c, raw), int(info.bits), info.signed)
		candidate := integer_const(c, wrapped)
		if enum_member_by_value(c, type, candidate) == INVALID_SYMBOL {
			return {}, .Invalid
		}
		return candidate, .Folded
	}
	// A pointer, an aggregate, or anything else with no constant spelling: the
	// cast is still valid, it simply does not fold.
	return {}, .Unfoldable
}

// Whether an expression is the folded constant `0`. A length the compiler can
// see is zero initialises nothing, whatever the element type is.
@(private = "file")
is_constant_zero :: proc(k: ^Checker, e: Expr) -> bool {
	base := expr_base(e)
	if base == nil || !base.is_const || base.const_value.kind != .Integer {
		return false
	}
	return bi_is_zero(base.const_value.integer)
}

// An argument that could be the trailing allocator is checked with `Allocator`
// as its context, so `mem.default_allocator()` resolves the same way it does in
// any other allocator position. Everything before it wants `int`.
@(private = "file")
allocator_hint :: proc(k: ^Checker, index: int, count: int) -> Type_Id {
	return index == count - 1 ? INVALID_TYPE : TYPE_INT
}

@(private = "file")
set_allocation_results :: proc(k: ^Checker, v: ^Expr_Call, pointer: Type_Id) {
	v.type = result_type(k, pointer, TYPE_ALLOCATOR_ERROR)
	v.value_category = .Value
}

// `free` ends the allocation root designated by a checked base pointer from
// `new` or `new_clone` (design.md). The syntax check is only that the operand
// is a checked pointer; whether its value really is that allocation base, and
// whether it has already been released, is root provenance (`src/borrow.odin`).
//
// `unsafe.free` shares the shape and reports under its own name, because it is
// the one a `rawptr` reaches first (design.md "The `unsafe` package"). The
// release is sized, so the pointee type is cast back on before the call rather
// than checked away here.
@(private = "file")
check_free_operand :: proc(k: ^Checker, e: Expr, pointer: Type_Id, form: string) -> bool {
	if underlying_kind(k.c, pointer) != .Pointer {
		errorf(k.c, expr_span(e), "L0493", "`%s` takes an allocation pointer, found `%s`", form, type_name(k.c, pointer))
		return false
	}
	// Releasing storage is the strongest write there is, so it needs the write
	// capability. A `^T` weakened from an allocation still reads the allocation;
	// it does not get to end it.
	if !pointer_is_mutable(k.c, pointer) {
		errorf(
			k.c, expr_span(e), "L0639",
			"`%s` needs a mutable allocation pointer, found `%s`", form, type_name(k.c, pointer),
		)
		return false
	}
	return true
}

// design.md: an `assert`/`panic` message is a compile-time string in M3; M6
// turns it into a runtime panic message.
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
