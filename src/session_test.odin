package lokec

import "core:fmt"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(private = "file")
session_test_config :: proc() -> Compilation_Config {
	config := DEFAULT_COMPILATION_CONFIG
	config.collections = make([]string, 2, context.temp_allocator)
	config.collections[0] = fmt.tprintf("base=%s", canonical_dir("base"))
	config.collections[1] = fmt.tprintf("core=%s", canonical_dir("core"))
	return config
}

@(private = "file")
session_fixture :: proc(t: ^testing.T, name: string) -> string {
	root := fmt.tprintf("tests/tmp/session-%d-%s", os2.get_pid(), name)
	if !testing.expect(t, os2.make_directory_all(root) == nil) { return "" }
	return root
}

@(private = "file")
write_session_source :: proc(t: ^testing.T, path, text: string) -> bool {
	return testing.expect(t, os2.write_entire_file(path, transmute([]u8)text) == nil)
}

@(private = "file")
expect_session_diagnostics :: proc(t: ^testing.T, a, b: ^Compiler) {
	testing.expect_value(t, a.error_count, b.error_count)
	testing.expect_value(t, len(a.sources), len(b.sources))
	if !testing.expect_value(t, len(a.diagnostics), len(b.diagnostics)) { return }
	for diagnostic, index in a.diagnostics {
		other := b.diagnostics[index]
		testing.expect_value(t, diagnostic.severity, other.severity)
		testing.expect_value(t, diagnostic.code, other.code)
		testing.expect_value(t, diagnostic.message, other.message)
		testing.expect_value(t, diagnostic.label, other.label)
		testing.expect_value(t, diagnostic.span, other.span)
		if !testing.expect_value(t, len(diagnostic.notes), len(other.notes)) { continue }
		for note, note_index in diagnostic.notes {
			testing.expect_value(t, note, other.notes[note_index])
		}
	}
}

// Rechecking reloads both package contents and manifest-selected dependencies.
// Compare each result, including a broken edit, with a new batch session.
@(test)
session_rechecks_match_fresh_compilations :: proc(t: ^testing.T) {
	root := session_fixture(t, "edits")
	if root == "" { return }
	defer os2.remove_all(root)
	app := filepath.join({root, "app"}, context.temp_allocator)
	for dir in ([]string{app, filepath.join({root, "lib", "values"}, context.temp_allocator), filepath.join({root, "replacement", "values"}, context.temp_allocator)}) {
		if !testing.expect(t, os2.make_directory_all(dir) == nil) { return }
	}
	path := filepath.join({app, "main.loke"}, context.temp_allocator)
	manifest := filepath.join({app, "loke.project"}, context.temp_allocator)
	valid := `package main;
import "library:values";
main :: proc() {
    when (build_config(FEATURE, false)) { assert(LOKE_DEBUG); }
    assert(values.identity(7) == 7);
}`
	if !write_session_source(t, path, valid) ||
	   !write_session_source(t, manifest, "require library ../lib\n") ||
	   !write_session_source(t, filepath.join({root, "lib", "values", "values.loke"}, context.temp_allocator),
	                         "package values; @(public) identity :: proc(value: $T) -> T { return value; }") ||
	   !write_session_source(t, filepath.join({root, "replacement", "values", "values.loke"}, context.temp_allocator),
	                         "package values; @(public) identity :: proc(value: $T) -> T { return value + 2; }") { return }

	config := session_test_config()
	config.defines = []string{"FEATURE=true"}
	config.debug, config.opt_mode, config.panic_unwind = true, .Size, false
	// All caller-owned configuration storage may disappear after initialization.
	owned := config
	owned.defines = make([]string, len(config.defines))
	owned.collections = make([]string, len(config.collections))
	for entry, index in config.defines { owned.defines[index] = strings.clone(entry) }
	for entry, index in config.collections { owned.collections[index] = strings.clone(entry) }
	s: Compilation_Session
	initialized := init_session(&s, owned)
	for entry in owned.defines { delete(entry) }
	for entry in owned.collections { delete(entry) }
	delete(owned.defines)
	delete(owned.collections)
	defer destroy_session(&s)
	if !testing.expect(t, initialized) { return }
	testing.expect(t, !init_session(&s), "initializing a live session must not replace its state")
	testing.expect(t, s.compiler.debug && s.compiler.opt_mode == .Size && !s.compiler.panic_unwind)
	previous_ir := ""
	defer delete(previous_ir)
	for edit in 0 ..< 5 {
		switch edit {
		case 1:
			if !write_session_source(t, filepath.join({root, "lib", "values", "values.loke"}, context.temp_allocator),
			                         "package values; @(public) identity :: proc(value: $T) -> T { return value + 1; }") { return }
		case 2:
			if !write_session_source(t, manifest, "require library ../replacement\n") { return }
		case 3:
			if !write_session_source(t, path, "package main; main :: proc() { missing(); }") { return }
		case 4:
			if !write_session_source(t, path, valid) { return }
		}
		input := strings.clone(app)
		checked := check_session(&s, input)
		delete(input)
		fresh: Compilation_Session
		if !testing.expect(t, init_session(&fresh, config)) { destroy_session(&fresh); return }
		fresh_checked := check_session(&fresh, app)
		if checked != (edit != 3) { report(&s.compiler) }
		testing.expect_value(t, checked, edit != 3)
		testing.expect_value(t, checked, fresh_checked)
		expect_session_diagnostics(t, &s.compiler, &fresh.compiler)
		ir, emitted := emit_session_ir(&s)
		fresh_ir, fresh_emitted := emit_session_ir(&fresh)
		testing.expect_value(t, emitted, checked)
		testing.expect_value(t, emitted, fresh_emitted)
		testing.expect_value(t, ir, fresh_ir)
		if emitted {
			again, again_emitted := emit_session_ir(&s)
			testing.expect(t, again_emitted && again == ir, "repeated emission changed the checked program")
			if edit == 1 || edit == 2 {
				testing.expect(t, ir != previous_ir, "the edit reused obsolete IR")
			}
			delete(previous_ir)
			previous_ir = strings.clone(ir)
		}
		destroy_session(&fresh)
	}
}

@(test)
session_check_modes_preserve_entry_requirements :: proc(t: ^testing.T) {
	root := session_fixture(t, "modes")
	if root == "" { return }
	defer os2.remove_all(root)
	path := filepath.join({root, "library.loke"}, context.temp_allocator)
	if !write_session_source(t, path, "package library; @(public) answer :: proc() -> int { return 42; }") { return }
	s: Compilation_Session
	defer destroy_session(&s)
	testing.expect(t, !check_session(&s, path))
	_, emitted := emit_session_ir(&s)
	testing.expect(t, !emitted)
	if !testing.expect(t, init_session(&s, session_test_config())) { return }
	if !testing.expect(t, check_session(&s, path, documentation = true)) { report(&s.compiler); return }
	page := document_project(&s.compiler, s.compiler.root_package)
	testing.expect(t, strings.contains(page, "answer"))
	delete(page)
	_, emitted = emit_session_ir(&s)
	testing.expect(t, !emitted, "documentation checking must not enable executable emission")
	testing.expect(t, !check_session(&s, path), "an executable still requires main")
	testing.expect(t, s.compiler.error_count > 0)
	destroy_session(&s)
	config := session_test_config()
	config.build_mode = .Obj
	if !testing.expect(t, init_session(&s, config) && check_session(&s, path)) { return }
	ir, generated := emit_session_ir(&s)
	testing.expect(t, generated && !strings.contains(ir, "define i32 @main("), "an object must not emit process entry")
	output := filepath.join({root, "library.obj"}, context.temp_allocator)
	testing.expect_value(t, emit_session(&s, Emission_Options{output = output, emit_ll = true}), 0)
	ll_path := replace_ext(output, ".ll")
	defer delete(ll_path)
	bytes, read_error := os2.read_entire_file(ll_path, context.allocator)
	testing.expect(t, read_error == nil && string(bytes) == ir, "artifact emission differs from in-memory emission")
	delete(bytes)
	testing.expect_value(t, emit_session(&s, Emission_Options{}), 2)
	testing.expect(t, s.compiler.error_count == 1 && s.compiler.diagnostics[0].code == "L0401")
	testing.expect(t, check_session(&s, path), "a new check must clear emission failures")
	_, generated = emit_session_ir(&s)
	testing.expect(t, generated)
}

// Odin's test allocator checks ordinary allocations and frees in this loop;
// the arena assertions also check release of virtual reservations.
@(test)
session_creation_and_destruction_release_owned_state :: proc(t: ^testing.T) {
	root := session_fixture(t, "lifetime")
	if root == "" { return }
	defer os2.remove_all(root)
	path := filepath.join({root, "main.loke"}, context.temp_allocator)
	if !write_session_source(t, path, "package main; main :: proc() {}") { return }
	for iteration in 0 ..< 12 {
		s: Compilation_Session
		config := session_test_config()
		if iteration % 3 == 0 { config.defines = []string{"INVALID-NAME=1"} }
		initialized := init_session(&s, config)
		if initialized {
			testing.expect(t, check_session(&s, path))
			_, emitted := emit_session_ir(&s)
			testing.expect(t, emitted)
		} else {
			testing.expect(t, s.compiler.error_count == 1 && s.compiler.diagnostics[0].code == "L0388")
			testing.expect(t, !check_session(&s, path))
		}
		destroy_session(&s)
		testing.expect(t, !s.initialized && !s.compiler.semantic_initialized && len(s.compiler.sources) == 0 && len(s.compiler.diagnostics) == 0)
		testing.expect(t, s.configuration_arena.curr_block == nil && s.scratch_arena.curr_block == nil && s.compiler.emission_arena.curr_block == nil)
		destroy_session(&s)
	}
}

@(private = "file")
snapshot_test_symbol :: proc(t: ^testing.T, s: ^Compilation_Session, snapshot: Compilation_Snapshot, file: u32, name: string) -> Symbol_Handle {
	handles, found := query_symbols(s, snapshot, file)
	if !testing.expect(t, found) { return {} }
	for handle in handles {
		if symbol, ok := query_symbol(s, handle); ok && symbol.name == name { return handle }
	}
	testing.expect(t, false, fmt.tprintf("missing query symbol %s", name))
	return {}
}

@(private = "file")
snapshot_test_position :: proc(t: ^testing.T, s: ^Compilation_Session, snapshot: Compilation_Snapshot, file: u32, text, needle: string) -> Query_Position {
	offset := strings.index(text, needle)
	if !testing.expect(t, offset >= 0) { return {} }
	position, found := query_at(s, snapshot, file, u32(offset))
	testing.expect(t, found, fmt.tprintf("missing query at %s", needle))
	return position
}

// The same source loader checks overlays and disk, and the same package loader
// discovers both. Caller memory, alias spelling, and unsaved directories matter.
@(test)
session_overlays_match_disk_compilation :: proc(t: ^testing.T) {
	root := session_fixture(t, "overlays")
	if root == "" { return }
	defer os2.remove_all(root)
	path := filepath.join({root, "main.loke"}, context.temp_allocator)
	extra := filepath.join({root, "extra.loke"}, context.temp_allocator)
	dependency := filepath.join({root, "lib", "values", "values.loke"}, context.temp_allocator)
	disk := "package main; main :: proc() {}"
	text := `package main; import "library:values"; main :: proc() { assert(values.identity(answer) == 42); }`
	lib_text := "package values; @(public) identity :: proc(value: $T) -> T { return value; }"
	if !write_session_source(t, path, disk) || !write_session_source(t, filepath.join({root, "loke.project"}, context.temp_allocator), "require library ./lib\n") { return }
	s: Compilation_Session
	defer destroy_session(&s)
	if !testing.expect(t, init_session(&s, session_test_config())) { return }
	owned_path, owned_text := strings.clone(path), strings.clone(text)
	testing.expect(t, set_session_overlay(&s, owned_path, owned_text))
	delete(owned_path)
	delete(owned_text)
	alias := strings.to_upper(canonical_dir(path), context.temp_allocator)
	testing.expect(t, set_session_overlay(&s, alias, text))
	testing.expect_value(t, len(s.overlays), 1)
	testing.expect(t, set_session_overlay(&s, extra, "package main; answer :: 42;"))
	testing.expect(t, set_session_overlay(&s, dependency, lib_text))
	if !testing.expect(t, check_session(&s, root)) { report(&s.compiler); return }
	snapshot, captured := session_snapshot(&s)
	if !testing.expect(t, captured) { return }
	file, found := query_file(&s, snapshot, alias)
	if !testing.expect(t, found) { return }
	source: Query_Source
	source, found = query_source(&s, snapshot, file)
	testing.expect(t, found && source.text == text)
	bytes, read_error := os2.read_entire_file(path, context.allocator)
	testing.expect(t, read_error == nil && string(bytes) == disk, "overlay changed the disk")
	delete(bytes)
	testing.expect(t, !os2.exists(dependency), "checking created an unsaved directory")
	// Removing the only unsaved source removes that package from discovery.
	testing.expect(t, remove_session_overlay(&s, dependency) && !check_session(&s, root))
	_, found = query_source(&s, snapshot, file)
	testing.expect(t, !found)
	testing.expect(t, set_session_overlay(&s, dependency, lib_text) && check_session(&s, root))
	snapshot, captured = session_snapshot(&s)
	testing.expect(t, captured)
	file, found = query_file(&s, snapshot, path)
	testing.expect(t, found)
	source, found = query_source(&s, snapshot, file)
	testing.expect(t, found)
	ir, emitted := emit_session_ir(&s)
	if !testing.expect(t, emitted) { return }
	// Materialize exactly the same program to compare with a fresh batch check.
	if !testing.expect(t, os2.make_directory_all(filepath.dir(dependency, context.temp_allocator)) == nil) ||
	   !write_session_source(t, path, text) || !write_session_source(t, extra, "package main; answer :: 42;") ||
	   !write_session_source(t, dependency, lib_text) { return }
	fresh: Compilation_Session
	defer destroy_session(&fresh)
	if !testing.expect(t, init_session(&fresh, session_test_config()) && check_session(&fresh, root)) { report(&fresh.compiler); return }
	expect_session_diagnostics(t, &s.compiler, &fresh.compiler)
	fresh_ir, fresh_emitted := emit_session_ir(&fresh)
	testing.expect(t, fresh_emitted && fresh_ir == ir, "overlay and disk produced different IR")
	// A no-op removal preserves handles; an edit invalidates emission and queries.
	testing.expect(t, !remove_session_overlay(&s, "absent.loke"))
	_, found = query_source(&s, snapshot, file)
	testing.expect(t, found)
	testing.expect(t, set_session_overlay(&s, path, source.text))
	_, found = query_source(&s, snapshot, file)
	testing.expect(t, !found)
	_, emitted = emit_session_ir(&s)
	testing.expect(t, !emitted)
	testing.expect(t, remove_session_overlay(&s, alias))
	testing.expect_value(t, len(s.overlays), 2)
	testing.expect(t, check_session(&s, root))
	again, again_emitted := emit_session_ir(&s)
	testing.expect(t, again_emitted && again == fresh_ir)
}

@(test)
session_snapshot_queries_follow_checked_bindings :: proc(t: ^testing.T) {
	root := session_fixture(t, "queries")
	if root == "" { return }
	defer os2.remove_all(root)
	path := filepath.join({root, "unsaved", "main.loke"}, context.temp_allocator)
	dependency := filepath.join({root, "unsaved", "values", "values.loke"}, context.temp_allocator)
	text := `package main;
import "values";
Box :: struct { item: int }
Wrap :: struct($Element: type) { content: Element }
plain :: proc(value: int = 1) -> int { return value; }
floating :: proc(value: f64) -> f64 { return value; }
pick :: proc{plain, floating};
when (false) { inactive :: proc() { unknown(); } }
value :: 9;
other :: proc() -> int { value := 8; return value; }
main :: proc() {
    value := 7;
    box := Box{item = value};
    wrapped: Wrap(int) = {content = 1};
    assert(wrapped.content == 1);
    assert(box.item == plain());
    assert(values.identity(value) == value);
    assert(values.identity(f64(2)) == f64(2));
    assert(pick(1) == 1);
    foreach ($number in [2]int{1, 2}) { assert(number > 0); }
}`
	lib_text := "package values; @(public) identity :: proc(value: $T) -> T { return value; }"
	s: Compilation_Session
	defer destroy_session(&s)
	if !testing.expect(t, init_session(&s, session_test_config())) { return }
	testing.expect(t, set_session_overlay(&s, path, text) && set_session_overlay(&s, dependency, lib_text))
	if !testing.expect(t, check_session(&s, filepath.dir(path, context.temp_allocator))) { report(&s.compiler); return }
	semantic_used, extent := s.compiler.semantic_arena.total_used, semantic_extent(&s.compiler)
	snapshot, captured := session_snapshot(&s)
	if !testing.expect(t, captured) { return }
	testing.expect_value(t, s.compiler.semantic_arena.total_used, semantic_used)
	file, found := query_file(&s, snapshot, path)
	if !testing.expect(t, found) { return }
	lib_file: u32
	lib_file, found = query_file(&s, snapshot, dependency)
	if !testing.expect(t, found) { return }
	identity := snapshot_test_symbol(t, &s, snapshot, lib_file, "identity")
	position := snapshot_test_position(t, &s, snapshot, file, text, "identity(value)")
	definition: Query_Location
	definition, found = query_definition(&s, position.symbol)
	testing.expect(t, found && definition.span.file == lib_file && lib_text[definition.span.lo:definition.span.hi] == "identity")
	references: []Query_Location
	references, found = query_references(&s, identity, include_definition = true)
	testing.expect(t, found && len(references) == 3, "generic instances must share a written definition")
	delete(references)
	// Generic bodies share binding identity, but their differing types are unknown.
	lib_position := snapshot_test_position(t, &s, snapshot, lib_file, lib_text, "value; }")
	testing.expect(t, lib_position.symbol.id != INVALID_SYMBOL && lib_position.type.id == INVALID_TYPE)
	references, found = query_references(&s, lib_position.symbol)
	testing.expect(t, found && len(references) == 1, "generic cloned uses were duplicated")
	delete(references)
	outer := snapshot_test_position(t, &s, snapshot, file, text, "value := 7")
	inner := snapshot_test_position(t, &s, snapshot, file, text, "value := 8")
	testing.expect(t, outer.symbol.id != inner.symbol.id, "shadowed bindings were conflated")
	references, found = query_references(&s, outer.symbol)
	testing.expect(t, found && len(references) == 3)
	delete(references)
	references, found = query_references(&s, inner.symbol)
	testing.expect(t, found && len(references) == 1)
	delete(references)
	type: Query_Type
	type, found = query_type(&s, outer.type)
	testing.expect(t, found && type.kind == .Int && type.name == "int")
	position = snapshot_test_position(t, &s, snapshot, file, text, "int) = {content")
	argument_symbol, argument_ok := query_symbol(&s, position.symbol)
	testing.expect(t, argument_ok && argument_symbol.name == "int" && position.type.id == TYPE_INT, "an inferred generic binding must not masquerade as a written definition at its argument")
	box := snapshot_test_symbol(t, &s, snapshot, file, "Box")
	box_symbol: Query_Symbol
	box_symbol, found = query_symbol(&s, box)
	testing.expect(t, found)
	type, found = query_type(&s, box_symbol.type)
	if testing.expect(t, found && type.kind == .Struct && len(type.fields) == 1) {
		references, found = query_references(&s, type.fields[0])
		testing.expect(t, found && len(references) == 2, "field selectors and composite keys must refer to the field")
		delete(references)
		position = snapshot_test_position(t, &s, snapshot, file, text, "item ==")
		testing.expect_value(t, position.symbol, type.fields[0])
		position = snapshot_test_position(t, &s, snapshot, file, text, "item = value")
		testing.expect_value(t, position.symbol, type.fields[0])
	}
	plain := snapshot_test_symbol(t, &s, snapshot, file, "plain")
	signatures: []Query_Signature
	signatures, found = query_signatures(&s, plain)
	if testing.expect(t, found && len(signatures) == 1 && len(signatures[0].parameters) == 1) {
		testing.expect(t, signatures[0].complete && signatures[0].parameters[0].name == "value" && signatures[0].parameters[0].has_default)
		testing.expect(t, signatures[0].result.id == TYPE_INT && strings.contains(signatures[0].text, "int = 1"))
	}
	pick := snapshot_test_symbol(t, &s, snapshot, file, "pick")
	signatures, found = query_signatures(&s, pick)
	testing.expect(t, found && len(signatures) == 2)
	references, found = query_references(&s, plain)
	testing.expect(t, found && len(references) == 3, "group membership and selected overload calls must retain their recorded bindings")
	delete(references)
	position = snapshot_test_position(t, &s, snapshot, file, text, "pick(1)")
	testing.expect_value(t, position.symbol, plain)
	position = snapshot_test_position(t, &s, snapshot, file, text, "number > 0")
	references, found = query_references(&s, position.symbol)
	testing.expect(t, found && len(references) == 1, "static loop cloned uses were duplicated")
	delete(references)
	signatures, found = query_signatures(&s, identity)
	testing.expect(t, found && len(signatures) == 1 && !signatures[0].complete && strings.contains(signatures[0].text, "$T"))
	_, found = query_at(&s, snapshot, file, u32(strings.index(text, "unknown()")))
	testing.expect(t, !found, "inactive syntax must not invent checked bindings")
	query_used := s.query_arena.total_used
	for _ in 0 ..< 4 {
		again, _ := session_snapshot(&s)
		testing.expect_value(t, again, snapshot)
		_, _ = query_type(&s, outer.type)
		_, _ = query_signatures(&s, pick)
		_, _ = query_at(&s, snapshot, file, u32(strings.index(text, "identity(value)")))
	}
	testing.expect_value(t, s.query_arena.total_used, query_used)
	testing.expect_value(t, s.compiler.semantic_arena.total_used, semantic_used)
	testing.expect_value(t, semantic_extent(&s.compiler), extent)
	ir, emitted := emit_session_ir(&s)
	testing.expect(t, emitted && ir != "", "queries changed emission readiness")
	// Emission diagnostics after capture do not mutate a read-only snapshot.
	diagnostics, diagnostics_ok := query_diagnostics(&s, snapshot)
	testing.expect(t, diagnostics_ok && len(diagnostics) == 0)
	testing.expect_value(t, emit_session(&s, Emission_Options{}), 2)
	diagnostics, diagnostics_ok = query_diagnostics(&s, snapshot)
	testing.expect(t, diagnostics_ok && len(diagnostics) == 0 && len(s.compiler.diagnostics) == 1)
}

@(test)
session_snapshot_errors_and_stale_handles :: proc(t: ^testing.T) {
	root := session_fixture(t, "snapshot-errors")
	if root == "" { return }
	defer os2.remove_all(root)
	path := filepath.join({root, "new.loke"}, context.temp_allocator)
	s: Compilation_Session
	defer destroy_session(&s)
	_, found := session_snapshot(&s)
	testing.expect(t, !found && !set_session_overlay(&s, path, ""))
	if !testing.expect(t, init_session(&s, session_test_config())) { return }
	testing.expect(t, !set_session_overlay(&s, "loke.project", ""))
	text := "package main; good :: proc(value: int) -> int { return value; } main :: proc() { assert(good(1) == 1); missing(); }"
	testing.expect(t, set_session_overlay(&s, path, text) && !check_session(&s, path))
	snapshot, captured := session_snapshot(&s)
	if !testing.expect(t, captured) { return }
	file: u32
	file, found = query_file(&s, snapshot, path)
	if !testing.expect(t, found) { return }
	good := snapshot_test_symbol(t, &s, snapshot, file, "good")
	position := snapshot_test_position(t, &s, snapshot, file, text, "good(1)")
	testing.expect_value(t, position.symbol, good)
	_, found = query_at(&s, snapshot, file, u32(strings.index(text, "missing()")))
	testing.expect(t, !found, "an unresolved name must not inherit its parent's type")
	diagnostics: []Query_Diagnostic
	diagnostics, found = query_diagnostics(&s, snapshot)
	testing.expect(t, found && len(diagnostics) > 0 && diagnostics[0].severity == .Error && diagnostics[0].code != "")
	_, found = query_signatures(&s, good)
	testing.expect(t, found, "a body error must not hide a valid signature")
	_, found = query_source(&s, snapshot, NO_FILE)
	testing.expect(t, !found)
	_, found = query_symbol(&s, Symbol_Handle{snapshot.id, Symbol_Id(max(u32))})
	testing.expect(t, !found)
	_, found = query_type(&s, Type_Handle{snapshot.id, Type_Id(max(u32))})
	testing.expect(t, !found)
	_, found = query_at(&s, snapshot, file, u32(len(text)))
	testing.expect(t, !found)
	other: Compilation_Session
	testing.expect(t, init_session(&other, session_test_config()))
	_, _ = session_snapshot(&other)
	_, found = query_symbol(&other, good)
	testing.expect(t, !found)
	destroy_session(&other)
	// Rechecking the same bytes also replaces the snapshot.
	borrowed, borrowed_ok := query_source(&s, snapshot, file)
	testing.expect(t, borrowed_ok && !check_session(&s, borrowed.path))
	_, found = query_symbol(&s, good)
	testing.expect(t, !found)
	for invalid, index in ([]string{"", "\xef\xbb\xbfpackage main;", "package main;\xff", "package main; main :: proc() {", "package main; bad :: proc(x: Missing) {} main :: proc() {}"}) {
		testing.expect(t, set_session_overlay(&s, path, invalid))
		_, found = session_snapshot(&s)
		testing.expect(t, !found, "overlay edits require a check before querying")
		testing.expect(t, !check_session(&s, path))
		broken, ok := session_snapshot(&s)
		if !testing.expect(t, ok) { continue }
		diagnostics, found = query_diagnostics(&s, broken)
		testing.expect(t, found && len(diagnostics) > 0)
		if index == 1 { testing.expect_value(t, diagnostics[0].code, "L0002") }
		if index == 2 { testing.expect_value(t, diagnostics[0].code, "L0003") }
		if index == 4 {
			file, found = query_file(&s, broken, path)
			if testing.expect(t, found) {
				bad := snapshot_test_symbol(t, &s, broken, file, "bad")
				_, found = query_signatures(&s, bad)
				testing.expect(t, !found, "an erroneous signature must not appear complete")
			}
		}
	}
	testing.expect(t, set_session_overlay(&s, path, "package main; main :: proc() {}") && check_session(&s, path))
	latest, _ := session_snapshot(&s)
	destroy_session(&s)
	testing.expect(t, s.query_arena.curr_block == nil && len(s.overlays) == 0)
	_, found = query_diagnostics(&s, latest)
	testing.expect(t, !found)
	testing.expect(t, init_session(&s, session_test_config()))
	_, _ = session_snapshot(&s)
	_, found = query_diagnostics(&s, latest)
	testing.expect(t, !found, "recreating a session must not resurrect handles")
	destroy_session(&s)
	config := session_test_config()
	config.defines = []string{"INVALID-NAME=1"}
	testing.expect(t, !init_session(&s, config))
	failed, ok := session_snapshot(&s)
	diagnostics, found = query_diagnostics(&s, failed)
	testing.expect(t, ok && found && len(diagnostics) == 1 && diagnostics[0].code == "L0388")
}
