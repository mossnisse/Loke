/* Atomic operations at widths this target has no usable native lowering for
 * (design.md "Concurrency and the memory model").
 *
 * On Windows x64 the machine has `cmpxchg16b`, but reaching it through LLVM's
 * default 128-bit atomic lowering emits calls to `__atomic_load_16` and its
 * siblings, and this link does not supply that library. Emitting valid IR is
 * not the same as implementing the promised type set, so the 128-bit operations
 * arrive here instead.
 *
 * The contract these implement, which is the same one the native widths give:
 *
 *   - every operation on a 128-bit value is indivisible with respect to every
 *     other operation on a 128-bit value, whatever their orderings;
 *   - a release operation makes every write before it visible to a thread that
 *     performs an acquire operation reading what it wrote;
 *   - the sequentially consistent operations, native and fallback alike,
 *     appear in one total order that also contains every sequentially
 *     consistent fence.
 *
 * The last point is why *every* operation at a fallback width takes the lock,
 * loads and stores included. A locked read-modify-write beside an unlocked wide
 * load would let the load see a half-written value, which is exactly the
 * atomicity the lock exists to provide.
 *
 * ponytail: one global lock for every 128-bit atomic in the process, rather
 * than an address-hashed table of them. A program whose contention on wide
 * atomics matters wants a lock per cache line; the upgrade is to hash the
 * address into a fixed array of the same critical section, with no change to
 * this file's interface.
 *
 * Nothing here allocates, and nothing here depends on `core:sync` - the library
 * is written over these, not the other way round. */
#include "loke_rt.h"

#include <string.h>

/* The lock is a spin lock over the compiler's own atomic builtins rather than
 * an operating-system primitive: this file must not depend on a platform
 * header, must not allocate, and must not need an initializer to run before it
 * is usable. `__sync_lock_test_and_set` is an acquire and `__sync_lock_release`
 * a release, both lowered to plain instructions with no library behind them.
 *
 * ponytail: a spin with no yield and no backoff. The critical sections here are
 * a sixteen-byte compare and copy; if a program ever contends hard enough for
 * that to matter, the upgrade is a platform wait, which changes only these
 * three functions. */
#if defined(__clang__) || defined(__GNUC__)

static volatile int32_t loke_rt_atomic_gate = 0;

static void atomic_lock(void) {
	while (__sync_lock_test_and_set(&loke_rt_atomic_gate, 1) != 0) {
	}
}

static void atomic_unlock(void) { __sync_lock_release(&loke_rt_atomic_gate); }

/* The barrier that makes a fallback operation participate in the same total
 * order the native operations and the fences do, rather than only in the
 * lock's own order. */
static void atomic_barrier(void) { __sync_synchronize(); }

#else
/* A toolchain without those builtins gets the single-threaded behaviour.
 * design.md places concurrent access outside the contract where there is no way
 * to provide it, and a wrong answer that looks atomic would be worse than none.
 */
static void atomic_lock(void) {}
static void atomic_unlock(void) {}
static void atomic_barrier(void) {}
#endif

/* A 128-bit value, moved as bytes so this file needs no 128-bit integer type
 * and no compiler-specific spelling of one. */
enum { LOKE_RT_ATOMIC128_BYTES = 16 };

/* The orderings, matching `runtime.Memory_Order`. Only the two questions the
 * lock protocol asks are read: does this operation acquire, and does it
 * release. */
enum {
	LOKE_RT_ORDER_RELAXED = 0,
	LOKE_RT_ORDER_ACQUIRE = 1,
	LOKE_RT_ORDER_RELEASE = 2,
	LOKE_RT_ORDER_ACQ_REL = 3,
	LOKE_RT_ORDER_SEQ_CST = 4
};

static int32_t order_acquires(int32_t order) {
	return order == LOKE_RT_ORDER_ACQUIRE || order == LOKE_RT_ORDER_ACQ_REL ||
	       order == LOKE_RT_ORDER_SEQ_CST;
}

static int32_t order_releases(int32_t order) {
	return order == LOKE_RT_ORDER_RELEASE || order == LOKE_RT_ORDER_ACQ_REL ||
	       order == LOKE_RT_ORDER_SEQ_CST;
}

static void enter(int32_t order) {
	atomic_lock();
	if (order_acquires(order)) {
		atomic_barrier();
	}
}

static void leave(int32_t order) {
	if (order_releases(order)) {
		atomic_barrier();
	}
	atomic_unlock();
}

/* Little-endian 128-bit arithmetic over the two halves, so the carry and borrow
 * are written once each rather than trusted to a type this file avoids. */
static void read_halves(const void *p, uint64_t *low, uint64_t *high) {
	memcpy(low, (const char *)p, 8);
	memcpy(high, (const char *)p + 8, 8);
}

static void write_halves(void *p, uint64_t low, uint64_t high) {
	memcpy((char *)p, &low, 8);
	memcpy((char *)p + 8, &high, 8);
}

void loke_rt_v1_atomic128_load(const void *address, void *out, int32_t order) {
	enter(order);
	memcpy(out, address, LOKE_RT_ATOMIC128_BYTES);
	leave(order);
}

void loke_rt_v1_atomic128_store(void *address, const void *value, int32_t order) {
	enter(order);
	memcpy(address, value, LOKE_RT_ATOMIC128_BYTES);
	leave(order);
}

void loke_rt_v1_atomic128_exchange(void *address, const void *value, void *out, int32_t order) {
	enter(order);
	memcpy(out, address, LOKE_RT_ATOMIC128_BYTES);
	memcpy(address, value, LOKE_RT_ATOMIC128_BYTES);
	leave(order);
}

/* 1 when it swapped. On failure the observed value is written back through
 * `expected`, which is what a failed compare-exchange has to report; `failure`
 * is the ordering that path takes. */
int32_t loke_rt_v1_atomic128_compare_exchange(
	void *address, void *expected, const void *desired, int32_t success, int32_t failure) {
	int32_t same;
	enter(success);
	same = memcmp(address, expected, LOKE_RT_ATOMIC128_BYTES) == 0;
	if (same) {
		memcpy(address, desired, LOKE_RT_ATOMIC128_BYTES);
		leave(success);
		return 1;
	}
	memcpy(expected, address, LOKE_RT_ATOMIC128_BYTES);
	leave(failure);
	return 0;
}

/* Each read-modify-write writes the *previous* value to `out`, which is what
 * `atomicrmw` answers on the native widths. */
#define LOKE_RT_ATOMIC128_RMW(name, body)                                          \
	void loke_rt_v1_atomic128_##name(                                              \
		void *address, const void *value, void *out, int32_t order) {              \
		uint64_t a_low, a_high, b_low, b_high, r_low, r_high;                      \
		enter(order);                                                              \
		read_halves(address, &a_low, &a_high);                                     \
		read_halves(value, &b_low, &b_high);                                       \
		body                                                                       \
		write_halves(out, a_low, a_high);                                          \
		write_halves(address, r_low, r_high);                                      \
		leave(order);                                                              \
	}

LOKE_RT_ATOMIC128_RMW(add, {
	r_low = a_low + b_low;
	r_high = a_high + b_high + (r_low < a_low ? 1u : 0u);
})

LOKE_RT_ATOMIC128_RMW(sub, {
	r_low = a_low - b_low;
	r_high = a_high - b_high - (a_low < b_low ? 1u : 0u);
})

LOKE_RT_ATOMIC128_RMW(and, {
	r_low = a_low & b_low;
	r_high = a_high & b_high;
})

LOKE_RT_ATOMIC128_RMW(or, {
	r_low = a_low | b_low;
	r_high = a_high | b_high;
})

LOKE_RT_ATOMIC128_RMW(xor, {
	r_low = a_low ^ b_low;
	r_high = a_high ^ b_high;
})

/* The fence the fallback widths order against. Generated code lowers a Loke
 * `fence` to LLVM's own `fence` instruction; this exists so a host, and this
 * file, can reach the same barrier. */
void loke_rt_v1_atomic_fence(int32_t order) {
	(void)order;
	atomic_barrier();
}
