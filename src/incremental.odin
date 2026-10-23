// Conservative dependency-prefix reuse (compiler-architecture.md "Incremental checking").
package lokec

import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Compilation_Check_Stats :: struct {
	// IDs belong to the current compilation; slices expire at the next check.
	rechecked_packages, reused_packages: []Package_Id,
	semantic_bytes, cache_bytes: u64,
}

session_check_stats :: proc(s: ^Compilation_Session) -> Compilation_Check_Stats {
	stats := s.check_stats
	stats.semantic_bytes = u64(s.compiler.semantic_arena.total_used)
	stats.cache_bytes = s.package_cache.bytes
	return stats
}

@(private)
Package_Check_Cache :: struct {
	allocator: mem.Allocator,
	entries: [dynamic]Package_Checkpoint,
	order: []Package_Id,
	input, cwd: string,
	directory_root, documentation: bool,
	bytes: u64,
}

@(private)
Package_Checkpoint :: struct {
	index: int,
	state: Compiler,
	mark: virtual.Arena_Temp,
	blocks: [dynamic]Arena_Block_Image,
}

@(private)
Arena_Block_Image :: struct {
	block: ^virtual.Memory_Block,
	bytes: []u8,
}

// ponytail: bounded arena images preserve all cross-package IDs and mutations;
// package-owned semantic stores can replace prefix replay if its measured cost
// warrants that larger refactor. No cache persists beyond this live session.
@(private)
MAX_PACKAGE_CACHE_BYTES :: 64 * 1024 * 1024

// A file-scope `when` changes the package graph only if it selects an `import`
// or a `parallel` block, which needs `core:thread`. A `when` that
// selects declarations alone, such as the platform code of `core:fs`, reads
// only its own package and what that imports, so it settles before any
// dependent package is prepared.
@(private)
static_package_graph :: proc(c: ^Compiler) -> bool {
	if any_provider_selected(c) { return false }
	for file in c.parsed_files {
		if selects_imports(file.items, false) { return false }
		if selects_parallel_by_when(file.items, file.parallels) { return false }
	}
	return true
}

@(private = "file")
selects_imports :: proc(items: []Item, selected: bool) -> bool {
	for item in items {
		#partial switch v in item {
		case ^Item_Import:
			if selected { return true }
		case ^Item_Block:
			if selects_imports(v.items, selected) { return true }
		case ^Item_When:
			branches := [2]Item{v.then, v.otherwise}
			if selects_imports(branches[:] if v.otherwise != nil else branches[:1], true) { return true }
		}
	}
	return false
}

// Whether a `parallel` keyword lies in a file-scope `when` branch, whose
// selection decides whether `core:thread` is a dependency.
@(private = "file")
selects_parallel_by_when :: proc(items: []Item, parallels: []u32) -> bool {
	for item in items {
		#partial switch v in item {
		case ^Item_Block:
			if selects_parallel_by_when(v.items, parallels) { return true }
		case ^Item_When:
			for offset in parallels {
				if offset >= v.span.lo && offset < v.span.hi { return true }
			}
		}
	}
	return false
}

@(private)
check_static_packages :: proc(k: ^Checker, order: []Package_Id, start: int) {
	for index in start ..< len(order) {
		if cache := k.c.package_cache; cache != nil && k.c.error_count == 0 {
			cache_package_checkpoint(k.c, index)
		}
		id := order[index]
		prepare_package(k, id)
		// The package's own selection fixed point. Every package it imports is
		// already settled, and no branch adds an import.
		for activate_when_items(k, package_of(k.c, id)) {
			rebuild_active_items(k.c, package_of(k.c, id))
			prepare_package(k, id)
		}
		report_stalled_whens(k, package_of(k.c, id))
		check_package_bodies(k, id)
		check_pending_impl_instances(k)
	}
}

@(private)
cache_package_checkpoint :: proc(c: ^Compiler, index: int) {
	cache := c.package_cache
	context.allocator = cache.allocator
	for entry in cache.entries { if entry.index == index { return } }
	if u64(c.semantic_arena.total_used) > MAX_PACKAGE_CACHE_BYTES { return }
	// Keep the latest boundaries under pressure: ordinary edits near the root
	// should not lose their checkpoint to rarely used dependency boundaries.
	for cache.bytes + u64(c.semantic_arena.total_used) > MAX_PACKAGE_CACHE_BYTES {
		discard_checkpoint(cache, &cache.entries[0])
		ordered_remove(&cache.entries, 0)
	}
	checkpoint := Package_Checkpoint{index = index, state = c^}
	checkpoint.mark = virtual.arena_temp_begin(&c.semantic_arena)
	for block := c.semantic_arena.curr_block; block != nil; block = block.prev {
		bytes := make([]u8, int(block.used))
		copy(bytes, block.base[:block.used])
		append(&checkpoint.blocks, Arena_Block_Image{block = block, bytes = bytes})
		cache.bytes += u64(len(bytes))
	}
	append(&cache.entries, checkpoint)
}

@(private = "file")
discard_checkpoint :: proc(cache: ^Package_Check_Cache, checkpoint: ^Package_Checkpoint) {
	virtual.arena_temp_ignore(checkpoint.mark)
	for block in checkpoint.blocks {
		cache.bytes -= u64(len(block.bytes))
		delete(block.bytes)
	}
	delete(checkpoint.blocks)
}

@(private)
destroy_package_cache :: proc(cache: ^Package_Check_Cache) {
	context.allocator = cache.allocator if cache.allocator.procedure != nil else context.allocator
	for &checkpoint in cache.entries { discard_checkpoint(cache, &checkpoint) }
	delete(cache.entries)
	delete(cache.order)
	delete(cache.input)
	delete(cache.cwd)
	cache^ = {}
}

@(private)
remember_incremental_inputs :: proc(s: ^Compilation_Session, input: string, documentation: bool) {
	context.allocator = s.allocator
	cache := &s.package_cache
	cache.order = slice.clone(package_order(&s.compiler))
	cache.input = strings.clone(input)
	cache.cwd = os.get_working_directory(context.allocator) or_else ""
	cache.directory_root = is_source_directory(&s.compiler, input)
	cache.documentation = documentation
}

// `a_text` and `b_text` are the sources the two files were parsed from.
@(private = "file")
same_file_topology :: proc(a, b: ^File, a_text, b_text: string) -> bool {
	if a.package_name != b.package_name || len(a.attributes) != len(b.attributes) || selects_imports(b.items, false) { return false }
	// Which `parallel` blocks are selected decides whether `core:thread` loads.
	if (len(a.parallels) > 0) != (len(b.parallels) > 0) || selects_parallel_by_when(b.items, b.parallels) { return false }
	// File attributes include provider defaults, which discovery reads.
	for attribute, index in a.attributes {
		other := b.attributes[index].span
		if a_text[attribute.span.lo:attribute.span.hi] != b_text[other.lo:other.hi] { return false }
	}
	// Compare imports in source order, including aliases and literal spelling.
	a_imports := make([dynamic]^Item_Import, context.temp_allocator)
	b_imports := make([dynamic]^Item_Import, context.temp_allocator)
	collect_file_imports(a.items, &a_imports)
	collect_file_imports(b.items, &b_imports)
	if len(a_imports) != len(b_imports) { return false }
	for imported, index in a_imports {
		other := b_imports[index]
		if imported.path != other.path || imported.alias.text != other.alias.text { return false }
	}
	return true
}

@(private = "file")
collect_file_imports :: proc(items: []Item, imports: ^[dynamic]^Item_Import) {
	for item in items {
		#partial switch v in item {
		case ^Item_Import: append(imports, v)
		case ^Item_Block: collect_file_imports(v.items, imports)
		}
	}
}

@(private = "file")
same_discovery :: proc(s: ^Compilation_Session, probe: ^Compiler, input: string, documentation: bool) -> bool {
	c, cache := &s.compiler, &s.package_cache
	// Written paths are observable in source_location and reflection, even when
	// two spellings have the same Windows directory identity.
	if input != cache.input || documentation != cache.documentation ||
	   (os.get_working_directory(context.temp_allocator) or_else "") != cache.cwd ||
	   is_source_directory(c, input) != cache.directory_root { return false }
	if !register_project(probe, input) || len(probe.collections) != len(c.collections) { return false }
	for name, path in c.collections {
		if other, found := probe.collections[name]; !found || dir_key(canonical_dir(path)) != dir_key(canonical_dir(other)) { return false }
	}
	// This also detects newly nearer and previously absent transitive manifests.
	manifest_count := 0
	for source in c.sources {
		if filepath.base(source.path) != PROJECT_FILE { continue }
		if manifest_count >= len(probe.sources) { return false }
		other := probe.sources[manifest_count]
		if dir_key(canonical_dir(source.path)) != dir_key(canonical_dir(other.path)) || source.text != other.text { return false }
		manifest_count += 1
	}
	if manifest_count != len(probe.sources) { return false }
	for _, id in c.package_by_dir {
		if id == c.root_package && !cache.directory_root { continue }
		files := package_of(c, id).files
		dir := canonical_dir(path_dir(c.sources[files[0].file].path, context.temp_allocator))
		paths := package_sources(probe, dir)
		if len(paths) != len(files) { return false }
		for path, index in paths {
			if canonical_dir(path) != canonical_dir(c.sources[files[index].file].path) { return false }
		}
	}
	return true
}

@(private)
try_incremental_check :: proc(s: ^Compilation_Session, input: string, documentation: bool) -> bool {
	context.allocator = s.allocator
	cache, c := &s.package_cache, &s.compiler
	if len(cache.entries) == 0 { return false }
	// Probe every discovery and source input before modifying the cached state.
	probe: Compilation_Session
	defer destroy_session(&probe)
	if !init_session(&probe, s.config) { return false }
	context.temp_allocator = virtual.arena_allocator(&probe.scratch_arena)
	probe.compiler.source_overlays = &s.overlays
	if !same_discovery(s, &probe.compiler, input, documentation) { return false }
	texts := make(map[u32]string, context.temp_allocator)
	first := len(cache.order) - 1 // An unchanged check still reruns the final package.
	syntax_errors := false
	for id, position in cache.order {
		for file in package_of(c, id).files {
			path := c.sources[file.file].path
			index, loaded := load_source(&probe.compiler, path)
			if !loaded { return false }
			text := probe.compiler.sources[index].text
			texts[file.file] = text
			if text == c.sources[file.file].text { continue }
			errors := probe.compiler.error_count
			tokens := lex(&probe.compiler, index)
			parsed := parse(&probe.compiler, index, tokens)
			delete(tokens)
			syntax_errors ||= probe.compiler.error_count > errors
			same := same_file_topology(file, &parsed, c.sources[file.file].text, text)
			destroy_ast(&parsed)
			if !same { return false }
			first = min(first, position)
		}
	}
	// The nearest boundary at or before the edit. Checkpoints stop at a package
	// with errors, so an edit after it restarts there rather than from scratch.
	checkpoint_index := -1
	for entry, index in cache.entries { if entry.index <= first { checkpoint_index = index } }
	if checkpoint_index < 0 { return false }
	first = cache.entries[checkpoint_index].index
	// A batch reports syntax errors while loading, before the first package is
	// checked; here they follow the boundary's diagnostics. Checkpoints hold no
	// errors, so the order differs only if the boundary kept warnings.
	if syntax_errors && len(cache.entries[checkpoint_index].state.diagnostics) > 0 { return false }

	// Rewind exactly, including mutations to earlier types, generic templates,
	// registries and syntax. Saved allocator pointers still target this Compiler;
	// never relocate either the live compiler or a checkpoint into another one.
	for index := len(cache.entries) - 1; index > checkpoint_index; index -= 1 {
		discard_checkpoint(cache, &cache.entries[index])
	}
	resize(&cache.entries, checkpoint_index + 1)
	checkpoint := &cache.entries[checkpoint_index]
	virtual.arena_temp_end(checkpoint.mark)
	for block in checkpoint.blocks { copy(block.block.base[:len(block.bytes)], block.bytes) }
	virtual.arena_destroy(&c.analysis_arena)
	virtual.arena_destroy(&c.emission_arena)
	semantic_arena := c.semantic_arena
	c^ = checkpoint.state
	c.semantic_arena = semantic_arena
	c.analysis_arena, c.emission_arena = {}, {}
	if err := virtual.arena_init_growing(&c.analysis_arena); err != nil { panic("cannot reserve the compilation's analysis arena") }
	checkpoint.mark = virtual.arena_temp_begin(&c.semantic_arena)
	virtual.arena_destroy(&s.scratch_arena)
	context.temp_allocator = virtual.arena_allocator(&s.scratch_arena)

	Replacement :: struct { pkg: ^Package, index: int }
	replacements := make([dynamic]Replacement, context.temp_allocator)
	edited := make(map[Package_Id]bool, context.temp_allocator)
	for id in cache.order[first:] {
		pkg := package_of(c, id)
		for file, index in pkg.files {
			if texts[file.file] == c.sources[file.file].text { continue }
			append(&replacements, Replacement{pkg, index})
			edited[id] = true
		}
	}
	// A batch parses each file as it loads it, so syntax diagnostics follow the
	// loading order, which source indices record, not the dependency order.
	slice.sort_by(replacements[:], proc(a, b: Replacement) -> bool {
		return a.pkg.files[a.index].file < b.pkg.files[b.index].file
	})
	for entry in replacements {
		file := entry.pkg.files[entry.index]
		path := c.sources[file.file].path
		new_index := add_source(c, path, strings.clone(texts[file.file], c.semantic_allocator))
		c.sources[file.file] = c.sources[new_index]
		pop(&c.sources)
		tokens := lex(c, file.file)
		replacement := new(File, c.semantic_allocator)
		replacement^ = parse(c, file.file, tokens, c.semantic_allocator)
		delete(tokens)
		entry.pkg.files[entry.index] = replacement
		for old, parsed_index in c.parsed_files {
			if old == file { c.parsed_files[parsed_index] = replacement; break }
		}
	}
	for id in cache.order[first:] {
		pkg := package_of(c, id)
		if edited[id] {
			clear(&pkg.imports)
			pkg.bound_aliases = 0
			// Unchanged files in an edited multi-file package also bind again.
			for file in pkg.files {
				imports := make([dynamic]^Item_Import, context.temp_allocator)
				collect_file_imports(file.items, &imports)
				for imported in imports { imported.bound = false }
				file.parallel_bound = false
			}
			rebuild_active_items(c, pkg)
		}
	}
	k := Checker{c = c}
	_ = discover_imports(c, &k)
	// Retain the pre-edit boundary. Reload the complete suffix from the probe on
	// each rewind, including edits made since an earlier boundary was captured.
	// Recapturing it after parsing would accumulate obsolete syntax each edit.
	check_static_packages(&k, cache.order, first)
	finish_program_analysis(&k)
	allocator := virtual.arena_allocator(&s.stats_arena)
	s.check_stats.reused_packages = slice.clone(cache.order[:first], allocator)
	s.check_stats.rechecked_packages = slice.clone(cache.order[first:], allocator)
	return true
}
