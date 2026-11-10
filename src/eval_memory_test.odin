// The compile-time evaluator's allocator at the edges of the allocator contract.
package lokec

import "core:mem"
import "core:testing"

@(test)
eval_allocator_handles_nil_and_empty_requests :: proc(t: ^testing.T) {
	storage: Eval_Storage
	defer eval_storage_destroy(&storage)
	alloc := mem.Allocator{eval_allocator_proc, &storage}

	// Freeing nothing is a no-op.
	_, freed := alloc.procedure(alloc.data, .Free, 0, 16, nil, 0)
	testing.expect_value(t, freed, mem.Allocator_Error.None)
	testing.expect_value(t, storage.bytes, 0)

	// Resizing nothing allocates.
	grown, resized := alloc.procedure(alloc.data, .Resize, 24, 16, nil, 0)
	testing.expect_value(t, resized, mem.Allocator_Error.None)
	testing.expect_value(t, len(grown), 24)
	testing.expect(t, storage.bytes > 0, "a resized nil was not charged")
	alloc.procedure(alloc.data, .Free, 0, 16, raw_data(grown), len(grown))
	testing.expect_value(t, storage.bytes, 0)

	// An empty request takes a block of the smallest class, which releases cleanly.
	empty, allocated := alloc.procedure(alloc.data, .Alloc, 0, 16, nil, 0)
	testing.expect_value(t, allocated, mem.Allocator_Error.None)
	testing.expect(t, raw_data(empty) != nil, "an empty request got no block")
	alloc.procedure(alloc.data, .Free, 0, 16, raw_data(empty), 0)
	testing.expect_value(t, storage.bytes, 0)
}
