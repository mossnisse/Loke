/* The C host owns process entry (m7-plan step 5): it attaches its thread to the
 * Loke runtime, calls the exported procedures, and detaches. No Loke `main` or
 * `wmain` exists in the linked object; this `main` is the only entry.
 *
 * No headers: the object build's whole point is that a foreign consumer needs
 * only these declarations and the seed runtime. */
int widget_add(int a, int b);
int widget_answer(void);
extern int widget_counter;

void loke_rt_v1_thread_attach(void);
void loke_rt_v1_thread_detach(void);

int main(void) {
	int status;
	loke_rt_v1_thread_attach();
	status = widget_add(3, 4) + widget_answer() + widget_counter;
	widget_counter = 1;
	status += widget_counter;
	loke_rt_v1_thread_detach();
	/* 7 + 42 + 7 + 1 */
	return status == 57 ? 0 : status;
}
