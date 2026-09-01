/* The C host of an object build that selects providers (design.md "Build
 * modes", m8-plan step 3). Nothing calls the initializer automatically: this
 * host calls it once, after attaching a thread and before using any export.
 *
 * The second call proves the documented no-op: a host that cannot tell whether
 * it has already initialized may ask again.
 *
 * No headers, for the same reason `host.c` uses none: an object build's whole
 * point is that a foreign consumer needs only these declarations. */
void loke_rt_v1_thread_attach(void);
void loke_rt_v1_thread_detach(void);
void loke_rt_v1_program_init(void);

int hostlib_report(void);

int main(void) {
	int status;
	loke_rt_v1_thread_attach();
	loke_rt_v1_program_init();
	loke_rt_v1_program_init();
	status = hostlib_report();
	loke_rt_v1_thread_detach();
	return status;
}
