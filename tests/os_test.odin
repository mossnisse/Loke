// standard-library.md "Filesystem operations": what each operation does with a
// file link, which only a machine allowed to create one can observe.
package tests

import "core:fmt"
import "core:os"
import win "core:sys/windows"
import "core:testing"

// Windows' `ERROR_PRIVILEGE_NOT_HELD`, the answer to creating a symbolic link
// without `SeCreateSymbolicLinkPrivilege` or Developer Mode.
@(private = "file")
PRIVILEGE_NOT_HELD :: 1314

// Whether this machine may create a file link, asked the way `mklink` asks.
// Only a missing privilege is a missing capability; any other failure is the
// harness's own and fails the test.
@(private = "file")
probe_file_link :: proc(t: ^testing.T) -> (allowed: bool, ok: bool) {
	target := fmt.tprintf("%s/file-link-probe.txt", TMP)
	link := fmt.tprintf("%s/file-link-probe.lnk", TMP)
	os.remove(link)
	if !testing.expectf(t, os.write_entire_file(target, []u8{}) == nil, "cannot write %s", target) {
		return false, false
	}
	defer os.remove(target)
	made := win.CreateSymbolicLinkW(
		win.utf8_to_wstring(link, context.temp_allocator),
		win.utf8_to_wstring(target, context.temp_allocator),
		win.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE,
	)
	if made {
		os.remove(link)
		return true, true
	}
	error := win.GetLastError()
	if error == PRIVILEGE_NOT_HELD {
		return false, true
	}
	testing.expectf(t, false, "creating a file link failed with Windows error %d", error)
	return false, false
}

@(test)
file_links_act_on_their_names :: proc(t: ^testing.T) {
	os.make_directory(TMP)
	allowed, ok := probe_file_link(t)
	if !ok {
		return
	}
	if !allowed {
		skipped_capability(t, "this account may not create a file link")
		return
	}

	exe := fmt.tprintf("%s/os-file-links.exe", TMP)
	state, _, stderr, err := exec(
		os.Process_Desc{command = []string{compiler_path(), "tests/os/file_links.loke", "-o", exe}},
		context.allocator,
	)
	if !testing.expectf(t, err == nil, "cannot run %s", compiler_path()) {
		return
	}
	if !testing.expectf(t, state.exit_code == 0, "compile failed:\n%s", string(stderr)) {
		return
	}
	expected, expected_err := os.read_entire_file("tests/os/file_links.expected", context.allocator)
	if !testing.expect(t, expected_err == nil, "missing tests/os/file_links.expected") {
		return
	}
	run_state, stdout, run_stderr, run_err := exec(
		os.Process_Desc{command = []string{launch_path(exe)}},
		context.allocator,
	)
	testing.expectf(t, run_err == nil, "cannot run %s", exe)
	testing.expectf(t, run_state.exit_code == 0, "exited with %d:\n%s", run_state.exit_code, string(run_stderr))
	testing.expectf(
		t,
		normalise(string(stdout)) == normalise(string(expected)),
		"expected %q, got %q",
		normalise(string(expected)),
		normalise(string(stdout)),
	)
}
