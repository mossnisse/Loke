/* Unrecoverable runtime failure: report and terminate, with no strategy and no
 * cleanup. It is the last step of every panic, and the whole of an allocator
 * `.Trap`, a panic raised while unwinding, and a fault in the runtime's own
 * records (an allocator ABI mismatch, a failed provider factory).
 */
#include "loke_rt.h"

#include <stdio.h>
#include <stdlib.h>

void loke_rt_v1_abort(const char *what) {
	/* Output written before the failure is part of what a test observes, and
	 * `_Exit` deliberately does not flush. */
	fflush(stdout);
	fputs("loke: ", stderr);
	fputs(what == 0 ? "runtime failure" : what, stderr);
	fputc('\n', stderr);
	fflush(stderr);
	_Exit(3);
}
