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
	"tests/run/lib_linalg.loke",
	"tests/run/lib_linalg_rotations.loke",
	"tests/run/lib_linalg_edges.loke",
	"tests/run/lib_linalg_lanes.loke",
	"tests/run/lib_geometry_predicates.loke",
	"tests/run/lib_geometry_shapes.loke",
	"tests/run/lib_geometry_rays.loke",
	"tests/run/lib_geometry_polygons.loke",
	"tests/run/lib_geometry_lanes.loke",
	"tests/run/lib_geometry_ranges.loke",
	"tests/run/lib_dense.loke",
	"tests/run/lib_dense_solve.loke",
	"tests/run/lib_dense_qr.loke",
	"tests/run/lib_dense_eigen.loke",
	"tests/run/lib_dense_svd.loke",
	"tests/run/lib_dense_kernels.loke",
	"tests/run/lib_dense_complex.loke",
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
@(private)
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

// design.md "@(cpu_dispatch=<string>)": a baseline build runs a dispatched
// procedure's copy for `x86-64-v3` exactly where the processor has the level,
// which the same program built for the level tells, and its plain copy when
// `LOKE_DISPATCH_CPU` caps the level below it or names none. Every way
// computes the same bits, `core:math/repro`'s functions included.
@(test)
dispatched_procedures_compute_what_their_copies_do :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/cpu", TMP)
	os.make_directory(TMP)
	os.make_directory(dir)
	levels := []string{"x86-64", "x86-64-v3"}
	builds := make([]Exec, len(levels), context.temp_allocator)
	for level, index in levels {
		command := make([dynamic]string, context.temp_allocator)
		append(&command, compiler_path(), "tests/repro/dispatch.loke", fmt.tprintf("-cpu=%s", level))
		append(&command, "-o", fmt.tprintf("%s/dispatch-%s.exe", dir, level))
		append(&command, ..env_flags())
		builds[index].command = command[:]
	}
	exec_all(builds)
	for build, index in builds {
		if !testing.expectf(t, build.err == nil && build.state.exit_code == 0, "the build at -cpu=%s failed:\n%s", levels[index], string(build.stderr)) {
			return
		}
	}
	baseline := launch_path(fmt.tprintf("%s/dispatch-x86-64.exe", dir))
	inherited, environ_err := os.environ(context.allocator)
	if !testing.expect(t, environ_err == nil, "cannot read this process's environment") {
		return
	}
	level, _, level_stderr, level_err := exec(
		os.Process_Desc{command = []string{launch_path(fmt.tprintf("%s/dispatch-x86-64-v3.exe", dir))}, env = without_dispatch_cap(inherited)},
		context.allocator,
	)
	has_level := true
	if level.exit_code == 3 && strings.has_prefix(string(level_stderr), UNSUPPORTED_CPU) {
		has_level = false
	} else if !testing.expectf(t, level_err == nil && level.exit_code == 0, "the x86-64-v3 build exited %d", level.exit_code) {
		return
	}

	// The cap, if any, and whether the copy for the level runs under it.
	Case :: struct {
		cap:    string,
		copies: bool,
	}
	cases := []Case{{"", has_level}, {"x86-64-v3", has_level}, {"x86-64-v2", false}, {"x86-64", false}, {"none", false}}
	results := make([]string, len(cases), context.temp_allocator)
	for c, index in cases {
		env := without_dispatch_cap(inherited)
		if c.cap != "" {
			env = append_env(env, fmt.tprintf("LOKE_DISPATCH_CPU=%s", c.cap))
		}
		run, stdout, stderr, err := exec(os.Process_Desc{command = []string{baseline}, env = env}, context.allocator)
		if !testing.expectf(t, err == nil && run.exit_code == 0, "LOKE_DISPATCH_CPU=%q: exited %d:\n%s", c.cap, run.exit_code, string(stderr)) {
			return
		}
		text := string(stdout)
		first, _ := strings.split_lines_iterator(&text)
		testing.expectf(
			t, first == fmt.tprintf("copy %v main false", c.copies),
			"LOKE_DISPATCH_CPU=%q: expected the copy for the level %s, found %q",
			c.cap, c.copies ? "to run" : "not to run", first,
		)
		results[index] = text
	}
	for result, index in results {
		testing.expectf(t, result == results[0], "LOKE_DISPATCH_CPU=%q computed other bits", cases[index].cap)
	}
}

// The inherited environment with no `LOKE_DISPATCH_CPU`, which a developer may
// have set.
@(private = "file")
without_dispatch_cap :: proc(env: []string) -> []string {
	kept := make([dynamic]string, context.temp_allocator)
	for entry in env {
		if !strings.has_prefix(strings.to_upper(entry, context.temp_allocator), "LOKE_DISPATCH_CPU=") {
			append(&kept, entry)
		}
	}
	return kept[:]
}

// deterministic-math-and-targets-plan.md "Validation and performance gates":
// the object code itself shows what may run where. Built for baseline, no
// function but a dispatched procedure's copy for `x86-64-v3`, named `.v3`,
// holds an instruction beyond SSE2, so forcing the plain copies never meets
// one, and those copies do hold the FMA instruction. Built for `x86-64-v3`, a
// written `a*b + c` is still not fused.
@(test)
object_code_keeps_each_level_where_it_may_run :: proc(t: ^testing.T) {
	clang, _, found := host_toolchain()
	objdump, _ := filepath.join({filepath.dir(clang), "llvm-objdump.exe"}, context.temp_allocator)
	if !found || !os.exists(objdump) {
		skipped_capability(t, "no llvm-objdump beside clang, so no object code is disassembled")
		return
	}
	dir := fmt.tprintf("%s/cpu", TMP)
	os.make_directory(TMP)
	os.make_directory(dir)
	levels := []string{"x86-64", "x86-64-v3"}
	listings: [2]map[string][dynamic]string
	for level, index in levels {
		obj := fmt.tprintf("%s/dispatch_kernels-%s.obj", dir, level)
		command := make([dynamic]string, context.temp_allocator)
		append(&command, compiler_path(), "tests/obj/dispatch_kernels.loke", "-build-mode=obj", fmt.tprintf("-cpu=%s", level), "-o", obj)
		append(&command, ..env_flags())
		state, _, stderr, err := exec(os.Process_Desc{command = command[:]}, context.allocator)
		if !testing.expectf(t, err == nil && state.exit_code == 0, "the object build at -cpu=%s failed:\n%s", level, string(stderr)) {
			return
		}
		dumped, stdout, dump_stderr, dump_err := exec(
			os.Process_Desc{command = []string{objdump, "-d", "--no-show-raw-insn", obj}},
			context.allocator,
		)
		if !testing.expectf(t, dump_err == nil && dumped.exit_code == 0, "llvm-objdump failed on %s:\n%s", obj, string(dump_stderr)) {
			return
		}
		listings[index] = function_mnemonics(string(stdout))
	}

	fused_copies := 0
	for name, mnemonics in listings[0] {
		copy := strings.has_suffix(name, ".v3")
		for mnemonic in mnemonics {
			if copy {
				fused_copies += int(is_fma_mnemonic(mnemonic))
			} else {
				testing.expectf(t, !beyond_baseline(mnemonic), "baseline function %s holds `%s`", name, mnemonic)
			}
		}
	}
	testing.expect(t, fused_copies > 0, "no `x86-64-v3` copy in the baseline object holds the FMA instruction")
	for listing, index in listings {
		for name in ([]string{"unfused", "loke.entry.unfused"}) {
			mnemonics, present := listing[name]
			if !testing.expectf(t, present, "-cpu=%s: no function %s in the object", levels[index], name) {
				continue
			}
			for mnemonic in mnemonics {
				testing.expectf(t, !is_fma_mnemonic(mnemonic), "-cpu=%s: %s fuses `a*b + c` into `%s`", levels[index], name, mnemonic)
			}
		}
	}
}

// Each function's instruction mnemonics in `llvm-objdump -d` output, by name.
@(private = "file")
function_mnemonics :: proc(listing: string) -> map[string][dynamic]string {
	functions := make(map[string][dynamic]string, context.temp_allocator)
	current := ""
	rest := listing
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if strings.has_suffix(trimmed, ">:") {
			open := strings.index_byte(trimmed, '<')
			current = trimmed[open + 1:len(trimmed) - 2]
			functions[current] = make([dynamic]string, context.temp_allocator)
			continue
		}
		fields := strings.fields(trimmed, context.temp_allocator)
		if current == "" || len(fields) < 2 || !strings.has_suffix(fields[0], ":") {
			continue
		}
		append(&functions[current], fields[1])
	}
	return functions
}

@(private = "file")
is_fma_mnemonic :: proc(mnemonic: string) -> bool {
	return strings.has_prefix(mnemonic, "vfmadd") || strings.has_prefix(mnemonic, "vfmsub") ||
		strings.has_prefix(mnemonic, "vfnmadd") || strings.has_prefix(mnemonic, "vfnmsub")
}

// Every VEX instruction is spelled with a leading `v`; the rest are the SSE3,
// SSSE3, SSE4, POPCNT, LZCNT, BMI, MOVBE, and CMPXCHG16B instructions LLVM
// selects when a level allows them.
@(private = "file")
beyond_baseline :: proc(mnemonic: string) -> bool {
	if strings.has_prefix(mnemonic, "v") {
		return true
	}
	switch mnemonic {
	case "popcnt", "lzcnt", "tzcnt", "andn", "bextr", "blsi", "blsr", "blsmsk", "bzhi",
	     "pdep", "pext", "rorx", "sarx", "shlx", "shrx", "mulx", "movbe", "crc32",
	     "cmpxchg16b", "haddpd", "haddps", "hsubpd", "hsubps", "addsubpd", "addsubps",
	     "movddup", "movshdup", "movsldup", "lddqu", "pshufb", "palignr", "pabsd",
	     "pmaddubsw", "phaddd", "ptest", "roundsd", "roundss", "roundpd", "roundps",
	     "blendpd", "blendps", "blendvpd", "blendvps", "pblendvb", "pblendw",
	     "insertps", "extractps", "pextrb", "pextrd", "pextrq", "pinsrb", "pinsrd",
	     "pinsrq", "pmulld", "pminsd", "pmaxsd", "pminud", "pmaxud", "pcmpeqq",
	     "pcmpgtq", "packusdw", "dppd", "dpps", "pmovzxbw", "pmovzxbd", "pmovzxwd",
	     "pmovzxdq", "pmovsxbw", "pmovsxbd", "pmovsxwd", "pmovsxdq":
		return true
	}
	return false
}
