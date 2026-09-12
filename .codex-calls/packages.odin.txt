// Package discovery and the program-level fixed point.
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

import "core:fmt"
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
	// design.md "Build-selected providers": selections live on the root package
	// clause. A selected provider's package is a build dependency even where no
	// source imports it, so it is loaded here and then travels the ordinary
	// discovery, ordering, and checking path.
	collect_source_provider_defaults(c, root)
	load_provider_packages(c)

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

	// No rebuild here: the loop only exits after a round that changed nothing, so
	// the view its top built is still current, and a stalled `when` contributes
	// nothing to a view either way.
	for index in 1 ..< len(c.packages) {
		report_stalled_whens(&k, &c.packages[index])
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
	// The factories are resolved once the whole program is checked, so a factory
	// declared inside a selected `when` branch has a resolved signature to check.
	resolve_provider_factories(&k)
	return root, c.error_count == 0
}

// ------------------------------------------------------------------ loading --

// The one unconditional package. It is loaded through the ordinary collection
// machinery, so a program that also imports `base:runtime` by name gets the
// same package rather than a second copy of it.
load_runtime_bootstrap :: proc(c: ^Compiler) -> (Package_Id, bool) {
	root, registered := c.collections["base"]
	if !registered {
		return INVALID_PACKAGE, false // reported at the first import that needs it
	}
	return load_package_dir(c, strings.concatenate({root, "/runtime"}), STD_RUNTIME, no_span())
}

// `compile_program` reaches `base:runtime` through the ordinary dependency
// order. A caller that checks one package on its own — a unit test, or any
// other direct entry — asks for the bootstrap here instead, because `Option`
// and `Result` have to exist before a signature can name them.
ensure_runtime_bootstrap :: proc(k: ^Checker) {
	if k.c.bootstrap_ready {
		return
	}
	init_semantic_stores(k.c)
	if _, seeded := k.c.collections["base"]; !seeded {
		if k.c.collections == nil {
			k.c.collections = make(map[string]string, 2, k.c.semantic_allocator)
		}
		// The bundled root is resolved from the running executable. A direct entry
		// is often *not* the installed compiler — the unit-test binary lives in a
		// temporary directory — so the working directory is the fallback.
		root := install_component("base")
		if root == "" || !is_directory(strings.concatenate({root, "/runtime"})) {
			root = "base"
		}
		k.c.collections["base"] = root
	}
	id, loaded := load_runtime_bootstrap(k.c)
	if !loaded {
		return
	}
	saved_pkg, saved_lookup, saved_scope := k.pkg, k.lookup_pkg, k.scope
	prepare_package(k, id)
	k.pkg, k.lookup_pkg, k.scope = saved_pkg, saved_lookup, saved_scope
}

// A directory argument compiles every `.loke` file directly in it. A file
// argument keeps the one-file-package behaviour the existing corpus relies on,
// though its relative imports still resolve from its own directory.
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
	id := new_package(c, file.package_name, "")
	add_package_file(c, id, file)
	// A single-file root still occupies its directory's identity, so a sibling
	// importing `.` finds this package rather than loading the directory twice.
	c.package_by_dir[dir_key(c.root_dir)] = id
	return id, true
}

// `written` is the import path as the source spelled it, used only to name the
// package in a diagnostic. The identity the package keeps is derived from its
// directory, by `package_key`.
load_package_dir :: proc(c: ^Compiler, dir: string, written: string, at: Span) -> (Package_Id, bool) {
	canonical := canonical_dir(dir)
	if existing, found := c.package_by_dir[dir_key(canonical)]; found {
		return existing, true
	}
	if !is_directory(canonical) {
		errorf(c, at, "L0327", "cannot find package `%s`", written == "" ? dir : written)
		return INVALID_PACKAGE, false
	}
	paths := package_sources(canonical)
	if len(paths) == 0 {
		errorf(c, at, "L0327", "`%s` holds no `.loke` files", canonical)
		return INVALID_PACKAGE, false
	}

	id := new_package(c, "", package_key(c, canonical))
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
	// The view is built here rather than at the next round's top, so `import`
	// items are visible to the discovery pass that loaded this package and the
	// graph stops being walked one level per round. Nothing is checked earlier
	// than before: `prepare_package` does reach the package a round sooner, but
	// declaring an `impl` block waits on the package's own `when` items now, and
	// that is what the round of slack used to stand in for -- badly, since it
	// never covered the root package, whose blocks always raced its own
	// selection.
	rebuild_active_items(c, pkg)
	return id, len(pkg.files) > 0
}

// Every `.loke` file directly in one directory, sorted, so one directory always
// produces one package in one order. The extension is matched
// case-insensitively: Windows is the only v1 target and its filesystem is too,
// so a file named `helper.LOKE` must not be silently invisible.
@(private = "file")
package_sources :: proc(dir: string) -> []string {
	entries, err := filepath.glob(strings.concatenate({dir, "/*"}))
	if err != nil {
		return nil
	}
	paths := make([dynamic]string, 0, len(entries))
	for entry in entries {
		if strings.to_lower(filepath.ext(entry), context.temp_allocator) == ".loke" {
			append(&paths, entry)
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

// Turns every not-yet-bound active `import` into an edge, loading the target
// package if this is the first time anything named it. Returns true when the
// graph grew, which is what keeps the surrounding fixed point going.
@(private = "file")
discover_imports :: proc(c: ^Compiler, k: ^Checker) -> bool {
	changed := false
	// `c.packages` grows while this runs — loading a target appends to it, which
	// reallocates the store. Nothing here retains a `^Package` across a load; the
	// index walk also picks up the new packages in the same pass.
	//
	// A package loaded here already has its selected view, so its own imports are
	// found before this pass ends rather than one round later.
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
// Why a prefixed import could not be resolved. The caller reports it, because an
// `import` statement and a provider selection name the offender differently.
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
		// A prefix selects a collection, so the path behind it names a package
		// *inside* that collection. Without this, `name:../elsewhere` reaches a
		// directory the collection does not contain while borrowing its name.
		collection_root := canonical_dir(root)
		resolved := canonical_dir(strings.concatenate({root, "/", rest}))
		if _, under := path_under(collection_root, resolved); !under {
			return "", .Outside_Collection
		}
		return resolved, .Ok
	}
	// Without an importing file an unprefixed path has nothing to be relative to.
	// Answering here rather than leaving the caller to re-test the prefix keeps
	// the precondition in one place: the caller reports it, because a selection
	// and an `import` name the offender differently.
	if file == nil {
		return "", .No_Collection
	}
	source_dir := filepath.dir(c.sources[file.file].path)
	return canonical_dir(strings.concatenate({source_dir, "/", path})), .Ok
}

// A package's identity is a function of its directory, never of the import that
// happened to reach it first. Two spellings of one directory — `core:log` and a
// relative `../core/log`, say — resolve to one package, so deriving the key from
// the spelling would let the discovery order decide the emitted symbol names,
// and renaming a source file would rename another package's exports.
//
// The root package keeps the empty key its fixed entry name depends on. A
// directory genuinely inside a registered collection is named `collection:path`;
// the longest matching root wins, so a collection nested in another keeps its
// own name, and the scan runs over sorted names so map order cannot decide it.
// Anything else — including a path that escaped its collection with `..` — is
// named relative to the root package rather than claiming a collection it is
// not in.
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

// `sub` spelled relative to `root`, when `sub` is `root` or lies inside it. Both
// are canonical, so this is a prefix test on a directory boundary — case-blind,
// for the same reason `dir_key` is.
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
	if len(sub) > len(root) && strings.has_prefix(lower_sub, lower_root) && sub[len(root)] == '/' {
		return sub[len(root) + 1:], true
	}
	return "", false
}

// Also used to name the offending prefix in the provider diagnostics.
collection_prefix :: proc(path: string) -> string {
	if colon := strings.index_byte(path, ':'); colon > 0 {
		return path[:colon]
	}
	return path
}

// The logical identity of a package that belongs to no registered collection:
// its path relative to the root package. A directory outside the root tree gets
// a `..`-prefixed spelling and therefore an identity that travels with the
// project's layout — which is the most a package inside no collection can be
// given, since its own name is not unique and its absolute path is the host's.
// A package meant to keep one name wherever it is used is registered as a
// collection, and `package_key` names it from there.
//
// `rel` has no answer across Windows volumes. The directory's own name would
// not be unique there — two `util` directories on two drives would mangle
// alike, and LLVM would see one definition twice — so it is qualified by a
// digest of the path rather than spelling the path out.
@(private = "file")
root_relative_key :: proc(c: ^Compiler, dir: string) -> string {
	relative, err := filepath.rel(c.root_dir, dir)
	if err != nil {
		return fmt.aprintf(
			"%s.%x", filepath.base(dir), path_digest(dir), allocator = c.semantic_allocator,
		)
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
		// `path` is the route from wherever the outer scan started, which may reach
		// the cycle through edges that are not in it. The cycle is the tail that
		// leaves `id`, so it begins just after the approach arrives there; listing
		// the approach as well would blame imports that are perfectly fine.
		//
		// The last edge is the arrival that closed the cycle, so it is not the
		// approach — searching without it also leaves the whole path as the answer
		// when the scan happened to start on `id` itself.
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

// A digest of a case-folded path, for the two places that need one path to stay
// distinct from another whose visible name matches it. FNV-1a, not
// cryptographic and not stable across compiler versions: it only has to be a
// function of the path within one build.
path_digest :: proc(path: string) -> u64 {
	key := strings.to_lower(path, context.temp_allocator)
	digest := u64(14695981039346656037) // FNV-1a offset basis
	for index in 0 ..< len(key) {
		digest = (digest ~ u64(key[index])) * HASH_MULTIPLIER
	}
	return digest
}
