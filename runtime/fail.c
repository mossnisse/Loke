/* Unrecoverable runtime failure: report and terminate, with no strategy and no
 * cleanup. It is the last step of every panic, and the whole of an allocator
 * `.Trap`, a panic raised while unwinding, and a fault in the runtime's own
 * records (an allocator ABI mismatch, a failed provider factory).
 *
 * Also the writer every report and `core:fmt`'s standard error go through.
 */
#include "loke_rt.h"

#include <stdio.h>
#include <stdlib.h>

__declspec(dllimport) void OutputDebugStringA(const char *text);

/* design.md "Windowed executables": a process started without a standard
 * error, as a windowed one is from Explorer, has none to write to: the C
 * library gives it descriptor -2 and drops what is written. Its text goes to an
 * attached debugger instead, a line at a time, since each `OutputDebugStringA`
 * shows as an entry of its own. Per thread, as the lines are. */
static __declspec(thread) char pending[512];
static __declspec(thread) size_t pending_used;

static int has_stderr(void) {
	return _fileno(stderr) >= 0;
}

static void send_pending(void) {
	if (pending_used == 0) {
		return;
	}
	pending[pending_used] = 0;
	OutputDebugStringA(pending);
	pending_used = 0;
}

void loke_rt_err_write(const char *bytes, size_t count) {
	if (has_stderr()) {
		fwrite(bytes, 1, count, stderr);
		return;
	}
	for (size_t at = 0; at < count; at++) {
		/* A zero byte would end the debugger's string early. */
		pending[pending_used++] = bytes[at] == 0 ? '?' : bytes[at];
		if (bytes[at] == '\n' || pending_used == sizeof pending - 1) {
			send_pending();
		}
	}
}

void loke_rt_err_puts(const char *text) {
	size_t length = 0;
	while (text[length] != 0) {
		length++;
	}
	loke_rt_err_write(text, length);
}

void loke_rt_err_flush(void) {
	if (has_stderr()) {
		fflush(stderr);
	} else {
		send_pending();
	}
}

void loke_rt_v1_abort(const char *what) {
	/* Output written before the failure is part of what a test observes, and
	 * `_Exit` deliberately does not flush. */
	fflush(stdout);
	loke_rt_err_puts("loke: ");
	loke_rt_err_puts(what == 0 ? "runtime failure" : what);
	loke_rt_err_puts("\n");
	loke_rt_err_flush();
	_Exit(3);
}
