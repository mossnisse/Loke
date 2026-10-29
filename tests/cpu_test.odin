// compiler-guide.md "CPU levels": a level changes the instructions a program
// is built from, never what it computes.
package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The run cases whose output a level could move: fused or unfused arithmetic,
// `math.fma` as an instruction, the bit operations v3 has instructions for,
// vectors at twice the width, and the distributions over all of them. Each
// keeps its one `.expected`, which the ordinary run corpus pins at baseline.
@(private = "file")
CPU_LEVEL_CASES :: []string {
	"tests/run/float_contraction.loke",
	"tests/run/lib_math.loke",
	"tests/run/lib_math_bits.loke",
	"tests/run/lib_simd.loke",
	"tests/run/simd_byte_lanes.loke",
	"tests/run/lib_random.loke",
}

@(private = "file")
CPU_LEVELS :: []string{"x86-64-v2", "x86-64-v3"}

// What the startup check prints on a processor without the level.
@(private = "file")
UNSUPPORTED_CPU :: "loke: this processor does not support "

@(test)
cpu_levels_compute_what_baseline_does :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/cpu", TMP)
	os.make_directory(TMP)
	os.make_directory(dir)
	compiles := make([dynamic]Exec, context.temp_allocator)
	for level in CPU_LEVELS {
		for path in CPU_LEVEL_CASES {
			command := make([dynamic]string, context.temp_allocator)
			exe := fmt.tprintf("%s/%s-%s.exe", dir, filepath.stem(path), level)
			append(&command, compiler_path(), path, "-o", exe, fmt.tprintf("-cpu=%s", level))
			append(&command, ..env_flags())
			append(&compiles, Exec{command = command[:]})
		}
	}
	exec_all(compiles[:])

	runs := make([]Exec, len(compiles), context.temp_allocator)
	for job, index in compiles {
		if !testing.expectf(t, job.err == nil, "cannot run %s", compiler_path()) {
			continue
		}
		if !testing.expectf(t, job.state.exit_code == 0, "%v failed:\n%s", job.command, string(job.stderr)) {
			continue
		}
		runs[index].command = make([]string, 1, context.temp_allocator)
		runs[index].command[0] = launch_path(job.command[3])
	}
	exec_all(runs)

	levels, cases := CPU_LEVELS, CPU_LEVEL_CASES
	for run, index in runs {
		if run.command == nil {
			continue
		}
		level, path := levels[index / len(cases)], cases[index % len(cases)]
		if run.state.exit_code == 3 && strings.has_prefix(string(run.stderr), UNSUPPORTED_CPU) {
			skipped_capability(t, fmt.tprintf("this processor does not run %s", level))
			continue
		}
		testing.expectf(t, run.err == nil && run.state.exit_code == 0, "%s at -cpu=%s exited %d", path, level, run.state.exit_code)
		expected, expected_err := os.read_entire_file(expected_path(path), context.temp_allocator)
		if !testing.expectf(t, expected_err == nil, "%s: missing .expected file", path) {
			continue
		}
		testing.expectf(
			t,
			normalise(string(run.stdout)) == normalise(string(expected)),
			"%s at -cpu=%s: expected %q, got %q",
			path, level, normalise(string(expected)), normalise(string(run.stdout)),
		)
	}
}
