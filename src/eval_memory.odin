// The compile-time evaluator's storage. design.md "Compile-time procedure
// evaluation": the memory limit bounds what an evaluation holds live. A block
// is charged from its allocation until its release, and a released block is
// reused by the next request of its size class instead of growing the arena.
//
// Only the compiler's own code releases: core:math/big's temporaries and the
// results it shrinks (bigint.odin), the evaluator's frames and scratch arrays,
// and Odin's containers as they grow. Values the evaluated program drops are
// not tracked, since copies share their digits and elements, so they stay
// charged until evaluation ends.
package lokec

import "base:runtime"
import "core:math/bits"
import "core:mem"
import "core:mem/virtual"

// A payload up to this size comes in a size class from the arena and returns to
// its class's free list; a larger one comes from the system heap and returns to
// it, so a large block's storage never waits on a request of the same size.
EVAL_SMALL_LIMIT :: 32 * 1024
// Sixteen classes 16 bytes apart up to 256, then four per doubling to
// `EVAL_SMALL_LIMIT`, each at most a quarter larger than the request.
EVAL_CLASSES :: 16 + 4 * 7
// Payload alignments 16, 32, and 64 each have their own lists. Maps ask for 64.
EVAL_ALIGNMENTS :: 3

EVAL_BLOCK_LIVE :: u32(0x4c4f4b45)
EVAL_BLOCK_FREE :: u32(0x46524545)

// Just before each payload. `state` catches a block released twice, or memory
// that was never the evaluator's, before either corrupts a free list.
Eval_Block :: struct {
	capacity: int,
	// Bytes from the block's start to its payload, this header included.
	pad:      u16,
	// A free list's index, or -1 for a block from the heap.
	class:    i16,
	state:    u32,
}
#assert(size_of(Eval_Block) == 16)

// At the start of a heap block, so `eval_storage_destroy` can release what
// evaluation still holds.
Eval_Large :: struct {
	prev, next: ^Eval_Large,
}

Eval_Storage :: struct {
	arena:      virtual.Arena,
	free_lists: [EVAL_CLASSES * EVAL_ALIGNMENTS]rawptr,
	large:      ^Eval_Large,
}

eval_storage_init :: proc(storage: ^Eval_Storage) -> mem.Allocator_Error {
	return virtual.arena_init_growing(&storage.arena)
}

eval_storage_destroy :: proc(storage: ^Eval_Storage) {
	for link := storage.large; link != nil; {
		next := link.next
		mem.free(link, runtime.heap_allocator())
		link = next
	}
	storage.large = nil
	virtual.arena_destroy(&storage.arena)
}

// Whether integers built in `storage` are charged to an evaluation.
is_eval_storage :: proc(storage: Value_Storage) -> bool {
	allocator, is_allocator := storage.(mem.Allocator)
	return is_allocator && allocator.procedure == eval_allocator_proc
}

eval_allocator_proc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location,
) -> ([]u8, mem.Allocator_Error) {
	ev := (^Evaluator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return eval_block_alloc(ev, size, alignment, mode == .Alloc)
	case .Resize, .Resize_Non_Zeroed:
		return eval_block_resize(ev, old_memory, old_size, size, alignment, mode == .Resize)
	case .Free:
		eval_block_free(ev, old_memory)
		return nil, nil
	case .Query_Features:
		if features := (^mem.Allocator_Mode_Set)(old_memory); features != nil {
			features^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
	}
	return nil, .Mode_Not_Implemented
}

// Where a request is served: a free list's index and the class's capacity, or
// `class == -1` and a capacity of its own for the heap.
@(private = "file")
Eval_Shape :: struct {
	class:    int,
	capacity: int,
	pad:      int,
}

@(private = "file")
eval_shape :: proc(size, alignment: int) -> Eval_Shape {
	align := max(alignment, 16)
	if size > EVAL_SMALL_LIMIT || align > 64 {
		return Eval_Shape{class = -1, capacity = mem.align_forward_int(size, 16), pad = max(align, size_of(Eval_Large) + size_of(Eval_Block))}
	}
	class, capacity: int
	if size <= 256 {
		count := max((size + 15) / 16, 1)
		class, capacity = count - 1, count * 16
	} else {
		// 2^k < size <= 2^(k+1), split into four steps of 2^(k-2).
		k := bits.len_uint(uint(size - 1)) - 1
		step := 1 << uint(k - 2)
		j := (size - (1 << uint(k)) + step - 1) / step
		class, capacity = 16 + (k - 8) * 4 + (j - 1), (1 << uint(k)) + j * step
	}
	shift := align == 16 ? 0 : align == 32 ? 1 : 2
	return Eval_Shape{class = class * EVAL_ALIGNMENTS + shift, capacity = capacity, pad = 16 << uint(shift)}
}

@(private = "file")
eval_header :: #force_inline proc(payload: rawptr) -> ^Eval_Block {
	return (^Eval_Block)(uintptr(payload) - size_of(Eval_Block))
}

@(private = "file")
eval_block_alloc :: proc(ev: ^Evaluator, size, alignment: int, zeroed: bool) -> ([]u8, mem.Allocator_Error) {
	if ev.memory_error != nil || size < 0 || size > EVAL_MAX_MEMORY || alignment > 32768 ||
	   !mem.is_power_of_two(uintptr(max(alignment, 1))) {
		ev.memory_error = .Out_Of_Memory
		return nil, .Out_Of_Memory
	}
	shape := eval_shape(size, alignment)
	cost := shape.pad + shape.capacity
	if cost > EVAL_MAX_MEMORY - ev.bytes {
		ev.memory_error = .Out_Of_Memory
		return nil, .Out_Of_Memory
	}
	storage := &ev.storage
	payload: [^]u8
	if shape.class >= 0 {
		if head := storage.free_lists[shape.class]; head != nil {
			storage.free_lists[shape.class] = (^rawptr)(head)^
			payload = ([^]u8)(head)
		} else {
			block, err := mem.alloc_bytes_non_zeroed(cost, shape.pad, virtual.arena_allocator(&storage.arena))
			if err != nil {
				ev.memory_error = err
				return nil, err
			}
			payload = ([^]u8)(raw_data(block))[shape.pad:]
		}
	} else {
		block, err := mem.alloc_bytes_non_zeroed(cost, max(alignment, 16), runtime.heap_allocator())
		if err != nil {
			ev.memory_error = err
			return nil, err
		}
		link := (^Eval_Large)(raw_data(block))
		link^ = Eval_Large{next = storage.large}
		if storage.large != nil {
			storage.large.prev = link
		}
		storage.large = link
		payload = ([^]u8)(raw_data(block))[shape.pad:]
	}
	eval_header(payload)^ = Eval_Block{
		capacity = shape.capacity,
		pad      = u16(shape.pad),
		class    = i16(shape.class),
		state    = EVAL_BLOCK_LIVE,
	}
	ev.bytes += cost
	if zeroed {
		mem.zero(payload, size)
	}
	return payload[:size], nil
}

@(private = "file")
eval_block_free :: proc(ev: ^Evaluator, payload: rawptr) {
	if payload == nil {
		return
	}
	header := eval_header(payload)
	assert(header.state == EVAL_BLOCK_LIVE, "compile-time storage released twice, or never allocated there")
	header.state = EVAL_BLOCK_FREE
	ev.bytes -= int(header.pad) + header.capacity
	storage := &ev.storage
	if header.class >= 0 {
		(^rawptr)(payload)^ = storage.free_lists[header.class]
		storage.free_lists[header.class] = payload
		return
	}
	link := (^Eval_Large)(uintptr(payload) - uintptr(header.pad))
	if link.prev != nil {
		link.prev.next = link.next
	} else {
		storage.large = link.next
	}
	if link.next != nil {
		link.next.prev = link.prev
	}
	mem.free(link, runtime.heap_allocator())
}

// In place when the new size keeps the block's shape, so growth within a class
// costs nothing; otherwise a new block, and the old one is released.
@(private = "file")
eval_block_resize :: proc(
	ev: ^Evaluator, old_memory: rawptr, old_size, size, alignment: int, zeroed: bool,
) -> ([]u8, mem.Allocator_Error) {
	if old_memory == nil {
		return eval_block_alloc(ev, size, alignment, zeroed)
	}
	if size == 0 {
		eval_block_free(ev, old_memory)
		return nil, nil
	}
	header := eval_header(old_memory)
	assert(header.state == EVAL_BLOCK_LIVE, "compile-time storage resized after its release")
	kept := clamp(old_size, 0, min(size, header.capacity))
	old := ([^]u8)(old_memory)
	if size >= 0 && size <= EVAL_MAX_MEMORY {
		shape := eval_shape(size, alignment)
		if shape.class == int(header.class) && shape.capacity == header.capacity && shape.pad == int(header.pad) {
			if zeroed && size > kept {
				mem.zero(old[kept:], size - kept)
			}
			return old[:size], nil
		}
	}
	block, err := eval_block_alloc(ev, size, alignment, false)
	if err != nil {
		return nil, err
	}
	copy(block, old[:kept])
	if zeroed && size > kept {
		mem.zero(raw_data(block[kept:]), size - kept)
	}
	eval_block_free(ev, old_memory)
	return block, nil
}
