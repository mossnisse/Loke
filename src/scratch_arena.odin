// The per-body scratch arenas (compiler-architecture.md "Allocation domains"):
// one reserved range each, pages committed as first used and kept committed
// across resets. Only the thread checking a compilation allocates in its
// arenas, so unlike Odin's virtual arena this one takes no lock per
// allocation, which cost about a tenth of each provenance graph build.
package lokec

import "core:mem"
import "core:mem/virtual"

Scratch_Arena :: struct {
	base:       [^]byte,
	reserved:   uint,
	committed:  uint,
	// Bytes handed out since the last reset; everything past them is zero.
	total_used: uint,
}

// Committed at least this much at a time, so a growing body does not commit
// page by page.
@(private = "file")
SCRATCH_COMMIT_STEP :: mem.Megabyte

scratch_arena_init :: proc(arena: ^Scratch_Arena, reserved: uint) -> mem.Allocator_Error {
	data := virtual.reserve(reserved) or_return
	arena^ = {base = raw_data(data), reserved = len(data)}
	return nil
}

scratch_arena_destroy :: proc(arena: ^Scratch_Arena) {
	if arena.base != nil {
		virtual.release(arena.base, arena.reserved)
	}
	arena^ = {}
}

scratch_allocator :: proc(arena: ^Scratch_Arena) -> mem.Allocator {
	return {procedure = scratch_allocator_proc, data = arena}
}

// Zeroes what was used, so every allocation after it starts zeroed, as one
// from fresh pages does.
scratch_arena_reset :: proc(arena: ^Scratch_Arena) {
	mem.zero(arena.base, int(arena.total_used))
	arena.total_used = 0
}

@(private = "file")
scratch_alloc :: proc(arena: ^Scratch_Arena, size, alignment: uint) -> (data: []byte, err: mem.Allocator_Error) {
	if size == 0 {
		return nil, nil
	}
	// The reservation is page-aligned, so aligning the offset aligns the address.
	assert(alignment <= uint(mem.PAGE_SIZE) && alignment & (alignment - 1) == 0, "unsupported scratch alignment")
	start := mem.align_forward_uint(arena.total_used, alignment)
	scratch_commit(arena, start + size) or_return
	arena.total_used = start + size
	return arena.base[start:][:size], nil
}

@(private = "file")
scratch_commit :: proc(arena: ^Scratch_Arena, end: uint) -> mem.Allocator_Error {
	if end <= arena.committed {
		return nil
	}
	// The growing virtual arena chained another block here; `make` and `append`
	// would swallow an error, so a body this large stops the compilation.
	if end > arena.reserved {
		panic("a procedure body's analysis outgrew its scratch arena reservation")
	}
	target := mem.align_forward_uint(max(end, arena.committed + SCRATCH_COMMIT_STEP), uint(mem.PAGE_SIZE))
	target = min(target, arena.reserved)
	virtual.commit(arena.base[arena.committed:], target - arena.committed) or_return
	arena.committed = target
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
		// The latest allocation grows in place; the bytes past it are zero.
		start := uint(uintptr(old_memory) - uintptr(arena.base))
		if aligned && start + uint(old_size) == arena.total_used {
			scratch_commit(arena, start + uint(size)) or_return
			arena.total_used = start + uint(size)
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
