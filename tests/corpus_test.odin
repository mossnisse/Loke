// The whole executable test harness (compiler-plan E). Corpora shelling out to
// the built compiler, plus the parser's own:
//
//   tests/run/*.loke + .expected   compile, run, compare stdout
//   tests/ll/*.loke  + .expected   compile with -emit-ll, assert the generated
//                                  IR still contains each listed shape
//   tests/err/*.loke + .expected   compile, assert exact diagnostic count plus
//                                  code/message substrings and @line:column spans
//   tests/trap/*.loke              compile, run, expect a non-zero exit
//   tests/layout/*.loke            compile with -check-layout: the checker's
//                                  size/alignment/offsets must agree with LLVM's
//   tests/pkg/<case>/ with        a directory compiled as one root package, with
//     tests/pkg/<case>.expected   its own imported subdirectories
//   tests/pkg_err/<case>/ with    the same, for package and import diagnostics
//     tests/pkg_err/<case>.expected
//   tests/syntax_err/*.loke        the same, for parser diagnostics, and assert
//     with .expected               the file's trailing sentinel survived recovery
//
// Two cases are one-off rather than a corpus, because each needs something the
// glob-and-compare shape cannot express:
//
//   tests/obj/{lib.loke,host.c}    an object build linked into a C host that
//                                  owns process entry and supplies the runtime
//   tests/os/args.{loke,expected}  a program run with a real, non-ASCII argument
//                                  vector, which every other case lacks
//
// Any case may sit beside a `.flags` file of extra compiler options, one per
// line, which is how `-define` and `-collection` are exercised.
//
// The valid-syntax corpus in tests/syntax/ is checked in-process instead, by
// src/syntax_corpus_test.odin — it asserts on spans and token streams, which are
// not visible from stdout.
//
// Run with:  odin build src -out:lokec.exe  &&  odin test tests
package tests

import "core:fmt"
import "core:log"
import "core:os"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

LOKEC_DEFAULT :: "lokec.exe"
TMP :: "tests/tmp"

@(private)
compiler_path :: proc() -> string {
	if configured := os.get_env("LOKEC", context.temp_allocator); configured != "" {
		return configured
	}
	return LOKEC_DEFAULT
}

// Extra compiler flags applied to every run/trap compile, from the environment.
// The differential-optimization corpus sets `LOKE_TEST_FLAGS=-opt=speed` (and
// the other four modes) and requires identical observable results at each
// (m7-plan step 1, decision "Optimization safety").
@(private)
env_flags :: proc() -> []string {
	text := os.get_env("LOKE_TEST_FLAGS", context.temp_allocator)
	if text == "" {
		return nil
	}
	flags := make([dynamic]string, context.temp_allocator)
	for field in strings.fields(text) {
		append(&flags, field)
	}
	return flags[:]
}

// The corpus shells out, so a forgotten build must fail visibly instead of
// validating an unrelated stale executable. An explicitly supplied `LOKEC`
// path is trusted because CI may place its build outside this source tree.
@(test)
compiler_binary_is_current :: proc(t: ^testing.T) {
	if os.get_env("LOKEC", context.temp_allocator) != "" {
		return
	}
	compiler := compiler_path()
	compiler_info, compiler_err := os.stat(compiler, context.temp_allocator)
	if !testing.expectf(t, compiler_err == nil, "cannot stat %s; build it or set LOKEC=<path>", compiler) {
		return
	}
	sources, _ := filepath.glob("src/*.odin", context.temp_allocator)
	compiler_time := time.time_to_unix_nano(compiler_info.modification_time)
	for source in sources {
		info, err := os.stat(source, context.temp_allocator)
		if err == nil && time.time_to_unix_nano(info.modification_time) > compiler_time {
			testing.expectf(t, false, "%s is older than %s; rebuild it or set LOKEC=<path>", compiler, source)
			return
		}
	}
}

@(test)
front_end_modes :: proc(t: ^testing.T) {
	parse_state, parse_stdout, parse_stderr, parse_err := os2.process_exec(
		os2.Process_Desc{command = []string{compiler_path(), "examples/hello.loke", "-parse-only"}},
		context.allocator,
	)
	testing.expectf(t, parse_err == nil, "cannot run %s in parse-only mode", compiler_path())
	testing.expectf(t, parse_state.exit_code == 0, "parse-only failed:\n%s", string(parse_stderr))
	testing.expectf(t, len(parse_stdout) == 0, "parse-only unexpectedly wrote output: %s", string(parse_stdout))

	dump_state, dump_stdout, dump_stderr, dump_err := os2.process_exec(
		os2.Process_Desc{command = []string{compiler_path(), "examples/hello.loke", "-dump-ast"}},
		context.allocator,
	)
	testing.expectf(t, dump_err == nil, "cannot run %s in AST-dump mode", compiler_path())
	testing.expectf(t, dump_state.exit_code == 0, "AST dump failed:\n%s", string(dump_stderr))
	testing.expectf(
		t,
		strings.has_prefix(string(dump_stdout), `(file package="main"`),
		"unexpected AST dump:\n%s",
		string(dump_stdout),
	)
}

// The seed runtime is found beside the compiler, not beside the caller
// (m6a-plan decision "Runtime language and discovery"): compiling from an
// unrelated working directory must still link, and an explicit `-runtime`
// directory must replace the bundled one rather than adding to it.
@(test)
seed_runtime_is_found_from_anywhere :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	cwd := os.get_current_directory(context.temp_allocator)
	compiler := filepath.join({cwd, compiler_path()}, context.temp_allocator)
	source := filepath.join({cwd, "examples", "hello.loke"}, context.temp_allocator)
	exe := filepath.join({cwd, TMP, "runtime-elsewhere.exe"}, context.temp_allocator)
	elsewhere := filepath.join({cwd, TMP}, context.temp_allocator)

	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = []string{compiler, source, "-o", exe}, working_dir = elsewhere},
		context.allocator,
	)
	testing.expectf(t, err == nil, "cannot run %s from %s", compiler, elsewhere)
	testing.expectf(t, state.exit_code == 0, "compiling from %s failed:\n%s", elsewhere, string(stderr))

	// An empty directory is a directory that exists and holds no `.c` inputs, so
	// the override really replaced the bundled tree.
	bare := filepath.join({cwd, TMP, "empty-runtime"}, context.temp_allocator)
	os.make_directory(bare)
	replaced, _, replaced_stderr, replaced_err := os2.process_exec(
		os2.Process_Desc {
			command = []string{compiler, source, "-o", exe, fmt.tprintf("-runtime=%s", bare)},
		},
		context.allocator,
	)
	testing.expectf(t, replaced_err == nil, "cannot run %s", compiler)
	testing.expectf(t, replaced.exit_code == 2, "expected an explicit -runtime to replace the bundled tree")
	testing.expectf(
		t,
		strings.contains(string(replaced_stderr), "L0551") &&
		strings.contains(string(replaced_stderr), bare),
		"expected L0551 naming %s, got:\n%s",
		bare,
		string(replaced_stderr),
	)
}

@(test)
programs_run :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	cases, _ := filepath.glob("tests/run/*.loke")
	testing.expect(t, len(cases) > 0, "no run cases found; is the working directory the repo root?")
	for path in cases {
		run_one_program(t, path, expected_path(path), fmt.tprintf("%s/%s.exe", TMP, filepath.stem(path)))
	}
}

// A non-zero exit alone cannot prove what a panic did on the way down, so a
// trap case reads its sibling `.flags` like every other corpus — which is how
// `-panic=abort` is exercised — and may pin the stdout produced before the
// failure with a `.expected` file (m6a-plan decision "Corpora").
@(test)
programs_trap :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	cases, _ := filepath.glob("tests/trap/*.loke")
	testing.expect(t, len(cases) > 0, "no runtime-trap cases found")

	for path in cases {
		exe := fmt.tprintf("%s/trap-%s.exe", TMP, filepath.stem(path))
		command := make([dynamic]string, context.temp_allocator)
		append(&command, compiler_path(), path, "-o", exe)
		for flag in env_flags() {
			append(&command, flag)
		}
		for flag in extra_flags(path) {
			append(&command, flag)
		}
		state, _, stderr, err := os2.process_exec(
			os2.Process_Desc{command = command[:]},
			context.allocator,
		)
		if !testing.expectf(t, err == nil, "%s: cannot run %s", path, compiler_path()) {
			continue
		}
		if !testing.expectf(t, state.exit_code == 0, "%s: compile failed\n%s", path, string(stderr)) {
			continue
		}

		run_state, stdout, _, run_err := os2.process_exec(
			os2.Process_Desc{command = []string{exe}},
			context.allocator,
		)
		testing.expectf(t, run_err == nil, "%s: cannot run the produced exe", path)
		testing.expectf(t, run_state.exit_code != 0, "%s: expected a runtime failure", path)

		expected, has_expected := os.read_entire_file(expected_path(path))
		if !has_expected {
			continue
		}
		testing.expectf(
			t,
			normalise(string(stdout)) == normalise(string(expected)),
			"%s: expected %q before the failure, got %q",
			path,
			normalise(string(expected)),
			normalise(string(stdout)),
		)
	}
}

// The generated IR is not compared whole — that would break on every temporary
// renumbering. Each case lists the instruction shapes that must survive: the
// integer guards, the short-circuit phi, the bounds and nil checks, the defer
// flags, recursive aggregate equality, and the indirect call.
@(test)
generated_ir_keeps_its_shape :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	cases, _ := filepath.glob("tests/ll/*.loke")
	testing.expect(t, len(cases) > 0, "no IR cases found")

	for path in cases {
		expected, has_expected := os.read_entire_file(expected_path(path))
		if !testing.expectf(t, has_expected, "%s: missing .expected file", path) {
			continue
		}

		exe := fmt.tprintf("%s/%s.exe", TMP, filepath.stem(path))
		state, _, stderr, err := os2.process_exec(
			os2.Process_Desc{command = []string{compiler_path(), path, "-o", exe, "-emit-ll"}},
			context.allocator,
		)
		if !testing.expectf(t, err == nil, "%s: cannot run %s", path, compiler_path()) {
			continue
		}
		if !testing.expectf(t, state.exit_code == 0, "%s: compile failed\n%s", path, string(stderr)) {
			continue
		}

		ll_path := fmt.tprintf("%s/%s.ll", TMP, filepath.stem(path))
		ir, read_ok := os.read_entire_file(ll_path)
		if !testing.expectf(t, read_ok, "%s: no IR at %s", path, ll_path) {
			continue
		}
		for raw_line in strings.split_lines(normalise(string(expected))) {
			line := strings.trim_space(raw_line)
			if line == "" {
				continue
			}
			testing.expectf(t, strings.contains(string(ir), line), "%s: IR does not contain %q", path, line)
		}
	}
}

// `-check-layout` builds a second module that asks LLVM for the size,
// alignment, and field offsets of every type in the file, runs it, and compares
// the answers with the checker's cached layout. What the folded built-ins
// themselves produce is a tests/run case.
@(test)
layout_agrees_with_llvm :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	cases, _ := filepath.glob("tests/layout/*.loke")
	testing.expect(t, len(cases) > 0, "no layout cases found")

	for path in cases {
		exe := fmt.tprintf("%s/layout-%s.exe", TMP, filepath.stem(path))
		state, stdout, stderr, err := os2.process_exec(
			os2.Process_Desc{command = []string{compiler_path(), path, "-o", exe, "-check-layout"}},
			context.allocator,
		)
		if !testing.expectf(t, err == nil, "%s: cannot run %s", path, compiler_path()) {
			continue
		}
		testing.expectf(
			t,
			state.exit_code == 0,
			"%s: the checker and LLVM disagree\n%s%s",
			path,
			string(stdout),
			string(stderr),
		)
	}
}

// Multi-file and import behaviour cannot be expressed by the one-file corpora:
// each case is a directory passed to the compiler as one root, and may hold
// imported subdirectories of its own.
@(test)
packages_run :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	for path in case_directories(t, "tests/pkg") {
		run_one_program(
			t,
			path,
			fmt.tprintf("%s.expected", path),
			fmt.tprintf("%s/pkg-%s.exe", TMP, filepath.base(path)),
		)
	}
}

// design.md "Program entry and exit" (m7-plan step 5): the corpus runs every
// other case with no arguments, so this is the one that passes a real vector —
// including non-ASCII arguments, which is what exercises the UTF-16-to-UTF-8
// conversion the generated `wmain` performs before the initial thread attaches.
@(test)
process_arguments_reach_os_args :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	exe := fmt.tprintf("%s/os-args.exe", TMP)
	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = []string{compiler_path(), "tests/os/args.loke", "-o", exe}},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "compile failed:\n%s", string(stderr)) {
		return
	}

	expected, has_expected := os.read_entire_file("tests/os/args.expected")
	if !testing.expect(t, has_expected, "missing tests/os/args.expected") {
		return
	}
	run_state, stdout, _, run_err := os2.process_exec(
		os2.Process_Desc{command = []string{exe, "alpha", "héllo", "日本"}},
		context.allocator,
	)
	testing.expectf(t, run_err == nil, "cannot run %s", exe)
	testing.expectf(t, run_state.exit_code == 0, "exited with %d", run_state.exit_code)
	testing.expectf(
		t,
		normalise(string(stdout)) == normalise(string(expected)),
		"expected %q, got %q",
		normalise(string(expected)),
		normalise(string(stdout)),
	)
}

// design.md "Build modes" (m7-plan step 5): `-build-mode=obj` produces one
// relocatable module from a non-`main` root. This links it into a C program that
// owns process entry and supplies the seed runtime, and asserts the object
// defines no entry symbol of its own.
@(test)
object_build_links_into_a_c_host :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	clang, include_flags, found := host_toolchain()
	if !found {
		log.info("no clang or MSVC toolset found; skipping the object-build host link")
		return
	}

	obj := fmt.tprintf("%s/widget.obj", TMP)
	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc {
			command = []string{compiler_path(), "tests/obj/lib.loke", "-build-mode=obj", "-o", obj},
		},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "the object build failed:\n%s", string(stderr)) {
		return
	}

	// The object owns no entry: a compiler-generated `main`/`wmain` would collide
	// with the host's own, and the runtime references it keeps are the point.
	nm := filepath.join({filepath.dir(clang), "llvm-nm.exe"}, context.temp_allocator)
	if os.is_file(nm) {
		nm_state, symbols, _, nm_err := os2.process_exec(
			os2.Process_Desc{command = []string{nm, obj}},
			context.allocator,
		)
		if testing.expectf(t, nm_err == nil && nm_state.exit_code == 0, "cannot list %s", obj) {
			text := string(symbols)
			testing.expectf(t, !strings.contains(text, " T main"), "the object defines `main`:\n%s", text)
			testing.expectf(t, !strings.contains(text, " T wmain"), "the object defines `wmain`:\n%s", text)
			testing.expectf(t, strings.contains(text, " T widget_add"), "the object does not define `widget_add`:\n%s", text)
			testing.expectf(
				t,
				strings.contains(text, "U loke_rt_v1_thread_attach") ||
				strings.contains(text, "U loke_rt_v1_frame_pop") ||
				strings.contains(text, "U memset"),
				"the object resolved references its host should supply:\n%s",
				text,
			)
		}
	}

	// The host link: the object, the C entry, and the seed runtime sources.
	exe := fmt.tprintf("%s/widget-host.exe", TMP)
	command := make([dynamic]string, context.temp_allocator)
	// `-rtlib=compiler-rt` is the same choice the compiler's own link makes: the
	// runtime's 128-bit division helpers are not in the MSVC CRT.
	append(&command, clang, "tests/obj/host.c", obj, "-o", exe, "-Wno-override-module", "-rtlib=compiler-rt")
	runtime_sources, _ := filepath.glob("runtime/*.c")
	for source in runtime_sources {
		append(&command, source)
	}
	append(&command, "-I", "runtime")
	for flag in include_flags {
		append(&command, flag)
	}
	link_state, _, link_stderr, link_err := os2.process_exec(
		os2.Process_Desc{command = command[:]},
		context.allocator,
	)
	if !testing.expectf(t, link_err == nil, "cannot run %s", clang) {
		return
	}
	if !testing.expectf(t, link_state.exit_code == 0, "the host link failed:\n%s", string(link_stderr)) {
		return
	}

	run_state, _, _, run_err := os2.process_exec(os2.Process_Desc{command = []string{exe}}, context.allocator)
	testing.expectf(t, run_err == nil, "cannot run %s", exe)
	testing.expectf(t, run_state.exit_code == 0, "the C host got the wrong answer (exit %d)", run_state.exit_code)
}

// clang plus the `-isystem`/`-L` flags its Windows target needs outside a
// developer prompt, discovered the same way the compiler's own link does. The
// test skips rather than fails when neither is installed.
@(private)
host_toolchain :: proc() -> (clang: string, flags: []string, ok: bool) {
	clang = os.get_env("LOKE_CLANG", context.temp_allocator)
	if clang == "" {
		for candidate in ([]string{`C:\Program Files\LLVM\bin\clang.exe`, `C:\Program Files (x86)\LLVM\bin\clang.exe`}) {
			if os.is_file(candidate) {
				clang = candidate
				break
			}
		}
	}
	if clang == "" || !os.is_file(clang) {
		return "", nil, false
	}
	out := make([dynamic]string, context.temp_allocator)
	if os.get_env("INCLUDE", context.temp_allocator) == "" {
		tools := newest_directory(`C:\Program Files\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*`)
		ucrt := newest_directory(`C:\Program Files (x86)\Windows Kits\10\Include\*\ucrt`)
		if tools == "" || ucrt == "" {
			return "", nil, false
		}
		append(&out, "-isystem", filepath.join({tools, "include"}, context.temp_allocator))
		append(&out, "-isystem", ucrt)
		append(&out, "-L", filepath.join({tools, "lib", "x64"}, context.temp_allocator))
	}
	return clang, out[:], true
}

@(private)
newest_directory :: proc(pattern: string) -> string {
	matches, _ := filepath.glob(pattern)
	newest := ""
	for match in matches {
		if os.is_dir(match) && match > newest {
			newest = match
		}
	}
	return newest
}

@(test)
package_diagnostics_reported :: proc(t: ^testing.T) {
	for path in case_directories(t, "tests/pkg_err") {
		check_one_diagnostic_case(t, path, fmt.tprintf("%s.expected", path), "-emit-ll", "")
	}
}

@(test)
diagnostics_reported :: proc(t: ^testing.T) {
	check_diagnostics(t, "tests/err/*.loke", "-emit-ll", "")
}

// Syntax errors are reported by the parser, so these run in `-dump-ast` mode:
// the dump is printed before the diagnostics are, which is what lets the test
// assert the file's trailing sentinel survived recovery.
@(test)
syntax_errors_recover :: proc(t: ^testing.T) {
	check_diagnostics(t, "tests/syntax_err/*.loke", "-dump-ast", `(const names=["sentinel"]`)
}

@(private)
check_diagnostics :: proc(t: ^testing.T, pattern: string, mode: string, sentinel: string) {
	cases, _ := filepath.glob(pattern)
	testing.expectf(t, len(cases) > 0, "no cases found for %s", pattern)
	for path in cases {
		check_one_diagnostic_case(t, path, expected_path(path), mode, sentinel)
	}
}

// Every immediate subdirectory of `root`, in the deterministic order the glob
// returns. Sibling `.expected` and `.flags` files are not cases.
@(private)
case_directories :: proc(t: ^testing.T, root: string) -> []string {
	entries, _ := filepath.glob(fmt.tprintf("%s/*", root))
	cases := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if os.is_dir(entry) {
			append(&cases, entry)
		}
	}
	testing.expectf(t, len(cases) > 0, "no cases found under %s", root)
	return cases[:]
}

// One case, whether it is a single file or a package directory: compile, run,
// and compare stdout.
@(private)
run_one_program :: proc(t: ^testing.T, path, expected_file, exe: string) {
	expected, has_expected := os.read_entire_file(expected_file)
	if !testing.expectf(t, has_expected, "%s: missing .expected file", path) {
		return
	}

	command := make([dynamic]string, context.temp_allocator)
	append(&command, compiler_path(), path, "-o", exe)
	for flag in env_flags() {
		append(&command, flag)
	}
	for flag in extra_flags(path) {
		append(&command, flag)
	}
	state, _, stderr, err := os2.process_exec(os2.Process_Desc{command = command[:]}, context.allocator)
	if !testing.expectf(t, err == nil, "%s: cannot run %s", path, compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "%s: compile failed\n%s", path, string(stderr)) {
		return
	}

	run_state, stdout, _, run_err := os2.process_exec(
		os2.Process_Desc{command = []string{exe}},
		context.allocator,
	)
	testing.expectf(t, run_err == nil, "%s: cannot run the produced exe", path)
	testing.expectf(t, run_state.exit_code == 0, "%s: exited with %d", path, run_state.exit_code)
	testing.expectf(
		t,
		normalise(string(stdout)) == normalise(string(expected)),
		"%s: expected %q, got %q",
		path,
		normalise(string(expected)),
		normalise(string(stdout)),
	)
}

// One case: compile it, then assert the exact diagnostic count plus every
// listed code, message substring, and `@line:column` span.
@(private)
check_one_diagnostic_case :: proc(t: ^testing.T, path, expected_file, mode, sentinel: string) {
	expected, has_expected := os.read_entire_file(expected_file)
	if !testing.expectf(t, has_expected, "%s: missing .expected file", path) {
		return
	}

	command := make([dynamic]string, context.temp_allocator)
	append(&command, compiler_path(), path, mode)
	for flag in extra_flags(path) {
		append(&command, flag)
	}
	state, stdout, stderr, err := os2.process_exec(
		os2.Process_Desc{command = command[:]},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "%s: cannot run %s", path, compiler_path()) {
		return
	}
	testing.expectf(t, state.exit_code == 1, "%s: expected exit 1, got %d", path, state.exit_code)
	if sentinel != "" {
		testing.expectf(
			t,
			strings.contains(string(stdout), sentinel),
			"%s: recovery did not reach the trailing sentinel",
			path,
		)
	}

	output := string(stderr)
	expected_errors := 0
	for raw_line in strings.split_lines(normalise(string(expected))) {
		line := strings.trim_space(raw_line)
		if line == "" {
			continue
		}
		if strings.has_prefix(line, "@") {
			if line == "@no-span" {
				testing.expectf(t, !strings.contains(output, " --> "), "%s: expected a location-free diagnostic\n%s", path, output)
			} else {
				location := line[1:]
				testing.expectf(
					t,
					strings.contains(output, strings.concatenate({":", location})),
					"%s: diagnostics do not contain span %s\n%s",
					path,
					location,
					output,
				)
			}
			continue
		}
		if strings.has_prefix(line, "L0") {
			expected_errors += 1
		}
		testing.expectf(
			t,
			strings.contains(output, line),
			"%s: diagnostics do not mention %q\n--- got ---\n%s",
			path,
			line,
			output,
		)
	}
	testing.expectf(
		t,
		strings.count(output, "error[L") == expected_errors,
		"%s: expected %d diagnostics, got %d\n%s",
		path,
		expected_errors,
		strings.count(output, "error[L"),
		output,
	)
}

// A case may sit beside a `.flags` file holding extra compiler options, one per
// line — which is how a `-define` override or a `-collection` root is tested
// without a second harness.
@(private)
extra_flags :: proc(path: string) -> []string {
	text, ok := os.read_entire_file(fmt.tprintf("%s.flags", strings.trim_suffix(path, ".loke")))
	if !ok {
		return nil
	}
	flags := make([dynamic]string, context.temp_allocator)
	for raw_line in strings.split_lines(normalise(string(text))) {
		if line := strings.trim_space(raw_line); line != "" {
			append(&flags, line)
		}
	}
	return flags[:]
}

@(private)
expected_path :: proc(path: string) -> string {
	return fmt.tprintf("%s.expected", strings.trim_suffix(path, ".loke"))
}

@(private)
normalise :: proc(s: string) -> string {
	return strings.trim_space(strings.replace_all(s, "\r\n", "\n") or_else s)
}
