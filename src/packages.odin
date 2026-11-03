// Package discovery and the program-level fixed point. Package state grows
// monotonically while imports and `when` selections settle.
package lokec

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Loads, discovers, and checks one program in dependency order.
compile_program :: proc(c: ^Compiler, input: string) -> (Package_Id, bool) {
	init_semantic_stores(c)
	// Runtime types must exist before user signatures are resolved.
	load_runtime_bootstrap(c)
	root, loaded := load_root_package(c, input)
	if !loaded {
		return INVALID_PACKAGE, false
	}
	c.root_package = root
	// Selected providers are build dependencies even without source imports.
	collect_source_provider_defaults(c, root)
	load_provider_packages(c)

	k := Checker{c = c}
	// If file-scope selection cannot add an import or a `parallel` dependency,
	// discovery needs no semantic preparation. Checking each dependency, its
	// own selection included, before its dependents gives checkpoints a boundary
	// with no references back into a later package.
	_ = discover_imports(c, &k)
	if !check_import_cycles(c) { return root, false }
	if static_package_graph(c) {
		check_static_packages(&k, package_order(c), 0)
		finish_program_analysis(&k)
		return root, c.error_count == 0
	}
	for {
		order := package_order(c)
		for id in order {
			prepare_package(&k, id)
		}
		changed := false
		for id in order {
			if activate_when_items(&k, package_of(c, id)) {
				changed = true
			}
		}
		for index in 1 ..< len(c.packages) {
			rebuild_active_items(c, c.packages[index])
		}
		if discover_imports(c, &k) {
			changed = true
		}
		if !check_import_cycles(c) {
			return root, false
		}
		if !changed {
			break
		}
	}

	// The last unchanged round left every active view current.
	for index in 1 ..< len(c.packages) {
		report_stalled_whens(&k, c.packages[index])
	}
	// Bodies wait until selections and imports are stable.
	for id in package_order(c) {
		check_package_bodies(&k, id)
		check_pending_impl_instances(&k)
	}
	finish_program_analysis(&k)
	return root, c.error_count == 0
}

// The whole-program analyses that follow checking every body. The emission
// boundary requires the completion fact this records.
finish_program_analysis :: proc(k: ^Checker) {
	analyze_program_provenance(k)
	resolve_provider_factories(k)
	release_held_diagnostics(k.c)
	k.c.program_analyzed = true
}

// ------------------------------------------------------------------ loading --

// Uses ordinary collection loading so an explicit import reuses this package.
load_runtime_bootstrap :: proc(c: ^Compiler) -> (Package_Id, bool) {
	root, registered := c.collections["base"]
	if !registered {
		return INVALID_PACKAGE, false // reported at the first import that needs it
	}
	return load_package_dir(c, strings.concatenate({root, "/runtime"}, context.temp_allocator), STD_RUNTIME, no_span())
}

// Directory roots include their direct `.loke` files; file roots stand alone.
@(private = "file")
load_root_package :: proc(c: ^Compiler, input: string) -> (Package_Id, bool) {
	if is_source_directory(c, input) {
		c.root_dir = strings.clone(canonical_dir(input), c.semantic_allocator)
		return load_package_dir(c, input, "", no_span())
	}
	c.root_dir = strings.clone(canonical_dir(path_dir(input, context.temp_allocator)), c.semantic_allocator)
	file, ok := parse_file(c, input)
	if !ok {
		return INVALID_PACKAGE, false
	}
	id := new_package(c, file.package_name, "")
	add_package_file(c, id, file)
	rebuild_active_items(c, package_of(c, id))
	// A sibling importing `.` must reuse this package.
	c.package_by_dir[dir_key(c.root_dir, c.semantic_allocator)] = id
	return id, true
}

// `written` is only for diagnostics; directory identity supplies the key.
// What `pkg` declares by `name`. A package that is absent or not yet scoped
// declares nothing.
package_symbol_named :: proc(c: ^Compiler, pkg: ^Package, name: string) -> Symbol_Id {
	if pkg == nil || pkg.scope == nil {
		return INVALID_SYMBOL
	}
	return pkg.scope.names[intern_identifier(c, name)]
}

// A type `pkg` declares by `name`, directly or as an alias such as
// `Writer :: dyn mut Sink` — a constant whose value is a type.
package_type_named :: proc(k: ^Checker, pkg: ^Package, name: string) -> (Type_Id, bool) {
	symbol_id := package_symbol_named(k.c, pkg, name)
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

load_package_dir :: proc(c: ^Compiler, dir: string, written: string, at: Span) -> (Package_Id, bool) {
	canonical := canonical_dir(dir)
	if existing, found := c.package_by_dir[dir_key(canonical)]; found {
		return existing, true
	}
	if !is_source_directory(c, canonical) {
		errorf(c, at, "L0327", "cannot find package `%s`", written == "" ? dir : written)
		return INVALID_PACKAGE, false
	}
	paths := package_sources(c, canonical)
	if len(paths) == 0 {
		errorf(c, at, "L0327", "`%s` holds no `.loke` files", canonical)
		return INVALID_PACKAGE, false
	}

	files := make([dynamic]^File, 0, len(paths), context.temp_allocator)
	for path in paths {
		file, ok := parse_file(c, path)
		if !ok {
			continue
		}
		append(&files, file)
	}
	if len(files) == 0 {
		return INVALID_PACKAGE, false
	}

	// A file with no `package` clause has been reported, and names nothing.
	established := files[0]
	for file in files {
		if file.package_name != "" {
			established = file
			break
		}
	}
	id := new_package(c, established.package_name, package_key(c, canonical))
	c.package_by_dir[dir_key(canonical, c.semantic_allocator)] = id
	pkg := package_of(c, id)
	for file in files {
		if file.package_name != "" && file.package_name != established.package_name {
			errorf(
				c,
				file.package_span,
				"L0328",
				"package `%s` does not match `%s`",
				file.package_name,
				established.package_name,
			)
			add_notef(c, established.package_span, "the package was established here")
		}
		append(&pkg.files, file)
	}
	// Let the current discovery pass see this package's imports.
	rebuild_active_items(c, pkg)
	return id, true
}

// Direct regular `.loke` files, sorted for deterministic package order.
@(private)
package_sources :: proc(c: ^Compiler, dir: string) -> []string {
	overlays := compiler_overlays(c)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil && len(overlays) == 0 {
		return nil
	}
	paths := make([dynamic]string, 0, len(entries), c.semantic_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for entry in entries {
		if entry.type == .Regular && strings.equal_fold(filepath.ext(entry.name), ".loke") {
			append(&paths, strings.clone(entry.fullpath, c.semantic_allocator))
			seen[dir_key(canonical_dir(entry.fullpath))] = true
		}
	}
	key := dir_key(canonical_dir(dir))
	for path, overlay in overlays {
		if !seen[path] && dir_key(canonical_dir(path_dir(overlay.path, context.temp_allocator))) == key {
			append(&paths, strings.clone(overlay.path, c.semantic_allocator))
		}
	}
	// By name: listed paths end `\name` on Windows, unsaved ones `/name`, and
	// the separator must not put unsaved files first.
	slice.sort_by(paths[:], proc(a, b: string) -> bool { return filepath.base(a) < filepath.base(b) })
	return paths[:]
}

@(private = "file")
parse_file :: proc(c: ^Compiler, path: string) -> (^File, bool) {
	index, loaded := load_source(c, path)
	if !loaded {
		return nil, false
	}
	tokens := lex(c, index)
	defer delete(tokens)
	// Incremental syntax joins the checkpointed arena; batch files own theirs.
	syntax: mem.Allocator
	if c.package_cache != nil { syntax = c.semantic_allocator }
	file := new(File, syntax if c.package_cache != nil else context.allocator)
	file^ = parse(c, index, tokens, syntax)
	append(&c.parsed_files, file)
	return file, true
}

// ---------------------------------------------------------------- discovery --

// Binds active imports and reports whether the graph grew.
@(private)
discover_imports :: proc(c: ^Compiler, k: ^Checker) -> bool {
	changed := false
	for index := 1; index < len(c.packages); index += 1 {
		id := Package_Id(index)
		for file in package_of(c, id).files[:] {
			if !file.parallel_bound && selects_parallel(file) {
				file.parallel_bound = true
				changed = true
				bind_parallel_edge(c, id)
			}
			for item in file.active_items {
				imported, is_import := item.(^Item_Import)
				if !is_import || imported.bound {
					continue
				}
				imported.bound = true
				changed = true
				bind_import_edge(c, id, file, imported)
			}
		}
	}
	return changed
}

@(private = "file")
bind_import_edge :: proc(c: ^Compiler, id: Package_Id, file: ^File, imported: ^Item_Import) {
	path, decoded := decode_string_literal(c, imported.path, false)
	if !decoded || path == "" {
		errorf(c, imported.span, "L0329", "this import path is not a string")
		return
	}
	dir, why := resolve_import_path(c, file, path)
	switch why {
	case .No_Collection:
		errorf(
			c,
			imported.span,
			"L0329",
			"no collection is registered for `%s`; add `require %s <path>` to loke.project, or pass `-collection %s=<path>`",
			path,
			collection_prefix(path),
			collection_prefix(path),
		)
		return
	case .Outside_Collection:
		errorf(
			c,
			imported.span,
			"L0329",
			"`%s` leaves the `%s` collection; a prefixed path names a package inside it",
			path,
			collection_prefix(path),
		)
		return
	case .Ok:
	}
	target, loaded := load_package_dir(c, dir, path, imported.span)
	if !loaded {
		return
	}
	// design.md "Exported names": `package main` is an executable's root, which
	// nothing imports, so its declarations are public by default.
	if identifier_text(c, package_of(c, target).name) == "main" {
		errorf(c, imported.span, "L0719", "`%s` is a `package main`, which cannot be imported", path)
		add_notef(c, no_span(), "move what both programs share into a package of its own")
		return
	}
	append(&package_of(c, id).imports, Package_Import {
		target = target,
		span   = imported.span,
		alias  = import_alias(imported, path),
	})
}

// Whether a selected item holds a `parallel` keyword: an unselected `when`
// branch is never checked, so it needs nothing. One in a body's own `when` is
// counted, since a statement's branch is chosen while checking.
@(private = "file")
selects_parallel :: proc(file: ^File) -> bool {
	for item in file.active_items {
		span := item_span(item)
		for offset in file.parallels {
			if offset >= span.lo && offset < span.hi {
				return true
			}
		}
	}
	return false
}

// compiler-architecture.md "Lowering parallel blocks": a `parallel` block's
// hidden scope is `core:thread`'s, so the package is a dependency no source
// names. The edge binds no alias. Where no collection provides it, the block
// that needs it says so (`check_parallel`), and a block in a branch no check
// reaches needs nothing.
@(private = "file")
bind_parallel_edge :: proc(c: ^Compiler, id: Package_Id) {
	dir, why := resolve_import_path(c, nil, STD_THREAD)
	if why != .Ok || !os.is_dir(dir) {
		return
	}
	target, loaded := load_package_dir(c, dir, STD_THREAD, no_span())
	if !loaded {
		return
	}
	append(&package_of(c, id).imports, Package_Import{target = target, span = no_span()})
}

// Available before decoding for stalled-condition checks.
import_binding_name :: proc(imported: ^Item_Import) -> string {
	raw := imported.path
	if len(raw) >= 2 {
		raw = raw[1:len(raw) - 1] // the literal's quotes
	}
	return import_alias(imported, raw)
}

@(private = "file")
import_alias :: proc(imported: ^Item_Import, path: string) -> string {
	if imported.alias.text != "" {
		return imported.alias.text
	}
	return path_tail(path)
}

@(private = "file")
path_tail :: proc(path: string) -> string {
	cleaned := strings.trim_right(path, "/")
	if slash := strings.last_index_byte(cleaned, '/'); slash >= 0 {
		return cleaned[slash + 1:]
	}
	if colon := strings.index_byte(cleaned, ':'); colon >= 0 {
		return cleaned[colon + 1:]
	}
	return cleaned
}

// The caller reports resolution failures because imports and providers differ.
Import_Resolution :: enum {
	Ok,
	No_Collection,
	Outside_Collection,
}

resolve_import_path :: proc(c: ^Compiler, file: ^File, path: string) -> (dir: string, why: Import_Resolution) {
	if colon := strings.index_byte(path, ':'); colon > 0 {
		name := path[:colon]
		rest := path[colon + 1:]
		root, registered := c.collections[name]
		if !registered {
			return "", .No_Collection
		}
		// Collection imports may not escape through `..`.
		collection_root := canonical_dir(root)
		resolved := canonical_dir(strings.concatenate({root, "/", rest}, context.temp_allocator))
		if _, under := path_under(collection_root, resolved); !under {
			return "", .Outside_Collection
		}
		return resolved, .Ok
	}
	if file == nil {
		return "", .No_Collection
	}
	source_dir := path_dir(c.sources[file.file].path, context.temp_allocator)
	return canonical_dir(strings.concatenate({source_dir, "/", path}, context.temp_allocator)), .Ok
}

// Directory-derived identity makes alternate import spellings deterministic
// (design.md "Import statement"): the key spells the directory as it is stored,
// whatever case an import wrote. The longest registered collection root wins,
// for the root directory too, so `lokec core/strings -doc` checks
// `core:strings` with what the compiler contributes to it. Of collections
// sharing that root, `base` and `core` win, so another name for a bundled root
// still reaches its contributed members; the rest go by name.
@(private = "file")
package_key :: proc(c: ^Compiler, canonical: string) -> string {
	names := make([dynamic]string, 0, len(c.collections), context.temp_allocator)
	for name in c.collections {
		append(&names, name)
	}
	slice.sort_by(names[:], proc(a, b: string) -> bool {
		a_bundled, b_bundled := a == "base" || a == "core", b == "base" || b == "core"
		return a_bundled != b_bundled ? a_bundled : a < b
	})
	best, best_root := "", -1
	for name in names {
		root := canonical_dir(c.collections[name])
		rest, under := path_under(root, canonical)
		if under && len(root) > best_root {
			best = strings.concatenate({name, ":", stored_case(root, rest)}, c.semantic_allocator)
			best_root = len(root)
		}
	}
	if best_root >= 0 {
		return best
	}
	return root_relative_key(c, canonical)
}

// Returns `sub` relative to canonical `root`, case-insensitively.
@(private = "file")
path_under :: proc(root: string, sub: string) -> (rest: string, ok: bool) {
	if root == "" {
		return "", false
	}
	lower_root := strings.to_lower(root, context.temp_allocator)
	lower_sub := strings.to_lower(sub, context.temp_allocator)
	if lower_sub == lower_root {
		return "", true
	}
	if len(sub) <= len(root) || !strings.has_prefix(lower_sub, lower_root) {
		return "", false
	}
	offset := len(root)
	if root[len(root) - 1] != '/' {
		if sub[offset] != '/' {
			return "", false
		}
		offset += 1
	}
	return sub[offset:], true
}

collection_prefix :: proc(path: string) -> string {
	if colon := strings.index_byte(path, ':'); colon > 0 {
		return path[:colon]
	}
	return path
}

// Unregistered packages use root-relative identity; cross-volume packages add
// a digest because `filepath.rel` has no answer there.
@(private = "file")
root_relative_key :: proc(c: ^Compiler, dir: string) -> string {
	relative, err := filepath.rel(c.root_dir, dir, context.temp_allocator)
	if err != nil {
		return fmt.aprintf(
			"%s.%x", filepath.base(dir), path_digest(dir), allocator = c.semantic_allocator,
		)
	}
	cleaned, _ := strings.replace_all(relative, "\\", "/", context.temp_allocator)
	if cleaned == "." {
		return ""
	}
	return strings.clone(stored_case(c.root_dir, cleaned), c.semantic_allocator)
}

// `rest`, a relative directory below `root`, spelled as the directories are
// stored. A component with no stored match, as an unsaved overlay's has, keeps
// its spelling.
@(private = "file")
stored_case :: proc(root, rest: string) -> string {
	if rest == "" {
		return rest
	}
	parts := strings.split(rest, "/", context.temp_allocator)
	dir := root
	for &part in parts {
		if entries, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
			for entry in entries {
				if entry.type == .Directory && strings.equal_fold(entry.name, part) {
					part = entry.name
					break
				}
			}
		}
		dir = strings.concatenate({dir, "/", part}, context.temp_allocator)
	}
	return strings.join(parts, "/", context.temp_allocator)
}

// -------------------------------------------------------------- graph shape --

// Rejects a cycle in the currently active import graph, reporting it as the
// ordered path of import statements that closes it.
@(private = "file")
check_import_cycles :: proc(c: ^Compiler) -> bool {
	state := make([]u8, len(c.packages), context.temp_allocator) // 0 new, 1 on stack, 2 done
	path := make([dynamic]Package_Import, 0, 8, context.temp_allocator)
	for index in 1 ..< len(c.packages) {
		if !visit_for_cycle(c, Package_Id(index), state, &path) {
			return false
		}
	}
	return true
}

@(private = "file")
visit_for_cycle :: proc(c: ^Compiler, id: Package_Id, state: []u8, path: ^[dynamic]Package_Import) -> bool {
	if state[id] == 2 {
		return true
	}
	if state[id] == 1 {
		// Drop the acyclic approach and report only the cycle tail.
		cycle := path[:]
		for edge, index in cycle[:len(cycle) - 1] {
			if edge.target == id {
				cycle = cycle[index + 1:]
				break
			}
		}
		errorf(c, path[len(path) - 1].span, "L0330", "import cycle")
		from := id
		for edge in cycle {
			add_notef(c, edge.span, "`%s` imports `%s` here", identifier_text(c, package_of(c, from).name), identifier_text(c, package_of(c, edge.target).name))
			from = edge.target
		}
		return false
	}
	state[id] = 1
	defer state[id] = 2
	pkg := package_of(c, id)
	for edge in pkg.imports {
		append(path, edge)
		if !visit_for_cycle(c, edge.target, state, path) {
			return false
		}
		pop(path)
	}
	return true
}

// Dependency-first order, deterministic because the edge list is built in
// source order and the walk is a post-order DFS.
package_order :: proc(c: ^Compiler) -> []Package_Id {
	visited := make([]bool, len(c.packages), context.temp_allocator)
	order := make([dynamic]Package_Id, 0, len(c.packages), context.temp_allocator)
	for index in 1 ..< len(c.packages) {
		visit_for_order(c, Package_Id(index), visited, &order)
	}
	return order[:]
}

@(private = "file")
visit_for_order :: proc(c: ^Compiler, id: Package_Id, visited: []bool, order: ^[dynamic]Package_Id) {
	if visited[id] {
		return
	}
	visited[id] = true
	for edge in package_of(c, id).imports {
		visit_for_order(c, edge.target, visited, order)
	}
	append(order, id)
}
