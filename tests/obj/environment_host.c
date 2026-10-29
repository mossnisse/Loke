/* The host for `tests/obj/environment.loke` (design.md "Floating-point
 * operators"). Each call into Loke is made in an environment of the host's
 * own, which rounds upward, flushes subnormals to zero, reads them as zero,
 * and unmasks the invalid-operation exception: every probe must still see
 * Loke's, and the host must get its own back. The exit code names the first
 * check that failed.
 *
 * The thread is started as `concurrent_host.c` starts its workers, through
 * the CRT, so no Windows SDK header is involved; the main thread spins on an
 * atomic flag instead of joining it. */
#include <process.h>
#include <stdatomic.h>
#include <xmmintrin.h>

void loke_rt_v1_thread_attach(void);
void loke_rt_v1_thread_detach(void);

typedef int (*probe_fn)(double one);
typedef int (*visit_fn)(probe_fn probe, double one);

int env_probe(double one);
int env_through(visit_fn visit, double one);
void env_track(double one);

int env_dropped;

enum { ALL = 15 };

/* MXCSR: round upward (bits 13-14 = 10), flush-to-zero (bit 15),
 * denormals-are-zero (bit 6), and every exception masked but invalid
 * operation (bit 7). Bits 6-15 are the control bits. */
#define CONTROL 0xffc0u
#define HOST (0x4000u | 0x8000u | 0x0040u | (0x1f80u & ~0x0080u))

static int visited;

/* Called by Loke: it changes the environment, calls back into Loke, sees its
 * own environment again, and restores Loke's before returning. */
static int visit(probe_fn probe, double one) {
	unsigned saved = _mm_getcsr();
	int result;
	_mm_setcsr(HOST);
	result = probe(one);
	visited = (_mm_getcsr() & CONTROL) == (HOST & CONTROL);
	_mm_setcsr(saved);
	return result;
}

static int thread_status = 99;
static atomic_int finished;

/* A foreign thread with its own environment from before it attaches. */
static unsigned __stdcall worker(void *argument) {
	int probe;
	unsigned after;
	(void)argument;
	_mm_setcsr(HOST);
	loke_rt_v1_thread_attach();
	probe = env_probe(1.0);
	after = _mm_getcsr();
	loke_rt_v1_thread_detach();
	_mm_setcsr(0x1f80u);
	thread_status = probe != ALL ? 6 : (after & CONTROL) != (HOST & CONTROL) ? 7 : 0;
	atomic_store(&finished, 1);
	return 0;
}

static int check(void) {
	unsigned saved = _mm_getcsr();
	unsigned after;
	int probe;
	if (env_probe(1.0) != ALL) {
		return 1;
	}
	_mm_setcsr(HOST);
	probe = env_probe(1.0);
	after = _mm_getcsr();
	_mm_setcsr(saved);
	if (probe != ALL) {
		return 2;
	}
	if ((after & CONTROL) != (HOST & CONTROL)) {
		return 3;
	}
	if (env_through(visit, 1.0) != ALL) {
		return 4;
	}
	if (!visited) {
		return 5;
	}
	if (_beginthreadex(0, 0, worker, 0, 0, 0) == 0) {
		return 90;
	}
	while (!atomic_load(&finished)) {
	}
	return thread_status;
}

/* Detaching drops the thread-local value `env_track` set, in Loke, though the
 * host detaches in its own environment. */
int main(void) {
	int status;
	unsigned saved = _mm_getcsr();
	unsigned after;
	loke_rt_v1_thread_attach();
	status = check();
	env_track(1.0);
	_mm_setcsr(HOST);
	loke_rt_v1_thread_detach();
	after = _mm_getcsr();
	_mm_setcsr(saved);
	if (status != 0) {
		return status;
	}
	if (env_dropped != 1) {
		return 8;
	}
	if ((after & CONTROL) != (HOST & CONTROL)) {
		return 9;
	}
	return 0;
}
