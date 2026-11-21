/* The byte sink behind `core:fmt`, and the scalar spellings.
 *
 * standard-library.md "Printed forms": printing is a library protocol. The
 * protocol, the writer, the options, and the `print` family are Loke source in
 * `core:fmt`; what lives here is what every formatter ends at — turning one
 * scalar into bytes, and handing bytes to a stream.
 *
 * Keeping the scalars here rather than in generated LLVM is a size decision: a
 * base-N integer spelling is the same code whichever of the eleven integer
 * types asked for it.
 */
#include "loke_rt.h"

#include <errno.h>
#include <locale.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The "C" numeric locale, made once and shared by every thread. The process
 * locale is mutable through `setlocale`, and under a decimal-comma one plain
 * `printf` and `strtod` spell and read `1,5`: every spelling and reading of a
 * float here and in `core:strconv` goes through this locale instead.
 *
 * Two threads racing to make it both succeed, and the loser frees its copy.
 * Failing to make it answers 0 with `*failure` set to `LOKE_RT_NUMERIC_*`: the
 * `_l` functions read a null locale as the current one, so carrying on would
 * quietly bring back the comma it exists to rule out. A later call tries
 * again. */
static _locale_t try_c_numeric(int32_t *failure) {
	static _locale_t cached;
	_locale_t found = __atomic_load_n(&cached, __ATOMIC_ACQUIRE);
	if (found != 0) {
		return found;
	}
	errno = 0;
	_locale_t made = _create_locale(LC_NUMERIC, "C");
	if (made == 0) {
		*failure = errno == ENOMEM ? LOKE_RT_NUMERIC_OUT_OF_MEMORY : LOKE_RT_NUMERIC_UNAVAILABLE;
		return 0;
	}
	_locale_t expected = 0;
	if (!__atomic_compare_exchange_n(&cached, &expected, made, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
		_free_locale(made);
		return expected;
	}
	return made;
}

/* What printing does instead, since its sink has no way to report a failure. */
static void no_c_numeric(void) {
	loke_rt_v1_panic("cannot create the \"C\" numeric locale for float text");
}

static _locale_t c_numeric(void) {
	int32_t failure = 0;
	_locale_t made = try_c_numeric(&failure);
	if (made == 0) {
		no_c_numeric();
	}
	return made;
}

/* `core:strconv`'s float conversion. The caller has already checked the
 * spelling, so a correct conversion consumes all of it; one that does not
 * answers `LOKE_RT_NUMERIC_REJECTED`, and a locale that cannot be made answers
 * its failure. Otherwise it stores the value and answers 0. */
int32_t loke_rt_v1_try_parse_f64(const char *text, double *value) {
	int32_t failure = 0;
	_locale_t locale = try_c_numeric(&failure);
	if (locale == 0) {
		return failure;
	}
	char *end = 0;
	*value = _strtod_l(text, &end, locale);
	return *end == 0 ? 0 : LOKE_RT_NUMERIC_REJECTED;
}

/* Standard output a process has none of is dropped, as the C library drops it;
 * standard error may still reach a debugger (`loke_rt_err_write`). */
void loke_rt_v1_write_std(void *state, const uint8_t *bytes, int64_t count) {
	if (count <= 0) {
		return;
	}
	if ((uintptr_t)state == LOKE_RT_STDERR) {
		loke_rt_err_write((const char *)bytes, (size_t)count);
	} else {
		fwrite(bytes, 1, (size_t)count, stdout);
	}
}

/* `core:term` writes the standard handles directly, past this buffer, so it
 * flushes what `core:fmt` holds first; otherwise redirected output comes out of
 * order. */
void loke_rt_v1_flush_stdout(void) {
	fflush(stdout);
}

void loke_rt_v1_fmt_bytes(const loke_rt_writer_v1 *w, const uint8_t *bytes, int64_t count) {
	if (w->witness == 0) {
		loke_rt_v1_panic("call through a nil dyn view");
	}
	if (count > 0) {
		loke_rt_v1_sink_write(w, bytes, count);
	}
}

static int64_t base_of(const loke_rt_options_v1 *o) {
	if (o == 0 || o->base < 2 || o->base > 36) {
		return 10;
	}
	return o->base;
}

/* `value`'s digits, written least-significant first backwards from `end`, so
 * they land in order without a copy; answers where they start. 128 bits in base
 * 2 is the widest case, at 128 digits. Once the rest fits 64 bits it is divided
 * as a `uint64_t`, far cheaper than a 128-bit divide per digit. */
static uint8_t *spell_digits(uint8_t *end, unsigned __int128 value, uint64_t base, int uppercase) {
	const char *digits = uppercase ? "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	                               : "0123456789abcdefghijklmnopqrstuvwxyz";
	for (; value > UINT64_MAX; value /= base) {
		*--end = (uint8_t)digits[value % base];
	}
	uint64_t rest = (uint64_t)value;
	do {
		*--end = (uint8_t)digits[rest % base];
		rest /= base;
	} while (rest != 0);
	return end;
}

/* Every integer entry point: a magnitude, and whether a `-` goes before it. */
static void fmt_integer(
	const loke_rt_writer_v1 *w, unsigned __int128 magnitude, int negative, const loke_rt_options_v1 *o) {
	uint8_t buffer[129];
	uint8_t *end = buffer + sizeof(buffer);
	uint8_t *start = spell_digits(end, magnitude, (uint64_t)base_of(o), o != 0 && o->uppercase != 0);
	if (negative) {
		*--start = '-';
	}
	loke_rt_v1_fmt_bytes(w, start, end - start);
}

void loke_rt_v1_fmt_u64(const loke_rt_writer_v1 *w, uint64_t value, const loke_rt_options_v1 *o) {
	fmt_integer(w, value, 0, o);
}

/* A negative value's magnitude is its unsigned negation, which, unlike negating
 * the signed value, cannot overflow at the most negative one. */
void loke_rt_v1_fmt_i64(const loke_rt_writer_v1 *w, int64_t value, const loke_rt_options_v1 *o) {
	fmt_integer(w, value < 0 ? 0 - (uint64_t)value : (uint64_t)value, value < 0, o);
}

void loke_rt_v1_fmt_u128(
	const loke_rt_writer_v1 *w, uint64_t low, uint64_t high, const loke_rt_options_v1 *o) {
	fmt_integer(w, ((unsigned __int128)high << 64) | low, 0, o);
}

void loke_rt_v1_fmt_i128(
	const loke_rt_writer_v1 *w, uint64_t low, uint64_t high, const loke_rt_options_v1 *o) {
	unsigned __int128 bits = ((unsigned __int128)high << 64) | low;
	int negative = (high >> 63) != 0;
	fmt_integer(w, negative ? 0 - bits : bits, negative, o);
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
 * notation from 1e-4 to below 1e17, and an exponent outside that. A float never
 * reads as an integer (standard-library.md "Printed forms"): fixed notation keeps
 * one fractional digit, `1.0`, and an exponent is written bare, `1e21`, `1e-7`. */
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
		return used + snprintf(out + used, 8, "e%d", exponent);
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
	if (count <= exponent + 1) {
		out[used++] = '.';
		out[used++] = '0';
	}
	return used;
}

/* `x` rounded to `f16`, ties to even, as arithmetic on the scaled value: the
 * Win64 C ABI has no `f16` (design.md "Foreign-ABI-safe types"). Past `f16`'s
 * range it gives a value no `f16` equals, which is all `reads_back` asks. */
static double nearest_f16(double x) {
	int exponent;
	frexp(x, &exponent);
	int unit = exponent - 11 < -24 ? -24 : exponent - 11;
	return ldexp(nearbyint(ldexp(x, -unit)), unit);
}

static int reads_back(const char *sci, double value, int bits, _locale_t locale) {
	double back = _strtod_l(sci, 0, locale);
	switch (bits) {
	case 16:
		return nearest_f16(back) == value;
	case 32:
		return (float)back == (float)value;
	default:
		return back == value;
	}
}

/* The shortest spelling that reads back as the same value. `%.17g` alone always
 * round-trips a double but spells 0.1 as 0.10000000000000001, so the precisions
 * are tried in order and the first that survives `strtod` is kept. `bits`
 * compares at that width, where 5 digits suffice for `f16` and 9 for `f32`: a
 * widened `f32` would otherwise print its binary noise, 0.10000000149011612.
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
static int64_t spell_float(uint8_t *out, double value, int bits) {
	if (isnan(value)) {
		memcpy(out, "nan", 3);
		return 3;
	}
	if (isinf(value)) {
		if (value < 0) {
			memcpy(out, "-inf", 4);
			return 4;
		}
		memcpy(out, "inf", 3);
		return 3;
	}
	int32_t failure = 0;
	_locale_t locale = try_c_numeric(&failure);
	if (locale == 0) {
		return -(int64_t)failure;
	}
	/* The longest spelling, `-2.2250738585072014e-308`, is 24 bytes; the
	 * longest fixed one, `-0.00012345678901234567`, is 23. */
	char sci[32];
	int widest = bits == 16 ? 5 : bits == 32 ? 9 : 17;
	for (int precision = 1;; precision++) {
		_snprintf_s_l(sci, sizeof(sci), _TRUNCATE, "%.*e", locale, precision - 1, value);
		if (precision == widest || reads_back(sci, value, bits, locale)) {
			break;
		}
		spell_up(sci);
		if (reads_back(sci, value, bits, locale)) {
			break;
		}
	}
	return spell_general((char *)out, sci);
}

/* NaN and the infinities need no locale, so printing them cannot panic. */
static void fmt_float(const loke_rt_writer_v1 *w, double value, int bits) {
	uint8_t out[LOKE_RT_FLOAT_SPELLING_MAX];
	int64_t used = spell_float(out, value, bits);
	if (used < 0) {
		no_c_numeric();
	}
	loke_rt_v1_fmt_bytes(w, out, used);
}

/* `fmt.try_spell_f64`: `fmt_float`'s bytes into `out`, which holds
 * `LOKE_RT_FLOAT_SPELLING_MAX` of them, answering their count, or the negated
 * locale failure where printing panics. */
int64_t loke_rt_v1_try_spell_f64(uint8_t *out, double value) {
	return spell_float(out, value, 64);
}

void loke_rt_v1_fmt_f64(const loke_rt_writer_v1 *w, double value) {
	fmt_float(w, value, 64);
}

void loke_rt_v1_fmt_f32(const loke_rt_writer_v1 *w, float value) {
	fmt_float(w, value, 32);
}

void loke_rt_v1_fmt_f16(const loke_rt_writer_v1 *w, float value) {
	fmt_float(w, value, 16);
}

/* `fmt.fixed`: `value` with exactly `digits` fractional digits, rounded as the
 * C library rounds, to nearest with ties to even. `digits` is clamped to 0 to
 * 40, so the longest spelling is a sign, the 309 integer digits of the largest
 * double, the point, and 40 digits. NaN and the infinities print as any float. */
void loke_rt_v1_fmt_fixed(const loke_rt_writer_v1 *w, double value, int64_t digits) {
	if (isnan(value) || isinf(value)) {
		fmt_float(w, value, 64);
		return;
	}
	digits = digits < 0 ? 0 : digits > 40 ? 40 : digits;
	char out[352];
	int used = _snprintf_s_l(out, sizeof(out), _TRUNCATE, "%.*f", c_numeric(), (int)digits, value);
	if (used > 0) {
		loke_rt_v1_fmt_bytes(w, (const uint8_t *)out, used);
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
 * it denotes rather than as its number. `loke_rt_encode_rune` rejects exactly
 * what cannot be printed — a negative value, one past U+10FFFF, or a surrogate —
 * so its 0 is where U+FFFD is printed instead. Answers the count in `out`. */
static int64_t encode_printed_rune(uint8_t out[4], int32_t value) {
	int64_t used = loke_rt_encode_rune(out, value);
	if (used == 0) {
		memcpy(out, "\xEF\xBF\xBD", 3);
		return 3;
	}
	return used;
}

void loke_rt_v1_fmt_rune(const loke_rt_writer_v1 *w, int32_t value) {
	uint8_t buffer[4];
	loke_rt_v1_fmt_bytes(w, buffer, encode_printed_rune(buffer, value));
}

/* `bytes` as a literal would spell them, between `quote`s: a string or rune
 * nested in an aggregate (standard-library.md "Printed forms"). Only the
 * backslash, the quote, and control bytes are escaped; any other byte, including
 * the rest of UTF-8, is written as it is. */
static void fmt_quoted(const loke_rt_writer_v1 *w, const uint8_t *bytes, int64_t count, uint8_t quote) {
	static const char hex[] = "0123456789ABCDEF";
	loke_rt_v1_fmt_bytes(w, &quote, 1);
	int64_t start = 0;
	for (int64_t i = 0; i < count; i++) {
		uint8_t b = bytes[i];
		uint8_t escape[4] = {'\\', 0, 0, 0};
		int64_t length = 2;
		if (b == '\\' || b == quote) {
			escape[1] = b;
		} else if (b == '\n') {
			escape[1] = 'n';
		} else if (b == '\r') {
			escape[1] = 'r';
		} else if (b == '\t') {
			escape[1] = 't';
		} else if (b < 0x20 || b == 0x7F) {
			escape[1] = 'x';
			escape[2] = (uint8_t)hex[b >> 4];
			escape[3] = (uint8_t)hex[b & 15];
			length = 4;
		} else {
			continue;
		}
		loke_rt_v1_fmt_bytes(w, bytes + start, i - start);
		loke_rt_v1_fmt_bytes(w, escape, length);
		start = i + 1;
	}
	loke_rt_v1_fmt_bytes(w, bytes + start, count - start);
	loke_rt_v1_fmt_bytes(w, &quote, 1);
}

void loke_rt_v1_fmt_quoted(const loke_rt_writer_v1 *w, const uint8_t *bytes, int64_t count) {
	fmt_quoted(w, bytes, count, '"');
}

void loke_rt_v1_fmt_quoted_rune(const loke_rt_writer_v1 *w, int32_t value) {
	uint8_t buffer[4];
	fmt_quoted(w, buffer, encode_printed_rune(buffer, value), '\'');
}

void loke_rt_v1_fmt_ptr(const loke_rt_writer_v1 *w, const void *value) {
	if (value == 0) {
		loke_rt_v1_fmt_bytes(w, (const uint8_t *)"<nil>", 5);
		return;
	}
	uint8_t buffer[18];
	uint8_t *start = spell_digits(buffer + sizeof(buffer), (uintptr_t)value, 16, 1) - 2;
	memcpy(start, "0x", 2);
	loke_rt_v1_fmt_bytes(w, start, buffer + sizeof(buffer) - start);
}
