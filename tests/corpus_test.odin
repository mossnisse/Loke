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
import "core:os"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:testing"

LOKEC :: "lokec.exe"
TMP :: "tests/tmp"

@(test)
front_end_modes :: proc(t: ^testing.T) {
	parse_state, parse_stdout, parse_stderr, parse_err := os2.process_exec(
		os2.Process_Desc{command = []string{LOKEC, "examples/hello.loke", "-parse-only"}},
		context.allocator,
	)
	testing.expectf(t, parse_err == nil, "cannot run %s in parse-only mode", LOKEC)
	testing.expectf(t, parse_state.exit_code == 0, "parse-only failed:\n%s", string(parse_stderr))
	testing.expectf(t, len(parse_stdout) == 0, "parse-only unexpectedly wrote output: %s", string(parse_stdout))

	dump_state, dump_stdout, dump_stderr, dump_err := os2.process_exec(
		os2.Process_Desc{command = []string{LOKEC, "examples/hello.loke", "-dump-ast"}},
		context.allocator,
	)
	testing.expectf(t, dump_err == nil, "cannot run %s in AST-dump mode", LOKEC)
	testing.expectf(t, dump_state.exit_code == 0, "AST dump failed:\n%s", string(dump_stderr))
	testing.expectf(
		t,
		strings.has_prefix(string(dump_stdout), `(file package="main"`),
		"unexpected AST dump:\n%s",
		string(dump_stdout),
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

@(test)
programs_trap :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	cases, _ := filepath.glob("tests/trap/*.loke")
	testing.expect(t, len(cases) > 0, "no runtime-trap cases found")

	for path in cases {
		exe := fmt.tprintf("%s/trap-%s.exe", TMP, filepath.stem(path))
		state, _, stderr, err := os2.process_exec(
			os2.Process_Desc{command = []string{LOKEC, path, "-o", exe}},
			context.allocator,
		)
		if !testing.expectf(t, err == nil, "%s: cannot run %s", path, LOKEC) {
			continue
		}
		if !testing.expectf(t, state.exit_code == 0, "%s: compile failed\n%s", path, string(stderr)) {
			continue
		}

		run_state, _, _, run_err := os2.process_exec(
			os2.Process_Desc{command = []string{exe}},
			context.allocator,
		)
		testing.expectf(t, run_err == nil, "%s: cannot run the produced exe", path)
		testing.expectf(t, run_state.exit_code != 0, "%s: expected a runtime failure", path)
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
			os2.Process_Desc{command = []string{LOKEC, path, "-o", exe, "-emit-ll"}},
			context.allocator,
		)
		if !testing.expectf(t, err == nil, "%s: cannot run %s", path, LOKEC) {
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
			os2.Process_Desc{command = []string{LOKEC, path, "-o", exe, "-check-layout"}},
			context.allocator,
		)
		if !testing.expectf(t, err == nil, "%s: cannot run %s", path, LOKEC) {
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
	append(&command, LOKEC, path, "-o", exe)
	for flag in extra_flags(path) {
		append(&command, flag)
	}
	state, _, stderr, err := os2.process_exec(os2.Process_Desc{command = command[:]}, context.allocator)
	if !testing.expectf(t, err == nil, "%s: cannot run %s", path, LOKEC) {
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
	append(&command, LOKEC, path, mode)
	for flag in extra_flags(path) {
		append(&command, flag)
	}
	state, stdout, stderr, err := os2.process_exec(
		os2.Process_Desc{command = command[:]},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "%s: cannot run %s", path, LOKEC) {
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
