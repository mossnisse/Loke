// design.md "String format printing": generated format members and the ordinary
// Formattable witnesses that erased arguments recover through their typeid.
package lokec

// A generated method is an ordinary slot candidate. Hypothetical requirements
// may create its signature, but only a real use enrolls its body and typeid.
ensure_format_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	if identifier_text(k.c, name) != "format" || !type_is_printable(k.c, type) || type_is_untyped(k.c, type) {
		return
	}
	writer, options: Type_Id
	for pkg in k.c.packages {
		if pkg.key != STD_FMT { continue }
		writer, _ = package_type_named(k, package_of(k.c, pkg.id), "Writer")
		options, _ = package_type_named(k, package_of(k.c, pkg.id), "Options")
		break
	}
	if writer == INVALID_TYPE || options == INVALID_TYPE { return }
	k.c.runtime_types["Writer"], k.c.runtime_types["Options"] = writer, options
	id := INVALID_SYMBOL
	for member in type_of(k.c, type).members {
		if sym := symbol_of(k.c, member); sym != nil && sym.name == name {
			if sym.synth != .Standard_Format { return }
			id = member
			break
		}
	}
	if id == INVALID_SYMBOL {
		id = synth_proc(k.c, "format", .Standard_Format, type,
			[]Type_Id{type, writer, options}, []Param_Mode{.Borrow, .Value, .Value}, INVALID_TYPE, enroll = false)
		sym := symbol_of(k.c, id)
		sym.has_receiver, sym.receiver = true, .Borrow
		add_members(k.c, type, []Symbol_Id{id})
	}
	if k.c.speculation_depth == 0 {
		k.c.format_requested = true
		request_typeid(k.c, type)
		info := type_of(k.c, type)
		if .Format_Enrolled not_in info.contributed {
			info.contributed += {.Format_Enrolled}
			append(&k.c.synth_procs, id)
		}
	}
}

type_is_printable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type != INVALID_TYPE && type_is_supported(c, type) && !type_is_compile_time_only(c, type)
}

// A type's inherent `format`, or INVALID_SYMBOL when the compiler generates one.
@(private = "file")
formatter_of :: proc(c: ^Compiler, type, writer, options: Type_Id, reported: ^map[Span]bool) -> Symbol_Id {
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL
	}
	for member in info.members {
		sym := symbol_of(c, member)
		if sym == nil || sym.synth != .None || sym.bound_excluded || identifier_text(c, sym.name) != "format" {
			continue
		}
		if formatter_signature_ok(c, sym, type, writer, options) {
			return member
		}
		// design.md gives the name to the protocol, so a `format` that cannot
		// serve it is a mistake, not an unrelated procedure. Reported once per
		// written declaration, not per generic instance.
		if reported[sym.span] {
			return INVALID_SYMBOL
		}
		reported[sym.span] = true
		errorf(
			c, sym.span, "L0572",
			"`format` on `%s` is what erased printing calls, so it is written `proc(self, w: fmt.Writer, o: fmt.Options)`",
			type_name(c, type),
		)
		return INVALID_SYMBOL
	}
	return INVALID_SYMBOL
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
		_ = formatter_of(c, type, writer, options, &reported)
	}
	k := Checker{c = c}
	defer delete(k.nil_uses)
	for pkg in c.packages {
		if pkg.key != STD_FMT { continue }
		k.pkg, k.lookup_pkg, k.scope = pkg.id, pkg.id, pkg.scope
		view, exists := package_type_named(&k, package_of(c, pkg.id), "Format_View")
		if !exists { return }
		c.runtime_types["Format_View"] = view
		dyn := underlying_info(c, view)
		iface := interface_info_for(&k, dyn.dyn_interface)
		for type in c.typeid_order {
			if !type_is_printable(c, type) { continue }
			c.formatters[type] = request_witness(&k, iface, type, nil, no_span())
		}
		break
	}
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
//   format_view(value: any_view) -> dyn Formattable
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
	case .Fmt_Format_View:
		wanted = []Type_Id{TYPE_ANY_VIEW}
		result, _ = local_type_named(k, "Format_View")
		k.c.runtime_types["Format_View"] = result
		if k.c.speculation_depth == 0 {
			k.c.format_requested = true
		}
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

// A type `pkg` declares by `name`, directly or as an alias such as
// `Writer :: dyn mut Sink` — a constant whose value is a type.
package_type_named :: proc(k: ^Checker, pkg: ^Package, name: string) -> (Type_Id, bool) {
	if pkg == nil || pkg.scope == nil {
		return INVALID_TYPE, false
	}
	symbol_id := pkg.scope.names[intern_identifier(k.c, name)] or_else INVALID_SYMBOL
	symbol := symbol_of(k.c, symbol_id)
	if symbol != nil && symbol.kind == .Type {
		resolve_symbol_signature_in_place(k, symbol_id)
		symbol = symbol_of(k.c, symbol_id)
		return symbol.type, symbol.type != INVALID_TYPE
	}
	if symbol != nil && symbol.kind == .Const {
		if symbol.decl != nil && symbol.decl.check_state == .Unchecked {
			check_symbol_decl_in_place(k, symbol_id)
			symbol = symbol_of(k.c, symbol_id)
		}
		if const_names_type(k.c, symbol.const_value, symbol.type) {
			return symbol.const_value.type_value, true
		}
	}
	return INVALID_TYPE, false
}
