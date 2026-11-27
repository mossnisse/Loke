/* Local allocator regions: `mem.Arena` and `mem.Scratch` (m6b-plan step 5).
 *
 * design.md "Allocator regions and region provenance": "Allocator values have a
 * region identity in addition to their allocation procedures and failure
 * policy. Copying an allocator value preserves that identity". Here the identity
 * *is* the control block's address, and the control block never moves -- a Loke
 * `Arena` value is one pointer to it. So moving the owner, copying the handle,
 * and passing the handle through a call all preserve the region trivially.
 *
 * The allocation strategy is a bump pointer over a chain of blocks. Individual
 * `free` is a no-op except for the top allocation, which is worth the four lines
 * because a growing container reallocating in place is the common case.
 */
#include "loke_rt.h"

#include <string.h>

#define ARENA_DEFAULT_BLOCK 4096u
/* Growth doubles a block's size up to this; a larger request still gets a block
 * large enough for it. */
#define ARENA_MAX_GROWN_BLOCK (1u << 20)
#define ARENA_CONTROL_ALIGN 16u

/* A block's bytes run from just past its header to `limit`; `cursor` is the
 * next free one. Both are addresses, so a bump compares against `limit`
 * directly. */
typedef struct arena_block {
	struct arena_block *next;
	uintptr_t cursor;
	uintptr_t limit;
} arena_block;

/* A fixed-buffer arena has `parent == NULL` and cannot grow past the buffer it
 * was given; a provider-backed one asks its parent for another block. */
struct loke_rt_arena_v1 {
	/* First, so `&arena->record` is the handle and the two addresses coincide. */
	loke_rt_allocator_v1 record;
	const loke_rt_allocator_v1 *parent;
	arena_block *blocks; /* newest first, ending at `first` */
	/* The block whose bytes follow this record. A reset keeps it, which is what
	 * makes a reset *reusable*; for a provider-backed arena it shares the one
	 * `ARENA_DEFAULT_BLOCK` allocation with the record. */
	arena_block first;
};

LOKE_RT_STATIC_ASSERT(
	sizeof(loke_rt_arena_v1) + ARENA_CONTROL_ALIGN <= ARENA_DEFAULT_BLOCK, arena_control_fits);

static uint64_t arena_align(uint64_t align) {
	return align == 0 ? 1 : align;
}

/* `value` rounded up to a multiple of `align`, or 0 when that overflows. */
static uint64_t arena_round_up(uint64_t value, uint64_t align) {
	uint64_t slack = value + (align - 1);
	if (slack < value) {
		return 0;
	}
	return slack & ~(align - 1);
}

/* The bump itself. Answers NULL when this block cannot hold the request, which
 * is the caller's signal to reach for another one. */
static void *arena_bump(arena_block *block, uint64_t size, uint64_t align) {
	uint64_t at = arena_round_up(block->cursor, align);
	uint64_t end = at + size;
	if (at == 0 || end < at || end > block->limit) {
		return 0;
	}
	block->cursor = end;
	return (void *)(uintptr_t)at;
}

uint64_t loke_rt_v1_arena_min_buffer(void) {
	return sizeof(loke_rt_arena_v1) + ARENA_CONTROL_ALIGN;
}

/* Returns every block newer than `first` to the parent and rewinds `first`.
 * A fixed-buffer arena never has any, since it cannot grow. */
static void arena_rewind(loke_rt_arena_v1 *arena) {
	while (arena->blocks != &arena->first) {
		arena_block *block = arena->blocks;
		arena->blocks = block->next;
		loke_rt_v1_free(arena->parent, block, block->limit - (uintptr_t)block, ARENA_CONTROL_ALIGN);
	}
	arena->first.cursor = (uintptr_t)(arena + 1);
}

/* One more block from the parent, at least large enough for `size`/`align`. The
 * request is twice the newest block's size, up to `ARENA_MAX_GROWN_BLOCK`, so a
 * growing arena asks its parent ever more rarely; a larger request doubles until
 * it fits. A reset rewinds to `first` and so starts small again. */
static int32_t arena_grow(loke_rt_arena_v1 *arena, uint64_t size, uint64_t align) {
	arena_block *newest = arena->blocks;
	uint64_t newest_size = newest == &arena->first ? ARENA_DEFAULT_BLOCK : newest->limit - (uintptr_t)newest;
	uint64_t want = newest_size >= ARENA_MAX_GROWN_BLOCK / 2 ? ARENA_MAX_GROWN_BLOCK : newest_size * 2;
	uint64_t needed = size + align + sizeof(arena_block);
	arena_block *block;

	if (arena->parent == 0) {
		return 0; /* a fixed buffer is exactly as large as the caller made it */
	}
	if (needed < size) {
		return 0;
	}
	while (want < needed) {
		uint64_t doubled = want * 2;
		if (doubled <= want) {
			return 0;
		}
		want = doubled;
	}
	block = (arena_block *)loke_rt_v1_alloc(arena->parent, want, ARENA_CONTROL_ALIGN);
	if (block == 0) {
		return 0;
	}
	block->next = newest;
	block->cursor = (uintptr_t)(block + 1);
	block->limit = (uintptr_t)block + want;
	arena->blocks = block;
	return 1;
}

/* Every operation accepts a NULL state: that is the zero value's empty region,
 * which holds no memory and has nothing to release. */
static void *arena_alloc(void *state, uint64_t size, uint64_t align) {
	loke_rt_arena_v1 *arena = (loke_rt_arena_v1 *)state;
	void *out;
	if (arena == 0 || size == 0) {
		return 0;
	}
	align = arena_align(align);
	out = arena_bump(arena->blocks, size, align);
	if (out != 0) {
		return out;
	}
	if (!arena_grow(arena, size, align)) {
		return 0;
	}
	return arena_bump(arena->blocks, size, align);
}

/* Whether `ptr` is the newest allocation of the newest block, which is the case
 * a growing container hits every time it is the only thing allocating. */
static int32_t arena_is_top(loke_rt_arena_v1 *arena, void *ptr, uint64_t old_size) {
	return ptr != 0 && (uintptr_t)ptr + old_size == arena->blocks->cursor;
}

static void *arena_resize(void *state, void *ptr, uint64_t old_size, uint64_t new_size, uint64_t align) {
	loke_rt_arena_v1 *arena = (loke_rt_arena_v1 *)state;
	void *out;
	if (arena == 0 || new_size == 0) {
		return 0;
	}
	if (ptr == 0) {
		return arena_alloc(state, new_size, align);
	}
	if (arena_is_top(arena, ptr, old_size)) {
		uintptr_t end = (uintptr_t)ptr + new_size;
		if (end >= (uintptr_t)ptr && end <= arena->blocks->limit) {
			arena->blocks->cursor = end;
			return ptr;
		}
	}
	/* A shrink below the top keeps its block: copying it out would spend region
	 * bytes to release none, and fail outright in a full fixed buffer. */
	if (new_size <= old_size) {
		return ptr;
	}
	out = arena_alloc(state, new_size, align);
	if (out == 0) {
		return 0; /* design.md: the old allocation is still live and unchanged */
	}
	memcpy(out, ptr, (size_t)old_size);
	return out;
}

/* Only the top allocation is recoverable. Anything else waits for the reset,
 * which is the whole bargain a region offers.
 * ponytail: no free list. Add one if a measured workload frees out of order
 * often enough for the wasted bytes to matter. */
static void arena_free(void *state, void *ptr, uint64_t size, uint64_t align) {
	loke_rt_arena_v1 *arena = (loke_rt_arena_v1 *)state;
	(void)align;
	if (arena != 0 && arena_is_top(arena, ptr, size)) {
		arena->blocks->cursor -= size;
	}
}

/* design.md: `free_all` "may end every allocation root in that allocator
 * region", and the region stays usable afterwards -- which is what makes a
 * successful reset permit later reuse. */
static int32_t arena_reset(void *state) {
	if (state != 0) {
		arena_rewind((loke_rt_arena_v1 *)state);
	}
	return 1;
}

static const loke_rt_allocator_ops_v1 loke_rt_arena_ops = {
	arena_alloc,
	arena_resize,
	arena_free,
	arena_reset,
};

/* Lays the control record and its embedded first block over `storage`, which
 * both constructors have already checked is large enough. A provider-backed
 * arena's first block is exactly a fixed buffer it happens to own. */
static loke_rt_arena_v1 *arena_place(
	void *storage, uint64_t size, const loke_rt_allocator_v1 *parent, int64_t policy) {
	loke_rt_arena_v1 *arena =
		(loke_rt_arena_v1 *)(uintptr_t)arena_round_up((uintptr_t)storage, ARENA_CONTROL_ALIGN);
	*arena = (loke_rt_arena_v1){
		/* design.md: "a provider whose allocations all belong to one resettable
		 * region points this at itself". */
		.record = {LOKE_RT_ABI_VERSION, (uint32_t)sizeof(loke_rt_allocator_v1), arena, arena,
			&loke_rt_arena_ops, (uint32_t)policy, 0},
		.parent = parent,
		.blocks = &arena->first,
		.first = {0, (uintptr_t)(arena + 1), (uintptr_t)storage + size},
	};
	return arena;
}

loke_rt_arena_v1 *loke_rt_v1_arena_open(const loke_rt_allocator_v1 *parent, int64_t policy) {
	void *storage;
	if (parent == 0) {
		parent = loke_rt_v1_selected_allocator();
	}
	storage = loke_rt_v1_alloc(parent, ARENA_DEFAULT_BLOCK, ARENA_CONTROL_ALIGN);
	return storage == 0 ? 0 : arena_place(storage, ARENA_DEFAULT_BLOCK, parent, policy);
}

loke_rt_arena_v1 *loke_rt_v1_arena_open_fixed(void *buffer, int64_t size, int64_t policy) {
	if (buffer == 0 || size < 0 || (uint64_t)size < loke_rt_v1_arena_min_buffer()) {
		/* A buffer too small to hold a control block is a caller error, not an
		 * allocation failure: no policy could make it succeed. */
		loke_rt_v1_container_fault("this buffer is too small to host an arena");
	}
	return arena_place(buffer, (uint64_t)size, 0, policy);
}

void loke_rt_v1_arena_drop(loke_rt_arena_v1 *arena) {
	if (arena == 0) {
		return; /* the zero or moved-from value */
	}
	arena_rewind(arena);
	if (arena->parent != 0) {
		loke_rt_v1_free(arena->parent, arena, ARENA_DEFAULT_BLOCK, ARENA_CONTROL_ALIGN);
	}
}

/* design.md "Allocators": the zero `Arena` or `Scratch` owns an empty region.
 * Allocating from it fails and resetting it does nothing, so its handle is one
 * shared record with a NULL state rather than nil, which would mean the default
 * provider. */
static const loke_rt_allocator_v1 loke_rt_empty_region = {
	LOKE_RT_ABI_VERSION,
	(uint32_t)sizeof(loke_rt_allocator_v1),
	0,
	(void *)&loke_rt_empty_region,
	&loke_rt_arena_ops,
	LOKE_RT_ON_FAILURE_PANIC,
	0,
};

const loke_rt_allocator_v1 *loke_rt_v1_arena_allocator(loke_rt_arena_v1 *arena) {
	return arena == 0 ? &loke_rt_empty_region : &arena->record;
}

/* How an allocation-failure report names this handle, or NULL when it is not
 * an arena's. */
const char *loke_rt_arena_name(const loke_rt_allocator_v1 *a) {
	if (a == &loke_rt_empty_region) {
		return "a zero-value arena, which holds no memory";
	}
	if (a->ops != &loke_rt_arena_ops) {
		return 0;
	}
	return ((const loke_rt_arena_v1 *)a->state)->parent == 0 ? "a fixed-buffer arena" : "an arena";
}
