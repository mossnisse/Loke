/* compiler-guide.md "CPU levels": whether this processor runs the instruction
 * set a build was compiled for.
 *
 * A build above baseline compiles the whole runtime for its level, so this file
 * is the exception: every function in it is baseline x86-64 whatever the
 * command line asks for, or the check would itself execute the instructions it
 * is about to report missing. The C library it reports through is not
 * compiled with the build's flags: the toolchain supplies it already built, for
 * every x64 processor.
 */
#include "loke_rt.h"

#include <stdio.h>
#include <stdlib.h>

#if defined(_MSC_VER) && !defined(__clang__)
#include <intrin.h>
#endif

#if defined(__clang__)
#pragma clang attribute push(__attribute__((target("arch=x86-64"))), apply_to = function)
#endif

typedef struct {
	uint32_t eax, ebx, ecx, edx;
} cpuid_result;

static cpuid_result cpuid(uint32_t leaf, uint32_t subleaf) {
	cpuid_result r;
#if defined(_MSC_VER) && !defined(__clang__)
	int words[4];
	__cpuidex(words, (int)leaf, (int)subleaf);
	r.eax = (uint32_t)words[0];
	r.ebx = (uint32_t)words[1];
	r.ecx = (uint32_t)words[2];
	r.edx = (uint32_t)words[3];
#else
	__asm__ volatile("cpuid" : "=a"(r.eax), "=b"(r.ebx), "=c"(r.ecx), "=d"(r.edx) : "a"(leaf), "c"(subleaf));
#endif
	return r;
}

/* The register state the operating system saves on a switch. Valid only once
 * CPUID reports OSXSAVE; without it `xgetbv` is itself an invalid opcode. */
static uint64_t enabled_state(void) {
#if defined(_MSC_VER) && !defined(__clang__)
	return _xgetbv(0);
#else
	uint32_t low, high;
	__asm__ volatile("xgetbv" : "=a"(low), "=d"(high) : "c"(0));
	return ((uint64_t)high << 32) | low;
#endif
}

/* What each level needs, cumulatively, in the bits CPUID reports it by. */
typedef struct {
	const char *name;
	uint32_t leaf1_ecx;     /* CPUID 1, ECX */
	uint32_t leaf7_ebx;     /* CPUID 7.0, EBX */
	uint32_t extended_ecx;  /* CPUID 0x80000001, ECX */
	uint64_t state;         /* XCR0: the registers the OS must save */
} cpu_level;

/* SSE3 0, SSSE3 9, CMPXCHG16B 13, SSE4.1 19, SSE4.2 20, POPCNT 23; LAHF/SAHF
 * in 64-bit mode is extended bit 0. */
#define V2_LEAF1 0x00982201u
#define V2_EXTENDED 0x00000001u
/* FMA 12, MOVBE 22, OSXSAVE 27, AVX 28, F16C 29; BMI1 3, AVX2 5, BMI2 8; LZCNT
 * is extended bit 5. The OS must save the SSE and AVX state, XCR0 bits 1-2. */
#define V3_LEAF1 (V2_LEAF1 | 0x38401000u)
#define V3_LEAF7 0x00000128u
#define V3_EXTENDED (V2_EXTENDED | 0x00000020u)
#define V3_STATE 0x06u

static const cpu_level levels[] = {
	{"x86-64", 0, 0, 0, 0},
	{"x86-64-v2", V2_LEAF1, 0, V2_EXTENDED, 0},
	{"x86-64-v3", V3_LEAF1, V3_LEAF7, V3_EXTENDED, V3_STATE},
};

#define LEVEL_COUNT ((int32_t)(sizeof(levels) / sizeof(levels[0])))

static int32_t supports(const cpu_level *need) {
	uint32_t max_leaf = cpuid(0, 0).eax;
	uint32_t max_extended = cpuid(0x80000000u, 0).eax;
	uint32_t leaf1_ecx = max_leaf >= 1 ? cpuid(1, 0).ecx : 0;
	uint32_t leaf7_ebx = max_leaf >= 7 ? cpuid(7, 0).ebx : 0;
	uint32_t extended_ecx = max_extended >= 0x80000001u ? cpuid(0x80000001u, 0).ecx : 0;
	if ((leaf1_ecx & need->leaf1_ecx) != need->leaf1_ecx ||
	    (leaf7_ebx & need->leaf7_ebx) != need->leaf7_ebx ||
	    (extended_ecx & need->extended_ecx) != need->extended_ecx) {
		return 0;
	}
	if (need->state == 0) {
		return 1;
	}
	/* OSXSAVE, bit 27, is part of every level that needs saved state. */
	return (enabled_state() & need->state) == need->state;
}

int32_t loke_rt_v1_cpu_supports(int32_t level) {
	if (level < 0 || level >= LEVEL_COUNT) {
		return 0;
	}
	return supports(&levels[level]);
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
		fputs(levels[level].name, stderr);
		fputs(", which the program was built for\n", stderr);
	} else {
		fputs("loke: the program was built for a CPU level this runtime does not know\n", stderr);
	}
	fflush(stderr);
	_Exit(3);
}

#if defined(__clang__)
#pragma clang attribute pop
#endif
