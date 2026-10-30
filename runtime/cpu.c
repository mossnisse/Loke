/* compiler-guide.md "CPU levels": whether this processor runs the instruction
 * set a build was compiled for.
 *
 * A build above baseline compiles the whole runtime for its level, so this file
 * is the exception: every function in it is baseline x86-64 whatever the
 * command line asks for, or the check would itself execute the instructions it
 * is about to report missing. The libraries it calls are not compiled with the
 * build's flags: the toolchain supplies them already built, for every x64
 * processor. That includes the detection, which is compiler-rt's: from Clang
 * 18, `__builtin_cpu_supports` knows the levels by name, reads each level's
 * features from CPUID, and for `x86-64-v3` also asks XGETBV whether the
 * operating system saves the AVX registers.
 */
/* `getenv` is standard C; the Microsoft C library deprecates it. */
#define _CRT_SECURE_NO_WARNINGS
#include "loke_rt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma clang attribute push(__attribute__((target("arch=x86-64"))), apply_to = function)

/* Each level's name, as `-cpu` and `__builtin_cpu_supports` spell it. */
static const char *const level_names[] = {"x86-64", "x86-64-v2", "x86-64-v3"};

#define LEVEL_COUNT ((int32_t)(sizeof(level_names) / sizeof(level_names[0])))

int32_t loke_rt_v1_cpu_supports(int32_t level) {
	/* compiler-rt fills in its answers from a constructor, which need not have
	 * run yet when this is called from another, as an object build's check
	 * is; the first call detects and later ones return at once. */
	__builtin_cpu_init();
	switch (level) {
	case 0:
		return 1;
	case 1:
		return __builtin_cpu_supports("x86-64-v2") != 0;
	case 2:
		return __builtin_cpu_supports("x86-64-v3") != 0;
	default:
		return 0;
	}
}

/* design.md "@(cpu_dispatch=<string>)": whether a dispatched procedure runs its
 * copy for `level`. `LOKE_DISPATCH_CPU` caps the level for testing: with it
 * set, only a copy for the level it names or a lower one runs, and with a value
 * naming no level, none does. */
int32_t loke_rt_v1_cpu_dispatch(int32_t level) {
	const char *cap = getenv("LOKE_DISPATCH_CPU");
	if (cap != NULL) {
		int32_t allowed = -1;
		for (int32_t index = 0; index < LEVEL_COUNT; index++) {
			if (strcmp(cap, level_names[index]) == 0) {
				allowed = index;
			}
		}
		if (level > allowed) {
			return 0;
		}
	}
	return loke_rt_v1_cpu_supports(level);
}

void loke_rt_v1_require_cpu(int32_t level) {
	if (loke_rt_v1_cpu_supports(level)) {
		return;
	}
	/* The report and status `loke_rt_v1_abort` gives. A C host may call this
	 * after writing output of its own, which goes first. */
	fflush(stdout);
	if (level >= 0 && level < LEVEL_COUNT) {
		fputs("loke: this processor does not support ", stderr);
		fputs(level_names[level], stderr);
		fputs(", which the program was built for\n", stderr);
	} else {
		fputs("loke: the program was built for a CPU level this runtime does not know\n", stderr);
	}
	fflush(stderr);
	_Exit(3);
}

#pragma clang attribute pop
