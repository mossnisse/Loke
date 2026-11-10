// Type syntax: resolving a written type, the finite-size check every declared
// type passes, and the diagnostics for a type that does not resolve.
// Declarations and signatures are in `check.odin`.
package lokec

import "core:strings"

// ------------------------------------------------------- finite size --

check_declaration_size :: proc(k: ^Checker, d: ^Decl) {
	if len(d.symbols) != 1 || d.symbols[0] == INVALID_SYMBOL {
		return
	}
	symbol := symbol_of(k.c, d.symbols[0])
	if symbol == nil {
		return
	}
	// An anonymous type past the maximum has no span of its own, so each is
	// measured here where its declaration can say where it is.
	if symbol.kind == .Proc && !symbol.generic {
		if info := type_of(k.c, symbol.proc_type); info != nil {
			for parameter in info.parameters {
				type_size(k.c, parameter, symbol.span)
			}
			type_size(k.c, info.result, symbol.span)
		}
	}
	if symbol.kind != .Type {
		return
	}
	path := make([dynamic]Type_Id, 0, 8, context.temp_allocator)
	if check_finite_size(k, symbol.type, d.span, &path) {
		info := type_of(k.c, symbol.type)
		for field in info.fields {
			if sym := symbol_of(k.c, field); sym != nil && info.kind == .Struct {
				type_size(k.c, sym.type, sym.span)
			}
		}
	}
	check_union_zero_payload(k, symbol.type, d.attributes)
}

// Walks value edges only, since a pointer breaks a containment cycle.
check_finite_size :: proc(k: ^Checker, type: Type_Id, span: Span, path: ^[dynamic]Type_Id) -> bool {
	info := type_of(k.c, type)
	if info == nil {
		return true
	}
	switch info.size_state {
	case .Finite:
		return true
	case .Cyclic:
		return false
	case .Checking:
		errorf(
			k.c, span, "L0364", "`%s` contains itself by value: %s",
			type_name(k.c, type), size_cycle_path(k, path[:], type),
		)
		info.size_state = .Cyclic
		return false
	case .Unchecked:
	}

	#partial switch info.kind {
	case .Struct, .Array, .Distinct, .Union:
	case:
		info.size_state = .Finite
		return true
	}
	// A generic instance whose fields are still resolving is walked again once
	// they have; an answer through it now would be cached from a partial record.
	if record_resolving(k.c, info) {
		k.size_incomplete = true
		return true
	}
	outer_incomplete := k.size_incomplete
	k.size_incomplete = false

	info.size_state = .Checking
	append(path, type)
	defer pop(path)

	ok := true
	#partial switch info.kind {
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(k.c, field)
			if symbol == nil {
				continue
			}
			if !check_finite_size(k, symbol.type, span, path) {
				ok = false
			}
		}
	case .Array, .Distinct:
		if info.element != INVALID_TYPE {
			ok = check_finite_size(k, info.element, span, path)
		}
	case .Union:
		for variant in info.variants {
			if !check_finite_size(k, variant, span, path) {
				ok = false
			}
		}
	}
	// Reacquired: the walk may have grown the type store.
	info = type_of(k.c, type)
	switch {
	case !ok:
		info.size_state = .Cyclic
	case k.size_incomplete:
		info.size_state = .Unchecked
	case:
		info.size_state = .Finite
	}
	k.size_incomplete ||= outer_incomplete
	return ok
}

// A record whose fields are still being resolved: its declaration signature is
// on the stack.
record_resolving :: proc(c: ^Compiler, info: ^Type_Info) -> bool {
	if info.kind != .Struct && info.kind != .Union {
		return false
	}
	sym := symbol_of(c, info.symbol)
	return sym != nil && sym.decl != nil && sym.decl.sig_state == .Checking
}

@(private = "file")
size_cycle_path :: proc(k: ^Checker, path: []Type_Id, closing: Type_Id) -> string {
	names := make([dynamic]string, 0, len(path) + 1, context.temp_allocator)
	for type in path {
		append(&names, type_name(k.c, type))
	}
	append(&names, type_name(k.c, closing))
	return strings.join(names[:], " -> ", k.c.semantic_allocator)
}

concat :: proc(c: ^Compiler, parts: ..string) -> string {
	return strings.concatenate(parts, c.semantic_allocator)
}

// ---------------------------------------------------------- type syntax --

// Records what type syntax denotes.
@(private = "file")
denote :: proc(base: ^Expr_Base, type: Type_Id) -> Type_Id {
	base.denoted_type = type
	base.resolution.kind = .Type
	return type
}

// Resolves written type syntax, reporting what `resolve_type_syntax` left silent.
// No syntax is no type, and nothing to report.
resolve_type_reporting :: proc(k: ^Checker, syntax: Expr) -> Type_Id {
	if syntax == nil {
		return INVALID_TYPE
	}
	reported := k.c.error_count
	resolved := resolve_type_syntax(k, syntax)
	if resolved == INVALID_TYPE && k.c.error_count == reported {
		report_unresolved_type(k, syntax)
	}
	return resolved
}

resolve_type_syntax :: proc(k: ^Checker, syntax: Expr) -> Type_Id {
	#partial switch value in syntax {
	case ^Expr_Ident:
		symbol_id := lookup_symbol(k.scope, identifier_of(k.c, value))
		// A template names no type on its own.
		if symbol_is_generic(k, symbol_id) {
			return INVALID_TYPE
		}
		if symbol := symbol_of(k.c, symbol_id); symbol != nil && symbol.kind == .Type {
			resolve_symbol_signature_in_place(k, symbol_id)
			value.symbol = symbol_id
			return mark_denotes_type(&value.base, symbol_of(k.c, symbol_id).type, symbol_id)
		}
		// A type alias is a constant whose value is a type: `Alias :: u32`.
		if named := const_type_value(k, symbol_id); named != INVALID_TYPE {
			value.symbol = symbol_id
			return mark_denotes_type(&value.base, named, symbol_id)
		}

	case ^Expr_Selector:
		// `pkg.Point`.
		if ident, alias, is_alias := selector_package_alias(k, value); is_alias {
			check_package_selector(k, value, ident, alias, false)
			return value.value_category == .Type ? value.denoted_type : INVALID_TYPE
		}
		// An associated type, `Countdown.Iterator`.
		return resolve_associated_type(k, value)

	case ^Type_Pointer:
		if element := resolve_type_syntax(k, value.elem); element != INVALID_TYPE {
			return denote(&value.base, pointer_to(k.c, element, value.mutable))
		}

	case ^Type_C_Pointer:
		if element := resolve_type_syntax(k, value.elem); element != INVALID_TYPE {
			return denote(&value.base, c_pointer_to(k.c, element))
		}

	case ^Type_Slice:
		if element := resolve_type_syntax(k, value.elem); element != INVALID_TYPE {
			return denote(&value.base, slice_of(k.c, element, value.mutable))
		}

	case ^Type_Dynamic_Array:
		if element := resolve_type_syntax(k, value.elem); element != INVALID_TYPE {
			return denote(&value.base, dynamic_array_of(k.c, element))
		}

	case ^Type_Array:
		return resolve_array_type(k, value)

	case ^Type_Map:
		key := resolve_type_syntax(k, value.key)
		element := resolve_type_syntax(k, value.value)
		if key != INVALID_TYPE && element != INVALID_TYPE {
			return denote(&value.base, map_of(k.c, key, element))
		}

	case ^Type_Distinct:
		// A fresh identity; a named one got its shell in `prepare_package`.
		if value.denoted_type == INVALID_TYPE {
			element := resolve_distinct_element(k, value)
			value.denoted_type = new_type(k.c, Type_Info {
				kind = .Distinct,
				element = element,
				site = Type_Site{lookup_package(k), value.span, k.scope},
			})
		}
		return denote(&value.base, value.denoted_type)

	case ^Type_Record:
		if value.denoted_type == INVALID_TYPE {
			value.denoted_type = reject_in_place_record(k, value)
		}
		return denote(&value.base, value.denoted_type)

	case ^Type_Anon_Record:
		if value.denoted_type == INVALID_TYPE {
			value.denoted_type = resolve_anon_record(k, value)
		}
		return denote(&value.base, value.denoted_type)

	case ^Type_Anon_Union:
		if value.denoted_type == INVALID_TYPE {
			value.denoted_type = resolve_anon_union(k, value)
		}
		return denote(&value.base, value.denoted_type)

	case ^Type_Enum:
		if value.denoted_type == INVALID_TYPE {
			// design.md "Enumerations": every one has a name.
			errorf(
				k.c, value.span, "L0717",
				"an `enum` type is declared, `Name :: enum {{ ... }}`, not written in place",
			)
			value.denoted_type = new_type(k.c, Type_Info{kind = .Enum})
			resolve_enum_members(k, value.denoted_type, value)
		}
		return denote(&value.base, value.denoted_type)

	case ^Type_Proc:
		return resolve_proc_type(k, value)

	case ^Type_Dyn:
		// `dyn Interface(args...)`, without the subject parameter.
		if value.denoted_type != INVALID_TYPE {
			return value.denoted_type
		}
		return denote(&value.base, resolve_dyn_type(k, value))

	case ^Type_Type:
		return denote(&value.base, TYPE_TYPE)

	case ^Type_Poly:
		// Inside an instance, `$E` is bound in the instance scope.
		bound := lookup_symbol(k.scope, name_identifier(k.c, value.name))
		if sym := symbol_of(k.c, bound); sym != nil && sym.kind == .Type {
			return mark_denotes_type(&value.base, sym.type, bound)
		}

	case ^Expr_Call:
		return resolve_call_type(k, value)
	}
	return INVALID_TYPE
}

// `[N]T`. `[?]T` takes its length from the literal it types, which
// `check_composite` fills in; on its own it has none.
@(private = "file")
resolve_array_type :: proc(k: ^Checker, value: ^Type_Array) -> Type_Id {
	element := resolve_type_syntax(k, value.elem)
	if element == INVALID_TYPE || value.length == nil {
		return INVALID_TYPE
	}
	if value.denoted_type != INVALID_TYPE {
		return value.denoted_type
	}
	length, counted := constant_count(k, value.length, "an array length", "L0384")
	return counted ? denote(&value.base, array_of(k.c, element, length)) : INVALID_TYPE
}

// A written `[N]E` length or `Simd(T, N)` lane count: a constant, or `$N` bound
// inside an instance. An unbound `$N` reports nothing here; `report_unresolved_type`
// names it.
constant_count :: proc(k: ^Checker, written: Expr, what, code: string) -> (u64, bool) {
	if poly, is_poly := written.(^Type_Poly); is_poly {
		return poly_array_length(k, poly)
	}
	if check_single_expr(k, written, TYPE_INT) == INVALID_TYPE {
		return 0, false
	}
	folded, evaluated := require_const(k, written, what, code)
	if !evaluated {
		return 0, false
	}
	if folded.kind != .Integer {
		errorf(k.c, expr_span(written), code, "%s must be a constant integer", what)
		return 0, false
	}
	count, fits := bi_to_i64(k.c, folded.integer)
	if !fits || count < 0 {
		errorf(k.c, expr_span(written), code, "%s must be a non-negative constant", what)
		return 0, false
	}
	return u64(count), true
}

// design.md "Structs", "Unions": a declaration's value only. The type is still
// made, once, so its uses report nothing more.
@(private = "file")
reject_in_place_record :: proc(k: ^Checker, value: ^Type_Record) -> Type_Id {
	is_struct := value.kind == .Struct
	keyword := is_struct ? "struct" : "union"
	errorf(
		k.c, value.span, "L0717",
		"a `%s` type is declared, `Name :: %s {{ ... }}`, not written in place",
		keyword, keyword,
	)
	add_notef(
		k.c, value.span, "a %s written in place is an anonymous %s, `%s`",
		is_struct ? "record" : "union", is_struct ? "record" : "union",
		is_struct ? "(x: int, y: int)" : "(a: int | b: bool)",
	)
	validate_record_attributes(k, value)
	type := new_type(k.c, Type_Info{kind = is_struct ? Type_Kind.Struct : Type_Kind.Union, move_only = value.move_only})
	if is_struct {
		resolve_struct_fields(k, type, value)
	} else {
		resolve_union_variants(k, type, value)
	}
	return type
}

// `proc(...) -> R`. A clean answer is kept: one with diagnostics may have been
// rolled back, so it is reported again by the check that commits.
@(private = "file")
resolve_proc_type :: proc(k: ^Checker, value: ^Type_Proc) -> Type_Id {
	if value.denoted_type != INVALID_TYPE {
		return value.denoted_type
	}
	reported := k.c.error_count
	validate_param_attributes(k, value.params)
	builder := Signature_Builder {
		params  = make([dynamic]Type_Id, 0, len(value.params), context.temp_allocator),
		modes   = make([dynamic]Param_Mode, 0, len(value.params), context.temp_allocator),
		resets  = make([dynamic]bool, 0, len(value.params), context.temp_allocator),
		escapes = make([dynamic]Escape_Level, 0, len(value.params), context.temp_allocator),
		crosses = make([dynamic]bool, 0, len(value.params), context.temp_allocator),
	}
	generic := in_generic_signature(k)
	for parameter, position in value.params {
		count := max(len(parameter.names), 1)
		if parameter.type == nil {
			// A procedure type has no receiver to take a type from.
			name := len(parameter.names) > 0 ? parameter.names[0].name.text : "value"
			if parameter.default == nil && parameter.mode == .Value {
				// A bare word was meant as the type.
				errorf(
					k.c, parameter.span, "L0697",
					"`%s` is a parameter name here, not a type: a procedure type is written `proc(value: %s)`",
					name, name,
				)
			} else {
				errorf(
					k.c, parameter.span, "L0697",
					"a parameter of a procedure type needs a written type, as in `proc(%s: T)`", name,
				)
			}
		}
		written := resolve_type_reporting(k, parameter.type)
		for name_index in 0 ..< count {
			checked := check_signature_parameter(
				k, value.params, position, name_index, written, generic, in_foreign = false,
			)
			append_signature_parameter(&builder, checked)
		}
	}
	result_type, result_inout := resolve_signature_result(k, value.result)
	check_signature_convention(
		k, value.convention, builder.params[:], builder.modes[:], nil, result_type, result_inout, value.span,
	)
	type := intern_proc_type(
		k.c, builder.params[:], builder.modes[:], result_type, result_inout, value.convention, builder.resets[:],
		param_escapes = builder.escapes[:],
		param_cross_thread = builder.crosses[:],
	)
	if k.c.error_count == reported {
		value.denoted_type = type
	}
	value.resolution.kind = .Type
	return type
}

// A call in type position: a predeclared type constructor, a generic application,
// or a procedure that computes a type.
@(private = "file")
resolve_call_type :: proc(k: ^Checker, value: ^Expr_Call) -> Type_Id {
	// Predeclared type constructors: design.md "SIMD vectors", "Ranges", and
	// "Owned values".
	if predeclared_callee(k, value.callee, "Simd") {
		return resolve_simd_application(k, value)
	}
	if predeclared_callee(k, value.callee, "Range") {
		return resolve_range_application(k, value)
	}
	if predeclared_callee(k, value.callee, "Box") {
		return resolve_box_application(k, value)
	}
	// `Index_Type(1000)`: a call to a procedure that computes a type (design.md
	// "`type` and `typeid`"), folded where it is checked. Any other procedure's
	// call names none, and its receiver or argument position checks it once.
	callee_id := named_callee_symbol(k, value.callee)
	callee := symbol_of(k.c, callee_id)
	if callee != nil && callee.kind == .Proc && !symbol_is_generic(k, callee_id) {
		resolve_symbol_signature_in_place(k, callee_id)
		callee = symbol_of(k.c, callee_id)
		if (callee.decl == nil || callee.decl.sig_state == .Checked) && !compile_time_only_procedure(k.c, callee) {
			return INVALID_TYPE
		}
	}
	if (callee != nil && callee.kind == .Proc) || generic_template_of_callee(k, value.callee, {.Procedure}) != nil {
		if value.denoted_type == INVALID_TYPE {
			check_expr(k, value)
		}
		return value.denoted_type
	}
	// design.md "Parametric aliases": `Status(int)` denotes its body's type.
	if alias := generic_template_of_callee(k, value.callee, {.Alias}); alias != nil {
		return resolve_alias_application(k, value, alias, report = true)
	}
	// `Table(string, int)`: a generic application in type position.
	template := generic_template_of_callee(k, value.callee, {.Record})
	if template == nil {
		return INVALID_TYPE
	}
	if value.denoted_type != INVALID_TYPE {
		return value.denoted_type
	}
	return instantiate_record_application(k, value, template, report = true)
}

// `Type.Member` where the member is an associated type. Silent when the operand
// is not a type or the member is not one, so an ordinary value selection is
// still free to mean what it means.
@(private = "file")
resolve_associated_type :: proc(k: ^Checker, value: ^Expr_Selector) -> Type_Id {
	subject := resolve_type_syntax(k, value.operand)
	if subject == INVALID_TYPE {
		return INVALID_TYPE
	}
	member := find_member(k, subject, intern_identifier(k.c, value.name.text))
	sym := symbol_of(k.c, member)
	if sym == nil {
		return INVALID_TYPE
	}
	denoted := sym.kind == .Type ? sym.type : const_type_value(k, member, subject)
	if denoted == INVALID_TYPE {
		return INVALID_TYPE
	}
	return mark_denotes_type(&value.base, denoted, member)
}

// An invariant guard: every construct is compiled or has its own diagnostic,
// so reaching this is a compiler defect.
unsupported_construct :: proc(k: ^Checker, span: Span) {
	errorf(
		k.c,
		span,
		"L0350",
		"this construct parses, but the checker has no rule for it; this is a compiler defect",
	)
}

// Whether a type may be used for runtime storage, reported once per declaration.
gate_type :: proc(k: ^Checker, type: Type_Id, span: Span) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	// design.md "Interfaces as reusable constraints".
	if type_is_interface(k.c, type) {
		errorf(
			k.c,
			span,
			"L0441",
			"`%s` is an interface, which is compile-time metadata; write `dyn %s` for a runtime value",
			type_name(k.c, type),
			type_name(k.c, type),
		)
		return false
	}
	if !type_is_supported(k.c, type) {
		// A component that never resolved was already reported.
		if type_mentions_invalid(k.c, type) {
			return false
		}
		// A descriptor is unsupported on purpose, not by omission, so say which.
		if offender := compile_time_only_component(k.c, type); offender != INVALID_TYPE {
			report_compile_time_only(k, offender, span)
		} else {
			unsupported_construct(k, span)
		}
		return false
	}
	// design.md "Maps": key policies are settled where the map type is named.
	if !require_nested_map_key_policies(k, type, span) {
		return false
	}
	return true
}

// Says why a written type did not resolve, for the paths where
// `resolve_type_syntax` reported nothing itself.
report_unresolved_type :: proc(k: ^Checker, syntax: Expr) {
	// The parser already reported it: an error node, or a shape it marked,
	// such as `[1]proc(x: int) -> int{one}`, a type around a procedure
	// literal, whose components would otherwise be reported again.
	if _, is_error := syntax.(^Expr_Error); is_error || expr_has_error(syntax) {
		return
	}
	#partial switch value in syntax {
	case ^Expr_Ident:
		report_unresolved_name(k, value)

	case ^Expr_Call:
		report_unresolved_call(k, value)

	case ^Type_Poly:
		errorf(k.c, value.span, "L0437", "`$%s` is not bound here", value.name.text)

	case ^Expr_Selector:
		// `x.Name` where `x` is not an imported package; a package reports its own.
		if operand, operand_is_ident := value.operand.(^Expr_Ident); operand_is_ident {
			errorf(
				k.c, value.span, "L0306", "unknown type `%s.%s`: `%s` is not an imported package",
				operand.name, value.name.text, operand.name,
			)
			return
		}
		// A chained selector, `S.Iterator.Item`, names an associated type.
		head := source_text(k.c, value.operand)
		errorf(
			k.c, value.span, "L0306", "unknown type `%s.%s`: `%s` has no associated type `%s`",
			head, value.name.text, head, value.name.text,
		)

	case:
		// Name the component that failed rather than the shape around it.
		if component := unresolved_component(k, syntax); component != nil {
			report_unresolved_type(k, component)
			return
		}
		if array, is_array := syntax.(^Type_Array); is_array {
			// grammar.md "Types": `[?]T` is valid only on a composite literal.
			if array.length == nil {
				errorf(k.c, array.span, "L0384", "`[?]T` takes its length from a composite literal, so it is not a type on its own")
				return
			}
			if poly, is_poly := array.length.(^Type_Poly); is_poly {
				report_unresolved_type(k, poly)
				return
			}
			// The element resolves, so the length failed, and the constant it reads
			// said why, perhaps when its declaration was settled, before the caller
			// began, so a mark the caller took would not see it. With no error
			// anywhere, nothing did.
			if k.c.error_count > 0 {
				return
			}
		}
		unsupported_construct(k, expr_span(syntax))
	}
}

@(private = "file")
report_unresolved_name :: proc(k: ^Checker, ident: ^Expr_Ident) {
	if predeclared_callee(k, ident, "Simd") {
		errorf(k.c, ident.span, "L0681", "`Simd` needs its element type and lane count, as in `Simd(f32, 4)`")
		return
	}
	if predeclared_callee(k, ident, "Box") {
		errorf(k.c, ident.span, "L0713", "`Box` needs its element type, as in `Box(Node)`")
		return
	}
	named := lookup_symbol(k.scope, identifier_of(k.c, ident))
	if symbol_is_generic(k, named) {
		errorf(k.c, ident.span, "L0431", "`%s` is generic and needs its arguments, as in `%s(...)`", ident.name, ident.name)
		return
	}
	// design.md "`type` and `typeid`": a typeid is not usable as a type.
	if sym := symbol_of(k.c, named); sym != nil && sym.kind == .Const && type_underlying(k.c, sym.type) == TYPE_TYPEID {
		errorf(k.c, ident.span, "L0306", "`%s` is a `typeid` value, not a type", ident.name)
		return
	}
	errorf(k.c, ident.span, "L0306", "unknown type `%s`", ident.name)
}

// `Name(args)` that names no type.
@(private = "file")
report_unresolved_call :: proc(k: ^Checker, call: ^Expr_Call) {
	if report_handle_type_spelling(k, call, type_position = true) {
		return
	}
	// A generic rejected at its declaration was reported there, and an
	// application of a known one reported its own arguments.
	if generic_template_of_callee(k, call.callee, TYPE_GENERICS) != nil {
		return
	}
	if callee := symbol_of(k.c, named_callee_symbol(k, call.callee)); callee != nil && callee.kind == .Proc {
		returned := call.type != INVALID_TYPE ? call.type : callee.result
		if returned == INVALID_TYPE {
			errorf(k.c, call.span, "L0306", "this call does not compute a type: it returns nothing")
		} else {
			errorf(k.c, call.span, "L0306", "this call does not compute a type: it returns `%s`", type_name(k.c, returned))
		}
		return
	}
	// `resolve_simd_application` reports all but an unbound `Simd(f32, $M)`.
	if predeclared_callee(k, call.callee, "Simd") {
		if len(call.args) == 2 {
			if poly, is_poly := call.args[1].value.(^Type_Poly); is_poly {
				report_unresolved_type(k, poly)
			}
		}
		return
	}
	errorf(k.c, expr_span(call.callee), "L0306", "unknown type `%s`", source_text(k.c, call.callee))
}

// The component of a composed type that did not resolve, or nil.
@(private = "file")
unresolved_component :: proc(k: ^Checker, syntax: Expr) -> Expr {
	failed :: proc(k: ^Checker, part: Expr) -> bool {
		return part != nil && resolve_type_syntax(k, part) == INVALID_TYPE
	}
	#partial switch value in syntax {
	case ^Type_Pointer:
		if failed(k, value.elem) { return value.elem }
	case ^Type_C_Pointer:
		if failed(k, value.elem) { return value.elem }
	case ^Type_Slice:
		if failed(k, value.elem) { return value.elem }
	case ^Type_Dynamic_Array:
		if failed(k, value.elem) { return value.elem }
	case ^Type_Array:
		if failed(k, value.elem) { return value.elem }
	case ^Type_Distinct:
		if failed(k, value.elem) { return value.elem }
	case ^Type_Map:
		if failed(k, value.key) { return value.key }
		if failed(k, value.value) { return value.value }
	}
	return nil
}
