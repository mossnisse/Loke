// An index written `a + b` or `a - b` is checked for overflow and for bounds
// behind one branch (design.md "Integer overflow", "Slices"). One generated
// program evaluates `xs[a + b]` or `xs[a - b]` for the operands its arguments
// name, and is run once per pair of boundary values, since a panic ends the
// process. What each run prints, or which panic ends it, comes from
// `index_sum_expected`, exact arithmetic written apart from the compiler.
package tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(private = "file")
INDEX_SUM_DIR :: TMP + "/index_sum"

// The elements of every container indexed, each holding its own index.
@(private = "file")
INDEX_SUM_LENGTH :: 3

@(private = "file")
Index_Sum_Type :: struct {
	name:     string,
	min, max: i128,
}

@(private = "file")
INDEX_SUM_TYPES := [?]Index_Sum_Type {
	{"i8", i128(min(i8)), i128(max(i8))},
	{"int", i128(min(i64)), i128(max(i64))},
	{"i128", min(i128), max(i128)},
	// Unsigned, so it is checked apart from the bounds.
	{"u8", 0, i128(max(u8))},
}

// The operands of a type: its ends and what lies next to them and to zero, so
// that sums overflow either way, wrap into bounds, and miss them on each side.
@(private = "file")
index_sum_values :: proc(type: Index_Sum_Type) -> [dynamic]i128 {
	values := make([dynamic]i128, context.temp_allocator)
	for value in ([]i128{type.min, type.min + 1, -2, -1, 0, 1, 2, type.max - 1, type.max}) {
		if value >= type.min && value <= type.max && !slice.contains(values[:], value) {
			append(&values, value)
		}
	}
	return values
}

@(private = "file")
INDEX_SUM_CONTAINERS := [?]string{"fixed", "view", "items"}

@(private = "file")
INDEX_SUM_OPS := [?]string{"+", "-"}

// What the run prints, or the panic that ends it.
@(private = "file")
index_sum_expected :: proc(type: Index_Sum_Type, op: string, a, b: i128) -> (stdout, panic: string) {
	// Exact: `a` and `b` are within an `i128`, so only the sum can leave it.
	exact := a
	overflowed := false
	if op == "+" {
		overflowed = (b > 0 && a > max(i128) - b) || (b < 0 && a < min(i128) - b)
		exact = a + b
	} else {
		overflowed = (b < 0 && a > max(i128) + b) || (b > 0 && a < min(i128) + b)
		exact = a - b
	}
	switch {
	case overflowed || exact < type.min || exact > type.max:
		return "", type.min < 0 ? "signed integer overflow" : "unsigned integer overflow"
	case exact < 0 || exact >= INDEX_SUM_LENGTH:
		return "", "index out of range"
	}
	return fmt.tprintf("%d", exact), ""
}

@(private = "file")
index_sum_source :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `package main;

import "core:fmt";
import "core:os";
import "core:strconv";

argument :: proc(at: int) -> int {
	switch (strconv.parse_int(os.args[at])) {
	case .ok(value): return value;
	case .err(_):    return -1;
	}
}

main :: proc() {
	fixed := [3]int{0, 1, 2};
	view := fixed[:];
	items := make([dynamic]int, 0, 3);
	foreach (element in fixed) { items.append(element); }
	which := argument(1);
	left := argument(2);
	right := argument(3);
`)
	which := 0
	for type in INDEX_SUM_TYPES {
		fmt.sbprintf(&b, "\tvalues_%s := [?]%s{{", type.name, type.name)
		for value, at in index_sum_values(type) {
			fmt.sbprintf(&b, "%s%d", at == 0 ? "" : ", ", value)
		}
		strings.write_string(&b, "};\n")
		for op in INDEX_SUM_OPS {
			for container in INDEX_SUM_CONTAINERS {
				fmt.sbprintfln(
					&b, "\tif (which == %d) {{ a := values_%s[left]; b := values_%s[right]; fmt.println(%s[a %s b]); }",
					which, type.name, type.name, container, op,
				)
				which += 1
			}
		}
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

@(test)
an_index_sum_is_checked_for_overflow_and_bounds :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	os.make_directory(INDEX_SUM_DIR)
	source := INDEX_SUM_DIR + "/sums.loke"
	if !testing.expect(t, os.write_entire_file(source, transmute([]byte)index_sum_source()) == nil, "cannot write the program") {
		return
	}

	// Unoptimized, and optimized so that LLVM has folded what it can of the check.
	levels := [?]string{"none", "speed"}
	builds: [len(levels)]Exec
	for level, at in levels {
		exe := fmt.tprintf("%s/sums-%s.exe", INDEX_SUM_DIR, level)
		builds[at].command = slice.clone([]string{compiler_path(), source, "-o", exe, fmt.tprintf("-opt=%s", level)}, context.temp_allocator)
	}
	exec_all(builds[:])
	for build, at in builds {
		if !testing.expectf(t, build.err == nil && build.state.exit_code == 0, "-opt=%s: compile failed\n%s", levels[at], string(build.stderr)) {
			return
		}
	}

	Run :: struct {
		stdout, panic: string,
	}
	jobs := make([dynamic]Exec, context.temp_allocator)
	runs := make([dynamic]Run, context.temp_allocator)
	for build in builds {
		exe := launch_path(build.command[3])
		which := 0
		for type in INDEX_SUM_TYPES {
			values := index_sum_values(type)
			for op in INDEX_SUM_OPS {
				for _ in INDEX_SUM_CONTAINERS {
					for a, left in values {
						for b, right in values {
							stdout, panic := index_sum_expected(type, op, a, b)
							append(&runs, Run{stdout, panic})
							command := slice.clone([]string{exe, fmt.tprint(which), fmt.tprint(left), fmt.tprint(right)}, context.temp_allocator)
							append(&jobs, Exec{command = command})
						}
					}
					which += 1
				}
			}
		}
	}
	exec_all(jobs[:])

	failures := 0
	for job, at in jobs {
		run := runs[at]
		stdout, stderr := normalise(string(job.stdout)), normalise(string(job.stderr))
		passed := job.err == nil && stdout == run.stdout
		if run.panic == "" {
			passed &&= job.state.exit_code == 0
		} else {
			passed &&= job.state.exit_code != 0 && strings.contains(stderr, fmt.tprintf("panic: %s\n", run.panic))
		}
		if !passed {
			failures += 1
			if failures <= 10 {
				testing.expectf(
					t, false, "%s %s %s %s: expected %q %q, got %q with exit %d and %q",
					job.command[0], job.command[1], job.command[2], job.command[3],
					run.stdout, run.panic, stdout, job.state.exit_code, stderr,
				)
			}
		}
	}
	testing.expectf(t, failures == 0, "%d of %d runs differ from the model", failures, len(jobs))
	testing.expect(t, len(jobs) > 2000, "the matrix lost its cases")
}
