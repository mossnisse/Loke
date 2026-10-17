// standard-library "`core:fmt`" and "`core:strconv`": float text is the "C"
// locale's, and failing to create that locale panics rather than falling back to
// the process locale. A Loke program cannot make `_create_locale` fail, so this
// host compiles its own copy of `runtime/format.c` with that call redirected,
// sets a decimal-comma locale, and parses `1.5`. `corpus_test.odin` runs it and
// expects exit 0: the panic stub exits with it; a parse that returns exits 1.
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>

static _locale_t failing_create_locale(int category, const char *name) {
    (void)category;
    (void)name;
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
    // Any decimal-comma locale shows the fallback; without one the parse would
    // still return, which fails the same way.
    if (setlocale(LC_NUMERIC, "de-DE") == 0) {
        setlocale(LC_NUMERIC, "fr-FR");
    }
    double value = loke_rt_v1_parse_f64("1.5");
    printf("returned %g\n", value);
    return 1;
}
