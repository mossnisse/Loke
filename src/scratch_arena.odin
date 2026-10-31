// The per-body scratch arenas (compiler-architecture.md "Allocation domains"):
// one reserved range each, pages committed as first used and kept committed
// across resets. Only the thread checking a compilation allocates in its
// arenas, so unlike Odin's virtual arena this one takes no lock per
// allocation, which cost about a tenth of each provenance graph build.
//
// A body that outgrows the range chains another, as Odin's growing virtual
// arena does. Earlier ranges stay reserved, so what they handed out stays
// valid, until the next reset releases every range but the first.
package lokec

import "core:mem"
import "core:mem/virtual"

Scratch_Block :: struct {
	base:      [^]byte,
	reserved:  uint,
	committed: uint,
	// Bytes handed out from this range since the last reset; everything past
	// them is zero.
	used:      uint,
	// The range this one was chained after, recorded at this one's start; nil
	// for the first.
	prev:      ^Scratch_Block,
}

Scratch_Arena :: struct {
	using current: Scratch_Block,
	// Bytes handed out from the ranges before the current one.
	earlier_used:  uint,
	// What each chained range reserves at least.
	block_reserve: uint,
}

// Committed at least this much at a time, so a growing body does not commit
// page by page.
@(private = "file")
SCRATCH_COMMIT_STEP :: mem.Megabyte

scratch_arena_init :: proc(arena: ^Scratch_Arena, reserved: uint) -> mem.Allocator_Error {
	data := virtual.reserve(reserved) or_return
	arena^ = {current = {base = raw_data(data), reserved = len(data)}, block_reserve = len(data)}
	return nil
}

scratch_arena_destroy :: proc(arena: ^Scratch_Arena) {
	scratch_release_chained(arena)
	if arena.base != nil {
		virtual.release(arena.base, arena.reserved)
	}
	arena^ = {}
}

scratch_allocator :: proc(arena: ^Scratch_Arena) -> mem.Allocator {
	return {procedure = scratch_allocator_proc, data = arena}
}

// Bytes handed out since the last reset, across every range.
scratch_arena_used :: proc(arena: ^Scratch_Arena) -> uint {
	return arena.earlier_used + arena.used
}

// Releases the chained ranges and zeroes what was used of the first, so every
// allocation after it starts zeroed, as one from fresh pages does.
scratch_arena_reset :: proc(arena: ^Scratch_Arena) {
	scratch_release_chained(arena)
	mem.zero(arena.base, int(arena.used))
	arena.used = 0
}

// Makes the first range current again, releasing every range after it.
@(private = "file")
scratch_release_chained :: proc(arena: ^Scratch_Arena) {
	for arena.prev != nil {
		// The record lives in the range being released.
		earlier := arena.prev^
		virtual.release(arena.base, arena.reserved)
		arena.current = earlier
	}
	arena.earlier_used = 0
}

@(private = "file")
scratch_alloc :: proc(arena: ^Scratch_Arena, size, alignment: uint) -> (data: []byte, err: mem.Allocator_Error) {
	if size == 0 {
		return nil, nil
	}
	// Each reservation is page-aligned, so aligning the offset aligns the address.
	assert(alignment <= uint(mem.PAGE_SIZE) && alignment & (alignment - 1) == 0, "unsupported scratch alignment")
	start := mem.align_forward_uint(arena.used, alignment)
	end := start + size
	if end > arena.committed {
		if end > arena.reserved {
			return scratch_alloc_chained(arena, size, alignment)
		}
		scratch_commit(&arena.current, end) or_return
	}
	arena.used = end
	return arena.base[start:][:size], nil
}

// Chains a range large enough for the allocation and hands it out from there.
@(private = "file", cold)
scratch_alloc_chained :: proc(arena: ^Scratch_Arena, size, alignment: uint) -> (data: []byte, err: mem.Allocator_Error) {
	start := mem.align_forward_uint(size_of(Scratch_Block), alignment)
	end := start + size
	reservation := virtual.reserve(max(arena.block_reserve, mem.align_forward_uint(end, uint(mem.PAGE_SIZE)))) or_return
	block := Scratch_Block{base = raw_data(reservation), reserved = len(reservation)}
	if err = scratch_commit(&block, end); err != nil {
		virtual.release(block.base, block.reserved)
		return nil, err
	}
	record := (^Scratch_Block)(block.base)
	record^ = arena.current
	block.prev = record
	block.used = end
	arena.earlier_used += arena.used
	arena.current = block
	return block.base[start:][:size], nil
}

@(private = "file")
scratch_commit :: proc(block: ^Scratch_Block, end: uint) -> mem.Allocator_Error {
	if end <= block.committed {
		return nil
	}
	assert(end <= block.reserved, "scratch commit past its reservation")
	target := mem.align_forward_uint(max(end, block.committed + SCRATCH_COMMIT_STEP), uint(mem.PAGE_SIZE))
	target = min(target, block.reserved)
	virtual.commit(block.base[block.committed:], target - block.committed) or_return
	block.committed = target
	return nil
}

@(private = "file")
scratch_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (data: []byte, err: mem.Allocator_Error) {
	arena := (^Scratch_Arena)(allocator_data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return scratch_alloc(arena, uint(size), uint(alignment))
	case .Free:
		return nil, .Mode_Not_Implemented
	case .Free_All:
		scratch_arena_reset(arena)
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return scratch_alloc(arena, uint(size), uint(alignment))
		}
		old := ([^]byte)(old_memory)
		if size == old_size {
			return old[:size], nil
		}
		if size == 0 {
			return nil, .Mode_Not_Implemented
		}
		aligned := uintptr(old_memory) & uintptr(alignment - 1) == 0
		if aligned && size < old_size {
			return old[:size], nil
		}
		// The latest allocation grows in place while its range has room; the
		// bytes past it are zero. One from an earlier range lies outside the
		// current one, so its offset wraps past `reserved`.
		start := uint(uintptr(old_memory) - uintptr(arena.base))
		end := start + uint(size)
		if aligned && start < arena.reserved && start + uint(old_size) == arena.used && end <= arena.reserved {
			scratch_commit(&arena.current, end) or_return
			arena.used = end
			return old[:size], nil
		}
		data = scratch_alloc(arena, uint(size), uint(alignment)) or_return
		copy(data, old[:old_size])
		return data, nil
	case .Query_Features:
		if set := (^mem.Allocator_Mode_Set)(old_memory); set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free_All, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
