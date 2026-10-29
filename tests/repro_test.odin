// deterministic-math-and-targets-plan.md "Validation and performance gates":
// `core:math/repro` against the oracle in tests/math_oracle.odin.
package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

// The constants in core/math/repro are what the oracle derives.
@(test)
repro_constants_match_their_derivation :: proc(t: ^testing.T) {
	o: Oracle
	oracle_init(&o)
	defer oracle_destroy(&o)
	check_generated_block(t, "core/math/repro/exp.loke", exp_constants_source(&o))
	check_generated_block(t, "core/math/repro/log.loke", log_constants_source(&o))
	check_generated_block(t, "core/math/repro/trig.loke", trig_constants_source(&o))
}

@(private = "file")
check_generated_block :: proc(t: ^testing.T, path: string, expected: string) {
	source, err := os.read_entire_file(path, context.allocator)
	if !testing.expectf(t, err == nil, "cannot read %s", path) {
		return
	}
	text := strings.replace_all(string(source), "\r\n", "\n") or_else string(source)
	BEGIN :: "// BEGIN GENERATED\n"
	start := strings.index(text, BEGIN)
	end := strings.index(text, "// END GENERATED")
	if !testing.expectf(t, start >= 0 && end > start, "%s has no generated block", path) {
		return
	}
	testing.expectf(
		t,
		text[start + len(BEGIN):end] == expected,
		"%s's generated block is stale; it should read:\n%s",
		path,
		expected,
	)
}

// The package's functions agree with their slow paths, which the probe
// reaches through a copy of the package with tests/repro/probe_hook.loke
// added, over seeded arguments, and with the oracle over a sample of them.
// The constants the probe folds agree with the same calls at run time.
@(test)
repro_functions_round_correctly :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/repro_probe", TMP)
	dir := fmt.tprintf("%s/repro", root)
	os.make_directory(TMP)
	os.make_directory(root)
	os.make_directory(dir)
	package_sources, _ := filepath.glob("core/math/repro/*.loke", context.temp_allocator)
	sources := make([dynamic]string, context.temp_allocator)
	append(&sources, ..package_sources)
	append(&sources, "tests/repro/probe_hook.loke")
	for path in sources {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, read_err == nil, "cannot read %s", path) {
			return
		}
		_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, filepath.base(path)), data)
	}
	exe := fmt.tprintf("%s/probe.exe", root)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, compiler_path(), "tests/repro/probe.loke", fmt.tprintf("-collection:probe=%s", root), "-o", exe)
	append(&command, ..env_flags())
	state, _, stderr, err := exec(os.Process_Desc{command = command[:]}, context.allocator)
	if !testing.expectf(t, err == nil && state.exit_code == 0, "the probe build failed:\n%s", string(stderr)) {
		return
	}
	run, stdout, run_stderr, run_err := exec(os.Process_Desc{command = []string{launch_path(exe)}}, context.allocator)
	if !testing.expectf(t, run_err == nil && run.exit_code == 0, "the probe failed:\n%s", string(run_stderr)) {
		return
	}

	o: Oracle
	oracle_init(&o)
	defer oracle_destroy(&o)
	checked, constants := 0, 0
	text := string(stdout)
	for line in strings.split_lines_iterator(&text) {
		fields := strings.fields(strings.trim_space(line), context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "constant":
			testing.expectf(t, !strings.contains(line, "false"), "a folded call differs from the run-time call: %s", line)
			constants += len(fields) - 1
		case "compared":
			testing.expectf(t, len(fields) == 5 && fields[3] == "0" && fields[4] == "0", "a fast path differs from its slow path: %s", line)
		case "differs64", "differs32":
			testing.expectf(t, false, "a fast path differs from its slow path at %s", line)
		case "Exp", "Sin", "Cos", "Log":
			function := Oracle_Function.Exp
			if fields[0] == "Sin" {function = .Sin}
			if fields[0] == "Cos" {function = .Cos}
			if fields[0] == "Log" {function = .Log}
			x, _ := strconv.parse_u64(fields[2])
			got, _ := strconv.parse_u64(fields[3])
			argument := transmute(f64)x
			format := F64_FORMAT
			if fields[1] == "32" {
				argument = f64(transmute(f32)u32(x))
				format = F32_FORMAT
			}
			want := oracle_eval(&o, function, argument, format)
			testing.expectf(t, got == want, "%s at f%s of %v: got %x, the oracle %x", fields[0], fields[1], argument, got, want)
			checked += 1
		}
	}
	testing.expectf(t, checked == 10007 && constants == 18, "the probe printed %d checked results and %d constants", checked, constants)
}
