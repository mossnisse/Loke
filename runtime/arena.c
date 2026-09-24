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
#define ARENA_CONTROL_ALIGN 16u

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

static uint8_t *arena_block_bytes(loke_rt_arena_block_v1 *block) {
	return (uint8_t *)block + sizeof(loke_rt_arena_block_v1);
}

/* The bump itself. Answers NULL when this block cannot hold the request, which
 * is the caller's signal to reach for another one. */
static void *arena_bump(loke_rt_arena_block_v1 *block, uint64_t size, uint64_t align) {
	uint64_t base = (uint64_t)(uintptr_t)arena_block_bytes(block);
	uint64_t at = arena_round_up(base + block->used, align);
	uint64_t end;
	if (at == 0) {
		return 0;
	}
	end = at + size;
	if (end < at || end > base + block->size) {
		return 0;
	}
	block->used = end - base;
	return (void *)(uintptr_t)at;
}

uint64_t loke_rt_v1_arena_min_buffer(void) {
	return sizeof(loke_rt_arena_v1) + sizeof(loke_rt_arena_block_v1) + ARENA_CONTROL_ALIGN;
}

/* Lays the control block, its embedded first block header, and the usable
 * remainder out over `storage`. Shared by both constructors, because a
 * provider-backed arena's first block is exactly a fixed buffer it happens to
 * own. */
static loke_rt_arena_v1 *arena_place(
	void *storage, uint64_t size, const loke_rt_allocator_v1 *parent, uint64_t block_bytes) {
	uint64_t base = (uint64_t)(uintptr_t)storage;
	uint64_t control_at = arena_round_up(base, ARENA_CONTROL_ALIGN);
	uint64_t header_at, usable_at;
	loke_rt_arena_v1 *arena;
	loke_rt_arena_block_v1 *block;

	if (control_at == 0 || control_at < base) {
		return 0;
	}
	header_at = arena_round_up(control_at + sizeof(loke_rt_arena_v1), ARENA_CONTROL_ALIGN);
	if (header_at == 0) {
		return 0;
	}
	usable_at = header_at + sizeof(loke_rt_arena_block_v1);
	if (usable_at < header_at || usable_at > base + size) {
		return 0;
	}

	arena = (loke_rt_arena_v1 *)(uintptr_t)control_at;
	block = (loke_rt_arena_block_v1 *)(uintptr_t)header_at;
	block->next = 0;
	block->size = base + size - usable_at;
	block->used = 0;
	block->owned = 0; /* it lives in the control allocation, so drop releases it */

	memset(&arena->record, 0, sizeof(arena->record));
	arena->record.abi_version = LOKE_RT_ABI_VERSION;
	arena->record.record_size = (uint32_t)sizeof(loke_rt_allocator_v1);
	arena->record.state = arena;
	/* design.md: "a provider whose allocations all belong to one resettable
	 * region points this at itself". */
	arena->record.region = arena;
	arena->record.ops = 0; /* filled in by the caller, which owns the ops table */
	arena->record.on_failure = LOKE_RT_ON_FAILURE_PANIC;
	arena->parent = parent;
	arena->blocks = block;
	arena->first = block;
	arena->block_bytes = block_bytes;
	arena->control_bytes = size;
	return arena;
}

static void arena_release_blocks(loke_rt_arena_v1 *arena, int32_t keep_first) {
	loke_rt_arena_block_v1 *block = arena->blocks;
	while (block != 0) {
		loke_rt_arena_block_v1 *next = block->next;
		if (block->owned && arena->parent != 0) {
			loke_rt_v1_free(
				arena->parent, block, sizeof(loke_rt_arena_block_v1) + block->size, ARENA_CONTROL_ALIGN);
		}
		block = next;
	}
	arena->blocks = keep_first ? arena->first : 0;
	if (keep_first) {
		arena->first->next = 0;
		arena->first->used = 0;
	}
}

/* One more block from the parent, at least large enough for `size`/`align`. The
 * request doubles until it is comfortable, so a long-lived arena stops asking. */
static int32_t arena_grow(loke_rt_arena_v1 *arena, uint64_t size, uint64_t align) {
	uint64_t want = arena->block_bytes;
	uint64_t needed = size + align + sizeof(loke_rt_arena_block_v1);
	void *storage;
	loke_rt_arena_block_v1 *block;

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
	storage = loke_rt_v1_alloc(arena->parent, want, ARENA_CONTROL_ALIGN);
	if (storage == 0) {
		return 0;
	}
	block = (loke_rt_arena_block_v1 *)storage;
	block->next = arena->blocks;
	block->size = want - sizeof(loke_rt_arena_block_v1);
	block->used = 0;
	block->owned = 1;
	arena->blocks = block;
	arena->block_bytes = want;
	return 1;
}

static void *arena_alloc(void *state, uint64_t size, uint64_t align) {
	loke_rt_arena_v1 *arena = (loke_rt_arena_v1 *)state;
	void *out;
	if (arena == 0) {
		return 0;
	}
	if (size == 0) {
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
	uint64_t base;
	if (ptr == 0 || arena->blocks == 0) {
		return 0;
	}
	base = (uint64_t)(uintptr_t)arena_block_bytes(arena->blocks);
	return (uint64_t)(uintptr_t)ptr + old_size == base + arena->blocks->used;
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
		uint64_t base = (uint64_t)(uintptr_t)arena_block_bytes(arena->blocks);
		uint64_t end = (uint64_t)(uintptr_t)ptr + new_size;
		if (end >= (uint64_t)(uintptr_t)ptr && end <= base + arena->blocks->size) {
			arena->blocks->used = end - base;
			return ptr;
		}
	}
	out = arena_alloc(state, new_size, align);
	if (out == 0) {
		return 0; /* design.md: the old allocation is still live and unchanged */
	}
	memcpy(out, ptr, (size_t)(old_size < new_size ? old_size : new_size));
	return out;
}

/* Only the top allocation is recoverable. Anything else waits for the reset,
 * which is the whole bargain a region offers.
 * ponytail: no free list. Add one if a measured workload frees out of order
 * often enough for the wasted bytes to matter. */
static void arena_free(void *state, void *ptr, uint64_t size, uint64_t align) {
	loke_rt_arena_v1 *arena = (loke_rt_arena_v1 *)state;
	(void)align;
	if (arena == 0 || ptr == 0) {
		return;
	}
	if (arena_is_top(arena, ptr, size)) {
		arena->blocks->used -= size;
	}
}

/* design.md: `free_all` "may end every allocation root in that allocator
 * region", and the region stays usable afterwards -- which is what makes a
 * successful reset permit later reuse. */
static int32_t arena_reset(void *state) {
	loke_rt_arena_v1 *arena = (loke_rt_arena_v1 *)state;
	if (arena == 0) {
		return 0;
	}
	arena_release_blocks(arena, 1);
	return 1;
}

static const loke_rt_allocator_ops_v1 loke_rt_arena_ops = {
	arena_alloc,
	arena_resize,
	arena_free,
	arena_reset,
};

loke_rt_arena_v1 *loke_rt_v1_arena_open(const loke_rt_allocator_v1 *parent) {
	void *storage;
	loke_rt_arena_v1 *arena;
	if (parent == 0) {
		parent = loke_rt_v1_selected_allocator();
	}
	storage = loke_rt_v1_alloc(parent, ARENA_DEFAULT_BLOCK, ARENA_CONTROL_ALIGN);
	if (storage == 0) {
		return 0;
	}
	arena = arena_place(storage, ARENA_DEFAULT_BLOCK, parent, ARENA_DEFAULT_BLOCK);
	if (arena == 0) {
		loke_rt_v1_free(parent, storage, ARENA_DEFAULT_BLOCK, ARENA_CONTROL_ALIGN);
		return 0;
	}
	arena->record.ops = &loke_rt_arena_ops;
	return arena;
}

loke_rt_arena_v1 *loke_rt_v1_arena_open_fixed(void *buffer, int64_t size) {
	loke_rt_arena_v1 *arena;
	if (buffer == 0 || size < 0 || (uint64_t)size < loke_rt_v1_arena_min_buffer()) {
		/* A buffer too small to hold a control block is a caller error, not an
		 * allocation failure: no policy could make it succeed. */
		loke_rt_v1_container_fault("this buffer is too small to host an arena");
	}
	arena = arena_place(buffer, (uint64_t)size, 0, 0);
	if (arena == 0) {
		loke_rt_v1_container_fault("this buffer is too small to host an arena");
	}
	arena->record.ops = &loke_rt_arena_ops;
	return arena;
}

void loke_rt_v1_arena_drop(loke_rt_arena_v1 *arena) {
	const loke_rt_allocator_v1 *parent;
	if (arena == 0) {
		return; /* the zero or moved-from value */
	}
	parent = arena->parent;
	arena_release_blocks(arena, 0);
	if (parent != 0) {
		loke_rt_v1_free(parent, arena, arena->control_bytes, ARENA_CONTROL_ALIGN);
	}
}

/* design.md "Allocators": the zero `Arena` or `Scratch` owns an empty region.
 * Allocating from it fails and resetting it does nothing, so its handle is one
 * shared record rather than nil, which would mean the default provider. */
static void *empty_alloc(void *state, uint64_t size, uint64_t align) {
	(void)state, (void)size, (void)align;
	return 0;
}

static void *empty_resize(void *state, void *ptr, uint64_t old_size, uint64_t new_size, uint64_t align) {
	(void)state, (void)ptr, (void)old_size, (void)new_size, (void)align;
	return 0;
}

static void empty_free(void *state, void *ptr, uint64_t size, uint64_t align) {
	(void)state, (void)ptr, (void)size, (void)align;
}

static int32_t empty_reset(void *state) {
	(void)state;
	return 1;
}

static const loke_rt_allocator_ops_v1 loke_rt_empty_ops = {
	empty_alloc,
	empty_resize,
	empty_free,
	empty_reset,
};

static const loke_rt_allocator_v1 loke_rt_empty_region = {
	LOKE_RT_ABI_VERSION,
	(uint32_t)sizeof(loke_rt_allocator_v1),
	0,
	(void *)&loke_rt_empty_region,
	&loke_rt_empty_ops,
	LOKE_RT_ON_FAILURE_PANIC,
	0,
};

const loke_rt_allocator_v1 *loke_rt_v1_arena_allocator(loke_rt_arena_v1 *arena) {
	return arena == 0 ? &loke_rt_empty_region : &arena->record;
}
