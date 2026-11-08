// A small program whose analysis once took minutes, compiled under a deadline far above
// what it takes now and far below what it took then.
package tests

import "core:os"
import "core:testing"
import "core:time"

@(private = "file")
ANALYSIS_TIME_DIR :: TMP + "/analysis_time"

@(private = "file")
ANALYSIS_TIME_LIMIT :: 30 * time.Second

// `make_contiguous` reverses slices it took from `self.slots_mut()`, known only to point
// somewhere into the deque. The alias walk for what `slice.reverse` leaves applied its
// element step to the whole deque record, whose type then never narrowed, and walked the
// deque back into itself at every path up to WRITTEN_ALIAS_DEPTH: about 40 s for each of
// the body's three walks.
@(test)
analysis_finishes_promptly :: proc(t: ^testing.T) {
	source := `package main;

import "core:container";
import "core:fmt";

main :: proc() {
	xs := []int{1, 2};
	d := container.Deque([]int).init(4);
	d.append(xs[:]);
	s := d.make_contiguous();
	fmt.println(s.len());
}
`
	os.make_directory(TMP)
	os.make_directory(ANALYSIS_TIME_DIR)
	path := ANALYSIS_TIME_DIR + "/deque_of_views.loke"
	if !testing.expectf(t, os.write_entire_file(path, transmute([]byte)source) == nil, "%s: cannot write", path) {
		return
	}
	command := []string{compiler_path(), path, "-emit-ll", "-o", ANALYSIS_TIME_DIR + "/deque_of_views.ll"}
	state, _, stderr, err := exec({command = command}, context.temp_allocator, ANALYSIS_TIME_LIMIT)
	testing.expectf(t, err == nil && state.exited && state.exit_code == 0, "%v, exit %d: %s", err, state.exit_code, string(stderr))
}
