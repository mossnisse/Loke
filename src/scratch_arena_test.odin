package lokec

import "core:mem"
import "core:slice"
import "core:testing"

// The analysis arenas hand out zeroed memory, as the virtual arena they replace
// did: maps and `new` rely on it. A reset zeroes what was used, so memory
// reused after it starts zeroed too, and an allocation grown in place reads
// zero past its old end.
@(test)
scratch_arena_hands_out_zeroed_memory :: proc(t: ^testing.T) {
	arena: Scratch_Arena
	testing.expect_value(t, scratch_arena_init(&arena, 64 * mem.Megabyte), nil)
	defer scratch_arena_destroy(&arena)
	allocator := scratch_allocator(&arena)

	first := make([]u8, 100, allocator)
	slice.fill(first, 0xAB)
	testing.expect_value(t, arena.total_used, uint(100))
	free_all(allocator)
	testing.expect_value(t, arena.total_used, uint(0))
	again := make([]u8, 100, allocator)
	testing.expect(t, raw_data(again) == raw_data(first), "a reset does not reuse its pages")
	testing.expect(t, slice.all_of(again, 0), "memory reused after a reset is not zeroed")

	// The latest allocation grows in place; an earlier one is copied.
	grown := make([dynamic]u8, 0, 8, allocator)
	append(&grown, 1, 2, 3)
	before := raw_data(grown)
	reserve(&grown, 64)
	testing.expect(t, raw_data(grown) == before, "the latest allocation did not grow in place")
	testing.expect(t, slice.all_of(([^]u8)(raw_data(grown))[3:cap(grown)], 0), "growth in place is not zeroed")
	_ = make([]u8, 1, allocator)
	reserve(&grown, 128)
	testing.expect(t, raw_data(grown) != before, "an allocation that is no longer the latest grew over its successor")
	testing.expect(t, slice.equal(grown[:], []u8{1, 2, 3}), "a moved allocation lost its contents")

	// Growth past the first commit commits more, and alignment is kept.
	large := make([]u64, 512 * 1024, allocator)
	testing.expect(t, uintptr(raw_data(large)) % align_of(u64) == 0, "an allocation is misaligned")
	testing.expect(t, arena.committed >= arena.total_used, "used memory is not committed")
	large[len(large) - 1] = 7
	testing.expect_value(t, large[len(large) - 1], u64(7))
}
