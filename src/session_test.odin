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
