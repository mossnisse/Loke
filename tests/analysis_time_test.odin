// Small programs whose analysis once took minutes, compiled under a deadline far above what
// they take now and far below what they took then.
package tests

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

@(private = "file")
ANALYSIS_TIME_DIR :: TMP + "/analysis_time"

@(private = "file")
ANALYSIS_TIME_LIMIT :: 30 * time.Second

@(private = "file")
Analysis_Case :: struct {
	name:   string,
	source: string,
}

@(test)
analysis_finishes_promptly :: proc(t: ^testing.T) {
	cases := []Analysis_Case{
		// `make_contiguous` reverses slices it took from `self.slots_mut()`, known only
		// to point somewhere into the deque. The alias walk for what `slice.reverse`
		// leaves applied its element step to the whole deque record, whose type then
		// never narrowed, and walked the deque back into itself at every path up to
		// WRITTEN_ALIAS_DEPTH: about 40 s for each of the body's three walks.
		{"deque_of_views", `package main;

import "core:container";
import "core:fmt";

main :: proc() {
	xs := []int{1, 2};
	d := container.Deque([]int).init(4);
	d.append(xs[:]);
	s := d.make_contiguous();
	fmt.println(s.len());
}
`},
	}
	os.make_directory(TMP)
	os.make_directory(ANALYSIS_TIME_DIR)
	jobs := make([]Exec, len(cases), context.temp_allocator)
	for c, index in cases {
		path := fmt.tprintf("%s/%s.loke", ANALYSIS_TIME_DIR, c.name)
		if !testing.expectf(t, os.write_entire_file(path, transmute([]byte)c.source) == nil, "%s: cannot write", path) {
			return
		}
		jobs[index] = Exec{
			command  = []string{compiler_path(), path, "-emit-ll", "-o", fmt.tprintf("%s/%s.ll", ANALYSIS_TIME_DIR, c.name)},
			deadline = ANALYSIS_TIME_LIMIT,
		}
	}
	exec_all(jobs)
	for job, index in jobs {
		testing.expectf(
			t, job.err == nil && job.state.exited && job.state.exit_code == 0,
			"%s: %v, exit %d: %s", cases[index].name, job.err, job.state.exit_code, string(job.stderr),
		)
	}
}
