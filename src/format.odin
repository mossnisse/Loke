// design.md "String format printing": an `any_view` carries only a pointer and a
// `typeid`, so erased printing has one formatter per concrete type — the type's
// own `format` from its owning package, or a compiler-generated one.
package lokec

// A type's inherent `format`, or INVALID_SYMBOL when the compiler generates one.
@(private = "file")
formatter_of :: proc(c: ^Compiler, type, writer, options: Type_Id, reported: ^map[Span]bool) -> Symbol_Id {
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL
	}
	for member in info.members {
		sym := symbol_of(c, member)
		if sym == nil || sym.synth != .None || sym.generic || identifier_text(c, sym.name) != "format" {
			continue
		}
		if formatter_signature_ok(sym, type, writer, options) {
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
		if hook := formatter_of(c, type, writer, options, &reported); hook != INVALID_SYMBOL {
			c.formatters[type] = hook
		}
	}
}

// The thunk passes the caller's own storage, so the receiver must be a borrow
// of the type itself, and nothing is given back.
@(private = "file")
formatter_signature_ok :: proc(sym: ^Symbol, subject, writer, options: Type_Id) -> bool {
	if !sym.has_receiver || sym.receiver != .Borrow {
		return false
	}
	return len(sym.params) == 3 && sym.result == INVALID_TYPE &&
		sym.params[0] == subject && sym.params[1] == writer && sym.params[2] == options
}

// The compiler-owned half of `core:fmt`, reachable only from inside it:
//
//   stdout_writer() -> Writer
//   stderr_writer() -> Writer
//   write_bytes(w: Writer, text: string_view)
//   format_any(value: any_view, w: Writer, options: Options)
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
	case .Fmt_Format_Any:
		wanted = []Type_Id{TYPE_ANY_VIEW, writer, options}
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
	pkg := package_of(k.c, k.pkg)
	if pkg == nil || pkg.scope == nil {
		return INVALID_TYPE, false
	}
	symbol := symbol_of(k.c, pkg.scope.names[intern_identifier(k.c, name)])
	if symbol != nil && symbol.kind == .Type && symbol.type != INVALID_TYPE {
		return symbol.type, true
	}
	return INVALID_TYPE, false
}
