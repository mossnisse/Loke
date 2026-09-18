// design.md "Foreign system": `foreign import` and `foreign <lib> { ... }`
// blocks. Members are ordinary package symbols marked foreign.
package lokec

foreign_default_convention :: proc(k: ^Checker, block: ^Item_Foreign_Block) -> string {
	if value, ok := attribute_string_value(k.c, block.attributes, "default_calling_convention"); ok {
		return value
	}
	return "c"
}

// Runs in `prepare_package`. The block supplies visibility and convention
// defaults; a member's own attribute or written convention wins.
declare_foreign_block :: proc(k: ^Checker, block: ^Item_Foreign_Block) {
	// Discovery re-prepares a package once per round.
	if block.declared {
		return
	}
	block.declared = true
	convention := foreign_default_convention(k, block)
	block_public, block_sets_visibility := foreign_block_visibility(k, block)

	for member in block.members {
		d, ok := member.(^Decl)
		if !ok {
			continue
		}
		declare_all(k, d, top_level = true)
		if literal := decl_proc_literal(d); literal != nil && literal.signature != nil {
			if literal.signature.convention == "" {
				literal.signature.convention = convention
			}
		}
		own_visibility := has_attribute(d.attributes, "public") || has_attribute(d.attributes, "private")
		for sid in d.symbols {
			sym := symbol_of(k.c, sid)
			if sym == nil {
				continue
			}
			sym.is_foreign = true
			if !own_visibility && block_sets_visibility {
				sym.public = block_public
			}
		}
	}
}

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

// Runs in `check_package_bodies`, after signatures.
check_foreign_block :: proc(k: ^Checker, block: ^Item_Foreign_Block) {
	block_requires := has_attribute(block.attributes, "require_results")
	for member in block.members {
		// The parser yields a `^Decl` or an already reported `^Item_Error`.
		d, ok := member.(^Decl)
		if !ok {
			continue
		}
		if literal := decl_proc_literal(d); literal != nil {
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
			sym.link_name = link_name_of(k.c, d, sym)
		}
	}
}

// A declaration's external symbol: its `@(link_name)`, else its own name.
link_name_of :: proc(c: ^Compiler, d: ^Decl, sym: ^Symbol) -> string {
	if name, has := attribute_string_value(c, d.attributes, "link_name"); has {
		return name
	}
	return identifier_text(c, sym.name)
}

// Members sharing a link name share one LLVM declaration, so they must agree on
// kind and type.
check_foreign_links :: proc(c: ^Compiler, block: ^Item_Foreign_Block, linked: ^map[string]Symbol_Id) {
	for member in block.members {
		d, ok := member.(^Decl)
		if !ok {
			continue
		}
		for sid in d.symbols {
			sym := symbol_of(c, sid)
			if sym == nil || sym.link_name == "" {
				continue
			}
			first_id, seen := linked[sym.link_name]
			if !seen {
				linked[sym.link_name] = sid
				continue
			}
			first := symbol_of(c, first_id)
			if first.kind != sym.kind || first.proc_type != sym.proc_type || first.type != sym.type {
				errorf(c, sym.span, "L0600", "the foreign symbol `%s` is already declared with a different type", sym.link_name)
				add_notef(c, first.span, "`%s` is first declared here", sym.link_name)
			}
		}
	}
}

// A foreign global is a bare `x: T;` with an ABI-safe type.
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

// design.md "`@(c_vararg)`": only the final `..any_view` parameter of a foreign
// declaration.
check_c_vararg_param :: proc(k: ^Checker, is_foreign: bool, literal: ^Expr_Proc, position: int, parameter: Parameter) {
	if !is_foreign {
		errorf(k.c, parameter.span, "L0627", "`@(c_vararg)` is only allowed on a foreign procedure parameter")
		return
	}
	type := resolve_type_syntax(k, parameter.type)
	if parameter.mode != .Variadic || (type != TYPE_ANY_VIEW && type != INVALID_TYPE) {
		errorf(k.c, parameter.span, "L0627", "`@(c_vararg)` marks a variadic parameter: `@(c_vararg) args: ..any_view`")
		return
	}
	if position != len(literal.signature.params) - 1 {
		errorf(k.c, parameter.span, "L0627", "`@(c_vararg)` must mark the final parameter")
	}
}
