package lokec

import "core:testing"

// Checks `source` and runs the whole program's provenance; answers how many
// provenance graphs that built.
@(private = "file")
provenance_builds :: proc(t: ^testing.T, p: ^Checked, source: string, loc := #caller_location) -> int {
	check_source(p, source)
	if !testing.expect(t, p.c.error_count == 0, "checking failed", loc = loc) {
		report(&p.c)
		return 0
	}
	k := Checker{c = &p.c}
	analyze_program_provenance(&k)
	return p.c.provenance_stats.body_builds
}

// A compiler that rechecks builds the bodies these tests count once more.
@(private = "file")
expect_builds :: proc(t: ^testing.T, builds, expected: int, loc := #caller_location) {
	when !LOKE_RECHECK_PROVENANCE {
		testing.expect_value(t, builds, expected, loc = loc)
	}
}

// A body with a summary is built for its write effects and for its summary,
// whose solve reports its diagnostics too, once. One with no summary is built
// for its effects and for its diagnostics.
@(test)
a_summary_solve_reports_the_bodys_diagnostics :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: Checked
	defer destroy_checked(&p)
	builds := provenance_builds(t, &p, `package main;
escape :: proc() -> inout int {
    local := [4]int{1, 2, 3, 4};
    return inout local[0];
}
main :: proc() {
    escape() = 1;
}
`)
	expect_builds(t, builds, 4)
	if testing.expect_value(t, len(p.c.diagnostics), 1) {
		testing.expect_value(t, p.c.diagnostics[0].code, "L0526")
	}
	testing.expect_value(t, p.c.error_count, 1)
}

// A caller that read a summary still to be made is built again for its
// diagnostics, which read the summary that is there by then; one that follows
// its callee is not.
@(test)
a_summary_read_before_it_was_made_is_not_diagnosed_from :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	CALLER :: "caller :: proc(values: []int) -> []int { return callee(values); }\n"
	CALLEE :: "callee :: proc(values: []int) -> []int { empty: []int = {}; return empty; }\n"
	CALLER_FIRST :: "package main;\n" + CALLER + CALLEE
	for source in ([2]string{CALLER_FIRST, "package main;\n" + CALLEE + CALLER}) {
		p: Checked
		builds := provenance_builds(t, &p, source)
		expect_builds(t, builds, source == CALLER_FIRST ? 5 : 4)
		testing.expect_value(t, len(p.c.diagnostics), 0)
		destroy_checked(&p)
	}
}

// A summary leaves a callback the body received to its callers, and a
// diagnosing graph does not, so such a body is built for each.
@(test)
a_body_that_receives_a_callback_is_diagnosed_apart :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: Checked
	defer destroy_checked(&p)
	builds := provenance_builds(t, &p, `package main;
apply :: proc(values: []int, pick: proc(values: []int) -> []int) -> []int { return pick(values); }
`)
	expect_builds(t, builds, 3)
	testing.expect_value(t, len(p.c.diagnostics), 0)
}
