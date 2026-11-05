// LLVM symbol names: the naming pass, mangling, escaping, and linkage.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// design.md "@(export)": only exports need linker-visible names; `internal`
// lets LLVM drop everything else once inlined. `llvm_external_name` never spells
// a link name with this prefix, so the prefix means a generated name.
@(private)
llvm_linkage :: proc(name: string) -> string {
	return strings.has_prefix(name, "@loke.") ? "internal " : ""
}

// Every symbol is named before any body, so an unnamed one is a contract break,
// unless it was omitted with its test: a witness or a format thunk on a test's
// local type is still written, for a value no surviving code can make. "null"
// keeps the text well formed.
symbol_name :: proc(e: ^Emitter, id: Symbol_Id) -> string {
	if name, named := e.names[id]; named {
		return name
	}
	if !omitted_with_test(e.c, id) {
		backend_fail(e, "a resolved operation has no emitted name")
	}
	return "null"
}

@(private)
name_package_symbols :: proc(e: ^Emitter, pkg: ^Package) {
	for file in pkg.files {
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				for symbol_id in v.symbols {
					if sym := symbol_of(e.c, symbol_id); sym != nil && sym.kind == .Var && !sym.is_foreign {
						e.names[symbol_id] = sym.exported \
							? llvm_external_name(sym.link_name) \
							: claim_name(e, llvm_global_name(pkg, identifier_text(e.c, sym.name)))
					}
				}
				// Only a template's instances are named and emitted.
				if decl_proc_literal(v) != nil && len(v.symbols) > 0 && !symbol_is_template(e.c, v.symbols[0]) {
					if sym := symbol_of(e.c, v.symbols[0]); sym != nil && sym.exported {
						e.names[v.symbols[0]] = llvm_external_name(sym.link_name)
					} else {
						e.names[v.symbols[0]] = claim_name(e, llvm_proc_name(pkg, v.names[0].text))
					}
				}
			case ^Item_Impl:
				for member in v.members {
					d, is_decl := member.(^Decl)
					if !is_decl || decl_proc_literal(d) == nil || len(d.symbols) == 0 {
						continue
					}
					sym := symbol_of(e.c, d.symbols[0])
					if sym == nil {
						continue
					}
					e.names[d.symbols[0]] = sym.exported \
						? llvm_external_name(sym.link_name) \
						: claim_name(e, llvm_proc_name(pkg, qualified_member_name(e, sym)))
				}
			case ^Item_Foreign_Block:
				// design.md "Foreign system": foreign members keep their link names.
				for d in v.members {
					for sid in d.symbols {
						if sym := symbol_of(e.c, sid); sym != nil && sym.is_foreign {
							e.names[sid] = foreign_llvm_name(sym)
							append(&e.foreign_symbols, sid)
						}
					}
				}
			}
		}
	}
	for literal, index in pkg.hoisted_procs {
		if omitted_with_test(e.c, literal.symbol) {
			continue
		}
		// The index keeps two bodies' same-named local procedures apart.
		written := "lambda"
		if sym := symbol_of(e.c, literal.symbol); sym != nil && sym.decl != nil {
			written = llvm_safe(identifier_text(e.c, sym.name))
		}
		e.names[literal.symbol] = claim_name(e, llvm_proc_name(pkg, fmt.aprintf("%s.%d", written, index)))
	}
	for instance in pkg.instances {
		if omitted_with_test(e.c, instance.symbol) {
			continue
		}
		spelled: string
		if instance.template == INVALID_SYMBOL {
			spelled = qualified_member_name(e, symbol_of(e.c, instance.symbol))
		} else {
			spelled = instance_spelling(e, instance.template, instance.args)
		}
		e.names[instance.symbol] = claim_name(e, llvm_proc_name(pkg, spelled))
	}
}

// `base`, or the first free `base.<n>`. Spellings alone collide: `f(alpha.Item)`
// and `f(beta.Item)` read alike, and an impl member spells its owner unqualified.
@(private)
claim_name :: proc(e: ^Emitter, base: string) -> string {
	name := base
	for n := 1; e.taken_names[name]; n += 1 {
		name = fmt.aprintf("%s.%d", base, n)
	}
	e.taken_names[name] = true
	return name
}

// design.md "@(export)": a name the compiler generates under one spelling at each
// use, such as one thunk per type, claimed at its first use, so that it too stays
// clear of a link name.
@(private)
generated_name :: proc(e: ^Emitter, base: string) -> string {
	if name, claimed := e.generated_names[base]; claimed {
		return name
	}
	name := claim_name(e, base)
	e.generated_names[base] = name
	return name
}

// A claimed name stays clear of every link name the program gives, exported or
// foreign, which may spell `loke.` too. Quoted or not, LLVM reads one symbol, so
// these go in as the bytes a claim would spell.
@(private)
reserve_link_names :: proc(e: ^Emitter) {
	for sym in e.c.symbols {
		if sym != nil && sym.link_name != "" {
			e.taken_names[strings.concatenate({"@", sym.link_name})] = true
		}
	}
}

// Compiler-contributed members belong to no package.
@(private)
name_synth_procs :: proc(e: ^Emitter) {
	for symbol_id in e.c.synth_procs {
		symbol := symbol_of(e.c, symbol_id)
		if symbol == nil {
			continue
		}
		e.names[symbol_id] = claim_name(e, fmt.aprintf("@loke.i.%s", qualified_member_name(e, symbol)))
	}
}

// Spelled from names rather than ids, which shift on unrelated changes. Two
// packages may both have a `Shape`, so the spelling is only a base.
@(private)
name_witnesses :: proc(e: ^Emitter) {
	for witness in e.c.witness_order {
		b := strings.builder_make()
		interface_name := "interface"
		if sym := symbol_of(e.c, witness.interface_symbol); sym != nil {
			interface_name = identifier_text(e.c, sym.name)
		}
		fmt.sbprintf(&b, "@loke.w.%s.%s", llvm_safe(interface_name), llvm_safe(type_name(e.c, witness.concrete)))
		for arg in witness.args {
			part := arg.is_type ? type_name(e.c, arg.type) : fmt.aprintf("v%s:%s", type_name(e.c, arg.value_type), const_key_text(e.c, arg.value))
			fmt.sbprintf(&b, ".%s", llvm_safe(part, dots = false))
		}
		e.witness_names[witness] = claim_name(e, strings.to_string(b))
	}
}

// A type's backend spelling, escaped, or "" for one known only by its name. An
// instance is spelled from its template and arguments, a compiler-made type
// from the label the checker gave it.
@(private)
type_spelling :: proc(e: ^Emitter, type: Type_Id) -> string {
	info := type_of(e.c, type)
	if info == nil {
		return ""
	}
	if info.instance_of != INVALID_SYMBOL {
		return instance_spelling(e, info.instance_of, info.instance_args)
	}
	return llvm_safe(info.backend_label)
}

// `Table.int.i32`, escaped. Each argument is escaped on its own, so distinct
// vectors stay distinct.
@(private = "file")
instance_spelling :: proc(e: ^Emitter, template: Symbol_Id, args: []Generic_Arg) -> string {
	b := strings.builder_make()
	if sym := symbol_of(e.c, template); sym != nil {
		// `Atomic(int).load` and `Atomic(bool).load` are two templates named `load`.
		if sym.owner_type != INVALID_TYPE {
			strings.write_string(&b, qualified_member_name(e, sym))
		} else {
			strings.write_string(&b, llvm_safe(identifier_text(e.c, sym.name)))
		}
	}
	for arg in args {
		part := arg.is_type ? type_name(e.c, arg.type) : const_key_text(e.c, arg.value)
		fmt.sbprintf(&b, ".%s", llvm_safe(part, dots = false))
	}
	return strings.to_string(b)
}

// The backend name of a method, escaped: `Pair.int.member` for an instantiation's.
@(private = "file")
qualified_member_name :: proc(e: ^Emitter, sym: ^Symbol) -> string {
	owner := type_spelling(e, sym.owner_type)
	if owner == "" {
		owner = llvm_safe(type_name(e.c, sym.owner_type))
	}
	return fmt.aprintf("%s.%s", owner, llvm_safe(identifier_text(e.c, sym.name)))
}

@(private)
symbol_is_template :: proc(c: ^Compiler, symbol_id: Symbol_Id) -> bool {
	sym := symbol_of(c, symbol_id)
	if sym == nil {
		return false
	}
	if sym.generic {
		return true
	}
	// An unused generic's signature may never have been checked, so fall back to
	// its syntax; instances keep that syntax but have `instance_of`.
	return sym.instance_of == INVALID_SYMBOL && declaration_generic_kind(sym.decl) != .None
}

// The internal name of the body behind `emit_entry_guard`'s function
// `llvm_name`. A quoted export name, such as a decorated C++ one, lends it no
// spelling.
@(private)
entry_body_name :: proc(e: ^Emitter, llvm_name: string) -> string {
	plain := llvm_plain_name(llvm_name[1:])
	return claim_name(e, plain ? strings.concatenate({"@loke.entry.", llvm_name[1:]}) : "@loke.entry")
}

// Names carry the package's key; the root package's is empty.
@(private = "file")
llvm_global_name :: proc(pkg: ^Package, name: string) -> string {
	return fmt.aprintf("@loke.g.%s%s", mangled_key(pkg), name)
}

@(private = "file")
llvm_proc_name :: proc(pkg: ^Package, name: string) -> string {
	return fmt.aprintf("@loke.p.%s%s", mangled_key(pkg), name)
}

// Whether `name` needs no escaping.
@(private)
llvm_plain_name :: proc(name: string) -> bool {
	for i in 0 ..< len(name) {
		if !llvm_name_byte(name[i]) {
			return false
		}
	}
	return len(name) > 0
}

@(private = "file")
llvm_name_byte :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
		ch == '_' || ch == '.'
}

// Escapes every byte LLVM would need quoted, `$` included, as `$XX`: injective
// and still readable. `dots = false` also escapes `.`, for a part that a `.`
// joins to others.
llvm_safe :: proc(name: string, dots := true) -> string {
	hex := "0123456789abcdef"
	out := make([dynamic]u8, 0, len(name) + 8)
	for i in 0 ..< len(name) {
		ch := name[i]
		if llvm_name_byte(ch) && (dots || ch != '.') {
			append(&out, ch)
			continue
		}
		append(&out, '$', hex[ch >> 4], hex[ch & 0x0f])
	}
	return string(out[:])
}

// The key's own dots are escaped: `util.v2` + `f` must not meet `util` + `v2.f`.
@(private = "file")
mangled_key :: proc(pkg: ^Package) -> string {
	if pkg.key == "" {
		return ""
	}
	return fmt.aprintf("%s.", llvm_safe(pkg.key, dots = false))
}
