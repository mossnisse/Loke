// Package discovery and the program-level fixed point (compiler-plan B5).
//
// A round alternates discovery, collection, and selection: import the edges
// that are active now, collect what the newly active items declare, answer the
// `when` conditions that have become answerable, and repeat while anything
// changed. Package state is persistent and monotonic, so re-running a round
// never re-declares what an earlier one already established.
//
// There is no built-in `core:` root. A collection prefix resolves only when the
// driver was given a matching `-collection name=path`.
package lokec

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The whole front end for one program: load the root, discover everything it
// reaches, and check each package in dependency order.
compile_program :: proc(c: ^Compiler, input: string) -> (Package_Id, bool) {
	init_semantic_stores(c)
	// design.md "Typed fallibility": `base:runtime` declares `Unit`, `Option`,
	// and `Result`, which the checker instantiates for built-in producers before
	// any user signature is resolved. Loading it first also makes it package 1,
	// so the dependency-first order checks it before everything else.
	load_runtime_bootstrap(c)
	root, loaded := load_root_package(c, input)
	if !loaded {
		return INVALID_PACKAGE, false
	}
	c.root_package = root

	k := Checker{c = c}
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

	for index in 1 ..< len(c.packages) {
		report_stalled_whens(&k, &c.packages[index])
		rebuild_active_items(c, &c.packages[index])
	}
	// Ordinary body checking waits until selection and the import graph are
	// stable, so an unconditional body may name a declaration a selected branch
	// supplied.
	for id in package_order(c) {
		check_package_bodies(&k, id)
		// Methods of a generic instantiation are checked once their requesting
		// package is finished, so a method body may itself use the instance that
		// its own signature created.
		check_pending_impl_instances(&k)
	}
	// design.md "Borrows and lifetimes" and "Allocator regions and region
	// provenance": both analyses run once the whole program is checked, over
	// disposable read-only rebuilds of the same control-flow view.
	analyze_program_provenance(&k)
	return root, c.error_count == 0
}

// ------------------------------------------------------------------ loading --

// A directory argument compiles every `.loke` file directly in it. A file
// argument keeps the one-file-package behaviour the existing corpus relies on,
// though its relative imports still resolve from its own directory.
// The one unconditional package. It is loaded through the ordinary collection
// machinery, so a program that also imports `base:runtime` by name gets the
// same package rather than a second copy of it.
@(private = "file")
load_runtime_bootstrap :: proc(c: ^Compiler) {
	root, registered := c.collections["base"]
	if !registered {
		return // reported at the first import that needs it
	}
	load_package_dir(c, strings.concatenate({root, "/runtime"}), STD_RUNTIME, no_span())
}

@(private = "file")
load_root_package :: proc(c: ^Compiler, input: string) -> (Package_Id, bool) {
	if is_directory(input) {
		c.root_dir = canonical_dir(input)
		return load_package_dir(c, input, "", no_span())
	}
	c.root_dir = canonical_dir(filepath.dir(input))
	file, ok := parse_file(c, input)
	if !ok {
		return INVALID_PACKAGE, false
	}
	id := new_package(c, file.package_name, input, "")
	add_package_file(c, id, file)
	// A single-file root still occupies its directory's identity, so a sibling
	// importing `.` finds this package rather than loading the directory twice.
	c.package_by_dir[dir_key(c.root_dir)] = id
	return id, true
}

@(private = "file")
load_package_dir :: proc(c: ^Compiler, dir: string, key: string, at: Span) -> (Package_Id, bool) {
	canonical := canonical_dir(dir)
	if existing, found := c.package_by_dir[dir_key(canonical)]; found {
		return existing, true
	}
	if !is_directory(canonical) {
		errorf(c, at, "L0327", "cannot find package `%s`", key == "" ? dir : key)
		return INVALID_PACKAGE, false
	}
	paths, _ := filepath.glob(strings.concatenate({canonical, "/*.loke"}))
	slice.sort(paths)
	if len(paths) == 0 {
		errorf(c, at, "L0327", "`%s` holds no `.loke` files", canonical)
		return INVALID_PACKAGE, false
	}

	id := new_package(c, "", canonical, key)
	c.package_by_dir[dir_key(canonical)] = id
	pkg := package_of(c, id)
	for path in paths {
		file, ok := parse_file(c, path)
		if !ok {
			continue
		}
		if len(pkg.files) == 0 {
			pkg.name = intern_identifier(c, file.package_name)
		} else if file.package_name != pkg.files[0].package_name {
			// A directory is one package; files that disagree about its name would
			// otherwise give it two identities.
			errorf(
				c,
				file.package_span,
				"L0328",
				"package `%s` does not match `%s`",
				file.package_name,
				pkg.files[0].package_name,
			)
			add_notef(c, pkg.files[0].package_span, "the package was established here")
		}
		append(&pkg.files, file)
	}
	return id, len(pkg.files) > 0
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

// Turns every not-yet-bound active `import` into an edge, loading the target
// package if this is the first time anything named it. Returns true when the
// graph grew, which is what keeps the surrounding fixed point going.
@(private = "file")
discover_imports :: proc(c: ^Compiler, k: ^Checker) -> bool {
	changed := false
	// `c.packages` grows while this runs — loading a target appends to it, which
	// reallocates the store. Nothing here retains a `^Package` across a load; the
	// index walk also picks up the new packages in the same pass.
	for index := 1; index < len(c.packages); index += 1 {
		id := Package_Id(index)
		for position := 0; position < len(package_of(c, id).files); position += 1 {
			file := package_of(c, id).files[position]
			for item in file.active_items {
				imported, is_import := item.(^Item_Import)
				if !is_import || imported.bound {
					continue
				}
				// Mark the syntax item itself. A later selection round may insert a
				// new import before this one, so an active-list position is not a
				// durable discovery identity.
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
	dir, key, resolved := resolve_import_path(c, file, path)
	if !resolved {
		errorf(
			c,
			imported.span,
			"L0329",
			"no collection is registered for `%s`; pass `-collection %s=<path>`",
			path,
			collection_prefix(path),
		)
		return
	}
	target, loaded := load_package_dir(c, dir, key, imported.span)
	if !loaded {
		return
	}
	// `load_package_dir` may have grown the store; reacquire before appending.
	append(&package_of(c, id).imports, Package_Import {
		target = target,
		span   = imported.span,
		alias  = import_alias(imported, path),
	})
}

// The name an import binds in its package: the written alias, or by convention
// the last element of the path. Available before the path is decoded, so the
// stalled-condition check can ask what a branch's imports would supply.
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
	cleaned := strings.trim_suffix(path, "/")
	if slash := strings.last_index_byte(cleaned, '/'); slash >= 0 {
		return cleaned[slash + 1:]
	}
	if colon := strings.index_byte(cleaned, ':'); colon >= 0 {
		return cleaned[colon + 1:]
	}
	return cleaned
}

// An unprefixed path is relative to the importing file; `name:path` resolves
// under `-collection name=path`. The returned key is the logical identity used
// for mangling, never the host absolute path.
@(private = "file")
resolve_import_path :: proc(c: ^Compiler, file: ^File, path: string) -> (dir: string, key: string, ok: bool) {
	if colon := strings.index_byte(path, ':'); colon > 0 {
		name := path[:colon]
		rest := path[colon + 1:]
		root, registered := c.collections[name]
		if !registered {
			return "", "", false
		}
		return strings.concatenate({root, "/", rest}), path, true
	}
	source_dir := filepath.dir(c.sources[file.file].path)
	resolved := canonical_dir(strings.concatenate({source_dir, "/", path}))
	return resolved, root_relative_key(c, resolved), true
}

@(private = "file")
collection_prefix :: proc(path: string) -> string {
	if colon := strings.index_byte(path, ':'); colon > 0 {
		return path[:colon]
	}
	return path
}

// The logical identity of a package inside the root tree. A directory outside
// it keeps its own name, which is enough to keep symbols apart without putting
// a host path into the binary.
@(private = "file")
root_relative_key :: proc(c: ^Compiler, dir: string) -> string {
	relative, err := filepath.rel(c.root_dir, dir)
	if err != nil {
		return filepath.base(dir)
	}
	cleaned := strings.replace_all(relative, "\\", "/") or_else relative
	if cleaned == "." {
		return ""
	}
	return cleaned
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
		errorf(c, path[len(path) - 1].span, "L0330", "import cycle")
		for edge in path {
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

@(private = "file")
is_directory :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	return err == nil && info.is_dir
}

// Absolute, `/`-separated, and free of `.`/`..`, so two spellings of one
// directory are the same package.
@(private = "file")
canonical_dir :: proc(path: string) -> string {
	absolute, ok := filepath.abs(path)
	cleaned := ok ? absolute : path
	return strings.replace_all(filepath.clean(cleaned), "\\", "/") or_else cleaned
}

// Windows paths are case-insensitive, so package identity must be too.
@(private = "file")
dir_key :: proc(dir: string) -> string {
	return strings.to_lower(dir)
}
