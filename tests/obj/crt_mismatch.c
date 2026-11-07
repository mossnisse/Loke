/*
 * compiler-guide.md "C runtime": `corpus_test.odin` compiles this once for
 * the static C runtime, which clang chooses by default, and once with
 * `-fms-runtime-lib=dll`, the dynamic one `/MD` selects. Only the second
 * should draw L0755 when `crt_mismatch.loke` links it.
 */
#include <stdlib.h>

int crt_mismatch_answer(void) {
    int *cell = malloc(sizeof *cell);
    if (cell == NULL) {
        return 0;
    }
    *cell = 42;
    int answer = *cell;
    free(cell);
    return answer;
}
