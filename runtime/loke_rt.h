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

/* ----------------------------------------------------------------- text -- */

/* design.md "string type": an immutable, owning UTF-8 value that "behaves like a
 * simple local variable". m6a-plan decision "Runtime string representation"
 * fixes the three words:
 *
 *   data         the bytes, always zero-terminated one past `byte_len`
 *   byte_len     O(1), which is what `len(text)` is shorthand for
 *   owner_flags  0 = the empty value, 1 = static literal storage,
 *                otherwise the address of the runtime buffer's header
 *
 * The empty value is all zero, and a literal is a compile-time constant, so
 * neither costs an allocation or a handle update. */
enum { LOKE_RT_STRING_STATIC = 1 };

typedef struct loke_rt_string_v1 {
	const uint8_t *data;
	int64_t byte_len;
	uintptr_t owner_flags;
} loke_rt_string_v1;

LOKE_RT_STATIC_ASSERT(sizeof(loke_rt_string_v1) == 24, string_value_size);

/* The header of one runtime buffer. design.md: "If an implementation shares
 * backing storage between string values, its reference count must be atomic so
 * concurrent handle accounting cannot corrupt the storage. The last drop also
 * deallocates through the string's bound allocator." */
typedef struct loke_rt_string_header_v1 {
	int64_t handles;
	const loke_rt_allocator_v1 *allocator;
	/* Total bytes handed to the provider, so the release returns the same size. */
	uint64_t block_size;
} loke_rt_string_header_v1;

/* Each returns 1 on success and 0 on failure. A validating conversion publishes
 * the zero value on failure, which is what design.md's optional-ok result
 * requires. */
int32_t loke_rt_v1_string_from_bytes(
	loke_rt_string_v1 *out, const uint8_t *data, int64_t len, const loke_rt_allocator_v1 *a);
int32_t loke_rt_v1_string_concat(
	loke_rt_string_v1 *out,
	const uint8_t *a_data, int64_t a_len,
	const uint8_t *b_data, int64_t b_len,
	const loke_rt_allocator_v1 *allocator);
/* Unlike assignment, this always allocates an independent buffer. */
int32_t loke_rt_v1_string_clone(
	loke_rt_string_v1 *out, const uint8_t *data, int64_t len, const loke_rt_allocator_v1 *a);
/* Runes in, UTF-8 out. Rejects a surrogate or out-of-range scalar value. */
int32_t loke_rt_v1_string_from_runes(
	loke_rt_string_v1 *out, const int32_t *runes, int64_t count, const loke_rt_allocator_v1 *a);

void loke_rt_v1_string_retain(uintptr_t owner_flags);
void loke_rt_v1_string_release(uintptr_t owner_flags);

int32_t loke_rt_v1_utf8_valid(const uint8_t *data, int64_t len);
int64_t loke_rt_v1_rune_count(const uint8_t *data, int64_t len);
/* Decodes the scalar value beginning at `offset` and answers how many bytes it
 * used, which is what advances a rune loop's byte offset. */
int64_t loke_rt_v1_rune_at(const uint8_t *data, int64_t len, int64_t offset, int32_t *out_rune);
/* Lexical byte-wise order: negative, zero, or positive. */
int32_t loke_rt_v1_bytes_compare(
	const uint8_t *a_data, int64_t a_len, const uint8_t *b_data, int64_t b_len);
int64_t loke_rt_v1_cstring_len(const uint8_t *p);

/* ------------------------------------------------------------ containers -- */

/* m6b-plan decisions "Dynamic-array value ABI", "Map value ABI" and "Container
 * runtime boundary". Both managed containers are four words, and both keep the
 * provider handle their drop has to release through. The all-zero value is
 * empty, allocator-unbound, and immediately usable, which is what makes a
 * file-scope or `static` container a constant.
 *
 * The raw storage and table mechanics live here; what a *Loke* element or key
 * costs to clone, drop, hash and compare cannot be known by C, so the compiler
 * hands one operation table of generated thunks to every call. */
typedef struct loke_rt_dynamic_v1 {
	void *data;
	int64_t len;
	int64_t cap;
	const loke_rt_allocator_v1 *allocator;
} loke_rt_dynamic_v1;

typedef struct loke_rt_map_v1 {
	void *table;
	int64_t len;
	/* Entries insertable before the next growth, not the raw slot count. */
	int64_t cap;
	const loke_rt_allocator_v1 *allocator;
} loke_rt_map_v1;

LOKE_RT_STATIC_ASSERT(sizeof(loke_rt_dynamic_v1) == 32, dynamic_value_size);
LOKE_RT_STATIC_ASSERT(sizeof(loke_rt_map_v1) == 32, map_value_size);

/* One private table per concrete element, or key/value combination. A NULL
 * `drop` means the part is trivially destroyed; a NULL `clone` means its clone
 * is the copy its representation already is. The key half is zero for a dynamic
 * array. */
typedef struct loke_rt_container_ops_v1 {
	uint64_t elem_size;
	uint64_t elem_align;
	void (*elem_drop)(void *elem);
	int32_t (*elem_clone)(void *out, const void *src, const loke_rt_allocator_v1 *a);

	uint64_t key_size;
	uint64_t key_align;
	void (*key_drop)(void *key);
	int32_t (*key_clone)(void *out, const void *src, const loke_rt_allocator_v1 *a);
	uint64_t (*key_hash)(const void *key, uint64_t seed);
	int32_t (*key_equal)(const void *a, const void *b);
} loke_rt_container_ops_v1;

/* The header of one map allocation. design.md leaves map order unspecified, and
 * m6b-plan keeps the seed and the control metadata *out* of the public value, so
 * the table algorithm can change without changing `map[K]V`'s layout.
 *
 * One block holds the header, then `slot_count` control bytes, then the key
 * array, then the value array. Offsets are stored rather than recomputed so the
 * reader and the allocator agree byte for byte. */
enum { LOKE_RT_MAP_EMPTY = 0, LOKE_RT_MAP_TOMBSTONE = 1, LOKE_RT_MAP_OCCUPIED = 2 };

typedef struct loke_rt_map_table_v1 {
	int64_t slot_count; /* a power of two */
	int64_t occupied;
	int64_t tombstones;
	uint64_t seed;
	uint64_t controls_offset;
	uint64_t keys_offset;
	uint64_t values_offset;
	uint64_t block_size;
	uint64_t block_align;
} loke_rt_map_table_v1;

/* Every one of these returns 1 on success. On failure the container is
 * bit-for-bit unchanged, which is what m6b-plan decision "Atomic mutation"
 * requires of every fallible container operation. */
int32_t loke_rt_v1_dyn_reserve(
	loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t min_capacity);
int32_t loke_rt_v1_dyn_clone(
	loke_rt_dynamic_v1 *out, const loke_rt_dynamic_v1 *src,
	const loke_rt_container_ops_v1 *ops, const loke_rt_allocator_v1 *a);
/* Destroys every live element, releases the storage, and writes the inert
 * all-zero representation. */
void loke_rt_v1_dyn_drop(loke_rt_dynamic_v1 *self, const loke_rt_container_ops_v1 *ops);

int32_t loke_rt_v1_map_reserve(
	loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops, int64_t min_capacity);
int32_t loke_rt_v1_map_clone(
	loke_rt_map_v1 *out, const loke_rt_map_v1 *src,
	const loke_rt_container_ops_v1 *ops, const loke_rt_allocator_v1 *a);
void loke_rt_v1_map_drop(loke_rt_map_v1 *self, const loke_rt_container_ops_v1 *ops);

/* Checked container arithmetic, shared by the generated code and the helpers
 * above: a source `int` count is signed and its overflow is defined to wrap, and
 * m6b-plan decision "Checked sizes" forbids letting that rule reach a provider
 * as an undersized allocation. Each answers 0 when the result is not
 * representable. */
int32_t loke_rt_v1_checked_add(int64_t a, int64_t b, int64_t *out);
int32_t loke_rt_v1_checked_bytes(int64_t count, uint64_t size, uint64_t *out);

/* An invalid index, a negative count, or a `len > cap` relationship is an
 * ordinary program fault, not an allocator failure. */
void loke_rt_v1_container_fault(const char *what);

/* ------------------------------------------------------------ formatting -- */

/* design.md "String format printing": "Formatting is a library protocol." The
 * library half lives in `core:fmt`; what the runtime owns is the byte sink every
 * formatter writes through, and the scalar spellings that would otherwise be
 * hundreds of lines of generated LLVM apiece.
 *
 * `Writer` and `Options` are declared in `core:fmt` with exactly these shapes.
 * A compiler-generated formatter thunk receives a pointer to each. */
typedef struct loke_rt_writer_v1 {
	void (*write)(void *state, const uint8_t *bytes, int64_t count);
	void *state;
} loke_rt_writer_v1;

typedef struct loke_rt_options_v1 {
	int64_t base;
	int32_t uppercase;
	int32_t reserved;
} loke_rt_options_v1;

LOKE_RT_STATIC_ASSERT(sizeof(loke_rt_writer_v1) == 16, writer_size);
LOKE_RT_STATIC_ASSERT(sizeof(loke_rt_options_v1) == 16, options_size);

/* The two process sinks. `state` carries the stream selector, so one `write`
 * implementation serves both and `core:fmt` needs no foreign declarations. */
void loke_rt_v1_write_std(void *state, const uint8_t *bytes, int64_t count);
enum { LOKE_RT_STDOUT = 0, LOKE_RT_STDERR = 1 };

void loke_rt_v1_fmt_bytes(const loke_rt_writer_v1 *w, const uint8_t *bytes, int64_t count);
void loke_rt_v1_fmt_i64(const loke_rt_writer_v1 *w, int64_t value, const loke_rt_options_v1 *o);
void loke_rt_v1_fmt_u64(const loke_rt_writer_v1 *w, uint64_t value, const loke_rt_options_v1 *o);
void loke_rt_v1_fmt_i128(
	const loke_rt_writer_v1 *w, uint64_t low, uint64_t high, const loke_rt_options_v1 *o);
void loke_rt_v1_fmt_u128(
	const loke_rt_writer_v1 *w, uint64_t low, uint64_t high, const loke_rt_options_v1 *o);
void loke_rt_v1_fmt_f64(const loke_rt_writer_v1 *w, double value);
void loke_rt_v1_fmt_bool(const loke_rt_writer_v1 *w, int32_t value);
void loke_rt_v1_fmt_rune(const loke_rt_writer_v1 *w, int32_t value);
void loke_rt_v1_fmt_ptr(const loke_rt_writer_v1 *w, const void *value);

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
/* Supplied by every generated module. Detach invokes it on the current thread,
 * whose thread-local globals are therefore the ones the thunk addresses. */
void loke_rt_v1_program_tls_cleanup(void);
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
