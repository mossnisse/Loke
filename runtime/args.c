/* Process arguments (design.md "Program entry and exit").
 *
 * Windows hands `wmain` a UTF-16 argument vector, and Loke text is UTF-8 by
 * invariant. The conversion happens once, here, before the initial thread
 * attaches — so `os.args` is a read of cached, already-valid UTF-8 rather than a
 * conversion at every use, and no Loke package needs an initializer to run.
 *
 * The two getters are deliberately foreign-ABI-safe: `core:os` is
 * ordinary Loke source over a foreign block, with no compiler knowledge.
 */
#include "loke_rt.h"

#include <fcntl.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

__declspec(dllimport) int WideCharToMultiByte(
	unsigned code_page, unsigned long flags, const wchar_t *wide, int count,
	char *bytes, int capacity, const char *default_char, int *used_default);

#define CP_UTF8 65001u

/* One converted argument: zero-terminated, with its byte length cached so a
 * lookup never scans. */
typedef struct {
	char *bytes;
	int64_t len;
} arg_entry;

static int32_t arg_count;
static arg_entry *arg_values;

/* One zero-terminated UTF-16 argument to UTF-8. Without `WC_ERR_INVALID_CHARS`
 * an unpaired surrogate becomes U+FFFD, which is what Loke needs: a `string`
 * may not hold one, and a Windows argument vector is not guaranteed to be
 * well-formed. A count of -1 converts the terminator too, so both answers
 * include it. */
static arg_entry to_utf8(const uint16_t *wide) {
	arg_entry entry;
	int size = WideCharToMultiByte(CP_UTF8, 0, (const wchar_t *)wide, -1, 0, 0, 0, 0);
	entry.bytes = size > 0 ? (char *)malloc((size_t)size) : 0;
	if (entry.bytes == 0 ||
		WideCharToMultiByte(CP_UTF8, 0, (const wchar_t *)wide, -1, entry.bytes, size, 0, 0) != size) {
		loke_rt_v1_abort("cannot convert the argument vector");
	}
	entry.len = size - 1;
	return entry;
}

/* Called from the generated `wmain` before the initial thread attaches.
 *
 * It also puts the C library's stdout and stderr, which `core:fmt` and panics
 * write through, in binary mode: the UCRT opens them in text mode, which turns
 * each `\n` into `\r\n`, while `core:term` writes the handles directly. Binary
 * keeps both writers' bytes as given, as on every other platform
 * (standard-library.md "Standard byte streams and line input"). */
void loke_rt_v1_args_init(int32_t argc, const uint16_t **argv) {
	int32_t index;
	/* A windowed process started outside a terminal has neither: descriptor
	 * -2 (compiler-guide.md "Windowed programs"). */
	if (_fileno(stdout) >= 0) {
		_setmode(_fileno(stdout), _O_BINARY);
	}
	if (_fileno(stderr) >= 0) {
		_setmode(_fileno(stderr), _O_BINARY);
	}
	if (argc < 0) {
		argc = 0;
	}
	arg_count = argc;
	arg_values = (arg_entry *)malloc((size_t)((argc == 0 ? 1 : argc)) * sizeof(arg_entry));
	if (arg_values == 0) {
		loke_rt_v1_abort("cannot convert the argument vector");
	}
	for (index = 0; index < argc; index += 1) {
		arg_values[index] = to_utf8(argv[index]);
	}
}

int64_t loke_rt_v1_args_count(void) {
	return (int64_t)arg_count;
}

/* One cached UTF-8 argument, valid for the process lifetime, with its byte
 * length through `len`; null for an index out of range, which `core:os` turns
 * into a panic or the end of iteration. */
const char *loke_rt_v1_args_get(int64_t index, int64_t *len) {
	if (index < 0 || index >= (int64_t)arg_count) {
		return 0;
	}
	*len = arg_values[index].len;
	return arg_values[index].bytes;
}

/* design.md "Test procedures": which test a test executable runs. With no
 * argument, every one: -1. With one, the index of the test of that name, whose
 * argument is then consumed so `os.args` holds only the executable path. A
 * name no test has, or a second argument, ends the process with status 2. */
int64_t loke_rt_v1_test_select(const char *const *names, int64_t count) {
	int64_t index;
	if (arg_count < 2) {
		return -1;
	}
	if (arg_count == 2) {
		for (index = 0; index < count; index += 1) {
			if (strcmp(arg_values[1].bytes, names[index]) == 0) {
				arg_count = 1;
				return index;
			}
		}
		fprintf(stderr, "loke: no test is named `%s`\n", arg_values[1].bytes);
	} else {
		fputs("loke: a test executable takes at most one test name\n", stderr);
	}
	fflush(stderr);
	exit(2);
}
