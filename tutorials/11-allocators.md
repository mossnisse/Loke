# Choosing an allocator

Containers already manage their own cleanup. An allocator chooses where their
backing storage comes from; it does not change who owns the values. The default
is the system heap unless the application selects another provider.

This page uses the borrowing rules from
[Borrowing and lifetimes](08-borrowing-and-lifetimes.md) to manage temporary
storage in batches.

## Pass the storage choice

Use an `Allocator` parameter when the caller should choose where a result lives:

```odin file=allocator_results.loke
package main;

import "core:fmt";
import "core:mem";

squares :: proc(count: int, allocator: Allocator) -> [dynamic]int {
	result: [dynamic]int via allocator = {};
	foreach (i in 0 ..< count) { result.append(i * i); }
	return result;
}

main :: proc() {
	heap_values := squares(4, mem.default_allocator());
	fmt.println(heap_values);

	buffer: [4096]u8 = {};
	arena := mem.Arena.from_buffer(buffer[:]);
	{
		local_values := squares(5, arena.allocator());
		fmt.println(local_values);
	}
	free_all(arena.allocator());
	fmt.println("arena reset");
}
```

```text output=allocator_results
[0, 1, 4, 9]
[0, 1, 4, 9, 16]
arena reset
```

`via allocator` binds the dynamic array to that allocator, including future
growth. Returning it transfers the owner to the caller and preserves its
allocator dependency. The heap-backed result may outlive the local arena;
`local_values` may not.

`Arena.from_buffer` borrows a fixed buffer and uses part of it for bookkeeping,
so not all 4096 bytes are available to values. It cannot grow past that buffer.
`Arena.init()` instead obtains backing blocks from a parent allocator, which
defaults to the program's allocator.

## Reuse scratch storage

A scratch region is useful when each batch needs temporary containers that
should all be discarded together:

```odin file=scratch_batches.loke
package main;

import "core:fmt";
import "core:mem";

batch_sum :: proc(start: int, allocator: Allocator) -> int {
	values: [dynamic]int via allocator = {};
	foreach (offset in 0 ..< 3) { values.append(start + offset); }
	total := 0;
	foreach (value in values) { total += value; }
	return total;
}

main :: proc() {
	scratch := mem.Scratch.init();
	foreach (batch in 0 ..< 3) {
		fmt.println(batch_sum(batch * 10, scratch.allocator()));
		free_all(scratch.allocator());
	}
}
```

```text output=scratch_batches
3
33
63
```

The array in `batch_sum` is dropped before the call returns. The returned
integer carries no storage dependency, so the caller can reset the region.
`free_all` invalidates its allocations while leaving the region usable for
another batch. The scratch owner itself is dropped when `main` ends.

## Reset only after dependent owners are gone

A container still needs its allocator for cleanup, even if you are done reading
its elements. Put it in an inner scope, as in the first example, or explicitly
`drop` it before resetting its region. This is rejected:

```odin file=early_reset.loke
package main;

import "core:fmt";
import "core:mem";

main :: proc() {
	arena := mem.Arena.init();
	values: [dynamic]int via arena.allocator() = {};
	values.append(7);
	free_all(arena.allocator());
	fmt.println(values);
}
```

```text error=early_reset
error[L0537]: this reset would end the region backing `values`, which is still live here
  --> early_reset.loke:10:2
    |
10 | 	free_all(arena.allocator());
    | 	^^^^^^^^^^^^^^^^^^^^^^^^^^^
  = note: early_reset.loke:8:2: `values` is declared here and is cleaned up after this point
```

Similarly, a procedure cannot return a container backed by its own local
arena. Take an allocator parameter, as `squares` does, or build the result
with the default allocator. Returning `move(result)` does not extend the
arena's lifetime.

## Handle allocation failure when it is recoverable

Ordinary `append` follows the allocator's failure policy, usually a panic.
Its `try_` counterpart returns a `Result` instead:

```odin file=bounded_allocation.loke
package main;

import "core:fmt";
import "core:mem";

main :: proc() {
	buffer: [4096]u8 = {};
	arena := mem.Arena.from_buffer(buffer[:]);
	values: [dynamic]u8 via arena.allocator() = {};
	switch (_ in values.try_reserve(8192)) {
	case .ok: fmt.println("reserved");
	case .err: fmt.println("buffer is too small");
	}
	fmt.println("length:", values.len());
}
```

```text output=bounded_allocation
buffer is too small
length: 0
```

The failure is deterministic: an 8192-byte reservation cannot fit in the
4096-byte region. The container stays valid after failure. `mem.try_arena`
and `mem.try_scratch` provide fallible construction of provider-backed regions.

Strings share immutable storage when copied, so they do not use `via`.
String-producing library procedures take an allocator argument instead.
Copying an `Allocator` handle selects the same provider; it neither copies
the region nor keeps it alive beyond its owner.

[design.md "Allocators"](../design.md#allocators) gives the allocation and
region rules. [Allocator providers](14-allocator-providers.md) later selects
the default for a complete application.

Next: [Owning resources](12-owning-resources.md).
