/* Process arguments (design.md "Program entry and exit").
 *
 * Windows hands `wmain` a UTF-16 argument vector, and Loke text is UTF-8 by
 * invariant. The conversion happens once, here, before the initial thread
 * attaches — so `os.args` is a read of cached, already-valid UTF-8 rather than a
 * conversion at every use, and no Loke package needs an initializer to run.
 *
 * The three getters are deliberately foreign-ABI-safe scalars: `core:os` is
 * ordinary Loke source over a foreign block, with no compiler knowledge.
 */
#include "loke_rt.h"

#include <stdlib.h>
#include <string.h>

static int32_t arg_count;
static char **arg_values;

/* One UTF-16 code unit sequence to UTF-8. Surrogate pairs combine; an unpaired
 * surrogate becomes U+FFFD, because a Loke `string` may not hold one and a
 * Windows argument vector is not guaranteed to be well-formed. */
static char *to_utf8(const uint16_t *wide) {
	uint64_t units = 0;
	uint64_t bytes = 0;
	uint64_t at = 0;
	char *out;
	uint64_t written = 0;

	while (wide[units] != 0) {
		units += 1;
	}
	/* Four bytes per code unit is the worst case and never underestimates: a
	 * surrogate pair is two units producing four bytes. */
	bytes = units * 4u + 1u;
	out = (char *)malloc((size_t)bytes);
	if (out == 0) {
		loke_rt_v1_abort("cannot convert the argument vector");
	}

	while (at < units) {
		uint32_t code_point = wide[at];
		at += 1;
		if (code_point >= 0xD800u && code_point <= 0xDBFFu) {
			if (at < units && wide[at] >= 0xDC00u && wide[at] <= 0xDFFFu) {
				code_point = 0x10000u + ((code_point - 0xD800u) << 10) + (wide[at] - 0xDC00u);
				at += 1;
			} else {
				code_point = 0xFFFDu; /* an unpaired high surrogate */
			}
		} else if (code_point >= 0xDC00u && code_point <= 0xDFFFu) {
			code_point = 0xFFFDu; /* an unpaired low surrogate */
		}
		written += loke_rt_encode_rune((uint8_t *)(out + written), (int32_t)code_point);
	}
	out[written] = 0;
	return out;
}

/* Called from the generated `wmain` before the initial thread attaches. */
void loke_rt_v1_args_init(int32_t argc, const uint16_t **argv) {
	int32_t index;
	if (argc < 0) {
		argc = 0;
	}
	arg_count = argc;
	arg_values = (char **)malloc((size_t)((argc == 0 ? 1 : argc)) * sizeof(char *));
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

/* One zero-terminated UTF-8 argument, valid for the process lifetime. Out of
 * range yields the empty string rather than a fault: `core:os` bounds-checks
 * before it calls, so reaching this is a compiler bug, not a program one. */
const char *loke_rt_v1_args_at(int64_t index) {
	if (index < 0 || index >= (int64_t)arg_count) {
		return "";
	}
	return arg_values[index];
}

/* The byte length of one argument, so `core:os` can build a `string_view` over
 * the cached bytes without a second scan on the Loke side. */
int64_t loke_rt_v1_args_len(int64_t index) {
	if (index < 0 || index >= (int64_t)arg_count) {
		return 0;
	}
	return (int64_t)strlen(arg_values[index]);
}
