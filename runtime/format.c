/* The byte sink behind `core:fmt`, and the scalar spellings.
 *
 * design.md "String format printing": "Formatting is a library protocol." The
 * protocol, the writer, the options, and the `print` family are Loke source in
 * `core:fmt`; what lives here is what every formatter ends at — turning one
 * scalar into bytes, and handing bytes to a stream.
 *
 * Keeping the scalars here rather than in generated LLVM is a size decision: a
 * base-N integer spelling is the same twenty lines whichever of the eleven
 * integer types asked for it.
 */
#include "loke_rt.h"

#include <stdio.h>
#include <string.h>

void loke_rt_v1_write_std(void *state, const uint8_t *bytes, int64_t count) {
	FILE *stream = (uintptr_t)state == LOKE_RT_STDERR ? stderr : stdout;
	if (count > 0) {
		fwrite(bytes, 1, (size_t)count, stream);
	}
}

void loke_rt_v1_fmt_bytes(const loke_rt_writer_v1 *w, const uint8_t *bytes, int64_t count) {
	if (w != 0 && w->write != 0 && count > 0) {
		w->write(w->state, bytes, count);
	}
}

static int64_t base_of(const loke_rt_options_v1 *o) {
	if (o == 0 || o->base < 2 || o->base > 36) {
		return 10;
	}
	return o->base;
}

/* Digits are produced least-significant first into a fixed buffer, then
 * reversed: 64 bits in base 2 is the widest case and fits in 64 digits. */
static int64_t spell_unsigned(uint8_t *out, uint64_t value, int64_t base, int uppercase) {
	const char *digits = uppercase ? "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	                               : "0123456789abcdefghijklmnopqrstuvwxyz";
	uint8_t scratch[64];
	int64_t used = 0;
	do {
		scratch[used++] = (uint8_t)digits[value % (uint64_t)base];
		value /= (uint64_t)base;
	} while (value != 0);
	for (int64_t i = 0; i < used; i++) {
		out[i] = scratch[used - 1 - i];
	}
	return used;
}

static int64_t spell_unsigned128(
	uint8_t *out, unsigned __int128 value, int64_t base, int uppercase) {
	const char *digits = uppercase ? "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	                               : "0123456789abcdefghijklmnopqrstuvwxyz";
	uint8_t scratch[128];
	int64_t used = 0;
	do {
		scratch[used++] = (uint8_t)digits[value % (unsigned __int128)base];
		value /= (unsigned __int128)base;
	} while (value != 0);
	for (int64_t i = 0; i < used; i++) {
		out[i] = scratch[used - 1 - i];
	}
	return used;
}

void loke_rt_v1_fmt_u64(const loke_rt_writer_v1 *w, uint64_t value, const loke_rt_options_v1 *o) {
	uint8_t buffer[64];
	int64_t used = spell_unsigned(buffer, value, base_of(o), o != 0 && o->uppercase != 0);
	loke_rt_v1_fmt_bytes(w, buffer, used);
}

void loke_rt_v1_fmt_i64(const loke_rt_writer_v1 *w, int64_t value, const loke_rt_options_v1 *o) {
	uint8_t buffer[66];
	int64_t used = 0;
	uint64_t magnitude;
	if (value < 0) {
		buffer[used++] = '-';
		/* Negating the most negative value overflows; complementing does not. */
		magnitude = (uint64_t)(-(value + 1)) + 1;
	} else {
		magnitude = (uint64_t)value;
	}
	used += spell_unsigned(buffer + used, magnitude, base_of(o), o != 0 && o->uppercase != 0);
	loke_rt_v1_fmt_bytes(w, buffer, used);
}

void loke_rt_v1_fmt_u128(
	const loke_rt_writer_v1 *w, uint64_t low, uint64_t high, const loke_rt_options_v1 *o) {
	uint8_t buffer[128];
	unsigned __int128 value = ((unsigned __int128)high << 64) | low;
	int64_t used = spell_unsigned128(buffer, value, base_of(o), o != 0 && o->uppercase != 0);
	loke_rt_v1_fmt_bytes(w, buffer, used);
}

void loke_rt_v1_fmt_i128(
	const loke_rt_writer_v1 *w, uint64_t low, uint64_t high, const loke_rt_options_v1 *o) {
	uint8_t buffer[129];
	int64_t used = 0;
	unsigned __int128 bits = ((unsigned __int128)high << 64) | low;
	unsigned __int128 magnitude = bits;
	if ((high >> 63) != 0) {
		buffer[used++] = '-';
		magnitude = (~bits) + 1;
	}
	used += spell_unsigned128(
		buffer + used, magnitude, base_of(o), o != 0 && o->uppercase != 0);
	loke_rt_v1_fmt_bytes(w, buffer, used);
}

/* ponytail: `%g` through the C library rather than a Ryu/Grisu implementation.
 * It round-trips at 17 significant digits, which is what shortest-representation
 * printing would also guarantee; swap it out if the exact shortest spelling ever
 * becomes observable. */
void loke_rt_v1_fmt_f64(const loke_rt_writer_v1 *w, double value) {
	char buffer[64];
	int used = snprintf(buffer, sizeof(buffer), "%.17g", value);
	if (used > 0) {
		loke_rt_v1_fmt_bytes(w, (const uint8_t *)buffer, used);
	}
}

void loke_rt_v1_fmt_bool(const loke_rt_writer_v1 *w, int32_t value) {
	if (value != 0) {
		loke_rt_v1_fmt_bytes(w, (const uint8_t *)"true", 4);
	} else {
		loke_rt_v1_fmt_bytes(w, (const uint8_t *)"false", 5);
	}
}

/* design.md: a `rune` is a Unicode scalar value, so it prints as the character
 * it denotes rather than as its number. */
void loke_rt_v1_fmt_rune(const loke_rt_writer_v1 *w, int32_t value) {
	uint8_t buffer[4];
	uint32_t v = (uint32_t)value;
	int64_t used;
	if (value < 0 || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) {
		loke_rt_v1_fmt_bytes(w, (const uint8_t *)"\xEF\xBF\xBD", 3); /* U+FFFD */
		return;
	}
	if (v < 0x80) {
		buffer[0] = (uint8_t)v;
		used = 1;
	} else if (v < 0x800) {
		buffer[0] = (uint8_t)(0xC0 | (v >> 6));
		buffer[1] = (uint8_t)(0x80 | (v & 0x3F));
		used = 2;
	} else if (v < 0x10000) {
		buffer[0] = (uint8_t)(0xE0 | (v >> 12));
		buffer[1] = (uint8_t)(0x80 | ((v >> 6) & 0x3F));
		buffer[2] = (uint8_t)(0x80 | (v & 0x3F));
		used = 3;
	} else {
		buffer[0] = (uint8_t)(0xF0 | (v >> 18));
		buffer[1] = (uint8_t)(0x80 | ((v >> 12) & 0x3F));
		buffer[2] = (uint8_t)(0x80 | ((v >> 6) & 0x3F));
		buffer[3] = (uint8_t)(0x80 | (v & 0x3F));
		used = 4;
	}
	loke_rt_v1_fmt_bytes(w, buffer, used);
}

void loke_rt_v1_fmt_ptr(const loke_rt_writer_v1 *w, const void *value) {
	if (value == 0) {
		loke_rt_v1_fmt_bytes(w, (const uint8_t *)"<nil>", 5);
		return;
	}
	uint8_t buffer[18];
	buffer[0] = '0';
	buffer[1] = 'x';
	int64_t used = 2 + spell_unsigned(buffer + 2, (uint64_t)(uintptr_t)value, 16, 1);
	loke_rt_v1_fmt_bytes(w, buffer, used);
}
