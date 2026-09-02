/* The threaded host for `tests/obj/concurrentlib`.
 *
 * A foreign thread that calls into an object build must attach and detach
 * through the runtime API (design.md "Threads"), which is exactly what each
 * worker thunk does around its one call.
 *
 * There is no join here, and that is deliberate: waiting would need a platform
 * header this runtime does not use, and the wait it would replace is itself one
 * of the things under test. `conc_check` spins on an atomic counter the workers
 * increment, so the synchronisation being tested is the synchronisation being
 * used.
 *
 * `_beginthreadex` is the CRT entry point rather than `CreateThread`, so no
 * Windows SDK header is involved. The thread handles are deliberately not
 * closed: closing one needs that header too, and the process exits immediately
 * after the check. */
#include <process.h>

void loke_rt_v1_thread_attach(void);
void loke_rt_v1_thread_detach(void);

void conc_worker(int index, int iterations);
int conc_check(int threads, int iterations);

enum { THREADS = 8, ITERATIONS = 20000 };

static int worker_index[THREADS];

static unsigned __stdcall worker(void *argument) {
	int index = *(int *)argument;
	loke_rt_v1_thread_attach();
	conc_worker(index, ITERATIONS);
	loke_rt_v1_thread_detach();
	return 0;
}

int main(void) {
	int i;
	int status;
	uintptr_t handle;
	loke_rt_v1_thread_attach();
	for (i = 0; i < THREADS; i += 1) {
		worker_index[i] = i;
		handle = _beginthreadex(0, 0, worker, &worker_index[i], 0, 0);
		if (handle == 0) {
			loke_rt_v1_thread_detach();
			/* A thread that never started would make the check spin, so this is a
			 * failure of the harness rather than of what it tests. */
			return 90;
		}
	}
	status = conc_check(THREADS, ITERATIONS);
	loke_rt_v1_thread_detach();
	return status;
}
