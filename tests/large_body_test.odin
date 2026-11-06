// A body's size has no limit in the language, so analyzing one must not be what stops it. These are
// generated at sizes where the solver's tables once took minutes, and then all of memory.
package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
LARGE_BODY_DIR :: TMP + "/large_body"

// Far above what these take, and far below what a row per slot per block took.
@(private = "file")
LARGE_BODY_LIMIT :: 2 * time.Minute

@(private = "file")
Large_Body :: struct {
	name:  string,
	lines: proc(b: ^strings.Builder),
}

@(test)
large_bodies_compile :: proc(t: ^testing.T) {
	bodies := []Large_Body{
		{"many_borrows", proc(b: ^strings.Builder) {
			strings.write_string(b, "run :: proc(c: bool) {\n\tv := 0;\n")
			for index in 0 ..< 3000 {
				fmt.sbprintfln(b, "\tif (c) {{ p := &mut v; p^ = %d; }}", index)
			}
			strings.write_string(b, "}\n")
		}},
		{"chain_of_reborrows", proc(b: ^strings.Builder) {
			strings.write_string(b, "keep :: proc(p: ^mut int) { p^ = 1; }\nrun :: proc() {\n\tv := 0;\n\tp0 := &mut v;\n\tkeep(p0);\n")
			for index in 1 ..= 4000 {
				fmt.sbprintfln(b, "\tp%d := p%d;\n\tkeep(p%d);", index, index - 1, index)
			}
			strings.write_string(b, "}\n")
		}},
		// Each new value of `p` ends what every copy took from the old one, which once
		// asked each slot's row about every copy again: cubic, minutes at this size.
		{"redefined_after_copies", proc(b: ^strings.Builder) {
			strings.write_string(b, "keep :: proc(p: ^mut int) { p^ = 1; }\nrun :: proc() {\n\tv := 0;\n\tp := &mut v;\n")
			for index in 0 ..< 3000 {
				fmt.sbprintfln(b, "\tq%d := p;\n\tkeep(q%d);\n\tp = &mut v;", index, index)
			}
			strings.write_string(b, "}\n")
		}},
	}
	os.make_directory(TMP)
	os.make_directory(LARGE_BODY_DIR)
	jobs := make([]Exec, len(bodies), context.temp_allocator)
	for body, index in bodies {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "package main;\n")
		body.lines(&b)
		strings.write_string(&b, "main :: proc() {}\n")
		path := fmt.tprintf("%s/%s.loke", LARGE_BODY_DIR, body.name)
		if !testing.expectf(t, os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil, "%s: cannot write", path) {
			return
		}
		jobs[index] = Exec{
			command  = []string{compiler_path(), path, "-emit-ll", "-o", fmt.tprintf("%s/%s.ll", LARGE_BODY_DIR, body.name)},
			deadline = LARGE_BODY_LIMIT,
		}
	}
	exec_all(jobs)
	for job, index in jobs {
		testing.expectf(
			t, job.err == nil && job.state.exited && job.state.exit_code == 0,
			"%s: %v, exit %d: %s", bodies[index].name, job.err, job.state.exit_code, string(job.stderr),
		)
	}
}
