/* The host for `tests/obj/attach.loke` (design.md "Values that outlive every
 * scope"). Its worker thread never calls `loke_rt_v1_thread_attach`: entering
 * an export attaches it. The exit code names the first check that failed.
 *
 * The thread is started through the CRT, as `concurrent_host.c` starts its
 * workers, and the main thread spins on an atomic flag instead of joining it. */
#include <process.h>
#include <stdatomic.h>

void loke_rt_v1_thread_detach(void);

void attach_track(int value);
int attach_read(void);

int attach_drops;
static int reentered;

/* Called by the drop while the thread detaches: it enters Loke again. */
void attach_reenter(void) {
	reentered = attach_read();
}

static int thread_status = 99;
static atomic_int finished;

static int run(void) {
	attach_track(5);
	loke_rt_v1_thread_detach();
	if (attach_drops != 1) {
		return 1;
	}
	if (reentered != 5) {
		return 2;
	}
	/* The entry during the drop did not attach the thread again. */
	loke_rt_v1_thread_detach();
	if (attach_drops != 1) {
		return 3;
	}
	/* A detached thread attaches again when it next enters. */
	attach_track(6);
	loke_rt_v1_thread_detach();
	if (attach_drops != 2 || reentered != 6) {
		return 4;
	}
	return 0;
}

static unsigned __stdcall worker(void *argument) {
	(void)argument;
	thread_status = run();
	atomic_store(&finished, 1);
	return 0;
}

int main(void) {
	if (_beginthreadex(0, 0, worker, 0, 0, 0) == 0) {
		return 90;
	}
	while (!atomic_load(&finished)) {
	}
	/* Detaching a thread that never entered Loke drops nothing. */
	loke_rt_v1_thread_detach();
	if (attach_drops != 2) {
		return 5;
	}
	return thread_status;
}
