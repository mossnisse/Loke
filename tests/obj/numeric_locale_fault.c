// standard-library "`core:fmt`" and "`core:strconv`": float text is the "C"
// locale's, and failing to create that locale panics rather than falling back to
// the process locale. A Loke program cannot make `_create_locale` fail, so this
// host compiles its own copy of `runtime/format.c` with that call redirected and
// sets a decimal-comma locale. The fallible entry points behind
// `strconv.try_parse_f64` and `fmt.try_spell_f64` must report the failure, as
// out of memory when the creation failed to allocate and as unavailable
// otherwise; printing a float must then panic. `corpus_test.odin` runs it and
// expects exit 0: the panic stub exits with it; a print that returns exits 1,
// and a wrong fallible answer exits 4 or more.
#include <errno.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>

static int fail_with_enomem;

static _locale_t failing_create_locale(int category, const char *name) {
    (void)category;
    (void)name;
    if (fail_with_enomem) {
        errno = ENOMEM;
    }
    return 0;
}

#define _create_locale failing_create_locale
#include "format.c"
#undef _create_locale

void loke_rt_v1_panic(const char *message) {
    printf("panic: %s\n", message);
    exit(0);
}

void loke_rt_v1_sink_write(const loke_rt_writer_v1 *w, const uint8_t *bytes, int64_t count) {
    (void)w;
    (void)bytes;
    (void)count;
    exit(2);
}

int64_t loke_rt_encode_rune(uint8_t *out, int32_t value) {
    (void)out;
    (void)value;
    exit(3);
}

int main(void) {
    // Any decimal-comma locale shows the fallback; without one a print would
    // still return, which fails the same way.
    if (setlocale(LC_NUMERIC, "de-DE") == 0) {
        setlocale(LC_NUMERIC, "fr-FR");
    }
    double value = 0;
    if (loke_rt_v1_try_parse_f64("1.5", &value) != LOKE_RT_NUMERIC_UNAVAILABLE) {
        return 4;
    }
    uint8_t spelled[LOKE_RT_FLOAT_SPELLING_MAX];
    if (loke_rt_v1_try_spell_f64(spelled, 1.5) != -LOKE_RT_NUMERIC_UNAVAILABLE) {
        return 5;
    }
    // NaN and the infinities need no locale.
    if (loke_rt_v1_try_spell_f64(spelled, NAN) != 3) {
        return 6;
    }
    fail_with_enomem = 1;
    if (loke_rt_v1_try_parse_f64("1.5", &value) != LOKE_RT_NUMERIC_OUT_OF_MEMORY) {
        return 7;
    }
    if (loke_rt_v1_try_spell_f64(spelled, 1.5) != -LOKE_RT_NUMERIC_OUT_OF_MEMORY) {
        return 8;
    }
    // The panic comes before the writer is used.
    loke_rt_v1_fmt_f64(0, 1.5);
    printf("printing returned\n");
    return 1;
}
