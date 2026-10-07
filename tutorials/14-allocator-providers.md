# Allocator providers

[Choosing an allocator](11-allocators.md) passed storage choices explicitly.
An application can also select the provider used by default throughout the
program. This is useful for a deliberately bounded application or an embedding
environment with its own storage policy.

Start with an existing arena. It supplies the allocation machinery; this page
supplies the provider's lifetime and startup factory.

## A bounded default allocator

Create these files:

```text
bounded_app/
    main.loke
    storage/
        storage.loke
```

**`bounded_app/storage/storage.loke`**

```odin file=bounded_app/storage/storage.loke
package storage;

import "core:mem";

buffer: static [65536]u8 = {};
region: static mem.Arena = {};

@(public)
allocator_factory :: proc() -> Allocator {
	region = mem.Arena.from_buffer(&mut buffer[:]);
	return region.allocator();
}
```

**`bounded_app/main.loke`**

```odin file=bounded_app/main.loke
@(default_allocator = "./storage:allocator_factory")
package main;

import "core:fmt";

main :: proc() {
	values: [dynamic]u8 = {};
	values.append(1, 2, 3);
	fmt.println(values);
	switch (values.try_reserve(131072)) {
	case .ok: fmt.println("reserved");
	case .err: fmt.println("default region is too small");
	}
	fmt.println("still valid:", values);
}
```

Build the directory from its parent:

```powershell
lokec bounded_app -o bounded_app.exe
.\bounded_app.exe
```

```text output=bounded_app
[1, 2, 3]
default region is too small
still valid: [1, 2, 3]
```

No `via` is written on `values`: its first allocation uses the selected
default. A 131072-byte reservation cannot fit in the 65536-byte backing buffer,
so the fallible operation reports failure and preserves the existing values.
Bookkeeping and earlier allocations also consume space in that buffer.

## Why the provider is static

`static` storage lasts for the process. Both the buffer and the arena owner
must outlive every allocation made through the returned handle. A factory
that returned a local arena's handle would leave a dangling provider after
the factory returned.

The compiler invokes the public, zero-argument factory once before `main`.
The package attribute makes `storage` a dependency even though `main` does
not import it. Do not call the factory again to get the allocator: use
`mem.default_allocator()` after startup.

Only the root package selects the default. Importing a library cannot replace
it. Libraries that need a specific region should take an explicit allocator
parameter, as in the earlier lesson.

## Know the limits of a fixed arena

This example is a bounded, single-threaded program. An arena does not reclaim
each container's old buffer for arbitrary reuse when it is individually freed;
repeated growth can consume the region. A process-wide arena is therefore not
a general replacement for the heap. Prefer a local arena or scratch owner for
repeatable batches, and reset it only after its dependents are gone.

Default allocation failures still follow the provider's failure policy. Use
`try_` operations when the program can recover; merely selecting a small
provider does not turn every allocation into a recoverable operation.

Static owners do not receive ordinary scope-exit cleanup at process exit. That
is sufficient for this buffer-backed example, which owns no external resource.
Providers used across threads must also support the required synchronization
and deallocation behavior.

## Implementing different allocation machinery

Selecting a provider and implementing its allocation algorithm are separate
tasks. The public `core:mem` surface supplies arenas and scratch regions; a
new algorithm currently integrates through the runtime ABI. The authoritative
callback and record layouts are in [runtime/loke_rt.h](../runtime/loke_rt.h).

A provider implementation must honor requested sizes and alignments, keep
existing storage valid when a resize fails, and keep its state and callback
record alive while any allocation uses it. Its region identity and failure
policy must agree with the runtime contract. An `Allocator` is a provider
handle, not a pointer that can be fabricated from an arbitrary record.

Use the built-in providers unless those requirements call for different
machinery. [design.md "Build-selected providers"](../design.md#build-selected-providers)
specifies selection and initialization; implementing a new runtime allocator
also requires the C and unchecked-code knowledge from the preceding lesson.

Next: [Reflection and formatting](15-reflection-and-formatting.md).
