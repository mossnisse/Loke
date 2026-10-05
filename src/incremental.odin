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
	directory_root: bool,
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
static_package_graph :: proc(c: ^Compiler) -> bool {
	if any_provider_selected(c) { return false }
	for file in c.parsed_files {
		if items_have_when(file.items) { return false }
	}
	return true
}

@(private = "file")
items_have_when :: proc(items: []Item) -> bool {
	for item in items {
		#partial switch v in item {
		case ^Item_When: return true
		case ^Item_Block: if items_have_when(v.items) { return true }
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
		prepare_package(k, order[index])
		check_package_bodies(k, order[index])
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
remember_incremental_inputs :: proc(s: ^Compilation_Session, input: string) {
	context.allocator = s.allocator
	cache := &s.package_cache
	cache.order = slice.clone(package_order(&s.compiler))
	cache.input = strings.clone(input)
	cache.cwd = os.get_current_directory()
	cache.directory_root = is_source_directory(&s.compiler, input)
}

@(private = "file")
same_file_topology :: proc(a, b: ^File) -> bool {
	if a.package_name != b.package_name || len(a.attributes) > 0 || len(b.attributes) > 0 || items_have_when(b.items) { return false }
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
same_discovery :: proc(s: ^Compilation_Session, probe: ^Compiler, input: string) -> bool {
	c, cache := &s.compiler, &s.package_cache
	// Written paths are observable in source_location and reflection, even when
	// two spellings have the same Windows directory identity.
	if input != cache.input ||
	   os.get_current_directory(context.temp_allocator) != cache.cwd ||
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
		dir := canonical_dir(filepath.dir(c.sources[files[0].file].path, context.temp_allocator))
		paths := package_sources(probe, dir)
		if len(paths) != len(files) { return false }
		for path, index in paths {
			if canonical_dir(path) != canonical_dir(c.sources[files[index].file].path) { return false }
		}
	}
	return true
}

@(private)
try_incremental_check :: proc(s: ^Compilation_Session, input: string) -> bool {
	context.allocator = s.allocator
	cache, c := &s.package_cache, &s.compiler
	if len(cache.entries) == 0 { return false }
	// Probe every discovery and source input before modifying the cached state.
	probe: Compilation_Session
	defer destroy_session(&probe)
	if !init_session(&probe, s.config) { return false }
	context.temp_allocator = virtual.arena_allocator(&probe.scratch_arena)
	probe.compiler.source_overlays = &s.overlays
	if !same_discovery(s, &probe.compiler, input) { return false }
	texts := make(map[u32]string, context.temp_allocator)
	first := len(cache.order) - 1 // An unchanged check still reruns the final package.
	for id, position in cache.order {
		for file in package_of(c, id).files {
			path := c.sources[file.file].path
			index, loaded := load_source(&probe.compiler, path)
			if !loaded { return false }
			text := probe.compiler.sources[index].text
			texts[file.file] = text
			if text == c.sources[file.file].text { continue }
			tokens := lex(&probe.compiler, index)
			parsed := parse(&probe.compiler, index, tokens)
			delete(tokens)
			same := probe.compiler.error_count == 0 && same_file_topology(file, &parsed)
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

	for id in cache.order[first:] {
		pkg := package_of(c, id)
		edited := false
		for file, index in pkg.files {
			text := texts[file.file]
			if text == c.sources[file.file].text { continue }
			edited = true
			path := c.sources[file.file].path
			new_index := add_source(c, path, strings.clone(text, c.semantic_allocator))
			c.sources[file.file] = c.sources[new_index]
			pop(&c.sources)
			tokens := lex(c, file.file)
			replacement := new(File, c.semantic_allocator)
			replacement^ = parse(c, file.file, tokens, c.semantic_allocator)
			delete(tokens)
			pkg.files[index] = replacement
			for old, parsed_index in c.parsed_files {
				if old == file { c.parsed_files[parsed_index] = replacement; break }
			}
		}
		if edited {
			clear(&pkg.imports)
			pkg.bound_aliases = 0
			// Unchanged files in an edited multi-file package also bind again.
			for file in pkg.files {
				imports := make([dynamic]^Item_Import, context.temp_allocator)
				collect_file_imports(file.items, &imports)
				for imported in imports { imported.bound = false }
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
