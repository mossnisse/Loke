/* Unrecoverable runtime failure.
 *
 * M6a step 1 has one exit: report and terminate. Step 3 adds the classified
 * program panic strategy on top, and this immediate abort stays as the `.Trap`
 * and double-panic path.
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
