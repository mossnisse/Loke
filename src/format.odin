// standard-library.md "Printed forms": generated format members and the ordinary
// Formattable witnesses that erased arguments recover through their typeid.
package lokec

// A generated method is an ordinary slot candidate. Hypothetical requirements
// may create its signature, but only a real use enrolls its body and typeid.
ensure_format_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	if identifier_text(k.c, name) != "format" || !type_is_printable(k.c, type) || type_is_untyped(k.c, type) {
		return
	}
	// What a slot can meet takes the default's place: a written `format`, or the
	// forwarding one of a `dyn` view whose interface has that slot.
	id := INVALID_SYMBOL
	for member in type_of(k.c, type).members {
		sym := symbol_of(k.c, member)
		if sym == nil || sym.name != name { continue }
		if sym.synth == .Standard_Format {
			id = member
		} else if !sym.bound_excluded && format_meets_slot(k.c, sym, type) {
			return
		}
	}
	if id == INVALID_SYMBOL {
		writer, _ := package_type_named(k, standard_package(k.c, STD_FMT), "Writer")
		options, _ := package_type_named(k, standard_package(k.c, STD_FMT), "Options")
		if writer == INVALID_TYPE || options == INVALID_TYPE { return }
		id = synth_receiver_proc(k.c, "format", .Standard_Format, type,
			[]Type_Id{type, writer, options}, []Param_Mode{.Borrow, .Value, .Value}, INVALID_TYPE, enroll = false)
		add_members(k.c, type, []Symbol_Id{id})
	}
	if committing(k.c) {
		k.c.format_requested = true
		request_typeid(k.c, type)
		info := type_of(k.c, type)
		if .Format_Enrolled not_in info.contributed {
			info.contributed += {.Format_Enrolled}
			enroll_synth(k.c, id)
		}
	}
}

type_is_printable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	// design.md "Capture literals": a callable has no printed form.
	return type_is_supported(c, type) && !type_is_compile_time_only(c, type) &&
		!type_is_capture_record(c, type)
}

// Whether a type's own `format` is what printing uses.
type_has_written_format :: proc(c: ^Compiler, type: Type_Id) -> bool {
	sym := written_format_member(c, type)
	return sym != nil && format_meets_slot(c, sym, type)
}

// A public type's private `format` meets no slot (design.md "Interface bodies"),
// so the type prints by the generated default.
format_meets_slot :: proc(c: ^Compiler, sym: ^Symbol, type: Type_Id) -> bool {
	return sym.public || !type_is_exported(c, type)
}

// Whether printing a `type` may run a program's code: a `format` of its own or of
// a part it prints, or one a `dyn` view's slot calls. The rest prints by a generated
// spelling, which writes nothing but the report.
type_prints_through_method :: proc(c: ^Compiler, type: Type_Id) -> bool {
	seen: Type_Walk
	defer delete(seen)
	return prints_through_method_walk(c, type, &seen)
}

// Follows what `emit_format_body` and `emit_format_nested` print, which the
// checker cannot call. A `distinct` type prints its underlying type's parts by a
// default of its own, not by that type's `format` or `dyn` slot.
@(private = "file")
prints_through_method_walk :: proc(c: ^Compiler, type: Type_Id, seen: ^Type_Walk) -> bool {
	if type_has_written_format(c, type) {
		return true
	}
	info := underlying_info(c, type)
	if info == nil || !type_walk_enter(seen, type, type_of(c, type)) {
		return false
	}
	#partial switch info.kind {
	case .Dyn:
		return dyn_has_format_slot(c, type)
	case .Array:
		return info.count > 0 && prints_through_method_walk(c, info.element, seen)
	case .Simd, .Slice, .Dynamic_Array, .Box, .Pointer:
		return prints_through_method_walk(c, info.element, seen)
	case .Map:
		return prints_through_method_walk(c, info.key, seen) || prints_through_method_walk(c, info.element, seen)
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && sym.public && prints_through_method_walk(c, sym.type, seen) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if prints_through_method_walk(c, variant, seen) {
				return true
			}
		}
	}
	return false
}

// Whether `view` forwards a `format` slot, as `dyn fmt.Formattable` and a view of
// an interface composing it do. Any other view prints its type's name.
@(private = "file")
dyn_has_format_slot :: proc(c: ^Compiler, view: Type_Id) -> bool {
	for member in type_of(c, view).members {
		sym := symbol_of(c, member)
		if sym != nil && sym.synth == .Dyn_Forward && identifier_text(c, sym.name) == "format" {
			return true
		}
	}
	return false
}

// A type's own declared `format`, whether or not a slot may use it.
written_format_member :: proc(c: ^Compiler, type: Type_Id) -> ^Symbol {
	info := type_of(c, type)
	if info == nil {
		return nil
	}
	for member in info.members {
		sym := symbol_of(c, member)
		if sym != nil && sym.synth == .None && !sym.bound_excluded && identifier_text(c, sym.name) == "format" {
			return sym
		}
	}
	return nil
}

// Whether a generated format is hidden from observer: a written or visible local
// format takes the name (design.md "Interface bodies"); interface slots bypass this.
standard_format_hidden :: proc(c: ^Compiler, sym: ^Symbol, observer: Package_Id) -> bool {
	if sym.synth != .Standard_Format {
		return false
	}
	if written_format_member(c, sym.owner_type) != nil {
		return true
	}
	pkg := package_of(c, observer)
	if pkg == nil {
		return false
	}
	local := symbol_of(c, member_named(c, pkg.extensions[sym.owner_type], sym.name))
	return local != nil && !local.bound_excluded && (local.pkg == observer || local.public)
}

// standard-library.md "Printed forms": a `format` that cannot serve the slot is a
// mistake, not an unrelated procedure. Reported once per written declaration, not
// per generic instance.
@(private = "file")
check_formatter :: proc(c: ^Compiler, type: Type_Id, reported: ^map[Span]bool) {
	if !format_misdeclared(c, type) {
		return
	}
	sym := written_format_member(c, type)
	if reported[sym.span] {
		return
	}
	reported[sym.span] = true
	errorf(
		c, sym.span, "L0572",
		"`format` on `%s` is what erased printing calls, so it is written `proc(self, w: fmt.Writer, o: fmt.Options)`",
		type_name(c, type),
	)
}

discover_formatters :: proc(c: ^Compiler) {
	if c.formatters_ready {
		return
	}
	c.formatters_ready = true
	report_misdeclared_formatters(c)
	build_formatter_witnesses(c)
}

// Checks every type's `format`, printed or not, so a wrong one is an error in
// every program that sees it. Extension members are never formatters.
@(private = "file")
report_misdeclared_formatters :: proc(c: ^Compiler) {
	reported := make(map[Span]bool, context.temp_allocator)
	for index in 0 ..< len(c.types) {
		check_formatter(c, Type_Id(index), &reported)
	}
}

// Without `core:fmt` no formatter can be spelled.
@(private = "file")
build_formatter_witnesses :: proc(c: ^Compiler) {
	view := format_view_interface(c)
	if view == INVALID_SYMBOL {
		return
	}
	pkg := package_of(c, symbol_of(c, view).pkg)
	k := Checker{c = c, location = {pkg = pkg.id, lookup_pkg = pkg.id, scope = pkg.scope}}
	iface := interface_info_for(&k, view)
	for type in c.typeid_order {
		if !type_is_printable(c, type) { continue }
		c.formatters[type] = request_witness(&k, iface, type, nil, NO_SPAN)
	}
}

// The interface of printing's `dyn fmt.Formattable`, once `core:fmt` is checked.
format_view_interface :: proc(c: ^Compiler) -> Symbol_Id {
	view, found := c.runtime_types["Format_View"]
	return underlying_info(c, view).dyn_interface if found else INVALID_SYMBOL
}

// Whether `iface` is printing's `fmt.Formattable`. By name, so it also answers
// while `core:fmt` is being checked.
interface_is_printing :: proc(c: ^Compiler, iface: Symbol_Id) -> bool {
	sym := symbol_of(c, iface)
	return sym != nil && package_of(c, sym.pkg).key == STD_FMT && identifier_text(c, sym.name) == "Formattable"
}

// Whether `element` is printing's `dyn fmt.Formattable`.
dyn_views_printing :: proc(c: ^Compiler, element: Type_Id) -> bool {
	info := underlying_info(c, element)
	return info != nil && info.kind == .Dyn && interface_is_printing(c, info.dyn_interface)
}

// Whether `type` writes a `format` that cannot serve printing, which
// `check_formatter` reports once at its declaration rather than at every print.
// False until `core:fmt` is checked, which writes no wrong one.
format_misdeclared :: proc(c: ^Compiler, type: Type_Id) -> bool {
	sym := written_format_member(c, type)
	if sym == nil {
		return false
	}
	writer, has_writer := c.runtime_types["Writer"]
	options, has_options := c.runtime_types["Options"]
	return has_writer && has_options && !formatter_signature_ok(c, sym, type, writer, options)
}

// The thunk passes the caller's own storage, so the receiver cannot be `move` or
// `inout`, and nothing is given back.
@(private = "file")
formatter_signature_ok :: proc(c: ^Compiler, sym: ^Symbol, subject, writer, options: Type_Id) -> bool {
	if sym.generic || !sym.has_receiver || (sym.receiver != .Borrow && sym.receiver != .Value) {
		return false
	}
	info := type_of(c, sym.proc_type)
	if info == nil || info.convention != "" { return false }
	return len(sym.params) == 3 && sym.result == INVALID_TYPE &&
		sym.params[0] == subject && sym.params[1] == writer && sym.params[2] == options &&
		symbol_param_mode(c, sym, 1) == .Value && symbol_param_mode(c, sym, 2) == .Value
}

// The compiler-owned half of `core:fmt`, reachable only from inside it:
//
//   stdout_writer() -> Writer
//   stderr_writer() -> Writer
//   write_bytes(w: Writer, text: string_view)
check_fmt_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.value_category = .Value
	v.type = INVALID_TYPE
	writer, has_writer := package_type_named(k, package_of(k.c, k.pkg), "Writer")
	if !has_writer {
		errorf(k.c, v.span, "L0601", "`%s` needs `core:fmt`'s own `Writer`", ident.name)
		return
	}

	wanted: []Type_Id
	result := TYPE_VOID
	#partial switch kind {
	case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer:
		result = writer
	case .Fmt_Write_Bytes:
		wanted = []Type_Id{writer, TYPE_STRING_VIEW}
	}

	if !builtin_arity_ok(k, v, ident, "L0322", len(wanted)) {
		return
	}
	bound := make([]Expr, len(wanted), k.c.semantic_allocator)
	for target, index in wanted {
		value, passed := check_argument_value(k, v.args[index].value, target)
		bound[index] = value
		if !passed {
			return
		}
	}
	v.bound = bound
	v.type = result
}
