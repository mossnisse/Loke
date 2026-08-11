// The whole M0 test harness (compiler-plan E). Two corpora, one shelling out to
// the built compiler:
//
//   tests/run/*.loke + .expected   compile, run, compare stdout
//   tests/err/*.loke + .expected   compile, assert exact diagnostic count plus
//                                  code/message substrings and @line:column spans
//   tests/trap/*.loke              compile, run, expect a non-zero exit
//   tests/syntax_err/*.loke        the same, for parser diagnostics, and assert
//     with .expected               the file's trailing sentinel survived recovery
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
		expected, has_expected := os.read_entire_file(expected_path(path))
		if !testing.expectf(t, has_expected, "%s: missing .expected file", path) {
			continue
		}

		exe := fmt.tprintf("%s/%s.exe", TMP, filepath.stem(path))
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
		expected, has_expected := os.read_entire_file(expected_path(path))
		if !testing.expectf(t, has_expected, "%s: missing .expected file", path) {
			continue
		}

		state, stdout, stderr, err := os2.process_exec(
			os2.Process_Desc{command = []string{LOKEC, path, mode}},
			context.allocator,
		)
		if !testing.expectf(t, err == nil, "%s: cannot run %s", path, LOKEC) {
			continue
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
}

@(private)
expected_path :: proc(path: string) -> string {
	return fmt.tprintf("%s.expected", strings.trim_suffix(path, ".loke"))
}

@(private)
normalise :: proc(s: string) -> string {
	return strings.trim_space(strings.replace_all(s, "\r\n", "\n") or_else s)
}
