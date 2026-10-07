package lokec

import os2 "core:os/os2"
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
// children, does not accumulate one per child. The pinned Odin `os2` still
// leaks each child's thread handle, which this allows; before the fix each
// call kept two handles.
@(test)
subprocess_run_releases_the_process_handle :: proc(t: ^testing.T) {
	RUNS :: 32
	child := os2.Process_Desc{command = {"cmd.exe", "/c", "exit 0"}}
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
