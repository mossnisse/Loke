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

@(private)
cache_package_checkpoint :: proc(c: ^Compiler, index: int) {
	cache := c.package_cache
	context.allocator = cache.allocator
	// A rewind keeps its pre-edit boundary: recapturing after reparsing would accumulate obsolete syntax.
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

@(private = "file")
same_file_topology :: proc(a, b: ^File, a_text, b_text: string) -> bool {
	if a.package_name != b.package_name || len(a.attributes) != len(b.attributes) || when_holds_dependency(b) { return false }
	if (len(a.parallels) > 0) != (len(b.parallels) > 0) { return false }
	// File attributes include provider defaults, which discovery reads.
	for attribute, index in a.attributes {
		other := b.attributes[index].span
		if a_text[attribute.span.lo:attribute.span.hi] != b_text[other.lo:other.hi] { return false }
	}
	if len(a.imports) != len(b.imports) { return false }
	for imported, index in a.imports {
		other := b.imports[index]
		if imported.path != other.path || imported.alias.text != other.alias.text { return false }
	}
	return true
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

// Each loaded file's current text by source index, and the earliest edited
// package's position in `order`. Fails if an edit changes a file's topology.
@(private = "file")
compare_sources :: proc(c, probe: ^Compiler, order: []Package_Id) -> (texts: []string, first: int, syntax_errors, ok: bool) {
	texts = make([]string, len(c.sources), context.temp_allocator)
	first = len(order) - 1 // An unchanged check still reruns the final package.
	for id, position in order {
		for file in package_of(c, id).files {
			path := c.sources[file.file].path
			index, loaded := load_source(probe, path)
			if !loaded { return }
			text := probe.sources[index].text
			texts[file.file] = text
			if text == c.sources[file.file].text { continue }
			errors := probe.error_count
			tokens := lex(probe, index)
			parsed := parse(probe, index, tokens)
			delete(tokens)
			syntax_errors ||= probe.error_count > errors
			same := same_file_topology(file, &parsed, c.sources[file.file].text, text)
			destroy_ast(&parsed)
			if !same { return }
			first = min(first, position)
		}
	}
	return texts, first, syntax_errors, true
}

// Rewind exactly, including mutations to earlier types, generic templates, registries and syntax.
@(private = "file")
restore_checkpoint :: proc(s: ^Compilation_Session, checkpoint_index: int) {
	cache, c := &s.package_cache, &s.compiler
	for &entry in cache.entries[checkpoint_index + 1:] { discard_checkpoint(cache, &entry) }
	resize(&cache.entries, checkpoint_index + 1)
	checkpoint := &cache.entries[checkpoint_index]
	virtual.arena_temp_end(checkpoint.mark)
	for block in checkpoint.blocks { copy(block.block.base[:len(block.bytes)], block.bytes) }
	destroy_analysis_arenas(c)
	virtual.arena_destroy(&c.emission_arena)
	semantic_arena := c.semantic_arena
	c^ = checkpoint.state
	c.semantic_arena = semantic_arena
	c.emission_arena = {}
	init_analysis_arenas(c)
	checkpoint.mark = virtual.arena_temp_begin(&c.semantic_arena)
	virtual.arena_destroy(&s.scratch_arena)
}

// Replaces the files whose text differs from the restored boundary's, and has
// their packages bind again.
@(private = "file")
reparse_edited_files :: proc(c: ^Compiler, order: []Package_Id, texts: []string) {
	Replacement :: struct { pkg: ^Package, index: int }
	replacements := make([dynamic]Replacement, context.temp_allocator)
	for id in order {
		pkg := package_of(c, id)
		for file, index in pkg.files {
			if texts[file.file] == c.sources[file.file].text { continue }
			append(&replacements, Replacement{pkg, index})
			unbind_package(pkg)
		}
	}
	// In loading order (source indices), as a batch reports syntax diagnostics.
	slice.sort_by(replacements[:], proc(a, b: Replacement) -> bool {
		return a.pkg.files[a.index].file < b.pkg.files[b.index].file
	})
	for entry in replacements {
		file := entry.pkg.files[entry.index]
		c.sources[file.file] = make_source(c, c.sources[file.file].path, strings.clone(texts[file.file], c.semantic_allocator))
		replacement := parse_loaded_source(c, file.file)
		entry.pkg.files[entry.index] = replacement
		for old, parsed_index in c.parsed_files {
			if old == file { c.parsed_files[parsed_index] = replacement; break }
		}
	}
	for entry in replacements { rebuild_active_items(c, entry.pkg) }
}

// Unchanged files in an edited multi-file package also bind again.
@(private = "file")
unbind_package :: proc(pkg: ^Package) {
	clear(&pkg.imports)
	for file in pkg.files {
		for imported in file.imports { imported.bound = false }
		file.parallel_bound = false
	}
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
	texts, first, syntax_errors := compare_sources(c, &probe.compiler, cache.order) or_return
	// Checkpoints stop at errors, so an edit after one restarts there.
	checkpoint_index := -1
	for entry, index in cache.entries { if entry.index <= first { checkpoint_index = index } }
	if checkpoint_index < 0 { return false }
	first = cache.entries[checkpoint_index].index
	// A batch reports syntax errors before any warning (compiler-architecture.md "Incremental checking").
	if syntax_errors && len(cache.entries[checkpoint_index].state.diagnostics) > 0 { return false }

	restore_checkpoint(s, checkpoint_index)
	context.temp_allocator = virtual.arena_allocator(&s.scratch_arena)
	reparse_edited_files(c, cache.order[first:], texts)
	k := Checker{c = c}
	_ = discover_imports(c, &k)
	check_static_packages(&k, cache.order, first)
	finish_program_analysis(&k)
	allocator := virtual.arena_allocator(&s.stats_arena)
	s.check_stats.reused_packages = slice.clone(cache.order[:first], allocator)
	s.check_stats.rechecked_packages = slice.clone(cache.order[first:], allocator)
	return true
}
