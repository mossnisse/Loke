# Owning resources

Memory is only one kind of resource. Files and other handles also need one
owner, a defined cleanup operation, and a clear way to transfer responsibility.
This page uses a file to make those transitions visible.

## A pointer is not automatically an owner

`&value` borrows existing storage. `new(T)` allocates storage that must be
released explicitly or placed under an owning wrapper:

```odin file=explicit_allocation.loke
package main;

import "core:fmt";

main :: proc() {
	cell := new(int);
	defer free(cell);
	cell^ = 42;
	fmt.println(cell^);
}
```

```text output=explicit_allocation
42
```

`new(int)` starts with the zero value and returns a `^mut int`. The `defer`
releases that allocation at scope exit. Passing an allocator to `new` requires
using the same allocator for `free`. Pointers made with `&` or `&mut` cannot be
freed: they borrow storage owned elsewhere.

Ordinary containers already supply ownership and cleanup, so use them when
they fit. A raw allocation is useful when an API specifically requires it.

## Make a resource move-only

A file cannot be copied like an array: two owners of one native handle would
both try to close it. `fs.File` is therefore move-only. A wrapper containing it
is also move-only; spelling `move_only` makes that intent explicit.

Save this input as `tracked_input.txt`:

```text file=tracked_input.txt
some input
```

```odin file=owned_resource.loke
package main;

import "core:fmt";
import "core:fs";
import "core:io";

Tracked_File :: move_only struct {
	name: string,
	file: fs.File,
}

impl Tracked_File {
	open :: proc(path: string) -> Result(Tracked_File, io.Error) {
		file := fs.open_read(path) or_return;
		fmt.println("opened", path);
		return .ok({path, move(file)});
	}

	close :: proc(self: inout) -> Result(Unit, io.Error) {
		if (!self.file.is_open()) { return .ok; }
		self.file.close() or_return;
		fmt.println("closed", self.name);
		return .ok;
	}

	release :: hook(drop) proc(self: inout Tracked_File) {
		_ = self.close();
	}
}

Problem :: enum { Cancelled }

process :: proc(input: move Tracked_File, cancel: bool) -> Result(Unit, Problem) {
	fmt.println("processing", input.name);
	if (cancel) { return .err(.Cancelled); }
	return .ok;
}

main :: proc() {
	file := Tracked_File.open("tracked_input.txt") or_else panic("cannot open input");
	switch (_ in process(move(file), true)) {
	case .ok: fmt.println("done");
	case .err: fmt.println("cancelled");
	}

	other := Tracked_File.open("tracked_input.txt") or_else panic("cannot reopen input");
	_ = other.close() or_else panic("close failed");
	fmt.println("explicit close complete");
	// The zero value must also be safe to drop.
	empty: Tracked_File = {};
}
```

```text output=owned_resource
opened tracked_input.txt
processing tracked_input.txt
closed tracked_input.txt
cancelled
opened tracked_input.txt
closed tracked_input.txt
explicit close complete
```

`process(move(file), true)` transfers ownership into the parameter. `file`
cannot be read afterwards. The early return drops `input` before the caller
handles the error, so `closed` appears before `cancelled`.

An ordinary parameter would only borrow the file for the call. Use a `move`
parameter when the procedure must consume it, keep it, or hand it to another
owner. Move-only values cannot be cloned; a second independent file requires
opening it again.

## Cleanup hooks and explicit close

`hook(drop)` marks the procedure that runs when a live owner is dropped. Its
name, `release` here, is not special. After the hook, fields are dropped in
reverse declaration order. The wrapped `fs.File` is already closed at that
point, so its own cleanup has nothing left to release.

The hook must tolerate the zero value and should not fail. Here it discards a
close error deliberately because implicit cleanup cannot return a `Result`.
When success depends on observing a close or flush error, call the explicit
fallible operation before leaving scope, as `other.close()` does.

Calling `drop(owner)` runs cleanup early and leaves the variable dead. Calling
`owner.close()` is an ordinary method; this implementation leaves a live but
closed value whose later drop is harmless. Moving an owner transfers its
future cleanup to the destination instead of running it immediately.

The default panic strategy also runs local cleanup; an aborting panic does
not. The [Errors lesson](05-errors.md#panics) explains the distinction.

Custom copy hooks are only needed for resources that have a meaningful,
independent clone. [design.md "Lifecycle hooks and resource types"](../design.md#lifecycle-hooks-and-resource-types)
specifies their allocator and failure contracts. A unique handle normally
stays move-only.

Next: [Calling C](13-calling-c.md).
