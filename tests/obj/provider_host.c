/* The C host of an object build that selects providers (design.md "Build
 * modes"). Nothing calls the initializer automatically: this
 * host calls it once, after attaching a thread and before using any export.
 *
 * The second call proves the documented no-op: a host that cannot tell whether
 * it has already initialized may ask again. The first is made rounding upward,
 * which the initializer must neither see nor change (design.md "Floating-point
 * operators").
 *
 * No headers but the SSE intrinsics, for the same reason `host.c` uses none: an
 * object build's whole point is that a foreign consumer needs only these
 * declarations. */
#include <xmmintrin.h>

double provider_one = 1.0;

void loke_rt_v1_thread_attach(void);
void loke_rt_v1_thread_detach(void);
void loke_rt_v1_program_init(void);

int hostlib_report(void);

int main(void) {
	int status;
	unsigned saved = _mm_getcsr();
	unsigned after;
	loke_rt_v1_thread_attach();
	_mm_setcsr(0x5f80u);
	loke_rt_v1_program_init();
	after = _mm_getcsr();
	_mm_setcsr(saved);
	if ((after & 0xffc0u) != 0x5f80u) {
		loke_rt_v1_thread_detach();
		return 7;
	}
	loke_rt_v1_program_init();
	status = hostlib_report();
	loke_rt_v1_thread_detach();
	return status;
}
