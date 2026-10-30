// Child processes for the compiler and its test harness, which both import it:
// `lokec` waits on clang and NASM, and the harness on everything it launches.
package subprocess

import "base:runtime"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:time"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	CreateJobObjectW :: proc(attributes: ^win.SECURITY_ATTRIBUTES, name: win.LPCWSTR) -> win.HANDLE ---
	AssignProcessToJobObject :: proc(job: win.HANDLE, process: win.HANDLE) -> win.BOOL ---
	TerminateJobObject :: proc(job: win.HANDLE, exit_code: win.UINT) -> win.BOOL ---
	InitializeProcThreadAttributeList :: proc(list: rawptr, count: win.DWORD, flags: win.DWORD, size: ^win.SIZE_T) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(
		list: rawptr, flags: win.DWORD, attribute: win.DWORD_PTR, value: rawptr, size: win.SIZE_T,
		previous: rawptr, return_size: ^win.SIZE_T,
	) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(list: rawptr) ---
}

@(private = "file")
PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: win.DWORD_PTR(0x20002)

// `STARTUPINFOEXW`.
@(private = "file")
Startup_Info_Ex :: struct {
	info:       win.STARTUPINFOW,
	attributes: rawptr,
}

// `run` waits for as long as the child takes.
NO_DEADLINE :: time.Duration(0)

// `os.process_exec`, but idle while the child runs. The core one polls its pipes
// in a loop with no pause, so a waiting process held a whole core, and parallel
// builds and test corpora starved the very children they were waiting for.
//
// With a `deadline`, a child that has not closed its output and exited by then
// is ended with every process it started, and `err` is `.Timeout`; `stdout` and
// `stderr` keep what it wrote. The tree is ended, not just the child: a
// grandchild holding an inherited pipe would otherwise keep the reads from
// ever seeing EOF. Descendants still running when the child finishes in time
// are left alone, since some tools, like the MSVC linker's PDB server, are
// meant to outlive the process that started them.
run :: proc(
	desc: os.Process_Desc,
	allocator: runtime.Allocator,
	deadline := NO_DEADLINE,
) -> (
	state: os.Process_State,
	stdout, stderr: []byte,
	err: os.Error,
) {
	started := time.tick_now()
	// Each end is owned from the moment it exists, so a failure making the
	// second pipe still closes the first.
	stdout_r, stdout_w := os.pipe() or_return
	defer os.close(stdout_r)
	defer if stdout_w != nil { os.close(stdout_w) }
	stderr_r, stderr_w := os.pipe() or_return
	defer os.close(stderr_r)
	defer if stderr_w != nil { os.close(stderr_w) }
	process: os.Process
	job: win.HANDLE
	{
		// Our copies of the write ends must close before reading, or the reads
		// never see EOF.
		defer {
			os.close(stdout_w)
			os.close(stderr_w)
			stdout_w, stderr_w = nil, nil
		}
		process, job = start(desc, stdout_w, stderr_w) or_return
	}
	defer if job != nil { win.CloseHandle(job) }

	out := make([dynamic]byte, allocator)
	errs := make([dynamic]byte, allocator)
	out_done, errs_done: bool
	for err == nil && !(out_done && errs_done) {
		got_out, got_errs: bool
		got_out, err = drain(stdout_r, &out, &out_done)
		if err == nil {
			got_errs, err = drain(stderr_r, &errs, &errs_done)
		}
		if err == nil && !got_out && !got_errs {
			if remaining(started, deadline) == 0 {
				err = os.General_Error.Timeout
			} else {
				time.sleep(time.Millisecond)
			}
		}
	}
	stdout, stderr = out[:], errs[:]
	if err != nil {
		end(process, job)
	}
	// `os.process_wait` releases the process handle, whether or not it succeeds,
	// except when it times out.
	wait_err: os.Error
	if wait_override != nil {
		state, wait_err = wait_override(process)
	} else {
		limit := os.TIMEOUT_INFINITE
		if err == nil && deadline > 0 {
			limit = remaining(started, deadline)
		}
		state, wait_err = os.process_wait(process, limit)
		if wait_err == os.General_Error.Timeout {
			end(process, job)
			state, _ = os.process_wait(process)
		}
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

// What is left of `deadline` since `started`: 0 once it has passed, and
// `os.TIMEOUT_INFINITE` when there is none.
@(private = "file")
remaining :: proc(started: time.Tick, deadline: time.Duration) -> time.Duration {
	if deadline <= 0 {
		return os.TIMEOUT_INFINITE
	}
	return max(deadline - time.tick_since(started), 0)
}

// Ends the child and, when it runs in `job`, everything it started.
@(private = "file")
end :: proc(process: os.Process, job: win.HANDLE) {
	if job == nil || !TerminateJobObject(job, 9) {
		_ = os.process_kill(process)
	}
}

// `os.process_start`, but the child starts in a job of its own, so `end` can
// reach every process it starts. It is created suspended and joins the job
// before it runs, or a grandchild started at once could escape. A job that
// cannot be made or joined, as where a parent job forbids it, leaves `job` nil
// and the child alone to end. Only the stdio of `desc` that `run` uses is
// read, its `stdin` and the `stdout` and `stderr` it passes, and those three
// are all the child inherits.
@(private = "file")
start :: proc(
	desc: os.Process_Desc,
	stdout, stderr: ^os.File,
) -> (
	process: os.Process,
	job: win.HANDLE,
	err: os.Error,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	command_line := win.utf8_to_wstring(command_line_of(desc.command), context.temp_allocator)
	environment: rawptr
	if desc.env != nil {
		environment = raw_data(win.utf8_to_utf16(environment_block_of(desc.env), context.temp_allocator))
	}
	working_dir: win.wstring
	if desc.working_dir != "" {
		working_dir = win.utf8_to_wstring(desc.working_dir, context.temp_allocator)
	}
	// An inheritable handle of our own, closed once the child has its copy.
	stdin_handle: win.HANDLE
	if desc.stdin != nil {
		this := win.GetCurrentProcess()
		if !win.DuplicateHandle(this, win.HANDLE(os.fd(desc.stdin)), this, &stdin_handle, 0, true, win.DUPLICATE_SAME_ACCESS) {
			return {}, nil, os.Platform_Error(win.GetLastError())
		}
	} else {
		stdin_handle = win.CreateFileW(
			win.L("NUL"),
			win.GENERIC_READ,
			win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
			&win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true},
			win.OPEN_EXISTING,
			win.FILE_ATTRIBUTE_NORMAL,
			nil,
		)
		if stdin_handle == win.INVALID_HANDLE_VALUE {
			return {}, nil, os.Platform_Error(win.GetLastError())
		}
	}
	defer win.CloseHandle(stdin_handle)

	// The child inherits its stdio and nothing else. Every inheritable handle
	// would otherwise go to it, among them the pipes of children other threads
	// are starting, and a child holding another's pipe keeps that one's reads
	// from their end for as long as it lives, past that one's deadline.
	inherited := [3]win.HANDLE{stdin_handle, win.HANDLE(os.fd(stdout)), win.HANDLE(os.fd(stderr))}
	list_size: win.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &list_size)
	list := make([]byte, list_size, context.temp_allocator)
	if !InitializeProcThreadAttributeList(raw_data(list), 1, 0, &list_size) {
		return {}, nil, os.Platform_Error(win.GetLastError())
	}
	defer DeleteProcThreadAttributeList(raw_data(list))
	if !UpdateProcThreadAttribute(
		raw_data(list), 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherited, size_of(inherited), nil, nil,
	) {
		return {}, nil, os.Platform_Error(win.GetLastError())
	}
	startup := Startup_Info_Ex {
		info = {
			cb = size_of(Startup_Info_Ex),
			hStdInput = stdin_handle,
			hStdOutput = inherited[1],
			hStdError = inherited[2],
			dwFlags = win.STARTF_USESTDHANDLES,
		},
		attributes = raw_data(list),
	}

	info: win.PROCESS_INFORMATION
	if !win.CreateProcessW(
		nil,
		command_line,
		nil,
		nil,
		true,
		win.CREATE_UNICODE_ENVIRONMENT | win.NORMAL_PRIORITY_CLASS | win.CREATE_SUSPENDED | win.EXTENDED_STARTUPINFO_PRESENT,
		environment,
		working_dir,
		&startup.info,
		&info,
	) {
		return {}, nil, os.Platform_Error(win.GetLastError())
	}
	// Closed here, which `os.process_start` never does: a launch keeps no
	// handle but the process's.
	defer win.CloseHandle(info.hThread)
	process = {pid = int(info.dwProcessId), handle = uintptr(info.hProcess)}
	job = CreateJobObjectW(nil, nil)
	if job != nil && !AssignProcessToJobObject(job, info.hProcess) {
		win.CloseHandle(job)
		job = nil
	}
	if win.ResumeThread(info.hThread) == max(win.DWORD) {
		err = os.Platform_Error(win.GetLastError())
		end(process, job)
		_, _ = os.process_wait(process)
		if job != nil {
			win.CloseHandle(job)
		}
		return {}, nil, err
	}
	return
}

// The command line `CommandLineToArgvW` and the C runtime split back into
// `command`, in the temporary allocator. An argument is quoted, as
// `os.process_start` quotes it, when it holds a character the C runtime or
// cmd.exe would read apart, and also when it is empty, which it drops.
@(private = "file")
command_line_of :: proc(command: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for arg, index in command {
		if index != 0 {
			strings.write_byte(&b, ' ')
		}
		if arg != "" && !strings.contains_any(arg, "()[]{}^=;!'+,`~\" \t") {
			strings.write_string(&b, arg)
			continue
		}
		// Backslashes are literal except before a quote, so a run of them before
		// one, or before the closing quote, is doubled.
		strings.write_byte(&b, '"')
		backslashes := 0
		for c in transmute([]byte)arg {
			switch c {
			case '\\':
				backslashes += 1
				continue
			case '"':
				backslashes = backslashes * 2 + 1
			}
			for _ in 0 ..< backslashes {
				strings.write_byte(&b, '\\')
			}
			backslashes = 0
			strings.write_byte(&b, c)
		}
		for _ in 0 ..< backslashes * 2 {
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, '"')
	}
	return strings.to_string(b)
}

// `KEY=VALUE` entries as an environment block, each ended by a NUL and the
// whole by another, in the temporary allocator. A later entry for a key
// replaces an earlier one, as `os.process_start` treats them. A key may begin
// with `=`, as the per-drive directories Windows keeps do.
@(private = "file")
environment_block_of :: proc(environment: []string) -> string {
	key_of :: proc(entry: string) -> string {
		if len(entry) == 0 {
			return entry
		}
		equals := strings.index_byte(entry[1:], '=')
		return entry if equals < 0 else entry[:equals + 1]
	}
	b := strings.builder_make(context.temp_allocator)
	entries: for entry, index in environment {
		key := key_of(entry)
		for later in environment[index + 1:] {
			if key_of(later) == key {
				continue entries
			}
		}
		strings.write_string(&b, entry)
		strings.write_byte(&b, 0)
	}
	strings.write_byte(&b, 0)
	return strings.to_string(b)
}

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
