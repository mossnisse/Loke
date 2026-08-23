// Coherent runtime formatting (design.md "String format printing", m6a-plan
// decision "Coherent formatting").
//
// design.md makes formatting a library protocol: a value type provides a
// `format(value, writer, options)` procedure. What the compiler owns is the
// *erased* half. `fmt.println(a, b, c)` receives `..any_view`, and an
// `any_view` carries only a pointer and a `typeid` — so a callee cannot recover
// a call-site-specific visible overload. Runtime formatting therefore has one
// formatter per concrete `typeid`:
//
//   - a built-in type gets a compiler-generated formatter;
//   - a user type gets its own `format` when that `format` is declared in the
//     type's owning package, and a compiler-generated field-wise one otherwise;
//   - a caller-local extension's `format` stays callable explicitly and never
//     changes what `print` does.
//
// The dispatch table is private and parallel to the type-info table. The public
// `Type_Info` layout deliberately exposes no code pointers, which is also what
// keeps `base:runtime` from having to know `core:fmt` exists.
package lokec

// The formatter a concrete type answers to, or INVALID_SYMBOL when the compiler
// generates one. design.md's coherence rule in one predicate: only the package
// that owns the type may supply it.
formatter_of :: proc(c: ^Compiler, type: Type_Id) -> Symbol_Id {
	// Formatting is coherent per *concrete identity*. In particular a distinct
	// type owns different inherent members from the representation it wraps.
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL
	}
	chosen := INVALID_SYMBOL
	for member in info.members {
		sym := symbol_of(c, member)
		if sym == nil || sym.synth != .None || identifier_text(c, sym.name) != "format" {
			continue
		}
		if !formatter_signature_ok(c, sym) {
			continue
		}
		if chosen != INVALID_SYMBOL {
			errorf(
				c, sym.span, "L0572",
				"`%s` has two `format` procedures in its own package, so its erased formatting would be ambiguous",
				type_name(c, type),
			)
			if previous := symbol_of(c, chosen); previous != nil {
				add_notef(c, previous.span, "the other one is declared here")
			}
			continue
		}
		chosen = member
	}
	return chosen
}

// design.md's coherence rule, resolved once for the whole program: an `impl`
// block in the type's own package supplies its formatter, and a caller-local
// an extension never does — an `any_view` carries only a pointer and a `typeid`, so
// a callee has no way to see a call-site-specific overload. `Package.extensions`
// is where an extension member lives, and nothing here reads it.
discover_formatters :: proc(c: ^Compiler) {
	if !c.format_requested {
		return
	}
	for type in c.typeid_order {
		if _, done := c.formatters[type]; done {
			continue
		}
		c.formatters[type] = formatter_of(c, type)
	}
}

// `format(self, writer: Writer, options: Options)`. The two library types are
// resolved through the importing package, exactly as `Source_Code_Location` is,
// so there is one identity for each.
@(private = "file")
formatter_signature_ok :: proc(c: ^Compiler, sym: ^Symbol) -> bool {
	if len(sym.params) != 3 || len(sym.results) != 0 {
		return false
	}
	writer, has_writer := c.runtime_types["Writer"]
	options, has_options := c.runtime_types["Options"]
	if !has_writer || !has_options {
		return false
	}
	return sym.params[1] == writer && sym.params[2] == options
}

// Whether a concrete type can be formatted at all. design.md's erased printing
// covers every runtime value; a compile-time-only type has none to print.
type_is_printable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type != INVALID_TYPE &&
		type_is_supported(c, type) &&
		!type_is_compile_time_only(c, type)
}

// The compiler-owned half of `core:fmt`, checked here so `core:fmt`'s own
// source can be ordinary Loke.
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
		errorf(k.c, v.span, "L0572", "`%s` needs `core:fmt`'s own `Writer` and `Options`", ident.name)
		v.type = INVALID_TYPE
		return
	}
	k.c.runtime_types["Writer"], k.c.runtime_types["Options"] = writer, options

	wanted: []Type_Id
	result := TYPE_VOID
	switch kind {
	case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer:
		result = writer
	case .Fmt_Write_Bytes:
		wanted = []Type_Id{writer, TYPE_STRING_VIEW}
	case .Fmt_Format_Any:
		// design.md: formatting is coherent per concrete `typeid`, so the erased
		// value is all the dispatch has and all it needs.
		wanted = []Type_Id{TYPE_ANY_VIEW, writer, options}
		if k.c.speculation_depth == 0 {
			k.c.format_requested = true
		}
	case .None, .Assert, .Panic, .Size_Of, .Align_Of, .Offset_Of, .Len, .Cap, .Hash,
	     .Static_Assert, .Build_Config, .Source_Location, .Caller_Location,
	     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of, .Iter, .New, .New_Clone, .Make, .Free,
	     .Free_All, .Default_Allocator, .Drop, .Exchange, .Type_Info_Of,
	     .Unsafe_Raw_Data, .Unsafe_String_View, .Unsafe_C_String_View, .Strings_Allocate,
	     .Clone, .Try_Clone:
		v.type = INVALID_TYPE
		return
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
		value, passed := check_argument_value(k, v.args[index].value, target)
		bound[index] = value
		if !passed {
			v.type = INVALID_TYPE
			return
		}
	}
	v.bound = bound
	v.type = result
}

// A type declared by the package being checked. `core:fmt` owns `Writer` and
// `Options`, and these builtins are only reachable from inside it.
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
