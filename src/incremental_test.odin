package lokec

import "core:os"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
session_incremental_reuses_dependencies_and_reclaims_edits :: proc(t: ^testing.T) {
	root := session_fixture(t, "incremental")
	if root == "" { return }
	defer os.remove_all(root)
	for name in ([]string{"steady", "values", "bridge"}) {
		if !testing.expect(t, os.make_directory_all(join_path({root, name}, context.temp_allocator)) == nil) { return }
	}
	path := join_path({root, "main.loke"}, context.temp_allocator)
	values := join_path({root, "values", "values.loke"}, context.temp_allocator)
	bridge := join_path({root, "bridge", "bridge.loke"}, context.temp_allocator)
	main_text := `package main; import "steady"; import "bridge";
main :: proc() {
    assert(steady.answer() == 8);
    when (bridge.answer() == 42) { assert(bridge.answer() == 42); }
    else { assert(bridge.answer() == 61); }
}`
	values_text := "package values; @(public) identity :: proc(value: $T) -> T { return value + 1; }"
	bridge_text := `package bridge; import "../values"; @(public) answer :: proc() -> int { return values.identity(41); }`
	if !write_session_source(t, path, main_text) ||
	   !write_session_source(t, values, values_text) ||
	   !write_session_source(t, bridge, bridge_text) ||
	   !write_session_source(t, join_path({root, "steady", "steady.loke"}, context.temp_allocator), "package steady; @(public) answer :: proc() -> int { return 8; }") { return }
	config := session_test_config()
	config.debug_info = true
	s: Compilation_Session
	defer destroy_session(&s)
	if !testing.expect(t, init_session(&s, config)) { return }
	previous := expect_session_matches_fresh(t, &s, path, config, true)
	stats := session_check_stats(&s)
	testing.expect(t, len(stats.reused_packages) == 0 && len(stats.rechecked_packages) == len(s.compiler.packages) - 1)
	testing.expect(t, stats.cache_bytes > 0 && stats.cache_bytes <= MAX_PACKAGE_CACHE_BYTES)
	steady := s.compiler.package_by_dir[dir_key(canonical_dir(join_path({root, "steady"}, context.temp_allocator)))]
	values_id := s.compiler.package_by_dir[dir_key(canonical_dir(join_path({root, "values"}, context.temp_allocator)))]
	bridge_id := s.compiler.package_by_dir[dir_key(canonical_dir(join_path({root, "bridge"}, context.temp_allocator)))]
	for edit in 0 ..< 8 {
		switch edit {
		case 0: if !write_session_source(t, path, strings.concatenate({main_text, "\nextra :: proc() -> int { return 123; }"}, context.temp_allocator)) { return }
		case 1:
			text, _ := strings.replace_all(values_text, "value + 1", "value + 20", context.temp_allocator)
			if !write_session_source(t, values, text) { return }
		case 2:
			text, _ := strings.replace_all(bridge_text, "values.identity(41)", "missing", context.temp_allocator)
			if !write_session_source(t, bridge, text) { return }
		case 3: if !write_session_source(t, bridge, bridge_text) { return }
		case 4: if !write_session_source(t, values, values_text) { return }
		case 5: if !write_session_source(t, path, main_text) { return }
		case 6:
			text, _ := strings.replace_all(values_text, "-> T {", "-> T where false {", context.temp_allocator)
			if !write_session_source(t, values, text) { return }
		case 7: if !write_session_source(t, values, values_text) { return }
		}
		current := expect_session_matches_fresh(t, &s, path, config, edit != 2 && edit != 6)
		_, stale := query_file(&s, previous, path)
		testing.expect(t, !stale && current.id != previous.id)
		previous = current
		stats = session_check_stats(&s)
		testing.expect(t, slice.contains(stats.reused_packages, steady), "an unrelated package was rechecked")
		testing.expect(t, slice.contains(stats.rechecked_packages, s.compiler.root_package))
		testing.expect_value(t, slice.contains(stats.rechecked_packages, values_id), edit == 1 || edit == 4 || edit >= 6)
		testing.expect_value(t, slice.contains(stats.rechecked_packages, bridge_id), (edit >= 1 && edit <= 4) || edit >= 6)
	}
	// An unchanged check still issues a new snapshot and reruns final analyses.
	expect_session_matches_fresh(t, &s, path, config, true)
	testing.expect_value(t, len(session_check_stats(&s).rechecked_packages), 1)
	// Repeated arbitrary-length overlays must not retain obsolete syntax,
	// diagnostics, generic instances, query indexes, or emitted modules.
	semantic, cached: [2]u64
	for edit in 0 ..< 40 {
		variant := edit % 2
		text := main_text if variant == 0 else strings.concatenate({main_text, "\nextra :: proc() -> int { return 123; }"}, context.temp_allocator)
		testing.expect(t, set_session_overlay(&s, path, text))
		// The fresh oracle consumes the identical overlay as disk bytes.
		if !write_session_source(t, path, text) { return }
		current := expect_session_matches_fresh(t, &s, path, config, true)
		_, queried := query_file(&s, current, path)
		testing.expect(t, queried)
		stats = session_check_stats(&s)
		testing.expect_value(t, len(stats.rechecked_packages), 1)
		if edit < 2 {
			semantic[variant], cached[variant] = stats.semantic_bytes, stats.cache_bytes
		} else {
			testing.expect_value(t, stats.semantic_bytes, semantic[variant])
			testing.expect_value(t, stats.cache_bytes, cached[variant])
		}
	}
	// Invalidation expires views but keeps checkpoints: the next check revalidates.
	testing.expect(t, invalidate_session(&s))
	testing.expect(t, session_check_stats(&s).cache_bytes > 0)
	expect_session_matches_fresh(t, &s, path, config, true)
	testing.expect(t, slice.contains(session_check_stats(&s).reused_packages, steady))
	destroy_session(&s)
	testing.expect(t, s.compiler.semantic_arena.curr_block == nil && s.package_cache.bytes == 0 && len(s.package_cache.entries) == 0)
}

// Checkpoints stop at a package with errors. An edit after it restarts from the
// nearest earlier boundary, not from scratch.
@(test)
session_incremental_reuses_prefix_before_an_error :: proc(t: ^testing.T) {
	root := session_fixture(t, "incremental-error-prefix")
	if root == "" { return }
	defer os.remove_all(root)
	if !testing.expect(t, os.make_directory_all(join_path({root, "dep"}, context.temp_allocator)) == nil) { return }
	path := join_path({root, "main.loke"}, context.temp_allocator)
	main_text := `package main; import "dep"; main :: proc() { assert(dep.answer() == 1); }`
	if !write_session_source(t, join_path({root, "dep", "dep.loke"}, context.temp_allocator), "package dep; @(public) answer :: proc() -> int { return missing; }") ||
	   !write_session_source(t, path, main_text) { return }
	config := session_test_config()
	s: Compilation_Session
	defer destroy_session(&s)
	if !testing.expect(t, init_session(&s, config)) { return }
	expect_session_matches_fresh(t, &s, path, config, false)
	edited, _ := strings.replace_all(main_text, "== 1", "== 2", context.temp_allocator)
	if !write_session_source(t, path, edited) { return }
	expect_session_matches_fresh(t, &s, path, config, false)
	dep := s.compiler.package_by_dir[dir_key(canonical_dir(join_path({root, "dep"}, context.temp_allocator)))]
	stats := session_check_stats(&s)
	testing.expect(t, len(stats.reused_packages) > 0, "an edit after a failing dependency rechecked everything")
	testing.expect(t, slice.contains(stats.rechecked_packages, dep) && slice.contains(stats.rechecked_packages, s.compiler.root_package))
}

@(test)
session_incremental_discovery_changes_use_full_checks :: proc(t: ^testing.T) {
	root := session_fixture(t, "incremental-discovery")
	if root == "" { return }
	defer os.remove_all(root)
	lib := join_path({root, "lib"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory_all(lib) == nil) { return }
	path := join_path({root, "main.loke"}, context.temp_allocator)
	other := join_path({lib, "other.loke"}, context.temp_allocator)
	main_text := `package main; import "lib"; main :: proc() { assert(lib.answer() > 0); }`
	if !write_session_source(t, path, main_text) ||
	   !write_session_source(t, join_path({lib, "lib.loke"}, context.temp_allocator), "package lib; @(public) answer :: proc() -> int { return 1; }") { return }
	config := session_test_config()
	s: Compilation_Session
	defer destroy_session(&s)
	if !testing.expect(t, init_session(&s, config)) { return }
	for edit in 0 ..< 10 {
		switch edit {
		case 1: if !write_session_source(t, other, "package lib; other :: 2;") { return }
		case 2: if !testing.expect(t, os.remove(other) == nil) { return }
		case 3: if !write_session_source(t, path, "package main; main :: proc() {}") { return }
		case 4: if !write_session_source(t, path, main_text) { return }
		case 5: if !write_session_source(t, path, strings.concatenate({main_text, "\nwhen (true) { selected :: 1; }"}, context.temp_allocator)) { return }
		case 6: if !write_session_source(t, path, main_text) { return }
		case 7: if !write_session_source(t, path, "package main; main :: proc() {") { return }
		case 8: if !write_session_source(t, path, main_text) { return }
		case 9: if !write_session_source(t, join_path({root, PROJECT_FILE}, context.temp_allocator), "# newly nearer manifest\n") { return }
		}
		expect_session_matches_fresh(t, &s, path, config, edit != 7)
		testing.expectf(t, len(session_check_stats(&s).reused_packages) == 0, "edit %d reused an invalid graph", edit)
	}
	// Switching to documentation or batch checking clears all checkpoints.
	testing.expect(t, check_session_incremental(&s, path, documentation = true))
	testing.expect(t, !s.ready && session_check_stats(&s).cache_bytes == 0)
	testing.expect(t, check_session_incremental(&s, path))
	testing.expect(t, check_session(&s, path))
	testing.expect_value(t, session_check_stats(&s).cache_bytes, u64(0))
	// Path spelling is an input to source_location and reflection.
	testing.expect(t, check_session_incremental(&s, path))
	alias := strings.concatenate({root, "/./main.loke"}, context.temp_allocator)
	expect_session_matches_fresh(t, &s, alias, config, true)
	testing.expect_value(t, len(session_check_stats(&s).reused_packages), 0)
}

@(test)
session_incremental_cache_limit_evicts_old_boundaries :: proc(t: ^testing.T) {
	cache := Package_Check_Cache{allocator = context.allocator}
	c := Compiler{package_cache = &cache}
	defer destroy_compilation(&c)
	defer destroy_package_cache(&cache)
	init_semantic_stores(&c)
	// More than one arena block, and enough payload to evict older images.
	padding := make([]u8, 17 * 1024 * 1024, c.semantic_allocator)
	padding[0], padding[len(padding) - 1] = 1, 2
	for index in 0 ..< 5 { cache_package_checkpoint(&c, index) }
	testing.expect_value(t, len(cache.entries), 3)
	testing.expect_value(t, cache.entries[0].index, 2)
	testing.expect(t, cache.bytes <= MAX_PACKAGE_CACHE_BYTES)
	testing.expect(t, len(cache.entries[0].blocks) > 1)
	destroy_package_cache(&cache)
	virtual.arena_check_temp(&c.semantic_arena)
	testing.expect(t, len(cache.entries) == 0 && cache.bytes == 0)
}

@(test)
session_incremental_rebuilds_final_registry_demands :: proc(t: ^testing.T) {
	root := session_fixture(t, "incremental-registries")
	if root == "" { return }
	defer os.remove_all(root)
	data_dir := join_path({root, "data"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory_all(data_dir) == nil) { return }
	path := join_path({root, "main.loke"}, context.temp_allocator)
	if !write_session_source(t, join_path({data_dir, "data.loke"}, context.temp_allocator), "@(public) package data; Value :: struct { item: int }") { return }
	rich := `package main; import "core:fmt"; import "data";
main :: proc() { value := data.Value{item = 1}; fmt.println(value, typeid_of(data.Value)); assert(type_info_of(typeid_of(data.Value)).id == typeid_of(data.Value)); }`
	simple := `package main; import "core:fmt"; import "data"; main :: proc() {}`
	config := session_test_config()
	s: Compilation_Session
	defer destroy_session(&s)
	if !testing.expect(t, init_session(&s, config)) { return }
	rich_typeids := 0
	for edit in 0 ..< 3 {
		if !write_session_source(t, path, simple if edit == 1 else rich) { return }
		expect_session_matches_fresh(t, &s, path, config, true)
		if edit == 0 { rich_typeids = len(s.compiler.typeid_order) }
		if edit == 1 { testing.expect(t, len(s.compiler.typeid_order) < rich_typeids, "unused metadata survived the edit") }
		if edit > 0 { testing.expect_value(t, len(session_check_stats(&s).rechecked_packages), 1) }
	}
}
