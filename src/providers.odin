// Build-selected providers (design.md "Build-selected providers", m8-plan
// step 3).
//
// The final build selects at most one default-allocator provider and one
// logging provider, on the command line and nowhere else. Each selection names
// a *factory*: a public, non-generic procedure taking nothing and returning the
// slot's handle type. Naming one makes its package a build dependency even
// where no source imports it, which is the whole point — a program should not
// have to mention the provider it runs on.
//
// Nothing here changes what an unselected build does. The runtime's fallback
// record is still the answer `mem.default_allocator()` gives; what changes is
// that the answer now arrives through an accessor the initializer can move.
package lokec

import "core:strings"

Provider_Slot :: enum {
	Allocator,
	Logger,
}

Provider_Selection :: struct {
	// The written `path:name`, kept verbatim for diagnostics.
	written:  string,
	path:     string,
	name:     string,
	selected: bool,
	pkg:      Package_Id,
	factory:  Symbol_Id,
}

provider_slot_name :: proc(slot: Provider_Slot) -> string {
	switch slot {
	case .Allocator: return "allocator"
	case .Logger:    return "logger"
	}
	return "?"
}

// Does this build select anything at all? An unselected build emits no
// initializer and keeps M7's startup exactly.
any_provider_selected :: proc(c: ^Compiler) -> bool {
	for slot in Provider_Slot {
		if c.providers[slot].selected {
			return true
		}
	}
	return false
}

// `-provider <slot>=<import path>:<name>`. Parsed before any source is loaded,
// so a malformed selection is reported without compiling anything.
select_provider :: proc(c: ^Compiler, entry: string) -> bool {
	equals := strings.index_byte(entry, '=')
	if equals <= 0 {
		errorf(c, no_span(), "L0656", "`-provider %s` needs the form <slot>=<package>:<name>", entry)
		return false
	}
	slot_text := entry[:equals]
	target := entry[equals + 1:]
	slot := Provider_Slot.Allocator
	switch slot_text {
	case "allocator": slot = .Allocator
	case "logger":    slot = .Logger
	case:
		errorf(c, no_span(), "L0656", "`%s` is not a provider slot; use `allocator` or `logger`", slot_text)
		return false
	}
	// The *last* colon separates the declaration from the import path, because an
	// import path contains one of its own: `core:log:standard_logger`.
	split := strings.last_index_byte(target, ':')
	if split <= 0 || split == len(target) - 1 {
		errorf(
			c, no_span(), "L0656",
			"`-provider %s` needs the form <slot>=<package>:<name>", entry,
		)
		return false
	}
	if c.providers[slot].selected {
		errorf(
			c, no_span(), "L0657",
			"the %s provider is selected twice: `%s` and `%s`",
			provider_slot_name(slot), c.providers[slot].written, target,
		)
		return false
	}
	// The argument vector lives for the process, so these are borrows of it
	// rather than copies.
	c.providers[slot] = Provider_Selection {
		written  = target,
		path     = target[:split],
		name     = target[split + 1:],
		selected = true,
		pkg      = INVALID_PACKAGE,
		factory  = INVALID_SYMBOL,
	}
	return true
}

// A selected provider's package is a build dependency whether or not anything
// imports it, so it is loaded beside the root before discovery begins.
load_provider_packages :: proc(c: ^Compiler) {
	for slot in Provider_Slot {
		selection := &c.providers[slot]
		if !selection.selected {
			continue
		}
		// A relative import path resolves against the importing *file*, and a
		// selection has none — it comes from the command line. So a provider is
		// named through a collection, always.
		dir, key, resolved := "", "", false
		if strings.index_byte(selection.path, ':') > 0 {
			dir, key, resolved = resolve_import_path(c, nil, selection.path)
		}
		if !resolved {
			errorf(
				c, no_span(), "L0658",
				"the %s provider's package `%s` does not name a registered collection",
				provider_slot_name(slot), selection.path,
			)
			continue
		}
		id, loaded := load_package_dir(c, dir, key, no_span())
		if !loaded {
			continue
		}
		selection.pkg = id
	}
}

// Resolves each selection to one factory symbol and checks its shape. Run once
// the whole program is checked, so a factory declared in a `when` branch has
// been selected and its signature resolved.
resolve_provider_factories :: proc(k: ^Checker) {
	c := k.c
	for slot in Provider_Slot {
		selection := &c.providers[slot]
		if !selection.selected || selection.pkg == INVALID_PACKAGE {
			continue
		}
		wanted := provider_handle_type(k, slot)
		pkg := package_of(c, selection.pkg)
		symbol_id := INVALID_SYMBOL
		if pkg != nil && pkg.scope != nil {
			symbol_id = pkg.scope.names[intern_identifier(c, selection.name)] or_else INVALID_SYMBOL
		}
		sym := symbol_of(c, symbol_id)
		if sym == nil || !sym.public {
			errorf(
				c, no_span(), "L0658",
				"the %s provider `%s` names no public declaration in `%s`",
				provider_slot_name(slot), selection.name, selection.path,
			)
			continue
		}
		resolve_symbol_signature_in_place(k, symbol_id)
		sym = symbol_of(c, symbol_id)
		if !provider_factory_shape(c, sym, wanted) {
			errorf(
				c, no_span(), "L0659",
				"the %s provider `%s` is not a factory: it must be `proc() -> %s`",
				provider_slot_name(slot), selection.written,
				wanted == INVALID_TYPE ? "the slot's handle" : type_name(c, wanted),
			)
			continue
		}
		selection.factory = symbol_id
	}
}

@(private = "file")
provider_factory_shape :: proc(c: ^Compiler, sym: ^Symbol, wanted: Type_Id) -> bool {
	if sym.kind != .Proc || sym.generic || sym.has_receiver || sym.is_foreign {
		return false
	}
	if len(sym.params) != 0 || sym.result_inout {
		return false
	}
	return wanted != INVALID_TYPE && sym.result == wanted
}

// The handle a slot's factory returns: the universe's `Allocator`, and
// `core:log`'s own `Logger`. The second is looked up by name rather than owned
// by the compiler, because a logger is an ordinary library service handle with
// no compiler-known behavior at all.
@(private = "file")
provider_handle_type :: proc(k: ^Checker, slot: Provider_Slot) -> Type_Id {
	if slot == .Allocator {
		return TYPE_ALLOCATOR
	}
	for index in 1 ..< len(k.c.packages) {
		pkg := &k.c.packages[index]
		if pkg.key != STD_LOG || pkg.scope == nil {
			continue
		}
		symbol_id := pkg.scope.names[intern_identifier(k.c, "Logger")] or_else INVALID_SYMBOL
		if sym := symbol_of(k.c, symbol_id); sym != nil && sym.kind == .Type {
			resolve_symbol_signature_in_place(k, symbol_id)
			return symbol_of(k.c, symbol_id).type
		}
	}
	errorf(
		k.c, no_span(), "L0660",
		"selecting a logging provider needs `%s` in the build, which declares `Logger`",
		STD_LOG,
	)
	return INVALID_TYPE
}

// Where the generated initializer publishes the logger: `core:log`'s own
// file-scope handle. The library reads it on every call and falls back to the
// standard sink while it is the zero value, so nothing here has to run for an
// unselected build.
log_current_logger_symbol :: proc(c: ^Compiler) -> Symbol_Id {
	for index in 1 ..< len(c.packages) {
		pkg := &c.packages[index]
		if pkg.key != STD_LOG || pkg.scope == nil {
			continue
		}
		return pkg.scope.names[intern_identifier(c, "selected")] or_else INVALID_SYMBOL
	}
	return INVALID_SYMBOL
}
