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
 *   - A failed operation leaves the container bit-for-bit unchanged. New
 *     storage is filled completely before any header word is published, and a
 *     clone that fails part-way destroys exactly the prefix it built.
 */
#include "loke_rt.h"

#include <string.h>

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
 * not a language guarantee. */
static int32_t dyn_growth_target(int64_t cap, int64_t min_capacity, int64_t *out) {
	int64_t want = min_capacity;
	if (cap > 0) {
		int64_t doubled;
		if (loke_rt_v1_checked_add(cap, cap, &doubled) && doubled > want) {
			want = doubled;
		}
	}
	if (want < 8) {
		want = 8;
	}
	if (want < min_capacity) {
		return 0;
	}
	*out = want;
	return 1;
}

int32_t loke_rt_v1_dyn_reserve(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t min_capacity) {
	int64_t target;
	uint64_t old_bytes, new_bytes;
	void *storage;

	if (min_capacity < 0) {
		loke_rt_v1_container_fault("a container capacity cannot be negative");
	}
	loke_rt_v1_dyn_bind(self);
	if (min_capacity <= self->cap) {
		return 1;
	}
	if (!dyn_growth_target(self->cap, min_capacity, &target)) {
		return 0;
	}
	if (!loke_rt_v1_checked_bytes(target, ops->elem_size, &new_bytes)) {
		return 0;
	}
	if (!loke_rt_v1_checked_bytes(self->cap, ops->elem_size, &old_bytes)) {
		return 0;
	}
	/* A zero-sized element needs no storage at all, and `_aligned_realloc` of
	 * zero bytes would answer NULL and read as a failure. */
	if (new_bytes == 0) {
		self->cap = target;
		return 1;
	}
	storage = loke_rt_v1_resize(
		self->allocator, self->data, old_bytes, new_bytes, sane_container_align(ops->elem_align));
	if (storage == 0) {
		return 0; /* the old allocation is still live and unchanged */
	}
	self->data = storage;
	self->cap = target;
	return 1;
}

void loke_rt_v1_dyn_drop(loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops) {
	uint64_t bytes;
	if (self->data != 0) {
		if (ops->elem_drop != 0) {
			int64_t i;
			for (i = 0; i < self->len; i += 1) {
				ops->elem_drop(dyn_at(self, ops, i));
			}
		}
		if (loke_rt_v1_checked_bytes(self->cap, ops->elem_size, &bytes) && bytes != 0) {
			loke_rt_v1_free(self->allocator, self->data, bytes, sane_container_align(ops->elem_align));
		}
	}
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
		uint64_t bytes;
		if (!loke_rt_v1_checked_bytes(src->len, ops->elem_size, &bytes)) {
			loke_rt_v1_dyn_drop(out, ops);
			out->allocator = a;
			return 0;
		}
		memcpy(out->data, src->data, (size_t)bytes);
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

/* design.md's lazy default binding: an unbound container binds a provider the
 * first time it needs one. A `via` declaration wrote its own at the declaration
 * point, so this never overrides a written policy. */
void loke_rt_v1_dyn_bind(loke_rt_dynamic_v1 *self) {
	if (self->allocator == 0) {
		self->allocator = &loke_rt_v1_default_allocator;
	}
}

/* Growth that keeps the old block alive. A source slice pointing into that block
 * has to stay readable until the copy out of it is finished, which a plain
 * `resize` cannot promise. */
typedef struct dyn_grow_undo {
	void *old_data;
	int64_t old_cap;
	int32_t grew;
} dyn_grow_undo;

static int32_t dyn_regrow(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops,
	int64_t need, int32_t force, dyn_grow_undo *undo) {
	int64_t target;
	uint64_t bytes, used;
	void *fresh;

	undo->grew = 0;
	undo->old_data = self->data;
	undo->old_cap = self->cap;
	if (need <= self->cap && !force) {
		return 1;
	}
	if (!dyn_growth_target(self->cap, need, &target)) {
		return 0;
	}
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
	if (loke_rt_v1_checked_bytes(self->len, ops->elem_size, &used) && used != 0) {
		memcpy(fresh, self->data, (size_t)used);
	}
	self->data = fresh;
	self->cap = target;
	undo->grew = 1;
	return 1;
}

static void dyn_regrow_commit(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, const dyn_grow_undo *undo) {
	uint64_t bytes;
	if (undo->grew && undo->old_data != 0 &&
	    loke_rt_v1_checked_bytes(undo->old_cap, ops->elem_size, &bytes) && bytes != 0) {
		loke_rt_v1_free(self->allocator, undo->old_data, bytes, sane_container_align(ops->elem_align));
	}
}

static void dyn_regrow_rollback(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, const dyn_grow_undo *undo) {
	uint64_t bytes;
	if (!undo->grew) {
		return;
	}
	if (loke_rt_v1_checked_bytes(self->cap, ops->elem_size, &bytes) && bytes != 0) {
		loke_rt_v1_free(self->allocator, self->data, bytes, sane_container_align(ops->elem_align));
	}
	self->data = undo->old_data;
	self->cap = undo->old_cap;
}

/* Whether `src` points into this container's own storage, in which case a shift
 * of the existing elements would overwrite it and the operation has to build a
 * fresh block instead. */
static int32_t dyn_src_aliases(
	const loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, const void *src) {
	const char *base = (const char *)self->data;
	const char *p = (const char *)src;
	uint64_t bytes;
	if (base == 0 || !loke_rt_v1_checked_bytes(self->cap, ops->elem_size, &bytes)) {
		return 0;
	}
	return p >= base && p < base + bytes;
}

/* Fills slots [at, at+count) from `src`, destroying exactly the prefix it built
 * if one element's clone fails. */
static int32_t dyn_fill(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops,
	int64_t at, const void *src, int64_t count) {
	int64_t i, j;
	uint64_t bytes;
	if (ops->elem_clone == 0) {
		if (!loke_rt_v1_checked_bytes(count, ops->elem_size, &bytes)) {
			return 0;
		}
		if (bytes != 0) {
			memcpy(dyn_at(self, ops, at), src, (size_t)bytes);
		}
		return 1;
	}
	for (i = 0; i < count; i += 1) {
		const void *from = (const char *)src + (uint64_t)i * ops->elem_size;
		if (ops->elem_clone(dyn_at(self, ops, at + i), from, self->allocator)) {
			continue;
		}
		if (ops->elem_drop != 0) {
			for (j = 0; j < i; j += 1) {
				ops->elem_drop(dyn_at(self, ops, at + j));
			}
		}
		return 0;
	}
	return 1;
}

int32_t loke_rt_v1_dyn_append(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, const void *src, int64_t count) {
	dyn_grow_undo undo;
	int64_t need;

	if (count < 0) {
		loke_rt_v1_container_fault("a container append count cannot be negative");
	}
	if (count == 0) {
		return 1;
	}
	loke_rt_v1_dyn_bind(self);
	if (!loke_rt_v1_checked_add(self->len, count, &need)) {
		return 0;
	}
	/* Appending writes past `len`, which no live element and therefore no
	 * possible source overlaps, so only reallocation is a hazard here. */
	if (!dyn_regrow(self, ops, need, 0, &undo)) {
		return 0;
	}
	if (!dyn_fill(self, ops, self->len, src, count)) {
		dyn_regrow_rollback(self, ops, &undo);
		return 0;
	}
	self->len = need;
	dyn_regrow_commit(self, ops, &undo);
	return 1;
}

int32_t loke_rt_v1_dyn_insert(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops,
	int64_t index, const void *src, int64_t count) {
	dyn_grow_undo undo;
	int64_t need, tail;
	uint64_t tail_bytes;

	if (index < 0 || index > self->len) {
		loke_rt_v1_container_fault("this insert index is out of range");
	}
	if (count < 0) {
		loke_rt_v1_container_fault("a container insert count cannot be negative");
	}
	if (count == 0) {
		return 1;
	}
	loke_rt_v1_dyn_bind(self);
	if (!loke_rt_v1_checked_add(self->len, count, &need)) {
		return 0;
	}
	/* An insert shifts live elements, so a source inside this container's own
	 * storage would be overwritten by that shift. Building a fresh block leaves
	 * the source block untouched until the copy is done. */
	if (!dyn_regrow(self, ops, need, dyn_src_aliases(self, ops, src), &undo)) {
		return 0;
	}
	tail = self->len - index;
	if (loke_rt_v1_checked_bytes(tail, ops->elem_size, &tail_bytes) && tail_bytes != 0) {
		memmove(dyn_at(self, ops, index + count), dyn_at(self, ops, index), (size_t)tail_bytes);
	}
	if (!dyn_fill(self, ops, index, src, count)) {
		if (tail_bytes != 0) {
			memmove(dyn_at(self, ops, index), dyn_at(self, ops, index + count), (size_t)tail_bytes);
		}
		dyn_regrow_rollback(self, ops, &undo);
		return 0;
	}
	self->len = need;
	dyn_regrow_commit(self, ops, &undo);
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
	uint64_t tail_bytes;
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
	if (loke_rt_v1_checked_bytes(self->len - index, ops->elem_size, &tail_bytes) && tail_bytes != 0) {
		memmove(dyn_at(self, ops, index), dyn_at(self, ops, index + 1), (size_t)tail_bytes);
	}
}

void loke_rt_v1_dyn_clear(loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops) {
	int64_t i;
	if (ops->elem_drop != 0) {
		for (i = 0; i < self->len; i += 1) {
			ops->elem_drop(dyn_at(self, ops, i));
		}
	}
	self->len = 0;
}

int32_t loke_rt_v1_dyn_resize(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t new_len) {
	uint64_t bytes;
	int64_t i;

	if (new_len < 0) {
		loke_rt_v1_container_fault("a container length cannot be negative");
	}
	if (new_len < self->len) {
		if (ops->elem_drop != 0) {
			for (i = new_len; i < self->len; i += 1) {
				ops->elem_drop(dyn_at(self, ops, i));
			}
		}
		self->len = new_len;
		return 1;
	}
	if (new_len == self->len) {
		return 1;
	}
	loke_rt_v1_dyn_bind(self);
	if (!loke_rt_v1_dyn_reserve(self, ops, new_len)) {
		return 0;
	}
	/* Every Loke zero value is all-zero bits, so the new tail is one memset and
	 * the drop of an untouched element is the no-op every hook already handles. */
	if (loke_rt_v1_checked_bytes(new_len - self->len, ops->elem_size, &bytes) && bytes != 0) {
		memset(dyn_at(self, ops, self->len), 0, (size_t)bytes);
	}
	self->len = new_len;
	return 1;
}

int32_t loke_rt_v1_dyn_shrink(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t min_capacity) {
	int64_t target = self->len < min_capacity ? min_capacity : self->len;
	uint64_t old_bytes, new_bytes;
	void *storage;

	if (min_capacity < 0) {
		loke_rt_v1_container_fault("a container capacity cannot be negative");
	}
	if (target >= self->cap || self->data == 0) {
		return 1;
	}
	if (!loke_rt_v1_checked_bytes(self->cap, ops->elem_size, &old_bytes) ||
	    !loke_rt_v1_checked_bytes(target, ops->elem_size, &new_bytes)) {
		return 0;
	}
	if (new_bytes == 0) {
		loke_rt_v1_free(self->allocator, self->data, old_bytes, sane_container_align(ops->elem_align));
		self->data = 0;
		self->cap = 0;
		return 1;
	}
	storage = loke_rt_v1_resize(
		self->allocator, self->data, old_bytes, new_bytes, sane_container_align(ops->elem_align));
	if (storage == 0) {
		return 0; /* the old allocation is still live and unchanged */
	}
	self->data = storage;
	self->cap = target;
	return 1;
}

/* ------------------------------------------------------------------- map -- */

static uint8_t *map_controls(const loke_rt_map_table_v1 *t) {
	return (uint8_t *)t + t->controls_offset;
}

static void *map_key_at(const loke_rt_map_table_v1 *t, const loke_rt_container_ops_v1 *ops, int64_t slot) {
	return (char *)t + t->keys_offset + (uint64_t)slot * ops->key_size;
}

static void *map_value_at(const loke_rt_map_table_v1 *t, const loke_rt_container_ops_v1 *ops, int64_t slot) {
	return (char *)t + t->values_offset + (uint64_t)slot * ops->elem_size;
}

/* m6b-plan decision "Map algorithm and coherence": an opaque per-table seed, so
 * iteration order is unspecified and no program can come to depend on it. The
 * mix is deterministic within one process and derived from the table's own
 * address and a running counter. */
static uint64_t map_next_seed(const void *block) {
	static uint64_t counter = 0x9e3779b97f4a7c15u;
	uint64_t x = counter + (uint64_t)(uintptr_t)block;
	counter += 0x9e3779b97f4a7c15u;
	x ^= x >> 30;
	x *= 0xbf58476d1ce4e5b9u;
	x ^= x >> 27;
	x *= 0x94d049bb133111ebu;
	x ^= x >> 31;
	return x;
}

/* Maximum load: seven eighths. Pinned by the runtime tests, not by the
 * language. */
static int64_t map_capacity_of(int64_t slot_count) {
	return slot_count - slot_count / 8;
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

	if (!checked_round_up(sizeof(loke_rt_map_table_v1), 8, &cursor)) {
		return 0;
	}
	shape->controls_offset = cursor;
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
	shape->occupied = 0;
	shape->tombstones = 0;
	shape->block_align = align;
	return 1;
}

static void map_free_block(const loke_rt_allocator_v1 *a, loke_rt_map_table_v1 *t) {
	loke_rt_v1_free(a, t, t->block_size, t->block_align);
}

/* Relocation within a rehash is a compiler-known move of initialized
 * representations: m6b-plan decision "Element lifecycle" is explicit that it
 * does not call user clone or drop hooks. */
static void map_place_moved(
	loke_rt_map_table_v1 *dst, const loke_rt_container_ops_v1 *ops, const void *key, const void *value) {
	uint64_t mask = (uint64_t)dst->slot_count - 1;
	uint64_t index = ops->key_hash(key, dst->seed) & mask;
	uint8_t *controls = map_controls(dst);
	for (;;) {
		if (controls[index] != LOKE_RT_MAP_OCCUPIED) {
			memcpy(map_key_at(dst, ops, (int64_t)index), key, (size_t)ops->key_size);
			memcpy(map_value_at(dst, ops, (int64_t)index), value, (size_t)ops->elem_size);
			controls[index] = LOKE_RT_MAP_OCCUPIED;
			dst->occupied += 1;
			return;
		}
		index = (index + 1) & mask;
	}
}

int32_t loke_rt_v1_map_reserve(
	loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t min_capacity) {
	loke_rt_map_table_v1 shape;
	loke_rt_map_table_v1 *fresh;
	loke_rt_map_table_v1 *old = (loke_rt_map_table_v1 *)self->table;
	int64_t slots, want;

	if (min_capacity < 0) {
		loke_rt_v1_container_fault("a container capacity cannot be negative");
	}
	loke_rt_v1_map_bind(self);
	if (min_capacity <= self->cap && (old != 0 || min_capacity == 0)) {
		return 1;
	}
	want = min_capacity < self->len ? self->len : min_capacity;
	if (!map_slots_for(want, &slots)) {
		return 0;
	}
	if (!map_block_shape(ops, slots, &shape)) {
		return 0;
	}
	fresh = (loke_rt_map_table_v1 *)loke_rt_v1_alloc_zeroed(
		self->allocator, shape.block_size, shape.block_align);
	if (fresh == 0) {
		return 0; /* the old table is still live and unchanged */
	}
	*fresh = shape;
	fresh->seed = map_next_seed(fresh);

	if (old != 0) {
		uint8_t *controls = map_controls(old);
		int64_t slot;
		for (slot = 0; slot < old->slot_count; slot += 1) {
			if (controls[slot] == LOKE_RT_MAP_OCCUPIED) {
				map_place_moved(fresh, ops, map_key_at(old, ops, slot), map_value_at(old, ops, slot));
			}
		}
		map_free_block(self->allocator, old);
	}
	self->table = fresh;
	self->cap = map_capacity_of(slots);
	return 1;
}

void loke_rt_v1_map_drop(loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops) {
	loke_rt_map_table_v1 *t = (loke_rt_map_table_v1 *)self->table;
	if (t != 0) {
		if (ops->key_drop != 0 || ops->elem_drop != 0) {
			uint8_t *controls = map_controls(t);
			int64_t slot;
			for (slot = 0; slot < t->slot_count; slot += 1) {
				if (controls[slot] != LOKE_RT_MAP_OCCUPIED) {
					continue;
				}
				if (ops->key_drop != 0) {
					ops->key_drop(map_key_at(t, ops, slot));
				}
				if (ops->elem_drop != 0) {
					ops->elem_drop(map_value_at(t, ops, slot));
				}
			}
		}
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

void loke_rt_v1_map_bind(loke_rt_map_v1 *self) {
	if (self->allocator == 0) {
		self->allocator = &loke_rt_v1_default_allocator;
	}
}

/* The slot holding `key`, or -1. A probe stops at the first empty control byte:
 * a tombstone is skipped, because an entry inserted after a removal may lie
 * beyond it. */
static int64_t map_probe(
	const loke_rt_map_table_v1 *t, const loke_rt_container_ops_v1 *ops, const void *key) {
	uint64_t mask = (uint64_t)t->slot_count - 1;
	uint64_t index = ops->key_hash(key, t->seed) & mask;
	const uint8_t *controls = map_controls(t);
	int64_t probes;
	for (probes = 0; probes < t->slot_count; probes += 1) {
		if (controls[index] == LOKE_RT_MAP_EMPTY) {
			return -1;
		}
		if (controls[index] == LOKE_RT_MAP_OCCUPIED &&
		    ops->key_equal(map_key_at(t, ops, (int64_t)index), key)) {
			return (int64_t)index;
		}
		index = (index + 1) & mask;
	}
	return -1;
}

void *loke_rt_v1_map_find(
	const loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, const void *key) {
	const loke_rt_map_table_v1 *t = (const loke_rt_map_table_v1 *)self->table;
	int64_t slot;
	if (t == 0 || self->len == 0) {
		return 0;
	}
	slot = map_probe(t, ops, key);
	return slot < 0 ? 0 : map_value_at(t, ops, slot);
}

/* design.md: "`m[key]` as an assignment target inserts. If the key is absent,
 * the zero value of the element type is inserted first and the resulting slot
 * is the location." The zero value is written only after growth has succeeded,
 * so a failed insertion never leaves a partial slot; NULL is that failure. */
void *loke_rt_v1_map_entry(
	loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, const void *key, int32_t *inserted) {
	loke_rt_map_table_v1 *t;
	uint8_t *controls;
	uint64_t mask, index;
	int64_t slot, first_free;

	*inserted = 0;
	loke_rt_v1_map_bind(self);
	t = (loke_rt_map_table_v1 *)self->table;
	if (t != 0) {
		slot = map_probe(t, ops, key);
		if (slot >= 0) {
			return map_value_at(t, ops, slot);
		}
	}
	/* Growth first: the key clone below must not be stranded by a table that
	 * then fails to allocate. Tombstones count against the load, so a table full
	 * of them is rebuilt rather than probed forever. */
	if (t == 0 || self->len + 1 > self->cap ||
	    t->occupied + t->tombstones + 1 > t->slot_count - t->slot_count / 8) {
		if (!loke_rt_v1_map_reserve(self, ops, self->len + 1)) {
			return 0;
		}
		t = (loke_rt_map_table_v1 *)self->table;
	}

	controls = map_controls(t);
	mask = (uint64_t)t->slot_count - 1;
	index = ops->key_hash(key, t->seed) & mask;
	first_free = -1;
	for (;;) {
		if (controls[index] == LOKE_RT_MAP_OCCUPIED) {
			index = (index + 1) & mask;
			continue;
		}
		if (controls[index] == LOKE_RT_MAP_TOMBSTONE && first_free < 0) {
			first_free = (int64_t)index;
			index = (index + 1) & mask;
			continue;
		}
		break;
	}
	if (first_free >= 0) {
		t->tombstones -= 1;
		index = (uint64_t)first_free;
	}
	/* The stored key is an independent clone: the caller's may be a borrow. */
	if (ops->key_clone != 0) {
		if (!ops->key_clone(map_key_at(t, ops, (int64_t)index), key, self->allocator)) {
			if (first_free >= 0) {
				t->tombstones += 1;
			}
			return 0;
		}
	} else {
		memcpy(map_key_at(t, ops, (int64_t)index), key, (size_t)ops->key_size);
	}
	memset(map_value_at(t, ops, (int64_t)index), 0, (size_t)ops->elem_size);
	controls[index] = LOKE_RT_MAP_OCCUPIED;
	t->occupied += 1;
	self->len += 1;
	*inserted = 1;
	return map_value_at(t, ops, (int64_t)index);
}

/* Moves the stored value to `out`, drops the key, and answers 0 when the key was
 * absent. The slot becomes a tombstone, because an entry inserted after it may
 * lie beyond it in a probe run. */
int32_t loke_rt_v1_map_remove(
	loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, const void *key, void *out) {
	loke_rt_map_table_v1 *t = (loke_rt_map_table_v1 *)self->table;
	int64_t slot;

	memset(out, 0, (size_t)ops->elem_size);
	if (t == 0 || self->len == 0) {
		return 0;
	}
	slot = map_probe(t, ops, key);
	if (slot < 0) {
		return 0;
	}
	memcpy(out, map_value_at(t, ops, slot), (size_t)ops->elem_size);
	if (ops->key_drop != 0) {
		ops->key_drop(map_key_at(t, ops, slot));
	}
	map_controls(t)[slot] = LOKE_RT_MAP_TOMBSTONE;
	t->occupied -= 1;
	t->tombstones += 1;
	self->len -= 1;
	return 1;
}

void loke_rt_v1_map_clear(loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops) {
	loke_rt_map_table_v1 *t = (loke_rt_map_table_v1 *)self->table;
	uint8_t *controls;
	int64_t slot;
	if (t == 0) {
		return;
	}
	controls = map_controls(t);
	for (slot = 0; slot < t->slot_count; slot += 1) {
		if (controls[slot] != LOKE_RT_MAP_OCCUPIED) {
			continue;
		}
		if (ops->key_drop != 0) {
			ops->key_drop(map_key_at(t, ops, slot));
		}
		if (ops->elem_drop != 0) {
			ops->elem_drop(map_value_at(t, ops, slot));
		}
	}
	memset(controls, LOKE_RT_MAP_EMPTY, (size_t)t->slot_count);
	t->occupied = 0;
	t->tombstones = 0;
	self->len = 0;
}

/* design.md: `shrink` "removes excess capacity". A rebuild at the smallest slot
 * count that still holds the live entries also clears every tombstone. */
int32_t loke_rt_v1_map_shrink(
	loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t min_capacity) {
	loke_rt_map_table_v1 shape;
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
	if (slots >= old->slot_count && old->tombstones == 0) {
		return 1;
	}
	if (!map_block_shape(ops, slots, &shape)) {
		return 0;
	}
	fresh = (loke_rt_map_table_v1 *)loke_rt_v1_alloc_zeroed(
		self->allocator, shape.block_size, shape.block_align);
	if (fresh == 0) {
		return 0; /* the old table is still live and unchanged */
	}
	*fresh = shape;
	fresh->seed = map_next_seed(fresh);
	{
		uint8_t *controls = map_controls(old);
		int64_t slot;
		for (slot = 0; slot < old->slot_count; slot += 1) {
			if (controls[slot] == LOKE_RT_MAP_OCCUPIED) {
				map_place_moved(fresh, ops, map_key_at(old, ops, slot), map_value_at(old, ops, slot));
			}
		}
	}
	map_free_block(self->allocator, old);
	self->table = fresh;
	self->cap = map_capacity_of(slots);
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

/* design.md's standard catalogue promises `string` and `string_view` satisfy
 * `Hashable`, and two equal texts must hash equally however they were built. The
 * mix is the same 64-bit FNV-1a step the compiler folds over a scalar, applied
 * once per byte, so the compile-time and runtime paths agree exactly. */
uint64_t loke_rt_v1_hash_bytes(const uint8_t *data, int64_t len, uint64_t seed) {
	uint64_t h = seed;
	int64_t i;
	for (i = 0; i < len; i += 1) {
		h = (h ^ (uint64_t)data[i]) * 1099511628211u;
	}
	return h;
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
