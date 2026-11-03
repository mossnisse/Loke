// design.md "Foreign system": `foreign import` and `foreign <lib> { ... }`
// blocks. Members are ordinary package symbols marked foreign.
package lokec

import "core:strings"

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
			if !own_visibility && block_sets_visibility && sym.kind != .Var {
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
			if !foreign_links_agree(first, sym) {
				errorf(c, sym.span, "L0600", "the foreign symbol `%s` is already declared with a different type", sym.link_name)
				add_notef(c, first.span, "`%s` is first declared here", sym.link_name)
			}
		}
	}
}

// Two declarations of one external symbol share one LLVM declaration.
foreign_links_agree :: proc(a, b: ^Symbol) -> bool {
	return a.kind == b.kind && a.proc_type == b.proc_type && a.type == b.type
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

// design.md "`@(c_vararg)`": only the final parameter of a foreign
// declaration, written `..` with no type.
check_c_vararg_param :: proc(k: ^Checker, is_foreign: bool, literal: ^Expr_Proc, position: int, parameter: Parameter) {
	if !is_foreign {
		errorf(k.c, parameter.span, "L0627", "`@(c_vararg)` is only allowed on a foreign procedure parameter")
		return
	}
	if parameter.mode != .Variadic || parameter.type != nil {
		errorf(
			k.c, parameter.span, "L0627",
			"`@(c_vararg)` marks a C variadic parameter, which has no Loke type: `@(c_vararg) args: ..`",
		)
		return
	}
	if position != len(literal.signature.params) - 1 {
		errorf(k.c, parameter.span, "L0627", "`@(c_vararg)` must mark the final parameter")
	}
}

// design.md "@(export)": a whole-program pass, so clashing external symbols are
// reported with locations rather than failing at link time. `defines_entry` says
// the build writes the startup entry, whose name no export can then take.
check_exports :: proc(c: ^Compiler, defines_entry: bool) {
	claimed := make(map[string]Symbol_Id, 16, context.temp_allocator)
	linked := make(map[string]Symbol_Id, 16, context.temp_allocator)
	for id in package_order(c) {
		pkg := package_of(c, id)
		if pkg == nil {
			continue
		}
		for file in pkg.files {
			for item in file.active_items {
				#partial switch v in item {
				case ^Decl:
					check_export_decl(c, v, &claimed)
				case ^Item_Impl:
					for member in v.members {
						if d, ok := member.(^Decl); ok {
							check_export_decl(c, d, &claimed)
						}
					}
				case ^Item_Foreign_Block:
					check_foreign_links(c, v, &linked)
				}
			}
		}
	}
	if entry, taken := claimed["wmain"]; taken && defines_entry {
		errorf(c, symbol_of(c, entry).span, "L0635", "an exported symbol cannot use `wmain`, this build's startup entry")
	}
	// A foreign binding of an exported name links to that definition.
	for name, bound_id in linked {
		defined_id, seen := claimed[name]
		if !seen {
			continue
		}
		bound := symbol_of(c, bound_id)
		defined := symbol_of(c, defined_id)
		if !foreign_links_agree(bound, defined) {
			errorf(c, bound.span, "L0600", "the foreign symbol `%s` is exported with a different type", name)
			add_notef(c, defined.span, "`%s` is exported here", name)
		}
	}
}

@(private = "file")
check_export_decl :: proc(c: ^Compiler, d: ^Decl, claimed: ^map[string]Symbol_Id) {
	if !has_attribute(d.attributes, "export") {
		return
	}
	// A member of a generic `impl` has symbols only in its instances.
	if len(d.symbols) == 0 {
		errorf(c, d.span, "L0438", "a member of a generic `impl` has no ABI until it is instantiated, so it cannot be `@(export)`")
		return
	}
	for sid in d.symbols {
		sym := symbol_of(c, sid)
		if sym == nil {
			continue
		}
		name := link_name_of(c, d, sym)
		if strings.has_prefix(name, "loke_rt_") {
			errorf(c, sym.span, "L0635", "an exported symbol cannot use the reserved `loke_rt_` runtime prefix: `%s`", name)
			continue
		}
		// Already L0438.
		if sym.generic {
			continue
		}
		#partial switch sym.kind {
		case .Proc:
			info := type_of(c, sym.proc_type)
			if info == nil || !convention_is_foreign(info.convention) {
				errorf(c, sym.span, "L0629", "an exported procedure must use a foreign calling convention: `proc \"c\" (...)`")
				continue
			}
		case .Var:
			if ok, reason := foreign_abi_safe(c, sym.type); !ok {
				errorf(c, sym.span, "L0619", "an exported global is not ABI-safe: %s", reason)
				continue
			}
		case:
			continue // export on anything else is a misplaced-attribute error already
		}
		if first, seen := claimed[name]; seen {
			errorf(c, sym.span, "L0634", "two declarations export the symbol `%s`", name)
			add_notef(c, symbol_of(c, first).span, "`%s` is also exported here", name)
			continue
		}
		claimed[name] = sid
		sym.exported = true
		sym.link_name = name
	}
}
