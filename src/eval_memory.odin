// The compile-time evaluator's storage. design.md "Compile-time procedure
// evaluation": the memory limit bounds what an evaluation holds live. A block
// is charged from its allocation until its release, and a released block is
// reused by the next request of its size class instead of growing the arena.
//
// Only the compiler's own code releases. A value the program drops stays charged;
// see comments.md "The evaluator's memory limit counts what it holds".
package lokec

import "base:runtime"
import "core:math/bits"
import "core:mem"
import "core:mem/virtual"

// A larger payload comes from the system heap, so its storage never waits on a
// request of the same size.
@(private = "file")
EVAL_SMALL_LIMIT :: 32 * 1024
// Sixteen classes 16 bytes apart up to 256, then four per doubling to
// `EVAL_SMALL_LIMIT`, each at most a quarter larger than the request.
EVAL_CLASSES :: 16 + 4 * 7
// Payload alignments 16, 32, and 64 each have their own lists. Maps ask for 64.
EVAL_ALIGNMENTS :: 3

@(private = "file")
EVAL_BLOCK_LIVE :: u32(0x4c4f4b45)

// Just before each payload. `state` catches a block released twice, or memory
// that was never the evaluator's, before either corrupts a free list.
@(private = "file")
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
	// What the live blocks cost.
	bytes:      int,
	// A request was refused. Reported outside the allocator, since reporting allocates too.
	exhausted:  bool,
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
	storage := (^Eval_Storage)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return eval_block_alloc(storage, size, alignment, mode == .Alloc)
	case .Resize, .Resize_Non_Zeroed:
		return eval_block_resize(storage, old_memory, old_size, size, alignment, mode == .Resize)
	case .Free:
		eval_block_free(storage, old_memory)
		return nil, nil
	}
	return nil, .Mode_Not_Implemented
}

// The header of the block that serves a request.
@(private = "file")
eval_shape :: proc(request, alignment: int) -> Eval_Block {
	// An empty request takes the smallest class: none would be a negative
	// class, which marks a heap block.
	size := max(request, 1)
	align := max(alignment, 16)
	if size > EVAL_SMALL_LIMIT || align > 64 {
		return Eval_Block{
			capacity = mem.align_forward_int(size, 16),
			pad      = u16(max(align, size_of(Eval_Large) + size_of(Eval_Block))),
			class    = -1,
			state    = EVAL_BLOCK_LIVE,
		}
	}
	class, capacity: int
	if size <= 256 {
		count := (size + 15) / 16
		class, capacity = count - 1, count * 16
	} else {
		// 2^k < size <= 2^(k+1), split into four steps of 2^(k-2).
		k := bits.len_uint(uint(size - 1)) - 1
		step := 1 << uint(k - 2)
		j := (size - (1 << uint(k)) + step - 1) / step
		class, capacity = 16 + (k - 8) * 4 + (j - 1), (1 << uint(k)) + j * step
	}
	shift := align == 16 ? 0 : align == 32 ? 1 : 2
	return Eval_Block{
		capacity = capacity,
		pad      = u16(align),
		class    = i16(class * EVAL_ALIGNMENTS + shift),
		state    = EVAL_BLOCK_LIVE,
	}
}

@(private = "file")
eval_header :: #force_inline proc(payload: rawptr) -> ^Eval_Block {
	return (^Eval_Block)(uintptr(payload) - size_of(Eval_Block))
}

@(private = "file")
eval_out_of_memory :: proc(storage: ^Eval_Storage) -> ([]u8, mem.Allocator_Error) {
	storage.exhausted = true
	return nil, .Out_Of_Memory
}

@(private = "file")
eval_block_alloc :: proc(storage: ^Eval_Storage, size, alignment: int, zeroed: bool) -> ([]u8, mem.Allocator_Error) {
	if storage.exhausted || size < 0 || size > EVAL_MAX_MEMORY || alignment > 32768 {
		return eval_out_of_memory(storage)
	}
	shape := eval_shape(size, alignment)
	cost := int(shape.pad) + shape.capacity
	if cost > EVAL_MAX_MEMORY - storage.bytes {
		return eval_out_of_memory(storage)
	}
	payload: rawptr
	if shape.class >= 0 {
		payload = storage.free_lists[shape.class]
		if payload != nil {
			storage.free_lists[shape.class] = (^rawptr)(payload)^
		}
	}
	if payload == nil {
		allocator := shape.class >= 0 ? virtual.arena_allocator(&storage.arena) : runtime.heap_allocator()
		block, err := mem.alloc_bytes_non_zeroed(cost, int(shape.pad), allocator)
		if err != nil {
			return eval_out_of_memory(storage)
		}
		payload = raw_data(block[shape.pad:])
		if shape.class < 0 {
			link := (^Eval_Large)(raw_data(block))
			link^ = Eval_Large{next = storage.large}
			if storage.large != nil {
				storage.large.prev = link
			}
			storage.large = link
		}
	}
	eval_header(payload)^ = shape
	storage.bytes += cost
	result := ([^]u8)(payload)[:size]
	if zeroed {
		mem.zero_slice(result)
	}
	return result, nil
}

@(private = "file")
eval_block_free :: proc(storage: ^Eval_Storage, payload: rawptr) {
	header := eval_header(payload)
	assert(header.state == EVAL_BLOCK_LIVE, "compile-time storage released twice, or never allocated there")
	header.state = 0
	storage.bytes -= int(header.pad) + header.capacity
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

// Growth within a class stays in place and costs nothing.
@(private = "file")
eval_block_resize :: proc(
	storage: ^Eval_Storage, old_memory: rawptr, old_size, size, alignment: int, zeroed: bool,
) -> ([]u8, mem.Allocator_Error) {
	header := eval_header(old_memory)
	assert(header.state == EVAL_BLOCK_LIVE, "compile-time storage resized after its release")
	kept := min(old_size, size)
	old := ([^]u8)(old_memory)
	result: []u8
	if size >= 0 && eval_shape(size, alignment) == header^ {
		result = old[:size]
	} else {
		err: mem.Allocator_Error
		result, err = eval_block_alloc(storage, size, alignment, false)
		if err != nil {
			return nil, err
		}
		copy(result, old[:kept])
		eval_block_free(storage, old_memory)
	}
	if zeroed {
		mem.zero_slice(result[kept:])
	}
	return result, nil
}
