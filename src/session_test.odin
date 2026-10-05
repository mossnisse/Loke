package lokec

import "core:fmt"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(private)
session_test_config :: proc() -> Compilation_Config {
	config := DEFAULT_COMPILATION_CONFIG
	config.collections = make([]string, 2, context.temp_allocator)
	config.collections[0] = fmt.tprintf("base=%s", canonical_dir("base"))
	config.collections[1] = fmt.tprintf("core=%s", canonical_dir("core"))
	return config
}

@(private)
session_fixture :: proc(t: ^testing.T, name: string) -> string {
	root := fmt.tprintf("tests/tmp/session-%d-%s", os2.get_pid(), name)
	if !testing.expect(t, os2.make_directory_all(root) == nil) { return "" }
	return root
}

@(private)
write_session_source :: proc(t: ^testing.T, path, text: string) -> bool {
	return testing.expect(t, os2.write_entire_file(path, transmute([]u8)text) == nil)
}

@(private = "file")
expect_session_diagnostics :: proc(t: ^testing.T, a, b: ^Compiler) {
	testing.expect_value(t, a.error_count, b.error_count)
	if testing.expect_value(t, len(a.sources), len(b.sources)) {
		for source, index in a.sources {
			testing.expect_value(t, filepath.base(source.path), filepath.base(b.sources[index].path))
		}
	}
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
	_, generated = emit_session_ir(&s)
	testing.expect(t, generated && len(s.compiler.diagnostics) == 0, "a missing output path must not block emission")
	unwritable := filepath.join({root, "missing", "library.obj"}, context.temp_allocator)
	testing.expect_value(t, emit_session(&s, Emission_Options{output = unwritable}), 2)
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
// discovers both. Caller memory, alias spelling, unsaved directories, and file
// order matter: an unsaved file sorts by name among listed ones.
@(test)
session_overlays_match_disk_compilation :: proc(t: ^testing.T) {
	root := session_fixture(t, "overlays")
	if root == "" { return }
	defer os2.remove_all(root)
	path := filepath.join({root, "main.loke"}, context.temp_allocator)
	extra := filepath.join({root, "z_extra.loke"}, context.temp_allocator)
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
	unwritable := filepath.join({root, "missing", "main.obj"}, context.temp_allocator)
	testing.expect_value(t, emit_session(&s, Emission_Options{output = unwritable}), 2)
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

@(private)
expect_session_matches_fresh :: proc(t: ^testing.T, s: ^Compilation_Session, input: string, config: Compilation_Config, expected: bool) -> Compilation_Snapshot {
	checked := check_session_incremental(s, input)
	if checked != expected { report(&s.compiler) }
	testing.expect_value(t, checked, expected)
	fresh: Compilation_Session
	defer destroy_session(&fresh)
	if !testing.expect(t, init_session(&fresh, config)) { return {} }
	testing.expect_value(t, check_session(&fresh, input), checked)
	expect_session_diagnostics(t, &s.compiler, &fresh.compiler)
	testing.expect_value(t, semantic_extent(&s.compiler), semantic_extent(&fresh.compiler))
	ir, emitted := emit_session_ir(s)
	fresh_ir, fresh_emitted := emit_session_ir(&fresh)
	testing.expect(t, emitted == checked && fresh_emitted == emitted && ir == fresh_ir, "recheck differs from a fresh batch's IR")
	snapshot, captured := session_snapshot(s)
	testing.expect(t, captured)
	return snapshot
}

@(test)
session_explicit_invalidation_rejects_all_cached_views :: proc(t: ^testing.T) {
	root := session_fixture(t, "invalidate")
	if root == "" { return }
	defer os2.remove_all(root)
	path := filepath.join({root, "main.loke"}, context.temp_allocator)
	text := "package main; main :: proc() {}"
	if !write_session_source(t, path, text) { return }
	s: Compilation_Session
	defer destroy_session(&s)
	testing.expect(t, !invalidate_session(&s))
	config := session_test_config()
	config.defines = []string{"FEATURE=true"}
	if !testing.expect(t, init_session(&s, config)) { return }
	testing.expect(t, invalidate_session(&s))
	testing.expect(t, set_session_overlay(&s, path, text))
	snapshot := expect_session_matches_fresh(t, &s, path, config, true)
	file, found := query_file(&s, snapshot, path)
	if !testing.expect(t, found) { return }
	handle := snapshot_test_symbol(t, &s, snapshot, file, "main")
	symbol, symbol_ok := query_symbol(&s, handle)
	if !testing.expect(t, symbol_ok) { return }
	testing.expect(t, s.query_arena.curr_block != nil)
	testing.expect(t, invalidate_session(&s) && invalidate_session(&s))
	testing.expect(t, s.query_arena.curr_block == nil && !s.ready && len(s.overlays) == 1 && s.config.defines[0] == "FEATURE=true")
	_, found = session_snapshot(&s)
	testing.expect(t, !found)
	_, found = query_file(&s, snapshot, path)
	testing.expect(t, !found)
	_, found = query_source(&s, snapshot, file)
	testing.expect(t, !found)
	_, found = query_symbols(&s, snapshot, file)
	testing.expect(t, !found)
	_, found = query_symbol(&s, handle)
	testing.expect(t, !found)
	_, found = query_type(&s, symbol.type)
	testing.expect(t, !found)
	_, found = query_definition(&s, handle)
	testing.expect(t, !found)
	_, found = query_references(&s, handle)
	testing.expect(t, !found)
	_, found = query_signatures(&s, handle)
	testing.expect(t, !found)
	_, found = query_diagnostics(&s, snapshot)
	testing.expect(t, !found)
	_, found = query_at(&s, snapshot, file, 14)
	testing.expect(t, !found)
	_, found = emit_session_ir(&s)
	testing.expect(t, !found)
	testing.expect_value(t, emit_session(&s, Emission_Options{output = "unused.exe"}), 2)
	new_snapshot := expect_session_matches_fresh(t, &s, path, config, true)
	testing.expect(t, new_snapshot.id != snapshot.id)
	destroy_session(&s)
	testing.expect(t, !invalidate_session(&s))
}

// Body-only CTFE edits change the selected import graph. Directory membership,
// nearest-manifest existence, effective collections, and rejected generic
// instances must also be re-read, even when exported signatures stay the same.
@(test)
session_discovery_and_ctfe_changes_match_fresh_checks :: proc(t: ^testing.T) {
	root := session_fixture(t, "invalidation-discovery")
	if root == "" { return }
	defer os2.remove_all(root)
	for dir in ([]string{"first/feature", "second/feature", "fast", "slow"}) {
		if !testing.expect(t, os2.make_directory_all(filepath.join({root, dir}, context.temp_allocator)) == nil) { return }
	}
	path := filepath.join({root, "main.loke"}, context.temp_allocator)
	manifest := filepath.join({root, "loke.project"}, context.temp_allocator)
	first := filepath.join({root, "first", "feature", "feature.loke"}, context.temp_allocator)
	second := filepath.join({root, "second", "feature", "feature.loke"}, context.temp_allocator)
	fast := filepath.join({root, "fast", "answer.loke"}, context.temp_allocator)
	slow := filepath.join({root, "slow", "answer.loke"}, context.temp_allocator)
	extra := filepath.join({root, "extra.loke"}, context.temp_allocator)
	feature_false := "package feature; @(public) enabled :: proc() -> bool { return false; } @(public) identity :: proc(value: $T) -> T { return value; }"
	feature_true, _ := strings.replace_all(feature_false, "return false;", "return true;", context.temp_allocator)
	text := `package main;
import "settings:feature";
when (feature.enabled()) {
    import "fast";
    chosen :: proc() -> int { return fast.answer(); }
} else {
    import "slow";
    chosen :: proc() -> int { return slow.answer(); }
}
main :: proc() { assert(chosen() > 0); static_assert(feature.identity(7) == 7); }`
	if !write_session_source(t, path, text) || !write_session_source(t, manifest, "require settings ./first\n") ||
	   !write_session_source(t, first, feature_false) || !write_session_source(t, second, feature_false) ||
	   !write_session_source(t, fast, "package fast; @(public) answer :: proc() -> int { return 1; }") ||
	   !write_session_source(t, slow, "package slow; @(public) answer :: proc() -> int { return 2; }") { return }
	s: Compilation_Session
	defer destroy_session(&s)
	config := session_test_config()
	if !testing.expect(t, init_session(&s, config)) { return }
	previous: Compilation_Snapshot
	for edit in 0 ..< 11 {
		switch edit {
		case 1: if !write_session_source(t, first, feature_true) { return }
		case 2: if !write_session_source(t, extra, "package main; extra :: 3;") { return }
		case 3: if !testing.expect(t, os2.remove(extra) == nil) { return }
		case 4: if !write_session_source(t, fast, "package fast; @(public) answer :: proc() -> int { return missing; }") { return }
		case 5: if !write_session_source(t, fast, "package fast; @(public) answer :: proc() -> int { return 4; }") { return }
		case 6: if !write_session_source(t, manifest, "require settings ./second\n") { return }
		case 7: if !testing.expect(t, os2.remove(manifest) == nil) { return }
		case 8: if !write_session_source(t, manifest, "require settings ./first\n") { return }
		case 9:
			bad, _ := strings.replace_all(feature_true, "-> T {", "-> T where false {", context.temp_allocator)
			if !write_session_source(t, first, bad) { return }
		case 10: if !write_session_source(t, first, feature_true) { return }
		}
		testing.expect(t, invalidate_session(&s))
		_, old_valid := query_diagnostics(&s, previous)
		testing.expect(t, !old_valid)
		expected := edit != 4 && edit != 7 && edit != 9
		snapshot := expect_session_matches_fresh(t, &s, path, config, expected)
		if expected {
			_, fast_loaded := query_file(&s, snapshot, fast)
			_, slow_loaded := query_file(&s, snapshot, slow)
			fast_selected := edit != 0 && edit != 6
			testing.expect(t, fast_loaded == fast_selected && slow_loaded != fast_selected, "obsolete conditional import survived rechecking")
			// A file root remains standalone; a directory root discovers additions.
			if edit == 2 || edit == 3 {
				snapshot = expect_session_matches_fresh(t, &s, root, config, true)
				_, extra_loaded := query_file(&s, snapshot, extra)
				testing.expect_value(t, extra_loaded, edit == 2)
			}
		}
		previous = snapshot
	}
}

// A dependency's signature alone does not describe its effects or its result's
// provenance. Change only bodies, make a previously safe caller fail, then fix
// the body and check that held diagnostics and inferred summaries are rebuilt.
@(test)
session_body_effect_changes_match_fresh_checks :: proc(t: ^testing.T) {
	root := session_fixture(t, "invalidation-effects")
	if root == "" { return }
	defer os2.remove_all(root)
	path := filepath.join({root, "main.loke"}, context.temp_allocator)
	s: Compilation_Session
	defer destroy_session(&s)
	config := session_test_config()
	if !testing.expect(t, init_session(&s, config)) { return }
	for scenario in 0 ..< 2 {
		for edit in 0 ..< 3 {
			text := ""
			if scenario == 0 {
				body := edit == 1 ? "values.clear();" : ""
				template := `package main;
values: [dynamic]int;
reset :: proc() { BODY }
first :: proc(input: []int) -> int { reset(); return input[0]; }
main :: proc() { values.append(1); assert(first(values) == 1); }`
				text, _ = strings.replace_all(template, "BODY", body, context.temp_allocator)
			} else {
				result := edit == 1 ? "b" : "a"
				template := `package main;
choose :: proc(a, b: []int) -> []int { return RESULT; }
main :: proc() {
    left := [dynamic]int{1}; right := [dynamic]int{2};
    view := choose(left, right); right.clear(); assert(view.len() == 1);
}`
				text, _ = strings.replace_all(template, "RESULT", result, context.temp_allocator)
			}
			if !write_session_source(t, path, text) { return }
			snapshot := expect_session_matches_fresh(t, &s, path, config, edit != 1)
			if edit > 0 { testing.expect(t, len(session_check_stats(&s).reused_packages) > 0) }
			if edit == 1 {
				diagnostics, captured := query_diagnostics(&s, snapshot)
				found_borrow_error := false
				for diagnostic in diagnostics { found_borrow_error ||= diagnostic.code == "L0512" }
				testing.expect(t, captured && found_borrow_error)
			}
		}
	}
}

// Providers are dependencies without source imports. A formatter/drop hook
// edit keeps the nominal type's declaration intact but changes final registries.
@(test)
session_provider_and_registry_changes_match_fresh_checks :: proc(t: ^testing.T) {
	root := session_fixture(t, "invalidation-registries")
	if root == "" { return }
	defer os2.remove_all(root)
	for dir in ([]string{"provider", "data"}) {
		if !testing.expect(t, os2.make_directory_all(filepath.join({root, dir}, context.temp_allocator)) == nil) { return }
	}
	path := filepath.join({root, "main.loke"}, context.temp_allocator)
	provider := filepath.join({root, "provider", "provider.loke"}, context.temp_allocator)
	data := filepath.join({root, "data", "data.loke"}, context.temp_allocator)
	text := `@(default_allocator = "./provider:factory") package main;
import "core:fmt"; import "data";
main :: proc() { value := data.Value{item = 1}; fmt.println(value, typeid_of(data.Value)); assert(type_info_of(typeid_of(data.Value)).id == typeid_of(data.Value)); }`
	selected_missing, _ := strings.replace_all(text, "provider:factory", "provider:other", context.temp_allocator)
	provider_text := "package provider; @(public) factory :: proc() -> Allocator { return {}; }"
	if !write_session_source(t, path, text) || !write_session_source(t, provider, provider_text) ||
	   !write_session_source(t, data, "@(public) package data; Value :: struct { item: int }") { return }
	s: Compilation_Session
	defer destroy_session(&s)
	config := session_test_config()
	if !testing.expect(t, init_session(&s, config)) { return }
	for edit in 0 ..< 8 {
		switch edit {
		case 1:
			changed := `@(public) package data; import "core:fmt";
Value :: struct { item: int }
impl Value {
    format :: proc(self: ^, writer: fmt.Writer, options: fmt.Options) { fmt.concat_to(writer, "changed"); }
    done :: hook(drop) proc(self: inout) {}
}`
			if !write_session_source(t, data, changed) { return }
		case 2: if !write_session_source(t, path, selected_missing) { return }
		case 3, 5:
			if !write_session_source(t, provider, strings.concatenate({provider_text, " @(public) other :: proc() -> Allocator { return {}; }"}, context.temp_allocator)) { return }
		case 4:
			if !write_session_source(t, provider, strings.concatenate({provider_text, " @(public) other :: proc() -> int { return 0; }"}, context.temp_allocator)) { return }
		case 6: if !write_session_source(t, path, "package main; main :: proc() {}") { return }
		case 7: if !write_session_source(t, path, text) { return }
		}
		snapshot := expect_session_matches_fresh(t, &s, path, config, edit != 2 && edit != 4)
		testing.expect_value(t, len(session_check_stats(&s).reused_packages), 0)
		c := &s.compiler
		testing.expect_value(t, c.providers[.Allocator].selected, edit != 6)
		if edit != 2 && edit != 4 {
			testing.expect(t, c.program_analyzed && c.typeid_frozen && c.formatters_ready && c.lifecycle_operations_ready)
			_, loaded := query_file(&s, snapshot, provider)
			testing.expect_value(t, loaded, edit != 6)
			if edit == 6 {
				testing.expect(t, !c.format_requested && !c.type_info_requested && len(c.formatters) == 0 && len(c.typeid_order) == 0)
			} else {
				factory := symbol_of(c, c.providers[.Allocator].factory)
				if testing.expect(t, factory != nil) {
					testing.expect_value(t, identifier_text(c, factory.name), edit >= 3 && edit <= 5 ? "other" : "factory")
				}
				testing.expect(t, c.format_requested && c.type_info_requested && len(c.formatters) > 0 && len(c.typeid_order) > 0)
			}
		}
	}
}
