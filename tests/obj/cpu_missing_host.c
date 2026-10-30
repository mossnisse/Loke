/* compiler-guide.md "CPU levels": an object built for a level reports a
 * processor without it, and exits with status 3, before this `main`. The host
 * stands in for compiler-rt's processor detection, which `runtime/cpu.c`
 * asks, with one that finds no level beyond baseline: defining the detection's
 * symbols here keeps the linker from taking compiler-rt's. The names are the
 * interface compiler-rt shares with libgcc; the array is wider than any
 * Clang reads. `tests/obj/lib.loke` is built at `x86-64-v2`, level 1. */
unsigned int __cpu_features2[8];

int __cpu_indicator_init(void) {
	return 0;
}

int main(void) {
	/* The object's check exits first; reaching here means it passed. */
	return 0;
}
