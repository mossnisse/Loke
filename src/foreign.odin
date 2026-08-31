package lokec

// The foreign system (design.md "Foreign system", m7-plan step 4): `foreign
// import` of a library or assembly file, and `foreign <lib> { ... }` blocks of
// bodiless procedures and globals. A block's members are collected as ordinary
// package symbols in the same top-level pass as declarations, so only
// signature checking, emission, and the ABI-safety rule need a foreign-specific
// path — not name resolution, visibility, or overload ranking.

// The default calling convention is `loke`, except inside a foreign block
// where it is `c` (design.md). A block-wide `@(default_calling_convention)`
// changes that default; a member's own convention still wins.
foreign_default_convention :: proc(k: ^Checker, block: ^Item_Foreign_Block) -> string {
	if value, ok := attribute_string_value(k.c, block.attributes, "default_calling_convention"); ok {
		return value
	}
	return "c"
}

// Collects a foreign block's members as ordinary package symbols and marks them
// foreign. Runs in `prepare_package`, beside ordinary declaration collection.
// The block supplies visibility and calling-convention defaults; a member's
// own attribute or written convention overrides either.
declare_foreign_block :: proc(k: ^Checker, block: ^Item_Foreign_Block) {
	convention := foreign_default_convention(k, block)
	block_public, block_sets_visibility := foreign_block_visibility(k, block)

	for member in block.members {
		d, ok := member.(^Decl)
		if !ok {
			continue
		}
		declare_all(k, d, top_level = true)

		// A foreign proc with no written convention inherits the block default; the
		// signature resolver reads this off the AST like an explicit one.
		if literal := decl_proc_literal(d); literal != nil && literal.signature != nil {
			if literal.signature.convention == "" {
				literal.signature.convention = convention
			}
		}

		own_public := has_attribute(d.attributes, "public")
		own_private := has_attribute(d.attributes, "private")
		for sid in d.symbols {
			sym := symbol_of(k.c, sid)
			if sym == nil {
				continue
			}
			sym.is_foreign = true
			// A member's own `@(public)`/`@(private)` wins; otherwise the block's
			// default applies, and failing that the visibility declare_all computed.
			if !own_public && !own_private && block_sets_visibility {
				sym.public = block_public
			}
		}
	}
}

// A foreign block's `@(public)`/`@(private)` visibility default, and whether it
// set one at all. Contradictory attributes are diagnosed once here.
@(private = "file")
foreign_block_visibility :: proc(k: ^Checker, block: ^Item_Foreign_Block) -> (public: bool, set: bool) {
	has_public := has_attribute(block.attributes, "public")
	has_private := has_attribute(block.attributes, "private")
	if has_public && has_private {
		errorf(k.c, block.span, "L0332", "this foreign block is both `@(public)` and `@(private)`")
		return false, false
	}
	return has_public, has_public || has_private
}

// design.md "@(require_results)": a foreign block's policy is copied to every
// procedure member. `@(link_name)` sets a member's exact external symbol;
// otherwise the member's own name is the link name. Runs in
// `check_package_bodies`, after signatures so the symbols and kinds exist.
check_foreign_block :: proc(k: ^Checker, block: ^Item_Foreign_Block) {
	block_requires := has_attribute(block.attributes, "require_results")
	for member in block.members {
		if _, recovered := member.(^Item_Error); recovered {
			// The parser already said what it could not read here; L0622 below would
			// be a second diagnostic for the same span (m7-plan step 6).
			continue
		}
		// `parse_member_list` produces a `^Decl` or the recovery node above and
		// nothing else, so this is an invariant guard rather than a reachable
		// diagnostic (m7-plan step 6, "Audit").
		d, ok := member.(^Decl)
		if !ok {
			errorf(k.c, item_span(member), "L0622", "a foreign block holds procedure and variable declarations only")
			continue
		}
		if literal := decl_proc_literal(d); literal != nil {
			// A bodiless proc: resolve the signature (its foreign convention makes
			// `resolve_proc_signature` run the ABI-safety check from step 3).
			resolve_declaration_signature(k, d)
			if !literal.bodiless {
				errorf(k.c, literal.span, "L0623", "a foreign procedure has no Loke body; end its declaration with `---`")
			}
		} else {
			resolve_foreign_global(k, d)
		}
		for sid in d.symbols {
			sym := symbol_of(k.c, sid)
			if sym == nil {
				continue
			}
			if sym.generic {
				errorf(k.c, d.span, "L0624", "a generic declaration has no ABI and cannot appear in a foreign block")
			}
			if block_requires && sym.kind == .Proc {
				sym.require_results = true
			}
			if name, has := attribute_string_value(k.c, d.attributes, "link_name"); has {
				sym.link_name = name
			} else {
				sym.link_name = identifier_text(k.c, sym.name)
			}
		}
	}
}

// A foreign global is a bare `x: T;`: it names an external variable, so it has a
// written type, no initializer, and an ABI-safe representation.
@(private = "file")
resolve_foreign_global :: proc(k: ^Checker, d: ^Decl) {
	if len(d.values) > 0 && d.values[0] != nil {
		errorf(k.c, d.span, "L0625", "a foreign global is declared without an initializer")
		return
	}
	if d.declared_type == nil {
		errorf(k.c, d.span, "L0625", "a foreign global needs a written type: `name: T;`")
		return
	}
	type := resolve_type_syntax(k, d.declared_type)
	if type == INVALID_TYPE {
		return
	}
	if ok, reason := foreign_abi_safe(k.c, type); !ok {
		errorf(k.c, d.span, "L0619", "a foreign global is not ABI-safe: %s", reason)
	}
	for sid in d.symbols {
		if sym := symbol_of(k.c, sid); sym != nil {
			sym.type = type
		}
	}
}

// design.md "`@(c_vararg)`": the C-variadic marker is valid only on the final
// parameter of a foreign declaration, written `..any_view`. The parameter
// never becomes a real slice; the call site passes the concrete arguments
// (m7-plan step 4).
check_c_vararg_param :: proc(k: ^Checker, is_foreign: bool, literal: ^Expr_Proc, position: int, parameter: Parameter) {
	if !is_foreign {
		errorf(k.c, parameter.span, "L0627", "`@(c_vararg)` is only allowed on a foreign procedure parameter")
		return
	}
	if parameter.mode != .Variadic {
		errorf(k.c, parameter.span, "L0627", "`@(c_vararg)` marks a variadic parameter: `@(c_vararg) args: ..any_view`")
		return
	}
	if position != len(literal.signature.params) - 1 {
		errorf(k.c, parameter.span, "L0627", "`@(c_vararg)` must mark the final parameter")
	}
}

// The string value of a named attribute in a list, decoded from its literal.
attribute_string_value :: proc(c: ^Compiler, attributes: []Attribute, name: string) -> (string, bool) {
	for attribute in attributes {
		if len(attribute.path) != 1 || attribute.path[0].text != name {
			continue
		}
		if lit, ok := attribute.value.(^Expr_Literal); ok && (lit.kind == .String || lit.kind == .Raw_String) {
			if text, decoded := decode_string_literal(c, lit.text, lit.kind == .Raw_String); decoded {
				return text, true
			}
		}
	}
	return "", false
}
