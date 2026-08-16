/* Panic, logical unwinding, and thread state (m6a-plan decision "Logical panic
 * unwind").
 *
 * Loke has no `recover`, so a panic never resumes and the runtime never has to
 * unwind the native stack. It only has to *run* each active Loke frame's live
 * cleanup before the process stops — and every one of those frames, together
 * with its local storage, is still live while this code runs, because the
 * panicking call is still on the stack below them.
 *
 * That is why a frame is an opaque `{previous, cleanup, context}` record the
 * compiler pushes, and why the walk is a linked-list traversal rather than a
 * Windows C++/SEH personality routine.
 */
#include "loke_rt.h"

#include <stdio.h>

/* One per thread. A panic terminates the whole process, so nothing here has to
 * be shared between threads. */
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
		/* Clear first: a cleanup panic terminates without recursively detaching. */
		attached = 0;
		loke_rt_v1_program_tls_cleanup();
	}
}

void loke_rt_v1_frame_push(loke_rt_frame_v1 *frame, loke_rt_cleanup_v1 cleanup, void *context) {
	frame->previous = frames;
	frame->cleanup = cleanup;
	frame->context = context;
	frames = frame;
}

/* Takes the frame it is undoing rather than popping blindly: a procedure that
 * never registered an action never pushed, and its zeroed record must leave the
 * caller's frame alone. */
void loke_rt_v1_frame_pop(loke_rt_frame_v1 *frame) {
	if (frames == frame) {
		frames = frame->previous;
	}
}

void loke_rt_v1_panic(const char *message) {
	/* design.md "Panic during unwinding": a panic raised by a `drop` hook or a
	 * deferred statement aborts immediately. There is no defined order for two
	 * interleaved unwinds, so there is no attempt at one. */
	if (panicking) {
		loke_rt_v1_abort("panic while unwinding a panic");
	}
	panicking = 1;

	fflush(stdout);
	fputs("loke: panic: ", stderr);
	fputs(message == 0 ? "runtime failure" : message, stderr);
	fputc('\n', stderr);
	fflush(stderr);

	/* Newest frame first, exactly as a `return` leaving each of them would. Under
	 * `-panic=abort` the compiler pushes no frames at all, so this walk is empty
	 * and the panic terminates at the point of the fault. */
	for (loke_rt_frame_v1 *frame = frames; frame != 0; frame = frame->previous) {
		if (frame->cleanup != 0) {
			frame->cleanup(frame->context);
		}
	}

	/* design.md: "File-scope, `static`, and `thread_local` values are not dropped
	 * during panic termination." Nothing else runs here. */
	loke_rt_v1_abort("panicked");
}
