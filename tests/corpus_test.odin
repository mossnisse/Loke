// The whole executable test harness. Corpora shelling out to
// the built compiler, plus the parser's own:
//
//   tests/run/*.loke + .expected   compile, run, compare stdout; an optional
//                                  sibling .expected-err compares stderr too
//   tests/ll/*.loke  + .expected   compile with -emit-ll, assert the generated
//                                  IR still contains each listed shape; a `*`
//                                  matches any run inside one IR line
//   tests/err/*.loke + .expected   compile, assert exact diagnostic count plus
//                                  code/message substrings and @line:column spans;
//                                  a `!`-prefixed line must *not* appear
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
//   tests/os/environment.{loke,    a program run with an environment block the
//     expected}                    program could not create for itself: a
//                                  variable whose value is the empty string
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
//.
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

// A seed runtime that exists but does not define everything the module calls
// is a runtime failure, not a foreign one. `loke_rt.h` makes the ABI version
// part of every exported name so a stale directory fails to link instead of
// agreeing on a changed record — and that link failure has to name the runtime
// it came from, since the program here imports nothing foreign at all.
@(test)
a_partial_seed_runtime_is_not_a_foreign_failure :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	partial := fmt.tprintf("%s/partial-runtime", TMP)
	os.make_directory(partial)
	// The header plus one source: enough to compile, far too little to link.
	for name in ([]string{"loke_rt.h", "alloc.c"}) {
		content, read := os.read_entire_file(filepath.join({"runtime", name}, context.temp_allocator))
		if !testing.expectf(t, read, "cannot read runtime/%s", name) {
			return
		}
		defer delete(content)
		os.write_entire_file(filepath.join({partial, name}, context.temp_allocator), content)
	}

	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc {
			command = []string {
				compiler_path(), "examples/hello.loke",
				"-o", fmt.tprintf("%s/partial-runtime.exe", TMP),
				fmt.tprintf("-runtime=%s", partial),
			},
		},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	testing.expectf(t, state.exit_code == 2, "a partial seed runtime linked")
	testing.expectf(
		t,
		!strings.contains(string(stderr), "L0633"),
		"a partial seed runtime was blamed on a foreign import:\n%s",
		string(stderr),
	)
	testing.expectf(
		t,
		strings.contains(string(stderr), "L0403") && strings.contains(string(stderr), partial),
		"expected L0403 naming %s, got:\n%s",
		partial,
		string(stderr),
	)
}

// `-o` chooses the artifact path, and `.ll` is a legal thing to call an
// executable. The generated module is derived from that same path, so the
// build must not take its own output for a temporary and delete it.
@(test)
a_dot_ll_output_survives_its_own_build :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	out := fmt.tprintf("%s/dot-ll-output.ll", TMP)
	os.remove(out)
	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = []string{compiler_path(), "examples/hello.loke", "-o", out}},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "building to %s failed:\n%s", out, string(stderr)) {
		return
	}
	testing.expectf(t, os.is_file(out), "the build reported success and left no %s", out)
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
			testing.expectf(t, ir_contains(string(ir), line), "%s: IR does not contain %q", path, line)
		}
	}
}

// A `*` matches any run of characters inside one IR line. A type name carries
// its `Type_Id` (`%struct.Point.49`), and which id a type gets is decided by the
// order packages are prepared in, so a fixture quoting one asserted that order
// rather than the shape it meant to pin. The wildcard stops at a line ending: a
// fragment quoted from one instruction must still be found in one instruction,
// not assembled from two.
@(private)
ir_contains :: proc(ir: string, pattern: string) -> bool {
	if !strings.contains(pattern, "*") {
		return strings.contains(ir, pattern)
	}
	segments := strings.split(pattern, "*", context.temp_allocator)
	for line in strings.split_lines(ir, context.temp_allocator) {
		if ir_line_matches(line, segments) {
			return true
		}
	}
	return false
}

@(private = "file")
ir_line_matches :: proc(line: string, segments: []string) -> bool {
	rest := line
	for segment in segments {
		// Empty where the pattern begins or ends with `*`, or writes two in a row.
		if segment == "" {
			continue
		}
		at := strings.index(rest, segment)
		if at < 0 {
			return false
		}
		rest = rest[at + len(segment):]
	}
	return true
}

// The matcher's interesting property is what it refuses: a `*` that crossed a
// line ending would let two unrelated instructions satisfy one quoted shape.
@(test)
ir_wildcard_stays_inside_one_line :: proc(t: ^testing.T) {
	ir := "%t1 = getelementptr %struct.Point.49, ptr %p\n%t2 = add i64 %a, %b\n"
	testing.expect(t, ir_contains(ir, "%t1 = getelementptr %struct.Point.*, ptr %p"))
	testing.expect(t, ir_contains(ir, "getelementptr %struct.Point.49, ptr %p"))
	testing.expect(t, ir_contains(ir, "*add i64*"))
	// Both halves are present, one per line, so only the line bound rejects this.
	testing.expect(t, !ir_contains(ir, "%t1 = *%b"))
	testing.expect(t, !ir_contains(ir, "%struct.Point.*, ptr %q"))
}

// Unwind environments assign slots on first use. Keep thunk emission in that
// same order: iterating the symbol-to-slot map here used to produce several
// byte-distinct modules for one unchanged input.
@(test)
generated_ir_is_reproducible :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	exe := fmt.tprintf("%s/deterministic.exe", TMP)
	ll_path := fmt.tprintf("%s/deterministic.ll", TMP)
	baseline: string
	for run := 0; run < 12; run += 1 {
		state, _, stderr, err := os2.process_exec(
			os2.Process_Desc{command = []string{
				compiler_path(), "tests/run/m3_eval.loke", "-o", exe, "-emit-ll",
			}},
			context.allocator,
		)
		if !testing.expectf(t, err == nil, "run %d: cannot run %s", run + 1, compiler_path()) {
			return
		}
		if !testing.expectf(t, state.exit_code == 0, "run %d: compile failed\n%s", run + 1, string(stderr)) {
			return
		}
		ir, read_ok := os.read_entire_file(ll_path)
		if !testing.expectf(t, read_ok, "run %d: no IR at %s", run + 1, ll_path) {
			return
		}
		if run == 0 {
			baseline = string(ir)
			continue
		}
		if !testing.expectf(t, string(ir) == baseline, "run %d: generated IR changed", run + 1) {
			return
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

// A package's mangled prefix comes from its directory, not from whichever import
// spelling the discovery walk bound first: `tests/pkg/spelling` reaches one
// directory both relatively, from the file that sorts first, and through the
// collection it lives in. `packages_run` already proves the program builds and
// runs; this asserts the name it built.
@(test)
package_keys_come_from_the_directory :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	exe := fmt.tprintf("%s/spelling-ir.exe", TMP)
	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc {
			command = []string {
				compiler_path(), "tests/pkg/spelling", "-o", exe, "-emit-ll",
				"-collection", "myc=tests/pkg/spelling",
			},
		},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "compile failed:\n%s", string(stderr)) {
		return
	}
	ir, read_ok := os.read_entire_file(fmt.tprintf("%s/spelling-ir.ll", TMP))
	if !testing.expect(t, read_ok, "no IR was emitted") {
		return
	}
	testing.expect(
		t,
		strings.contains(string(ir), "@loke.p.myc$3alib.value"),
		"the collection the package lives in did not name it",
	)
	testing.expect(
		t,
		!strings.contains(string(ir), "@loke.p.lib.value"),
		"the relative import spelling decided the package key",
	)
}

// design.md "Program entry and exit": the corpus runs every
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

// `core:os` says `Option` separates a variable that is not set from one whose
// value is the empty string. Windows deletes a variable set to "", so no program
// can build that environment for itself — this is the one case that needs the
// parent to hand over an environment block, which the glob corpus cannot express.
@(test)
empty_environment_values_are_values :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	exe := fmt.tprintf("%s/os-environment.exe", TMP)
	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = []string{compiler_path(), "tests/os/environment.loke", "-o", exe}},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "compile failed:\n%s", string(stderr)) {
		return
	}

	expected, has_expected := os.read_entire_file("tests/os/environment.expected")
	if !testing.expect(t, has_expected, "missing tests/os/environment.expected") {
		return
	}

	// `env` replaces the block wholesale, so the inherited one is carried over:
	// dropping it would change what the child can do for reasons unrelated to
	// the three variables under test.
	inherited, environ_err := os2.environ(context.allocator)
	if !testing.expectf(t, environ_err == nil, "cannot read this process' environment") {
		return
	}
	block := make([dynamic]string, context.temp_allocator)
	append(&block, ..inherited)
	append(&block, "LOKE_EMPTY_PROBE=", "LOKE_VALUE_PROBE=fivec")

	run_state, stdout, _, run_err := os2.process_exec(
		os2.Process_Desc{command = []string{exe}, env = block[:]},
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

// design.md "Foreign system": an `exe` build assembles a `.asm` import with
// `nasm` and links the object it produced — the half an `obj` build refuses.
// That object is the build's own temporary, written beside the executable
// rather than into a temp directory, so it has to reach the link and it has to
// not outlive it. Skips rather than fails when `nasm` is not installed.
@(test)
assembled_inputs_reach_the_link_and_not_the_output_directory :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	nasm := os.get_env("LOKE_NASM", context.temp_allocator)
	if nasm == "" {
		nasm = "nasm"
	}
	if _, _, _, probe := os2.process_exec(
		os2.Process_Desc{command = []string{nasm, "-v"}},
		context.allocator,
	); probe != nil {
		log.info("no nasm found; skipping the assembly-import link")
		return
	}

	// Its own directory: an assembled object is named after its source, and the
	// corpus runs several tests into TMP at once.
	dir := fmt.tprintf("%s/asm-exe", TMP)
	os.make_directory(dir)
	for stale in assembled_objects(dir) {
		os.remove(stale)
	}
	exe := fmt.tprintf("%s/asm-exe.exe", dir)

	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = []string{compiler_path(), "tests/obj/asm_exe.loke", "-o", exe}},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "an assembly import failed to link:\n%s", string(stderr)) {
		return
	}
	run_state, _, _, run_err := os2.process_exec(os2.Process_Desc{command = []string{exe}}, context.allocator)
	testing.expectf(t, run_err == nil, "cannot run %s", exe)
	testing.expectf(
		t,
		run_state.exit_code == 0,
		"the assembled input gave the wrong answer (exit %d)",
		run_state.exit_code,
	)
	testing.expectf(t, len(assembled_objects(dir)) == 0, "the link left its assembled object in %s", dir)

	// `-keep-temps` governs it too: the object is a build temporary like the
	// generated module, not something the build set out to produce.
	kept_state, _, kept_stderr, kept_err := os2.process_exec(
		os2.Process_Desc {
			command = []string{compiler_path(), "tests/obj/asm_exe.loke", "-o", exe, "-keep-temps"},
		},
		context.allocator,
	)
	testing.expectf(t, kept_err == nil, "cannot run %s", compiler_path())
	testing.expectf(
		t,
		kept_state.exit_code == 0,
		"an assembly import failed to link:\n%s",
		string(kept_stderr),
	)
	testing.expectf(
		t,
		len(assembled_objects(dir)) == 1,
		"-keep-temps did not keep the assembled object in %s",
		dir,
	)
}

// The objects `assemble_nasm` writes for `tests/obj/helper.asm`, whatever
// digest it gave them.
@(private)
assembled_objects :: proc(dir: string) -> []string {
	matches, _ := filepath.glob(fmt.tprintf("%s/helper.*.obj", dir), context.temp_allocator)
	return matches
}

// design.md "Build modes": `-build-mode=obj` produces one
// relocatable module from a non-`main` root. This links it into a C program that
// owns process entry and supplies the seed runtime, and asserts the object
// defines no entry symbol of its own.
@(test)
object_build_links_into_a_c_host :: proc(t: ^testing.T) {
	os.make_directory(TMP)

	// design.md "Build modes": one relocatable object cannot carry an assembled
	// input, so an `obj` build that imports one says what its consumer must do
	//. Every recognized assembly extension owes that diagnostic, each naming the
	// command its own syntax needs — a `.s` that slipped through would leave the
	// host an undefined symbol and no hint. This needs no toolchain, so it runs
	// before the skip below.
	assembly_cases := [][2]string {
		{"tests/obj/asm_import.loke", "nasm -f win64"},
		{"tests/obj/asm_import_gnu.loke", "clang -c"},
	}
	for assembly_case in assembly_cases {
		source, assembler := assembly_case[0], assembly_case[1]
		asm_state, _, asm_stderr, asm_err := os2.process_exec(
			os2.Process_Desc {
				command = []string {
					compiler_path(), source, "-build-mode=obj",
					"-o", fmt.tprintf("%s/%s.obj", TMP, filepath.stem(source)),
				},
			},
			context.allocator,
		)
		if !testing.expectf(t, asm_err == nil, "cannot run %s", compiler_path()) {
			continue
		}
		testing.expectf(t, asm_state.exit_code != 0, "an `obj` build accepted %s", source)
		testing.expectf(
			t,
			strings.contains(string(asm_stderr), "L0603") &&
			strings.contains(string(asm_stderr), assembler),
			"an `obj` build of %s did not report L0603 naming `%s`:\n%s",
			source,
			assembler,
			string(asm_stderr),
		)
	}

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
			// design.md "Build modes": an object that selects nothing exports no
			// initializer, so an existing host needs no change.
			testing.expectf(
				t,
				!strings.contains(text, " T loke_rt_v1_program_init"),
				"an unselected object build exported an initializer:\n%s",
				text,
			)
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

	selected_object_build_links_into_a_c_host(t, clang, include_flags)
	atomics_hold_under_contention(t, clang, include_flags)
}

// design.md "Concurrency and the memory model": the atomic
// claims under real contention. There is no thread API in version 1 Loke, so
// the threads come from a C host that attaches and detaches each one, which is
// also the documented way a foreign thread calls into an object build.
//
// Every assertion inside is an invariant — a count, a publication, a single run
// — never an interleaving, because an interleaving is the scheduler's answer
// rather than the program's.
@(private)
atomics_hold_under_contention :: proc(t: ^testing.T, clang: string, include_flags: []string) {
	obj := fmt.tprintf("%s/conc.obj", TMP)
	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc {
			command = []string {
				compiler_path(), "tests/obj/concurrentlib", "-build-mode=obj", "-o", obj,
			},
		},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "the concurrency object build failed:\n%s", string(stderr)) {
		return
	}

	exe := fmt.tprintf("%s/conc-host.exe", TMP)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, clang, "tests/obj/concurrent_host.c", obj, "-o", exe, "-Wno-override-module", "-rtlib=compiler-rt")
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
	if !testing.expectf(t, link_state.exit_code == 0, "the concurrency host link failed:\n%s", string(link_stderr)) {
		return
	}
	run_state, _, _, run_err := os2.process_exec(os2.Process_Desc{command = []string{exe}}, context.allocator)
	testing.expectf(t, run_err == nil, "cannot run %s", exe)
	testing.expectf(
		t, run_state.exit_code == 0,
		"an atomic invariant did not hold under contention: failure %d (see `conc_check`)",
		run_state.exit_code,
	)
}

// design.md "Build modes" and "Build-selected providers": an
// object build that selects a provider exports `loke_rt_v1_program_init`, and
// its host calls that once after attaching. Nothing calls it automatically, so
// the whole contract is what the host does with it — including the second call,
// which must do nothing.
@(private)
selected_object_build_links_into_a_c_host :: proc(t: ^testing.T, clang: string, include_flags: []string) {
	obj := fmt.tprintf("%s/hostlib.obj", TMP)
	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc {
			command = []string {
				compiler_path(), "tests/obj/providerlib", "-build-mode=obj",
				"-collection", "obj=tests/obj/providerlib",
				"-provider", "allocator=obj:provider:allocator_factory",
				"-provider", "logger=obj:provider:logger_factory",
				"-o", obj,
			},
		},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "the selected object build failed:\n%s", string(stderr)) {
		return
	}

	nm := filepath.join({filepath.dir(clang), "llvm-nm.exe"}, context.temp_allocator)
	if os.is_file(nm) {
		nm_state, symbols, _, nm_err := os2.process_exec(
			os2.Process_Desc{command = []string{nm, obj}},
			context.allocator,
		)
		if testing.expectf(t, nm_err == nil && nm_state.exit_code == 0, "cannot list %s", obj) {
			text := string(symbols)
			testing.expectf(
				t,
				strings.contains(text, " T loke_rt_v1_program_init"),
				"a selected object build exported no initializer:\n%s",
				text,
			)
			testing.expectf(t, !strings.contains(text, " T wmain"), "the object defines `wmain`:\n%s", text)
		}
	}

	exe := fmt.tprintf("%s/provider-host.exe", TMP)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, clang, "tests/obj/provider_host.c", obj, "-o", exe, "-Wno-override-module", "-rtlib=compiler-rt")
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
	if !testing.expectf(t, link_state.exit_code == 0, "the selected host link failed:\n%s", string(link_stderr)) {
		return
	}
	run_state, _, _, run_err := os2.process_exec(os2.Process_Desc{command = []string{exe}}, context.allocator)
	testing.expectf(t, run_err == nil, "cannot run %s", exe)
	testing.expectf(
		t, run_state.exit_code == 0,
		"the selected C host reported failure %d (see `hostlib_report`)", run_state.exit_code,
	)
}

// Every toolchain test in this file skips on `-print-toolchain` saying
// `ready=no`, so that answer has to be the same one a build gives: a
// `ready=yes` that cannot link fails all of them at once, and a `ready=no`
// that could link stops running them without saying so. Tying the two
// together is what keeps readiness from being computed a way that only looks
// right — counting the flags it happened to print, say.
@(test)
the_reported_toolchain_agrees_with_a_real_build :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	state, stdout, _, err := os2.process_exec(
		os2.Process_Desc{command = []string{compiler_path(), "-print-toolchain"}},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "-print-toolchain failed") {
		return
	}
	report := string(stdout)
	// The two lines the harness reads by name, plus the one it counts on being
	// absent or present rather than parsed.
	testing.expectf(t, strings.contains(report, "clang="), "no clang line:\n%s", report)
	testing.expectf(
		t,
		strings.contains(report, "ready=yes") || strings.contains(report, "ready=no"),
		"no ready line:\n%s",
		report,
	)
	ready := strings.contains(report, "ready=yes")

	build, _, build_stderr, build_err := os2.process_exec(
		os2.Process_Desc {
			command = []string {
				compiler_path(), "examples/hello.loke",
				"-o", fmt.tprintf("%s/toolchain-report.exe", TMP),
			},
		},
		context.allocator,
	)
	if !testing.expectf(t, build_err == nil, "cannot run %s", compiler_path()) {
		return
	}
	testing.expectf(
		t,
		ready == (build.exit_code == 0),
		"-print-toolchain reported ready=%v and a build exited %d:\n%s\n%s",
		ready,
		build.exit_code,
		report,
		string(build_stderr),
	)
}

// clang plus the `-isystem`/`-L` flags its Windows target needs outside a
// developer prompt, asked of the compiler instead of worked out again here:
// `-print-toolchain` reports the discovery `link` performs in
// `src/emit_llvm_toolchain.odin`, so one set of rules decides what a build and
// this test both link against. The copy that used to live here drifted looser
// than them — globbing one install root where the compiler globs two, and
// gating the `-L` on `INCLUDE` — which skipped this test, and in one
// half-configured environment failed it, where a real build worked.
//
// `ready` is the compiler's own answer to whether a link could run at all on
// this machine. The test skips rather than fails when it says no.
@(private)
host_toolchain :: proc() -> (clang: string, flags: []string, ok: bool) {
	state, stdout, _, err := os2.process_exec(
		os2.Process_Desc{command = []string{compiler_path(), "-print-toolchain"}},
		context.allocator,
	)
	if err != nil || state.exit_code != 0 {
		return "", nil, false
	}
	// `flag=` lines are passed through in the order they were printed; the
	// harness never has to know which of them pair up.
	out := make([dynamic]string, context.temp_allocator)
	ready := false
	for line in strings.split_lines(string(stdout), context.temp_allocator) {
		key, _, value := strings.partition(strings.trim_space(line), "=")
		switch key {
		case "clang":
			clang = strings.clone(value, context.temp_allocator)
		case "flag":
			append(&out, strings.clone(value, context.temp_allocator))
		case "ready":
			ready = value == "yes"
		}
	}
	if !ready {
		return "", nil, false
	}
	return clang, out[:], true
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

	run_state, stdout, run_stderr, run_err := os2.process_exec(
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

	// stderr is ignored unless the case pins it with a sibling `.expected-err`.
	// A `core:log` record on the standard sink is what needs that: it is the
	// logger every unselected build gets, and comparing stdout alone never sees
	// a line of it.
	errors, has_errors := os.read_entire_file(fmt.tprintf("%s-err", expected_file))
	if !has_errors {
		return
	}
	testing.expectf(
		t,
		normalise(string(run_stderr)) == normalise(string(errors)),
		"%s: expected stderr %q, got %q",
		path,
		normalise(string(errors)),
		normalise(string(run_stderr)),
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
		// A leading `!` asserts the opposite: the diagnostics must *not* say this.
		// The count assertion below cannot see a surplus note, so a rule about what
		// a diagnostic leaves out needs its own line.
		if strings.has_prefix(line, "!") {
			absent := line[1:]
			testing.expectf(
				t,
				!strings.contains(output, absent),
				"%s: diagnostics should not mention %q\n--- got ---\n%s",
				path,
				absent,
				output,
			)
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

// ------------------------------------------------------------- examples --

// The programs under `examples/` are what `examples/README.md` teaches from, so
// they are the one corpus a reader compiles by hand. They are built from their
// real sources rather than from copies, which is the only way the check and the
// documentation cannot drift apart.
@(private)
Example_Check :: enum {
	// Run with no arguments and compare stdout with `tests/examples/<name>.expected`.
	Output,
	// Compiled here; its behaviour is asserted by its own test below, because it
	// needs arguments, standard input, or a directory of its own.
	Driven,
	// Compiled here; the rest needs a real console and is checked by hand
	// (`examples/README.md`, "Checking keys by hand").
	Interactive,
}

// Every example must say how it is checked. A new one with no entry fails this
// test rather than quietly going unchecked.
@(test)
examples_compile_and_run :: proc(t: ^testing.T) {
	os.make_directory(TMP)

	Entry :: struct {
		name:  string,
		check: Example_Check,
	}
	checks := []Entry {
		{"aliasing",       .Output},
		{"arena_pipeline", .Output},
		{"compile_time",   .Output},
		{"config_parser",  .Output},
		{"game_of_life",   .Output},
		{"greeting",       .Driven},
		{"hello",          .Output},
		{"keys",           .Interactive},
		{"shapes",         .Output},
		{"streaming",      .Driven},
		{"tokens",         .Output},
		{"word_frequency", .Output},
	}

	sources, _ := filepath.glob("examples/*.loke")
	testing.expectf(
		t,
		len(sources) == len(checks),
		"examples/ holds %d programs but %d are classified",
		len(sources),
		len(checks),
	)
	for source in sources {
		name := filepath.stem(source)
		classified := false
		for entry in checks {
			if entry.name == name {
				classified = true
				break
			}
		}
		testing.expectf(t, classified, "examples/%s.loke has no test classification", name)
	}

	for entry in checks {
		source := fmt.tprintf("examples/%s.loke", entry.name)
		exe := fmt.tprintf("%s/example-%s.exe", TMP, entry.name)
		if !compile_example(t, source, exe, nil) {
			continue
		}
		if entry.check != .Output {
			continue
		}
		expect_example_output(
			t, source, exe, nil, "",
			fmt.tprintf("tests/examples/%s.expected", entry.name),
		)
	}

	// The one example that takes a build value. The tables it computes during
	// compilation change size with it, so the default run alone would not show
	// that `-define` reached compile-time code at all.
	sieve := fmt.tprintf("%s/example-compile_time-sieve200.exe", TMP)
	if compile_example(t, "examples/compile_time.loke", sieve, []string{"-define:SIEVE_LIMIT=200"}) {
		expect_example_output(
			t, "examples/compile_time.loke (SIEVE_LIMIT=200)", sieve, nil, "",
			"tests/examples/compile_time.sieve200.expected",
		)
	}
}

// `greeting` reads a line from standard input and appends to a file in the
// working directory, so it needs both — and the point of the example is that the
// second run finds what the first one wrote, which only shows up across two runs
// in a directory nothing else touches.
@(test)
example_greeting_appends_to_its_file :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	dir := fmt.tprintf("%s/example-greeting", TMP)
	os2.remove_all(dir)
	os.make_directory(dir)

	// Built into the directory it runs in, so the redirect below needs no path.
	if !compile_example(t, "examples/greeting.loke", fmt.tprintf("%s/greeting.exe", dir), nil) {
		return
	}

	// The file does not exist on the first run, which the example treats as an
	// empty history rather than a failure.
	if !run_greeting(t, dir, "Ada\n") {
		return
	}
	expect_file_contents(t, fmt.tprintf("%s/greetings.txt", dir), "Hello, Ada!\n", "after the first run")

	if !run_greeting(t, dir, "Bo\n") {
		return
	}
	expect_file_contents(
		t, fmt.tprintf("%s/greetings.txt", dir),
		"Hello, Ada!\nHello, Bo!\n", "after the second run",
	)
}

// The redirect goes through the shell rather than `Process_Desc.stdin`: os2
// hands a supplied handle straight to `CreateProcessW`, and a handle from
// `os2.open` is not marked inheritable, so the child receives an invalid one and
// the example reports `Not_A_Terminal` instead of reading a name.
@(private)
run_greeting :: proc(t: ^testing.T, dir, input: string) -> bool {
	if !testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/stdin.txt", dir), transmute([]u8)input),
		"cannot write the greeting input file",
	) {
		return false
	}
	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{
			command     = []string{"cmd", "/c", ".\\greeting.exe < stdin.txt"},
			working_dir = dir,
		},
		context.allocator,
	)
	if !testing.expect(t, err == nil, "cannot run the greeting example") {
		return false
	}
	if !testing.expectf(
		t, state.exit_code == 0,
		"greeting exited with %d\n%s", state.exit_code, string(stderr),
	) {
		return false
	}
	// The example reports a failure and still exits 0, so the exit code alone
	// cannot tell a successful run from a reported one.
	return testing.expectf(
		t, normalise(string(stderr)) == "",
		"greeting reported %q", normalise(string(stderr)),
	)
}

// `streaming` is about what happens at the edges: no argument, a file it can
// read, a file that is not there, and one past its own read limit. Each is a
// different path out of `run`, and three of them report through stderr.
@(test)
example_streaming_reads_its_input :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	dir := fmt.tprintf("%s/example-streaming", TMP)
	os2.remove_all(dir)
	os.make_directory(dir)

	exe, exe_ok := filepath.abs(fmt.tprintf("%s/example-streaming.exe", TMP), context.allocator)
	if !testing.expect(t, exe_ok, "cannot resolve the streaming executable path") {
		return
	}
	if !compile_example(t, "examples/streaming.loke", exe, nil) {
		return
	}

	// Three lines, seventeen bytes: both numbers are checked, because the bounded
	// whole-file read and the fixed-buffer pass are separate walks over the same
	// file.
	if !testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/three.txt", dir),
			transmute([]u8)string("alpha\nbeta\ngamma\n"),
		),
		"cannot write the streaming input file",
	) {
		return
	}
	// One byte past `LIMIT`, which is what makes the bounded read fail rather
	// than merely being large.
	over_limit := make([]u8, 1024 * 1024 + 1, context.allocator)
	defer delete(over_limit)
	for index in 0 ..< len(over_limit) {
		over_limit[index] = 'x'
	}
	if !testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/big.txt", dir), over_limit),
		"cannot write the over-limit input file",
	) {
		return
	}

	expect_streaming(t, dir, exe, nil, 0, "", "usage: streaming <path>", "no argument")
	expect_streaming(t, dir, exe, []string{"three.txt"}, 0, "bytes: 17\nlines: 3", "", "a readable file")
	expect_streaming(t, dir, exe, []string{"nope.txt"}, 1, "", "Not_Found", "a missing file")
	expect_streaming(t, dir, exe, []string{"big.txt"}, 1, "", "Limit_Exceeded", "a file past the read limit")
}

// stdout is compared whole; stderr only has to carry the reason, so the exact
// wording of an `io.Error` stays the standard library's business.
@(private)
expect_streaming :: proc(
	t: ^testing.T,
	dir, exe: string,
	args: []string,
	exit_code: int,
	stdout_text, stderr_contains, what: string,
) {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, exe)
	for arg in args {
		append(&command, arg)
	}
	state, stdout, stderr, err := os2.process_exec(
		os2.Process_Desc{command = command[:], working_dir = dir},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "streaming with %s: cannot run", what) {
		return
	}
	testing.expectf(
		t, state.exit_code == exit_code,
		"streaming with %s: exited with %d, expected %d", what, state.exit_code, exit_code,
	)
	testing.expectf(
		t, normalise(string(stdout)) == normalise(stdout_text),
		"streaming with %s: expected %q, got %q", what, stdout_text, normalise(string(stdout)),
	)
	if stderr_contains != "" {
		testing.expectf(
			t, strings.contains(normalise(string(stderr)), stderr_contains),
			"streaming with %s: %q does not report %q",
			what, normalise(string(stderr)), stderr_contains,
		)
	}
}

@(private)
compile_example :: proc(t: ^testing.T, source, exe: string, flags: []string) -> bool {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, compiler_path(), source, "-o", exe)
	for flag in env_flags() {
		append(&command, flag)
	}
	for flag in flags {
		append(&command, flag)
	}
	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = command[:]},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "%s: cannot run %s", source, compiler_path()) {
		return false
	}
	return testing.expectf(t, state.exit_code == 0, "%s: compile failed\n%s", source, string(stderr))
}

@(private)
expect_example_output :: proc(
	t: ^testing.T,
	label, exe: string,
	args: []string,
	working_dir, expected_file: string,
) {
	expected, has_expected := os.read_entire_file(expected_file)
	if !testing.expectf(t, has_expected, "%s: missing %s", label, expected_file) {
		return
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, exe)
	for arg in args {
		append(&command, arg)
	}
	state, stdout, stderr, err := os2.process_exec(
		os2.Process_Desc{command = command[:], working_dir = working_dir},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "%s: cannot run %s", label, exe) {
		return
	}
	testing.expectf(
		t, state.exit_code == 0,
		"%s: exited with %d\n%s", label, state.exit_code, string(stderr),
	)
	testing.expectf(
		t,
		normalise(string(stdout)) == normalise(string(expected)),
		"%s: expected %q, got %q",
		label,
		normalise(string(expected)),
		normalise(string(stdout)),
	)
}

@(private)
expect_file_contents :: proc(t: ^testing.T, path, expected, what: string) {
	actual, ok := os.read_entire_file(path)
	if !testing.expectf(t, ok, "%s: %s was not written", what, path) {
		return
	}
	testing.expectf(
		t,
		normalise(string(actual)) == normalise(expected),
		"%s: %s holds %q, expected %q",
		what, path, normalise(string(actual)), normalise(expected),
	)
}
