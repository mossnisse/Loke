/* Panic and per-thread unwind state (m6a-plan decision "Logical panic unwind").
 *
 * A panic never resumes, so nothing unwinds the native stack: the runtime walks
 * the frames the compiler pushed and runs their cleanup, then aborts. Every
 * frame's storage is still live, because the panicking call is below it.
 */
#include "loke_rt.h"

#include <stdio.h>

/* Per thread: a panic ends the whole process, so nothing is shared. */
static __declspec(thread) loke_rt_frame_v1 *frames;
static __declspec(thread) int32_t panicking;
/* NOT_ATTACHED before the thread first enters Loke and after it detaches;
 * DETACHING while detach runs its thread-local drops, so a call into Loke that a
 * drop makes through C neither attaches the thread again nor detaches it
 * twice. */
enum { NOT_ATTACHED, ATTACHED, DETACHING };
static __declspec(thread) int32_t attached;

/* design.md "Values that outlive every scope": every entry Loke code has from
 * foreign code calls this, so a thread attaches the first time it enters.
 * An attached thread may be running Loke frames below the entry, which an
 * unwind must still reach, so attaching again changes nothing. */
void loke_rt_v1_thread_attach(void) {
	if (attached != NOT_ATTACHED) {
		return;
	}
	frames = 0;
	panicking = 0;
	attached = ATTACHED;
}

void loke_rt_v1_thread_detach(void) {
	if (attached == DETACHING) {
		return;
	}
	frames = 0;
	if (attached == ATTACHED) {
		attached = DETACHING;
		loke_rt_v1_program_tls_cleanup();
	}
	attached = NOT_ATTACHED;
	/* A partial line held for the debugger is the thread's own, and a drop
	 * above may have written one. */
	loke_rt_err_end_thread();
}

void loke_rt_v1_run_task(loke_rt_task_entry_v1 run, void *frame) {
	run(frame);
}

void loke_rt_v1_frame_push(loke_rt_frame_v1 *frame, loke_rt_cleanup_v1 cleanup, void *context) {
	frame->previous = frames;
	frame->cleanup = cleanup;
	frame->context = context;
	frames = frame;
}

/* A procedure that registered nothing never pushed, and its zeroed record must
 * leave the caller's frame alone. */
void loke_rt_v1_frame_pop(loke_rt_frame_v1 *frame) {
	if (frames == frame) {
		frames = frame->previous;
	}
}

void loke_rt_v1_panic(const char *message) {
	loke_rt_v1_panic_begin(message);
	loke_rt_v1_panic_end();
}

void loke_rt_v1_panic_begin(const char *message) {
	/* design.md "Panic during unwinding". A formatter that panics while the
	 * report is written lands here too. */
	if (panicking) {
		loke_rt_v1_abort("panic while unwinding a panic");
	}
	panicking = 1;

	fflush(stdout);
	loke_rt_err_puts("loke: panic: ");
	loke_rt_err_puts(message == 0 ? "runtime failure" : message);
}

void loke_rt_v1_panic_end(void) {
	loke_rt_err_puts("\n");
	loke_rt_err_flush();
	loke_rt_v1_panic_trace();

	/* Newest first, as returns would. `-panic=abort` pushes no frames. */
	for (loke_rt_frame_v1 *frame = frames; frame != 0; frame = frame->previous) {
		if (frame->cleanup != 0) {
			frame->cleanup(frame->context);
		}
	}

	/* design.md "What the unwind runs, and what it does not": no static or
	 * thread-local value is dropped. */
	loke_rt_v1_abort("panicked");
}
