// standard-library.md "Printed forms": generated format members and the ordinary
// Formattable witnesses that erased arguments recover through their typeid.
package lokec

// A generated method is an ordinary slot candidate. Hypothetical requirements
// may create its signature, but only a real use enrolls its body and typeid.
ensure_format_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	if identifier_text(k.c, name) != "format" || !type_is_printable(k.c, type) || type_is_untyped(k.c, type) {
		return
	}
	writer, _ := package_type_named(k, standard_package(k.c, STD_FMT), "Writer")
	options, _ := package_type_named(k, standard_package(k.c, STD_FMT), "Options")
	if writer == INVALID_TYPE || options == INVALID_TYPE { return }
	k.c.runtime_types["Writer"], k.c.runtime_types["Options"] = writer, options
	// A public type's private `format` meets no slot (design.md "Interface
	// bodies"), so the slot, and with it printing, still needs the default.
	hidden := type_is_exported(k.c, type)
	id := INVALID_SYMBOL
	for member in type_of(k.c, type).members {
		sym := symbol_of(k.c, member)
		if sym == nil || sym.name != name { continue }
		if sym.synth == .Standard_Format {
			id = member
		} else if !(hidden && sym.synth == .None && !sym.public) {
			return
		}
	}
	if id == INVALID_SYMBOL {
		id = synth_proc(k.c, "format", .Standard_Format, type,
			[]Type_Id{type, writer, options}, []Param_Mode{.Borrow, .Value, .Value}, INVALID_TYPE, enroll = false)
		sym := symbol_of(k.c, id)
		sym.has_receiver, sym.receiver = true, .Borrow
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
	return type != INVALID_TYPE && type_is_supported(c, type) && !type_is_compile_time_only(c, type) &&
		!type_is_capture_record(c, type)
}

// Whether a type declares its own `format` that printing uses: one the
// `Formattable` slot can meet. A public type's private `format` meets no slot
// (design.md "Interface bodies"), so the type prints by the generated default.
type_has_written_format :: proc(c: ^Compiler, type: Type_Id) -> bool {
	sym := written_format_member(c, type)
	return sym != nil && format_meets_slot(c, sym, type)
}

format_meets_slot :: proc(c: ^Compiler, sym: ^Symbol, type: Type_Id) -> bool {
	return sym.public || !type_is_exported(c, type)
}

// Whether printing a `type` may run a program's code: a `format` of its own or of
// a part, or whatever a `dyn` view in it names. The rest prints by a generated
// spelling, which writes nothing but the report.
type_prints_through_method :: proc(c: ^Compiler, type: Type_Id) -> bool {
	visiting := make(map[Type_Id]bool, 8, context.temp_allocator)
	return prints_through_method_walk(c, type, &visiting)
}

@(private = "file")
prints_through_method_walk :: proc(c: ^Compiler, type: Type_Id, visiting: ^map[Type_Id]bool) -> bool {
	if type_has_written_format(c, type) {
		return true
	}
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil || visiting[under] {
		return false
	}
	visiting[under] = true
	if type_has_written_format(c, under) {
		return true
	}
	#partial switch info.kind {
	case .Dyn:
		return true
	case .Array:
		return info.count > 0 && prints_through_method_walk(c, info.element, visiting)
	case .Simd, .Slice, .Dynamic_Array, .Box, .Pointer:
		return prints_through_method_walk(c, info.element, visiting)
	case .Map:
		return prints_through_method_walk(c, info.key, visiting) || prints_through_method_walk(c, info.element, visiting)
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && prints_through_method_walk(c, sym.type, visiting) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if variant != TYPE_VOID && prints_through_method_walk(c, variant, visiting) {
				return true
			}
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

// design.md gives the name to the protocol, so a type's `format` that cannot
// serve it is a mistake, not an unrelated procedure. Reported once per written
// declaration, not per generic instance.
@(private = "file")
check_formatter :: proc(c: ^Compiler, type, writer, options: Type_Id, reported: ^map[Span]bool) {
	sym := written_format_member(c, type)
	if sym == nil || formatter_signature_ok(c, sym, type, writer, options) || reported[sym.span] {
		return
	}
	reported[sym.span] = true
	errorf(
		c, sym.span, "L0572",
		"`format` on `%s` is what erased printing calls, so it is written `proc(self, w: fmt.Writer, o: fmt.Options)`",
		type_name(c, type),
	)
}

// Checks every type's `format`, printed or not, so a wrong one is an error in
// every program that sees it. Extension members are never formatters.
discover_formatters :: proc(c: ^Compiler) {
	if c.formatters_ready {
		return
	}
	c.formatters_ready = true
	// Recorded when `core:fmt` is checked; without it no formatter can be spelled.
	writer, has_writer := c.runtime_types["Writer"]
	options, has_options := c.runtime_types["Options"]
	if !has_writer || !has_options {
		return
	}
	reported := make(map[Span]bool, context.temp_allocator)
	for index in 0 ..< len(c.types) {
		type := Type_Id(index)
		check_formatter(c, type, writer, options, &reported)
	}
	pkg := standard_package(c, STD_FMT)
	if pkg == nil { return }
	k := Checker{c = c, pkg = pkg.id, lookup_pkg = pkg.id, scope = pkg.scope}
	view, exists := package_type_named(&k, pkg, "Format_View")
	if !exists { return }
	c.runtime_types["Format_View"] = view
	dyn := underlying_info(c, view)
	iface := interface_info_for(&k, dyn.dyn_interface)
	for type in c.typeid_order {
		if !type_is_printable(c, type) { continue }
		c.formatters[type] = request_witness(&k, iface, type, nil, no_span())
	}
}

// Whether `element` is printing's `dyn fmt.Formattable`.
dyn_views_printing :: proc(c: ^Compiler, element: Type_Id) -> bool {
	info := underlying_info(c, element)
	if info == nil || info.kind != .Dyn {
		return false
	}
	sym := symbol_of(c, info.dyn_interface)
	return sym != nil && package_of(c, sym.pkg).key == STD_FMT && identifier_text(c, sym.name) == "Formattable"
}

// Whether `type` writes a `format` that cannot serve printing, which
// `check_formatter` reports once at its declaration rather than at every print.
format_misdeclared :: proc(c: ^Compiler, type: Type_Id) -> bool {
	writer, has_writer := c.runtime_types["Writer"]
	options, has_options := c.runtime_types["Options"]
	sym := written_format_member(c, type)
	return has_writer && has_options && sym != nil && !formatter_signature_ok(c, sym, type, writer, options)
}

// The thunk passes the caller's own storage, so the receiver must be a borrow
// of the type itself, and nothing is given back.
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
	writer, has_writer := local_type_named(k, "Writer")
	options, has_options := local_type_named(k, "Options")
	if !has_writer || !has_options {
		errorf(k.c, v.span, "L0601", "`%s` needs `core:fmt`'s own `Writer` and `Options`", ident.name)
		v.type = INVALID_TYPE
		return
	}
	k.c.runtime_types["Writer"], k.c.runtime_types["Options"] = writer, options

	wanted: []Type_Id
	result := TYPE_VOID
	#partial switch kind {
	case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer:
		result = writer
	case .Fmt_Write_Bytes:
		wanted = []Type_Id{writer, TYPE_STRING_VIEW}
	}

	if len(v.args) != len(wanted) {
		errorf(
			k.c, v.span, "L0322",
			"`%s` takes %d argument%s, found %d",
			ident.name, len(wanted), len(wanted) == 1 ? "" : "s", len(v.args),
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, len(wanted), k.c.semantic_allocator)
	for target, index in wanted {
		arg := v.args[index]
		if arg.name.text != "" || arg.mode != .Value {
			errorf(k.c, arg.span, "L0371", "`%s` takes plain positional arguments only", ident.name)
			v.type = INVALID_TYPE
			return
		}
		value, passed := check_argument_value(k, arg.value, target)
		bound[index] = value
		if !passed {
			v.type = INVALID_TYPE
			return
		}
	}
	v.bound = bound
	v.type = result
}

// A type declared by the package being checked, which is `core:fmt` here.
@(private = "file")
local_type_named :: proc(k: ^Checker, name: string) -> (Type_Id, bool) {
	return package_type_named(k, package_of(k.c, k.pkg), name)
}
