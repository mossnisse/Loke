// compiler-guide.md "CPU levels": a level changes the instructions a program
// is built from, never what it computes.
package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The run cases whose output a level could move: fused or unfused arithmetic,
// `math.fma` and the rounding to an integral value as instructions, the bit
// operations v3 has instructions for, vectors at twice the width, and the
// distributions over all of them, `core:math/repro`'s functions included, and
// the lockstep example, whose state hashes are the plan's phase 5 gate. Each
// keeps its one `.expected`, which the ordinary run corpus, or the examples
// test for the example, pins at baseline.
// The trap case binds the check the entry also calls above baseline.
@(private = "file")
CPU_LEVEL_CASES :: []string {
	"tests/run/float_contraction.loke",
	"tests/run/lib_math.loke",
	"tests/run/lib_math_bits.loke",
	"tests/run/lib_simd.loke",
	"tests/run/simd_byte_lanes.loke",
	"tests/run/lib_random.loke",
	"tests/run/lib_random_distributions.loke",
	"tests/run/lib_random_ziggurat.loke",
	"examples/lockstep.loke",
	"tests/trap/cpu_level_unknown.loke",
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
		// The trap case's level is one no processor has, which exits 3 too.
		trap := strings.has_prefix(path, "tests/trap/")
		testing.expectf(
			t,
			run.err == nil && run.state.exit_code == (trap ? 3 : 0),
			"%s at -cpu=%s exited %d",
			path, level, run.state.exit_code,
		)
		if trap {
			errors, errors_err := os.read_entire_file(fmt.tprintf("%s-err", expected_path(path)), context.temp_allocator)
			if testing.expectf(t, errors_err == nil, "%s: missing .expected-err file", path) {
				testing.expectf(
					t,
					normalise(string(run.stderr)) == normalise(string(errors)),
					"%s at -cpu=%s: expected stderr %q, got %q",
					path, level, normalise(string(errors)), normalise(string(run.stderr)),
				)
			}
		}
		expected_file := expected_path(path)
		if strings.has_prefix(path, "examples/") {
			expected_file = fmt.tprintf("tests/examples/%s.expected", filepath.stem(path))
		}
		expected, expected_err := os.read_entire_file(expected_file, context.temp_allocator)
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

// compiler-guide.md "CPU levels": an object build above baseline checks the
// processor before its host's `main`, from a static constructor. One host
// stands in for the check, to see it run once, first, for the object's level;
// the other links the runtime's own check, which passes on any processor that
// runs the level.
@(test)
object_checks_its_cpu_level_before_the_host :: proc(t: ^testing.T) {
	clang, include_flags, found := host_toolchain()
	if !found {
		skipped_capability(t, "no clang or MSVC toolset, so no object build reaches a C host")
		return
	}
	dir := fmt.tprintf("%s/cpu", TMP)
	os.make_directory(TMP)
	os.make_directory(dir)
	obj := fmt.tprintf("%s/widget-v2.obj", dir)
	state, _, stderr, err := exec(
		os.Process_Desc {
			command = []string{compiler_path(), "tests/obj/lib.loke", "-build-mode=obj", "-cpu=x86-64-v2", "-o", obj},
		},
		context.allocator,
	)
	if !testing.expectf(t, err == nil && state.exit_code == 0, "the v2 object build failed:\n%s", string(stderr)) {
		return
	}

	// The stand-in replaces `runtime/cpu.c`, which defines nothing else.
	stand_in := c_host_link_command(clang, "tests/obj/cpu_host.c", obj, fmt.tprintf("%s/cpu-host.exe", dir), include_flags)
	command := make([dynamic]string, context.temp_allocator)
	for word in stand_in {
		if filepath.base(word) != "cpu.c" {
			append(&command, word)
		}
	}
	real := c_host_link_command(clang, "tests/obj/host.c", obj, fmt.tprintf("%s/widget-host-v2.exe", dir), include_flags)
	links := []Exec{{command = command[:]}, {command = real}}
	exec_all(links)
	for link in links {
		if !testing.expectf(t, link.err == nil && link.state.exit_code == 0, "%v failed:\n%s", link.command, string(link.stderr)) {
			return
		}
	}

	runs := []Exec{{command = []string{launch_path(command[4])}}, {command = []string{launch_path(real[4])}}}
	exec_all(runs)
	testing.expectf(
		t,
		runs[0].err == nil && runs[0].state.exit_code == 0,
		"the object's constructor did not check level 1 exactly once before `main` (exit %d)",
		runs[0].state.exit_code,
	)
	if runs[1].state.exit_code == 3 && strings.has_prefix(string(runs[1].stderr), UNSUPPORTED_CPU) {
		skipped_capability(t, "this processor does not run x86-64-v2")
		return
	}
	testing.expectf(
		t,
		runs[1].err == nil && runs[1].state.exit_code == 0,
		"the v2 object's host exited %d:\n%s",
		runs[1].state.exit_code,
		string(runs[1].stderr),
	)
}
