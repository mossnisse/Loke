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
static __declspec(thread) int32_t attached;

void loke_rt_v1_thread_attach(void) {
	frames = 0;
	panicking = 0;
	attached = 1;
}

void loke_rt_v1_thread_detach(void) {
	frames = 0;
	if (attached) {
		attached = 0; /* first, so a panic in the cleanup cannot detach again */
		loke_rt_v1_program_tls_cleanup();
	}
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
	fputs("loke: panic: ", stderr);
	fputs(message == 0 ? "runtime failure" : message, stderr);
}

void loke_rt_v1_panic_end(void) {
	fputc('\n', stderr);
	fflush(stderr);

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
