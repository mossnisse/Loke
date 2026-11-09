// compiler-guide.md "Windowed programs": what `@(subsystem="windows")` links, and
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
	state, _, stderr, err := exec(os.Process_Desc{command = command[:]}, context.temp_allocator)
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

	state, stdout, stderr, err := exec(os.Process_Desc{command = []string{launch_path(windowed)}}, context.temp_allocator)
	if !testing.expectf(t, err == nil, "cannot run %s", windowed) {
		return
	}
	testing.expectf(t, state.exit_code == 5, "%s exited %d, not 5", windowed, state.exit_code)
	testing.expectf(t, normalise(string(stdout)) == "out 1", "%s printed %q", windowed, string(stdout))
	testing.expectf(t, normalise(string(stderr)) == "err line ö", "%s wrote %q to standard error", windowed, string(stderr))
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
	// The `Ex` form receives `OutputDebugStringW`'s text as it was written.
	WaitForDebugEventEx :: proc(event: ^DEBUG_EVENT, milliseconds: u32) -> win.BOOL ---
	ContinueDebugEvent :: proc(process_id, thread_id: u32, status: u32) -> win.BOOL ---
}

// Runs `path` with `argument` as a debuggee, as Explorer would start it: no
// inherited handles, and null standard ones. Each string it sends the debugger,
// followed by `|`.
@(private = "file")
run_debugged :: proc(t: ^testing.T, path, argument: string) -> (exit_code: u32, received: string, ok: bool) {
	command_line := win.utf8_to_wstring(fmt.tprintf(`"%s" %s`, path, argument), context.temp_allocator)
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

	sent := strings.builder_make(context.temp_allocator)
	exited, started := false, false
	for !exited {
		event: DEBUG_EVENT
		if !testing.expectf(t, bool(WaitForDebugEventEx(&event, 60_000)), "%s %s sent no debug event in a minute", path, argument) {
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
			// The length counts the terminating zero; read as many UTF-16 units,
			// which is enough whether it counts units or bytes.
			units := make([]u16, int(event.info.debug_string.length), context.temp_allocator)
			read: win.SIZE_T
			if win.ReadProcessMemory(process.hProcess, event.info.debug_string.data, raw_data(units), len(units) * size_of(u16), &read) {
				if event.info.debug_string.unicode != 0 {
					wide := units[:int(read) / size_of(u16)]
					for unit, index in wide {
						if unit == 0 {
							wide = wide[:index]
							break
						}
					}
					text, _ := win.utf16_to_utf8(wide, context.temp_allocator)
					strings.write_string(&sent, text)
				} else {
					// As a debugger shows it: in the ANSI code page, not as UTF-8.
					bytes := ([^]u8)(raw_data(units))[:min(int(read), int(event.info.debug_string.length))]
					ansi := strings.trim_right_null(string(bytes))
					wide := make([]u16, len(ansi), context.temp_allocator)
					count := win.MultiByteToWideChar(win.CP_ACP, 0, raw_data(ansi), i32(len(ansi)), raw_data(wide), i32(len(wide)))
					text, _ := win.utf16_to_utf8(wide[:max(count, 0)], context.temp_allocator)
					strings.write_string(&sent, text)
				}
				strings.write_byte(&sent, '|')
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
	return exit_code, strings.to_string(sent), true
}

// Started outside a terminal, a windowed process has no standard handles. What
// it writes to standard error reaches a debugger a line at a time, as UTF-16 so
// that any text shows as written; standard output is dropped. A partial line is
// still sent when the thread detaches, after its thread-local drops, and when
// `os.exit` ends the process. A line too long for one entry is cut between
// characters.
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
	long_start := strings.concatenate({"x", strings.repeat("ö", 255, context.temp_allocator)}, context.temp_allocator)
	long_end := strings.repeat("ö", 45, context.temp_allocator)
	cases := []struct{argument: string, exit_code: u32, sent: string} {
		{"panic", 3, "err line ö\n|loke: panic: asked to panic\n|loke: panicked\n|"},
		{"exit", 4, "err line ö\n|exiting|"},
		{"drop", 5, "err line ö\n|dropped|"},
		{"long", 5, fmt.tprintf("err line ö\n|%s|%s\n|", long_start, long_end)},
	}
	for c in cases {
		exit_code, sent, ran := run_debugged(t, path, c.argument)
		if !ran {
			continue
		}
		testing.expectf(t, exit_code == c.exit_code, "%s %s exited %d, not %d", path, c.argument, exit_code, c.exit_code)
		testing.expectf(t, sent == c.sent, "%s %s sent the debugger %q, not %q", path, c.argument, sent, c.sent)
	}
}

// A `-g` build's panic report names its frames, through the same writer, so
// each frame reaches the debugger as a line of its own.
@(test)
a_windowed_panic_trace_reaches_the_debugger :: proc(t: ^testing.T) {
	if _, _, has_clang := host_toolchain(); !has_clang {
		skipped_capability(t, "no usable clang, so nothing is linked")
		return
	}
	os.make_directory(TMP)
	windowed := fmt.tprintf("%s/windowed-traced.exe", TMP)
	if !build_windowed(t, "tests/windowed/windowed.loke", windowed, "-g") {
		return
	}
	path, _ := filepath.abs(windowed, context.temp_allocator)
	exit_code, sent, ran := run_debugged(t, path, "panic")
	if !ran {
		return
	}
	expected := "err line ö\n|loke: panic: asked to panic\n|loke: stack trace, newest call first:\n|    main at windowed.loke:24\n|loke: panicked\n|"
	testing.expectf(t, exit_code == 3, "%s panic exited %d, not 3", path, exit_code)
	testing.expectf(t, sent == expected, "%s panic sent the debugger %q, not %q", path, sent, expected)
}
