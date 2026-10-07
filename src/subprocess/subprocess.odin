// Child processes for the compiler and its test harness, which both import it:
// `lokec` waits on clang and NASM, and the harness on everything it launches.
package subprocess

import "base:runtime"
import os2 "core:os/os2"
import "core:time"

// `os2.process_exec`, but idle while the child runs. The core one polls its pipes
// in a loop with no pause, so a waiting process held a whole core, and parallel
// builds and test corpora starved the very children they were waiting for.
run :: proc(
	desc: os2.Process_Desc,
	allocator: runtime.Allocator,
) -> (
	state: os2.Process_State,
	stdout, stderr: []byte,
	err: os2.Error,
) {
	// Each end is owned from the moment it exists, so a failure making the
	// second pipe still closes the first.
	stdout_r, stdout_w := os2.pipe() or_return
	defer os2.close(stdout_r)
	defer if stdout_w != nil { os2.close(stdout_w) }
	stderr_r, stderr_w := os2.pipe() or_return
	defer os2.close(stderr_r)
	defer if stderr_w != nil { os2.close(stderr_w) }
	process: os2.Process
	{
		// Our copies of the write ends must close before reading, or the reads
		// never see EOF.
		defer {
			os2.close(stdout_w)
			os2.close(stderr_w)
			stdout_w, stderr_w = nil, nil
		}
		desc := desc
		desc.stdout, desc.stderr = stdout_w, stderr_w
		process = os2.process_start(desc) or_return
	}
	// Waiting does not release the process handle.
	defer _ = os2.process_close(process)

	out := make([dynamic]byte, allocator)
	errs := make([dynamic]byte, allocator)
	out_done, errs_done: bool
	for err == nil && !(out_done && errs_done) {
		got_out, got_errs: bool
		got_out, err = drain(stdout_r, &out, &out_done)
		if err == nil {
			got_errs, err = drain(stderr_r, &errs, &errs_done)
		}
		if !got_out && !got_errs {
			time.sleep(time.Millisecond)
		}
	}
	stdout, stderr = out[:], errs[:]
	if err != nil {
		_ = os2.process_kill(process)
	}
	state, _ = os2.process_wait(process)
	return
}

// One read from `pipe` if it holds anything; `done` once the writer is gone.
@(private = "file")
drain :: proc(pipe: ^os2.File, into: ^[dynamic]byte, done: ^bool) -> (got: bool, err: os2.Error) {
	if done^ {
		return false, nil
	}
	buf: [4096]byte
	n := 0
	has_data: bool
	has_data, err = os2.pipe_has_data(pipe)
	if has_data {
		n, err = os2.read(pipe, buf[:])
	}
	if err == .EOF || err == .Broken_Pipe {
		done^, err = true, nil
	}
	append(into, ..buf[:n])
	return n > 0, err
}
