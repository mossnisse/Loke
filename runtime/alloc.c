/* The default system-heap provider and the allocator dispatch helpers.
 *
 * design.md "Build-selected providers": the default provider is fixed at build
 * time. Source code cannot replace it; a future build option may install a
 * different implementation without changing the handle ABI, because everything
 * a caller sees is `loke_rt_allocator_v1`.
 */
#include "loke_rt.h"

#include <malloc.h>
#include <string.h>

/* Alignment is honoured exactly, so a caller asking for 32 gets 32 rather than
 * whatever the CRT's default happens to be. `_aligned_malloc` requires a
 * non-zero power of two. */
static uint64_t sane_align(uint64_t align) {
	return align == 0 ? 1 : align;
}

static void *sys_alloc(void *state, uint64_t size, uint64_t align) {
	(void)state;
	if (size == 0) {
		return 0;
	}
	return _aligned_malloc((size_t)size, (size_t)sane_align(align));
}

/* On failure the old block is untouched and still owned by the caller, which is
 * what `_aligned_realloc` already guarantees. */
static void *sys_resize(void *state, void *ptr, uint64_t old_size, uint64_t new_size, uint64_t align) {
	(void)state;
	(void)old_size;
	if (new_size == 0) {
		return 0;
	}
	if (ptr == 0) {
		return _aligned_malloc((size_t)new_size, (size_t)sane_align(align));
	}
	return _aligned_realloc(ptr, (size_t)new_size, (size_t)sane_align(align));
}

static void sys_free(void *state, void *ptr, uint64_t size, uint64_t align) {
	(void)state;
	(void)size;
	(void)align;
	_aligned_free(ptr);
}

/* The system heap has no region: individual allocations are freed one at a
 * time, and there is nothing for `free_all` to end. */
static int32_t sys_reset(void *state) {
	(void)state;
	return 0;
}

static const loke_rt_allocator_ops_v1 loke_rt_system_ops = {
	sys_alloc,
	sys_resize,
	sys_free,
	sys_reset,
};

loke_rt_allocator_v1 loke_rt_v1_default_allocator = {
	LOKE_RT_ABI_VERSION,
	(uint32_t)sizeof(loke_rt_allocator_v1),
	0, /* state */
	0, /* region: the system heap is not resettable */
	&loke_rt_system_ops,
	LOKE_RT_ON_FAILURE_PANIC,
	0,
};

/* A record from a mismatched runtime would read as a different shape, and the
 * generated module cannot check that itself. */
static void check_record(const loke_rt_allocator_v1 *a) {
	if (a == 0 || a->abi_version != LOKE_RT_ABI_VERSION ||
	    a->record_size < (uint32_t)sizeof(loke_rt_allocator_v1) || a->ops == 0) {
		loke_rt_v1_abort("allocator record does not match this runtime's ABI");
	}
}

/* ---------------------------------------------------- the selected provider --
 *
 * design.md "Build-selected providers": the build selects at most one default
 * allocator, and both generated code and this runtime have to reach the same
 * handle. The record above stays the fallback and keeps its symbol, so an
 * object built before this entry point existed still links; what a default
 * allocation *uses* is whatever is published here.
 *
 * Publication keeps the handle the factory returned rather than copying the
 * record it points at, which is what preserves the provider's identity, state,
 * and region. */
static const loke_rt_allocator_v1 *loke_rt_selected = &loke_rt_v1_default_allocator;

const loke_rt_allocator_v1 *loke_rt_v1_selected_allocator(void) {
	return loke_rt_selected;
}

void loke_rt_v1_publish_allocator(const loke_rt_allocator_v1 *a) {
	if (a == 0) {
		loke_rt_v1_abort("the selected allocator factory returned no handle");
	}
	check_record(a);
	loke_rt_selected = a;
}

/* Initialization runs before any worker thread exists, so this is a plain
 * variable rather than an atomic: design.md places concurrent initialization
 * outside the host contract, and re-entry is a program fault either way. */
enum { LOKE_RT_INIT_IDLE = 0, LOKE_RT_INIT_RUNNING = 1, LOKE_RT_INIT_DONE = 2 };

static int32_t loke_rt_init_state = LOKE_RT_INIT_IDLE;

/* 1 when the caller should run the factories, 0 when initialization is already
 * complete. A factory that re-enters initialization does not return. */
int32_t loke_rt_v1_provider_init_begin(void) {
	if (loke_rt_init_state == LOKE_RT_INIT_DONE) {
		return 0;
	}
	if (loke_rt_init_state == LOKE_RT_INIT_RUNNING) {
		loke_rt_v1_abort("provider initialization re-entered itself");
	}
	loke_rt_init_state = LOKE_RT_INIT_RUNNING;
	return 1;
}

void loke_rt_v1_provider_init_end(void) {
	loke_rt_init_state = LOKE_RT_INIT_DONE;
}

void *loke_rt_v1_alloc(const loke_rt_allocator_v1 *a, uint64_t size, uint64_t align) {
	check_record(a);
	return a->ops->alloc(a->state, size, align);
}

void *loke_rt_v1_alloc_zeroed(const loke_rt_allocator_v1 *a, uint64_t size, uint64_t align) {
	void *p = loke_rt_v1_alloc(a, size, align);
	if (p != 0) {
		memset(p, 0, (size_t)size);
	}
	return p;
}

void *loke_rt_v1_resize(
	const loke_rt_allocator_v1 *a, void *ptr, uint64_t old_size, uint64_t new_size, uint64_t align) {
	check_record(a);
	return a->ops->resize(a->state, ptr, old_size, new_size, align);
}

void loke_rt_v1_free(const loke_rt_allocator_v1 *a, void *ptr, uint64_t size, uint64_t align) {
	check_record(a);
	a->ops->free(a->state, ptr, size, align);
}

/* design.md "Allocation failure": an implicit allocation has nowhere to return
 * an error, so the *allocator's* failure policy decides. `.Panic` follows the
 * program strategy; `.Trap` terminates immediately under either strategy, which
 * is the whole meaning of "`.Panic` may unwind while `.Trap` does not". */
void loke_rt_v1_alloc_failed(const loke_rt_allocator_v1 *a) {
	if (a != 0 && a->on_failure == LOKE_RT_ON_FAILURE_TRAP) {
		loke_rt_v1_abort("allocation failed");
	}
	loke_rt_v1_panic("allocation failed");
}

/* ponytail: the abort below is unreachable from checked Loke. The only provider
 * whose `reset` answers 0 is the system heap, and the region rules reject every
 * source form that would hand it to a `free_all` -- a parameterless body may not
 * hide a reset of pre-existing storage, and `main` takes no parameters, so no
 * promise chain can start. It stays because a future provider may answer 0, and
 * because a silent no-op here would be worse than a stop. */
void loke_rt_v1_reset(const loke_rt_allocator_v1 *a) {
	check_record(a);
	if (a->ops->reset(a->state) == 0) {
		loke_rt_v1_abort("this allocator does not support free_all");
	}
}
