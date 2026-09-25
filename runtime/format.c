/* The byte sink behind `core:fmt`, and the scalar spellings.
 *
 * design.md "String format printing": printing is a library protocol. The
 * protocol, the writer, the options, and the `print` family are Loke source in
 * `core:fmt`; what lives here is what every formatter ends at — turning one
 * scalar into bytes, and handing bytes to a stream.
 *
 * Keeping the scalars here rather than in generated LLVM is a size decision: a
 * base-N integer spelling is the same twenty lines whichever of the eleven
 * integer types asked for it.
 */
#include "loke_rt.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void loke_rt_v1_write_std(void *state, const uint8_t *bytes, int64_t count) {
	FILE *stream = (uintptr_t)state == LOKE_RT_STDERR ? stderr : stdout;
	if (count > 0) {
		fwrite(bytes, 1, (size_t)count, stream);
	}
}

/* `core:term` writes the standard handles directly, past this buffer, so it
 * flushes what `core:fmt` holds first; otherwise redirected output comes out of
 * order. */
void loke_rt_v1_flush_stdout(void) {
	fflush(stdout);
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
 * reversed: 128 bits in base 2 is the widest case and fits in 128 digits.
 *
 * ponytail: one 128-bit spelling serves every width, so a 64-bit value pays for
 * a 128-bit divide per digit. Formatting is not a hot path; give `uint64_t` its
 * own copy of this loop if it ever becomes one. */
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

static int64_t spell_unsigned(uint8_t *out, uint64_t value, int64_t base, int uppercase) {
	return spell_unsigned128(out, (unsigned __int128)value, base, uppercase);
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

/* `sci`, a `%.*e` spelling, one unit up in its last digit, so 9.99e+05 becomes
 * 1.00e+06. */
static void spell_up(char *sci) {
	char *exponent = strchr(sci, 'e');
	char *digit = exponent - 1;
	for (;;) {
		if (*digit == '.') {
			digit -= 1;
			continue;
		}
		if (*digit != '9') {
			*digit += 1;
			return;
		}
		*digit = '0';
		if (digit == sci || digit[-1] == '-') {
			/* Carried out of the leading digit: every digit is now 0. */
			*digit = '1';
			snprintf(exponent + 1, 8, "%+03d", atoi(exponent + 1) + 1);
			return;
		}
		digit -= 1;
	}
}

/* `%g`'s layout for a `%.*e` spelling, with the trailing zeros dropped: fixed
 * notation from 1e-4 to below 1e17, and an exponent outside that. */
static int spell_general(char *out, const char *sci) {
	char digits[24];
	int count = 0;
	int used = 0;
	const char *p = sci;
	if (*p == '-') {
		out[used++] = *p++;
	}
	for (; *p != 'e'; p++) {
		if (*p != '.') {
			digits[count++] = *p;
		}
	}
	int exponent = atoi(p + 1);
	while (count > 1 && digits[count - 1] == '0') {
		count -= 1;
	}
	if (exponent < -4 || exponent >= 17) {
		out[used++] = digits[0];
		if (count > 1) {
			out[used++] = '.';
			memcpy(out + used, digits + 1, (size_t)(count - 1));
			used += count - 1;
		}
		return used + snprintf(out + used, 8, "e%+03d", exponent);
	}
	if (exponent < 0) {
		out[used++] = '0';
		out[used++] = '.';
		for (int i = 1; i < -exponent; i++) {
			out[used++] = '0';
		}
		memcpy(out + used, digits, (size_t)count);
		return used + count;
	}
	for (int i = 0; i <= exponent || i < count; i++) {
		if (i == exponent + 1) {
			out[used++] = '.';
		}
		out[used++] = i < count ? digits[i] : '0';
	}
	return used;
}

static int reads_back(const char *sci, double value, int single) {
	double back = strtod(sci, 0);
	return single ? (float)back == (float)value : back == value;
}

/* The shortest spelling that reads back as the same value. `%.17g` alone always
 * round-trips a double but spells 0.1 as 0.10000000000000001, so the precisions
 * are tried in order and the first that survives `strtod` is kept. `single`
 * compares at `float` precision, where 9 digits always suffice: a widened `f32`
 * would otherwise print its binary noise, 0.10000000149011612.
 *
 * At each precision the spelling one up is tried after the nearest one. At a
 * power of two the gap below the value is half the gap above it, so the nearest
 * spelling can fall outside while the next one up still reads back: f64 2^-24
 * is 5.960464477539063e-08, not the nearest 16 digits, 5.960464477539062e-08.
 *
 * NaN and the infinities are spelled here because the C library's spelling is
 * the platform's: the UCRT writes `-nan(ind)`. A NaN's sign carries no value.
 *
 * ponytail: up to 17 `snprintf`/`strtod` pairs per value rather than Ryu or
 * Grisu. Formatting is not a hot path; swap in one of those if it becomes one. */
static void fmt_float(const loke_rt_writer_v1 *w, double value, int single) {
	if (isnan(value)) {
		loke_rt_v1_fmt_bytes(w, (const uint8_t *)"nan", 3);
		return;
	}
	if (isinf(value)) {
		if (value < 0) {
			loke_rt_v1_fmt_bytes(w, (const uint8_t *)"-inf", 4);
		} else {
			loke_rt_v1_fmt_bytes(w, (const uint8_t *)"inf", 3);
		}
		return;
	}
	/* The longest spelling, `-2.2250738585072014e-308`, is 24 bytes; the
	 * longest fixed one, `-0.00012345678901234567`, is 23. */
	char sci[32];
	char out[32];
	int widest = single ? 9 : 17;
	for (int precision = 1;; precision++) {
		snprintf(sci, sizeof(sci), "%.*e", precision - 1, value);
		if (precision == widest || reads_back(sci, value, single)) {
			break;
		}
		spell_up(sci);
		if (reads_back(sci, value, single)) {
			break;
		}
	}
	int used = spell_general(out, sci);
	loke_rt_v1_fmt_bytes(w, (const uint8_t *)out, used);
}

void loke_rt_v1_fmt_f64(const loke_rt_writer_v1 *w, double value) {
	fmt_float(w, value, 0);
}

void loke_rt_v1_fmt_f32(const loke_rt_writer_v1 *w, float value) {
	fmt_float(w, value, 1);
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
	/* `loke_rt_encode_rune` rejects exactly what cannot be printed — a negative
	 * value, one past U+10FFFF, or a surrogate — so its 0 is the replacement
	 * case. */
	int64_t used = loke_rt_encode_rune(buffer, value);
	if (used == 0) {
		loke_rt_v1_fmt_bytes(w, (const uint8_t *)"\xEF\xBF\xBD", 3); /* U+FFFD */
		return;
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
