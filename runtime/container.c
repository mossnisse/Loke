/* Raw storage and table mechanics for the two managed containers.
 *
 * m6b-plan decision "Container runtime boundary": textual LLVM should not
 * duplicate a hash-table implementation, while C cannot know what a concrete
 * Loke element costs to clone, drop, hash, or compare. So the split is: every
 * byte of storage bookkeeping is here, and every Loke-visible operation on an
 * element arrives as a generated thunk in `loke_rt_container_ops_v1`.
 *
 * Two invariants hold throughout:
 *
 *   - Nothing wrapped reaches a provider. Every product and sum that sizes an
 *     allocation goes through the checked helpers at the top of this file.
 *   - A failed operation leaves the container bit-for-bit unchanged. Growth
 *     keeps the old storage until the operation succeeds, and a clone that
 *     fails part-way destroys exactly the elements it built.
 */
#include "loke_rt.h"

#include <string.h>

/* compiler-architecture.md "Container fast paths": an optimized build links
 * this file as bitcode, and an operation inlined into a program reads its
 * element's size and thunks out of a constant table, so it becomes code for that
 * element. The optimizer inlines only what is small. Each hot operation is
 * therefore a `LOKE_RT_FAST_PATH` in front of a `LOKE_RT_SLOW_PATH` holding
 * everything that allocates, clones, or rebuilds, and it must answer exactly
 * what the slow path alone would. */
#if defined(__GNUC__) || defined(__clang__)
#define LOKE_RT_FAST_PATH __attribute__((always_inline))
#define LOKE_RT_SLOW_PATH __attribute__((noinline))
#else
#define LOKE_RT_FAST_PATH
#define LOKE_RT_SLOW_PATH
#endif

/* ----------------------------------------------------------- checked math -- */

int32_t loke_rt_v1_checked_add(int64_t a, int64_t b, int64_t *out) {
	if (a < 0 || b < 0 || a > INT64_MAX - b) {
		return 0;
	}
	*out = a + b;
	return 1;
}

int32_t loke_rt_v1_checked_bytes(int64_t count, uint64_t size, uint64_t *out) {
	uint64_t n;
	if (count < 0) {
		return 0;
	}
	n = (uint64_t)count;
	if (size != 0 && n > UINT64_MAX / size) {
		return 0;
	}
	*out = n * size;
	return 1;
}

static uint64_t sane_container_align(uint64_t align) {
	return align == 0 ? 1 : align;
}

/* design.md's lazy default binding: an unbound container binds a provider the
 * first time it needs one. A `via` declaration wrote its own at the declaration
 * point, so this never overrides a written policy. */
static void bind_allocator(const loke_rt_allocator_v1 **allocator) {
	if (*allocator == 0) {
		*allocator = loke_rt_v1_selected_allocator();
	}
}

static int32_t checked_round_up(uint64_t value, uint64_t align, uint64_t *out) {
	uint64_t a = sane_container_align(align);
	if (value > UINT64_MAX - (a - 1)) {
		return 0;
	}
	*out = (value + a - 1) / a * a;
	return 1;
}

/* --------------------------------------------------------------- dynamic -- */

static void *dyn_at(const loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t index) {
	return (char *)self->data + (uint64_t)index * ops->elem_size;
}

/* m6b-plan decision "Growth/table policy": geometric growth with a small
 * minimum. The exact sequence is pinned by the runtime tests and is deliberately
 * not a language guarantee. This is the capacity an operation that adds elements
 * grows to; a requested capacity is taken exactly, by `loke_rt_v1_dyn_reserve`. */
static int64_t dyn_growth_target(int64_t cap, int64_t min_capacity) {
	int64_t want = min_capacity;
	if (cap > 0) {
		int64_t doubled;
		if (loke_rt_v1_checked_add(cap, cap, &doubled) && doubled > want) {
			want = doubled;
		}
	}
	return want < 8 ? 8 : want;
}

/* The bytes behind `count` elements, for a count no larger than a capacity
 * this array already holds: every capacity is checked when it is set, so no
 * product below one can wrap. */
static uint64_t dyn_bytes(const loke_rt_container_ops_v1 *ops, int64_t count) {
	return (uint64_t)count * ops->elem_size;
}

/* Gives back storage of `cap` elements. A zero-sized element, or a capacity of
 * none, never has storage behind it. */
static void dyn_release(
	const loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, void *data, int64_t cap) {
	if (data != 0 && dyn_bytes(ops, cap) != 0) {
		loke_rt_v1_free(self->allocator, data, dyn_bytes(ops, cap), sane_container_align(ops->elem_align));
	}
}

/* Moves the storage to hold exactly `target` elements, at least the length. */
static int32_t dyn_set_capacity(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t target) {
	uint64_t new_bytes;
	void *storage;

	if (!loke_rt_v1_checked_bytes(target, ops->elem_size, &new_bytes)) {
		return 0;
	}
	/* No element left, or a zero-sized element, whose capacity never has storage
	 * behind it; `_aligned_realloc` of zero bytes would answer NULL and read as a
	 * failure. */
	if (new_bytes == 0) {
		dyn_release(self, ops, self->data, self->cap);
		self->data = 0;
		self->cap = target;
		return 1;
	}
	storage = loke_rt_v1_resize(
		self->allocator, self->data, dyn_bytes(ops, self->cap), new_bytes,
		sane_container_align(ops->elem_align));
	if (storage == 0) {
		return 0; /* the old allocation is still live and unchanged */
	}
	self->data = storage;
	self->cap = target;
	return 1;
}

/* design.md "Dynamic array container operations": a `reserve` that grows the
 * array makes its capacity exactly the one asked for. The geometric step belongs
 * to the operations that add elements; applied here it would hand a caller who
 * sized an array that already has storage up to twice what it asked for. */
int32_t loke_rt_v1_dyn_reserve(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t min_capacity) {
	if (min_capacity < 0) {
		loke_rt_v1_container_fault("a container capacity cannot be negative");
	}
	bind_allocator(&self->allocator);
	if (min_capacity <= self->cap) {
		return 1;
	}
	return dyn_set_capacity(self, ops, min_capacity);
}

/* design.md "Uninitialized capacity": a container shortens before it drops what
 * it took, last element first, so a drop hook that panics leaves the length
 * counting exactly the elements still owed a drop, and the unwind drops each
 * of them once. */
static void dyn_truncate(loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t new_len) {
	if (ops->elem_drop == 0) {
		self->len = new_len;
		return;
	}
	while (self->len > new_len) {
		self->len -= 1;
		ops->elem_drop(dyn_at(self, ops, self->len));
	}
}

/* design.md "What the unwind runs, and what it does not": the caller keeps the
 * array registered while this runs, and it shortens before each drop, as
 * `dyn_truncate` does. A panicking hook therefore leaves the length counting
 * exactly the elements still owed a drop, and the unwind's second call drops
 * each of them once and frees the storage. */
void loke_rt_v1_dyn_drop(loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops) {
	dyn_truncate(self, ops, 0);
	dyn_release(self, ops, self->data, self->cap);
	memset(self, 0, sizeof *self);
}

int32_t loke_rt_v1_dyn_clone(
	loke_rt_dynamic_v1 *out, const loke_rt_dynamic_v1 *src,
	const loke_rt_container_ops_v1 *ops, const loke_rt_allocator_v1 *a) {
	int64_t i;

	memset(out, 0, sizeof *out);
	/* m6b-plan decision "Allocator binding": an explicit clone is bound to the
	 * selected allocator even when the result is empty. */
	out->allocator = a;
	if (src->len == 0) {
		return 1;
	}
	if (!loke_rt_v1_dyn_reserve(out, ops, src->len)) {
		memset(out, 0, sizeof *out);
		out->allocator = a;
		return 0;
	}
	if (ops->elem_clone == 0) {
		if (dyn_bytes(ops, src->len) != 0) {
			memcpy(out->data, src->data, (size_t)dyn_bytes(ops, src->len));
		}
		out->len = src->len;
		return 1;
	}
	for (i = 0; i < src->len; i += 1) {
		if (!ops->elem_clone(dyn_at(out, ops, i), dyn_at(src, ops, i), a)) {
			/* The initialized prefix, and only it, is destroyed. */
			out->len = i;
			loke_rt_v1_dyn_drop(out, ops);
			out->allocator = a;
			return 0;
		}
	}
	out->len = src->len;
	return 1;
}

/* --------------------------------------------------- dynamic operations -- */


/* Growth for elements that clone through a hook, which keeps the old block
 * alive. A source slice pointing into that block has to stay readable until the
 * last clone out of it is finished, and a clone that fails puts the old block
 * back; a plain `resize` can promise neither. */
typedef struct dyn_grow_undo {
	void *old_data;
	int64_t old_cap;
	int32_t grew;
} dyn_grow_undo;

static int32_t dyn_regrow(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops,
	int64_t need, dyn_grow_undo *undo) {
	int64_t target;
	uint64_t bytes;
	void *fresh;

	undo->grew = 0;
	undo->old_data = self->data;
	undo->old_cap = self->cap;
	if (need <= self->cap) {
		return 1;
	}
	target = dyn_growth_target(self->cap, need);
	if (!loke_rt_v1_checked_bytes(target, ops->elem_size, &bytes)) {
		return 0;
	}
	if (bytes == 0) {
		self->cap = target;
		return 1;
	}
	fresh = loke_rt_v1_alloc(self->allocator, bytes, sane_container_align(ops->elem_align));
	if (fresh == 0) {
		return 0;
	}
	/* Relocation within an allocation change is a compiler-known move of
	 * initialized representations: no user hook runs. */
	if (dyn_bytes(ops, self->len) != 0) {
		memcpy(fresh, self->data, (size_t)dyn_bytes(ops, self->len));
	}
	self->data = fresh;
	self->cap = target;
	undo->grew = 1;
	return 1;
}

static void dyn_regrow_commit(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, const dyn_grow_undo *undo) {
	if (undo->grew) {
		dyn_release(self, ops, undo->old_data, undo->old_cap);
	}
}

static void dyn_regrow_rollback(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, const dyn_grow_undo *undo) {
	if (undo->grew) {
		dyn_release(self, ops, self->data, self->cap);
		self->data = undo->old_data;
		self->cap = undo->old_cap;
	}
}

/* Appends `count` elements whose clone is their bytes, to `need` in all. Only
 * the growth can fail, so it resizes the block, in place when the provider can.
 * A `src` within the live elements follows them when the block moves; every
 * write lands past them. */
static int32_t dyn_append_bytes(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops,
	const void *src, uint8_t *owned, int64_t count, int64_t need) {
	if (need > self->cap) {
		uint64_t offset = (uint64_t)((uintptr_t)src - (uintptr_t)self->data);
		int32_t inside = offset < dyn_bytes(ops, self->len);
		if (!dyn_set_capacity(self, ops, dyn_growth_target(self->cap, need))) {
			return 0;
		}
		if (inside) {
			src = (const char *)self->data + offset;
		}
	}
	if (dyn_bytes(ops, count) != 0) {
		memcpy(dyn_at(self, ops, self->len), src, (size_t)dyn_bytes(ops, count));
	}
	if (owned != 0) {
		memset(owned, 0, (size_t)count);
	}
	self->len = need;
	return 1;
}

/* Appends `count` elements, to `need` in all. An element `owned` marks moves
 * in, and its flag is cleared as it does; every other one is cloned.
 *
 * design.md "What the unwind runs, and what it does not": the length counts each
 * element as soon as it is complete, so when a clone hook panics the array's own
 * cleanup drops every element this call made or took, and the caller's cleanup
 * drops the owned elements still flagged. A clone that fails takes the new
 * elements back out, last first, by the shortening `dyn_truncate` does, gives
 * the storage back as it was, and leaves the owned elements still flagged to
 * the caller. `src` is only read, and every write lands past the live elements,
 * so it may point into them. */
static int32_t dyn_append_clones(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops,
	const void *src, uint8_t *owned, int64_t count, int64_t need) {
	dyn_grow_undo undo;
	int64_t start = self->len, i;

	if (!dyn_regrow(self, ops, need, &undo)) {
		return 0;
	}
	for (i = 0; i < count; i += 1) {
		const void *from = (const char *)src + dyn_bytes(ops, i);
		if (owned != 0 && owned[i]) {
			memcpy(dyn_at(self, ops, self->len), from, (size_t)ops->elem_size);
			owned[i] = 0;
		} else if (!ops->elem_clone(dyn_at(self, ops, self->len), from, self->allocator)) {
			dyn_truncate(self, ops, start);
			dyn_regrow_rollback(self, ops, &undo);
			return 0;
		}
		self->len += 1;
	}
	dyn_regrow_commit(self, ops, &undo);
	return 1;
}

/* Binds the provider and appends `count` elements from `src`, which may point
 * into the array's own elements. A failure leaves the array as it was. */
static int32_t dyn_grow_fill(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops,
	const void *src, uint8_t *owned, int64_t count) {
	int64_t need;

	if (count == 0) {
		return 1;
	}
	bind_allocator(&self->allocator);
	if (!loke_rt_v1_checked_add(self->len, count, &need)) {
		return 0;
	}
	return ops->elem_clone == 0
		? dyn_append_bytes(self, ops, src, owned, count, need)
		: dyn_append_clones(self, ops, src, owned, count, need);
}

/* One element whose clone is its bytes, into spare capacity of an array that
 * already has its provider: the general append below would bind nothing, grow
 * nothing, and make this one copy. */
LOKE_RT_FAST_PATH int32_t loke_rt_v1_dyn_append(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, const void *src, int64_t count) {
	if (count == 1 && ops->elem_clone == 0 && self->len < self->cap && self->allocator != 0) {
		/* A zero-sized element has capacity and no storage to copy into. */
		if (ops->elem_size != 0) {
			memcpy(dyn_at(self, ops, self->len), src, (size_t)ops->elem_size);
		}
		self->len += 1;
		return 1;
	}
	return loke_rt_v1_dyn_append_owned(self, ops, src, 0, count);
}

LOKE_RT_SLOW_PATH int32_t loke_rt_v1_dyn_append_owned(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops,
	const void *src, uint8_t *owned, int64_t count) {
	if (count < 0) {
		loke_rt_v1_container_fault("a container append count cannot be negative");
	}
	return dyn_grow_fill(self, ops, src, owned, count);
}

/* The element is appended first, by the path `append` takes, so none is out of
 * place while a clone hook runs. Only then does it wait in `slot` while the tail
 * shifts up past the gap it fills. */
int32_t loke_rt_v1_dyn_insert(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t index, void *slot) {
	int64_t last;

	if (index < 0 || index > self->len) {
		loke_rt_v1_container_fault("this insert index is out of range");
	}
	if (!dyn_grow_fill(self, ops, slot, 0, 1)) {
		return 0;
	}
	last = self->len - 1;
	if (index < last && ops->elem_size != 0) {
		memcpy(slot, dyn_at(self, ops, last), (size_t)ops->elem_size);
		memmove(dyn_at(self, ops, index + 1), dyn_at(self, ops, index), (size_t)dyn_bytes(ops, last - index));
		memcpy(dyn_at(self, ops, index), slot, (size_t)ops->elem_size);
	}
	return 1;
}

int32_t loke_rt_v1_dyn_pop(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, void *out) {
	if (self->len == 0) {
		memset(out, 0, (size_t)ops->elem_size);
		return 0;
	}
	self->len -= 1;
	/* The element moves to the result: it is neither cloned nor dropped. */
	memcpy(out, dyn_at(self, ops, self->len), (size_t)ops->elem_size);
	return 1;
}

void loke_rt_v1_dyn_remove(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops,
	int64_t index, void *out, int32_t unordered) {
	if (index < 0 || index >= self->len) {
		loke_rt_v1_container_fault("this removal index is out of range");
	}
	memcpy(out, dyn_at(self, ops, index), (size_t)ops->elem_size);
	self->len -= 1;
	if (index == self->len) {
		return;
	}
	if (unordered) {
		memcpy(dyn_at(self, ops, index), dyn_at(self, ops, self->len), (size_t)ops->elem_size);
		return;
	}
	if (ops->elem_size != 0) {
		memmove(dyn_at(self, ops, index), dyn_at(self, ops, index + 1), (size_t)dyn_bytes(ops, self->len - index));
	}
}

void loke_rt_v1_dyn_clear(loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops) {
	dyn_truncate(self, ops, 0);
}

int32_t loke_rt_v1_dyn_resize(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t new_len) {
	if (new_len < 0) {
		loke_rt_v1_container_fault("a container length cannot be negative");
	}
	if (new_len < self->len) {
		dyn_truncate(self, ops, new_len);
		return 1;
	}
	if (new_len == self->len) {
		return 1;
	}
	bind_allocator(&self->allocator);
	/* A resize adds elements, so it grows as `append` does: lengthening an array
	 * one element at a time stays linear. */
	if (new_len > self->cap && !dyn_set_capacity(self, ops, dyn_growth_target(self->cap, new_len))) {
		return 0;
	}
	/* Every Loke zero value is all-zero bits, so the new tail is one memset and
	 * the drop of an untouched element is the no-op every hook already handles. */
	if (ops->elem_size != 0) {
		memset(dyn_at(self, ops, self->len), 0, (size_t)dyn_bytes(ops, new_len - self->len));
	}
	self->len = new_len;
	return 1;
}

int32_t loke_rt_v1_dyn_shrink(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t min_capacity) {
	int64_t target = self->len < min_capacity ? min_capacity : self->len;

	if (min_capacity < 0) {
		loke_rt_v1_container_fault("a container capacity cannot be negative");
	}
	if (target >= self->cap) {
		return 1;
	}
	return dyn_set_capacity(self, ops, target);
}

/* ------------------------------------------------------------------- map -- */

static uint8_t *map_controls(const loke_rt_map_table_v1 *t) {
	return (uint8_t *)(t + 1);
}

static void *map_key_at(const loke_rt_map_table_v1 *t, const loke_rt_container_ops_v1 *ops, int64_t slot) {
	return (char *)t + t->keys_offset + (uint64_t)slot * ops->key_size;
}

static void *map_value_at(const loke_rt_map_table_v1 *t, const loke_rt_container_ops_v1 *ops, int64_t slot) {
	return (char *)t + t->values_offset + (uint64_t)slot * ops->elem_size;
}

/* SplitMix64's finalizer: every input bit reaches every output bit. */
static uint64_t map_mix(uint64_t x) {
	x ^= x >> 30;
	x *= 0xbf58476d1ce4e5b9u;
	x ^= x >> 27;
	x *= 0x94d049bb133111ebu;
	x ^= x >> 31;
	return x;
}

/* m6b-plan decision "Map algorithm and coherence": an opaque per-table seed, so
 * iteration order is unspecified and no program can come to depend on it. The
 * mix is deterministic within one process and derived from the table's own
 * address and a running counter. */
static uint64_t map_next_seed(const void *block) {
	static uint64_t counter = 0x9e3779b97f4a7c15u;
	/* Map construction is allowed on independent threads. Reserve a unique
	 * counter value atomically; relaxed ordering is sufficient because the value
	 * is entropy, not synchronization. These are the same clang atomics used by
	 * the reference-counted text runtime. */
	return map_mix(__atomic_fetch_add(
		&counter, 0x9e3779b97f4a7c15u, __ATOMIC_RELAXED
	) + (uint64_t)(uintptr_t)block);
}

/* The slot a probe for `key` starts at. A key's `hash` need not spread its bits:
 * the built-in integer hash is one FNV-1a multiply, which carries bits only
 * upward, so keys differing only in their high bits, as small floats' bit
 * patterns do, hash alike in every low bit. The mix brings every bit of the hash
 * into the bits the mask keeps. */
LOKE_RT_FAST_PATH static uint64_t map_home(
	const loke_rt_map_table_v1 *t, const loke_rt_container_ops_v1 *ops, const void *key, uint64_t mask) {
	return map_mix(ops->key_hash(key, t->seed)) & mask;
}

/* The first slot from `key`'s home that holds no entry. Only for a table with
 * no tombstones, as a rebuild is: there that slot is where `key` belongs. */
static uint64_t map_first_free(
	const loke_rt_map_table_v1 *t, const loke_rt_container_ops_v1 *ops, const void *key) {
	uint64_t mask = (uint64_t)t->slot_count - 1;
	uint64_t index = map_home(t, ops, key, mask);
	const uint8_t *controls = map_controls(t);
	while (controls[index] == LOKE_RT_MAP_OCCUPIED) {
		index = (index + 1) & mask;
	}
	return index;
}

/* Maximum load: three quarters. Pinned by the runtime tests, not by the
 * language. Under linear probing a miss visits about 8 slots at that load and
 * about 32 at seven eighths, which took a miss two to three times as long
 * (comments.md "Maps stop at three quarters full"). */
static int64_t map_capacity_of(int64_t slot_count) {
	return slot_count - slot_count / 4;
}

static int32_t map_slots_for(int64_t min_capacity, int64_t *out) {
	int64_t slots = 8;
	while (map_capacity_of(slots) < min_capacity) {
		if (slots > INT64_MAX / 2) {
			return 0;
		}
		slots *= 2;
	}
	*out = slots;
	return 1;
}

/* One block: header, controls, keys, values. Every offset is checked, so a slot
 * count that cannot be described never reaches the provider. */
static int32_t map_block_shape(
	const loke_rt_container_ops_v1 *ops, int64_t slots, loke_rt_map_table_v1 *shape) {
	uint64_t cursor, bytes;
	uint64_t align = sane_container_align(ops->key_align);
	if (sane_container_align(ops->elem_align) > align) {
		align = sane_container_align(ops->elem_align);
	}
	if (align < 8) {
		align = 8; /* the header itself is eight-aligned */
	}

	cursor = sizeof(loke_rt_map_table_v1);
	if (!loke_rt_v1_checked_bytes(slots, 1, &bytes) || bytes > UINT64_MAX - cursor) {
		return 0;
	}
	cursor += bytes;

	if (!checked_round_up(cursor, ops->key_align, &cursor)) {
		return 0;
	}
	shape->keys_offset = cursor;
	if (!loke_rt_v1_checked_bytes(slots, ops->key_size, &bytes) || bytes > UINT64_MAX - cursor) {
		return 0;
	}
	cursor += bytes;

	if (!checked_round_up(cursor, ops->elem_align, &cursor)) {
		return 0;
	}
	shape->values_offset = cursor;
	if (!loke_rt_v1_checked_bytes(slots, ops->elem_size, &bytes) || bytes > UINT64_MAX - cursor) {
		return 0;
	}
	cursor += bytes;

	if (!checked_round_up(cursor, align, &shape->block_size)) {
		return 0;
	}
	shape->slot_count = slots;
	shape->tombstones = 0;
	shape->block_align = align;
	return 1;
}

static void map_free_block(const loke_rt_allocator_v1 *a, loke_rt_map_table_v1 *t) {
	loke_rt_v1_free(a, t, t->block_size, t->block_align);
}

/* A fresh table of `slots` slots holding `old`'s live entries, or NULL when it
 * cannot be laid out or allocated. `old`, if any, is left as it was: its
 * entries are only aliased until `map_replace` releases it, so a caller that
 * fails after this frees the fresh block and nothing else.
 *
 * Relocation is a compiler-known move of initialized representations: m6b-plan
 * decision "Element lifecycle" is explicit that it does not call user clone or
 * drop hooks. Only the header and controls are initialized, since a payload is
 * read only behind an occupied control byte. */
static loke_rt_map_table_v1 *map_rebuild(
	const loke_rt_allocator_v1 *a, const loke_rt_container_ops_v1 *ops,
	const loke_rt_map_table_v1 *old, int64_t slots) {
	loke_rt_map_table_v1 shape;
	loke_rt_map_table_v1 *fresh;
	if (!map_block_shape(ops, slots, &shape)) {
		return 0;
	}
	fresh = (loke_rt_map_table_v1 *)loke_rt_v1_alloc(a, shape.block_size, shape.block_align);
	if (fresh == 0) {
		return 0;
	}
	*fresh = shape;
	fresh->seed = map_next_seed(fresh);
	memset(map_controls(fresh), LOKE_RT_MAP_EMPTY, (size_t)slots);
	if (old != 0) {
		const uint8_t *controls = map_controls(old);
		int64_t slot;
		for (slot = 0; slot < old->slot_count; slot += 1) {
			if (controls[slot] == LOKE_RT_MAP_OCCUPIED) {
				const void *key = map_key_at(old, ops, slot);
				uint64_t index = map_first_free(fresh, ops, key);
				memcpy(map_key_at(fresh, ops, (int64_t)index), key, (size_t)ops->key_size);
				memcpy(map_value_at(fresh, ops, (int64_t)index), map_value_at(old, ops, slot), (size_t)ops->elem_size);
				map_controls(fresh)[index] = LOKE_RT_MAP_OCCUPIED;
			}
		}
	}
	return fresh;
}

/* Releases the bound table, whose entries `fresh` has taken over. */
static void map_replace(loke_rt_map_v1 *self, loke_rt_map_table_v1 *fresh) {
	if (self->table != 0) {
		map_free_block(self->allocator, (loke_rt_map_table_v1 *)self->table);
	}
	self->table = fresh;
	self->cap = map_capacity_of(fresh->slot_count);
}

int32_t loke_rt_v1_map_reserve(
	loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t min_capacity) {
	loke_rt_map_table_v1 *fresh;
	int64_t slots;

	if (min_capacity < 0) {
		loke_rt_v1_container_fault("a container capacity cannot be negative");
	}
	bind_allocator(&self->allocator);
	if (min_capacity <= self->cap && (self->table != 0 || min_capacity == 0)) {
		return 1;
	}
	if (!map_slots_for(min_capacity < self->len ? self->len : min_capacity, &slots)) {
		return 0;
	}
	fresh = map_rebuild(self->allocator, ops, (loke_rt_map_table_v1 *)self->table, slots);
	if (fresh == 0) {
		return 0; /* the old table is still live and unchanged */
	}
	map_replace(self, fresh);
	return 1;
}

/* Takes one entry out of the table before its hooks run, as `dyn_truncate`
 * shortens first: the slot is a tombstone that owns its value until the key's
 * hook returns, and a plain one once the value's hook starts. Whichever hook
 * panics, the slot then says exactly what is still owed, and a later drop of
 * the map finishes the entry without dropping either part twice. */
static void map_drop_entry(
	loke_rt_map_v1 *self, loke_rt_map_table_v1 *t, const loke_rt_container_ops_v1 *ops, int64_t slot) {
	uint8_t *controls = map_controls(t);
	if (controls[slot] == LOKE_RT_MAP_OCCUPIED) {
		controls[slot] = LOKE_RT_MAP_VALUE_OWED;
		t->tombstones += 1;
		self->len -= 1;
		if (ops->key_drop != 0) {
			ops->key_drop(map_key_at(t, ops, slot));
		}
	}
	if (controls[slot] == LOKE_RT_MAP_VALUE_OWED) {
		controls[slot] = LOKE_RT_MAP_TOMBSTONE;
		if (ops->elem_drop != 0) {
			ops->elem_drop(map_value_at(t, ops, slot));
		}
	}
}

/* Runs every entry's hooks; a trivial pair has none, and the caller resets the
 * table without a walk. design.md "What the unwind runs, and what it does not":
 * the caller keeps the map registered while this runs, so a panicking hook
 * leaves the entries not yet taken out to the unwind's second call. */
static void map_drop_entries(loke_rt_map_v1 *self, loke_rt_map_table_v1 *t, const loke_rt_container_ops_v1 *ops) {
	if (ops->key_drop != 0 || ops->elem_drop != 0) {
		int64_t slot;
		for (slot = 0; slot < t->slot_count; slot += 1) {
			map_drop_entry(self, t, ops, slot);
		}
	}
}

void loke_rt_v1_map_drop(loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops) {
	loke_rt_map_table_v1 *t = (loke_rt_map_table_v1 *)self->table;
	if (t != 0) {
		map_drop_entries(self, t, ops);
		map_free_block(self->allocator, t);
	}
	memset(self, 0, sizeof *self);
}

/* The whole block is copied first and each live key and value is then deepened
 * in place, so no slot moves and the clone never depends on two hashes of
 * "equal" keys agreeing. */
int32_t loke_rt_v1_map_clone(
	loke_rt_map_v1 *out, const loke_rt_map_v1 *src,
	const loke_rt_container_ops_v1 *ops, const loke_rt_allocator_v1 *a) {
	const loke_rt_map_table_v1 *source = (const loke_rt_map_table_v1 *)src->table;
	loke_rt_map_table_v1 *fresh;
	uint8_t *controls;
	int64_t slot;

	memset(out, 0, sizeof *out);
	out->allocator = a;
	if (source == 0 || src->len == 0) {
		return 1;
	}
	fresh = (loke_rt_map_table_v1 *)loke_rt_v1_alloc(a, source->block_size, source->block_align);
	if (fresh == 0) {
		return 0;
	}
	memcpy(fresh, source, (size_t)source->block_size);
	controls = map_controls(fresh);
	for (slot = 0; slot < fresh->slot_count; slot += 1) {
		if (controls[slot] != LOKE_RT_MAP_OCCUPIED) {
			/* An owed value stays the source's; the clone has only its bits. */
			if (controls[slot] == LOKE_RT_MAP_VALUE_OWED) {
				controls[slot] = LOKE_RT_MAP_TOMBSTONE;
			}
			continue;
		}
		if (ops->key_clone != 0 &&
		    !ops->key_clone(map_key_at(fresh, ops, slot), map_key_at(source, ops, slot), a)) {
			break;
		}
		if (ops->elem_clone != 0 &&
		    !ops->elem_clone(map_value_at(fresh, ops, slot), map_value_at(source, ops, slot), a)) {
			/* The key of this slot is already deepened, so it is part of the
			 * prefix that has to be destroyed. */
			if (ops->key_drop != 0) {
				ops->key_drop(map_key_at(fresh, ops, slot));
			}
			break;
		}
	}
	if (slot < fresh->slot_count) {
		/* Failure. Everything below `slot` is an independent clone; everything at
		 * or above it still aliases the source and must not be dropped. */
		int64_t done;
		for (done = 0; done < slot; done += 1) {
			if (controls[done] != LOKE_RT_MAP_OCCUPIED) {
				continue;
			}
			if (ops->key_drop != 0) {
				ops->key_drop(map_key_at(fresh, ops, done));
			}
			if (ops->elem_drop != 0) {
				ops->elem_drop(map_value_at(fresh, ops, done));
			}
		}
		loke_rt_v1_free(a, fresh, fresh->block_size, fresh->block_align);
		return 0;
	}
	out->table = fresh;
	out->len = src->len;
	out->cap = src->cap;
	return 1;
}

/* -------------------------------------------------------- map operations -- */

/* The slot holding `key`, or -1. A probe stops at the first empty control byte:
 * a tombstone is skipped, because an entry inserted after a removal may lie
 * beyond it. When `key` is absent and `vacant` is not NULL, it receives the slot
 * an insertion takes: the first tombstone the probe passed, else the empty slot
 * that ended it, else -1 for a probe that crossed the whole table.
 *
 * This is the only probe for a key, and it is inlined into each operation that
 * looks one up, so a program's lookup calls its key's `hash` and `==` directly. */
LOKE_RT_FAST_PATH static int64_t map_probe(
	const loke_rt_map_table_v1 *t, const loke_rt_container_ops_v1 *ops, const void *key,
	int64_t *vacant) {
	uint64_t mask = (uint64_t)t->slot_count - 1;
	uint64_t index = map_home(t, ops, key, mask);
	const uint8_t *controls = map_controls(t);
	int64_t first_free = -1;
	int64_t probes;
	for (probes = 0; probes < t->slot_count; probes += 1) {
		uint8_t control = controls[index];
		if (control == LOKE_RT_MAP_EMPTY) {
			if (first_free < 0) {
				first_free = (int64_t)index;
			}
			break;
		}
		if (control == LOKE_RT_MAP_OCCUPIED) {
			if (ops->key_equal(map_key_at(t, ops, (int64_t)index), key)) {
				return (int64_t)index;
			}
		} else if (control == LOKE_RT_MAP_TOMBSTONE && first_free < 0) {
			first_free = (int64_t)index;
		}
		index = (index + 1) & mask;
	}
	if (vacant != 0) {
		*vacant = first_free;
	}
	return -1;
}

LOKE_RT_FAST_PATH void *loke_rt_v1_map_find(
	const loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, const void *key) {
	const loke_rt_map_table_v1 *t = (const loke_rt_map_table_v1 *)self->table;
	int64_t slot;
	if (t == 0 || self->len == 0) {
		return 0;
	}
	slot = map_probe(t, ops, key, 0);
	return slot < 0 ? 0 : map_value_at(t, ops, slot);
}

/* Inserts `key`, which a probe of the current table did not find, at the
 * `vacant` slot that probe answered; -1 when there is no table or no vacancy.
 * NULL is allocation or key clone failure, before any new entry is published. */
LOKE_RT_SLOW_PATH static void *map_insert_missing(
	loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, const void *key, int64_t vacant,
	int32_t *inserted) {
	const loke_rt_allocator_v1 *allocator = self->allocator == 0 ? loke_rt_v1_selected_allocator() : self->allocator;
	loke_rt_map_table_v1 *fresh = 0;
	loke_rt_map_table_v1 *old = (loke_rt_map_table_v1 *)self->table;
	loke_rt_map_table_v1 *t = old;
	void *stored_key;
	int64_t slots;
	/* Reusing a tombstone leaves the count of nonempty slots as it was, so
	 * only the live entries need room. */
	int32_t reusing = t != 0 && vacant >= 0 && map_controls(t)[vacant] == LOKE_RT_MAP_TOMBSTONE;

	/* A growth is built off to the side. Its entries are representation moves
	 * that still alias `old`, so failure can release the fresh raw block without
	 * dropping anything and leave every old header/table byte untouched. Below
	 * the load limit some slot is empty, so the probe found a vacancy; `vacant`
	 * is checked anyway, since writing at -1 would corrupt memory. */
	if (t == 0 || vacant < 0 || self->len + 1 + (reusing ? 0 : t->tombstones) > self->cap) {
		if (!map_slots_for(self->len + 1, &slots)) {
			return 0;
		}
		/* The rebuild is not optional. Nothing else in this file clears a
		 * tombstone, so a table whose empty slots have all become one probes to
		 * the end of every run and never recovers. Never below the current size,
		 * which `reserve` promised; and never at a size the live entries already
		 * half fill, or a table sitting at its load limit rebuilds every other
		 * insertion instead of amortizing one over a linear run of them. */
		if (old != 0 && slots < old->slot_count) {
			slots = old->slot_count;
		}
		while (slots / 2 <= self->len) {
			if (slots > INT64_MAX / 2) {
				return 0;
			}
			slots *= 2;
		}
		fresh = map_rebuild(allocator, ops, old, slots);
		if (fresh == 0) {
			return 0;
		}
		t = fresh;
		reusing = 0;
		/* The fresh table has its own seed, so the key's home moves. */
		vacant = (int64_t)map_first_free(fresh, ops, key);
	}

	/* The stored key is an independent clone: the caller's may be a borrow. */
	stored_key = map_key_at(t, ops, vacant);
	if (ops->key_clone != 0) {
		if (!ops->key_clone(stored_key, key, allocator)) {
			if (fresh != 0) {
				map_free_block(allocator, fresh);
			}
			return 0;
		}
	} else {
		memcpy(stored_key, key, (size_t)ops->key_size);
	}
	if (reusing) {
		t->tombstones -= 1;
	}
	memset(map_value_at(t, ops, vacant), 0, (size_t)ops->elem_size);
	map_controls(t)[vacant] = LOKE_RT_MAP_OCCUPIED;
	self->allocator = allocator;
	if (fresh != 0) {
		map_replace(self, fresh);
	}
	self->len += 1;
	*inserted = 1;
	return map_value_at(t, ops, vacant);
}

/* Finds or inserts the raw slot shared by inserting indexes and explicit map
 * insertion. A new slot starts as zeroed inert bytes; the caller uses `inserted`
 * to avoid dropping them and commits a live supplied value before any hook can
 * observe the entry, including by unwinding. NULL is a failed insertion. */
LOKE_RT_FAST_PATH void *loke_rt_v1_map_entry(
	loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, const void *key, int32_t *inserted) {
	const loke_rt_map_table_v1 *t = (const loke_rt_map_table_v1 *)self->table;
	int64_t vacant = -1;

	*inserted = 0;
	if (t != 0) {
		int64_t slot = map_probe(t, ops, key, &vacant);
		if (slot >= 0) {
			return map_value_at(t, ops, slot);
		}
	}
	return map_insert_missing(self, ops, key, vacant, inserted);
}

/* Drops the stored key, moves the stored value to `out`, and answers 0 when the
 * key was absent. The slot becomes a tombstone, because an entry inserted after
 * it may lie beyond it in a probe run. The value moves only once the key's hook
 * has returned: until then the map owns it, so a panicking key hook leaves it
 * to the map's drop rather than to an `out` nothing has registered. */
int32_t loke_rt_v1_map_remove(
	loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, const void *key, void *out) {
	loke_rt_map_table_v1 *t = (loke_rt_map_table_v1 *)self->table;
	int64_t slot;

	memset(out, 0, (size_t)ops->elem_size);
	if (t == 0 || self->len == 0) {
		return 0;
	}
	slot = map_probe(t, ops, key, 0);
	if (slot < 0) {
		return 0;
	}
	map_controls(t)[slot] = LOKE_RT_MAP_VALUE_OWED;
	t->tombstones += 1;
	self->len -= 1;
	if (ops->key_drop != 0) {
		ops->key_drop(map_key_at(t, ops, slot));
	}
	memcpy(out, map_value_at(t, ops, slot), (size_t)ops->elem_size);
	map_controls(t)[slot] = LOKE_RT_MAP_TOMBSTONE;
	return 1;
}

void loke_rt_v1_map_clear(loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops) {
	loke_rt_map_table_v1 *t = (loke_rt_map_table_v1 *)self->table;
	if (t == 0) {
		return;
	}
	map_drop_entries(self, t, ops);
	memset(map_controls(t), LOKE_RT_MAP_EMPTY, (size_t)t->slot_count);
	t->tombstones = 0;
	self->len = 0;
}

/* design.md: `shrink` "removes excess capacity". A rebuild at the smallest slot
 * count that still holds the live entries also clears every tombstone. */
int32_t loke_rt_v1_map_shrink(
	loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t min_capacity) {
	loke_rt_map_table_v1 *fresh;
	loke_rt_map_table_v1 *old = (loke_rt_map_table_v1 *)self->table;
	int64_t want = self->len < min_capacity ? min_capacity : self->len;
	int64_t slots;

	if (min_capacity < 0) {
		loke_rt_v1_container_fault("a container capacity cannot be negative");
	}
	if (old == 0) {
		return 1;
	}
	if (!map_slots_for(want, &slots)) {
		return 0;
	}
	/* A minimum above the current size never grows the table; with tombstones
	 * the rebuild still happens, at the size it already has. */
	if (slots > old->slot_count) {
		slots = old->slot_count;
	}
	if (slots == old->slot_count && old->tombstones == 0) {
		return 1;
	}
	fresh = map_rebuild(self->allocator, ops, old, slots);
	if (fresh == 0) {
		return 0; /* the old table is still live and unchanged */
	}
	map_replace(self, fresh);
	return 1;
}

/* design.md: "**Iteration order is unspecified.**" A scan walks slots in table
 * order, which is exactly what makes that true — the seed decides where an entry
 * lands. Answers 0 when the walk is finished, and otherwise the cursor to resume
 * from, so the caller keeps one integer and no table knowledge. */
int64_t loke_rt_v1_map_scan(
	void *table, const loke_rt_container_ops_v1 *ops, int64_t cursor, void **out_key, void **out_value) {
	loke_rt_map_table_v1 *t = (loke_rt_map_table_v1 *)table;
	uint8_t *controls;
	int64_t slot;
	if (t == 0 || cursor < 0) {
		return 0;
	}
	controls = map_controls(t);
	for (slot = cursor; slot < t->slot_count; slot += 1) {
		if (controls[slot] != LOKE_RT_MAP_OCCUPIED) {
			continue;
		}
		*out_key = map_key_at(t, ops, slot);
		*out_value = map_value_at(t, ops, slot);
		return slot + 1;
	}
	return 0;
}

/* ---------------------------------------------------------------- hash -- */

/* One step of `hash_bytes`: FNV-1a's step, then the high half folded down, so
 * that a difference in a word's top byte reaches the low bits the next multiply
 * spreads from. Each step is a bijection of `h`. */
static uint64_t hash_word(uint64_t h, uint64_t word) {
	h = (h ^ word) * 1099511628211u;
	return h ^ (h >> 32);
}

/* Eight bytes a step, little-endian, the last word padded with zeros, then the
 * length, matching `hash_text_const` so compile-time and runtime hashes agree. */
uint64_t loke_rt_v1_hash_bytes(const uint8_t *data, int64_t len, uint64_t seed) {
	uint64_t h = seed;
	int64_t i = 0;
	for (; i + 8 <= len; i += 8) {
		uint64_t word;
		memcpy(&word, data + i, 8);
		h = hash_word(h, word);
	}
	if (i < len) {
		uint64_t word = 0;
		memcpy(&word, data + i, (size_t)(len - i));
		h = hash_word(h, word);
	}
	return hash_word(h, (uint64_t)len);
}

/* --------------------------------------------------------------- faults -- */

/* design.md: an invalid index or a negative size is an ordinary program fault,
 * so it takes the program panic strategy rather than an allocator policy. */
void loke_rt_v1_container_fault(const char *what) {
	loke_rt_v1_panic(what);
}

/* ------------------------------------------------------------- to_runes -- */

/* design.md "string type conversions": `[dynamic]rune` by copy. Two passes,
 * because the exact count is cheap to compute and an upper bound of one rune per
 * byte would over-allocate fourfold on ASCII.
 *
 * `rune` is trivial, so "prefix cleanup" is exactly releasing the buffer: there
 * are no partly built elements to destroy. The decoder cannot fail on a valid
 * `string`, which every Loke text already is. */
int32_t loke_rt_v1_string_to_runes(
	loke_rt_dynamic_v1 *out, const loke_rt_container_ops_v1 *ops,
	const uint8_t *data, int64_t len, const loke_rt_allocator_v1 *a) {
	int64_t count, offset, written;
	int32_t *slots;

	out->data = 0;
	out->len = 0;
	out->cap = 0;
	out->allocator = a;
	count = loke_rt_v1_rune_count(data, len);
	if (count == 0) {
		return 1;
	}
	if (!loke_rt_v1_dyn_reserve(out, ops, count)) {
		loke_rt_v1_dyn_drop(out, ops);
		return 0;
	}
	slots = (int32_t *)out->data;
	offset = 0;
	written = 0;
	while (offset < len && written < count) {
		int32_t decoded = 0;
		int64_t used = loke_rt_v1_rune_at(data, len, offset, &decoded);
		if (used <= 0) {
			break;
		}
		slots[written] = decoded;
		written += 1;
		offset += used;
	}
	out->len = written;
	return 1;
}

