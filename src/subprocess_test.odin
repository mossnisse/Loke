package lokec

import "core:os"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:testing"
import "core:thread"
import "core:time"

import "subprocess"

foreign import kernel32_handles "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32_handles {
	GetProcessHandleCount :: proc(process: win.HANDLE, count: ^win.DWORD) -> win.BOOL ---
}

// Held by each test here for its whole run: one counts the process's handles,
// and another's pipe must reach only the children it starts itself.
@(private = "file")
launching: sync.Mutex

@(private = "file")
open_handle_count :: proc() -> int {
	count: win.DWORD
	GetProcessHandleCount(win.GetCurrentProcess(), &count)
	return int(count)
}

// `subprocess.run` releases the process handle it waited on, and the thread
// and job handles it opened, so a compiler that launches clang and NASM, or a
// harness that launches thousands of children, does not accumulate them per
// child. Once each call kept two, and then one, the thread handle Odin's
// `core:os` start leaks.
@(test)
subprocess_run_releases_the_process_handle :: proc(t: ^testing.T) {
	sync.mutex_guard(&launching)
	RUNS :: 32
	child := os.Process_Desc{command = {"cmd.exe", "/c", "exit 0"}}
	// The first launch may open handles that stay for the process's life.
	_, _, _, warm_err := subprocess.run(child, context.temp_allocator)
	if !testing.expectf(t, warm_err == nil, "cannot launch cmd.exe: %v", warm_err) {
		return
	}
	before := open_handle_count()
	for _ in 0 ..< RUNS {
		_, _, _, _ = subprocess.run(child, context.temp_allocator)
	}
	growth := open_handle_count() - before
	testing.expectf(t, growth <= RUNS / 4, "%d launches kept %d handles open", RUNS, growth)
}

// A child still running at its deadline is ended with every process it
// started, so a stalled test fails promptly instead of hanging its harness, and
// what it wrote before then is kept. Here the child waits on a grandchild,
// `ping`, and both hold, as their stdin, the writing end of a pipe of the
// test's own: only when the grandchild is gone too does its reader see an end.
@(test)
subprocess_run_ends_the_tree_at_its_deadline :: proc(t: ^testing.T) {
	sync.mutex_guard(&launching)
	witness_r, witness_w, pipe_err := os.pipe()
	if !testing.expectf(t, pipe_err == nil, "cannot make a pipe: %v", pipe_err) {
		return
	}
	defer os.close(witness_r)
	child := os.Process_Desc {
		command = {"cmd.exe", "/c", "echo begun& ping -n 60 127.0.0.1 >nul"},
		stdin   = witness_w,
	}
	started := time.tick_now()
	state, stdout, _, err := subprocess.run(child, context.temp_allocator, 500 * time.Millisecond)
	os.close(witness_w)
	testing.expectf(t, err == os.General_Error.Timeout, "a stalled child was reported as %v (exit %d)", err, state.exit_code)
	testing.expectf(t, strings.has_prefix(string(stdout), "begun"), "the output before the deadline was %q", string(stdout))
	testing.expect(t, sees_its_end(witness_r, 10 * time.Second), "the grandchild outlived the deadline")
	testing.expectf(t, time.tick_since(started) < 30 * time.Second, "the deadline was enforced only after %v", time.tick_since(started))
}

// A child inherits its stdio and no other handle, so one started while another
// thread's child has its pipes open cannot keep that child's reads waiting.
// Here the child lives for two seconds, and a pipe of the test's, which it
// was not given, reaches its end while the child runs.
@(test)
subprocess_run_passes_a_child_only_its_stdio :: proc(t: ^testing.T) {
	sync.mutex_guard(&launching)
	witness_r, witness_w, pipe_err := os.pipe()
	if !testing.expectf(t, pipe_err == nil, "cannot make a pipe: %v", pipe_err) {
		return
	}
	defer os.close(witness_r)
	Check :: struct {
		witness_r, witness_w: ^os.File,
		ended:                bool,
	}
	check := Check{witness_r, witness_w, false}
	checker := thread.create_and_start_with_poly_data(&check, proc(check: ^Check) {
		time.sleep(500 * time.Millisecond)
		os.close(check.witness_w)
		check.ended = sees_its_end(check.witness_r, time.Second)
	})
	_, _, _, err := subprocess.run(os.Process_Desc{command = {"cmd.exe", "/c", "ping -n 3 127.0.0.1 >nul"}}, context.temp_allocator)
	thread.join(checker)
	thread.destroy(checker)
	testing.expectf(t, err == nil, "cannot run the child: %v", err)
	testing.expect(t, check.ended, "the child inherited a handle it was not given")
}

// Whether `pipe`'s writers are all gone within `limit`: ending a process
// closes its handles soon after, not at once.
@(private = "file")
sees_its_end :: proc(pipe: ^os.File, limit: time.Duration) -> bool {
	started := time.tick_now()
	for {
		if _, err := os.pipe_has_data(pipe); err != nil {
			return true
		}
		if time.tick_since(started) > limit {
			return false
		}
		time.sleep(50 * time.Millisecond)
	}
}

// A wait that fails leaves the state zero, which reads as a clean exit, so
// `run` must report the failure rather than let a child that may have failed
// pass as one that succeeded.
@(test)
subprocess_run_reports_a_failed_wait :: proc(t: ^testing.T) {
	sync.mutex_guard(&launching)
	subprocess.wait_override = proc(process: os.Process) -> (os.Process_State, os.Error) {
		_, _ = os.process_wait(process)
		return {}, os.General_Error.Invalid_Command
	}
	defer subprocess.wait_override = nil
	child := os.Process_Desc{command = {"cmd.exe", "/c", "exit 3"}}
	_, _, _, err := subprocess.run(child, context.temp_allocator)
	testing.expectf(t, err == os.General_Error.Invalid_Command, "a failed wait was reported as %v", err)
}
