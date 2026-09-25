// Source-selected allocator and logger providers.
package lokec

import "core:strings"

Provider_Slot :: enum {
	Allocator,
	Logger,
}

Provider_Selection :: struct {
	written:     string,
	path:        string,
	name:        string,
	selected:    bool,
	from_file:   ^File,
	span:        Span,
	pkg:         Package_Id,
	factory:     Symbol_Id,
	destination: Symbol_Id,
}

provider_slot_name :: proc(slot: Provider_Slot) -> string {
	switch slot {
	case .Allocator: return "allocator"
	case .Logger:    return "logger"
	}
	return "?"
}

any_provider_selected :: proc(c: ^Compiler) -> bool {
	for slot in Provider_Slot {
		if c.providers[slot].selected {
			return true
		}
	}
	return false
}

// Reads provider attributes from the root package before import discovery.
collect_source_provider_defaults :: proc(c: ^Compiler, root: Package_Id) {
	pkg := package_of(c, root)
	if pkg == nil {
		return
	}
	seen: [Provider_Slot]bool
	first_span: [Provider_Slot]Span
	for file in pkg.files {
		seen_in_file: [Provider_Slot]bool
		for attribute in file.attributes {
			slot, is_provider := source_provider_slot(attribute)
			if !is_provider {
				continue
			}
			if seen_in_file[slot] {
				continue // `validate_attribute_list` owns this diagnostic.
			}
			seen_in_file[slot] = true
			target, valid := source_provider_target(c, attribute)
			if !valid {
				continue // Attribute shape validation owns malformed values.
			}
			if seen[slot] {
				errorf(
					c, attribute.span, "L0657",
					"the source default for the %s provider is selected more than once",
					provider_slot_name(slot),
				)
				add_notef(c, first_span[slot], "the first source default is here")
				continue
			}
			seen[slot], first_span[slot] = true, attribute.span
			install_provider_selection(c, slot, target, attribute.span, file)
		}
	}
}

source_provider_slot :: proc(attribute: Attribute) -> (Provider_Slot, bool) {
	if len(attribute.path) != 1 {
		return .Allocator, false
	}
	switch attribute.path[0].text {
	case "default_allocator": return .Allocator, true
	case "default_logger":    return .Logger, true
	}
	return .Allocator, false
}

@(private = "file")
source_provider_target :: proc(c: ^Compiler, attribute: Attribute) -> (string, bool) {
	lit, ok := attribute.value.(^Expr_Literal)
	if !ok || (lit.kind != .String && lit.kind != .Raw_String) {
		return "", false
	}
	return decode_string_literal(c, lit.text, lit.kind == .Raw_String)
}

@(private = "file")
install_provider_selection :: proc(
	c: ^Compiler,
	slot: Provider_Slot,
	target: string,
	span: Span,
	from_file: ^File,
) {
	// Import paths may contain a colon, so the declaration follows the last one.
	split := strings.last_index_byte(target, ':')
	if split <= 0 || split == len(target) - 1 {
		errorf(
			c, span, "L0656",
			"the %s provider `%s` needs the form <package>:<name>",
			provider_slot_name(slot), target,
		)
		return
	}
	c.providers[slot] = Provider_Selection {
		written     = target,
		path        = target[:split],
		name        = target[split + 1:],
		selected    = true,
		from_file   = from_file,
		span        = span,
		pkg         = INVALID_PACKAGE,
		factory     = INVALID_SYMBOL,
		destination = INVALID_SYMBOL,
	}
}

// Selected provider packages are build dependencies even without imports.
load_provider_packages :: proc(c: ^Compiler) {
	for slot in Provider_Slot {
		selection := &c.providers[slot]
		if !selection.selected {
			continue
		}
		// Match the resolution base of an import in the package-clause file.
		dir, why := resolve_import_path(c, selection.from_file, selection.path)
		switch why {
		case .No_Collection:
			errorf(
				c, selection.span, "L0658",
				"the %s provider's package `%s` does not name a registered collection",
				provider_slot_name(slot), selection.path,
			)
			continue
		case .Outside_Collection:
			errorf(
				c, selection.span, "L0658",
				"the %s provider's package `%s` leaves the `%s` collection",
				provider_slot_name(slot), selection.path, collection_prefix(selection.path),
			)
			continue
		case .Ok:
		}
		id, loaded := load_package_dir(c, dir, selection.path, selection.span)
		if !loaded {
			continue
		}
		selection.pkg = id
	}
}

// Runs after checking so conditional factory declarations have been selected.
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
				c, selection.span, "L0658",
				"the %s provider `%s` names no public declaration in `%s`",
				provider_slot_name(slot), selection.name, selection.path,
			)
			continue
		}
		resolve_symbol_signature_in_place(k, symbol_id)
		sym = symbol_of(c, symbol_id)
		if !provider_factory_shape(c, sym, wanted) {
			errorf(
				c, selection.span, "L0659",
				"the %s provider `%s` is not a factory: it must be `proc() -> %s`",
				provider_slot_name(slot), selection.written,
				wanted == INVALID_TYPE ? "the slot's handle" : type_name(c, wanted),
			)
			continue
		}
		selection.factory = symbol_id
		if slot == .Logger {
			selection.destination = provider_logger_destination(k, wanted, selection.span)
		}
	}
}

@(private = "file")
provider_factory_shape :: proc(c: ^Compiler, sym: ^Symbol, wanted: Type_Id) -> bool {
	if sym.kind != .Proc || sym.generic || sym.has_receiver || sym.is_foreign {
		return false
	}
	info := type_of(c, sym.proc_type)
	if info == nil || info.convention != "" {
		return false
	}
	if len(sym.params) != 0 || sym.result_inout {
		return false
	}
	return wanted != INVALID_TYPE && sym.result == wanted
}

// Logger remains an ordinary library type rather than a compiler-owned type.
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
		if logger, found := package_type_named(k, pkg, "Logger"); found {
			return logger
		}
	}
	errorf(
		k.c, no_span(), "L0660",
		"selecting a logging provider needs `%s` in the build, which declares `Logger`",
		STD_LOG,
	)
	return INVALID_TYPE
}

@(private = "file")
provider_logger_destination :: proc(k: ^Checker, wanted: Type_Id, span: Span) -> Symbol_Id {
	for index in 1 ..< len(k.c.packages) {
		pkg := &k.c.packages[index]
		if pkg.key != STD_LOG || pkg.scope == nil {
			continue
		}
		symbol_id := pkg.scope.names[intern_identifier(k.c, "selected")] or_else INVALID_SYMBOL
		resolve_symbol_signature_in_place(k, symbol_id)
		sym := symbol_of(k.c, symbol_id)
		if sym != nil && sym.kind == .Var && !sym.immutable && sym.type == wanted {
			return symbol_id
		}
		break
	}
	errorf(
		k.c, span, "L0660",
		"selecting a logging provider needs `%s.selected` to be a writable global of type `%s`",
		STD_LOG, type_name(k.c, wanted),
	)
	return INVALID_SYMBOL
}
