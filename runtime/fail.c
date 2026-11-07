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
#include <string.h>

__declspec(dllimport) void OutputDebugStringW(const wchar_t *text);
__declspec(dllimport) int MultiByteToWideChar(
	unsigned code_page, unsigned long flags, const char *bytes, int count, wchar_t *wide, int capacity);

#define CP_UTF8 65001u

/* design.md "Windowed executables": a process started without a standard
 * error, as a windowed one is from Explorer, has none to write to: the C
 * library gives it descriptor -2 and drops what is written. Its text goes to an
 * attached debugger instead, a line at a time, since each `OutputDebugStringW`
 * shows as an entry of its own. Per thread, as the lines are. The text is
 * UTF-8, which the `A` form would read in the ANSI code page. */
static __declspec(thread) char pending[512];
static __declspec(thread) size_t pending_used;
static int exit_flush_registered;

static int has_stderr(void) {
	return _fileno(stderr) >= 0;
}

/* Sends the first `count` pending bytes and keeps the rest. */
static void send_pending_prefix(size_t count) {
	if (count == 0) {
		return;
	}
	/* A UTF-8 byte never makes more than one UTF-16 unit. Ill-formed bytes
	 * become U+FFFD. */
	wchar_t wide[sizeof pending + 1];
	int length = MultiByteToWideChar(CP_UTF8, 0, pending, (int)count, wide, (int)sizeof pending);
	wide[length > 0 ? length : 0] = 0;
	OutputDebugStringW(wide);
	pending_used -= count;
	memmove(pending, pending + count, pending_used);
}

static void send_pending(void) {
	send_pending_prefix(pending_used);
}

/* Where a full buffer is cut: before a character it holds only the start of,
 * which then begins the next entry. */
static size_t character_boundary(void) {
	size_t lead = pending_used;
	while (lead > 0 && pending_used - lead < 3 && (pending[lead - 1] & 0xC0) == 0x80) {
		lead--;
	}
	if (lead == 0) {
		return pending_used;
	}
	lead--;
	unsigned char byte = (unsigned char)pending[lead];
	size_t needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1;
	return pending_used - lead < needed ? lead : pending_used;
}

/* `exit`, which `os.exit` calls, runs no thread detach: the exiting thread's
 * partial line is sent from here. */
static void flush_at_exit(void) {
	send_pending();
}

void loke_rt_err_write(const char *bytes, size_t count) {
	if (has_stderr()) {
		fwrite(bytes, 1, count, stderr);
		return;
	}
	if (!__atomic_load_n(&exit_flush_registered, __ATOMIC_RELAXED) &&
	    !__atomic_exchange_n(&exit_flush_registered, 1, __ATOMIC_RELAXED)) {
		atexit(flush_at_exit);
	}
	for (size_t at = 0; at < count; at++) {
		/* A zero byte would end the debugger's string early. */
		pending[pending_used++] = bytes[at] == 0 ? '?' : bytes[at];
		if (bytes[at] == '\n') {
			send_pending();
		} else if (pending_used == sizeof pending) {
			send_pending_prefix(character_boundary());
		}
	}
}

void loke_rt_err_puts(const char *text) {
	loke_rt_err_write(text, strlen(text));
}

void loke_rt_err_flush(void) {
	if (has_stderr()) {
		fflush(stderr);
	} else {
		send_pending();
	}
}

/* With a standard error nothing is held, so there is nothing to flush. */
void loke_rt_err_end_thread(void) {
	send_pending();
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
