/* The Loke seed runtime, ABI version 1.
 *
 * This is an implementation component of the compiler, not a Loke package: it
 * is compiled by the same `clang` invocation that turns the generated `.ll`
 * into an executable, and it knows nothing about Loke package discovery.
 *
 * Every exported symbol begins `loke_rt_v1_`. The version is part of the name
 * on purpose — a generated module and a stale runtime directory then fail to
 * link instead of agreeing on a record that has silently changed shape.
 *
 * The public Loke-side declarations of these layouts live in `base/runtime` and
 * `core/mem`; the two sides are verified against each other by the compiler's
 * layout assertions and by this file's static assertions.
 */
#ifndef LOKE_RT_H
#define LOKE_RT_H

#include <stdint.h>

#define LOKE_RT_ABI_VERSION 1u

#if defined(__cplusplus)
extern "C" {
#endif

/* ------------------------------------------------------------ assertions -- */

#define LOKE_RT_STATIC_ASSERT(cond, tag) \
	typedef char loke_rt_static_assert_##tag[(cond) ? 1 : -1]

/* -------------------------------------------------------------- allocator -- */

/* design.md "Allocators": failure policy is a property of the allocator value,
 * not of the call site. `.Panic` runs the program panic strategy; `.Trap`
 * terminates immediately and bypasses cleanup under either strategy. */
enum {
	LOKE_RT_ON_FAILURE_PANIC = 0,
	LOKE_RT_ON_FAILURE_TRAP = 1
};

/* The four callbacks a provider supplies. `resize` returns NULL on failure and
 * must leave the old allocation live and unchanged; `reset` returns 0 when the
 * provider has no region to end. */
typedef struct loke_rt_allocator_ops_v1 {
	void *(*alloc)(void *state, uint64_t size, uint64_t align);
	void *(*resize)(void *state, void *ptr, uint64_t old_size, uint64_t new_size, uint64_t align);
	void (*free)(void *state, void *ptr, uint64_t size, uint64_t align);
	int32_t (*reset)(void *state);
} loke_rt_allocator_ops_v1;

/* A Loke `Allocator` value is a pointer to one of these and nothing else, so
 * copying a handle copies the pointer and therefore preserves `region`: region
 * identity is the record address chain, never a per-copy tag.
 *
 * `abi_version` and `record_size` lead so a later runtime can grow the record
 * without changing what an older generated module reads. */
typedef struct loke_rt_allocator_v1 {
	uint32_t abi_version;
	uint32_t record_size;
	void *state;
	/* Canonical region identity. A provider whose allocations all belong to one
	 * resettable region points this at itself; the system heap has no region and
	 * leaves it NULL. */
	void *region;
	const loke_rt_allocator_ops_v1 *ops;
	uint32_t on_failure;
	uint32_t reserved;
} loke_rt_allocator_v1;

LOKE_RT_STATIC_ASSERT(sizeof(void *) == 8, pointer_is_eight_bytes);
LOKE_RT_STATIC_ASSERT(sizeof(loke_rt_allocator_v1) == 40, allocator_record_size);
LOKE_RT_STATIC_ASSERT(sizeof(loke_rt_allocator_ops_v1) == 32, allocator_ops_size);

/* The one provider M6a installs: the system heap, `.Panic`, no region. */
extern loke_rt_allocator_v1 loke_rt_v1_default_allocator;

/* Dispatch helpers. The generated module calls these rather than loading the
 * ops table itself, so the record layout has exactly one reader. */
void *loke_rt_v1_alloc(const loke_rt_allocator_v1 *a, uint64_t size, uint64_t align);
void *loke_rt_v1_alloc_zeroed(const loke_rt_allocator_v1 *a, uint64_t size, uint64_t align);
void *loke_rt_v1_resize(
	const loke_rt_allocator_v1 *a, void *ptr, uint64_t old_size, uint64_t new_size, uint64_t align);
void loke_rt_v1_free(const loke_rt_allocator_v1 *a, void *ptr, uint64_t size, uint64_t align);
/* `free_all`. A provider that answers 0 does not support ending its region,
 * which is a runtime failure, not a diagnosable one. */
void loke_rt_v1_reset(const loke_rt_allocator_v1 *a);
/* An implicit allocation that failed, dispatched by the allocator's own policy. */
void loke_rt_v1_alloc_failed(const loke_rt_allocator_v1 *a);

/* ------------------------------------------------------ panic and threads -- */

/* One generated cleanup thunk: replays the live registered actions of one Loke
 * frame, newest registration first. `context` points at that frame's own
 * registration state, which is still live storage while the panic runs. */
typedef void (*loke_rt_cleanup_v1)(void *context);

typedef struct loke_rt_frame_v1 {
	struct loke_rt_frame_v1 *previous;
	loke_rt_cleanup_v1 cleanup;
	void *context;
} loke_rt_frame_v1;

LOKE_RT_STATIC_ASSERT(sizeof(loke_rt_frame_v1) == 24, frame_record_size);

void loke_rt_v1_thread_attach(void);
void loke_rt_v1_thread_detach(void);
void loke_rt_v1_frame_push(loke_rt_frame_v1 *frame, loke_rt_cleanup_v1 cleanup, void *context);
void loke_rt_v1_frame_pop(loke_rt_frame_v1 *frame);

/* The program panic strategy. Under `-panic=abort` the compiler pushes no
 * frames, so this runs no cleanup and terminates at the point of the fault. */
void loke_rt_v1_panic(const char *message);

/* Immediate abort, bypassing every strategy: an allocator whose failure policy
 * is `.Trap`, and a panic raised while one is already unwinding. */
void loke_rt_v1_abort(const char *what);

#if defined(__cplusplus)
}
#endif

#endif /* LOKE_RT_H */
