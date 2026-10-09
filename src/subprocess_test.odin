package lokec

import "core:os"
import win "core:sys/windows"
import "core:testing"

import "subprocess"

foreign import kernel32_handles "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32_handles {
	GetProcessHandleCount :: proc(process: win.HANDLE, count: ^win.DWORD) -> win.BOOL ---
}

@(private = "file")
open_handle_count :: proc() -> int {
	count: win.DWORD
	GetProcessHandleCount(win.GetCurrentProcess(), &count)
	return int(count)
}

// `subprocess.run` releases the process handle it waited on, so a compiler
// that launches clang and NASM, or a harness that launches thousands of
// children, does not accumulate one per child. Odin's `core:os` still
// leaks each child's thread handle, which this allows; before the fix each
// call kept two handles.
@(test)
subprocess_run_releases_the_process_handle :: proc(t: ^testing.T) {
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
	testing.expectf(t, growth <= RUNS + RUNS / 4, "%d launches kept %d handles open", RUNS, growth)
}

// A wait that fails leaves the state zero, which reads as a clean exit, so
// `run` must report the failure rather than let a child that may have failed
// pass as one that succeeded.
@(test)
subprocess_run_reports_a_failed_wait :: proc(t: ^testing.T) {
	subprocess.wait_override = proc(process: os.Process) -> (os.Process_State, os.Error) {
		_, _ = os.process_wait(process)
		return {}, os.General_Error.Invalid_Command
	}
	defer subprocess.wait_override = nil
	child := os.Process_Desc{command = {"cmd.exe", "/c", "exit 3"}}
	_, _, _, err := subprocess.run(child, context.temp_allocator)
	testing.expectf(t, err == os.General_Error.Invalid_Command, "a failed wait was reported as %v", err)
}
