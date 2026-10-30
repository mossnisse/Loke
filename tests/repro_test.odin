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
	check_generated_block(t, "core/math/repro/atan.loke", atan_constants_source(&o))
	check_generated_block(t, "core/math/repro/exp.loke", exp_constants_source(&o))
	check_generated_block(t, "core/math/repro/log.loke", log_constants_source(&o))
	check_generated_block(t, "core/math/repro/log_base.loke", log_base_constants_source(&o))
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
// The constants the probe folds agree with the same calls at run time. At
// `x86-64-v3`, where `two_product` takes the FMA instruction's error, the
// probe prints exactly what it does at baseline.
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
	levels := []string{"x86-64", "x86-64-v3"}
	builds := make([]Exec, len(levels), context.temp_allocator)
	for level, index in levels {
		command := make([dynamic]string, context.temp_allocator)
		exe := fmt.tprintf("%s/probe-%s.exe", root, level)
		append(&command, compiler_path(), "tests/repro/probe.loke", fmt.tprintf("-collection:probe=%s", root), "-o", exe)
		append(&command, fmt.tprintf("-cpu=%s", level))
		append(&command, ..env_flags())
		builds[index].command = command[:]
	}
	exec_all(builds)
	runs := make([]Exec, len(levels), context.temp_allocator)
	for build, index in builds {
		if !testing.expectf(t, build.err == nil && build.state.exit_code == 0, "the probe build at -cpu=%s failed:\n%s", levels[index], string(build.stderr)) {
			return
		}
		runs[index].command = make([]string, 1, context.temp_allocator)
		runs[index].command[0] = launch_path(build.command[4])
	}
	exec_all(runs)
	run, fused := runs[0], runs[1]
	if !testing.expectf(t, run.err == nil && run.state.exit_code == 0, "the probe failed:\n%s", string(run.stderr)) {
		return
	}
	stdout := run.stdout
	if fused.state.exit_code == 3 && strings.has_prefix(string(fused.stderr), UNSUPPORTED_CPU) {
		skipped_capability(t, "this processor does not run x86-64-v3")
	} else if testing.expectf(t, fused.err == nil && fused.state.exit_code == 0, "the probe at -cpu=x86-64-v3 failed:\n%s", string(fused.stderr)) {
		testing.expectf(t, string(fused.stdout) == string(stdout), "the probe's output at -cpu=x86-64-v3 differs from baseline's")
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
		case "Pow", "Hypot":
			x_bits, _ := strconv.parse_u64(fields[2])
			y_bits, _ := strconv.parse_u64(fields[3])
			got, _ := strconv.parse_u64(fields[4])
			x, y := transmute(f64)x_bits, transmute(f64)y_bits
			format := F64_FORMAT
			if fields[1] == "32" {
				x, y = f64(transmute(f32)u32(x_bits)), f64(transmute(f32)u32(y_bits))
				format = F32_FORMAT
			}
			want := fields[0] == "Pow" ? oracle_pow(&o, x, y, format) : oracle_hypot(x, y, format)
			testing.expectf(t, got == want, "%s at f%s of %v and %v: got %x, the oracle %x", fields[0], fields[1], x, y, got, want)
			checked += 1
		case "Norm4":
			values: [4]f64
			for i in 0 ..< 4 {
				pattern, _ := strconv.parse_u64(fields[2 + i])
				values[i] = fields[1] == "32" ? f64(transmute(f32)u32(pattern)) : transmute(f64)pattern
			}
			got, _ := strconv.parse_u64(fields[6])
			want := oracle_norm(values[:], fields[1] == "32" ? F32_FORMAT : F64_FORMAT)
			testing.expectf(t, got == want, "Norm4 at f%s of %v: got %x, the oracle %x", fields[1], values, got, want)
			checked += 1
		case "Atan2", "Atan":
			// atan x is atan2(x, 1).
			y_bits, _ := strconv.parse_u64(fields[2])
			x_bits := transmute(u64)f64(1)
			got, _ := strconv.parse_u64(fields[3])
			if fields[0] == "Atan2" {
				x_bits, _ = strconv.parse_u64(fields[3])
				got, _ = strconv.parse_u64(fields[4])
			}
			y, x := transmute(f64)y_bits, transmute(f64)x_bits
			format := F64_FORMAT
			if fields[1] == "32" {
				y = f64(transmute(f32)u32(y_bits))
				if fields[0] == "Atan2" {x = f64(transmute(f32)u32(x_bits))}
				format = F32_FORMAT
			}
			want := oracle_atan2(&o, y, x, format)
			testing.expectf(t, got == want, "%s at f%s of %v and %v: got %x, the oracle %x", fields[0], fields[1], y, x, got, want)
			checked += 1
		case "Sqrt":
			x, _ := strconv.parse_u64(fields[2])
			got, _ := strconv.parse_u64(fields[3])
			argument := transmute(f64)x
			format := F64_FORMAT
			if fields[1] == "32" {
				argument = f64(transmute(f32)u32(x))
				format = F32_FORMAT
			}
			want := oracle_sqrt(argument, format)
			testing.expectf(t, got == want, "Sqrt at f%s of %v: got %x, the oracle %x", fields[1], argument, got, want)
			checked += 1
		case "differs64", "differs32":
			testing.expectf(t, false, "a fast path differs from its slow path at %s", line)
		case "Exp", "Sin", "Cos", "Tan", "Log", "Log2", "Log10", "Asin", "Acos":
			function := Oracle_Function.Exp
			if fields[0] == "Sin" {function = .Sin}
			if fields[0] == "Cos" {function = .Cos}
			if fields[0] == "Tan" {function = .Tan}
			if fields[0] == "Log" {function = .Log}
			if fields[0] == "Log2" {function = .Log2}
			if fields[0] == "Log10" {function = .Log10}
			if fields[0] == "Asin" {function = .Asin}
			if fields[0] == "Acos" {function = .Acos}
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
	testing.expectf(t, checked == 37956 && constants == 107, "the probe printed %d checked results and %d constants", checked, constants)
}
