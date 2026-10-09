// Child processes for the compiler and its test harness, which both import it:
// `lokec` waits on clang and NASM, and the harness on everything it launches.
package subprocess

import "base:runtime"
import "core:os"
import "core:time"

// `os.process_exec`, but idle while the child runs. The core one polls its pipes
// in a loop with no pause, so a waiting process held a whole core, and parallel
// builds and test corpora starved the very children they were waiting for.
run :: proc(
	desc: os.Process_Desc,
	allocator: runtime.Allocator,
) -> (
	state: os.Process_State,
	stdout, stderr: []byte,
	err: os.Error,
) {
	// Each end is owned from the moment it exists, so a failure making the
	// second pipe still closes the first.
	stdout_r, stdout_w := os.pipe() or_return
	defer os.close(stdout_r)
	defer if stdout_w != nil { os.close(stdout_w) }
	stderr_r, stderr_w := os.pipe() or_return
	defer os.close(stderr_r)
	defer if stderr_w != nil { os.close(stderr_w) }
	process: os.Process
	{
		// Our copies of the write ends must close before reading, or the reads
		// never see EOF.
		defer {
			os.close(stdout_w)
			os.close(stderr_w)
			stdout_w, stderr_w = nil, nil
		}
		desc := desc
		desc.stdout, desc.stderr = stdout_w, stderr_w
		process = os.process_start(desc) or_return
	}

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
		_ = os.process_kill(process)
	}
	// `os.process_wait` releases the process handle, whether or not it succeeds.
	wait_err: os.Error
	if wait_override != nil {
		state, wait_err = wait_override(process)
	} else {
		state, wait_err = os.process_wait(process)
	}
	// A failed wait leaves `state` zero, which reads as a clean exit, so it
	// reaches the caller; a read error before it is the first cause and wins.
	if err == nil {
		err = wait_err
	}
	return
}

// Replaces `os.process_wait` for `run` on this thread, so a test can make the
// wait fail; nil means the real one.
@(thread_local)
wait_override: proc(process: os.Process) -> (os.Process_State, os.Error)

// One read from `pipe` if it holds anything; `done` once the writer is gone.
@(private = "file")
drain :: proc(pipe: ^os.File, into: ^[dynamic]byte, done: ^bool) -> (got: bool, err: os.Error) {
	if done^ {
		return false, nil
	}
	buf: [4096]byte
	n := 0
	has_data: bool
	has_data, err = os.pipe_has_data(pipe)
	if has_data {
		n, err = os.read(pipe, buf[:])
	}
	if err == .EOF || err == .Broken_Pipe {
		done^, err = true, nil
	}
	append(into, ..buf[:n])
	return n > 0, err
}
