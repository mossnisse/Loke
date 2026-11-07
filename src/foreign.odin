// design.md "Foreign system": `foreign <lib> { ... }` blocks. Members are
// ordinary package symbols marked foreign.
package lokec

import "core:path/filepath"
import "core:strings"

// design.md "`@(default_calling_convention=<string>)`".
@(private = "file")
foreign_default_convention :: proc(k: ^Checker, block: ^Item_Foreign_Block) -> string {
	if attribute, written := find_attribute(block.attributes, "default_calling_convention"); written {
		if convention, is_string := attribute_string_text(k.c, attribute); is_string {
			if convention_is_foreign(convention) {
				return convention
			}
			report_unknown_convention(k, convention, attribute.span)
		}
	}
	return "c"
}

// Runs in `prepare_package`. The block supplies visibility and convention
// defaults; a member's own attribute or written convention wins.
declare_foreign_block :: proc(k: ^Checker, block: ^Item_Foreign_Block) {
	if block.declared {
		return
	}
	block.declared = true
	convention := foreign_default_convention(k, block)
	block_default := attributes_are_public(k, block.attributes, block.span, "foreign block")

	for d in block.members {
		declare_all(k, d, top_level = true)
		if literal := decl_proc_literal(d); literal != nil && literal.signature.convention == "" {
			literal.signature.convention = convention
		}
		for sid in d.symbols {
			sym := symbol_of(k.c, sid)
			if sym == nil {
				continue
			}
			sym.is_foreign = true
			if sym.kind != .Var {
				sym.public = written_is_public(d.attributes, nil, block_default)
			}
		}
	}
}

// Runs in `check_package_bodies`, among the signatures.
check_foreign_block :: proc(k: ^Checker, block: ^Item_Foreign_Block) {
	block_requires := has_attribute(block.attributes, "require_results")
	for d in block.members {
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

link_name_of :: proc(c: ^Compiler, d: ^Decl, sym: ^Symbol) -> string {
	// An empty name is already L0608.
	if name, has := attribute_string_value(c, d.attributes, "link_name"); has && name != "" {
		return name
	}
	return identifier_text(c, sym.name)
}

// Members sharing a link name share one LLVM declaration, so they must agree on
// kind and type.
check_foreign_links :: proc(c: ^Compiler, block: ^Item_Foreign_Block, linked: ^map[string]Symbol_Id) {
	for d in block.members {
		for sid in d.symbols {
			sym := symbol_of(c, sid)
			if sym == nil {
				continue
			}
			first_id, seen := linked[sym.link_name]
			if !seen {
				linked[sym.link_name] = sid
				continue
			}
			first := symbol_of(c, first_id)
			if !foreign_links_agree(c, first, sym) {
				errorf(c, sym.span, "L0600", "the foreign symbol `%s` is already declared with a different type", sym.link_name)
				add_notef(c, first.span, "`%s` is first declared here", sym.link_name)
			}
		}
	}
}

// design.md "`@(export)`": same kind and type.
foreign_links_agree :: proc(c: ^Compiler, a, b: ^Symbol) -> bool {
	return a.kind == b.kind && erase_proc_contract(c, a.proc_type) == erase_proc_contract(c, b.proc_type) && a.type == b.type
}

// design.md "Foreign system": a path names a library or a file. An empty one
// names neither, and a block needs no import to name what the link already has.
check_foreign_import :: proc(k: ^Checker, imp: ^Item_Foreign_Import) {
	if !imp.path_written {
		return
	}
	if library, is_system := system_library_name(imp.path); is_system {
		if library == "" {
			errorf(k.c, imp.span, "L0756", "`%s` names no system library; write its name, as `system:kernel32.lib`", imp.path)
		}
		return
	}
	if imp.path == "" {
		errorf(k.c, imp.span, "L0756", "a foreign import's path is empty; name a library, as `system:kernel32.lib`, or a file")
		add_notef(
			k.c, NO_SPAN,
			"a foreign block needs no foreign import when the program's other inputs already define what it declares",
		)
	}
}

// design.md "Foreign system": the library a `system:` path names, without the
// optional `.lib` or `.a` suffix.
system_library_name :: proc(path: string) -> (library: string, is_system: bool) {
	if !strings.has_prefix(path, "system:") {
		return "", false
	}
	library = path[len("system:"):]
	extension := filepath.ext(library)
	if strings.equal_fold(extension, ".lib") || strings.equal_fold(extension, ".a") {
		library = library[:len(library) - len(extension)]
	}
	return library, true
}

// A foreign global is a bare `x: T;` with an ABI-safe type.
@(private = "file")
resolve_foreign_global :: proc(k: ^Checker, d: ^Decl) {
	if d.has_error {
		return
	}
	if d.kind != .Var {
		errorf(k.c, d.span, "L0625", "a foreign block declares only `---` procedures and `x: T;` variables")
		return
	}
	if len(d.values) > 0 {
		errorf(k.c, d.span, "L0625", "a foreign global is declared without an initializer")
		return
	}
	type := resolve_type_reporting(k, d.declared_type)
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

// design.md "`@(c_vararg)`".
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
	if position != len(literal.signature.params) - 1 || len(parameter.names) > 1 {
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
		for file in package_of(c, id).files {
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
		if !foreign_links_agree(c, bound, defined) {
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
