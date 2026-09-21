// Package discovery and the program-level fixed point. Package state grows
// monotonically while imports and `when` selections settle.
package lokec

import "core:fmt"
import "core:os"
import os2 "core:os/os2"
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
	defer delete(k.nil_uses)
	for {
		for index in 1 ..< len(c.packages) {
			rebuild_active_items(c, &c.packages[index])
		}
		changed := discover_imports(c, &k)
		if !check_import_cycles(c) {
			return root, false
		}
		order := package_order(c)
		for id in order {
			prepare_package(&k, id)
		}
		for id in order {
			if activate_when_items(&k, package_of(c, id)) {
				changed = true
			}
		}
		if !changed {
			break
		}
	}

	// The last unchanged round left every active view current.
	for index in 1 ..< len(c.packages) {
		report_stalled_whens(&k, &c.packages[index])
	}
	// Bodies wait until selections and imports are stable.
	for id in package_order(c) {
		check_package_bodies(&k, id)
		check_pending_impl_instances(&k)
	}
	analyze_program_provenance(&k)
	resolve_provider_factories(&k)
	return root, c.error_count == 0
}

// Makes a checked program ready for emission. Each step is idempotent.
finalize_semantics :: proc(c: ^Compiler) {
	freeze_typeids(c)
	discover_formatters(c)
	_ = finalize_lifecycle_operations(c)
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

// Bootstraps direct checker entry points that bypass `compile_program`.
ensure_runtime_bootstrap :: proc(k: ^Checker) {
	if k.c.bootstrap_ready {
		return
	}
	init_semantic_stores(k.c)
	if _, seeded := k.c.collections["base"]; !seeded {
		// Test binaries need the working-directory fallback.
		installed := install_component("base")
		defer delete(installed)
		root := installed
		if root == "" || !is_directory(strings.concatenate({root, "/runtime"}, context.temp_allocator)) {
			root = "base"
		}
		k.c.collections["base"] = strings.clone(root, k.c.semantic_allocator)
	}
	id, loaded := load_runtime_bootstrap(k.c)
	if !loaded {
		return
	}
	saved_pkg, saved_lookup, saved_scope := k.pkg, k.lookup_pkg, k.scope
	prepare_package(k, id)
	k.pkg, k.lookup_pkg, k.scope = saved_pkg, saved_lookup, saved_scope
}

// Directory roots include their direct `.loke` files; file roots stand alone.
@(private = "file")
load_root_package :: proc(c: ^Compiler, input: string) -> (Package_Id, bool) {
	if is_directory(input) {
		c.root_dir = strings.clone(canonical_dir(input), c.semantic_allocator)
		return load_package_dir(c, input, "", no_span())
	}
	c.root_dir = strings.clone(canonical_dir(filepath.dir(input, context.temp_allocator)), c.semantic_allocator)
	file, ok := parse_file(c, input)
	if !ok {
		return INVALID_PACKAGE, false
	}
	id := new_package(c, file.package_name, "")
	add_package_file(c, id, file)
	// A sibling importing `.` must reuse this package.
	c.package_by_dir[dir_key(c.root_dir, c.semantic_allocator)] = id
	return id, true
}

// `written` is only for diagnostics; directory identity supplies the key.
load_package_dir :: proc(c: ^Compiler, dir: string, written: string, at: Span) -> (Package_Id, bool) {
	canonical := canonical_dir(dir)
	if existing, found := c.package_by_dir[dir_key(canonical)]; found {
		return existing, true
	}
	if !is_directory(canonical) {
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

	id := new_package(c, files[0].package_name, package_key(c, canonical))
	c.package_by_dir[dir_key(canonical, c.semantic_allocator)] = id
	pkg := package_of(c, id)
	for file in files {
		if file.package_name != files[0].package_name {
			errorf(
				c,
				file.package_span,
				"L0328",
				"package `%s` does not match `%s`",
				file.package_name,
				files[0].package_name,
			)
			add_notef(c, files[0].package_span, "the package was established here")
		}
		append(&pkg.files, file)
	}
	// Let the current discovery pass see this package's imports.
	rebuild_active_items(c, pkg)
	return id, true
}

// Direct regular `.loke` files, sorted for deterministic package order.
@(private = "file")
package_sources :: proc(c: ^Compiler, dir: string) -> []string {
	entries, err := os2.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return nil
	}
	paths := make([dynamic]string, 0, len(entries), c.semantic_allocator)
	for entry in entries {
		if entry.type == .Regular && strings.to_lower(filepath.ext(entry.name), context.temp_allocator) == ".loke" {
			append(&paths, strings.clone(entry.fullpath, c.semantic_allocator))
		}
	}
	slice.sort(paths[:])
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
	file := new(File)
	file^ = parse(c, index, tokens)
	append(&c.parsed_files, file)
	return file, true
}

// ---------------------------------------------------------------- discovery --

// Binds active imports and reports whether the graph grew.
@(private = "file")
discover_imports :: proc(c: ^Compiler, k: ^Checker) -> bool {
	changed := false
	// Loading may reallocate `c.packages`, so retain IDs rather than pointers.
	for index := 1; index < len(c.packages); index += 1 {
		id := Package_Id(index)
		for position := 0; position < len(package_of(c, id).files); position += 1 {
			file := package_of(c, id).files[position]
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
			"no collection is registered for `%s`; pass `-collection %s=<path>`",
			path,
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
	// Loading may have reallocated the package store.
	append(&package_of(c, id).imports, Package_Import {
		target = target,
		span   = imported.span,
		alias  = import_alias(imported, path),
	})
}

// Available before decoding for stalled-condition checks.
import_binding_name :: proc(imported: ^Item_Import) -> string {
	if imported.alias.text != "" {
		return imported.alias.text
	}
	raw := imported.path
	if len(raw) >= 2 {
		raw = raw[1:len(raw) - 1] // the literal's quotes
	}
	return path_tail(raw)
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
	source_dir := filepath.dir(c.sources[file.file].path, context.temp_allocator)
	return canonical_dir(strings.concatenate({source_dir, "/", path}, context.temp_allocator)), .Ok
}

// Directory-derived identity makes alternate import spellings deterministic.
// The longest registered collection root wins.
@(private = "file")
package_key :: proc(c: ^Compiler, canonical: string) -> string {
	if c.root_dir != "" && dir_key(canonical) == dir_key(c.root_dir) {
		return ""
	}
	names := make([dynamic]string, 0, len(c.collections), context.temp_allocator)
	for name in c.collections {
		append(&names, name)
	}
	slice.sort(names[:])
	best, best_root := "", -1
	for name in names {
		root := canonical_dir(c.collections[name])
		rest, under := path_under(root, canonical)
		if under && len(root) > best_root {
			best = strings.concatenate({name, ":", rest}, c.semantic_allocator)
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

// Also used to name the offending prefix in the provider diagnostics.
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
	return strings.clone(cleaned, c.semantic_allocator)
}

// -------------------------------------------------------------- graph shape --

// Rejects a cycle in the currently active import graph, reporting it as the
// ordered path of import statements that closes it.
@(private = "file")
check_import_cycles :: proc(c: ^Compiler) -> bool {
	state := make([]u8, len(c.packages), context.temp_allocator) // 0 new, 1 on stack, 2 done
	path := make([dynamic]Package_Import, 0, 8, context.temp_allocator)
	ok := true
	for index in 1 ..< len(c.packages) {
		if !visit_for_cycle(c, Package_Id(index), state, &path) {
			ok = false
			break
		}
	}
	return ok
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
		for edge in cycle {
			add_notef(c, edge.span, "`%s` imports `%s` here", package_label(c, edge), identifier_text(c, package_of(c, edge.target).name))
		}
		return false
	}
	state[id] = 1
	defer state[id] = 2
	pkg := package_of(c, id)
	for edge in pkg.imports {
		if edge.target == INVALID_PACKAGE {
			continue
		}
		append(path, edge)
		if !visit_for_cycle(c, edge.target, state, path) {
			return false
		}
		pop(path)
	}
	return true
}

@(private = "file")
package_label :: proc(c: ^Compiler, edge: Package_Import) -> string {
	if edge.span.file == NO_FILE || int(edge.span.file) >= len(c.sources) {
		return "a package"
	}
	for index in 1 ..< len(c.packages) {
		for file in c.packages[index].files {
			if file.file == edge.span.file {
				return identifier_text(c, c.packages[index].name)
			}
		}
	}
	return "a package"
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
		if edge.target != INVALID_PACKAGE {
			visit_for_order(c, edge.target, visited, order)
		}
	}
	append(order, id)
}

// ------------------------------------------------------------------- paths --

is_directory :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	return err == nil && info.is_dir
}

// Produces a temporary absolute, cleaned, `/`-separated path.
@(private = "file")
canonical_dir :: proc(path: string) -> string {
	absolute, ok := filepath.abs(path, context.temp_allocator)
	cleaned := filepath.clean(ok ? absolute : path, context.temp_allocator)
	slashed, _ := strings.replace_all(cleaned, "\\", "/", context.temp_allocator)
	return slashed
}

// Windows paths are case-insensitive, so package identity must be too.
@(private = "file")
dir_key :: proc(dir: string, allocator := context.temp_allocator) -> string {
	return strings.to_lower(dir, allocator)
}

// FNV-1a distinguishes otherwise identical visible path names.
path_digest :: proc(path: string) -> u64 {
	key := strings.to_lower(path, context.temp_allocator)
	digest := u64(14695981039346656037) // FNV-1a offset basis
	for index in 0 ..< len(key) {
		digest = (digest ~ u64(key[index])) * HASH_MULTIPLIER
	}
	return digest
}
