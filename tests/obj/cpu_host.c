/* compiler-guide.md "CPU levels": an object built above baseline checks the
 * processor from a static constructor, which the C runtime runs before this
 * `main`. The host stands in for the runtime's check, so it can see that the
 * check ran, and when, and for which level: `tests/obj/lib.loke` is built at
 * `x86-64-v2`, level 1. */
#include <stdint.h>

int widget_add(int a, int b);

void loke_rt_v1_thread_attach(void);
void loke_rt_v1_thread_detach(void);

static int32_t checked_level = -1;
static int checks = 0;

void loke_rt_v1_require_cpu(int32_t level) {
	checked_level = level;
	checks += 1;
}

int main(void) {
	int status;
	if (checks != 1 || checked_level != 1) {
		return 100 + checks;
	}
	loke_rt_v1_thread_attach();
	status = widget_add(3, 4);
	loke_rt_v1_thread_detach();
	return status == 7 ? 0 : status;
}
