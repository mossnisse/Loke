// design.md "Windowed executables": what `@(subsystem="windows")` links, and
// where a windowed process's standard error goes when it has none.
package tests

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"
import "core:testing"

// The PE optional header's `Subsystem`: 2 is a windowed program, 3 a console one.
@(private = "file")
pe_subsystem :: proc(path: string) -> (subsystem: u16, ok: bool) {
	image, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(image) < 0x40 {
		return 0, false
	}
	header := int(endian.get_u32(image[0x3C:], .Little) or_return)
	// Four signature bytes, the 20-byte file header, then 68 bytes in.
	at := header + 4 + 20 + 68
	if at + 2 > len(image) {
		return 0, false
	}
	return endian.get_u16(image[at:], .Little)
}

@(private = "file")
build_windowed :: proc(t: ^testing.T, source, out: string, flags: ..string) -> bool {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, compiler_path(), source, "-o", out)
	append(&command, ..flags)
	state, _, stderr, err := exec(os.Process_Desc{command = command[:]}, context.allocator)
	return testing.expectf(t, err == nil && state.exit_code == 0, "building %s failed:\n%s", out, string(stderr))
}

// The attribute links for the GUI subsystem, and only an executable: a test
// build of the same package, and a program without it, stay console programs.
// A windowed process given handles uses them as any other does.
@(test)
a_windowed_executable_links_for_the_gui_subsystem :: proc(t: ^testing.T) {
	if _, _, has_clang := host_toolchain(); !has_clang {
		skipped_capability(t, "no usable clang, so nothing is linked")
		return
	}
	os.make_directory(TMP)
	windowed := fmt.tprintf("%s/windowed.exe", TMP)
	console := fmt.tprintf("%s/windowed-console.exe", TMP)
	tested := fmt.tprintf("%s/windowed.test.exe", TMP)
	if !build_windowed(t, "tests/windowed/windowed.loke", windowed) ||
	   !build_windowed(t, "examples/hello.loke", console) ||
	   !build_windowed(t, "tests/windowed/windowed.loke", tested, "-test") {
		return
	}
	for expected in ([]struct{path: string, subsystem: u16}{{windowed, 2}, {console, 3}, {tested, 3}}) {
		subsystem, read := pe_subsystem(expected.path)
		testing.expectf(t, read && subsystem == expected.subsystem, "%s has subsystem %d, not %d", expected.path, subsystem, expected.subsystem)
	}

	state, stdout, stderr, err := exec(os.Process_Desc{command = []string{launch_path(windowed)}}, context.allocator)
	if !testing.expectf(t, err == nil, "cannot run %s", windowed) {
		return
	}
	testing.expectf(t, state.exit_code == 5, "%s exited %d, not 5", windowed, state.exit_code)
	testing.expectf(t, normalise(string(stdout)) == "out 1", "%s printed %q", windowed, string(stdout))
	testing.expectf(t, normalise(string(stderr)) == "err line", "%s wrote %q to standard error", windowed, string(stderr))
}

// kernel32's debugging interface, which `core:sys/windows` does not bind.
@(private = "file")
DEBUG_EVENT :: struct {
	code:       u32,
	process_id: u32,
	thread_id:  u32,
	info:       struct #raw_union {
		// OUTPUT_DEBUG_STRING_INFO
		debug_string:   struct {
			data:    rawptr,
			unicode: u16,
			length:  u16,
		},
		// EXIT_PROCESS_DEBUG_INFO
		exit_code:      u32,
		// EXCEPTION_DEBUG_INFO's record starts with the code.
		exception_code: u32,
		// CREATE_PROCESS_DEBUG_INFO and LOAD_DLL_DEBUG_INFO start with a file
		// handle the debugger closes.
		file:           win.HANDLE,
		// The largest member, EXCEPTION_DEBUG_INFO.
		_:              [160]u8,
	},
}

#assert(size_of(DEBUG_EVENT) == 176)

@(private = "file")
EXCEPTION_DEBUG_EVENT :: 1
@(private = "file")
CREATE_PROCESS_DEBUG_EVENT :: 3
@(private = "file")
EXIT_PROCESS_DEBUG_EVENT :: 5
@(private = "file")
LOAD_DLL_DEBUG_EVENT :: 6
@(private = "file")
OUTPUT_DEBUG_STRING_EVENT :: 8
@(private = "file")
EXCEPTION_BREAKPOINT :: 0x80000003
@(private = "file")
DBG_CONTINUE :: 0x00010002
@(private = "file")
DBG_EXCEPTION_NOT_HANDLED :: 0x80010001

foreign import kernel32_debug "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_debug {
	WaitForDebugEvent :: proc(event: ^DEBUG_EVENT, milliseconds: u32) -> win.BOOL ---
	ContinueDebugEvent :: proc(process_id, thread_id: u32, status: u32) -> win.BOOL ---
}

// Started outside a terminal, a windowed process has no standard handles. The
// panic's report, and what the program wrote to standard error first, reach a
// debugger a line at a time; standard output is dropped. The exit status is the
// panic's.
@(test)
a_windowed_process_without_standard_error_reports_to_the_debugger :: proc(t: ^testing.T) {
	if _, _, has_clang := host_toolchain(); !has_clang {
		skipped_capability(t, "no usable clang, so nothing is linked")
		return
	}
	os.make_directory(TMP)
	windowed := fmt.tprintf("%s/windowed-debugged.exe", TMP)
	if !build_windowed(t, "tests/windowed/windowed.loke", windowed) {
		return
	}
	path, _ := filepath.abs(windowed, context.temp_allocator)
	command_line := win.utf8_to_wstring(fmt.tprintf(`"%s" panic`, path), context.temp_allocator)
	// No inherited handles, and null standard ones: what Explorer gives it.
	startup := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW), dwFlags = win.STARTF_USESTDHANDLES}
	process: win.PROCESS_INFORMATION
	if !testing.expectf(
		t,
		bool(win.CreateProcessW(nil, command_line, nil, nil, false, win.DEBUG_ONLY_THIS_PROCESS, nil, nil, &startup, &process)),
		"cannot start %s under the debugger: Windows error %d", path, win.GetLastError(),
	) {
		return
	}
	defer win.CloseHandle(process.hProcess)
	defer win.CloseHandle(process.hThread)

	received := strings.builder_make(context.temp_allocator)
	exit_code: u32
	exited, started := false, false
	for !exited {
		event: DEBUG_EVENT
		if !testing.expectf(t, bool(WaitForDebugEvent(&event, 60_000)), "%s sent no debug event in a minute", path) {
			win.TerminateProcess(process.hProcess, 1)
			return
		}
		status: u32 = DBG_CONTINUE
		switch event.code {
		case CREATE_PROCESS_DEBUG_EVENT, LOAD_DLL_DEBUG_EVENT:
			if event.info.file != nil {
				win.CloseHandle(event.info.file)
			}
		case OUTPUT_DEBUG_STRING_EVENT:
			text := make([]u8, int(event.info.debug_string.length), context.temp_allocator)
			read: win.SIZE_T
			if event.info.debug_string.unicode == 0 &&
			   win.ReadProcessMemory(process.hProcess, event.info.debug_string.data, raw_data(text), len(text), &read) {
				// The length counts the terminating zero.
				strings.write_string(&received, strings.trim_right_null(string(text[:read])))
				strings.write_byte(&received, '|')
			}
		case EXCEPTION_DEBUG_EVENT:
			// The loader's initial breakpoint is the debugger's; anything else
			// is the program's own.
			if started || event.info.exception_code != EXCEPTION_BREAKPOINT {
				status = DBG_EXCEPTION_NOT_HANDLED
			}
			started = true
		case EXIT_PROCESS_DEBUG_EVENT:
			exit_code = event.info.exit_code
			exited = true
		}
		ContinueDebugEvent(event.process_id, event.thread_id, status)
	}
	testing.expectf(t, exit_code == 3, "%s exited %d, not 3", path, exit_code)
	testing.expectf(
		t,
		strings.to_string(received) == "err line\n|loke: panic: asked to panic\n|loke: panicked\n|",
		"%s sent the debugger %q", path, strings.to_string(received),
	)
}
