# Loke language design

This document specifies the Loke programming language.

# File format

A Loke source file must use UTF-8 without a byte order mark (BOM). UTF-8 lets a source file contain Unicode text in comments and literals.

# Code blocks

A code block uses braces (`{}`). The block creates a scope for its local variables.

## Statements

Most statements end with a semicolon (`;`). A statement does not need a semicolon when its outermost form ends with a declaration block or a statement block.

Thus, the closing `}` terminates these forms:

- `if`, `for`, `foreach`, `switch`, and `when`
- a block and a deferred block statement
- procedure, record, interface, procedure-group, and brace-bodied operator definitions
- top-level `impl`, `extend`, and `foreign` blocks

An expression statement always needs a semicolon. This rule also applies when the expression ends with a composite literal such as `Point{1, 2}`. The braces of a composite literal are part of a value, not a declaration block or statement block.

A single `;` is an empty statement. Empty statements are also valid at file scope. Therefore, the compiler accepts a semicolon after a brace-bodied form as a separate empty statement:

```odin
Foo :: struct {}
Bar :: struct {};   // the trailing `;` is a separate empty declaration
x :: Point{1, 2};   // a composite-literal expression still needs `;`
```

Newlines do not terminate statements. The compiler does not insert semicolons.

## Control-flow headers

Each control-flow statement (`if`, `for`, `foreach`, `switch`, and `when`) has a header in parentheses. Its body is in braces. A control-flow statement cannot have an unbraced body.

```odin
if (x >= 0) { }
for (i := 0; i < 10; i += 1) { }
foreach (value in values) { }
switch (value) { }
when (LOKE_DEBUG) { }
```

# Identifiers

Identifiers are case-sensitive and match `[A-Za-z_][A-Za-z0-9_]*`. The identifier `_` discards a value and does not create a binding. Comments and literals can contain Unicode characters. Identifiers must contain only ASCII characters.

# Variable declarations

A variable declaration creates a variable in the current scope.

```odin
x: int; // declares an uninitialized `int`; `x` starts dead
y, z: int; // both variables start dead
```

A lexical local without an initializer starts **dead and uninitialized**. Its
declaration reserves storage but does not write a value to that storage. A full
assignment completes its initialization and makes it live. An explicit
initializer, including `{}` when the zero value is wanted, makes the variable
live at its declaration.

An ordinary expression may read, borrow, take the address of, move, or drop a
local only where the compiler can prove that the local is live on every path to
that expression. Otherwise the use is a compile-time error; ordinary Loke code
never evaluates an uninitialized value. A dead local may be named only as the
destination of a full assignment. Field and element assignments do not
partially initialize a dead aggregate.

Liveness is not required in an **unevaluated operand**. `type_of(expression)`,
the expression forms of `size_of` and `align_of`, and the entity operand of
`#location` inspect only a declaration or static type. Their operands must
resolve and type-check, but they do not read storage, create a borrow, or require
the named local to be live.

Parameters start live. File-scope, `static`, and `thread_local` variables use
the constant-initialization rule under [Storage modifiers](#storage-modifiers)
and therefore still receive their zero value when they omit an initializer.

```odin
count: int;
// fmt.println(count); // ERROR: `count` is dead

if (has_count) {
	count = 1;
}
// fmt.println(count); // ERROR: `count` is not live on every path

count = 0;             // full assignment makes it definitely live
fmt.println(count);    // OK
```

Each declaration in a scope must have a unique name. A local declaration must not shadow a local variable or parameter in an outer scope. The parameter-copy form is the only exception. In a procedure body, `x := x` can create a mutable local copy of the immutable parameter `x`. See [Shadowing parameters](#shadowing-parameters).

This restriction applies only to local scopes. A local declaration may shadow a file-scope declaration, an imported package name, or a predeclared identifier such as `byte`, `nil`, or `len`. The program cannot use the shadowed name in that local scope.

```odin
x := 10;
x := 20; // Redeclaration of `x` in this scope
y, z := 20, 30;
test, z := 20, 30; // not allowed since `z` exists already
```

## Managed values and storage

Owning values include `string`, `[dynamic]T`, and `map[K]V`. An owning variable has a fixed size, but it can own storage of a variable size. The compiler automatically releases this storage when a live managed value leaves its scope.

The representation of an owning value is implementation-defined. For example, the variable can contain a handle to storage at another location. See [`string`](#string-type).

```odin
numbers := [dynamic]int{1, 4, 9};
message := string("hello");

numbers.append(16);
// `numbers` and `message` are released automatically at the end of the scope.
```

This behavior is **managed lexical storage**. Cleanup occurs at normal scope exit and during `return`, `break`, or `continue`. Cleanup also occurs during panic unwinding when the build uses the unwinding [panic strategy](#panics-and-unwinding).

Cleanup uses the same order as `defer`. A managed local declaration places an
implicit conditional `defer drop(value)` at the declaration point. The action
drops the value only if the variable is live when the action runs. Implicit
drops and explicit deferred statements run in reverse registration order. Thus,
a deferred statement can read a managed local before the compiler drops that
local, provided the compiler can prove that the local is live when the deferred
statement runs.

For a `return`, the compiler first evaluates the result and moves it to result storage. The compiler then runs the scope-exit actions. A deferred statement cannot change the result. A return can require a clone when its expression names a non-owning parameter or borrowed place. See [Parameter semantics](#parameter-semantics-and-abi-lowering) and [Named results](#named-results).

### Values that outlive every scope

A managed value with static storage duration exists for the life of the process. This rule applies to managed values at file scope and managed values declared as [`static`](#storage-modifiers). The compiler does not automatically drop these values. The operating system reclaims their memory when the process ends. A leak checker reports this memory as reachable.

A `thread_local` owner exists for the life of its thread. The runtime initializes thread-local storage (TLS) in a deterministic order. It orders declarations by canonical package path, normalized package-relative file path, and source position. At normal thread return, the runtime drops each live managed `thread_local` value in reverse initialization order. This cleanup occurs before the thread synchronizes with a successful join.

The runtime does not drop a manual TLS owner. It does not guarantee TLS cleanup after `os.exit`, an aborting panic, or termination after panic unwinding. A library-created thread must enter and leave through the Loke runtime. A foreign thread must use the documented runtime attach and detach API before it calls exported Loke code.

Do not use implicit process cleanup for an operation that has an external effect. Examples are flushing a file, closing a socket, and releasing a lock in shared memory. Use an owning scope, `defer`, or an explicit `drop` in `main`:

```odin
cache: map[string]int;             // reclaimed by the OS at exit, no drop runs

main :: proc() {
	log_file := open_log();        // managed local: dropped at the end of `main`
	run(log_file);
}
```

### Storage modifiers

A declaration specifies storage duration and ownership separately. Storage modifiers occur after `:`.

**Duration** specifies where the variable exists and how long it exists. `static` and `thread_local` are mutually exclusive. If neither modifier is present, the variable has lexical storage.

- `static` creates one instance for the life of the process. The value remains available between calls.
- `thread_local` creates one instance for each thread. A live managed value is dropped at normal thread return.

**Ownership** specifies who cleans up an owning value. `manual` disables automatic cleanup. Use it for arenas, foreign ownership, custom containers, and low-level allocator code. It can occur with either duration modifier.

```odin
counter: static int;               // keeps its value across calls
current: thread_local ^Task;       // one per thread
buffer:  manual [dynamic]u8 = {};  // live zero owner; released explicitly
handle:  manual File = {};         // this scope, cleanup is mine
```

A modifier may also be written where the type is inferred:

```odin
counter: static = 0;
raw: manual := [dynamic]int{1, 2, 3};
```

A local variable's inline representation is stored in the stack frame and has lexical lifetime. A managed local variable can own backing storage supplied by an allocator. This backing storage can be on the heap or in another storage region. The compiler automatically drops the managed value when the variable leaves scope if it is live.

The compiler does not move a large fixed-size local variable to the heap. For example, `big: [1_000_000]f64;` stores the complete eight-megabyte array in the stack frame. This declaration causes a stack overflow on most targets. Use `new`, a `[dynamic]T`, or an arena to put the bulk storage in an allocator-selected storage region.

File-scope, `static`, and `thread_local` declarations use **constant initialization**. The initializer must be a compile-time constant. If there is no initializer, the declaration uses the zero value.

A binding with static storage duration is always live after this initialization.
`move` and explicit `drop` are forbidden on it and on a subplace rooted in it;
otherwise one procedure could make the binding dead while another procedure
accessed it, requiring a runtime liveness flag and check. Full assignment
replaces its current live value normally. Code that must extract the current
value uses [`exchange`](#exchange), which installs a replacement without exposing
a dead static-duration binding. For `thread_local`, these rules apply
independently to each thread's instance. The runtime may still drop a live
managed `thread_local` value when its thread exits, because no subsequent access
to that instance is possible.

File-scope and `static` storage is ready before `main` starts. Thread-local storage is ready before its thread runs Loke code. Importing a package does not run package code. For runtime initialization, call a package procedure explicitly, use a `once` value from `core:sync`, or use state that the caller owns.

**Storage modifiers are not type constructors.** `manual [dynamic]int` and `[dynamic]int` are the same type. A move between them does not need a conversion.

Storage modifiers are not [attributes](#attributes). A modifier specifies the storage of one variable. It specifies the storage duration, address stability, or cleanup behavior. Therefore, it occurs next to the type in the declaration. Attributes specify other properties of a declaration.

The following rules also apply to `static` and `thread_local`:

- A `static` has a stable address for the life of the process. A `thread_local` has a stable address for the life of its thread. A procedure can return a borrow of either one. A program must not send a `thread_local` borrow to another thread or keep it after its thread ends. The borrow analysis does not check these errors.
- An allocator-binding owner with either duration starts in the constant, allocator-unbound zero state. The first operation that needs an allocator binds the build-selected default allocator. The declaration cannot use `via` because a runtime allocator expression is not a constant initializer. To use a different allocator, construct the owner in an explicit startup procedure or thread-start procedure, and move it into the variable. `string` and `shared(T)` keep the allocator of the allocation that moves into them.

```odin
buffer: manual [dynamic]u8;
allocation_error: Allocator_Error;
buffer, allocation_error = make([dynamic]u8, allocator=my_allocator);
if (allocation_error != nil) { panic("buffer allocation failed"); }

// A manual owner must be dropped explicitly.
drop(buffer);
```

`drop(value)` explicitly cleans up a definitely live lexical owning variable. It
runs the cleanup operation, writes the inert zero representation, and marks the
variable **dead**. Applying it to file-scope, `static`, or `thread_local` storage,
or to a subplace rooted in such storage, is a compile-time error. Scope exit
automatically drops a live managed lexical owner. It does not clean up a manual
lexical owner.

The operand of `drop` must name a variable. Like `move`, `drop` operates on a storage location. It is a compiler special form, not an ordinary procedure. It can reset its operand and mark the operand as dead.

`drop` cannot operate directly on a field, an element, or a map entry. First move the owner out of the aggregate, or drop the complete aggregate. `drop` is a predeclared identifier, not a keyword. A declaration can shadow it and make the special form unavailable in that scope.

The compiler performs dataflow analysis and classifies a lexical local as definitely
live, definitely dead, or conditionally live at each program point. A use that
requires a value is valid only in the definitely-live state. This analysis is a
compile-time property and does not add storage to ordinary variables.

When runtime control flow makes an owning variable conditionally live and a
later lifecycle operation must distinguish the states, the compiler preserves
that condition. It may use a hidden drop flag, keep the condition in a register,
duplicate cleanup into predecessor branches, or use any equivalent lowering.
No flag is required for every variable, and no source or ABI rule requires a
flag to occupy an addressable byte. For example, runtime state may be needed
when only one branch initializes, moves, or drops a managed variable before
scope exit.

A full assignment to a dead variable completes an initialization and makes it
live. A full assignment to a live variable replaces its value using the normal
assignment lifecycle. If the destination is conditionally live, generated code
uses the runtime state to select the live-destination or dead-destination
assignment lifecycle, including allocator selection and failure behavior. A
dead or conditionally-live variable cannot otherwise be read, borrowed,
addressed, moved, or explicitly dropped.

Storage for a never-initialized dead variable contains unspecified bytes. A move
or `drop` writes the inert zero representation to its source, but that
representation does not make the dead variable readable: a zero value can also
be a valid live value, so liveness is never inferred by inspecting the bytes.
The compiler calls a `drop` hook one time for each completed initialization that
is not transferred or already consumed. See [Zero values](#zero-values).

An allocator-selecting declaration retains its **declaration allocation policy** even while its variable is dead: the expression after `via`, or the program-default policy when `via` is absent. Copy-initializing or copy-assigning a dead variable uses that policy and revives the variable. Moving a live owner into it instead transfers the source owner's currently bound allocator with the value. If that value is later moved out or dropped, a subsequent copy initialization again starts from the declaration policy. This separates the policy attached to the storage location from the allocator carried by whichever live owner currently occupies it.

Built-in owning types receive compiler-defined cleanup. User-defined types receive field-wise `try_clone`, policy-following `clone`, `move`, and `drop` behavior by default and may replace the canonical `try_clone` or `drop` hook when they manage a custom resource.

Structs and fixed arrays containing managed fields receive compiler-generated copy, move, and cleanup operations recursively. Self-assignment is safe. Reference cycles require explicit pointers or `shared(T)`; plain pointer cycles are non-owning, while `shared(T)` can form ownership cycles.

Multiple declarations such as `y, z := 20, 30;` remain valid. More general tuple destructuring and pattern matching can be designed separately because they do not affect storage lifetime.

# Assignment statements

An assignment statement writes a new value to a storage location:

```odin
x: int = 123; // declares a new variable `x` with type `int` and assigns a value to it
x = 637; // assigns a new value to `x`
```

`=` is the assignment operator.

One statement can assign multiple variables:

```odin
x, y := 1, "hello"; // declares `x` and `y` and infers the types from the assignments
y, x = "bye", 5;
```

`:=` consists of the two tokens `:` and `=`. The following declarations are equivalent:

```odin
x: int = 123;
x:     = 123; // default type for an integer literal is `int`
x := 123;
```

Assignment has value semantics. Assignment of a mutable owning value creates an independent value. It does not create a hidden alias to the same allocation.

```odin
a := [dynamic]int{1, 2, 3};
b := a; // deep copy: modifying `b` does not modify `a`
b[0] = 99;
assert(a[0] == 1);
```

`move(value)` transfers ownership without a copy. The operation writes the inert
zero representation to the lexical source and marks it dead until a later full
assignment. Applying `move` to file-scope, `static`, or `thread_local` storage,
or to a subplace rooted in such storage, is a compile-time error. Use
[`exchange`](#exchange) when the source must remain live with a replacement.

```odin
c := move(a); // transfers the allocation; `a` is now dead
a = [dynamic]int{7, 8}; // a full assignment revives `a`
```

The compiler may replace a copy with a move only for a type that has a trivial lifecycle. The replacement must not change allocator selection, call or suppress user code, or remove a possible failure.

The compiler does not silently move a dynamic array, map, runtime string, `shared(T)`, or type with a custom `try_clone`. This rule also applies at the last use of the source. Use `move(value)` to transfer ownership without a clone. Loke does not provide shallow aliases for mutable owning values. Use an explicit type such as `shared(T)` for shared ownership.

Assignment of a mutable owner deep-copies rather than copying only a container's header and sharing its mutable backing storage; the owning value then behaves like a simple one. Immutable `string` is the exception and may share immutable backing storage. Small inline values remain cheap to copy; a large or allocating copy is reported by the [copy-cost diagnostic](#copy-cost-diagnostics), whose advice is to write `move` when ownership should transfer or to use a pointer or `shared(T)` when sharing is intended. Copy cost is therefore visible to tooling rather than changed by an optimization with different allocation or lifecycle behavior.

If assignment cloning needs storage, `try_clone` uses the allocator currently carried by the live destination. A dead or allocator-unbound destination first resolves its declaration allocation policy, loading `mem.default_allocator()` lazily when no `via` policy was written. If cloning fails, the compiler invokes that allocator's failure policy described under [Allocation failure](#allocation-failure) and leaves a previously live destination unchanged. A non-allocating logical clone that shares immutable or reference-counted storage, as permitted for `string` and `shared(T)`, retains the allocator recorded by that shared allocation. Those types therefore select their allocator at construction and cannot use `via`.

## Exchange

`exchange(inout destination, replacement)` replaces a definitely live value and
returns its previous value without cloning it. It is a compiler special form
rather than an ordinary procedure:

```odin
previous := exchange(inout current, {});
```

The destination must be a definitely live variable or addressable place. Its
type supplies the context for `replacement`. The compiler evaluates the
destination place once and then evaluates `replacement` completely before
modifying the destination. If evaluation or construction of the replacement
fails or panics, the destination remains unchanged. Once the replacement is
ready, the compiler moves the old value into result storage and moves the
replacement into the destination as one lifecycle operation. No user code runs
between those two moves, and the destination is never observably dead.

If `replacement` names an owning variable whose ownership should transfer, it
must use the ordinary explicit `move(source)` spelling. The result is an
ordinary owning value; it may initialize a managed or `manual` local, be moved
again, or be ignored and cleaned up as a temporary under the normal rules.

`exchange` is permitted for lexical and static-duration destinations. It is the
only operation that can move the current value out of file-scope, `static`, or
`thread_local` storage, because it simultaneously leaves a completed live
replacement. Like any `inout` operation, it is rejected while an incompatible
borrow of the destination is live. It is not an atomic memory operation and
provides no inter-thread synchronization; concurrent code uses `Atomic(T)` or a
lock.

```odin
cache: Cache; // file-scope, always live

take_cache :: proc() -> Cache {
	return exchange(inout cache, {}); // `cache` remains a live zero value
}

clear_cache :: proc() {
	cache = {}; // drops the old value and installs a live zero value
}
```

# Borrows and lifetimes

Loke checks the lifetime of locally visible borrows. The model is based on
**storage roots**, not on whether cleanup is automatic.

## Storage roots and borrow carriers

Every ordinary variable and value temporary owns its inline storage. It is a
storage root for borrows of that storage. A root may additionally own a backing
allocation or another resource, as a dynamic array or `File` does, but that is a
separate lifecycle property. An allocator-created allocation is also a storage
root even though it is reached through a pointer.

The `manual` modifier changes who performs cleanup; it does not change which
value is the root. Thus `&managed_value` and `&manual_value` are checked borrows
in exactly the same way.

A **borrow carrier** is a value that refers to another root without owning that
root. The built-in carriers are:

- `^T`, a mutable single-value pointer;
- `[]T` and `[]mut T`, immutable and mutable slices;
- `string_view`, `cstring_view`, and `any_view`;
- `dyn Interface` views and compiler-known iterators;
- default and `inout` parameter access paths for the duration of a call.

Copying a borrow carrier copies the view and its root provenance, never the pointee.
It creates no cleanup obligation. The carrier variable owns only its own pointer,
length, or witness-table bits.

Root provenance is compile-time metadata, not part of a value's layout or
ABI. It identifies the root and the capability through which it is accessed.
The following operations preserve root provenance:

- `&place` creates a checked mutable `^T` borrow of the root containing `place`;
- slicing creates a checked `[]T` or `[]mut T` borrow of the sliced root;
- conversion to a built-in view and compiler-known iteration preserve the
  source root;
- a borrow returned from a Loke procedure derives root provenance from its borrowed
  arguments as described below;
- `new` and `new_clone` create a new allocation root and return a checked `^T`
  pointer to its first value.

### How root and region provenance compose

Loke performs two distinct lifetime analyses over related values:

- **Root provenance** belongs to a non-owning pointer, slice, or other borrow
  carrier. It identifies the storage root whose continued existence and access
  rules make that borrow valid.
- **Region provenance** belongs to an owning value or allocation root whose
  backing storage came from an allocator region. It identifies the region that
  must remain valid while that owner or allocation is live. See
  [Allocators](#allocators).

These are not two names for the same property. Root provenance answers “which
storage does this view borrow?” Region provenance answers “which allocator
region keeps this owned storage valid?” They compose transitively. If owner
`value` has backing storage in region `R`, and `view` borrows `value`, then
`view` depends directly on the storage root `value` and indirectly on `R`:

```text
view --borrows--> value --backed by--> R
```

The root analysis prevents `view` from outliving, conflicting with, or surviving
invalidation of `value`. The region analysis prevents `value` from outliving or
surviving reset of `R`. Resetting `R` is rejected while either the owner or a
checked borrow transitively depending on it is live. Passing either analysis
does not waive the other.

Operations propagate the two dependencies differently:

- Borrowing an owner creates a root dependency on that owner; its region
  dependency is inherited transitively rather than copied onto the borrow as a
  second ownership claim.
- Moving an owner is forbidden while one of its checked borrows is live. The
  move transfers the owner's region dependency to the destination, but does not
  make the destination borrow the source variable.
- Cloning creates a new owner. An allocating clone receives the destination
  allocator's region provenance; a documented logical clone that retains shared
  storage retains that allocation's region provenance.
- Returning a borrow propagates root provenance from borrowed parameters.
  Returning a moved owner propagates region provenance from the moved value.
  Constructing an owning result with an allocator parameter propagates that
  allocator's region provenance. These cases are recorded separately in the
  procedure's result-provenance summary.
- Storing a borrow in an untracked record or converting it through `core:unsafe`
  loses checked root provenance as described under
  [What is not checked](#what-is-not-checked). It does not extend the root or
  allocator region and therefore cannot make an otherwise invalid lifetime
  safe.

For example, the two rejected returns below fail for different reasons:

```odin
bad_view :: proc() -> []u8 {
	arena := mem.Arena();
	bytes: [dynamic]u8 via arena.allocator() = {};
	return bytes[:]; // ERROR: borrow outlives the local root `bytes`
}

bad_owner :: proc() -> [dynamic]u8 {
	arena := mem.Arena();
	bytes: [dynamic]u8 via arena.allocator() = {};
	return move(bytes); // ERROR: owner outlives allocator region `arena`
}
```

The pointee's cleanup policy does not decide whether a pointer is a borrow. A
pointer made with `&` is a borrow even when the root is `manual`. A pointer from
`new` designates a separately allocated root, but the `^T` value still does not
own that allocation or acquire automatic cleanup. `free` ends the allocation
root and invalidates every checked pointer derived from it. Code that wants an
allocation to behave as a move-only, automatically cleaned-up value wraps the
pointer and allocator in an ordinary resource type with a `drop` hook.

`rawptr` and `[^]T` carry no checked provenance. A `^T` received from foreign
code, reconstructed by unsafe code, or loaded from storage whose provenance the
compiler does not track is also an unchecked address despite having the same
machine type as a checked `^T`. Dereferencing an unchecked address is the
programmer's responsibility.

A user record that contains pointer, length, or witness-table fields is not a
new compiler-known borrow carrier. Version 1 has no user-defined provenance
annotation. Storing a built-in borrow in such a record escapes the local
analysis as described under [What is not checked](#what-is-not-checked).

## Capabilities and the one rule

An immutable borrow permits reads only. `[]T`, `string_view`, and ordinary
read-only parameter access are immutable borrows. While one is live, the root
may be read through compatible paths, but it may not be written, moved, dropped,
freed, or invalidated.

A mutable borrow permits reads and writes through that borrow. `^T`, `[]mut T`,
and `inout` are mutable borrows. While one is live, the root cannot be accessed
through a competing name or overlap another live borrow. An `inout` borrow of
the complete owner may update its header and invalidate its previous contents;
an interior `^T` or `[]mut T` borrow cannot.

> A checked borrow may be used only while its root is live, and every access to
> the root while the borrow is live must be compatible with the borrow's
> capability.

Moving, dropping, freeing, fully assigning, or exchanging a root invalidates
borrows of its previous value. Container operations such as `append`, `resize`, `reserve`,
`shrink`, `clear`, `remove`, map insertion, and any user operation whose `self`
parameter is `inout` also invalidate element and view borrows. Reallocation is
a common reason, but changing which logical elements exist is sufficient.

A borrow is live from its creation to its last use within the procedure body.
Copies of a borrow extend the same loan to the last use of any copy. A borrow
that is never used again stops constraining its root immediately.

```odin
numbers := [dynamic]int{1, 2, 3};

view := numbers[:];
fmt.println(view[0]);   // last use of `view`
numbers.append(4);      // OK: the borrow has ended

second := numbers[:];
numbers.append(5);      // ERROR: invalidates `second`
fmt.println(second[0]);
```

The diagnostic must name the root, the borrow's creation, the conflicting or
invalidating operation, and the later use that keeps the borrow live.

## Temporaries and procedure boundaries

A value temporary lives until the end of its complete expression. A borrow
derived from it may be used during that expression, including by a called
procedure, but cannot escape it. A temporary in a `foreach` iterable, `switch`
subject, or `if`, `for`, or `switch` initial statement instead lives until that
complete statement ends.

A borrow derived from a local root cannot be returned:

```odin
bad :: proc() -> []int {
	local := [dynamic]int{1, 2, 3};
	return local[:]; // ERROR: `local` ends when the procedure returns
}
```

A borrow returned from storage reachable through a borrowed parameter derives
root provenance from every borrowed argument received by the procedure:

```odin
first_half :: proc(values: []int) -> []int {
	return values[:len(values)/2];
}

numbers := [dynamic]int{1, 2, 3, 4};
view := first_half(numbers[:]); // borrows `numbers`

bad := first_half([dynamic]int{1, 2, 3, 4}[:]);
// ERROR: the result would outlive the temporary argument
```

The default parameter binding itself is a callee-local read-only value. Taking
`&parameter` borrows that local and cannot produce a returned pointer. An
`inout` parameter aliases the caller's root, so a borrow returned from it is
derived from that root. If a procedure has multiple borrowed arguments, its
returned borrow conservatively derives from all of them.

A checked pointer to an allocation root created by `new` or `new_clone` may be
returned because the allocation is not callee-local storage. The pointer's root
provenance and the allocation root's region provenance follow the result. This transfers release responsibility
by API convention, not by making `^T` an owning type; the compiler does not
require every manually allocated root to be freed.

For a direct call to a named Loke declaration or generic instantiation, the
compiler records a result-provenance summary with the declaration. For each
result it records two independent components when applicable:

- root provenance: borrowed parameters, static storage, a fresh allocation
  root, or unknown root provenance;
- region provenance: allocator parameters, the region dependency of a moved or
  shared owner, a non-resettable static region, or unknown region provenance.

At a direct call, the compiler substitutes the actual argument roots and
allocator regions into the corresponding component. The summary is compile-time
declaration metadata, is emitted for cross-package checking, and does not change
the runtime ABI.

An ordinary procedure value does not carry that declaration metadata. At a call
through a procedure value, a returned pointer, slice, or view is conservatively
derived from every borrowed argument of the call. If there is no such argument,
the result has unknown root provenance. An owning result conservatively retains
the possible region provenance of every moved owner and allocator argument; if
none exists, its region provenance is unknown. Fresh-allocation root provenance
is never preserved through an ordinary procedure value, so its result cannot be
passed to checked `free`. An API that transfers allocation responsibility
through indirect calls uses an ordinary move-only resource wrapper rather than
bare `^T`. Foreign procedure results likewise begin with unknown provenance
unless a library wrapper establishes an owned resource.

Allocator-wide invalidation is the one effect propagated through arbitrary
ordinary procedure wrappers. A parameter marked
[`@(allocator_reset)`](#allocator_reset) states that a successful call may end
every allocation root in that allocator region. At the call, the compiler
rejects the reset while a value or checked borrow from the region is live.

## What is not checked

The analysis is deliberately local to one procedure body. These cases remain
the programmer's responsibility:

- storing a pointer, slice, iterator, or other view in a record field, global,
  container, callback state, or service object;
- a procedure or foreign function retaining a borrowed argument after return;
- dereferencing `rawptr`, `[^]T`, or a `^T` with unknown provenance;
- pointers or views manufactured or stripped of provenance through
  `core:unsafe`;
- transferring borrows or unchecked addresses between threads;
- aliases hidden by foreign code or user-defined pointer-containing records.

If a view has no locally provable lifetime, make an owned copy with `clone`, use
`shared(T)`, or keep the lifetime correct as an explicit unsafe obligation.

## Debug-mode detection

When `LOKE_DEBUG` is set, an implementation is encouraged to put generation
counters in managed containers and their views and trap after reallocation or
logical invalidation. This is an implementation-defined debugging aid, not a
language guarantee, and release builds are expected to omit it.

## The `unsafe` package

Operations that discard or manufacture provenance live in `core:unsafe`. It is
an ordinary package; its visible import is the review mechanism.

```odin
import "core:unsafe"

raw := unsafe.raw_data(bytes);       // checked provenance is discarded
view := unsafe.cstring_view(raw);    // programmer promises the lifetime
```

Everything in `unsafe` is a promise by the programmer that the compiler cannot
verify. It does not make the underlying storage owned or extend its lifetime.

# Literals

## String and character literals

A string literal uses double quotation marks. A character literal uses single quotation marks. A backslash (`\`) starts an escape sequence.

```odin
"This is a string"
'A'
'\n' // newline character
"C:\\Windows\\notepad.exe"
```

One backtick on each side encloses a raw string literal. A raw string does not contain escape sequences.

```odin
`C:\Windows\notepad.exe`
```

The built-in `len` procedure returns the byte length of a string:

```odin
len("Foo");
len(some_string);
```

If the argument to `len` is a compile-time constant, the result is also a compile-time constant.

### Escape characters

- `\a` - bell (BEL)
- `\b` - backspace (BS)
- `\e` - escape (ESC)
- `\f` - form feed (FF)
- `\n` - newline
- `\r` - carriage return
- `\t` - tab
- `\v` - vertical tab (VT)
- `\\` - backslash
- `\"` - double quote (if needed)
- `\'` - single quote (if needed)
- `\NNN` - octal 6-bit character (3 digits)
- `\xNN` - hexadecimal 8-bit character (2 digits)
- `\uNNNN` - hexadecimal 16-bit Unicode character UTF-8 encoded (4 digits)
- `\UNNNNNNNN` - hexadecimal 32-bit Unicode character UTF-8 encoded (8 digits)

## Number literals

A numeric literal can contain underscores for readability. For example, `1_000_000_000` is one billion. A decimal point or exponent makes a floating-point literal. For example, `1.0e9` is one billion.

The prefix `0b` identifies a binary literal. The prefix `0o` identifies an octal literal. The prefix `0x` identifies a hexadecimal literal. A leading zero does not make an octal literal.

A numeric literal begins as an untyped integer or untyped floating constant.
The compiler evaluates such constants without first rounding them to a runtime
numeric type. Context may convert them implicitly under these rules:

- An untyped integer constant may convert to a built-in integer type when its
  mathematical value is in range.
- An untyped integer constant may convert to a built-in floating-point type
  under the floating conversion rule below.
- An untyped floating constant may convert implicitly only to a built-in
  floating-point type. It never converts implicitly to an integer type, even
  when its mathematical value is integral.

Converting a finite untyped numeric constant to a floating-point type rounds
once to that type using IEEE-754 round-to-nearest, ties-to-even. The conversion
is rejected when the correctly rounded result would overflow to infinity.
Rounding to a subnormal value or zero is permitted. This rule allows ordinary
decimal literals such as `0.1` even though their mathematical values have no
exact binary floating-point representation. An infinity or NaN produced by
constant evaluation may convert to a floating-point type, but never to an
integer type; its IEEE class and the sign of an infinity are preserved, while a
NaN payload is implementation-defined.

```odin
x: int = 1.0;      // ERROR: an untyped floating constant does not convert implicitly to `int`
x: int = int(1.0); // OK: the floating-to-integer conversion is explicit
y: f64 = 1;        // OK: the integer constant is rounded to `f64` if necessary
z: f64 = 0.1;      // OK: rounded once to `f64`
```

A literal constant is initially untyped. Context can convert it to a compatible type.

```odin
x: int; // `x` is typed as being of type `int`
x = 1; // `1` is an untyped integer literal which can implicitly convert to `int`
```

# Constant declarations

A constant binds a name to a value. The value must be available at compile time and cannot change.

```odin
x :: "what"; // constant `x` has the untyped string value "what"
```

A constant declaration can specify a type:

```odin
y : int : 123;
z :: y + 7; // constant computations are possible
```

Constants may be declared in any order and may refer to constants declared later in the same package. A cycle in that dependency graph has no value and is a compile-time error; the diagnostic reports the cycle as a path of constant declarations, in the same way an [import cycle](#import-cycles) is reported.

## Materialization

A constant is a value, not a variable, and an ordinary use of one is substituted at the point of use with no storage involved. Some uses need storage anyway:

- indexing by a non-constant index
- a slice expression

**A constant used in either of those ways is materialized into read-only storage.** All uses of that constant share one backing object. A constant that is never used in one of those ways occupies no space in the program.

```odin
NUMBERS :: [?]int{7, 42, 628};

main :: proc() {
	index := read_index();
	n := NUMBERS[index];        // materialized: the index is not constant
	m := NUMBERS[0];            // not materialized: folds to 7
	all := NUMBERS[:];          // materialized: `[]int` over static storage
}
```

Materialized storage is read-only. Assigning through it is rejected and a slice of it is `[]T`, never `[]mut T`. Taking the address of a constant or of any place within its materialized storage is a compile-time error: pointers carry no read-only capability, so permitting `&C` or `&C[i]` would allow an ordinary `^T` parameter to write into read-only storage. Low-level code that deliberately needs a foreign pointer obtains a read-only slice first and uses `unsafe.raw_data`, making the capability loss explicit.

Because the storage is static, a borrow of a materialized constant outlives every scope, exactly like [a slice over a string literal](#slices). It may be returned, stored in a global, or sent to another thread.

Loke does not need a separate read-only-data declaration. A constant table is materialized in read-only storage when runtime indexing needs storage:

```odin
NAMES :: [?]string{"north", "east", "south", "west"};

heading :: proc(category: int) -> string {
	return NAMES[category];
}
```

Placing a constant in a *particular* linker section is a toolchain concern and uses an [extension attribute](#extension-attributes) such as `@(link.section=".rodata.hot")`.

A constant value must be available at compile time. Thus, it cannot contain a managed owner, a pointer to non-static storage, or another value that needs lifecycle operations. Materialization emits bytes and does not need cleanup.

## Compile-time phases

Compile-time knowledge is a property of a binding, not a second family of value
types. A compile-time `int`, `string`, enum, array, or record has the same Loke
type and operations as its runtime counterpart. Information flows from compile
time to runtime by constant substitution or materialization; a runtime value can
never flow back into a compile-time-required context.

There are three ways to introduce compile-time information:

- `name :: expression` binds the compile-time result of an expression. Inside a
  generic declaration it is evaluated separately for each specialization that
  reaches the declaration.
- `$name` introduces a **specialization binding**. On an explicit procedure or
  type parameter the caller supplies a compile-time value. In a parameter type
  or static `foreach` binding the compiler infers one. `$` appears only where the
  name is introduced; subsequent uses write `name` normally.
- A type name is itself a compile-time value of the compile-time-only [`type`](#type-and-typeid)
  type.

Outside a call that is itself evaluated by the compiler, an ordinary variable,
including an immutable procedure parameter, is a runtime binding even when a
particular caller passes a constant. A parameter is part of specialization only
when its declaration uses `$`. During contextual compile-time evaluation,
ordinary parameters are evaluator locals and may hold the supplied constants,
but that does not create a reusable specialization of the procedure. This keeps
a constant argument in runtime code from silently creating another generated
procedure body.

The following contexts require compile-time values:

- constant initializers and arguments supplied to `$` parameters;
- generic type and value arguments;
- fixed-array lengths, enum values, `where` clauses, and `when` conditions;
- static `foreach` iterables;
- compile-time reflection and the operands required by a compile-time built-in.

An ordinary runtime expression may consume a compile-time value. The reverse is
a compile-time error and the diagnostic must identify the runtime binding that
prevented evaluation.

## Compile-time procedure evaluation

A normal `proc` may be evaluated by the compiler when its result is required in
a compile-time context. There is no second `comptime proc` declaration kind.
The same procedure may be called at runtime when its signature and result are
runtime-representable:

```odin
hash_name :: proc(text: string_view) -> u64 {
	hash: u64 = 14695981039346656037;
	foreach (b in text.bytes()) {   // bytes, not runes: string iteration yields code points
		hash = (hash ~ u64(b))*1099511628211;
	}
	return hash;
}

CLICKED_ID :: hash_name("clicked"); // evaluated by the compiler
id := hash_name(user_text);         // ordinary runtime call
```

There is no operation that reports whether the current call is being evaluated
by the compiler. A procedure cannot choose different semantics only because
the phase changed.

A compile-time call requires every value it reads from outside its own locals to
be compile-time known. Its executed path may use ordinary expressions,
procedures, local variables, mutation, control flow, recursion, and temporary
managed containers. It may not:

- read or modify runtime or mutable file-scope state;
- call foreign code or use volatile, atomic, thread, clock, random, environment,
  file-system, network, or process operations;
- observe a runtime address, convert a pointer to an integer, or retain a pointer
  to evaluator-owned storage;
- use a runtime allocator or transfer an evaluator-owned managed value into the
  generated program.

Temporary strings, arrays, maps, and other managed values use compiler-owned
storage while evaluation runs. This storage has no Loke `Allocator`, cannot be
observed by the program, and is reclaimed by the compiler. A final result must
be a compile-time-only value or a constant that satisfies the materialization
rules above. Compiler resource exhaustion is a compilation diagnostic, not an
`Allocator_Error` visible to the program.

An evaluator-produced immutable string may be frozen into static storage exactly
as though its bytes had appeared in a string literal; the emitted string value
must therefore have an inert `drop`. This does not generalize to mutable managed
owners: a dynamic array, map, or other value that would retain an allocation at
runtime is not a materializable constant. It must be converted to a fixed array,
immutable string, or ordinary record before the compile-time call returns.

Only the path actually evaluated must satisfy these execution restrictions; all
branches must still parse and type-check unless discarded by `when`. A panic
or failed `assert` reached during compile-time evaluation is a compilation error
reported with the compile-time call stack. Implementations may impose documented
step, recursion, and memory limits, but exceeding one must be diagnosed rather
than silently moving the call to runtime.

Compile-time evaluation is hermetic. It receives target and project information
only through language constants and [`#config`](#configidentifier-default).
Build scripts are ordinary programs run by the build system; compile-time
procedures do not acquire ambient access to the machine performing the build.
For identical source, configuration, and target, evaluation must produce the
same result. An operation with deliberately unspecified runtime ordering, such
as map iteration, is rejected on an executed compile-time path; maps remain
available for keyed lookup and working storage.

# Comments

A comment can occur outside a string or character literal. A line comment starts with `//` and ends at the newline:

```odin
// A comment

my_integer_variable: int; // A comment for documentation
```

A block comment starts with `/*` and ends with `*/`. Block comments can be nested:

```odin
/*
	Text and code in this block are comments.
	/*
		Nested comments are valid.
	*/
*/
```

# Packages

A Loke program contains one or more packages. A Loke source file uses the `.loke` extension. A package is a directory of source files. Each file in the directory must have the same package declaration. An executable starts at the `main` procedure of package `main`.

## Program entry and exit

An executable is built from a package named `main` containing exactly one procedure named `main`. Its signature is `main :: proc()`: no parameters, no results, the `loke` calling convention. Command-line arguments are read from `os.args`. The exit status is 0 when `main` returns normally. `os.exit(code)` terminates the process immediately with the specified status.

`main` takes no arguments because one `argv` representation cannot describe the platform argument encoding on every target. It returns no result. Use `os.args` to read arguments. Use `os.exit` only when immediate termination is required.

Program startup has this order:

1. Runtime initialization, including the build-selected allocator and logging providers.
2. `main`.

Importing a package does not run package code. A package that needs runtime initialization must expose a procedure, and the application must call it explicitly. The application owns the returned state or explicitly shuts the package down.

Normal return from `main` runs its scope-exit actions before the process ends. Managed values at file scope are [not dropped](#values-that-outlive-every-scope). `os.exit` terminates immediately. It does not run `defer`, automatic `drop`, or thread-local cleanup. A [panic](#panics-and-unwinding) follows its selected panic strategy.

To return a nonzero status after cleanup, keep owned state in a helper procedure. Cleanup runs when the helper returns. `main` can then call `os.exit`:

```odin
run_application :: proc() -> int {
	state, error := application.initialize();
	if (error != nil) { return 1; }
	defer application.shutdown(inout state);

	return application.run(inout state);
}

main :: proc() {
	status := run_application();
	if (status != 0) { os.exit(status); }
}
```

## Import statement

The following program imports the fmt and os packages from the core library collection.

```odin
package main;

import "core:fmt";
import "core:os";

main :: proc() {
}
```

An import path prefix selects a library collection. For example, `core:` selects the core library collection. A path without a prefix is relative to the current file.

By convention, the package name is the last element of the import path. Thus, files in `core:fmt` normally declare `package fmt;`. The compiler does not require this convention. When possible, it uses the last path element as the default import name.

An import can specify an alias instead of the default name:

```odin
import "core:fmt";
import foo "core:fmt"; // reference a package by a different name
```

An import name is a lexical alias and nothing more. Two names for the same package refer to the same declarations, and an alias never creates a second instance of a package or of anything it owns.

Every source file must contain its package declaration. Package versions are selected by the build system or package manager and are not part of import syntax.

### Import cycles

Import cycles between packages are rejected. The import graph must be a directed acyclic graph, and the compiler reports the cycle as a path of import statements.

The acyclic graph gives packages a deterministic dependency order for compilation and linking. Declarations *within* a package may refer to each other freely and in any order. Express a mutual dependency by merging the packages or by moving shared declarations to a third package that both packages import.

## Exported names

All declarations in a package are private to that package by default. A package's API is the set of declarations it marks public, so exporting is always a deliberate act.

The public attribute exports an entity from its package.

```odin
@(public)
my_variable: int; // visible to importers of this package
@(public)
my_other_variable: int;
```

`@(private)` names the default explicitly. It is redundant on its own, and exists so that a declaration can opt out of a file-wide `@(public)` package attribute.

**Loke has two visibility levels: package and public.** It has no file-private visibility. The package is the encapsulation boundary. Put code in a separate package when it needs a separate visibility boundary.

### Authoring a package

A package directory contains only one package. Each source file in that directory must have the same package name, for example `package main;`.

### Organizing packages

Packages may be thematically organized by placing them in subdirectories of another package. For example: core:image/png and core:image/tga, as subdirectories of core:image. Nesting these packages is a helpful taxonomy. It does not imply a dependency: core:foo/bar does not need to import core:foo and reference anything from it.

Private-by-default visibility means a package that exists to export — a foreign binding, a thin wrapper — would otherwise need `@(public)` on every declaration. Apply the same attribute to the package declaration to make every declaration in that file public by default:

```odin
@(public)
package glfw;
```

This is also the one-line fix when porting a package written against a public-by-default language.

# Control flow statements

## for statement

The language has two loop statements. `for` repeats according to control expressions, while `foreach` consumes an iterable.

### Basic `for` loop

A basic `for` loop has three parts separated by semicolons:

- The initial statement runs before the first iteration.
- The condition is evaluated before each iteration.
- The post statement runs after each iteration.

The loop stops when the condition is false.

```odin
for (i := 0; i < 10; i += 1) {
	fmt.println(i);
}
```

The loop header is parenthesized and the body is braced, as for every control-flow statement:

```odin
for (i := 0; i < 10; i += 1) { }
```

The initial and post statements are optional:

```odin
i := 0;
for (; i < 10;) {
	i += 1;
}
```

The separators in a three-part `for` header are required. A condition-only loop is equivalent to a `while` loop in languages that have one:

```odin
i := 0;
for (i < 10) {
	i += 1;
}
```

If the condition is omitted, this produces an infinite loop:

```odin
for (;;) {
}
```

## foreach statement

`foreach` binds each value produced by an iterable. It is the only iteration-loop syntax; `for ... in` is not an alternative spelling.

An integer range is iterable, so the basic loop

```odin
for (i := 0; i < 10; i += 1) {
	fmt.println(i);
}
```

can also be written as

```odin
foreach (i in 0..<10) {
	fmt.println(i);
}
// or
foreach (i in 0..=9) {
	fmt.println(i);
}
```

`a..=b` is a closed range. It includes `a` and `b`. `a..<b` is a half-open range. It includes `a` and excludes `b`.

The built-in iterable types include strings, arrays, slices, dynamic arrays, maps, and integer ranges:

```odin
some_string := "Hello, 世界";
foreach (character in some_string) {
	fmt.println(character);
}

some_array := [3]int{1, 4, 9};
foreach (value in some_array) {
	fmt.println(value);
}

some_slice := []int{1, 4, 9};
foreach (value in some_slice) {
	fmt.println(value);
}

some_dynamic_array := [dynamic]int{1, 4, 9};
foreach (value in some_dynamic_array) {
	fmt.println(value);
}

some_map := map[string]int{"A" = 1, "C" = 9, "B" = 4};
foreach (key in some_map) {
	fmt.println(key);
}
```

A second binding receives an index, or a map value:

```odin
foreach (character, index in some_string) {
	fmt.println(index, character);
}
foreach (value, index in some_array) {
	fmt.println(index, value);
}
foreach (value, index in some_slice) {
	fmt.println(index, value);
}
foreach (value, index in some_dynamic_array) {
	fmt.println(index, value);
}
foreach (key, value in some_map) {
	fmt.println(key, value);
}
```

By default, each iterated value is a copy. Assignment to the copy does not modify the source.

String iteration produces Unicode runes, not bytes. The string must contain valid UTF-8.

```odin
str: string = "Some text";
foreach (character in str) {
	assert(type_of(character) == rune);
	fmt.println(character);
}
```

Use the address operator to iterate by reference over a mutable array, dynamic array, or slice. A slice must have type `[]mut T`. A `[]T` slice supports only iteration by value.

```odin
mutable_slice := []mut int{1, 4, 9};

foreach (&value in some_array) {
	value = something;
}
foreach (&value in mutable_slice) {
	value = something;
}
foreach (&value in some_dynamic_array) {
	value = something;
}
// does not impact the second index value
foreach (&value, index in some_dynamic_array) {
	value = something;
}
```

Map values can be iterated by-reference, but their keys cannot since map keys are immutable:

```odin
some_map := map[string]int{"A" = 1, "C" = 9, "B" = 4};

foreach (key, &value in some_map) {
	value += 1;
}

fmt.println(some_map["A"]); // 2
fmt.println(some_map["C"]); // 10
fmt.println(some_map["B"]); // 5
```

String iteration cannot use a reference binding because strings are immutable.

### Static `foreach` expansion

A `foreach` whose bindings carry `$` is a compile-time expansion rather than a
runtime loop:

```odin
print_record :: proc(value: ^$T) {
	foreach ($field, $index in fields_of(T)) {
		fmt.println(index, field.name, field.get(value));
	}
}
```

The iterable must be compile-time known, finite, and produce compile-time values.
Fixed arrays, evaluator-owned arrays and slices, enum types, ranges, and
reflection descriptor arrays qualify; a runtime iterator does not. The compiler instantiates and
type-checks one copy of the body for each element, substituting constant values
for `field` and, when present, `index`. The copies execute at runtime in iterable
order unless the surrounding call is itself being evaluated at compile time.
This is what permits `field.get(value)` to have a different static result type
in each copy.

Both bindings use `$`; mixing a runtime and compile-time binding in one header is
an error. Static bindings are immutable and cannot use `&`. The body is parsed
once but semantically checked after substitution. If the iterable is empty it
has no instantiated body, just as an unselected `when` branch has no checked
contents. Diagnostics inside an expansion must show the element and its source
descriptor or index.

`break` and `continue` cannot target a static expansion. Ordinary runtime loops
inside its body may use them normally. Static `foreach` is a statement inside a
procedure; it does not synthesize identifiers or declarations at file scope,
and does not expose tokens or an abstract syntax tree to compile-time code.

### Reverse iteration

Reverse traversal is an ordinary iterator adapter rather than control-flow syntax. The core iterator library's `reverse` procedure uses `iter_reverse` when the value provides it:

```odin
array := [?]int { 10, 20, 30, 40, 50 };

foreach (x in reverse(array)) {
	fmt.println(x); // 50 40 30 20 10
}
```

Loop unrolling is an optimizer decision or a namespaced compiler-extension attribute. It does not change language semantics and has no base-language directive.

## if statement

The condition is parenthesized and the body is braced.

```odin
if (x >= 0) {
	fmt.println("x is positive");
}
```

Like for, the if statement can start with an initial statement to execute before the condition. Variables declared by the initial statement are only in the scope of that if statement.

```odin
if (x := foo(); x < 0) {
	fmt.println("x is negative");
}
```

Variables declared inside an if initial statement are also available to any of the else blocks:

```odin
if (x := foo(); x < 0) {
	fmt.println("x is negative");
} else if (x == 0) {
	fmt.println("x is zero");
} else {
	fmt.println("x is positive");
}
```

## switch statement

A switch statement selects a case by comparing its required subject expression with case values. It may include an initialization statement before the subject, separated by a semicolon. The default case is denoted by `case` without a value.

```odin
switch (arch := LOKE_ARCH; arch) {
case .I386, .Wasm32, .Arm32:
	fmt.println("32 bit");
case .Amd64, .Wasm64p32, .Arm64, .Riscv64:
	fmt.println("64 bit");
case .Unknown:
	fmt.println("Unknown architecture");
}
```

Switch is like the one in C or C++, except that only the selected case runs. This means that a break statement is not needed at the end of each case. Another important difference is that the case values need not be integers nor constants.

**There is no `fallthrough`.** A case that should also run for other values lists them, `case 0, 1, 2:`. A case that must run another case's body calls a shared procedure.

Switch cases are evaluated from top to bottom, stopping when a case succeeds. For example:

```odin
switch (i) {
case 0:
case foo():
}
```

`foo()` does not get called if `i == 0`. If all the case values are constants, the compiler may optimize the switch statement into a jump table (like C).

A switch header of the form `switch (name in expression)` is always a [type switch](#type-switch-statement), never a value switch whose subject is the boolean `name in expression`. The membership meaning needs a second pair of parentheses:

```odin
switch (x in set) { }     // type switch: `x` binds the variant of `set`
switch ((x in set)) { }   // value switch on the boolean `x in set`
```

The two readings are otherwise indistinguishable at the header, and the type switch is by far the more common one.

A switch statement can also use the same ranges accepted by `foreach`:

```odin
switch (c) {
case 'A'..='Z', 'a'..='z', '0'..='9':
	fmt.println("c is alphanumeric");
}

switch (x) {
case 0..<10:
	fmt.println("units");
case 10..<13:
	fmt.println("pre-teens");
case 13..<20:
	fmt.println("teens");
case 20..<30:
	fmt.println("twenties");
}
```

### Exhaustive switch

With enum values:

```odin
Foo :: enum {
	A,
	B,
	C,
	D,
}

f := Foo.A;
switch (f) {
case .A: fmt.println("A");
case .B: fmt.println("B");
case .C: fmt.println("C");
case .D: fmt.println("D");
}

// An empty default explicitly acknowledges the variants not handled here.
switch (f) {
case .A: fmt.println("A");
case .D: fmt.println("D");
case:
}
```

With union types (see Type switch statement)

```odin
Foo :: union {int, bool};
f: Foo = 123;
switch (_ in f) {
case int:  fmt.println("int");
case bool: fmt.println("bool");
case:
}

switch (_ in f) {
case bool: fmt.println("bool");
case: // intentionally ignore `int` and nil
}
```

A switch over an enum must either list every member or include `case:`. A type
switch over a union must either cover every variant and nil, or include `case:`.
The default may be empty; writing it is the explicit acknowledgement that the
remaining cases are intentionally ignored.

## defer statement

A defer statement defers the execution of a statement until the end of the scope it is in. It is registered when execution reaches the `defer` statement and participates in the unified LIFO scope-exit ordering described under [Managed values and storage](#managed-values-and-storage).

Deferred code may not transfer control out of the deferred statement. A `return` or `or_return` anywhere in the deferred statement is an error. A `break` or `continue` is legal only when its target loop or switch is wholly inside the deferred statement; it cannot target a construct surrounding the original `defer`. A deferred statement also may not contain another `defer`. Procedure literals nested in the deferred syntax are checked as independent procedures and are not subject to these restrictions only because their declarations occur there.

These restrictions make cleanup compositional: once scope exit begins, a deferred action runs to completion and cannot replace the return, break, or continue that caused the exit, nor register more work in the scope whose defer stack is already being drained.

The following will print 4 then 234:

```odin
package main;

import "core:fmt";

main :: proc() {
	x := 123;
	defer fmt.println(x);
	{
		defer x = 4;
		x = 2;
	}
	fmt.println(x);

	x = 234;
}
```

A `defer` statement can defer a complete block:

```odin
{
	defer {
		foo();
		bar();
	}
	// This is equivalent to `defer { if (cond) { bar(); } }` because the `if` is
	// a statement in its own right.
	defer if (cond) {
		bar();
	}
}
```

Defer statements are executed in the reverse order that they were declared:

```odin
defer fmt.println("1");
defer fmt.println("2");
defer fmt.println("3");
```

Will print 3, 2, and then 1.

A real world use case for defer may be something like the following:

```odin
f, err := os.open("my_file.txt");
if (err != os.ERROR_NONE) {
	// handle error
}
defer os.close(f);
// rest of code
```

In this case, it acts akin to an explicit C++ destructor however, the error handling is basic control flow.

It’s important to note that defer cannot be used to change a procedure’s named return values, as it runs after exit when the values have already been returned.

```odin
foo :: proc() -> (n: int) {
	defer {
		n = 456; // This does not change the returned value of `n`.
	}
	n = 123;
	return;
}
```

## when statement

`when` performs structural source selection. It is not the compile-time spelling
of `if`: an ordinary `if` already executes normally when its surrounding
procedure call is evaluated by the compiler. `when` is used when the condition
decides which source branch exists and which branch is semantically checked.

- Each condition must be a constant expression because a `when` statement is evaluated at compile time.
- Statements within a branch do not create a new scope.
- The compiler checks only the branch belonging to the first true condition.
- An initial statement is not allowed in a `when` statement.
- `when` statements are allowed at file scope.

The contents of a `when` branch match its location. Inside a procedure, a selected branch contains ordinary statements. At file scope, it contains top-level items, so it may conditionally provide imports, foreign declarations, `impl` or `extend` blocks, and declarations, but not executable expression statements. In either location the braces used by `when` do not introduce a scope; the selected contents behave as if they had appeared directly at the surrounding location.

Example:

```odin
print_architecture :: proc() {
	when (LOKE_ARCH == .I386) {
		fmt.println("32 bit");
	} else when (LOKE_ARCH == .Amd64) {
		fmt.println("64 bit");
	} else {
		fmt.println("Unsupported architecture");
	}
}
```

The selected branch is type-checked after selection; unselected branches are
discarded after parsing. This supports platform-specific code without textual
preprocessing.

See [Conditional compilation](#conditional-compilation) for built-in constants that a `when` statement can use.

## Branch statements

### break statement

`break` exits the innermost enclosing `for`, `foreach`, or `switch`. It takes no operand, and using it outside those constructs is an error. Conditions and ordinary blocks are not breakable constructs.

```odin
for (cond) {
	switch (next_action()) {
	case .stop:
		if (cond) {
			break; // exits the innermost construct: the switch
		}
	case:
	}

	break; // exits the innermost construct: the for loop
}
```

### continue statement

`continue` starts the next iteration of the innermost enclosing `for` or `foreach`. It takes no operand, and using it outside a loop is an error.

```odin
for (cond) {
	if (get_foo()) {
		continue;
	}
	fmt.println("Hellope");
}
```

## Procedures

A procedure contains executable code. The `proc` keyword defines a procedure literal:

```odin
fibonacci :: proc(n: int) -> int {
	if (n < 1) {
		return 0;
	}
	if (n == 1) {
		return 1;
	}
	return fibonacci(n-1) + fibonacci(n-2);
}

fmt.println(fibonacci(3)); // 2
```

**Procedure literals do not capture local state.** A procedure literal can refer to constants, types, and file-scope declarations. It cannot refer to local variables or parameters of an enclosing procedure. Loke has no closures. A procedure value is one code pointer without an environment. Pass callback state explicitly, usually as a `rawptr` or typed user-data parameter.

This rule keeps [borrow and lifetime](#borrows-and-lifetimes) analysis local. A procedure literal cannot capture and retain a borrow.

### Parameters

A procedure can have zero or more parameters. This procedure multiplies two integers:

```odin
multiply :: proc(x: int, y: int) -> int {
	return x * y;
}
fmt.println(multiply(137, 432));
```

Consecutive parameters can share one type annotation. Thus, `x: int, y: int` can be written as `x, y: int`:

```odin
multiply :: proc(x, y: int) -> int {
	return x * y;
}
fmt.println(multiply(137, 432));
```

#### Parameter semantics and ABI lowering

By default, procedures use the `loke` calling convention. It uses the platform C ABI as a base and defines its own deterministic classification of parameters and results. It adds no implicit environment or service argument. Every caller and callee compiled for the same target ABI must use the same classification; indirect passing is not a choice they may make independently at each call.

The source-level parameter mode is decided before ABI lowering:

| Parameter form | Source-level meaning |
| --- | --- |
| `value: T` | Immutable local binding; no ownership transfer |
| `value: []T` | Immutable borrowed view with read-only elements |
| `value: []mut T` | Immutable borrowed view whose elements may be modified |
| `value: inout T` | Exclusive mutable borrow of the caller's variable |
| `value: move T` | Ownership transfer from caller to callee |

A normal `value: T` parameter never becomes an `inout` parameter only because of its machine-level representation. For a trivial value, it behaves as an immutable callee-local value. For a managed owner—including a struct or fixed array containing managed fields—the parameter is a non-owning immutable borrow for the duration of the call. Passing it does not clone its allocation or transfer ownership, and storage reached through it is protected by [Borrows and lifetimes](#borrows-and-lifetimes).

Returning such a borrowed managed parameter by value performs a logical clone, because the callee owns nothing it could move out. A mutable owner is cloned into `mem.default_allocator()` unless the procedure explicitly constructs the result with another allocator; immutable `string` and `shared(T)` retain their existing shared allocation under their normal clone rules. The copy-cost diagnostic reports this return clone, and returning a borrowed value whose clone operation is disabled is a compile-time error. In contrast, returning a managed local, named result, temporary, or `move` parameter transfers that owned value into result storage without cloning. A procedure that needs allocator-controlled result storage therefore takes an allocator parameter and writes the explicit clone or construction against it.

After applying those rules, the ABI may transport a parameter in registers, in an argument slot, or indirectly through a hidden pointer. Indirect transport normally points to temporary argument storage prepared by the caller:

```text
source:   inspect(value)
lowered:  temporary = argument representation
          inspect_lowered(&temporary)
```

The temporary remains valid until the call completes. It is not source-level pointer syntax, cannot be retained by the callee, and does not grant permission to modify the caller's variable. Taking `&value` inside the procedure behaves as taking the address of a callee-local binding, not the address of the caller's variable. An optimizer may reuse the caller's storage only when it proves that the difference is completely unobservable under these rules.

This lowering is an implementation detail of the `loke` calling convention. A foreign procedure follows its declared foreign ABI instead, including that ABI's rules for passing aggregates.

#### Copy-cost diagnostics

Size is never a type error. A large type also does not by itself require a warning: hidden-pointer lowering may already avoid moving a parameter's representation, and replacing a value with a pointer would change its aliasing, lifetime, nil, and mutation semantics.

An implementation should provide a configurable warning for an expensive copy or `clone`. A **copy site** is a point that duplicates a value instead of moving or borrowing it. Copy sites include:

- a trivial aggregate copied into a `value: T` parameter
- a binding such as `x := big_owner`
- an [assignment](#assignment-statements) such as `x = big_owner`
- return of a borrowed managed owner by value

An ordinary `value: T` parameter borrows a managed owner and is not a copy site. The diagnostic should identify the operation and its approximate cost:

```text
warning: this binding copies 8192 bytes from `source`
note: the copy could not be elided
help: use `move(source)` if `source` is no longer needed
help: take a pointer or `shared(T)` if the two names should share one value
```

The threshold is target-specific and is not part of the language semantics. The warning should be more prominent when the copy occurs in a loop or when a non-trivial `clone` may allocate. It must not recommend `inout` solely as an optimization, because `inout` grants mutation rights and changes which aliases are legal. Because the check is a diagnostic and not a rule, an editor may equally surface it as an inline copy marker at the site through the same [show-desugaring](#operator-lookup-and-overload-resolution) mechanism, making the cost visible without spelling it in the grammar.

```odin
sum :: proc(values: [dynamic]int) -> int {
	// `values` is a read-only borrow; no array copy is made.
	result := 0;
	foreach (value in values) {
		result += value;
	}
	return result;
}
```

`sum(values)` borrows, while `local := values` in the same procedure clones; both are unmarked and one character apart. A large or allocating copy at such a site is reported by the copy-cost diagnostic, not forbidden. When two names must refer to one value, take a pointer or `shared(T)`; when the source is finished, write `move`.

Use `inout` for a mutable borrow and `move` when a procedure must take ownership:

```odin
sort_in_place :: proc(values: inout [dynamic]int) {
	values.sort();
}

process_owned :: proc(values: move [dynamic]int) {
	values.sort();
	consume(values);
}

sort_in_place(inout numbers);
process_owned(move(numbers));
```

**Both non-default modes are required at the call site, not just at the declaration.** An argument to an `inout` parameter must be written `inout expr`, and an argument to a `move` parameter must be written `move(expr)`. Omitting the marker is an error naming the parameter and the mode it needs. This is what makes a call readable without consulting the callee's signature: a reader can see at the call which arguments may be modified and which are being given away.

`move(x)` is an [expression](#assignment-statements) that produces a value,
writes the inert representation to a lexical `x`, and marks it dead; it is
equally usable in an assignment or a `return`. It cannot target static-duration
storage. `inout x` is not an expression and produces no value; it selects a
parameter mode and may appear only in an argument position, in an
[`operator([])` result](#indexing-and-slicing), and where a mutable receiver is
passed. Method-call syntax supplies an `inout` or `move` marker implicitly for
its receiver: `numbers.sort()` may call an `inout self` method, and a consuming
method may move its receiver, without a separate marker before the receiver.
This is the deliberate point where call-site mode visibility yields to method
syntax: the value before `.` is treated as the visibly selected mutation or
consumption target, but a reader must know the receiver mode to distinguish
those effects. Non-receiver arguments receive no such exception. See
[Borrows and lifetimes](#borrows-and-lifetimes) for the complete rule and the
cases it does not cover.

### Shadowing parameters

To mutate an independent local copy instead of borrowing the caller's value, explicitly copy it through shadowing. Use an `inout` parameter when the caller's value should be modified directly.

```odin
foo :: proc(x: int) {
	x := x; // explicit mutation
	for (x > 0) {
		fmt.println(x);
		x -= 1;
	}
}
```

### Variadic parameters

A variadic procedure accepts a variable number of arguments:

```odin
sum :: proc(nums: ..int) -> (result: int) {
	result = 0;
	foreach (n in nums) {
		result += n;
	}
	return;
}
fmt.println(sum());              // 0
fmt.println(sum(1, 2));          // 3
fmt.println(sum(1, 2, 3, 4, 5)); // 15

odds := []int{1, 3, 5};
fmt.println(sum(..odds));        // 9, passing a slice as varargs
```

### Multiple results

A procedure can return zero or more results:

```odin
swap :: proc(x, y: int) -> (int, int) {
	return y, x;
}
a, b := swap(1, 2);
fmt.println(a, b); // 2 1
```

### Named results

A result can have a name. A named result is an initially dead local variable that exists for the complete procedure body. A `return` statement without expressions returns all named results and is valid only where every named result is definitely live. Use this short form only when the returned values are clear.

A named result is an ordinary local variable, not the caller's result storage. A bare `return` **moves** the named result variables into result storage, and only then do scope-exit actions run. A return with expressions evaluates those expressions directly into result storage and does not require the named locals to be live. This is why a `defer` cannot change a result: by the time it runs, result storage has already been filled. Because transfer of a named result is a move rather than a copy, a managed named result costs nothing extra, and its scope-exit cleanup is suppressed by the same liveness tracking described under [Managed values and storage](#managed-values-and-storage).

```odin
do_math :: proc(input: int) -> (x, y: int) {
	x = 2*input + 1;
	y = 3*input / 5;
	return x, y;
}
do_math_with_naked_return :: proc(input: int) -> (x, y: int) {
	x = 2*input + 1;
	y = 3*input / 5;
	return; // A "naked" return statement, as no values are explicitly specified.
}
```

A named result has no initializer syntax. It starts dead and is assigned in the body like any other uninitialized local:

```odin
conditionally_blue :: proc(red: bool) -> (color: string) {
    if (red) {
        return "red";
    }
    color = "blue";
    return;
}
```

### Named arguments

A call can name its arguments. Named arguments show the parameter for each value and do not depend on parameter order:

```odin
create_window :: proc(title: string, x, y: int, width, height: int, monitor: ^Monitor) -> (^Window, Window_Error) {...};

window, err := create_window(title="Hellope Title", monitor=nil, width=854, height=480, x=0, y=0);
```

One call can contain positional and named arguments. Positional arguments must occur before named arguments.

An `inout` argument may also be named, with the mode remaining visible after the `=`: `update(target=inout value)`. A named `move` argument uses the ordinary expression form, `store(value=move(source))`.

```odin
foo :: proc(value: int, name: string, x: bool, y: f32, z := 0) { };
foo(134, "hellope", x=true, y=4.5);
```

### Default values

A parameter can have a default value. The call uses the default when it omits that argument:

```odin
create_window :: proc(title: string, x := 0, y := 0, width := 854, height := 480, monitor: ^Monitor = nil) -> (^Window, Window_Error) {...};

window1, err1 := create_window("Title1");
window2, err2 := create_window(title="Title1", width=640, height=360);
```

An input parameter's default is an ordinary expression, not necessarily a
compile-time-known value. The expression is evaluated once for each call that
omits that argument; it is not evaluated when the caller supplies the
argument. Names in the expression are resolved in the lexical scope of the
procedure declaration.

A default may additionally reference `self` and ordinary parameters declared to
its left. It may not reference its own parameter or any parameter to its right,
even when a later parameter is supplied by name at a particular call. This makes
every referenced parameter initialized before the default is evaluated and
keeps the meaning independent of the caller's argument ordering. `$` parameters
are compile-time values and may be referenced when they are declared to the
left under the same rule.

Only ordinary value parameters may have defaults. An `inout` parameter needs a caller-owned place, a `move` parameter must show the ownership transfer at the call site, and a variadic parameter is supplied by its argument sequence; defaults on any of those three forms are therefore rejected.

Defaults belong to a named declaration, not to its procedure type. A call whose
callee is a directly named procedure, method, or procedure group may omit
arguments and uses the selected declaration's defaults. Once a procedure is
stored in a procedure value, passed as a callback, or otherwise called through
an expression whose static information is only a procedure type, the call must
supply every non-variadic parameter. This preserves the one-code-pointer
procedure representation and is why defaults do not participate in procedure
type compatibility.

Allocator-taking procedures conventionally default to the program provider. The
provider implementation is selected once by the final build, while its returned
`Allocator` remains an ordinary runtime value:

```odin
read_file :: proc(
	path: string,
	allocator := mem.default_allocator(),
) -> ([]byte, Error) {...}

data, err := files.read_file("data.bin");
scratch_data, scratch_err := files.read_file("scratch.bin", allocator=scratch);
```

The compiler-provided [`#caller_location`](#caller_location) expression is also
valid as a default and denotes the source location of the call. Defaults exist
only for parameters; a [named result](#named-results) has no initializer syntax
and starts dead.

### Explicit procedure overloading

Procedure overloads are declared explicitly as named procedure groups:

```odin
bool_to_string :: proc(b: bool) -> string {...};
int_to_string  :: proc(i: int)  -> string {...};

to_string :: proc{bool_to_string, int_to_string};
```

Each member retains its ordinary name and may be called directly. A call through
the group uses the overload-resolution rules defined below. An unresolved tie is
a compile-time error.

```odin
foo :: proc{
	foo_bar,
	foo_baz,
	foo_baz2,
	another_thing_entirely,
}
```

# Basic types

Loke provides the following basic types.

bool

`bool` is the only logical type. It is one byte and has the representation of C `_Bool`.

There are no sized boolean types. A boolean-like foreign typedef binds as its
integer representation: Win32 `BOOL` and Xlib `Bool` are `i32`, and OLE's
`VARIANT_BOOL` is an `i16` whose true value is `-1`. A wrapper converts that
representation to `bool` at the foreign boundary.

```odin
foreign user32 {
	@(link_name="IsWindowVisible") is_window_visible_raw :: proc(window: Hwnd) -> i32 ---;
}

is_window_visible :: proc(window: Hwnd) -> bool {
	return is_window_visible_raw(window) != 0;
}
```

Loke does not provide a `b32` type. Foreign bindings must use the integer representation from the foreign API and convert it to `bool` in a wrapper.

```odin
// integers
int  i8 i16 i32 i64 i128
uint u8 u16 u32 u64 u128 uintptr

byte // predeclared alias for `u8`, not a distinct type
```

f16 f32 f64 // floating point numbers

```odin
rune // signed 32 bit integer
	 // represents a Unicode code point
	 // is a distinct type to `i32`
     // no attempt is made to handle multi-code-point symbols; that is a deep rabbit hole.

// text
string  // immutable, valid UTF-8

// raw pointer type
rawptr

// compile-time-only type of types
type

// runtime type information and erased view types
typeid
any_view
```

`uintptr` has the size of a pointer. `int` and `uint` have the natural register size. Their size is not less than the size of a pointer: `size_of(uint) >= size_of(uintptr)`. Use `int` for a general integer. Use a fixed-size or unsigned type when its range or representation is necessary. Loke `int` is not C `int`. See [Foreign-ABI-safe types](#foreign-abi-safe-types).

The `string` representation is implementation-defined, but its byte length is available in O(1) time. Foreign calls use `cstring_view` and temporary zero-terminated conversions. Loke does not have a second owning C-string type.

## Zero values

Every runtime value type has a zero value. A lexical local requests it
explicitly with an initializer such as `x: T = {};`; omitting the initializer
instead leaves that local dead. File-scope, `static`, and `thread_local`
variables receive the zero value when they omit an initializer.

The zero value is:

- `0` for numeric and rune types
- `false` for `bool`
- `""`, the empty string, for `string`
- an empty, immediately usable value with no backing allocation for `[dynamic]T` and `map[K]V`. `len` and `cap` are 0, and appending or inserting is legal without any prior construction. Unless its declaration has `via`, this value is allocator-unbound until the first operation that allocates
- `nil` for pointer, multi-pointer, `rawptr`, procedure, `typeid`, slice, `string_view`, `cstring_view`, union, `any_view`, every `dyn Interface`, `shared(T)`, and `weak(T)` type. A nil slice or view has length 0 and points to no storage; a nil union holds no variant

Aggregate zero values are formed recursively from their fields. A type with a custom `drop` hook has an additional invariant: its zero value must be an inert, valid state on which `drop` performs no external action. Explicit `{}` initialization, zero-initialized static-duration storage, fallible operations that return zero with an error, and compiler-generated lifecycle code can all produce this live zero value. A resource whose machine representation uses zero for a live handle must carry a separate validity field, translate the handle representation, or disallow direct representation as an owning value.

The expression {} can be used for every runtime value type to request its zero value. Compile-time-only `type` and reflection descriptors have no zero value. This spelling is not recommended when a type has a clearer specific zero value shown above.

### Type conversion

The expression `T(v)` converts `v` to type `T`.

```odin
i: int = 123;
f: f64 = f64(i);
u: u32 = u32(f);
```

or with type inference:

```odin
i := 123;
f := f64(i);
u := u32(f);
```

An assignment between different types requires an explicit conversion, unless an implicit conversion rule applies.

# Untyped types

Some constant expressions are initially **untyped**. Context can implicitly convert an untyped value to a compatible concrete type.

```odin
I :: 42;        // untyped integer; may convert to a compatible integer or floating type
F :: 1.27;      // untyped float; may convert only to a floating type
S :: "Hello"; // untyped string, implicitly converts to string
B :: true;      // untyped boolean, implicitly converts to bool
```

(The more formal name for these “untyped” types is existential or abstract types.)

# Built-in constants, values, and procedures

## Built-in constants

```text
false // untyped boolean constant equivalent to the expression 0!=0
true  // untyped boolean constant equivalent to the expression 0==0
```

## Built-in values

```text
nil   // untyped nil value used for certain values
```

`---` is not a value or an initializer. It is declaration syntax used for a
foreign procedure with no Loke body and for explicitly disabled lifecycle hooks.
Uninitialized lexical storage is requested by omitting a local initializer and
is governed by definite-initialization analysis rather than undefined behavior.

## Built-in procedures

There are two kinds of built-in procedures:

- Compiler defined
- Core library defined

For the full list, see the documentation for package `builtin`. The compiler-defined ones used by normative text in this document are:

| Procedure | Result |
| --- | --- |
| `len(value)`, `cap(value)` | Element or byte count, and capacity. Constant when the operand is constant |
| `size_of(T)`, `align_of(T)` | Size and alignment in bytes; compile-time constants. Accept a type or an expression |
| `offset_of(T, field)` | Byte offset of a field; a compile-time constant |
| `type_of(expr)` | The compile-time [`type`](#type-and-typeid) of an expression |
| `typeid_of(T)` | The runtime [`typeid`](#type-and-typeid) constant for a compile-time type |
| `type_info_of(id)` | `^runtime.Type_Info` for a `typeid` |
| `fields_of(T)`, `enum_values_of(T)` | Typed [compile-time reflection](#compile-time-reflection) descriptor arrays |
| `assert(condition, message := "")` | Phase-neutral check; failure panics at runtime or diagnoses a required compile-time evaluation |
| `panic(message)` | Panics at runtime or diagnoses the currently evaluated compile-time call |
| `new`, `new_clone`, `make`, `free`, `free_all`, `drop` | [Allocation and release](#allocators) |
| `exchange(inout destination, replacement)` | Replace a live place and return its previous value; see [Exchange](#exchange) |
| `transmute(T, value)` | Bit cast between two same-sized types with a [trivial lifecycle](#transmute-procedure) |
| `move(value)` | Keyword form, not a call; see [assignment](#assignment-statements) |

`len`, `cap`, `size_of`, `align_of`, and `offset_of` all result in `int`.

`assert` and `panic` execute in the phase of the call that reaches them. In an
ordinary runtime call they have their runtime behavior. In a procedure whose
result is required at compile time, reaching a failed `assert` or any `panic`
produces a compilation diagnostic with the evaluator call stack. `-no-assert`
may remove runtime assertions, but it never removes an assertion reached during
required compile-time evaluation.

[`#assert`](#assertboolean) independently requires its operand and check at
compile time, even when it appears inside code that otherwise executes at
runtime. `#assert(false, message)` is therefore the compile-time
unconditional-failure form. Neither spelling silently changes phase.

`move`, `drop`, and `exchange` operate on a **place** rather than only on values.
`move` is a keyword and looks like one; `drop` and `exchange` keep call
spellings but are equally compiler special forms, as described under
[Managed values and storage](#managed-values-and-storage) and
[Exchange](#exchange). Every other built-in listed here is an ordinary call.

`transmute(T, value)` is a bit cast conversion between two types of the same size. Both the source and destination must have a **trivial lifecycle**: they have no custom `try_clone` or `drop`, contain no managed owner, and are recursively bitwise-copyable. This prevents a bit cast from duplicating an owning representation or manufacturing a value whose cleanup invariant was never established.

```odin
f := f32(123);
u := transmute(u32, f);
```

It is an ordinary compile-time built-in procedure, not an operator: `transmute` is a predeclared identifier rather than a keyword, its first argument is a type in the same way `size_of(T)` and `new(T)` take one, and it binds like any other call.

This is akin to doing the following pointer cast manipulations:

```odin
f := f32(123);
u := (^u32)(&f)^;
```

However, `transmute` does not require taking the address of the value in question, which may not be possible for many expressions. `transmute` cannot reinterpret a managed or resource-owning value. Low-level code may inspect or manipulate such representations through raw storage in `core:unsafe`, but it is then responsible for establishing exactly one initialized owner; the language provides no safe bit-cast shortcut around lifecycle hooks.


# string type

`string` is an immutable, owning UTF-8 value. It behaves like a simple local variable: it can be assigned, returned, and stored without requiring explicit construction, cleanup, or `defer`.

```odin
first := "hello";
second := first; // cheap value copy; immutable backing storage may be shared
message := first + " world";
```

A string literal uses static storage. A string created at runtime owns a managed backing buffer. Implementations may use reference counting, small-string optimization, interning, or another representation, but these choices do not change language semantics. Because strings are immutable, sharing their backing storage is never observable as mutable aliasing.

If an implementation shares backing storage between string values, its reference
count must be atomic so concurrent handle accounting cannot corrupt the storage.
The last drop also deallocates through the string's bound allocator. As with
other owners, transferring such a string between threads is valid only when that
allocator permits deallocation on either thread; the compiler does not prove
this property in version 1. Code that does not want shared ownership can pass
`[]u8` or `string_view`, neither of which is an owner.

`string` always contains valid UTF-8. Arbitrary binary data uses `[]u8` or `[dynamic]u8`. Converting arbitrary bytes to a string validates the input and returns an error if it is not valid UTF-8.

String operations make their unit explicit:

```odin
text := "Hej, världen";
byte_count := text.byte_len();    // O(1)
rune_count := text.rune_count();  // O(n), Unicode scalar values
bytes := text.bytes();            // read-only borrowed []u8
```

`len(text)` is shorthand for `text.byte_len()` so that it remains a constant-time operation. Direct integer indexing of a string is not allowed because a UTF-8 code point may contain multiple bytes. Use `text.bytes()[index]`, iteration, or Unicode library procedures instead.

Grapheme clusters—what a user perceives as a displayed character—are handled by the Unicode library rather than by the core string type.

Repeated concatenation should use `String_Builder` from `core:strings`, a managed mutable buffer. It is an ordinary library type with no compiler support, built from `[dynamic]u8`:

```odin
builder: String_Builder = {};
builder.append("hello");
builder.append(' ');
builder.append("world");
message := builder.finish(); // moves the buffer into an immutable string when possible
```

## String iteration

String iteration yields Unicode scalar values by default. Byte iteration is explicit.

**The second name in a string loop is a byte offset, not a rune counter.** It is the index at which the yielded code point begins, so it advances by 1 to 4 per step and the loop's final offset is not `len(x) - 1`. This is the unit that can be fed back into `x.bytes()`, a slice expression, or a low-level API; a rune ordinal cannot, and a string carries no O(1) way to produce one.

```odin
// by runes: `offset` is a byte offset into the string
x := "AÅ✓";
foreach (codepoint, offset in x) {
	fmt.println(offset, codepoint);
	// 0 A     (1 byte)
	// 1 Å     (2 bytes)
	// 3 ✓     (3 bytes)
}
assert(len(x) == 6);

// by bytes: `index` is an ordinary slice index, so here the two coincide
foreach (byte, index in x.bytes()) {
	fmt.println(index, byte);
	// 0 65
	// 1 195
	// ...
}
```

Code that needs a running rune ordinal counts it itself, which costs one local and makes the difference visible:

```odin
ordinal := 0;
foreach (codepoint, offset in x) {
	fmt.println(ordinal, offset, codepoint);
	ordinal += 1;
}
```

String indices used by low-level APIs are byte offsets throughout. Unicode procedures that operate on runes or grapheme clusters state that unit in their names.

## String format printing

Formatting is a library protocol. A user type provides a visible `format(value, writer, options)` overload; byte-buffer interpretations and field tags belong to `core:fmt`, not the language specification.

# C string views

`cstring_view` is a non-owning, zero-terminated byte view — the type a C `char const *` maps to. It does not promise UTF-8 because foreign strings frequently use another encoding or arbitrary bytes. A view received from foreign code has no owner known to the compiler, so keeping it alive is the programmer's responsibility, as with anything crossing the [foreign boundary](#what-is-not-checked). Converting it to `string` scans for the terminator, validates UTF-8, and copies into owned storage.

A string literal may initialize a `cstring_view` because its zero-terminated bytes have static lifetime. A runtime `string` uses `to_c_view()`, which adds a terminator only when necessary and returns a temporary view valid for that complete expression. The temporary cannot be assigned, returned, or stored:

```odin
static_name: cstring_view = "Hellope";
text, ok := string(static_name); // validates and copies
c_api(runtime_name.to_c_view()); // temporary lives through this call
```

Code that must retain an owned zero-terminated buffer uses the ordinary library type `C_String` from `core:cstrings`. It is implemented with `[dynamic]u8`, exposes `view() -> cstring_view`, and has no compiler privileges.

# string type conversions

Safe conversions return managed values or explicitly borrowed views. They never hide a mutable alias.

`string_view` is an immutable, validated UTF-8 borrow represented by a pointer and a byte length. It has the same byte, rune, and iteration operations as `string`, but it has no allocator and does not own or terminate its storage. A `string_view` derived from a slice is a borrow of that slice's owner and cannot outlive it. Creating one from a pointer whose owner the compiler cannot identify requires `unsafe.string_view`.

**A `string` converts implicitly to a `string_view`,** and to a view of any of its subranges through slicing. The conversion is a borrow of the string, it costs nothing, and it needs no validation because a `string` is already valid UTF-8 by construction. String literals convert the same way, with static lifetime.

```odin
byte_count :: proc(text: string_view) -> int { return len(text); }

owned := "Hej, världen";
n := byte_count(owned);          // implicit borrow, no copy
m := byte_count(owned[5:]);      // a subrange view
```

This makes `string_view` the parameter type for anything that only reads text, and `string` the type for anything that stores it. Without the conversion the two would compete for every signature: an API taking `string` cannot accept a substring without allocating one, and an API taking `string_view` would force every caller holding a `string` to write a conversion. One implicit borrow removes the choice, in the same way an ordinary `value: T` parameter of a managed owner is [already a borrow](#parameter-semantics-and-abi-lowering).

The conversion runs one way only. A `string_view` becomes a `string` with `.clone()`, which allocates, because the result must own its bytes.

A conversion that validates input has [optional-ok semantics](#optional-ok-results): it produces `(value, ok: bool)`. On invalid input, `value` is the zero value and `ok` is false. It can be handled with the comma-ok form or with `or_else`; postfix `?` is not a conversion or error-propagation operator.

```odin
text, ok := string(bytes);
if (!ok) {
	// `bytes` was not valid UTF-8.
}
text = string(bytes) or_else "";
```

Legend:

- copy = create an independent managed value
- share = share immutable backing storage
- borrow = create a non-owning view, subject to [Borrows and lifetimes](#borrows-and-lifetimes)
- stream = get individual values from the string, without allocation
- st = the input string

There is no general `const` qualifier in the language, and nothing else stands in for one. Slice capability is expressed directly by its type: `[]T` is read-only and `[]mut T` permits mutation of elements. A view obtained from a `string` is therefore `[]u8`; it cannot be converted to `[]mut u8`. The other read-only storage in a program — a [materialized constant](#materialization) — is read-only because of how it was declared, not because a qualifier was applied to it.

**Pointers carry no read-only capability: there is no `^const T`.** A `^T`
created by `&` is therefore a checked mutable borrow. Read-only access to a
sequence is spelled `[]T`. Read-only access to a single value is an ordinary
`value: T` parameter, which is already an immutable borrow for a managed owner
and never copies its allocation; `inout T` opts into mutation.

Checked provenance follows a local `^T` and its copies until it is stored in an
untracked place or explicitly converted through `core:unsafe`. A `^T` loaded
from such a place or received from foreign code is an unchecked address. Code
that wants a checked read-only view of one element passes a `[]T` of length one
or restructures to take the value.

## From string to X

| To | Action | Code |
| --- | --- | --- |
| `[]u8` | borrow | `st.bytes()` |
| `string_view` | borrow, implicit | `view: string_view = st` |
| `string_view` | borrow a subrange | `st[low:high]` |
| `string` | share | `new_string := st` |
| `string` | copy | `st.clone()` |
| `cstring_view` | temporary borrow | `st.to_c_view()` |
| `[]rune` | stream | `foreach (rune in st) { ... }` |
| `[dynamic]rune` | copy | `st.to_runes()` |
| `[^]u8` | unsafe borrow | `unsafe.raw_data(st.bytes())` |

## From cstring_view to X

| To | Action | Code |
| --- | --- | --- |
| `string` | validate and copy, optional-ok | `string(st)` |
| `[^]u8` | unsafe borrow | `unsafe.raw_data(st)` |

## From a string literal to X

| To | Action | Code |
| --- | --- | --- |
| `string` | share static storage | `newstr: string = st` |
| `cstring_view` | borrow static storage | `newstr: cstring_view = st` |

## From []u8 to X

| To | Action | Code |
| --- | --- | --- |
| `string` | validate and copy, optional-ok | `string(st)` |
| `string_view` | validate and borrow, optional-ok | `string_view(st)` |
| `[^]u8` | unsafe borrow | `unsafe.raw_data(st)` |

## From []rune to string

| Action | Code |
| --- | --- |
| validate and copy, optional-ok | `string.from_runes(st)` |

## From [^]u8 to cstring_view

| Action | Code |
| --- | --- |
| unsafe borrow | `unsafe.cstring_view(st)` |

## From [^]u8 and length int to string

| Action | Code |
| --- | --- |
| validate and copy, optional-ok | `string(ptr[0:length])` |
| unsafe validate and borrow, optional-ok | `unsafe.string_view(ptr, length)` |

# Operators

Operators combine operands into expressions. For binary operations, operand types must be identical, implicitly convertible, or accepted by a visible user-defined overload. User-defined behavior is described in the User-defined abstractions section.

## Arithmetic operators

Unary:

```text
+                           is 0 + x
-    negation               is 0 - x
~    bitwise complement     is m ~ x where m = "all bits set to 1" for unsigned x
                                     and m = -1 for signed x
```

Binary:

```text
+       sum, string concatenation  integers, floats, strings
-       subtraction                integers, floats
*       multiplication             integers, floats
/       division                   integers, floats
%       remainder (truncated)      integers

|       bitwise or                 integers
~       bitwise xor                integers
&       bitwise and                integers
&~      bitwise and-not            integers
<<      left shift                 integer << unsigned integer
>>      right shift                integer >> unsigned integer
```

Except for shift operations, if one operand is an untyped constant and the other operand is not, the constant is implicitly converted to the type of the other operand (if possible).

**`+` concatenates strings at compile time and runtime.** For two `string` operands, `a + b` returns a new owning `string`. It contains the bytes of `a` followed by the bytes of `b`. Both operands contain valid UTF-8, so the result does not need validation.

Two constant operands produce a constant without runtime storage. Otherwise, the operation allocates from `mem.default_allocator()` and follows its [failure policy](#allocation-failure). A `string` and a `string_view` can occur in either order. Two `string_view` operands also produce an owning `string`.

This is the ordinary convenient spelling and it is the right one for building a message out of two or three pieces. It is the wrong one for a loop: each `+` allocates and copies the whole accumulated result, so repeated concatenation is quadratic. Use `String_Builder` from `core:strings`, which is also how code selects an allocator other than the default. The [copy-cost diagnostic](#copy-cost-diagnostics) reports a concatenation in a loop for the same reason it reports a large copy there.

Enum values do not support arithmetic or bitwise operators. An enum's members are named constants that need not be contiguous, so `Foo.A + Foo.B` need not be a member of `Foo` and has no useful meaning; convert to the backing integer type when arithmetic is intended. Flag sets are the library type `Bit_Set(Enum)` rather than bitwise operators on the enum itself. Enums remain [comparable and ordered](#comparison-operators).

The right operand in a shift expression must have an unsigned integer type or be an untyped constant representable by a typed unsigned integer. If the left operand of a non-constant shift expression is an untyped constant, it is first implicitly converted to the type it would assume if the shift expression were replaced solely by the left operand alone (with type inference and hinting rules applied).

## Comparison operators

```text
==      equal
!=      not equal
<       less
<=      less or equal
>       greater
>=      greater or equal
```

In any comparison, the first operand must be assignable to the type of the second, or vice versa.

The equality operators == and != apply to operands that are comparable. The ordering operators <, <=, >, and >= apply to operands that are ordered. These terms and the result of the comparisons are defined as follows:

- `bool` values are comparable.
- Integers values are comparable and ordered.
- Floating-point values are comparable and ordered, defined by the IEEE-754 standard.
- Rune values are comparable and ordered.
- `string` and `string_view` values are comparable and ordered, lexically byte-wise.
- Pointer and multi-pointer values are comparable. Equality compares addresses. Ordering compares the addresses as unsigned `uintptr` values, producing a total order within one execution even for pointers to unrelated allocations. Address-space randomization means that this order need not be reproducible between executions. On a target where a pointer cannot be represented losslessly by `uintptr`, ordering pointers is not supported and use of `<`, `<=`, `>`, or `>=` on them is a compile-time error.
- Enum values are comparable and ordered.
- Struct values are comparable if all their fields are comparable or a visible comparison overload is provided.
- Union values are comparable if all their variants are comparable or a visible comparison overload is provided.
- Array values are comparable if values of the element type are comparable.
- typeid is comparable.
- `Simd(T, N)` vectors are comparable.
- Slices, dynamic arrays, maps, and `dyn Interface` views are **not** comparable and may be tested only against `nil`. A fixed array is therefore comparable element-wise while a slice of that same array is not. Compare contents or behavior with an explicit library procedure.

## Logical operators

Logical operators apply to boolean values. The right operand is evaluated conditionally

```text
&&      conditional AND    a && b  is "b if a else false"
||      conditional OR     a || b  is "true if a else b"
!       NOT                !a      is "not a"
```

## Compound binary operator and assign

Like many other languages, eager arithmetic and bitwise operations have a shorthand for updating a place, such as `x += 5`. Short-circuiting logical operations do not; write `x = x && y` explicitly.

```text
+=       sum and assign                   a += b is a = a + b
-=       subtraction and assign           a -= b is a = a - b
*=       multiplication and assign        a *= b is a = a * b
/=       division and assign              a /= b is a = a / b
%=       remainder (truncated) and assign a %= b is a = a % b

|=       bitwise or and assign            a |= b is a = a | b
~=       bitwise xor and assign           a ~= b is a = a ~ b
&=       bitwise and and assign           a &= b is a = a & b
&~=      bitwise and-not and assign       a &~= b is a = a &~ b
<<=      left shift and assign            a <<= b is a = a << b
>>=      right shift and assign           a >>= b is a = a >> b
```

## Address operator

For an operand `x` of type `T`, `&x` returns a `^T` pointer to `x`. The operand must be addressable. The following operands are addressable:

- a variable or pointer dereference
- an index of a mutable slice, dynamic array, or addressable fixed array
- a visible [`operator([])` that returns `inout T`](#indexing-and-slicing)
- a field of an addressable, non-packed struct
- a type assertion of an addressable union
- a composite literal

An `any_view` is not addressable. An element reached through `[]T` is not addressable. An individual field of an `@(packed)` struct is not addressable.

`&` is always single-valued: every addressable operand yields exactly one pointer. A container whose lookup may fail supplies a method instead, as the built-in map does with [`m.find(key)`](#maps).

For an operand x of pointer type ^T, the pointer indirection x^ denotes the variable of type T pointed to by x. Explicit `x^` and implicit dereferences such as `x.field` test for nil and raise a runtime panic before accessing memory. This is a language guarantee; an implementation may use a hardware fault only when it preserves the same observable panic behavior. Dereferencing a non-nil address that is dangling, misaligned, or otherwise invalid is undefined behavior. Such an address can arise only through an unchecked lifetime hole, raw-pointer manipulation, or foreign code.

```odin
&x;
&a[foo(123)];
&Foo{1, 2};
p^;
pproc(a)^;

x: ^int = nil;
x^;      // causes a runtime panic
```

## Conditional expression

```odin
x if cond else y;
```

The condition may be a compile-time constant, in which case the result is also constant when the selected value is constant. Compile-time source selection that must leave the unselected branch unchecked uses a `when` statement. There is no second `when` expression or C-style `cond ? x : y` spelling.

## Other operators

- or_else
        see section on or_else
- or_return
        see section on or_return
- in - set membership (e in A, A contains element e)
        Used for map types and visible user-defined container operators
- ..= - inclusive range
- ..< - half open range

The range operations ..= and ..< are only possible within certain contexts:

```odin
foreach (x in a..<b) {}
foreach (x in a..=b) {}

switch (x) {
case a..<b:
case c..=d:
}
```

```odin
foo := [?]int{0..=3 = 1}; // initialises as: [1, 1, 1, 1]
bar := [?]int{0 = 0, 1..<3 = 1}; // initialises as: [0, 1, 1]
```

The `in` in a `foreach` header separates bindings from the iterable expression. In an ordinary `for` condition, `in` retains its usual membership-operator meaning, so no contextual parsing exception is needed:

```odin
foreach (x in y) {} // iteration
for (contains(y, x)) {} // condition-only loop
```

## Evaluation order

Except for the explicitly lazy operators `&&`, `||`, `or_else`, and the conditional expressions, expression evaluation is deterministic:

- A call evaluates its receiver, if any, and then its supplied arguments from left to right. It binds those supplied values to parameters, then evaluates omitted default arguments once in parameter order. A default may read only the receiver and parameters declared to its left, so each such binding is already initialized. Each default otherwise uses the lexical scope of its procedure declaration.
- A binary expression evaluates its left operand and then its right operand. An operator overload receives those already evaluated values and does not change their order.
- Array, struct, union, map, and container literal elements are evaluated in source order. A named struct literal still uses source order rather than field declaration order.
- A simple or multiple assignment evaluates all right-hand expressions from left to right before evaluating destination place expressions from left to right. Writes then occur from left to right, but only after every value and destination has been prepared. If a required clone fails, no destination is written. This makes swaps well-defined and prevents a failed later clone from partially updating an earlier destination; side effects already performed while evaluating an earlier right-hand expression, including an explicit `move`, are not rolled back.
- A compound assignment evaluates its destination place once, then evaluates the right operand, then performs the operation and write.
- Return expressions are evaluated from left to right before being moved into result storage.

Temporaries created by a complete expression are destroyed at its end in reverse order of completed initialization. Short-circuiting and conditional expressions evaluate only the selected operands, as described by their individual rules. These rules apply equally to built-in and user-defined operations.

## Operator precedence

Postfix operators bind tightest, then unary operators, then the binary levels below.

There are seven precedence levels for binary operators and the conditional expression.

```text
Precedence    Operator
     7           *   /   %   &   &~  <<   >>
     6           +   -   |   ~
     5           ==  !=  <   >    <=  >=   in
     4           &&
     3           ||
     2           ..=    ..<
     1           or_else     if
```

`in` sits at the comparison level because it produces a `bool` and is used where a comparison would be. At the additive level `x in values + extra` would group as `(x in values) + extra`, which is never what it looks like.

Binary operators of the same precedence associate from left to right. For instance x / y * z is the same as (x / y) * z. Level 2 is **non-associative**: `a ..< b ..< c` is a syntax error rather than a nested range, because a range takes two endpoints and neither grouping means anything.

**Level 1 is the exception: it associates from right to left.** This is what makes both of its forms chain the way they read:

```odin
a if c1 else b if c2 else d   // a if c1 else (b if c2 else d)
x or_else y or_else z         // x or_else (y or_else z)
```

The conditional groups as an else-if chain. `or_else` uses the same right grouping. Its left operand must be an [optional-ok expression](#optional-ok-results), and its result is an ordinary value. Left grouping would give the outer `or_else` an ordinary left operand and make a fallback chain invalid.

The postfix forms — call `()`, index `[]`, slice `[:]`, selector `.`, dereference `^`, type assertion `.(T)`, and `or_return` — are not in the table because they bind tighter than every unary and binary operator. They associate left to right among themselves. `-x^` is `-(x^)`, `f() or_return + 1` is `(f() or_return) + 1`, and `a.b().(T) or_else c` is `(a.b().(T)) or_else c`. `or_return` is postfix rather than binary because it takes no right operand; [Other operators](#other-operators) lists it alongside the binary forms only for discoverability.

## Integer operators

For two integers values x and y, the integer quotient q = x/y and remainder r = x%y satisfies the following relationships:

```odin
x = q*y + r   and |r| < |y|;
```

with x/y truncated towards zero (truncated division).

Floored remainder is the library procedure `floor_mod(x, y)`. It is useful but uncommon, and does not require a second remainder operator, precedence entry, overload family, and compound-assignment form.

The exception to these rules is when the dividend x is the most negative value for the integer type of x, and the quotient q = x/-1 is equal to x (and r = 0) under the wrapping two’s-complement rule below.

If the divisor is a constant, it must not be zero. If the divisor is zero at runtime, a runtime panic occurs.

The shift operators shift the left operand by the shift count specified by the right operand, whose type is an unsigned integer, so a negative count cannot arise. The shift operators implement arithmetic shifts if the left operand is a signed integer and logical shifts if the left operand is an unsigned integer. There is not an upper limit on the shift count. Shifts behave as if the left operand is shifted n times by 1 for a shift count of n. Therefore, x<<1 is the same as x*2 and x>>1 is the same as x/2 but truncated towards negative infinity.

A shift count that is equal to or greater than the width of the left operand has defined behavior. It is the limit of the repeated one-bit shift:

- `x << y` is `0` once `y >= 8*size_of(x)`, for both signed and unsigned `x`.
- `x >> y` is `0` once `y >= 8*size_of(x)` for unsigned `x` or non-negative signed `x`, and `-1` for negative signed `x`, because an arithmetic shift replicates the sign bit.

```odin
u: u32 = 1;
i: i32 = -1;
assert(u >> 32 == 0);
assert(i >> 32 == -1); // arithmetic shift saturates at the sign bit
assert(i << 32 == 0);
```

This differs from C, where such a shift count is undefined behavior. Defining it costs a masked or saturating shift sequence on targets whose instruction does something else, and buys a rule that does not silently change meaning under optimization.

### Integer overflow

For unsigned integers, the operations +, -, *, and << are computed modulo 2n, where n is the bit width of the unsigned integer’s type. In a sense, these unsigned integer operations discard the high bits upon overflow, and programs may rely on “wrap around”.

Every signed integer uses two’s-complement representation. For a signed type of width `n`, `+`, `-`, `*`, and `<<` compute the mathematical result modulo `2^n` and interpret the resulting bit pattern as that two’s-complement type. Division is truncated toward zero except that `MIN / -1` produces `MIN`; its remainder is zero. These results exist and are deterministic on every target, and overflow does not panic. A compiler may not optimize code under the assumption that signed overflow does not occur. For instance, `x < x+1` may not be assumed to be always true. Code in a measured hot loop that wants a no-overflow assumption states it explicitly — an explicitly sized unsigned type, a hoisted bound, or a narrowed index range — rather than inheriting it from every arithmetic expression.

## Floating-point operators

For floating-point types:

- +x is the same as x
- -x is the negation of x

Floating-point division by zero follows IEEE-754 and does not panic: a non-zero dividend produces `+Inf` or `-Inf` according to the signs of the operands, and `0.0/0.0` produces a NaN. Integer division by zero panics. Default floating-point exception handling is non-stop; a program that wants trapping behavior installs it through the target's floating-point environment.

An implementation may combine multiple floating-point operations into a single fused operation, and produce a result that differs from the value obtained by executing and rounding the instructions individually.

# User-defined abstractions

## General rules

Users must be able to create types that are as convenient to use as built-in types. A vector should support arithmetic, a matrix should support indexing, a range should support iteration, and a resource-owning type should participate in automatic cleanup.

User-defined syntax does not change parsing rules. Operators retain their built-in precedence, associativity, and operand evaluation order. An overload supplies behavior for an existing operation; it cannot invent new punctuation or rewrite surrounding syntax.

## Methods and implementation blocks

An `impl` block associates procedures and constants with a type. A first parameter named `self` is the receiver. Its type may be written explicitly or inferred from the `impl` type.

```odin
Vector2 :: struct {
	x, y: f32,
}

impl Vector2 {
	zero :: Vector2{0, 0};

	length_squared :: proc(self) -> f32 {
		return self.x*self.x + self.y*self.y;
	}

	scale :: proc(self: inout Vector2, factor: f32) {
		self.x *= factor;
		self.y *= factor;
	}
}

v := Vector2{3, 4};
length2 := v.length_squared();
v.scale(2);
origin := Vector2.zero;
```

Method-call syntax is uniform procedure-call syntax:

```odin
v.length_squared();
// equivalent to
Vector2.length_squared(v);
```

An unqualified `self` is an immutable borrow. `self: inout Type` is a mutable borrow, and `self: move Type` consumes the receiver. Associated procedures and constants without `self` are accessed through the type name.

An `extend` block may add methods or operators to a type declared in another package:

```odin
extend vendor.Vector2 {
	to_string :: proc(self) -> string {
		return fmt.tprint("({}, {})", self.x, self.y);
	}
}
```

An extension participates in method and operator lookup only inside the package that declares the `extend` block. Importing that package exposes the extension's named procedures through ordinary qualification, but does not add its methods or operators to implicit lookup. An otherwise unused import therefore cannot change or make ambiguous an existing expression.

Code that wants method syntax for a foreign extension declares a small local forwarding extension. This is an explicit opt-in at the point where the additional behavior becomes part of lookup, and ordinary ambiguity diagnostics apply within that package. Ordinary expression lookup needs no global orphan rule; cross-package protocols whose correctness depends on one stable operation, such as map hashing, state their stricter coherence rule separately.

Generic declarations use **definition-site lookup**. Substituting concrete generic arguments may reveal inherent operations of those concrete types, but it does not add extensions from the caller's package to the candidate set used by the generic body or its interface requirements. An interface application written outside a generic declaration uses the lexical package containing that application. Consequently the same generic instantiation has the same meaning in every caller, and a caller-local extension cannot make a requirement appear satisfied when the generic body could not call the corresponding operation.

Field lookup takes priority over method-call sugar. Inherent and extension methods otherwise use normal overload resolution. Methods can be collected into explicit procedure groups just like free procedures.

### Receiver forms

There are three receiver modes, and no others:

| Receiver | Meaning |
| --- | --- |
| `self` | Immutable borrow of the value |
| `self: inout Type` | Exclusive mutable borrow of the caller's variable |
| `self: move Type` | Consumes the receiver |

All three are reached through `value.method()`, and the call site supplies the
`inout` or `move` marker implicitly, as described under
[Parameter semantics](#parameter-semantics-and-abi-lowering). A `move self`
method cannot be called on file-scope, `static`, or `thread_local` storage,
because it would leave that storage dead; first use `exchange` to install a live
replacement and call the consuming method on the returned local value. The
immutable receiver may write its type explicitly as `self: Type` when that reads
better; the two spellings are the same mode.

A first parameter declared `self: ^Type` is **not** a receiver. It is an ordinary pointer parameter that happens to carry the name, so it gets no method-call sugar and must be called as `Type.method(pointer)`. It exists for code that genuinely manipulates an address, such as an intrusive data structure. Mutating methods use `inout self`; pointer receivers are not the way to spell mutation.

### Generic types

An `impl` or `extend` block may name a generic type by writing its shape, binding the parameters with `$` exactly as a [specialized](#specialization) procedure parameter does. The bound names are in scope throughout the block:

```odin
Table :: struct($Key, $Value: type) {
	count:     int,
	allocator: mem.Allocator,
	slots:     []mut Table_Slot(Key, Value),
}

impl Table($Key, $Value) {
	len :: proc(self) -> int {
		return self.count;
	}

	find :: proc(self, key: Key) -> (Value, bool) {
		...
	}

	insert :: proc(self: inout Table(Key, Value), key: Key, value: Value) {
		...
	}
}

table: Table(string, int) = {};
table.insert("a", 1);
value, ok := table.find("a");
```

Where the receiver's type is written out rather than inferred — `inout` and `move` receivers, and every non-receiver mention — the bound names are used without `$`, because `$` marks a binding site and these are uses.

A block may also be written for one specialization, `impl Table(string, int) { ... }`, in which case its methods apply only to that instantiation. When both are visible, the more specialized block wins by tie-breaker 4 of [overload resolution](#operator-lookup-and-overload-resolution). Constraints use a `where` clause on the individual procedure, not on the block.

This is what lets a generic container satisfy an [interface](#interfaces-and-generic-operators): requirements such as `(v: inout T, element: T.Element) v.append(element);` use method syntax, so a generic type with no way to declare methods could never satisfy one.

## Operator declarations

An operator implementation is an ordinary named procedure marked with `operator(symbol)`. The name allows direct calls, documentation lookup, function values, and explicit disambiguation.

```odin
impl Vector2 {
	add :: operator(+) proc(left, right: Vector2) -> Vector2 {
		return {left.x + right.x, left.y + right.y};
	}

	negate :: operator(-) proc(value: Vector2) -> Vector2 {
		return {-value.x, -value.y};
	}

	equal :: operator(==) proc(left, right: Vector2) -> bool {
		return left.x == right.x && left.y == right.y;
	}
}

a := Vector2{1, 2};
b := Vector2{3, 4};
c := a + b;
d := -c;

// The named form is always available.
e := Vector2.add(a, b);
```

Both operands may have the same type or different types. The return type may also differ:

```odin
impl Matrix4 {
	transform_point :: operator(*) proc(matrix: Matrix4, point: Vector3) -> Vector3 {
		...
	}
}
```

Operator declarations may be grouped and overloaded:

```odin
add :: operator(+) proc{
	add_vector2,
	add_vector3,
	add_matrix,
};
```

The following operations may be overloaded:

| Category | Operators |
|-  --| --- |
| Unary | `+`, `-`, `!`, `~` |
| Arithmetic | `+`, `-`, `*`, `/`, `%` |
| Bitwise and shifts | `|`, `~`, `&`, `&~`, `<<`, `>>` |
| Comparison | `==`, `!=`, `<`, `<=`, `>`, `>=` |
| Membership | `in` |
| Compound assignment | `+=`, `-=`, `*=`, `/=`, `%=`, `|=`, `~=`, `&=`, `&~=`, `<<=`, `>>=` |
| Structural syntax | `[]`, `[]=`, `[:]` |

`!=` falls back to `!(left == right)` when `==` is available and no more specific `!=` overload exists. A compound assignment falls back to the corresponding binary operator followed by ordinary assignment. A direct compound overload can avoid a temporary or allocation:

```odin
impl Big_Int {
	add_assign :: operator(+=) proc(left: inout Big_Int, right: Big_Int) {
		left.add_in_place(right);
	}
}
```

Assignment (`=`), declaration (`:=`), member access (`.`), address-of, pointer dereference, `move`, and `drop` are not ordinary overloadable operators. They are tied to storage and lifetime rules; user-defined value behavior is provided by the lifecycle hooks described below.

`&&`, `||`, `or_else`, and the conditional expression control whether an operand is evaluated and are not overloadable.

## Operator lookup and overload resolution

Operator lookup considers built-in operations, inherent implementations, and extension implementations declared in the current package. Operators may be defined for any operand types, including types from other packages and built-in types. Imported extension packages remain available through their qualified named procedures but do not alter operator lookup.

Lexical scope is considered before type ranking, so a local operator set can shadow an outer one for the types it covers.

**Built-in operations cannot be shadowed.** If every operand of an expression is a built-in type *and a built-in operation is defined for that operator on those operands*, the built-in operation always wins, regardless of what is in scope. `a + b` on two `int`s means integer addition in every file of every program.

The qualification matters. Where the language defines no built-in operation — `string + []u8`, say — there is nothing to shadow, and an ordinary user overload is found by normal lookup. The rule protects existing meanings; it does not reserve every combination of built-in types against ever having one.

A `distinct` type is not a built-in type for the purpose of this rule, even when its underlying type is. `Meters :: distinct f64` is a user type and its operators are ordinary overloads. (Note that `distinct` types *are* grouped with built-ins in stage 1 of [Resolving `T(...)`](#resolving-t), for the different reason given there.)

Domain-specific behavior over a primitive representation uses a `distinct` type:

```odin
Meters :: distinct f64;

impl Meters {
	add :: operator(+) proc(left, right: Meters) -> Meters { ... }
}
```

The named procedure remains available when shadowing between two user-defined operator sets would otherwise be unclear.

Candidates are ranked using the same algorithm as named procedure overloads. Candidate formation first rejects an arity mismatch, an incompatible parameter mode, an unsatisfied constraint, or a result incompatible with an already-known destination type. Each remaining candidate receives one conversion rank for every supplied argument:

0. Exact type and parameter-mode match.
1. Borrow, dereference, or mutable-to-read-only capability adjustment that does not create a value.
2. Built-in implicit conversion, including contextual conversion of a compatible
   untyped constant.
3. A user [`@(implicit)`](#implicit-conversion-from-constants) conversion. Reachable only for an argument that is an untyped constant, so it applies to at most one step and cannot chain.

Rank 3 sits below rank 2 so that a constant always prefers a compatible built-in destination: given `foo :: proc{foo_f64, foo_complex}`, the call `foo(2.0)` selects `foo_f64` at rank 2 rather than converting into `Complex_F64` at rank 3. An integer overload is not a candidate for `2.0`, because an untyped floating constant does not convert implicitly to an integer type.

The ranks form a vector; they are not added and argument order does not break ties. Candidate A is better than candidate B when A is no worse for every argument and strictly better for at least one. Crossed vectors such as `(0, 2)` and `(2, 0)` are intentionally ambiguous.

When conversion vectors are identical, the following tie-breakers apply in order:

1. A fixed-arity candidate beats a variadic candidate.
2. A candidate requiring fewer omitted default arguments wins.
3. A non-parametric candidate beats a parametric candidate.
4. Between parametric candidates, a structural specialization beats an unspecialized parameter: `Table(string, int)` beats `Table($K, $V)`. If neither is more structurally specialized than the other, the call is ambiguous.

**Constraints decide whether a candidate is viable, never which viable candidate wins.** `interface` applications and `where` clauses are filters; only structure orders what survives them. Two candidates of identical shape that differ only in constraint strength are therefore an ambiguity error, resolved by calling the intended member by its own name or by dispatching internally with `when`.

The compiler does not rank candidates by constraint strength. Non-overlapping `where` filters are not ambiguous because only one candidate is viable. Tie-breaker 4 continues to select a structural specialization.

Parametric instantiation is therefore not itself a worse argument conversion: an exact generic match beats a concrete overload that requires conversion unless the tie-breakers are reached with identical conversion vectors. Compiler-generated structural equality and comparison are fallbacks; a viable explicit overload for the aggregate suppresses the generated operation. This does not affect the rule above that primitive built-in operations cannot be shadowed.

Return type may filter candidates against an already-known destination type, but procedures cannot be overloaded by return type alone. If the partial ordering leaves more than one maximal candidate, the call is a compile-time ambiguity. The compiler diagnostic must list every maximal candidate, its conversion vector, and the tie-breaker at which selection failed.

The compiler and language server should provide a **show desugaring** action that displays the selected named procedure for a method, operator, conversion, index, or iteration expression. This makes powerful abstractions inspectable without weakening them.

## Indexing and slicing

`operator([])` defines indexed reads. An overload returning `inout T` produces an assignable location. `operator([]=)` handles computed or proxy assignment when no direct location can be returned.

```odin
Grid :: struct {
	width, height: int,
	cells: [dynamic]f32,
}

impl Grid {
	index :: operator([]) proc(self: Grid, x, y: int) -> f32 {
		return self.cells[y*self.width + x];
	}

	index_mut :: operator([]) proc(self: inout Grid, x, y: int) -> inout f32 {
		return inout self.cells[y*self.width + x];
	}
}

grid[3, 2] = 1.0;
value := grid[3, 2];
```

When both a value overload and an `inout` overload are visible, position selects between them before ordinary ranking is applied:

1. In a **place position** — the target of an assignment or compound assignment, the operand of `&`, or an argument passed as `inout` — the `inout` overload is required. If none exists, `operator([]=)` is used; if neither exists, the expression is not assignable and that is the diagnostic.
2. Everywhere else the value overload is preferred, even when the receiver is mutable.

Without this rule the two overloads differ only by receiver mutability and return mode, which rank 2 of [overload resolution](#operator-lookup-and-overload-resolution) would treat as an adjustment rather than a distinction, making every index on a mutable receiver ambiguous. The same rule applies to built-in indexing of maps and dynamic arrays.

Place position selects *which operation runs*. It does not by itself decide whether a missing element is **created**, which is a property of the container: a dynamic array never creates one and traps on an out-of-range index, while a built-in map inserts a zero element for an absent key. `&` is a place position for the purpose of overload selection but never creates an element in any container; a container that wants a non-inserting address supplies a method, as the built-in map does with [`m.find(key)`](#maps).

`operator([]=)` is for containers that have no location to hand out — computed, compressed, proxied, or validating storage. It takes the receiver, the index list, and the new value last, and returns nothing:

```odin
Sparse_Grid :: struct {
	entries: map[[2]int]f32,
}

impl Sparse_Grid {
	get :: operator([]) proc(self: Sparse_Grid, x, y: int) -> f32 {
		return self.entries[{x, y}] or_else 0;
	}

	// No `inout` overload exists: a zero is not stored, so there is no slot
	// whose address could be returned.
	set :: operator([]=) proc(self: inout Sparse_Grid, x, y: int, value: f32) {
		if (value == 0) {
			self.entries.remove({x, y});
		} else {
			self.entries[{x, y}] = value;
		}
	}
}

grid: Sparse_Grid = {};
grid[3, 2] = 1.0;   // calls `set`
grid[3, 2] = 0;     // calls `set`, which removes the entry
v := grid[9, 9];    // calls `get`, yielding 0
p := &grid[3, 2];   // ERROR: no `inout` overload; `[]=` cannot supply an address
```

A compound assignment on such a type reads through `operator([])` and writes back through `operator([]=)`, following the [fallback rule](#operator-declarations) for compound operators.

`operator([:])` defines slicing. It must return either an owning value or a borrow derived from the receiver, in which case the result is treated as a borrow of the receiver under [Borrows and lifetimes](#borrows-and-lifetimes) — the same treatment a built-in slice expression gets. A `[]mut T` result requires an `inout` receiver and carries its exclusive mutable capability; an immutable receiver can return only `[]T`.

Values are not made callable through operator overloading. A callable object exposes an ordinary method such as `call` or a domain-specific name such as `evaluate`, keeping procedure calls visually distinct from stateful objects.

Bounds checking remains the responsibility of the overload. Libraries may provide checked and unchecked types, and compiler tooling may warn about unchecked implementations without rejecting them.

## Iteration protocol

Iteration uses the standard [`Iterable`](#standard-interface-catalogue) and `Iterator` interfaces rather than a privileged user-container representation. A runtime value is iterable when its type provides associated `Element` and `Iterator` types, `iter(value)` returns that iterator, and the iterator has `next(self: inout Iterator) -> (Element, bool)`. `next` has [optional-ok semantics](#optional-ok-results): a false `bool` ends the loop with the first result unobserved.

Built-in runtime iterables participate in exactly the same static interface. The compiler contributes associated members, an `iter` overload, and an opaque iterator type for ranges, strings, string views, fixed arrays, slices, dynamic arrays, and maps. These compiler-provided declarations are visible to interface checking and generic code but do not expose the iterator representation. Enum *types* remain the compile-time-only exception described under [Iterating an Enumeration](#iterating-an-enumeration).

```odin
Countdown :: struct {
	start: int,
}

Countdown_Iterator :: struct {
	current: int,
}

impl Countdown {
	Element  :: int;
	Iterator :: Countdown_Iterator;

	iter :: proc(self) -> Countdown_Iterator {
		return {self.start};
	}
}

impl Countdown_Iterator {
	next :: proc(self: inout Countdown_Iterator) -> (int, bool) {
		if (self.current <= 0) {
			return 0, false;
		}
		value := self.current;
		self.current -= 1;
		return value, true;
	}
}

foreach (value in Countdown{3}) {
	fmt.println(value);
}
```

The associated output makes a generic loop's element type available without an existential or another inferred generic parameter:

```odin
first :: proc(source: $S) -> (S.Element, bool)
	where interfaces.Iterable(S) {
	iterator := iter(source);
	return iterator.next();
}
```

An iterable type has one default `Element` and `Iterator` pair. A type that needs another traversal exposes an adapter value with its own associated pair; byte iteration over text, filtered iteration, and enumerated iteration are examples. This keeps type inference local and avoids a general associated-type inference solver.

`iter_reverse` supports reverse iteration. An iterator obtained from a collection is a borrow of that collection, so mutating the collection while iterating it is rejected by the rules in [Borrows and lifetimes](#borrows-and-lifetimes).

### Two-name loops over user types

`next` yields one value per step. In `foreach (value, index in x)` over a user type, `index` is not supplied by the iterator: it is a zero-based `int` counter maintained by the loop itself, incremented once per successful `next`. This matches what the second name already means for built-in arrays and slices, and it keeps the protocol to a single method.

Two built-in types are exceptions, and both are exceptions because their second name carries information the loop counter could not reconstruct:

- **Maps.** `foreach (key, value in m)` yields two values from the map's own iteration; `value` is an element rather than a counter.
- **Strings.** `foreach (codepoint, offset in s)` yields a [byte offset](#string-iteration) rather than a rune ordinal, because the offset is what indexes back into the string.

A user type that wants a key/value loop returns a record from `next` and is iterated with one name:

```odin
foreach (entry in table) {
	fmt.println(entry.key, entry.value);
}
```

### By-reference iteration

By-reference `foreach` is a built-in-container facility in version 1. Mutable fixed arrays, mutable slices, dynamic arrays, and map values support `foreach (&value in collection)` directly. The standard `Iterable` protocol has only value-producing `next`; there is no `next_ref` protocol method or general storable `inout` local.

A user collection that needs mutable traversal exposes a mutable slice, an indexed `inout` operation, or an ordinary method that performs the traversal. This keeps borrowed result modes limited to immediate place operations such as indexing and avoids adding lifetime rules solely for one iterator protocol.

## Construction and conversions

Struct literals remain the simplest construction mechanism. An `init` overload provides validated, computed, or overloaded construction through type-call syntax:

```odin
impl Vector2 {
	init_components :: proc(x, y: f32) -> Vector2 {
		return {x, y};
	}

	init_splat :: proc(value: f32) -> Vector2 {
		return {value, value};
	}

	init :: proc{init_components, init_splat};
}

a := Vector2(1, 2);
b := Vector2(5);
```

Explicit user-defined conversion uses the same `init` mechanism as construction. A one-argument `init` overload on the target type participates in `Target(value)`:

```odin
Meters :: distinct f64;
Kilometers :: distinct f64;

impl Kilometers {
	from_meters :: proc(value: Meters) -> Kilometers {
		return Kilometers(f64(value) / 1000.0);
	}

	init :: proc{from_meters};
}

distance_m := Meters(1500);
distance_k := Kilometers(distance_m); // explicit user conversion
```

### Implicit conversion from constants

Adding `@(implicit)` to a one-argument `init` overload lets it also be applied without being written — but **only when the argument is an untyped constant.** A runtime value of the same type always requires the explicit form.

The parameter type must be a built-in numeric, boolean, rune, or string type, so that there is an untyped constant kind that can reach it. The constant must convert implicitly to that parameter type under the ordinary [untyped-constant rule](#untyped-types), and the procedure is then called normally. Consequently, an untyped floating constant can reach an `@(implicit)` conversion whose parameter is floating-point, but not one whose parameter is an integer type.

```odin
impl Complex_F64 {
	init_components :: proc(real, imaginary: f64) -> Complex_F64 {
		return {real, imaginary};
	}

	@(implicit)
	from_scalar :: proc(value: f64) -> Complex_F64 {
		return {value, 0};
	}

	init :: proc{init_components, from_scalar};
}

z := Complex_F64(1, 2);
w := z*z + 2.0;              // OK: `2.0` is an untyped float constant

scale: f64 = read_scale();
bad := z + scale;            // ERROR: no operator `+` for (Complex_F64, f64)
good := z + Complex_F64(scale);
```

This is the whole job the feature exists for. [Library numeric types](#library-numeric-types) need literals to enter them — `z*z + 2.0` should mean what it looks like — and that is a property of *literals*, not of `f64`. Restricting the rule to constants keeps the useful case and gives up a general implicit-conversion facility, which is the right trade three times over:

- **Runtime conversions are explicit.** Source code shows each conversion of a runtime value. Conversion behavior does not depend on declarations in scope.
- **Chains cannot form.** An untyped constant is not a user type, so a constant can take at most one user conversion and there is no need for a rule capping conversion depth or an argument that lookup terminates.
- **Narrowing is already handled.** Precision loss is caught by the constant-representability rule at compile time, so the language does not need to permit lossy implicit conversions and then advise implementations to warn about them.

### Resolving `T(...)`

The form `T(...)` has two possible meanings — a built-in conversion or an `init` overload — so the language fixes one resolution order:

1. **Built-in conversion.** If `T` is a built-in or `distinct` type and exactly one argument is given whose type has a built-in conversion to `T`, that conversion is used. This case is decided first and cannot be overridden, for the same reason built-in operators cannot be shadowed: `int(x)` must not change meaning based on imports.
2. **`init` overloads.** Otherwise, visible `init` overloads for `T` are considered using ordinary overload resolution, including the zero-argument and multi-argument forms.

Resolution stops at the first stage that produces a match. Within a stage, equal-ranked matches are ambiguous rather than being selected by declaration order, and the diagnostic must list the candidates from that stage only.

A single-argument `init` on a `distinct` type over a built-in cannot be reached through `T(x)` when `x` is of the underlying type, because stage 1 claims it; call it by name, or give it a distinguishing parameter. `@(implicit)` only grants an additional constant-only path to an `init` overload; it does not affect explicit `T(x)` resolution.

## Lifecycle hooks and resource types

User-defined records receive field-wise `try_clone`, `clone`, `move`, and `drop` behavior by default. An `impl` block may replace the canonical `try_clone` hook or the `drop` hook for a type that owns a resource.

The lifecycle signatures are fixed. `drop` is `proc(self: inout T)`. The canonical copy hook is `try_clone :: proc(self, allocator: Allocator = mem.default_allocator()) -> (T, Allocator_Error)`. A custom implementation must allocate all cloned backing storage through explicitly fallible operations using the supplied allocator and must return their error without publishing a partial result. Compiler-generated field-wise cloning calls `try_clone` recursively for every owning field, destroys a partially completed temporary on failure, and returns zero plus the error.

`clone :: proc(self, allocator: Allocator = mem.default_allocator()) -> T` is generated from `try_clone`; user code does not replace it independently. It calls `try_clone` once and, on failure, invokes the supplied allocator's failure policy. An explicit `value.clone()` therefore uses the program default, while `value.clone(allocator)` selects one. Assignment and copy initialization call `try_clone` directly with the destination's currently bound allocator, or resolve the destination's declaration allocation policy when it is dead or allocator-unbound. They invoke that allocator's failure policy only after cloning has failed and before modifying the destination. A non-allocating `try_clone` accepts and ignores the allocator and returns a nil error.

A custom `try_clone` is permitted to panic for ordinary program faults, but it must not invoke an allocator failure policy for an allocation it performs: recoverable allocation inside the hook uses `try_` operations. This is a semantic contract checked for compiler-known allocating operations and otherwise enforced like the `hash`/equality coherence contract on map keys.

```odin
File :: struct {
	handle: os.Handle,
	valid:  bool,
}

impl File {
	try_clone :: ---; // neither fallible nor policy-following clone exists

	drop :: proc(self: inout File) {
		if (self.valid) {
			os.close(self.handle);
			self.valid = false;
		}
	}
}
```

`try_clone :: ---;` disables both generated copy entry points, making `File` move-only. No signature is written, because the signature of a lifecycle hook is fixed by the type. `move(value)` remains a compiler primitive: it transfers the representation, writes the inert zero representation to a lexical source, and marks that source dead. `drop(value)` invokes the user hook when present, writes the inert representation, and likewise marks a lexical variable dead. Direct move and drop are forbidden for static-duration storage; `exchange` installs a live replacement while returning the previous value. Fields are dropped in reverse declaration order after the containing type's drop hook returns.

A `drop` hook is called **exactly once per completed initialization** that is not transferred or already consumed. Whether a variable still owns its value is tracked by the compiler, with runtime state only where control flow requires it, as described under [Managed values and storage](#managed-values-and-storage) — it is never inferred by comparing the value against its zero state. The hook must nevertheless accept the type's inert zero value, because explicit `{}` initialization and zero-initialized static-duration storage are completed initializations. In the `File` example, `valid` distinguishes a live zero value from an acquired POSIX file descriptor whose numeric handle may legitimately be zero. Liveness tracking separately prevents a value that has already been moved or dropped from being cleaned up again.

Copy assignment of a copyable user type behaves conceptually as follows, with self-assignment handled by the compiler:

```odin
temporary, error := source.try_clone(destination_allocator);
if (error != nil) { apply_failure_policy(destination_allocator, error); }
drop(destination);
destination = move(temporary);
```

The pseudocode's `apply_failure_policy` is not a source-level procedure; it denotes the allocator behavior specified under [Allocation failure](#allocation-failure). The destination is unchanged if `try_clone` fails. Calling `try_clone` explicitly returns the error and never applies that policy itself.

## Interfaces and generic operators

An `interface` names a set of compile-time structural requirements. A type satisfies an interface implicitly when every requirement in its body holds; no separate `implements` declaration is required. An interface declaration is compile-time metadata, not itself a runtime value type. Runtime polymorphism is requested explicitly with [`dyn Interface`](#borrowed-dynamic-interface-values).

```odin
Additive :: interface($T: type) {
	T(0) -> T;
	(a, b: T) a + b -> T;
}

sum :: proc(values: []$T) -> T
	where Additive(T) {
	result := T(0);
	foreach (value in values) {
		result += value;
	}
	return result;
}
```

### Interface bodies

An interface body is a semicolon-terminated list of requirements, written in the [`Requirement` grammar](grammar.md#interfaces). A requirement may be preceded by a **binding list**, which introduces names standing for values or explicit `inout` places of the given types. There are three forms:

- **expression form** — `expr -> Type;`
- **validity form** — `expr;`
- **named dispatch form** — `slot name: proc(...);`

A requirement that begins with `(` is always a binding list. A requirement whose own expression must start with a parenthesis needs a second pair.

Inside a requirement, a type name always means the type. Values come only from the binding list. This is the whole disambiguation rule: `T` never silently switches between meaning the type and meaning a value of it, so `T(0)` is unambiguously construction while `(a, b: T) a + b` is unambiguously addition of two values.

**Expression form** — `expr -> Type;` requires that `expr` compiles for the interface's parameters and bindings, and that its result is convertible to `Type`.

A binding written `name: inout T` represents a hypothetical exclusive mutable place. It may be read normally and may select an `inout` receiver, parameter, or indexing overload. A requirement result written `-> inout T` requires the expression to denote an assignable place of exactly type `T`; ordinary result conversions do not apply. These forms exist only while checking a requirement and do not add a first-class reference type:

```odin
Mutable_Indexable :: interface($T: type, $Element: type) {
	(value: inout T, index: int) value[index] -> inout Element;
}
```

Only `inout` is admitted in a requirement binding list. A consuming operation can be required as an ordinary named slot with a `move self` receiver, but there is no reusable hypothetical `move` binding: satisfying a capability check must not consume the evidence used to check the remaining requirements.

**Validity form** — `expr;` requires only that the expression compiles, with no constraint on its result type.

An associated constant is an ordinary expression requirement: `T.ZERO -> Element;` asks for a member named `ZERO` on `T` whose value converts to `Element`, and an `impl` constant satisfies it. When the required result is `type`, the selected member must itself evaluate to a compile-time type. That member is an **associated type** and may be used as a type in later requirements and in generic code constrained by the interface:

```odin
Source :: interface($T: type) {
	T.Element -> type;
	(value: T) value.read() -> T.Element;
}

Byte_Source :: struct {
	current_byte: u8,
}

impl Byte_Source {
	Element :: u8;

	read :: proc(self) -> u8 {
		return self.current_byte;
	}
}
```

Associated types need no separate declaration grammar because types are already compile-time values and an `impl` already admits constants. For a generic `T`, a selector such as `T.Element` is valid only when the active constraints require that member and make it unambiguous. Requirement order is irrelevant: associated members required directly or through a composed interface are available throughout the interface body and a constrained generic declaration. Two requirements for the same selector refer to the same member and must agree on its type.

**Named slot form** — `slot name: proc(...);` declares a method requirement. Its
first parameter must be the receiver name `self` in one of the three
[receiver modes](#receiver-forms): immutable `self` (written with or without its
type), `self: inout Subject`, or `self: move Subject`. A pointer parameter only
named `self` is not a receiver and cannot satisfy a slot. In an interface eligible for runtime use, only
immutable `self` (inferred or explicit) and `self: inout Subject` are allowed:
the former is an immutable borrow of the subject and the latter is an exclusive
mutable borrow. After substituting the interface arguments, requirement checking
must select one matching inherent method or an extension method from the
interface's own package. Parameter modes, results, calling convention, and
type-level effects match exactly; default arguments do not participate. A slot
is both a static callable requirement and a potential entry in a runtime
[witness](#runtime-polymorphism). Within generic code constrained by the
interface, the slot is available through ordinary method syntax on the subject;
this is a declaration supplied by the interface, not general uniform-call
rewriting.
Slot names must be unique across the interface and every interface it composes;
runtime witness members are never overload groups.

Method and operator requirements are written as ordinary calls on bound values. Lifecycle requirements name the hook; the standard [`Cloneable`](#standard-interface-catalogue) interface below, for example, requires the fixed `try_clone` slot rather than only checking that some unrelated free procedure has a similar name.

Interfaces compose by naming one another, and an interface application used in `where` is a compile-time boolean. The `Ordered` interface in the standard catalogue below, for example, composes `Equatable` before adding its `<` requirement.

An ordinary bound name is a value of that type for checking purposes and an `inout` bound name is a hypothetical mutable place. The compiler never constructs either one, so an interface may name a type that has no reachable constructor.

Requirement checking is non-recursive at the point of use: the compiler checks that each listed requirement holds for the concrete arguments, and does not attempt to prove requirements about types that do not yet exist. An interface application such as `Ordered(T)` is a compile-time predicate. The interface declaration by itself does not denote a runtime type and cannot be used as a variable, field, parameter, or result type; `dyn Ordered` is a separate, explicitly erased type and is valid only when the interface is dyn-compatible.

A failed requirement must be reported as the specific line of the interface body that did not hold, together with the concrete type that failed it. An interface diagnostic that reports only "constraint not satisfied" is a defect in the implementation.

### Standard interface catalogue

Version 1 has a small catalogue. These are ordinary declarations exported by `base:interfaces`, not compiler predicates; outside that package they are written with the imported package qualifier, such as `interfaces.Sequence(S)`. The compiler makes built-in operations and associated members visible to the same structural checks used for user types.

```odin
Equatable :: interface($T: type) {
	(a, b: T) a == b -> bool;
}

Ordered :: interface($T: type) {
	Equatable(T);
	(a, b: T) a < b -> bool;
}

Hashable :: interface($T: type) {
	Equatable(T);
	(value: T, seed: uint) hash(value, seed) -> uint;
}

Numeric :: interface($T: type) {
	T(0) -> T;
	T(1) -> T;
	(a, b: T) a + b -> T;
	(a, b: T) a - b -> T;
	(a, b: T) a * b -> T;
	(a, b: T) a / b -> T;
}

Integral :: interface($T: type) {
	Numeric(T);
	(a, b: T) a % b -> T;
	(a, b: T) a | b -> T;
	(a, b: T) a ~ b -> T;
	(a, b: T) a & b -> T;
	(a, b: T) a &~ b -> T;
	(a: T, shift: uint) a << shift -> T;
	(a: T, shift: uint) a >> shift -> T;
}

Cloneable :: interface($T: type) {
	slot try_clone: proc(self, allocator: Allocator) -> (T, Allocator_Error);
}

Iterator :: interface($Self, $Element: type) {
	slot next: proc(self: inout Self) -> (Element, bool);
}

Iterable :: interface($Self: type) {
	Self.Element -> type;
	Self.Iterator -> type;
	(value: Self) iter(value) -> Self.Iterator;
	Iterator(Self.Iterator, Self.Element);
}

Sequence :: interface($Self: type) {
	Iterable(Self);
	(value: Self) len(value) -> int;
	(value: Self, index: int) value[index] -> Self.Element;
}

Mutable_Sequence :: interface($Self: type) {
	Sequence(Self);
	(value: inout Self, index: int) value[index] -> inout Self.Element;
}

Growable_Sequence :: interface($Self: type) {
	Mutable_Sequence(Self);
	(value: inout Self, element: Self.Element) value.append(element);
}
```

`Ordered` means that the ordinary `<` operation is available; it does not silently promise a mathematical total order. In particular, floating-point types satisfy it with their IEEE-754 comparisons. An algorithm that requires a total or strict-weak order states that semantic precondition in its documentation or takes an explicit comparator. `Numeric` intentionally does not compose `Ordered`, so arithmetic SIMD values and library numeric types such as complex numbers can satisfy it without inventing an ordering.

`Cloneable` names the canonical fallible lifecycle hook rather than the policy-following `clone` wrapper. It is satisfied by copyable owning built-ins and by user records with generated or custom `try_clone`; `try_clone :: ---` makes it fail as intended. `Iterable` describes by-value traversal. The built-in `foreach (&element in value)` forms remain place operations, while generic indexed mutation uses `Mutable_Sequence`; version 1 does not add a second mutable-iterator hierarchy before a non-indexed use case needs it.

Formatting remains the `format(value, writer, options)` procedure protocol in `core:fmt` rather than adding writer and options parameters to this base catalogue. Maps remain best constrained by their concrete `map[K]V` shape until a common map algorithm requires a separate capability; they are iterable over keys but are not sequences. UTF-8 text likewise remains its concrete `string` or `string_view` type because byte length, rune iteration, and the absence of integer indexing do not form one honest `Sequence` interface.

Built-in satisfaction follows the operations already defined by the language:

- `bool`, integers, floats, runes, `string`, `string_view`, pointers including `rawptr` and multi-pointers, enums, `typeid`, `Simd`, and recursively comparable fixed arrays satisfy `Equatable`; records and unions do so when their generated or inherent equality is available;
- integers, floats, runes, `string`, `string_view`, pointers on targets that support pointer ordering, and enums satisfy `Ordered`;
- `bool`, integers, floats, runes, `string`, `string_view`, pointers, enums, `typeid`, `Simd`, and fixed arrays of hashable elements satisfy `Hashable`. For floats, `+0` and `-0` hash identically because they compare equal. User records and unions still require the inherent coherent equality/hash pair specified under [Maps](#maps);
- built-in integer, floating-point, and rune types satisfy `Numeric`; integer and rune types satisfy `Integral`. A `Simd(T, N)` satisfies either interface when all of the listed operations exist for that lane domain;
- copyable owning built-ins such as `string`, dynamic arrays, maps, and `shared(T)`, plus recursively copyable owning aggregates, satisfy `Cloneable`;
- runtime ranges, strings, string views, fixed arrays, slices, dynamic arrays, and maps satisfy `Iterable`. Their associated `Element` is respectively the endpoint type, `rune`, `rune`, the stored element, the stored element, the stored element, and the map key;
- fixed arrays, slices, and dynamic arrays satisfy `Sequence`; fixed arrays, mutable slices, and dynamic arrays satisfy `Mutable_Sequence` when supplied as mutable places; dynamic arrays satisfy `Growable_Sequence`. The standard `Small_Array(T, N)` library type supplies the same associated members and satisfies all three sequence interfaces.

No nominal `implements` list is involved. The catalogue records useful capability boundaries, not a requirement that every built-in type belong to an interface.

### Choosing between interfaces, `where`, and specialization

Three mechanisms can constrain a generic parameter, and they overlap. The intended division of labour:

- **`interface`** — requirements about what a type *can do*: operators, methods, lifecycle hooks, and named members.
- **[`where` clauses](#where-clauses)** — predicates over *values*, such as `N > 2` or `len(x) > 1`. A `where` clause of the form `where intrinsics.type_is_numeric(E)` is better written as an interface, and the standard library should not add new type-predicate intrinsics for constraints an interface can express.
- **[Specialization](#specialization)** — structural shape, written directly in the parameter type as in `values: []$E` or `table: ^Table($Key, $Value)`, where the point is to *destructure* the type and bind its parts rather than to test it.

All three remain in the language: they answer different questions, and collapsing them would cost more in expressiveness than the overlap costs in learning. But a constraint that could be written any of the three ways should be written as an interface, because only an interface produces the per-requirement diagnostic described above.

## Runtime polymorphism

Runtime polymorphism reuses the same structural interfaces as generics. It is
requested explicitly, with [`dyn Interface`](#borrowed-dynamic-interface-values),
and it is the only construct that erases a concrete type behind an interface.

For runtime use, the first generic parameter of an interface is its **subject**.
It must have type `type`; erasure substitutes the concrete implementation type
for that parameter. Any remaining generic parameters remain explicit arguments
of the dynamic interface type. The catalogue's `interfaces.Iterator(Self,
Element)` is one such interface; another package may declare its own:

```odin
Drawable :: interface($Self: type) {
	slot draw: proc(self, canvas: inout Canvas);
}
```

Each `(Interface, Concrete, arguments...)` tuple has exactly one **witness**: the
immutable evidence that the concrete type satisfies the interface's named slots.
Its slot implementations must be inherent to the concrete type or declared in the
interface's own package; caller-local extensions do not participate. Two packages
therefore cannot erase the same type behind the same interface and get different
behavior, and no import can change what an existing `dyn` value does. Static,
non-erased interface checks retain their normal definition-site lookup rules.

**A witness is a mechanism, not a value.** How it is represented — a table of
erased procedure pointers, adapter thunks where a receiver must be re-typed, the
order slots appear in — is the compiler's business and is not observable. There
is no built-in that materializes a witness and no compiler-defined type naming
one; `dyn` is the only way to reach one, and the only thing a program can do with
one is call through it. A future owning erased value will need a first-class
witness primitive and can introduce it together with the allocator, alignment,
clone, drop, and thread-affinity rules that make it meaningful. Fixing a witness
layout now, for a consumer that does not exist, would make the representation
part of the language contract before anything needs it to be.

### Dyn compatibility

An interface is **dyn-compatible** when it can be erased behind a finite set of
slots and invoked without knowing the subject's size. It must meet all of these
rules:

- its first generic parameter is `$Self: type` (the name may differ);
- every runtime operation is a named `slot`; free-form expression and validity
  requirements other than interface composition make the interface static-only;
- every composed interface is dyn-compatible and uses the same subject;
- a slot is non-generic and non-variadic, uses the ordinary Loke calling
  convention, and has no omitted-argument defaults;
- the subject occurs exactly once in the slot signature, as the first immutable
  `self` (inferred or written `self: Self`) or `self: inout Self` receiver, and
  nowhere in any other parameter or result type.

These restrictions exclude constructors, values returned as `Self`, consuming
methods, generic methods, and binary operations that require another value of
the same hidden concrete type. They remain valid static interface requirements;
the restriction applies only when forming a `dyn` type.

### Borrowed dynamic interface values

`dyn Interface(arguments...)` is a fixed-size, non-owning view: a data pointer
and a pointer to the coherent implementation of that interface application for
the erased type. The subject argument is omitted because it is the type erased at
runtime. For example, `dyn interfaces.Iterator(u8)` may hold a borrow of any
concrete value for which `interfaces.Iterator(Concrete, u8)` is satisfied.

The interface's receiver modes determine the view's borrow capability. A dyn
type whose slots all use immutable `self` is an immutable borrow. If any slot
uses `inout self`, the dyn type is an exclusive mutable borrow: the source owner
cannot be accessed through another name while that view is live, and copying the
view cannot create two overlapping live mutable paths. This is the same
use-based exclusivity rule applied to other compiler-recognized borrows; it does
not require a second `dyn mut` spelling.

Conversion is an ordinary explicit type conversion from a pointer to the
concrete subject:

```odin
circle := Circle{...};
drawable := (dyn Drawable)(&circle);
drawable.draw(inout canvas); // indirect call through the witness
```

The conversion performs no allocation and does not copy the concrete value. It
creates a compiler-recognized borrow whose root provenance derives from the pointed-to source and
materializes or reuses its witness. A pointer made from a temporary may be used
to create a `dyn` value only for that complete expression. Directly held local
`dyn` values participate in the ordinary use-based borrow analysis; storing one
in memory has the same explicit unchecked-lifetime boundary as storing a slice.
A `dyn` parameter or result follows the same coarse cross-procedure root-provenance
rule as a slice: a returned view derives from every borrowed argument from
which its data pointer could have been derived.

Converting a nil concrete pointer produces the nil dynamic view and does not
retain a witness for the absent value.

The zero value of every `dyn Interface` type is nil. Copying or assigning one
copies only the view when the borrow-capability rules permit the new alias.
Calling a slot on nil panics. Dynamic interface values are
comparable only with `nil`; two data pointers or witnesses are not implicitly an
application-level equality operation.

Dynamic interfaces do not support type assertions or type switches in version 1. A dynamic interface is a borrowed view and does not own a value. Loke has no read-only pointer type that can represent a safe downcast from an immutable view. Add a slot for required behavior. For runtime type inspection, pass an `any_view` with the interface or define a record of callbacks.

`dyn I` itself satisfies `I` by compiler-provided forwarding slots. This is the
bridge between static and runtime polymorphism:

```odin
paint :: proc(value: ^$T, canvas: inout Canvas)
	where Drawable(T) {
	value^.draw(inout canvas);
}

paint(&circle, inout canvas);   // T is Circle; specialized direct call
paint(&drawable, inout canvas); // T is dyn Drawable; witness dispatch
```

Passing a concrete value to generic code never introduces dynamic dispatch. The
caller must first construct a `dyn` value, or the parameter must explicitly ask
for one. A `dyn` value also converts without allocation to a composed base
interface by preserving the data pointer and selecting the base interface's own
witness for the hidden concrete type. No prefix-layout relationship between the
two witnesses is required.

There is no owning erased value in the base language. A future owner must state
its allocator, alignment, move, clone, drop, and thread-affinity behavior; those
costs cannot be hidden inside conversion to a borrowed interface. Closed
heterogeneous ownership continues to use unions, while libraries that need open
ownership combine an explicit allocation owner with their own record of
callbacks.
`shared(dyn I)` would share only the two-word view and would not extend the
concrete payload's lifetime; it is not an owning-erasure facility.

## Standard customization procedures

Not every customization needs punctuation. The standard library recognizes ordinary overloadable procedures for common behavior:

| Procedure | Purpose |
| --- | --- |
| `len(value)` | Number of logical elements or bytes, as defined by the type |
| `cap(value)` | Current capacity when meaningful |
| `hash(value, seed: uint) -> uint` | Hashing for maps and sets |
| `format(value, writer, options)` | Formatting and printing |
| `compare(left, right)` | Three-way ordering when useful |
| `iter(value: T) -> T.Iterator` | Forward iteration using the type's associated iterator |
| `iter_reverse(value)` | Reverse iteration when the type supplies it |
| `clone(value, allocator := mem.default_allocator())` | Explicit independent copy |
| `try_clone(value, allocator := mem.default_allocator())` | Fallible independent copy |

These procedures use normal overload groups. Each is written as a free call — `len(x)`, `hash(key, seed)`, `clone(value)` — and that spelling is canonical and always available. For lifecycle-enabled types, the compiler contributes the free `clone` and `try_clone` overloads that forward to the fixed hooks described above; a user customizes copying by replacing `T.try_clone`, not by adding an unrelated free clone with different semantics.

**Method syntax applies only to methods.** `x.f()` resolves to one of these declarations:

- a procedure with a `self` receiver in an `impl` block for the type of `x`
- a procedure with a `self` receiver in a visible `extend` block
- a built-in container operation such as `append`, `remove`, `reserve`, or `sort`

Loke does not rewrite `f(x)` as `x.f()`. A free procedure does not automatically get method syntax.

A type may of course declare one of the procedures above as a method, and many should:

```odin
impl Ring_Buffer {
	len :: proc(self) -> int { return self.count; }
}

buffer: Ring_Buffer = {};
n := len(buffer);        // always valid: the overload group
m := buffer.len();       // also valid: `Ring_Buffer` declared it with `self`
```

With the built-in containers, `len(x)` and `cap(x)` are free calls — the queries generic code calls on a type parameter, with the interface requirement `(c: T) len(c) -> int` — while mutators such as `x.append(v)` are receiver methods. Libraries may define additional protocols without compiler support.

## Library numeric types

Complex numbers and quaternions are standard-library abstractions rather than
base-language types. They use ordinary structs, methods, operators,
conversions, interfaces, and formatting hooks.

For example, a library can define a complex type entirely in ordinary code:

```odin
Complex_F64 :: struct {
	real, imaginary: f64,
}

impl Complex_F64 {
	init_components :: proc(real: f64, imaginary: f64 = 0) -> Complex_F64 {
		return {real, imaginary};
	}

	add :: operator(+) proc(left, right: Complex_F64) -> Complex_F64 {
		return {left.real + right.real, left.imaginary + right.imaginary};
	}

	multiply :: operator(*) proc(left, right: Complex_F64) -> Complex_F64 {
		return {
			left.real*right.real - left.imaginary*right.imaginary,
			left.real*right.imaginary + left.imaginary*right.real,
		};
	}

	@(implicit)
	from_scalar :: proc(value: f64) -> Complex_F64 {
		return {value, 0};
	}

	init :: proc{init_components, from_scalar};
}

z := Complex_F64(1, 2);
w := z*z + 2.0;               // `2.0` is a constant, so `from_scalar` applies
```

The standard library may offer generic `Complex(T)` and `Quaternion(T)` families and interfaces for their supported scalar types, but these declarations have no special relationship with the compiler. Promotion of a scalar *constant* is provided by an `@(implicit)` one-argument `init` overload; promotion of a scalar *variable* is written explicitly, as `Complex_F64(x)`. Equality, arithmetic, conjugation, norms, parsing, and formatting are ordinary overloads or procedures. Matrix support for these scalar domains is likewise a library abstraction rather than a built-in matrix rule.

The same facilities must be sufficient for third-party fixed-point, decimal, rational, dual, interval, unit-aware, and domain-specific numeric types, and for the geometric vector, matrix, and swizzle types built on top of [`Simd(T, N)`](#simd-vectors). Standard-library implementations should be readable examples, not compiler intrinsics disguised as library code.

# Advanced types

## Type alias

A type alias gives another name to a type:

```odin
My_Int :: int;
#assert(My_Int == int);
```

## Distinct types

A distinct type is a new type with the same representation as its underlying type.

```odin
My_Int :: distinct int;
#assert(My_Int != int);
```

A distinct type may define its own methods, operators, constructors, conversions, interfaces, formatting, and lifecycle hooks. It does not inherit the underlying type's operations: `Meters :: distinct f64` supports no arithmetic until it is given some. Operations are brought over either one at a time, with an ordinary forwarding declaration that unwraps to the underlying type, or in bulk with the [`delegate`](#delegating-operators) form below.

Each named aggregate type (`struct`, `enum`, or `union`) is distinct.

```odin
Foo :: struct {};
#assert(Foo != struct{});
```

### Delegating operators

A single forwarding overload is one line — unwrap to the underlying type, apply its operator, wrap the result back:

```odin
Meters :: distinct f64;

impl Meters {
    add :: operator(+) proc(a, b: Meters) -> Meters { return Meters(f64(a) + f64(b)); }
}
```

but a numeric newtype needs that same line for `-`, `==`, `<`, and every other operator it wants — the boilerplate `distinct` is otherwise accused of. `delegate` generates those forwarding overloads from a list of operator symbols. It parses its operands as operator symbols exactly as [`operator(...)`](#operator-declarations) does, and appears in an `impl` or `extend` block for a distinct type:

```odin
Meters :: distinct f64;

impl Meters {
    delegate(+, -, ==, !=, <, <=, >, >=);
}

a := Meters(3);
b := Meters(4);
c := a + b;      // Meters(7): generated (a, b: Meters) -> Meters
a += b;          // += follows from + by the compound-assignment fallback
ok := a < b;     // bool: a comparison result is not wrapped
```

For each listed symbol, `delegate` generates the overloads of that operator found for the underlying type at the delegation declaration's lexical package, with the distinct type substituted for the underlying type in every operand and result position. The selected underlying operations are fixed when the declaration is checked; extensions in a caller's package cannot later change what delegation means. Each generated overload unwraps its distinct operands to the underlying type, applies the underlying operator, and wraps a result *of the underlying type* back into the distinct type. A result of any other type — the `bool` from a comparison, or the `f32` from a dot product — is carried through unchanged. Compound-assignment forms follow from their binary operators through the existing [fallback rule](#operator-declarations), so delegating `+` also gives `+=`.

Delegation is selective by design, and the list is where the distinction earns its keep. `Meters` delegates `+` and `-` but not `*` or `/`: two lengths add to a length but do not multiply to one, so `Meters * Meters` is an area — a different type — and forwarding it would silently produce a wrong-dimensioned `Meters`. A mixed-operand operator such as `Meters * f64 -> Meters` is not a homogeneous delegation either and is written by hand. Listing a symbol the underlying type does not define is an error, and delegating an operator already declared explicitly in the same block is a redeclaration, diagnosed like any other.

`delegate` has no meaning for a type that is not `distinct`, because there is no underlying representation to forward to. Non-operator behavior — a method, or a `hash`, `compare`, or `format` overload — is re-exported the same way a single operator is: an ordinary one-line procedure that unwraps, calls, and where relevant wraps. Those are rarer and need no bulk form.

## Fixed arrays

A fixed array contains a compile-time number of elements of one type. An array index can have an integer, character, or enumeration type.

This declaration constructs a fixed array:

```odin
x := [5]int{1, 2, 3, 4, 5};
foreach (i in 0..=4) {
	fmt.println(x[i]);
}
```

A fixed array stores its elements contiguously. Its layout is equivalent to a record with one field for each element.

`x[i]` accesses element `i` of `x`. The first element has index 0.

### Multidimensional arrays

A multidimensional fixed array is an ordinary nested array. `[Rows][Columns]T` means an outer array of `Rows` values, each of which is an inner `[Columns]T` array:

```odin
grid := [2][3]int{
	{1, 2, 3},
	{4, 5, 6},
};

row := grid[1];       // [3]int{4, 5, 6}
x := grid[1][2];      // 6
```

Nested fixed arrays are one contiguous value; they are not arrays of pointers. Their layout is row-major in declaration order, with the rightmost index varying fastest. For `a: [D0][D1]...[Dn]T`, the scalar elements of `a[0]` precede those of `a[1]`. In two dimensions, `a[row][column]` has the flat element offset `row*Columns + column`.

**Built-in indexing takes exactly one index.** A nested container is indexed by chaining: `a[i][j][k]`. Each step is evaluated left to right and performs its own bounds check, and it is a compile-time error if an intermediate value is not indexable.

The comma form `a[i, j]` is reserved for a user-defined [`operator([])`](#indexing-and-slicing) taking that many indices, and it is a compile-time error on a built-in container. The two spellings therefore never mean the same thing: `value[i][j]` is two independent indexing operations, and `value[i, j]` is one operation that receives both indices at once and may map them onto rectangular, column-major, strided, or sparse storage however it likes. Giving built-ins a comma spelling that silently meant "chain" would make the same syntax mean two different things depending on who declared the type.

`[][]T` is a slice of slices and `[dynamic][dynamic]T` is a dynamic array of independently managed dynamic arrays; their inner containers may have different lengths and, for dynamic arrays, separate allocations. They are potentially jagged, and only nested *fixed* arrays have the single contiguous layout described above.

The base language assigns no mathematical meaning to arrays. Fixed arrays support storage, indexing, iteration, slicing, and structural equality, but not arithmetic or scalar broadcasting. Vector arithmetic, swizzling, matrix operations, and other numerical interpretations belong in libraries implemented with generic structs or distinct types, interfaces, and operators. A rectangular dynamically sized container should likewise be a library type containing one flat `[dynamic]T`, its dimensions, and an `operator([])` for multi-index access — which is precisely what the comma form exists to spell.

A fixed-array length can be inferred from its literal with a question mark (`?`):

```odin
x := [?]int{1, 2, 3, 4, 5};
```

Designated initializers set elements by index or index range:

```odin
favorite_animals := [?]string{
	// Assign by index
	0 = "Raven",
	1 = "Zebra",
	2 = "Spider",
	// Assign by range of indices
	3..=5 = "Frog",
	6..<8 = "Cat",
}
```

The built-in `len` procedure returns the array length.

```odin
x: [5]int = {};
#assert(len(x) == 5);
```

Built-in array access is always bounds checked, at compile time for constant indices and at runtime otherwise. Unchecked access crosses the `core:unsafe` boundary and uses a multi-pointer:

```odin
p := unsafe.raw_data(&x);
p[n] = 123; // unchecked; the programmer proves that n is valid
```

There is no source attribute or build flag that silently changes ordinary indexing semantics. The explicit conversion should be limited to small scopes where the bounds argument is locally evident.

## SIMD vectors

`Simd(T, N)` is a predeclared generic type representing a fixed-width vector of `N` lanes of `T`. `N` must be a compile-time constant power of two, and `T` must be a built-in integer, floating-point, or boolean type.

Arithmetic and bitwise operators apply **lane-wise** and produce a vector of the same shape. A scalar `T` implicitly converts to `Simd(T, N)` by splatting into every lane, so mixed scalar-vector expressions work without a written conversion:

```odin
a: Simd(f32, 4) = {1, 2, 3, 4};
b := a * 2;              // {2, 4, 6, 8}: the scalar is splatted
c := a + b;              // lane-wise
lane := c[1];            // constant index yields f32
```

Comparison operators are **whole-vector**, not lane-wise: `==` and `!=` on two vectors yield a single `bool`, matching what [comparability](#comparison-operators) means everywhere else in the language and keeping `Simd` usable with `Equatable`, maps, and generic code. Per-lane predicates and the masks they produce are `core:simd` procedures such as `simd.lanes_eq`, which return a boolean vector. Ordering operators are not defined on vectors.

Indexing requires a constant index and is bounds-checked at compile time. A lane is not addressable — `&v[0]` is rejected — because a vector value may live entirely in a register. Code that needs element addresses goes through `unsafe.raw_data(&v)`, which yields `[^]T` over the vector's storage.

Size and alignment are target-defined; `size_of(Simd(T, N))` is at least `N*size_of(T)` and may be larger. A `Simd(T, N)` type is [foreign-ABI-safe](#foreign-abi-safe-types) only on a target whose ABI defines a vector class for that shape, on the same terms as `f16` and the 128-bit integers.

## Slices

A slice is a non-owning view of a sequence. Its length is a runtime value. `[]T` has read-only elements. `[]mut T` has mutable elements. Both types have the same runtime representation. Mutability is a static capability and does not change the ABI.

A mutable slice implicitly weakens to a read-only slice. A read-only slice never converts to a mutable slice, including when its original owner happens to be mutable. Slicing a mutable, addressable array or dynamic array produces `[]mut T`; slicing an immutable parameter, a string, or an existing `[]T` produces `[]T`.

A slice expression has a low bound and a high bound separated by a colon:

a[low : high]

The range includes the low bound and excludes the high bound.

```odin
fibonaccis := [6]int{0, 1, 1, 2, 3, 5};
s: []int = fibonaccis[1:4]; // creates a slice which includes elements 1 through 3
fmt.println(s); // 1, 1, 2
```

A slice does not own element storage. Its runtime value contains a pointer and a length.

**A slice is a borrow.** It is not an owning value: it has no allocator, it is never cleaned up at scope exit, and it cannot be a `manual` owner. Creating a slice over a dynamic array therefore constrains that container for as long as the slice is live, and the rules in [Borrows and lifetimes](#borrows-and-lifetimes) apply in full:

```odin
numbers := [dynamic]int{1, 2, 3};
view: []int = numbers[:]; // mutable capability is weakened to read-only
numbers.append(4);   // ERROR: `numbers` may reallocate while `view` is live
fmt.println(view[0]);
```

A slice over a fixed array is a borrow of that array's storage, and so is bound by the array's scope in the same way. A slice over a string literal borrows static storage and is therefore valid for the whole program.

To keep the data after the owner expires, make an owned copy. `slice.clone(view)` returns an owned `[dynamic]T`.

The built-in `len` procedure returns the slice length. Element assignment and iteration by reference require `[]mut T`:

```odin
x: []mut int = ...;
x[0] = 10;
foreach (&value in x) {
	value += 1;
}
length_of_x := len(x);
```

### Slice literals

A slice literal does not specify a length. This is an array literal:

[3]int{1, 6, 3}

This slice literal creates the same hidden array and returns a read-only slice of it:

[]int{1, 6, 3}

**A slice literal has the type it is written with.** `[]T{...}` produces `[]T` and `[]mut T{...}` produces `[]mut T`; the capability is never inferred against the spelling, so a reader can tell from the literal alone whether its elements can be written. A `[]mut T` literal may still be weakened by an explicit `[]T` destination, like any other mutable slice.

```odin
readable := []int{1, 6, 3};        // []int
writable := []mut int{1, 6, 3};    // []mut int
writable[0] = 99;
readable[0] = 99;                  // ERROR: elements of `[]int` are read-only
```

The backing array of a slice literal is a hidden fixed-array owner in the surrounding lexical scope, so the slice remains valid until that scope exits. At file scope it has static lifetime. Returning a slice literal from a procedure is rejected because its hidden owner is local, just as returning a slice of a named local array is rejected.

### Slice shorthand

For the array:

```odin
a: [6]int = {};
```

these slice expressions are equivalent:

a[0:6]
a[:6]
a[0:]
a[:]

When grabbing a chunk of a slice:

a[offset:offset+length]

can also be written:

a[offset:][:length]

### Nil slices

The zero value of a slice is nil. A nil slice has a length of 0 and does not point to any underlying memory. Slices can be compared against nil and nothing else.

```odin
s: []int = nil;
if (s == nil) {
	fmt.println("s is nil!");
}
```

### Sorting slices

A mutable slice can be sorted in ascending order as follows. The library procedures accept `[]mut T`; passing a read-only `[]T` is a compile-time error:

```odin
s := []mut int{1, 6, 3, 5 ,7, 3, 0};
slice.sort(s);
```

or in descending order

```odin
r := []mut int{1, 6, 3, 5 ,7, 3, 0};
slice.reverse_sort(r);
```

## Dynamic arrays

Dynamic arrays are mutable owning values whose length may change at runtime. The value behaves like a local variable; its variable-sized backing storage is obtained through an allocator and released automatically when the array leaves scope.

```odin
x: [dynamic]int = {};
x.append(10); // the zero value is immediately usable
```

Along with `len`, dynamic arrays provide `cap` to report their current underlying capacity. Assignment creates an independent array, while `move` transfers its backing allocation:

```odin
x := [dynamic]int{1, 2, 3};
y := x;       // deep copy
z := move(x); // allocation transfer; x becomes dead
```

The allocator used by a managed dynamic array is stored with its allocation so automatic cleanup always uses the correct allocator. A declaration may select another allocator without becoming manual, using the `via` modifier. `via` is a declaration modifier and not a form of `using`; it selects storage, it does not bring names into scope.

**`via` appears only on declarations.** A procedure that needs an allocator takes an ordinary parameter. By convention, the parameter is named `allocator` and defaults to `mem.default_allocator()`. Callers supply it like any other argument.

`via` and an allocator parameter have different functions. `via` selects the declaration policy for allocations made for the destination. This policy also applies when the program clones into a dead or allocator-unbound variable. An allocator parameter is an ordinary value and follows the [runtime default](#default-values) rules. A `move` keeps the allocator of the moved owner. It does not relocate the backing storage to satisfy the destination policy.

```odin
temporary: [dynamic]u8 via scratch_allocator = {};
```

**An explicit `via` allocator is bound at the declaration; the program default is bound lazily.** A zero-valued array without `via` has no backing storage and carries an allocator-unbound sentinel. Its first operation that needs an allocator obtains `mem.default_allocator()` and records that handle before allocating. The build selects one provider for the whole program and there are no scoped overrides, so delaying this load cannot change which provider is selected. It does keep the zero representation a compile-time constant, which is required for file-scope, `static`, and `thread_local` owners. A declaration with `via` instead evaluates and records that allocator immediately.

```odin
numbers: [dynamic]int = {};                       // zero value remains unbound until needed
scratch: [dynamic]int via arena.allocator() = {}; // binds this arena here

fill(inout numbers);                              // first allocation binds the program default
fill(inout scratch);                              // continues using the bound arena
```

**The allocator selects the location of backing storage.** `[dynamic]T` specifies a runtime length and allocator-provided backing storage. It does not require heap storage. To put the backing storage in the current stack frame, use `via` with an arena over a local fixed buffer:

```odin
buffer: [4096]u8 = {};                            // a live value in this frame
arena := mem.Arena(buffer[:]);
data: [dynamic]int via arena.allocator() = {};    // runtime length, backing is in `buffer`
data.append(1, 2, 3);                             // no heap allocation
```

The array type does not always select a storage location. A local `[N]T` stores its elements directly in the local value. A `[dynamic]T` stores its elements where its allocator provides storage. That location can be on the stack. [`Small_Array(T, N)`](#fixed-capacity-arrays) stores an `N`-element buffer in the value.

The array type specifies when length and capacity are known. A value in a stack frame must have a compile-time size, and `size_of` must depend only on the type. The `manual` modifier specifies ownership. The `via` modifier specifies an allocator.

Copy initialization uses the destination's bound allocator, resolving its declaration policy if the zero destination is still allocator-unbound. Assignment into an existing live array preserves that array's allocator. `move` transfers both the allocation and its allocator; after that owner is moved out or dropped, revival by copy again uses the destination declaration's policy. `clone(value, allocator)` and `try_clone(value, allocator)` are available when a specific allocator is required.

A slice of a dynamic array is a borrowed view. While that view is live, operations that may reallocate the owner are rejected:

```odin
values := [dynamic]int{1, 2, 3};
middle := values[1:];
values.append(4); // error: append may invalidate `middle`
use(middle);
```

### Appending to a dynamic array

Container operations use method syntax. These are built-in operations rather than dynamically dispatched methods.

```odin
x: [dynamic]int = {};
x.append(123);
x.append(4, 1, 74, 3); // append multiple values at once

y: [dynamic]int = {};
y.append(..x[:]); // append a slice
```

Ordinary mutating operations use the allocator's configured failure policy, which normally reports an out-of-memory panic. Fallible variants such as `try_append` and `try_reserve` return `Allocator_Error` for code that needs to recover.

The `try_` prefix is a library-wide convention with one meaning: *report the failure this operation would otherwise panic on, and leave the value unchanged.* What it reports depends on what can fail. An operation that can fail only by allocating returns `Allocator_Error`; an operation on a container that never allocates, such as [`Small_Array(T, N)`](#fixed-capacity-arrays), has no allocator error to report and returns `bool`. The prefix names the contract, not the result type.

### Assigning to a dynamic array

`insert` adds an element and shifts later elements upwards. Its index must be in `0..=len(x)`.

**Indexed assignment does not change the array length.** `x[i] = v` causes an out-of-range panic when `i >= len(x)`. This rule prevents an incorrect index from silently increasing the array length. To assign past the current end, first change the length and then assign:

```odin
x: [dynamic]int = {};
x.reserve(16);
x.insert(0, 10);

x.resize(4);                        // [10, 0, 0, 0]
x[3] = 10;
fmt.eprintln(x[:], len(x), cap(x)); // [10, 0, 0, 10] 4 16

x[3] = 20;
x.append(30);
fmt.eprintln(x[:], len(x), cap(x)); // [10, 0, 0, 20, 30] 5 16

x.append(40, 50, 60);
fmt.eprintln(x[:], len(x), cap(x)); // [10, 0, 0, 20, 30, 40, 50, 60] 8 16
```

Loke has no separate grow-and-assign operation. Use `resize` to grow and zero-fill an array. Use `append` to add elements at the end.

### Removing from a dynamic array

Removing from a dynamic array can be done in several ways using the built-in procedures:

- `pop` removes and returns the last element with [optional-ok semantics](#optional-ok-results), as `(T, bool)`; on an empty array the value is zero and `ok` is false.
- `remove_unordered` removes and returns an element in O(1) by moving the last element into its location.
- `remove` removes and returns an element while preserving order.

```odin
x: [dynamic]int = {};
x.append(1, 2, 3, 4, 5); // [1, 2, 3, 4, 5]
x.pop(); // [1, 2, 3, 4]
x.remove(0); // [2, 3, 4]
x.remove_unordered(0); // [4, 3]
```

Other variants can be found in the built-in procedures documentation.

### Slicing and sorting a dynamic array

Although dynamic arrays and slices are different concepts, dynamic arrays can be ‘sliced’ and sorted as follows:

```odin
s: [dynamic]int = {};
s.append(1, 6, 3, 5, 7, 3, 0); // [1, 6, 3, 5, 7, 3, 0]
s.sort(); // [0, 1, 3, 3, 5, 6, 7]
```

### Creating and releasing slices and dynamic arrays

Managed dynamic arrays need no explicit construction or deletion. Their zero value is usable, literals create managed values, and capacity can be reserved separately:

```odin
a: [dynamic]int = {};   // len(a) == 0, cap(a) == 0
b := [dynamic]int{1, 2, 3};
c: [dynamic]int = {};
c.resize(6);            // len(c) == 6; new elements are zero
c.reserve(32);          // capacity is at least 32

// with an explicit allocator:
scratch := mem.Scratch();
temporary: [dynamic]int via scratch.allocator() = {};
temporary.reserve(64);
```

`drop` releases an owner, writes its inert zero representation, and makes the binding dead. Managed code can instead use automatic scope cleanup.

```odin
drop(b);
// `b` is dead here; assign a complete new value before using it again.
b = [dynamic]int{};
assert(len(b) == 0);
```

Low-level code may opt out of scope-exit cleanup with `manual` and use the explicitly fallible `make` constructor. `make` returns an ordinary owning value; the destination declaration determines whether cleanup is automatic. Moving an existing manual owner into a managed variable still requires `move`, for the same reason every ownership transfer does:

```odin
raw: manual [dynamic]int;
allocation_error: Allocator_Error;
raw, allocation_error = make([dynamic]int, 0, 64, my_allocator);
if (allocation_error != nil) { panic("array allocation failed"); }
owned := move(raw); // `owned` is managed; `raw` is dead and needs no `drop`

managed, managed_error := make([dynamic]int, 0, 64, my_allocator);
// `managed` is cleaned up automatically because its declaration is not manual.
```

### Clearing a dynamic array

`clear` removes all elements from a dynamic array. It sets `len()` to 0 and does not change `cap()`.

```odin
x: [dynamic]int = {};
x.append(1, 2, 3, 4, 5); // [1, 2, 3, 4, 5]
fmt.println(len(x)); // 5
x.clear(); // []
fmt.println(len(x)); // 0
```

### Resizing and reserving a dynamic array

A dynamic array can change its length or reserve capacity. These operations have different effects:

- `resize` sets the length to the requested element count. It can also increase the capacity.
- `reserve` makes the capacity at least the requested element count. It does not change the length.
- `shrink` reduces the capacity to the current length or to the specified minimum capacity.

```odin
x: [dynamic]int = {};
fmt.println(len(x), cap(x)); // 0 0
x.append(1, 2, 3); // [1, 2, 3]
fmt.println(len(x), cap(x)); // 3 8 — the growth policy is implementation-defined; 8 is illustrative
x.resize(5);
fmt.println(x[:]); // [1, 2, 3, 0, 0] other values are zero'd memory
fmt.println(len(x), cap(x)); // 5 8
x.reserve(32);
fmt.println(len(x), cap(x)); // 5 32
x.shrink();
fmt.println(len(x), cap(x)); // 5 5
```

### Fixed-capacity arrays

A growable array with inline fixed capacity is the library type `Small_Array(T, N)`, not a second built-in array form. It implements the ordinary indexing, slicing, iteration, and container procedures through the same abstraction facilities available to user code. It never allocates; operations that would exceed `N` panic, while their `try_` forms leave the value unchanged and return false.

```odin
x: Small_Array(int, 8) = {};
x.append(1, 2, 3);
fmt.println(len(x), cap(x)); // 3 8
```

## Enumerations

An enumeration defines a distinct type and a fixed set of named values. Values have declaration order:

```odin
Direction :: enum{North, East, South, West};
```

The following holds:

int(Direction.North) == 0
int(Direction.East)  == 1
int(Direction.South) == 2
int(Direction.West)  == 3

Enum fields can be assigned an explicit value:

```odin
Foo :: enum {
	A,
	B = 4, // Holes are valid
	C = 7,
	D = 1337,
}
```

If an enumeration requires a specific size, a backing integer type can be specified. By default, int is used as the backing type for an enumeration.

```odin
Foo :: enum u8 {A, B, C}; // Foo is 8 bits
```

Enum members are named constants, not numbers with a name: they may have holes, and arithmetic on them is not defined. See [Arithmetic operators](#arithmetic-operators). Convert to the backing integer type when a numeric value is wanted, and use the library `Bit_Set(Enum)` for flag sets.

Compiler-provided enums such as `LOKE_ARCH` spell their members in `Capitalized_Snake_Case`, and the core library follows the same convention. This is a naming convention for the library rather than a rule the compiler enforces, but the spelling of a compiler-provided member is normative.

### Implicit selector expression

An implicit selector omits the enumeration type when context supplies that type. It has this form:

.member_name

For example:

```odin
Foo :: enum{A, B, C};
f: Foo;
f = Foo.A;
f = .A;

switch (f) {
case .A:
	fmt.println("foo");
case .B:
	fmt.println("bar");
case .C:
	fmt.println("baz");
}
```

### Iterating an enumeration

An enum *type* can be iterated directly, yielding its declared members in declaration order. This supports tasks such as printing every member or populating a library-defined `Enum_Array(Enum, T)`.

This is a compiler special case, not an instance of the [iteration protocol](#iteration-protocol). The protocol is defined over runtime values via `iter(value)`, while a `type` value exists only at compile time and has no `impl` on which an `iter` overload for `Direction` could be declared. The compiler recognizes an enum type in the iterable position of a `foreach` header and lowers it directly. It is the only type accepted there; `foreach (x in int)` and `foreach (x in Some_Struct)` are errors.

```odin
Direction :: enum{North, East, South, West};

foreach (direction, index in Direction) {
	fmt.println(index, direction);
	// 0 North
	// 1 East
	// 2 South
	// 3 West
}
```

## Pointers

A pointer contains the memory address of a value. `^T` is a pointer to `T`. Its zero value is `nil`.

```odin
p: ^int = nil;
```

The `&` operator returns the address of an addressable operand:

```odin
i := 123;
p := &i;
```

The postfix `^` operator dereferences a pointer:

```odin
fmt.println(p^); // read `i` through the pointer `p`
p^ = 1337;       // write `i` through the pointer `p`
```

Loke uses `^` for pointer types and pointer dereference:

```odin
i := 0;
p: ^int = &i; // ^ on the left
x := p^;      // ^ on the right
```

Pointer arithmetic is not an operator. `core:mem.ptr_offset` and
`core:mem.ptr_sub` provide explicit address calculations.

## Structs

A struct is a record that contains named fields. The dot operator selects a field:

```odin
Vector2 :: struct {
	x: f32,
	y: f32,
}
v := Vector2{1, 2};
v.x = 4;
fmt.println(v.x);
```

The dot operator can also select a field through a struct pointer:

```odin
v := Vector2{1, 2};
p := &v;
p.x = 1335;
fmt.println(v);
```

For a pointer to a struct, `p.field` is equivalent to `p^.field`.

### Struct literals

A struct literal starts with its type and a pair of braces. An unnamed initializer list must supply all fields or no fields:

```odin
Vector3 :: struct {
	x, y, z: f32,
}
v: Vector3;
v = Vector3{}; // Zero value
v = Vector3{1, 4, 9};
```

A named initializer list can supply a subset of fields. Field order does not matter. Omitted fields use their zero value:

```odin
v := Vector3{z=1, y=2};
assert(v.x == 0);
assert(v.y == 2);
assert(v.z == 1);
```

Structs can be nested by defining a field as a struct.

```odin
Foo :: struct {
	a, b, c: int,
	
	bar_1: struct {
		x, y, z: int,
	},

	bar_2: struct {
		x, y, z: int,
	},

	_: struct {
		x, y, z: int,
	},
}
```

### Struct layout attributes

Structs can be annotated with different memory layout and alignment requirements:

struct @(align=4)  {...} // require four-byte alignment
struct @(packed)    {...} // remove padding between fields

These use the same attribute syntax as declarations and statements. Minimum/maximum field-alignment variants, bitwise-equality assertions, and all-or-none literal checking are not separate language features. Foreign layout uses the target ABI rules, equality optimizations require compiler proof, and validated construction uses an `init` procedure.

### Struct field tags

A string literal after a struct field is a field tag. Runtime type information can read this metadata. Libraries usually use tags to specify how to encode, decode, or format a field. The language does not interpret the tag contents.

```odin
User :: struct {
	flag: bool, // untagged field
	age:  int    "custom whatever information",
	name: string `json:"username" xml:"user-name" fmt:"q"`, // `core:reflect` layout
}
```

Within Loke’s core library, the standard convention is to use a key that denotes the consuming package followed by a value. For example, `json` tags are processed by `core:encoding/json`, while `fmt` tags are processed by `core:fmt`.

A package can define comma-separated options in its tag value. For example:

```odin
name: string `json:"username,omitempty"`,
```

## Unions

A union is a discriminated union, also known as a tagged union or sum type. The zero value of a union is nil.

```odin
Value :: union {
	bool,
	i32,
	f32,
	string,
}
v: Value;
v = "Hellope";

// type assert that `v` is a `string` and panic otherwise
s1 := v.(string);

// Type assertion with an explicit Boolean check. This does not panic.
s2, ok := v.(string);
```

A type assertion is single-valued where the asserted type is the only expected result, and it panics if the union does not currently hold that variant. In a comma-ok destination or as the left operand of `or_else` it instead has [optional-ok semantics](#optional-ok-results), producing `(T, bool)` and never panicking.

A type assertion must name the asserted type. The compiler does not infer it from context. A union has multiple variants, so the type name makes the selected variant explicit.

### Type assertions are always checked

There is no attribute, build flag, or `core:unsafe` operation that removes the
tag check from `v.(T)`. Code that already knows the active variant still uses
the ordinary assertion; the optimizer may remove the check when that fact is
provable.

### Type switch statement

A type switch is a construct that allows several type assertions in series. A type switch is like a regular switch statement, but the cases are types (not values). For a union, the only case types allowed are that of the union.

```odin
value: Value = ...;
switch (v in value) {
case string:
	#assert(type_of(v) == string)

case bool:
	#assert(type_of(v) == bool)

case i32, f32:
	// This case allows for multiple types, therefore we cannot know which type to use
	// `v` remains the original union value
	#assert(type_of(v) == Value)
case:
	// Default case
	// In this case, it is `nil`
}
```

### Union alignment

Unions have the `align` attribute, like structures:

union @(align=4) {...} // align to 4 bytes

## Maps

A map maps keys to values. Its zero value is empty and immediately usable. Like a dynamic array, a map is managed by default and releases its backing storage automatically.

**Iteration order is unspecified.** It can differ between iterations of one unmodified map, between maps with the same entries, and between program runs. To get a stable order, collect and sort the keys. Map iteration is not valid on an executed [compile-time path](#compile-time-procedure-evaluation), because compile-time results must be reproducible.

Any type can be a map key when it satisfies the operations of `interfaces.Hashable`, with a **coherent** `==` and `hash(value, seed: uint) -> uint`. The built-in conformances are the exact list under the [standard interface catalogue](#standard-interface-catalogue). For a user-defined key, both operations must be inherent implementations belonging to the key type; caller-local extensions do not qualify even if an ordinary interface check in that extension's package would succeed. This ensures that a `map[K]V` passed between packages continues to use one equality and hashing policy. Code that needs a different policy wraps the key in a local `distinct` type with its own inherent operations, or uses a library map type whose hasher and equality policy are explicit type or value parameters. The compiler trusts the programmer to preserve the semantic rule that equal values produce equal hashes.

```odin
m: map[string]int = {};
m["Bob"] = 2;
fmt.println(m["Bob"]);
```

To insert or update an element of a map:

```odin
m[key] = elem;
```

To retrieve an element:

```odin
elem = m[key];
```

To remove an element:

```odin
m.remove(key);
```

A lookup of a missing key returns the zero value. Use the optional-ok result or the `in` operator to test whether the key exists:

```odin
elem, ok := m[key]; // `ok` is true if the element for that key exists
```

or

```odin
ok := key in m; // `ok` is true if the element for that key exists
```

The first form is the **comma-ok** form.

A map literal initializes a map:

```odin
m := map[string]int{
	"Bob" = 2,
	"Chloe" = 5,
}
```

Map literals create managed values using the current allocator. Low-level code that must avoid implicit allocation can use a `manual` declaration or a project-level lint that rejects implicit allocation.

A map index in a place position is a location, so a field of a stored value can be assigned directly:

```odin
Test :: struct {
	x: int,
	y: int,
}

m := map[string]Test{
	"Bob" = { 0, 0 },
	"Chloe" = { 1, 1 },
}

m["Bob"] = { 3, 3 };
m["Chloe"].x = 0;    // allowed: assigns the field of the stored value
m["Dana"].x = 7;     // inserts a zero `Test` for "Dana", then assigns `.x`
```

The two forms differ when the key is missing:

- **`m[key]` as an assignment target inserts.** If the key is absent, the zero value of the element type is inserted first and the resulting slot is the location. This is the same behavior `m[key] = elem` already has, extended to field and index chains so that the two do not disagree. It applies to the target of an assignment or compound assignment and to an argument passed as `inout`. Insertion may reallocate the map, so the index is a mutable borrow of `m` for the duration of the statement.

  This behavior differs from [dynamic-array assignment](#assigning-to-a-dynamic-array). An array index past the end causes a panic and does not grow the array. A map key is not positional, and ordinary `m[key] = elem` already means insert or update. Field and index chains use the same map insertion rule.
- **A non-inserting lookup is `m.find(key)`,** not `&m[key]`. It has [optional-ok semantics](#optional-ok-results), yielding a pointer to the existing slot and a `bool`:

```odin
value, ok := m.find("Bob");
if (ok) {
	value^ = { 2, 2 };
}
```

  `&m[key]` is not a special lookup form. The `&` operator always returns one pointer, and it does not return an optional-ok result. Use `find` for a non-inserting lookup. The method name makes the behavior explicit.

### Map container operations

The built-in map supports these container operations:

- `len(some_map)` returns the number of entries.
- `cap(some_map)` returns the current capacity. An insertion can reallocate when it exceeds this capacity.
- `some_map.clear()` removes all entries and retains the capacity.
- `some_map.reserve(capacity)` reserves capacity for at least the requested number of entries.
- `some_map.shrink()` removes excess capacity.
- `some_map.find(key)` returns `(^V, bool)`. It returns a pointer to the existing value and `true`, or `nil` and `false`. It does not insert.

## Procedure type

A procedure type is a code pointer. Its zero value is `nil`.

Examples:

```odin
proc(x: int) -> bool
proc(c: proc(x: int) -> bool) -> (i32, f32);
```

A variable can have a procedure type:

```odin
Callback :: proc() -> int;
a: Callback = nil;
assert(a == nil);
a = proc() -> int { return 0; };
fmt.println(a()); // 0
a = proc() -> int { return 100; };
fmt.println(a()); // 100
```

### Calling conventions

Loke supports the following calling-convention names:

- `loke` — the default convention for a Loke procedure, using the target-specific parameter classification described under [Parameter semantics and ABI lowering](#parameter-semantics-and-abi-lowering). It passes only the arguments required by the source-level procedure type and ABI lowering; there is no implicit environment pointer.
- `c` — the target C ABI's default calling convention.
- `stdcall` — the Microsoft stdcall convention on targets that support it.

Compiler- or target-specific conventions use namespaced extension strings rather than portable aliases. The portable set is limited to conventions with a stable cross-toolchain meaning.

The default calling convention is `loke`, unless a declaration is within a foreign block, where it is `c`.

A procedure type with a different calling convention can be declared like the following:

proc "c" (n: i32, data: rawptr)

Procedure types are compatible only when calling convention, parameter and result types, parameter modes, variadic shape, and type-level parameter effects match. In particular, `@(allocator_reset)` is part of the parameter's procedure type: a reset-capable procedure cannot be stored in a procedure value whose type hides that effect. Declaration-only attributes such as visibility and deprecation do not participate in type compatibility. Omitted-argument defaults are declaration metadata rather than type metadata; every call through a procedure value supplies the full parameter list.

Result-provenance summaries are also declaration metadata rather than part of a
procedure type. A direct call can use the summary, but converting a declaration
to a procedure value erases it and activates the conservative indirect-call
rule under [Temporaries and procedure boundaries](#temporaries-and-procedure-boundaries).

## `type` and `typeid`

`type` is a compile-time-only type whose values are Loke types. It is used for
generic type parameters, compile-time reflection, and procedures that compute a
type:

```odin
Index_Type :: proc($Count: uint) -> type {
	when (Count <= 256) {
		return u8;
	} else when (Count <= 65536) {
		return u16;
	} else {
		return u32;
	}
}

Index :: Index_Type(1000);
```

A `type` value has no runtime representation or zero value. It may be bound by a
constant, used as a `$` parameter, or returned by a procedure whose every call
is evaluated at compile time. It cannot be the type of a variable, ordinary
non-`$` parameter, record field, container element, foreign declaration, or
runtime procedure value; compiler-defined reflection descriptors are the only
records allowed to carry it internally. A procedure whose signature contains `type` or a
compile-time reflection descriptor is itself compile-time-only and cannot be
exported or stored in a procedure value.

Two `type` values support `==` and `!=` during compilation; equality means the
same Loke type identity after aliases are resolved. They have no ordering and
cannot be elements or keys of runtime or materialized containers.

`typeid` is an ordinary runtime scalar containing the unique identifier of one
concrete runtime type. A `typeid` is not usable as a type and does not make a
generic procedure. This separation keeps runtime reflection from becoming a
second spelling of specialization.

`typeid` is used by `any_view`, [`dyn Interface`](#borrowed-dynamic-interface-values),
and runtime reflection:

```odin
a := typeid_of(bool);
i: int = 123;
b := typeid_of(type_of(i));
```

A typeid can be mapped to relevant type information which can be used in applications such as printing types and editing data:

```odin
import "base:runtime";

main :: proc() {
	u := u8(123);
	id := typeid_of(type_of(u));
	info: ^runtime.Type_Info;
info = type_info_of(id);
}
```

`typeid_of(T)` maps a compile-time `type` value to its runtime `typeid` constant.
`type_info_of(id)` accepts a runtime `typeid` and returns runtime metadata. It
does not recover a compile-time `type`, because runtime information cannot flow
back into specialization.

## Compile-time reflection

The compiler exposes two typed, immutable reflection descriptors, `meta.Field`
and `meta.Enum_Value`. Their names are exported by the compiler-defined
`base:meta` package and they exist only during compilation.

`fields_of(T)` and `enum_values_of(T)` return compile-time fixed arrays of the
corresponding descriptor type. Descriptors are opaque and cannot be forged. Names
are constant `string_view` values, and a descriptor's `.type` member is a
compile-time `type` value. A `meta.Field` also carries its declared
[field tag](#struct-field-tags), which is what serialization libraries read.

Both preserve source declaration order, after conditional `when` selection.
Reflection observes only declarations visible at the reflection site.

Reflection is limited to these two descriptors. Adding a further descriptor in a
later version is a backward-compatible change; removing one is not.

A `meta.Field` bound by static expansion provides compiler-defined operations
whose result follows that particular field's type:

```odin
visit_fields :: proc(value: ^$T, visitor: inout $Visitor) {
	foreach ($field in fields_of(T)) {
		visitor.visit(field.pointer(value));
	}
}
```

`field.get(value)` accepts `^T`, reads the selected field, and has type
`field.type` after expansion. `field.pointer(value)` also accepts `^T` and
returns `^field.type`. Both take a pointer so that one expansion body can use
either without restructuring its parameter. The
normal visibility, packed-field, borrow, copy, and mutation rules still apply;
`pointer` is rejected for a packed field. There is no string-based field lookup.

Reflection values may be inspected, compared for identity, passed to `$`
parameters, and iterated by static `foreach`. They cannot be materialized into
runtime storage. Runtime tools instead use the less powerful
`runtime.Type_Info` reached through `type_info_of`.

## any_view type

`any_view` is a non-owning type-erased value, used for formatting, logging, reflection, and other call-oriented APIs. Internally it is a pointer plus a `typeid`, and creating one borrows its source. Its zero value is nil.

It may be a local variable or parameter, but it cannot be a result type, global, struct or union field, container element, or captured/stored value. The ordinary local borrow checker ensures a local `any_view` does not outlive or overlap an invalidating operation on its source. A temporary converted for a call remains valid through that complete call expression.

**A variadic `..any_view` parameter is the only exception to the container rule.** Formatting procedures such as `fmt.println(a, b, c)` use this form. The caller converts each argument to `any_view`. It materializes a temporary `[]any_view` for the duration of the call.

```odin
println :: proc(args: ..any_view) { ... }
```

This exception does not permit an escape. The slice and its elements borrow the caller's temporary arguments. They are live only for the complete call expression. The called procedure can read, index, iterate, and forward the slice to another `..any_view` parameter. It must not store the slice or an element past the call.

No other operation can produce `[]any_view`. Loke has no `any_view` array, dynamic array, or slice local. Thus, this syntax is a calling form, not a general container type. [`@(c_vararg)`](#c_vararg) is separate. It is signature notation, and the compiler passes the original concrete arguments with the C default argument promotions.

Conversion from a concrete value to `any_view` is implicit when an `any_view` parameter or local destination is expected, and it never allocates. It supports runtime type assertions and type switches.

```odin
print_value :: proc(value: any_view) { ... }
print_value(42); // the temporary lives through the call
```

`any_view` has no owning counterpart. Its unrestricted type erasure is
call-scoped: a procedure may inspect the erased value but cannot retain it.

Code that needs to retain a value of one of several types uses a union. Code that
needs open borrowed runtime behavior uses `dyn Interface`, an explicit procedure
table, or a library-defined record of callbacks. Code that needs to retain
something genuinely arbitrary owns it concretely and passes an `any_view` or
`dyn` view at the point of use.

## Multi-pointers

Multi-pointers are a way to describe foreign (C-like) pointers which act like arrays (pointers that map to multiple items). The type [^]T is a multi-pointer to T value(s). Its zero value is nil.

```odin
p: [^]int = nil;
```

What multi-pointers support:

- Indexing without bounds checking.
- Slicing, with bounds checking when both low and high operands are given.
- Implicit conversions between `^T` and `[^]T`.
- Implicit conversion to `rawptr`, like all pointers.

What multi-pointers DO NOT SUPPORT:

- Dereferencing, making a multi-pointer closer to a slim slice than a pointer.

The main purpose of this type is to aid with foreign code and act as a way to auto-document functionality and allow for easier transition to Loke code, especially converting pointers into slices.

The following are the rules for indexing and slicing for multi-pointers, and what type they produce depending on the operands given:

```odin
x: [^]T = ...;
```

x[i]   -> T
x[:]   -> [^]T
x[i:]  -> [^]T
x[:n]  -> []T
x[i:n] -> []T

Interacting with Multi-Pointers is easiest using `unsafe.raw_data`, which makes the loss of bounds and borrow capability visible at the call site.

```odin
a: [^]int = nil;
fmt.println(a); // <nil>
b := [?]int { 10, 20, 30 };
a = unsafe.raw_data(b[:]);
fmt.println(a, a[1], b); // 0x7FFCBE9FE688 20 [10, 20, 30]
```

The language name for `[^]T` is *multi-pointer*.

## unsafe.raw_data procedure

`unsafe.raw_data` is a `core:unsafe` procedure that returns the underlying data of a built-in data type as a multi-pointer. A multi-pointer carries neither a length nor a read-only capability, and its lifetime is no longer checked after conversion.

```odin
unsafe.raw_data([]$E)              -> [^]E;    // read-only slices; capability is discarded
unsafe.raw_data([]mut $E)          -> [^]E;    // mutable slices
unsafe.raw_data([dynamic]$E)       -> [^]E;    // dynamic arrays
unsafe.raw_data(^[$N]$E)           -> [^]E;    // fixed arrays
unsafe.raw_data(^Simd($E, $N))     -> [^]E;    // SIMD vectors
unsafe.raw_data(string)            -> [^]byte;
```

For a nested fixed array, `unsafe.raw_data` exposes one array level at a time. If `grid` has type `[Rows][Columns]T`, then `unsafe.raw_data(&grid)` has type `[^][Columns]T`, while `unsafe.raw_data(&grid[0])` has type `[^]T` and points at the first scalar element of the contiguous row-major storage.

## Promoted struct fields

A struct field declared with `using` promotes that field's members for selector lookup on the containing value. This is the only use of `using`; it does not import packages or inject names from parameters, locals, enum types, or arbitrary values into lexical scope.

```odin
Vector3 :: struct{x, y, z: f32};
Quaternion_F32 :: struct{x, y, z, w: f32}; // ordinary library-defined type
Entity :: struct {
	position: Vector3,
	orientation: Quaternion_F32, // library-defined type
}
```

Promoting `position` makes its fields appear as selectors on `Entity`:

```odin
Entity :: struct {
	using position: Vector3,
	orientation: Quaternion_F32, // library-defined type
}
foo :: proc(entity: ^Entity) {
	fmt.println(entity.x, entity.y, entity.z);
}
```

Promoted names are only member-lookup shorthand. An explicitly declared field on the outer struct wins over a promoted name; otherwise two promoted fields supplying the same name make that selector ambiguous. A `using` field does not make the containing struct a subtype of the field type and does not create an implicit conversion. Passing the embedded value requires explicit selection, such as `consume(value.position)`.

# Error handling

## Optional-ok results

The common absence protocol is a value followed by a `bool` named `ok`: `(T, bool)`, or more generally `(A, B, ..., bool)`. `ok` is `true` when the preceding results are present. Built-in producers return the zero values of those results when `ok` is false; `or_else` and iteration do not observe the failed values. User procedures using this shape should follow the same convention.

An **optional-ok expression** is a built-in producer with that logical result shape or a procedure call with at least two results whose final result is `bool`. It therefore always has one or more payload results before the status. A comma-ok destination receives every result. `or_else` consumes the final `bool` and either yields the preceding payload results or evaluates its fallback. A procedure returning only `bool` is a status expression usable by `or_return` or ordinary control flow, but it is not an optional-ok expression and cannot be the left operand of `or_else`. The term describes this shared status protocol; it does not invent a universal plain single-value behavior. For example, a missing map lookup yields zero in its documented single-value form, while a failed single-value union assertion panics.

## or_else expression

`or_else` is an infix binary operator that supplies fallback values for an [optional-ok expression](#optional-ok-results). If the left operand has logical results `(A, B, ..., bool)`, the fallback expression must produce exactly `(A, B, ...)`, with each value assignable to the corresponding payload type. A single-payload fallback is any ordinary expression. A multiple-payload fallback must be a multiple-result call; Loke has no tuple literal that would provide a second spelling. The fallback is evaluated only when `ok` is false.

```odin
m: map[string]int = {};
i: int;
ok: bool;

if (i, ok = m["hellope"]; !ok) {
	i = 123;
}
// The above can be mapped to `or_else`
i = m["hellope"] or_else 123;

assert(i == 123);
```

`or_else` can be used with type assertions too, as they have optional-ok semantics.

```odin
v: union{int, f64} = nil;
i: int;
i = v.(int) or_else 123;
assert(i == 123);
```

`or_else` works with any optional-ok expression, so it applies equally to a map index, a validating conversion, a type assertion, and a procedure returning `(T, bool)`:

```odin
n := numbers.pop() or_else 0;
text := string(bytes) or_else "";

fallback_pair :: proc() -> (int, string) { return 0, ""; }
number, label := parse_pair(input) or_else fallback_pair();
```

## or_return operator

`or_return` is an error-propagation operator for an expression whose final result is a status value. The operand is evaluated exactly once. The status is successful when it is `true` for `bool`, or `nil` for a nil-comparable type; no other truthiness rules apply.

On success, `or_return` removes the final status and yields the preceding result values. A single-valued operand therefore yields no value and may only be used as a statement. On failure, control returns from the innermost enclosing procedure:

- If the procedure has one result, the failed status must be assignable to it and is returned directly.
- If the procedure has multiple results, every result must be named. The failed status must be assignable to the final result; it is assigned there and a bare `return` is performed. Every earlier named result must already be definitely live at the `or_return` expression and retains its current value. Otherwise the expression is a compile-time definite-initialization error.

The operand's temporary values are destroyed before the return completes, and normal `defer` and cleanup rules run. `or_return` cannot appear outside a procedure or inside a deferred statement. A nested procedure propagates only from that nested procedure, never from its lexical parent.

```odin
Error_Code :: enum {
	Something_Bad,
	Something_Worse,
	The_Worst,
	Your_Mum,
}

// The union's zero value is nil, which is the successful status.
// A failure contains one Error_Code value.
Error :: union {Error_Code};

caller_1 :: proc() -> Error {
	return nil;
}

caller_2 :: proc() -> (int, Error) {
	return 123, nil;
}
caller_3 :: proc() -> (int, int, Error) {
	return 123, 345, nil;
}

foo_1 :: proc() -> Error {
	// This can be a common idiom in many code bases
	n0, err := caller_2();
	if (err != nil) {
		return err;
	}

	// The above idiom can be transformed into the following
	n1 := caller_2() or_return;

	// And if the expression is 1-valued, it can be used like this
	caller_1() or_return;
	// which is functionally equivalent to
	if (err1 := caller_1(); err1 != nil) {
		return err1;
	}

	// Multiple return values still work with `or_return` as it only
	// pops off the end value in the multi-valued expression
	n0, n1 = caller_3() or_return;

	return nil;
}
foo_2 :: proc() -> (n: int, err: Error) {
	// A procedure usually returns multiple values in this case.
	// If `or_return` is used within a procedure that returns multiple 
	// values (2+), then all the returned values must be named 
	// so that a bare `return` statement can be used. Earlier results must
	// already be initialized because propagation returns their current values.
	n = 0;

	// This can be a common idiom in many code bases
	x: int;
	x, err = caller_2();
	if (err != nil) {
		return;
	}

	// The above idiom can be transformed into the following
	y := caller_2() or_return;
	_ = y;

	// And if the expression is 1-valued, it can be used like this
	caller_1() or_return;

	// which is functionally equivalent to
	if (err1 := caller_1(); err1 != nil) {
		err = err1;
		return;
	}

	// If using a non-bare `return` statement is required, setting the return values
	// using the normal idiom is a better choice and clearer to read
	if (z, zerr := caller_2(); zerr != nil) {
		return -345 * z, zerr;
	}

	n = 123;
	return;
}

caller_4 :: proc() -> (n: int, ok: bool) {
    return 3, true;
}

foo_3 :: proc() -> (ok: bool) {
    // `or_return` also supports the ok semantics common in Loke code.
    // Note an error is indicated by `ok` being `false`
	ok = false;
    x := caller_4() or_return;

    if (x < 5) {
        ok = true;
    }

    return;
}
```

# Panics and unwinding

A **panic** is an unrecoverable runtime fault. When the same operation is
reached during required compile-time procedure evaluation, it is instead a
compilation diagnostic with the evaluator call stack. These operations cause a
runtime panic in runtime execution:

- `panic(message)`
- a failed `assert`
- dereference of a nil pointer
- a call through a nil `dyn` view
- integer division or remainder by zero
- an out-of-range built-in index
- a failed checked type assertion, `v.(T)`
- an allocation failure when the allocator policy is [`.Panic`](#allocation-failure)

Version 1 has no `recover`, `try`, or catch construct. Loke code cannot observe or resume a panic. With the `unwind` strategy, the thread runs its registered cleanup before the program stops. The `abort` strategy does not guarantee cleanup.

## Panic strategy

The final build selects one of two **panic strategies** for the whole program, in the same way it selects the [allocator and logging providers](#build-selected-providers):

- **`unwind`** — the default on hosted targets. A panic unwinds the panicking thread's call stack frame by frame. At each frame it runs that frame's pending scope-exit actions — user `defer`s and the implicit `drop` of every live managed owner — in the one reverse-registration order defined under [Managed values and storage](#managed-values-and-storage), exactly as a `return` leaving that frame would. When the unwind leaves the outermost frame of the thread, the program terminates with a failure status.
- **`abort`** — the default on freestanding and embedded targets, and selectable on any target. A panic runs no cleanup and terminates the program immediately at the point of the fault.

An allocator whose failure policy is [`.Trap`](#allocation-failure) forces `abort` behavior for the failure it reports, regardless of the program's panic strategy. `.Panic` follows the program strategy. This is the whole meaning of the statement that `.Panic` may unwind while `.Trap` does not.

Both strategies are sound; they trade cleanup for size and simplicity. Because a panic cannot be caught either way, the strategy never changes which programs are valid, only what observable cleanup happens on the way down. Portable code therefore must not rely on a `drop` or `defer` running after a panic unless it is built with the `unwind` strategy; code that needs crash-time cleanup on a freestanding target performs it explicitly.

## What the unwind runs, and what it does not

Under the `unwind` strategy:

- Scope-exit cleanup runs for every **fully initialized** managed owner and every registered `defer` in each unwound frame, newest first. A value whose initialization had not completed when the panic was raised — including a half-constructed temporary in the faulting expression — is cleaned up only as far as its construction reached, using the same drop-flag tracking that governs ordinary [conditional cleanup](#managed-values-and-storage).
- If `main` is on the panicking thread's stack, the unwind passes through it like any other frame, so a managed owner declared as a local in `main` is dropped. This is not a program-wide guarantee: a panic raised by another thread does not unwind the thread running `main`.
- File-scope, `static`, and `thread_local` values are **not** dropped during panic termination. Managed TLS is dropped only on normal thread return; see [Values that outlive every scope](#values-that-outlive-every-scope).

Loke has no automatic package shutdown hooks. Only cleanup attached to a live owner or `defer` runs during panic unwinding.

The restrictions on a deferred statement apply equally to cleanup reached by an unwind: it may not `return`, `break`, or `continue` out of the frame being unwound, because that frame is already leaving.

## Panic during unwinding

If a `drop` hook or a deferred statement raises a panic while a panic is already unwinding the stack, the program aborts immediately, exactly as under the `abort` strategy. There is no attempt to unwind two panics at once and no defined order for their remaining cleanups. A cleanup path that can fail must handle that failure itself rather than panicking; this is why a `drop` hook is expected to be infallible and to absorb or ignore secondary errors from the resource it releases.

## Threads

A panic unwinds only the stack of the thread that raised it and then terminates the whole program; there is no per-thread recovery that turns one thread's panic into another thread's error. Other threads are not given an opportunity to unwind, so their local `drop`s and `defer`s do not run, and no surviving Loke code is guaranteed an opportunity to release their resources. A program that requires coordinated shutdown reports worker failures through ordinary error values, joins the workers, and performs cleanup without panicking. Resources that must survive abrupt process termination require an external protocol or operating-system guarantee.

# Conditional compilation

Conditional source selection uses `when`. Selecting files, generating source, discovering tests, and applying project-wide lint or feature policy are build-system responsibilities rather than additional language mechanisms. The reference commands are `loke build`, `loke run`, `loke check`, and `loke test`.

## when statements

A `when` statement includes a block only when its compile-time condition is true:

```odin
when (LOKE_OS == .Linux) {
	// Do Linux stuff
}
```

The compiler provides a small set of constants in every compilation:
| Name | Description |
| --- | --- |
| `LOKE_ARCH` | Target CPU architecture enum. |
| `LOKE_OS` | Target operating-system enum. |
| `LOKE_ENDIAN` | Target endianness enum. |
| `LOKE_BUILD_MODE` | Requested output kind. |
| `LOKE_DEBUG` | Whether debug information and debug-mode facilities are enabled. |
| `LOKE_OPTIMIZATION_MODE` | Selected optimization mode. |
| `LOKE_VENDOR` | Compiler implementation identifier; the official compiler uses `"loke"`. |
| `LOKE_VERSION` | Compiler version string. |

Additional project values are supplied by the build system and read with `#config`.

## Build configuration

Build configuration defines compile-time values for the complete project.

The build system may provide integer, boolean, or string configuration values. Source code reads them with `#config`, always supplying a default:

```odin
FOO :: #config(FOO, false); // defines `FOO` as a constant with the default value of false
BAR :: #config(BAR_DEBUG, true); // name can be different compared to the constant 

when (FOO) {
	// only evaluated when `FOO` is true
} else {
	// only evaluate when `FOO` is false
}
```

Configuration values are immutable constants. File selection, generated sources, test discovery, lint configuration, instrumentation policy, and language-feature policy are expressed in the build system rather than through source-file tags.

# Memory and program services

## Build-selected providers

The final program selects exactly one **default allocator provider** and one
**logging provider** as part of its build. A package import cannot replace either
provider, and importing the same package from two places never creates configured
copies of that package. Provider selection belongs to the final build graph rather
than to source-level package identity.

If the build does not select a provider, the standard runtime supplies the system
heap allocator and the standard logger. The selected implementations are fixed for
the resulting executable or library and may be devirtualized by the compiler.
Their state is still runtime state: an allocator has a region and callbacks, and a
logger may own buffers or synchronization. The provider must arrange required
internal initialization before `main` starts. It remains available until the
process ends. Packages cannot replace a provider or register automatic startup
or shutdown code.

`mem.default_allocator()` returns the allocator handle supplied by the selected
allocator provider. It is an ordinary runtime call or load, not a compile-time
allocator value. A live zero-valued managed owner without `via` starts in an
allocator-unbound state and binds that handle on the first operation that needs one; an
allocation procedure whose allocator argument is omitted obtains it when the
operation begins. Once an owner is bound, later calls continue to use the
recorded allocator. Loading the handle lazily is semantically stable because the
provider is fixed for the whole program and cannot be scoped or replaced at
runtime.

The `core:log` procedures route to the selected logging provider. The build may
also select a minimum compiled log level, allowing lower-level calls to be removed
entirely. A package that needs a different sink, captured test output, or
request-specific fields takes an ordinary `Logger` parameter or retains one in a
state object; there is no scoped or package-local override of the program logger.

Only provider *implementation* is selected at build time. Per-request allocators,
scratch arenas, log fields, trace spans, clocks used for simulation, deadlines,
cancellation, random-number state, and similar values have runtime identity and
are passed explicitly.

## Explicit runtime environments

Related runtime services may be grouped in an ordinary application-defined
record. The record is not compiler-known and procedures name it only when they
actually need it:

```odin
Request_Env :: struct {
	scratch:   mem.Scratch,
	logger:    Logger,
	span:      Trace_Span,
	deadline:  Time,
}

handle :: proc(env: inout Request_Env, request: Request) -> Response {
	...
}
```

Long-lived subsystems normally retain stable dependencies such as an allocator,
logger, or clock in their own record. Short-lived state stays in a request or task
environment and is moved explicitly when work is transferred to another thread.
Nothing is inherited only because one procedure called another.

Loke has no closures, but a hidden program-wide environment pointer is not a
substitute for lexical capture: it would supply the caller's state at invocation
rather than the state chosen when a procedure value was created. Immediate
callbacks instead take typed state explicitly:

```odin
visit_all :: proc(
	items: []Item,
	state: inout $S,
	visit: proc(state: inout S, item: Item),
) {
	foreach (item in items) {
		visit(inout state, item);
	}
}
```

A retained callback stores its state beside its procedure in an ordinary generic
record:

```odin
Handler :: struct($S: type) {
	state: S,
	invoke: proc(state: inout S, event: Event),
}

dispatch :: proc(handler: inout Handler($S), event: Event) {
	handler.invoke(inout handler.state, event);
}
```

This keeps ownership and borrowing visible and leaves ordinary procedure values
as one code pointer. Foreign APIs use their documented `rawptr` user-data field
when they require erased callback state; that remains an unsafe interop boundary.

## Allocators

The language uses deterministic managed memory for ordinary owning values and retains explicit allocators for systems programming. Managed values are not garbage-collected: the compiler inserts cleanup at the end of their lexical lifetime.

Dynamic arrays, maps, runtime strings, and other managed containers remember the allocator responsible for their backing storage. Mutable containers and user-defined managed types whose lifecycle clone honors a destination allocator use `mem.default_allocator()` by default, binding it lazily when their allocator-unbound zero state first needs storage, and may select another allocator eagerly with `via`.

Immutable `string` and `shared(T)` are different because assignment may retain an existing shared allocation rather than create destination-owned backing storage. They select an allocator in the operation that creates that allocation: string-producing procedures accept a conventional `allocator` argument when selection is needed, and `shared` has the constructor argument described below. Applying `via` to either type is a compile-time error.

```odin
scratch := mem.Scratch();
bytes: [dynamic]u8 via scratch.allocator() = {};
bytes.reserve(4096);
```

The allocator affects where backing storage comes from, but does not change value semantics or whether cleanup is automatic. Use the `manual` declaration modifier to opt out of automatic cleanup.

All allocations are preferably done through allocators. The following call:

```odin
ptr, err := new(int);
```

is equivalent to this:

```odin
ptr, err := new(int, mem.default_allocator());
```

The allocator is obtained by the ordinary runtime default expression
`allocator := mem.default_allocator()` only when the caller omits the allocator
argument. The final build fixes which provider implements that procedure.

There is no ambient temporary allocator. Temporary storage has a reset boundary
and runtime identity, so code creates a `mem.Scratch` or `mem.Arena` owner and
passes its allocator explicitly. The compiler rejects `free_all`, or any call
carrying the same allocator-reset effect, while a live owning value (managed or
manual) or borrow still refers to storage from that allocator.

### Allocator regions and region provenance

Allocator values have a region identity in addition to their allocation procedures and failure policy. Copying an allocator value preserves that identity, and every allocation records it. This is what lets the compiler recognize that two local allocator values refer to the same region. When compile-time region-identity analysis cannot prove two allocator values distinct, the lifetime check conservatively treats their regions as possibly identical. Across a procedure call the identity is propagated through a parameter marked `@(allocator_reset)`; a Loke procedure that resets an allocator received as a parameter must mark that parameter, and the compiler verifies the promise transitively. The attribute is part of procedure-type compatibility, so indirect calls preserve the same effect.

An owning value also carries compile-time **region provenance**. This provenance
is not part of its source type or ABI, but the region that supplies its backing
storage must outlive the value. An owner backed by a region created in the
current procedure may not be returned, assigned to `static`, `thread_local`, or
file-scope storage, placed in an escaping aggregate or container, or otherwise
retained past that region. Moving the owner does not erase this dependency.

Region provenance is distinct from the root provenance carried by a borrow.
Their complete composition rule is specified under
[How root and region provenance compose](#how-root-and-region-provenance-compose).
This section defines the region half: it constrains owner escape and allocator
reset, but does not itself grant borrow capabilities or decide whether aliases
may overlap.

Procedure checking is conservatively polymorphic over the region provenance of
an owner received through a `move` parameter. A procedure may use that owner
locally or return it, in which case the result keeps the moved value's region
dependency, but it may not retain it in longer-lived storage. Returning an
ordinary borrowed managed parameter instead follows the clone rule under
[Parameter semantics](#parameter-semantics-and-abi-lowering): a mutable clone
receives the region provenance of the allocator used for the result, while a
logical clone that retains shared storage keeps the source allocation's region
provenance. Likewise, an owning result constructed with an allocator parameter
derives its region provenance from that allocator argument at the call site.
These rules require no written lifetime parameter, but diagnostics must identify
the allocator region, the escaping owner, and the shorter-lived region root.

For example, returning `bytes` below is rejected because moving the array into result storage would leave it live while scope cleanup destroys its allocator region:

```odin
bad_buffer :: proc() -> [dynamic]u8 {
	arena := mem.Arena();
	bytes: [dynamic]u8 via arena.allocator() = {};
	bytes.append(1, 2, 3);
	return bytes; // ERROR: `bytes` cannot outlive `arena`
}
```

Resetting a region is intentionally explicit. There is no zero-argument `free_all`; code must name the allocator being reset. A procedure may reset a region it created locally, because no caller-owned value can belong to it. It may not hide a reset of a global or other pre-existing allocator: such an allocator is taken through an `@(allocator_reset)` parameter instead.

```odin
release_scratch :: proc(@(allocator_reset) allocator: Allocator) {
	free_all(allocator);
}

arena := mem.Arena();
scratch: [dynamic]u8 via arena.allocator() = {};
view := scratch[:];
release_scratch(arena.allocator()); // ERROR while `scratch` or `view` is live
```

The following low-level procedures are built in and are also available in package `mem` with enforced allocator errors. Normal managed strings, arrays, and maps do not need them.

- `new(T, allocator=mem.default_allocator()) -> (^T, Allocator_Error)` creates a new allocation root containing a zero-initialized value. On success the pointer has root provenance identifying that fresh allocation, and the allocation root has region provenance identifying its allocator region; the pointer is nil on failure. The allocation is manual: the pointer itself has no `drop` hook and the program must eventually pass the allocation root to `free`, reset its allocator region, or transfer responsibility to an ordinary resource wrapper.

```odin
ptr, err := new(int);
if (err != nil) { panic("integer allocation failed"); }
ptr^ = 123;
x: int = ptr^;
```

- `new_clone(value, allocator=mem.default_allocator()) -> (^T, Allocator_Error)` creates a new allocation root containing a clone of the value. Its pointer and allocation root receive the same respective root and region provenance and manual release rule as `new`; the pointer is nil on failure.

```odin
x: int = 123;
ptr: ^int;
err: Allocator_Error;
ptr, err = new_clone(x);
if (err != nil) { panic("clone allocation failed"); }
assert(ptr^ == 123);
```

- `make(Container, ..., allocator=mem.default_allocator()) -> (Container, Allocator_Error)` is an explicitly fallible constructor for a dynamic array or map with selected backing storage. On failure the container is zero. The result is an ordinary owning value: assigning it to a managed declaration enables automatic cleanup, while assigning it to a `manual` declaration requires an explicit `drop`. Slices are borrows and cannot be owners.

```odin
dynamic_array_zero_length: manual [dynamic]int;
dynamic_array_with_length: manual [dynamic]int;
dynamic_array_with_length_and_capacity: manual [dynamic]int;
made_map: manual map[string]int;
made_map_with_reservation: manual map[string]int;
managed_array: [dynamic]int;
err0, err1, err2, err3, err4, err5: Allocator_Error;

dynamic_array_zero_length, err0 = make([dynamic]int);
dynamic_array_with_length, err1 = make([dynamic]int, 32);
dynamic_array_with_length_and_capacity, err2 = make([dynamic]int, 16, 64);
made_map, err3 = make(map[string]int);
made_map_with_reservation, err4 = make(map[string]int, 64);
managed_array, err5 = make([dynamic]int, 32);
// Each error must be handled or explicitly discarded.
```

- `free` ends the allocation root designated by a checked base pointer from `new` or `new_clone`. It consumes the operand binding and invalidates every locally tracked pointer or view of that allocation. A pointer obtained with `&` is not an allocation root and cannot be passed to `free`. The program must use the allocator that created the allocation; releasing an unchecked or foreign allocation crosses the `core:unsafe` or foreign-allocator boundary.

```odin
ptr, err := new(int);
if (err != nil) { panic("integer allocation failed"); }
free(ptr);
```

- `free_all(@(allocator_reset) allocator: Allocator)` frees every allocation in the allocator's region. Not all allocators support this procedure. The explicit argument and effect annotation make the invalidation visible through wrappers and indirect calls.

```odin
free_all(my_allocator);
```

- `drop` releases either a managed or manual lexical owner, writes its inert zero representation, and marks it dead until full reassignment. Direct `drop` and `move` are forbidden on static-duration storage; use full assignment to clean up and replace its value, or `exchange` to move the old value out while installing a live replacement. Scope exit invokes `drop` automatically only for live managed lexical owners and for managed TLS at normal thread return; reading or explicitly dropping a dead lexical variable is an error.

```odin
drop(manual_dynamic_array);
drop(manual_map);
```

To see more uses of allocators and allocation-related procedures, please see package mem in the core library.

## Allocation failure

Managed values allocate implicitly. A dynamic array grows on `append`, a string is built by concatenation, and an assignment clones its source. None of these have a place to return an error, so an implicit allocation failure never continues as if it had produced a value.

Each allocator carries one of two **failure policies**:

| Policy | Behaviour on failure |
| --- | --- |
| `.Panic` | Raise a runtime panic reporting the requested size and the allocator. The default. |
| `.Trap` | Abort the process immediately without unwinding. For freestanding and embedded targets. |

The policy is part of the allocator value and follows an explicitly supplied
allocator into a subsystem. `.Panic` raises an ordinary [panic](#panics-and-unwinding)
and therefore follows the program's panic strategy, unwinding or not accordingly;
`.Trap` aborts immediately without unwinding whatever that strategy is. In either
case a partially constructed temporary is cleaned up when unwinding permits it, and
an existing assignment destination is not modified before all required allocation
and cloning succeeds.

Code that must recover from allocation failure uses an explicitly fallible form:

```odin
copy, err := source.try_clone();
if (err != nil) {
	return err;
}

err := numbers.try_append(value);
```

The explicitly fallible primitives `make`, `new`, and `new_clone`, and the
`try_` forms of implicitly allocating operations, always return an error and do
not invoke the allocator failure policy. There is no sticky allocation-error
flag or implicit error side channel. Deallocation operations such as `free` and
`drop` return no status. An owner records the allocator needed by `drop`; passing
`free` the wrong allocation or allocator is a programmer error detected by
debugging allocators when available.

For more information regarding memory allocation strategies in general, please see Ginger Bill’s Memory Allocation Strategy series.

Tracking and arena allocators are ordinary `core:mem` implementations. Their setup, diagnostics, and callbacks are library documentation rather than language rules.

# Concurrency and the memory model

Threads, mutexes, channels, and thread pools are library facilities, but reads and writes performed by them obey one language memory model.

Within one thread, evaluations are ordered by the rules under [Evaluation order](#evaluation-order). Evaluation and ownership transfer of a new thread's arguments happen before its first operation. On normal thread return, TLS destruction is sequenced before the thread's final operation; that final operation happens before a successful join returns. A mutex unlock happens before the next successful lock of that mutex. Atomic synchronization is defined below. These edges, together with ordinary sequenced-before order, form the **happens-before** relation.

Two accesses conflict when they touch overlapping bytes and at least one is a write. If conflicting non-atomic accesses from different threads are not ordered by happens-before, the program has a data race and its behavior is undefined. Ordinary variables, pointers, container headers, reference counts, and struct fields are not implicitly atomic. This rule permits conventional optimizing compilers while making synchronization requirements explicit.

The `core:sync` package provides `Atomic(T)` for booleans, integer types, enums with supported integer backing types, and pointers. Its operations are backed by compiler intrinsics and accept `.Relaxed`, `.Acquire`, `.Release`, `.Acquire_Release`, or `.Sequentially_Consistent` ordering where meaningful. `core:sync.fence(order)` provides acquire, release, acquire-release, and sequentially consistent fences; a relaxed fence is invalid because it would have no semantic effect. Unsupported type, operation, or ordering combinations are compile-time errors; the implementation may use a lock when the target lacks a lock-free instruction.

Loke adopts the C++20 atomic ordering model, excluding dependency-ordered `consume`, as the normative model for atomics. The relevant rules are restated here so ordinary code does not need another language specification:

- Every atomic object has one total **modification order** containing all atomic stores and read-modify-write operations to that object. This order is consistent with happens-before.
- An atomic load takes its value from one modification in that object's modification order, subject to the write-read, read-read, read-write, and write-write coherence requirements. A value cannot be manufactured without a contributing write; out-of-thin-air results are forbidden.
- A read-modify-write operation is one indivisible modification and reads the value written by the immediately preceding modification in that object's modification order.
- A release store or release read-modify-write synchronizes with an acquire load or acquire read-modify-write that reads from it or from its release sequence. A release sequence is the maximal contiguous suffix headed by that release and followed by atomic read-modify-write operations on the same object.
- A release fence sequenced before an atomic write synchronizes with an acquire fence sequenced after an atomic read when that read observes the write or its release sequence. This is the fence relation used by the final-reference path of `shared(T)`.
- Relaxed operations participate in atomicity, reads-from, coherence, and modification order but add no synchronizes-with edge. Sequentially consistent operations additionally participate in one total order consistent with happens-before and each affected object's modification order.

These rules intentionally match an established compiler memory model rather than defining a Loke-specific approximation. A compiler may map them to the corresponding LLVM or target atomic operations without strengthening or weakening their observable behavior.

Moving an ordinary owning value to another thread transfers that owner and is allowed when no checked borrow remains in the sending thread. Copying creates the same independent value it would create within one thread, except for types such as immutable `string` and `shared(T)` whose documented clone operation shares thread-safe handle state. The compiler does not prove that a custom `drop`, a foreign resource, or an allocator may run on the receiving thread; transferring an owner asserts that its entire lifecycle is valid there. Raw pointers, stored borrows, foreign handles, and unchecked views may also be transferred, but the compiler does not prove that their pointees remain alive or race-free. There are no implicit `Send` or `Sync` interfaces.

Threads and retained tasks receive only the arguments explicitly moved or copied
into them. A request environment, logger, clock, scratch owner, or other service
handle is transferred like any other value, and transferring a handle does not
make its underlying state thread-safe.

## Shared ownership

`shared(T)` is a library type for shared ownership. It owns one stable, heap-allocated `T` payload and an atomic strong-reference count. Its zero value is `nil`.

`shared(value)` clones the value into a new allocation. `shared(move(value))` moves the value into the allocation. `try_clone` increments the strong count without a new allocation. Thus, `clone` and ordinary assignment share the control block instead of cloning `T`. `move` transfers one handle. `drop` decrements the count with release ordering. At the final reference, it performs an acquire fence and drops the payload one time.

Construction uses `mem.default_allocator()` unless the `allocator` parameter selects another allocator. It follows the failure policy of that allocator. Use `try_shared` to handle a construction error locally. The control block stores the allocator. Therefore, a `shared(T)` declaration cannot use `via`. Use `shared(value, allocator=...)` or `try_shared` to select an allocator.

The atomic reference count makes concurrent handle accounting race-free. It does not make destruction safe on all threads. The thread that releases the final strong handle runs `T.drop` and uses the control-block allocator. Move or copy a handle to another thread only when that thread can run the destructor and allocator. The compiler does not check this requirement. A thread-affine resource must keep its final owning handle on the required thread or use an owner that schedules destruction there.

Atomic handle accounting also does **not** make concurrent access to `T` safe. `handle.get()` returns a non-owning `^T` whose root provenance derives from that handle; callers must use a mutex, atomics within `T`, immutability, or another protocol before conflicting access. The borrow may not outlive the handle used to obtain it, but the compiler does not correlate aliases obtained from different shared handles.

Strong-reference cycles are permitted and leak until explicitly broken. `weak(T)` is the non-owning companion: it keeps the control block but not the payload alive, and `upgrade` returns `(shared(T), bool)`. Libraries that build cyclic graphs should use weak back-edges or explicit teardown.

Immutable `string` implementations that share backing storage use the same atomic handle-accounting principle: their reference-count operations, when present, are atomic, while the bytes themselves never change. The allocator-lifecycle obligation above still applies, and this requirement does not make mutable containers safe for concurrent access.

# Foreign system

The foreign system lets Loke code call foreign code, such as a C library. A foreign import identifies a library or object file for the linker.

## Foreign-ABI-safe types

A procedure using a foreign calling convention, a variable declared in a foreign block, or an exported foreign symbol must have a representation the target ABI can describe. The following types are foreign-ABI-safe:

- fixed-width integers, `int`, `uint`, `uintptr`, `bool`, `rune`, `f32`, and `f64`; their size and alignment follow their Loke definitions and their argument classification follows the target C ABI for a scalar of that representation. `bool` uses C `_Bool`, and `int` and `uint` use the ABI class matching their target-selected width. `f16`, 128-bit integers, and other target extensions are safe only when that target ABI defines their C-compatible classification;
- `rawptr`, `^T`, and `[^]T`, lowered as C pointers; the pointed-to type need not be foreign-ABI-safe because the foreign function receives only an address;
- procedure pointers whose declared calling convention and complete signature match the foreign declaration;
- enums with an explicit foreign-ABI-safe integer backing type;
- plain structs with a trivial lifecycle whose fields are recursively foreign-ABI-safe. Their field order, padding, alignment, and by-value argument classification follow the target C ABI for the equivalent C record. A fixed array is permitted as a record field and has the equivalent C array layout;
- `cstring_view`, lowered to `char const *`. It may be used as a parameter or result and never claims ownership.

**`int` is not C `int`.** Loke's `int` and `uint` are the natural register width, so they are `i64`/`u64` on every 64-bit target while C's `int` stays 32 bits there. They are foreign-ABI-safe in the sense that the ABI can describe them, not in the sense that they match a C declaration spelled `int`. A binding writes the fixed-width type the C header actually resolves to — `i32` for C `int`, `i64` for C `long long`, `int` only where the C side is `ptrdiff_t`, `ssize_t`, or another register-width type. This is the single most common way a hand-written binding goes wrong, and nothing at the boundary can detect it.

Managed containers, `string`, slices, dynamic arrays, maps, tagged unions, `any_view`, `dyn Interface`, and records with custom lifecycle hooks are not foreign-ABI-safe. Interface declarations and compile-time `type` values have no runtime ABI, and a [generic](#generics) procedure or type is likewise not ABI surface — only a concrete instantiation, wrapped in a procedure with a foreign calling convention, can cross the boundary. A fixed array is not permitted as a top-level C parameter because C adjusts such parameters to pointers; write `[^]T` or `^T` explicitly. A packed record is safe only when the bound C declaration uses the same target-specific packing convention; portable bindings should instead copy through an ordinary ABI record.

The base language has no overlapping-record or C-union type. Portable bindings pass a C union as `rawptr` and expose typed wrapper accessors. A binding generator may use a target-specific extension for a union passed by value, but that representation is not portable Loke source.

A default foreign parameter is passed by value. `p: inout T` lowers to `T *`, while `@(by_ptr) p: T` lowers to `T const *`. Foreign parameters cannot use the `move` mode: a C call does not implicitly acquire Loke cleanup responsibility. Exported Loke procedures follow the same restrictions and must declare the foreign calling convention expected by their callers.

These rules define representation, not lifetime. A pointer, `cstring_view`, or `inout` argument is borrowed only for the call as far as the compiler can see. Foreign code that retains it crosses the trust boundary described under [What is not checked](#what-is-not-checked); the programmer must keep the storage alive and synchronize access. Returning a pointer likewise transfers no ownership unless the binding wraps it in an explicitly documented Loke resource type.

This declaration creates the foreign import name `kernel32`. A foreign block uses that name to associate declarations with the library:

```odin
foreign import kernel32 "system:kernel32.lib";
foreign kernel32 {
	ExitProcess :: proc "stdcall" (exit_code: u32) ---;
}
```

The compiler can build and link an imported assembly file. It can use `clang`, `as`, or `nasm`, as applicable to the host. Recognized assembly file extensions are `.asm`, `.s`, and `.S`.

For examples, see `base/runtime/entry_*.asm`.

```odin
foreign import lowlevel "lowlevel.asm";
foreign lowlevel {
    __get_flags :: proc "c" () -> u64 ---;
}
```

```asm
bits 64

global __get_flags

section .text
__get_flags:
	pushfq
	pop rax
	ret
```

A foreign block can also declare an exported global variable:

```odin
foreign lib {
	x: i32;
}
```

Foreign procedure declarations have the `c` calling convention by default unless specified otherwise. Because a foreign procedure has no Loke body, its declaration ends with `---` to distinguish it from a procedure type.

Attributes can change properties of declarations in a foreign block:

```odin
@(default_calling_convention = "stdcall")
foreign kernel32 {
	@(link_name="GetLastError") get_last_error :: proc() -> i32 ---;
}
```

Foreign blocks use these attributes:

- default_calling_convention=<string> - The default calling convention for procedures declared within this foreign block.
- link_name=<string> - Sets the exact foreign symbol name for an individual declaration.
- public - Exports all entities declared within the block. Bindings usually want this, or `@(public)` on the package declaration.
- require_results - All procedures declared within this foreign block must have their return values used.

# Generics

Generics let a procedure or data type bind compile-time type or value parameters and use them throughout its definition.

The `$` prefix always introduces a specialization-time input or pattern name. It
is used by explicit generic parameters, inferred type-shape parameters, and
static `foreach` bindings. It is required at the binding site and is not written
when the bound name is subsequently used. A computed local result uses the
ordinary constant spelling `name :: expression`; `$` is not a second constant
declaration operator.

Generics are compile-time constructs and are **not part of an ABI**. A generic procedure or type has no runtime representation before instantiation. It cannot have `@(export)`, use a foreign [calling convention](#calling-conventions), occur in a `foreign` block, or be stored in a procedure value.

Each concrete instantiation follows the normal ABI rules. To expose generic behavior to foreign code, create an instantiation and wrap it in a concrete [foreign-ABI-safe](#foreign-abi-safe-types) procedure. Code sharing between instantiations is an implementation detail and has no observable ABI effect.

## Explicit generic parameters

An explicit generic parameter is supplied by the caller. A parameter of type `type` receives a type; other parameter types receive compile-time constant values.

### Procedures with explicit generic parameters

Prefix a parameter name with `$` to require a compile-time argument. The following example uses two compile-time parameters to initialize an array of known length:

```odin
make_f32_array :: proc($N: int, $val: f32) -> (res: [N]f32) {
	res = {};
	foreach (_, i in res) {
		res[i] = val*val;
	}
	return;
}

array := make_f32_array(3, 2);
```

Types can also be explicitly passed through a `$` parameter of compile-time-only type `type`:

```odin
my_new :: proc($T: type) -> ^T {
	ptr, err := new(T);
	if (err != nil) { panic("allocation failed"); }
	return ptr;
}

ptr := my_new(int);
```

### Generic data types

Structures and unions declare generic parameters using the same parameter-list shape as procedures. Generic struct:

Arguments whose parameter type is `type` are types; arguments to any other parameter are compile-time constant expressions. Bare names are resolved after parsing, so both `Buffer(Element, Count)` and `Buffer(u8, 4096)` use the same argument syntax. A value argument is not restricted to an identifier.

```odin
Table_Slot :: struct($Key, $Value: type) {
	occupied: bool,
	hash:    u32,
	key:     Key,
	value:   Value,
}
slot: Table_Slot(string, int);
```

Generic union:

```odin
Error :: enum {Foo0, Foo1, Foo2};
Param_Union :: union($T: type) {T, Error};
r: Param_Union(int);
r = 123;
r = Error.Foo0;
```

Record and union generic parameters always require `$`, just like compile-time procedure parameters. This keeps every binding site visually explicit even though all record and union parameters are necessarily compile-time values.

## Inferred generic parameters

An inferred generic parameter is bound from the type or shape of a runtime argument. In this case `$` appears at the binding position inside the parameter type.

### Procedures with inferred generic parameters

```odin
foo :: proc($N: $I, $T: type) -> (res: [N]T) {
	// `N` is the constant value passed
	// `I` is the type of `N`
	// `T` is the type passed
	fmt.printf("Generating an array of type %v from the value %v of type %v\n",
			   typeid_of(type_of(res)), N, typeid_of(I));
	res = {};
	foreach (i in 0..<N) {
		res[i] = i*i;
	}
	return;
}

T :: int;
array := foo(4, T);
foreach (v, i in array) {
	assert(v == T(i*i));
}
```

## Specialization

A generic parameter can require a structural shape. Write the shape in the parameter type and prefix the parts to bind with `$`:

```odin
// Only allow read-only slices, binding their element type.
// A []mut E argument may call this through capability weakening.
first_slice_value :: proc(values: []$E) -> (E, bool) {
	if (len(values) == 0) {
		return {}, false;
	}
	return values[0], true;
}

Table_Slot :: struct($Key, $Value: type) {
	occupied: bool,
	hash:     u32,
	key:      Key,
	value:    Value,
}
Table :: struct($Key, $Value: type) {
	count:     int,
	allocator: mem.Allocator,
	slots:     []mut Table_Slot(Key, Value),
}

// Only allow specializations of `Table`, binding its parameters.
allocate :: proc(table: ^Table($Key, $Value), capacity: int) {
	...
}

find :: proc(table: ^Table($Key, $Value), key: Key) -> (Value, bool) {
	...
}
```

A parameter written this way is more specific than an unconstrained `$T`, which is what tie-breaker 4 of [overload resolution](#operator-lookup-and-overload-resolution) selects on. Specialization is therefore how a procedure group narrows one of its members to a shape.

There is no separate `$T: type/Shape` form binding a name to the *whole* matched type alongside its parts. The shape is already written in the parameter type, so a name for the aggregate would be a second spelling of a constraint the signature has already stated; where the aggregate is needed — as a result type, say — it is written out:

```odin
swapped :: proc(pair: [2]$E) -> [2]E {
	return [2]E{pair[1], pair[0]};
}
```

## where clauses

A bound on generic parameters to a procedure or record can be expressed using a `where` clause immediately before the opening `{`. Every bound is a compile-time boolean expression evaluated while the declaration is instantiated.

The clause is part of the same declaration as the signature it constrains. No semicolon separates them; the declaration is terminated by its body, exactly as it would be without the clause. Multiple bounds are separated by commas and all must hold.

Because the clause is followed immediately by the declaration's `{`, **a bound may not have a composite literal at its top level.** In `where Additive(T) {`, the brace opens the body; it never begins a literal `Additive(T){...}`. A bound that genuinely needs a composite literal parenthesises it, as in `where (Limits{0, N}).valid()`. This is the one place in the language where an expression is followed by a brace without an enclosing pair of parentheses, and it is the reason [control-flow headers](#control-flow-headers) are parenthesized everywhere else.

A bound may reference generic type and value parameters in scope from the declaration or an enclosing generic `impl`, plus constants, types, interface applications, compile-time built-ins, and ordinary procedures that can be evaluated at compile time. It may not depend on a runtime parameter, local variable, mutable global, or call that requires runtime execution. A declaration with no generic parameters in scope therefore cannot have a `where` clause. Runtime preconditions are ordinary `if` and `assert` statements in the procedure body.

Some cases that a where clause may be useful:

- Generic parameter checks for procedures. The bound here is about what `E` *can do*, so it is written as an [interface](#interfaces-and-generic-operators) rather than as a type predicate:

```odin
// A fixed array has no `.x`/`.y` swizzle selectors; index it.
cross_2d :: proc(a, b: [2]$E) -> E
	where interfaces.Numeric(E) {
	return a[0]*b[1] - a[1]*b[0];
}
cross_3d :: proc(a, b: [3]$E) -> [3]E
	where interfaces.Numeric(E) {
	x := a[1]*b[2] - a[2]*b[1];
	y := a[2]*b[0] - a[0]*b[2];
	z := a[0]*b[1] - a[1]*b[0];
	return [3]E{x, y, z};
}

a := [2]int{1, 2};
b := [2]int{5, -3};
fmt.println(cross_2d(a, b));

x := [3]f32{1, 4, 9};
y := [3]f32{-5, 0, 3};
fmt.println(cross_3d(x, y));

// Failure case
// i := [2]bool{true, false}
// j := [2]bool{false, true}
// fmt.println(cross_2d(i, j))
```

- Solving disambiguations with polymorphic procedures in a procedure grouping:

```odin
foo :: proc(x: [$N]int) -> bool
	where N > 2 {
	fmt.println(#location().procedure, "was called with the parameter", x);
	return true;
}

bar :: proc(x: [$N]int) -> bool
	where 0 < N,
	      N <= 2 {
	fmt.println(#location().procedure, "was called with the parameter", x);
	return false;
}

baz :: proc{foo, bar};

x := [3]int{1, 2, 3};
y := [2]int{4, 9};
ok_x := baz(x);
ok_y := baz(y);
assert(ok_x == true);
assert(ok_y == false);
```

- Restrictions on generic parameters for record types. Note the division of labour: `interfaces.Integral(T)` is a capability requirement, while `N > 2` is a predicate over a value and is what a `where` clause is for:

```odin
Foo :: struct($T: type, $N: int)
	where interfaces.Integral(T),
	      N > 2 {
	x: [N]T,
	y: [N-2]T,
}

T :: i32;
N :: 5;
f: Foo(T, N);
#assert(size_of(f) == (N+N-2)*size_of(T));
```

# Attributes

An attribute specifies a property of a declaration, parameter, statement, block, or type literal. Use `@(name)` for an attribute without a value. Use `@(name=value, ...)` for attributes with values. Layout and control-flow attributes use the same syntax.

## Attribute categories

### Foreign blocks

```odin
    @(default_calling_convention=<string>) – foreign blocks
    @(private)– all declarations except import statements
    @(public) – all declarations except import statements
    @(require_results) – procedure declarations and foreign blocks
```

### Procedure groups

```odin
    @(require_results)
```

### Procedure declarations

```odin
    @(deprecated=<string>)
    @(export)
    @(implicit)
    @(link_name=<string>)
    @(require_results)
```

Optimization and code-generation annotations such as `@(compiler.no_alias)` and `@(compiler.must_tail)` are [extension attributes](#extension-attributes), not base-language ones.

### Procedure parameters

```odin
    @(allocator_reset) – `Allocator` parameters whose region may be reset
    @(by_ptr) – foreign declarations only
    @(c_vararg) – final variadic parameter of a foreign declaration
```

### Variable declaration attributes

```odin
    @(export)
    @(link_name=<string>)
    @(private) – globals only
    @(public) – globals only
```

These attributes specify linkage or visibility. They specify the symbol that a declaration produces or the code that can use the declaration. Storage duration and ownership use [storage modifiers](#storage-modifiers), not attributes. A [constant](#constant-declarations) specifies read-only data.

### Constant value declarations

```odin
    @(private)
    @(public)
```

### Type declarations

```odin
    @(private)
    @(public)
```

## Attribute reference

### `@(implicit)`

`@(implicit)` permits an implicit call to a one-argument overload in the target type's `init` group. The argument must be an untyped constant. The parameter type must be a built-in numeric, Boolean, rune, or string type. A runtime value requires the explicit `Target(value)` form. See [Implicit conversion from constants](#implicit-conversion-from-constants).

`@(implicit)` on a procedure that is not a one-argument `init` overload is an error.

### `@(default_calling_convention=<string>)`

This attribute specifies the default calling convention for all procedures in a foreign block:

```odin
@(default_calling_convention = "stdcall")
foreign kernel32 {
	@(link_name="LoadLibraryA") load_library_a  :: proc(c_str: cstring_view) -> Hmodule ---;
}
```

### `@(deprecated=<string>)`

This attribute marks a procedure as deprecated. `loke build`, `loke run`, and `loke check` print the specified message for each use of the procedure.

```odin
@(deprecated="'foo' deprecated, use 'bar' instead")
foo :: proc() {
    ...
}
```

### `@(export)`

This attribute emits a variable or procedure symbol into the object file. A C program or dynamic library can link to that symbol. [`@(public)`](#public) controls access from other Loke packages. These attributes are independent, and a declaration can need both.

`@(export)` takes no argument. There is no enclosing export default. A foreign block or package clause can have `@(public)`, but it cannot have `@(export)`. To export conditionally, put the declaration in a `when` statement.

### `@(link_name=<string>)`

This attribute specifies the symbol name of a variable or procedure. It can occur on an exported declaration or on a declaration in a foreign block:

```odin
foreign foo {
    @(link_name = "bar")
    testbar :: proc(baz: i32) ---;   // C `int`, not Loke `int`
}

@(export, link_name="lib_foo")
foo :: proc "c" () -> int {
	return 42;
}
```

### `@(private)`

Names package visibility, which is already the default. It takes no argument, and there is no file-private visibility to narrow to.

It is load-bearing only in a file whose package declaration carries [`@(public)`](#public), where it excludes one declaration from the file-wide export:

```odin
@(public)
package glfw;

@(private)
scratch_buffer: [64]u8;   // not part of the package API
```

### `@(public)`

This attribute exports a top-level declaration from its package. Without it, only code in the same package can use the declaration.

```odin
@(public)
my_variable: int; // visible to importers of this package
@(public)
my_other_variable: int;
```

Applying `@(public)` to the package declaration makes everything in that file public by default:

```odin
@(public)
package foo;
```

Within a public-default file, `@(private)` narrows an individual declaration back down to package visibility.

### `@(require_results)`

This attribute requires a call to use or explicitly discard all procedure results. Assign results to variables to use them. Assign results to `_` to discard them.

```odin
@(require_results)
foo :: proc() -> bool {
    return true;
}

main :: proc() {
    foo();     // ERROR: the result is not handled
    _ = foo(); // OK: the result is explicitly discarded
}
```

### Storage duration and ownership

`static`, `thread_local`, and `manual` are not attributes but [storage modifiers](#storage-modifiers) written in the declaration; they control where a variable's storage lives, for how long, and who releases it:

```odin
test :: proc() -> int {
    foo: static = 0;
    foo += 1;
    return foo;
}

main :: proc() {
    fmt.println(test()); // prints 1
    fmt.println(test()); // prints 2
    fmt.println(test()); // prints 3
}
```

## Extension attributes

Target integration, linker sections and linkage strength, instrumentation, sanitizers, testing, debugger views, and optimization controls are not part of the base language. Tools may provide namespaced attributes such as `@(compiler.cold)`, `@(compiler.force_inline)`, `@(link.section=".text.hot")`, `@(link.tls_model="initial-exec")`, `@(objc.class="NSView")`, or `@(test.case)`. An unknown namespace is an error unless the corresponding toolchain extension is enabled.

The TLS model of a `thread_local` variable belongs here rather than on the modifier. Which model a target supports, and whether choosing one is even meaningful, is a property of the toolchain and the link; a program that drops the annotation keeps its meaning and may only get slower.

Two annotations that a systems language often makes portable live here instead, because both are instructions to the backend and neither changes what a program means:

- `@(compiler.no_alias)` on a pointer parameter, the equivalent of C's `restrict`. It asserts that the parameter does not alias the others; violating it is undefined behavior, and no Loke rule depends on it.
- `@(compiler.must_tail)` on a call in tail position, requiring the call to be emitted as a tail transfer and failing compilation when the target or the ABI cannot. Guaranteed tail calls are a code-generation contract, and which targets can honour one is a property of the toolchain rather than of the language.

A program that drops both keeps its meaning; it may get slower or overflow a stack it previously did not, which is exactly the boundary this namespace marks.

Portable source must not depend on extension attributes for parsing, type identity, ownership, lifetime, or ordinary control-flow semantics. An extension that changes one of those properties is a language extension rather than a portable attribute.

## Layout and ABI attributes

Layout and ABI annotations use the same `@(...)` syntax as declaration attributes. Loke has no separate category of hash-prefixed directives. Every `#name` form in the language is a compile-time value or compile-time procedure — never an annotation. The complete set is `#assert`, `#config`, `#location`, and `#caller_location`. SIMD uses the ordinary predeclared generic type [`Simd(T, N)`](#simd-vectors).

### Record layout attributes

#### `@(packed)`

This tag can be applied to a struct. Removes padding between fields that’s normally inserted to ensure all fields meet their type’s alignment requirements. Fields remain in source order.

This is useful where the structure is unlikely to be correctly aligned (the insertion rules for padding assume it is), or if the space-savings are more important or useful than the access speed of the fields.

Accessing a field in a packed struct is lowered as an unaligned load or store, or by copying through aligned temporary storage. An individual packed field is not addressable: `&value.field` is rejected even if its numeric offset happens to be aligned, because the base address of a packed value need not satisfy the field type's alignment. Low-level code that needs a pointer-like view uses `intrinsics.unaligned_load`, `intrinsics.unaligned_store`, or a raw byte pointer and accepts responsibility for alignment. Taking the address of the packed struct as a whole remains valid.

struct @(packed) {x: u8, y: i32, z: u16, w: u8}

#### `@(align=N)`

This attribute can be applied to a struct or union. It specifies that the value is aligned to `N` bytes. Fields remain in source order.

```odin
Foo :: struct @(align=4) {
    b: bool,
}
Bar :: union @(align=4) {
    i32,
    u8,
}
```

### Procedure parameter attributes

[`#caller_location`](#caller_location) also appears in a parameter list, but it
is a compile-time value rather than an attribute and is specified with the other
`#name` forms.

#### `@(c_vararg)`

Used to interface with vararg functions in foreign procedures.

```odin
foreign foo {
    bar :: proc(n: int, @(c_vararg) args: ..any_view) ---;
}
```

`any_view` is signature notation here; the compiler passes each original concrete argument using the C default argument promotions rather than passing an `any_view` representation.

#### `@(by_ptr)`

Used only on a foreign declaration to match an ABI that represents a const-reference parameter as a pointer. This is an explicit foreign-ABI adapter, not a performance annotation for ordinary Loke parameters. The parameter is passed according to the foreign ABI while remaining read-only in Loke source.

```odin
foreign foo {
    bar :: proc(@(by_ptr) p: T) ---;
}
```

to represent

void bar(const T*)

#### `@(allocator_reset)`

Marks an `Allocator` parameter whose region may be reset by a successful call. The effect is part of the procedure type. At each call site the compiler substitutes the supplied allocator's region identity and rejects the call while an owning value (managed or manual) or borrow from that region is live.

A Loke procedure is verified: every `free_all` operation on a region that existed before procedure entry, and every call through another reset-capable parameter, must be covered by one of the procedure's own `@(allocator_reset)` parameters. A procedure may freely reset a region it created locally. Foreign procedures carrying the attribute are programmer promises. A pre-existing allocator that may be reset must be passed explicitly; hidden resets through globals are not permitted.

# Compile-time built-ins

## `#assert(<boolean>)`

`#assert` requires its condition and check at compile time regardless of the
surrounding execution phase. It accepts an optional constant message string and
breaks compilation if the condition is false. It has no runtime cost. An
ordinary `assert` instead executes in the phase of the procedure call that
reaches it: runtime normally, or compile time when that call is already being
evaluated to satisfy a compile-time-required context.

```odin
#assert(SOME_CONST_CONDITION);
#assert(N > 0, "N must be positive");
```

## `#config(<identifier>, default)`

Checks if an identifier is defined through the command line, or gives a default value instead.

Values can be set with the -define:NAME=VALUE command line flag.

## `#location() or #location(<entity>)`

Returns a runtime.Source_Code_Location. Can be called with no parameters for current location, or with a parameter for the location of the variable/proc declaration.

```odin
foo :: proc() {};

main :: proc() {
    n: int;
    fmt.println(#location());
    fmt.println(#location(foo));
    fmt.println(#location(n));
}
```

## `#caller_location`

`#caller_location` denotes the source location of the code calling the
procedure, as a `runtime.Source_Code_Location`. It may appear only as the
default value of a procedure parameter, and it is evaluated at each call that
omits that argument, like any other [default](#default-values).

```odin
package example_caller_location;

import "core:fmt";

print_caller_location :: proc(loc := #caller_location) {
	fmt.println(loc);
	fmt.println(#location().procedure, "called by", loc.procedure);
}

main :: proc() {
	print_caller_location();
	// C:/some/dir/example_caller_location.loke(11:2)
	// print_caller_location called by main
}
```

These four — `#assert`, `#config`, `#location`, and `#caller_location` — are the
complete set of `#name` forms in the language. Every one is a compile-time value
or compile-time procedure; none is an annotation.

# Useful idioms

The following are useful idioms which are emergent from the semantics of the language.

## Basic idioms

### Conditional values

A conditional expression reads in evaluation order, value first:

```odin
bar := 1 if condition else 42;
```

The conditional expression also works in constant declarations:

```odin
DEBUG_LOG_SIZE :: 1024 if LOKE_DEBUG else 0;
```

### If-statements with initialization

```odin
if (str, ok := value.(string); ok) {
	...
} else {
   ...
}
```

### Iterating through slices of structs by value or by reference

```odin
Foo :: struct {
	f: f32,
	i: i32,
}

foos: [dynamic]Foo = {};
foos.resize(num);

// By-value foreach loop, with implicit indexing
foreach (v, j in foos) {
	fmt.println(j, v, v.f, v.i);
}

// By-value foreach loop, with explicit indexing
foreach (_, j in foos) {
	foo := foos[j]; // copy
	fmt.println(j, foo, foo.f, foo.i);
}

// By-reference foreach loop with explicit indexing
foreach (_, j in foos) {
	foo := &foos[j]; // pointer; writes through `foo` are visible outside this scope
	fmt.println(j, foo, foo.f, foo.i);
}

// By-reference foreach loop through a pointer
foreach (&v, j in foos) {
	fmt.println(j, v, v.f, v.i);
}
```

### defer if

`defer if` defers the complete `if` statement. The program evaluates the condition when it runs the deferred statement, not when it registers the `defer`.

```odin
cond := false;
defer {
	if (cond) { fmt.println("c"); } // This will print last.
}
defer if (cond) {
	fmt.println("b"); // This will print after "a".
}
defer {
	// This is first evaluated, allowing the prior `defer`s to act, as evaluation
	// happens in reverse declaration order.
	cond = true;
	fmt.println("a"); // This will print first.
}
```

### Optional results

A procedure that can have no value returns `(T, bool)`. This is the [optional-ok form](#optional-ok-results). Map indexing, validating conversions, type assertions, `pop`, and the [iteration protocol](#iteration-protocol) use the same form. The language and core library do not define `Option`, `Maybe`, or `Result` types.

```odin
halve :: proc(n: int) -> (int, bool) {
	if (n % 2 != 0) { return 0, false; }
	return n / 2, true;
}

half, ok := halve(2);
if (ok) { fmt.println(half); }      // 1

_, ok = halve(3);
if (!ok) { fmt.println("3/2 isn't an int"); }

n := halve(4) or_else 0;
fmt.println(n);                     // 2
```

The convention is that the `bool` comes last and is named `ok`, and that the value is the zero value when `ok` is false. An error that carries information returns an error value instead and is propagated with [`or_return`](#or_return-operator); `bool` is for the case where "absent" is the whole story. Nothing prevents a library from declaring `Option :: union($T: type) {T}` for its own use — it is an ordinary union — but the core library does not, and no language construct is aware of it.

## Advanced idioms

### Implicit type conversions

Loke is strongly typed. The following list contains all built-in implicit conversions. The only user-defined implicit conversion applies to an untyped constant. An import cannot add other implicit conversions. Thus, conversion behavior does not depend on the imported packages.

- ^T -> rawptr
- [^]T -> rawptr
- [^]T <-> ^T
- Concrete values to `any_view` when an `any_view` parameter or local destination is expected; the result is a checked non-escaping borrow
- `dyn Derived` -> `dyn Base` when `Derived` composes `Base`; the result keeps the same data borrow and selects the base witness
- Any of its variants to the union
- T -> Simd(T, N)
- distinct proc <-> proc (same base types)
- Untyped integers -> built-in integer types when in range, and built-in floating-point types under the specified rounding rule
- Untyped floats -> built-in floating-point types under the specified rounding rule; never implicitly to integer types
- Untyped booleans -> `bool`
- Untyped rune -> all rune types
- `string` -> `string_view`; a non-owning borrow of the string, subject to [Borrows and lifetimes](#borrows-and-lifetimes)
- Untyped strings -> `string`, `string_view`, or `cstring_view` when the destination supplies the required lifetime
- Untyped constants into a user type through a visible [`@(implicit)`](#implicit-conversion-from-constants) conversion; this is how literals enter library numeric types, and it is the only user-defined implicit conversion

# Library types assumed by this specification

Several types, interfaces, and a few core procedures are used in normative text above but are supplied by the library. They are listed here so that an implementer knows what the core library owes the language. `Atomic(T)`, the built-in implementations of the standard interfaces, and the compile-time `meta` descriptors are backed directly by compiler facilities; the remaining entries use ordinary language facilities.

| Type | Used by | Status |
| --- | --- | --- |
| `os.args`, `os.exit`, `os.open`, `os.close`, `os.Handle` | [program entry and exit](#program-entry-and-exit), the [`defer`](#defer-statement) example | `core:os`. The program model reads command-line arguments from `os.args`. `os.exit` terminates immediately with a specified status. File handles are ordinary library resources with no compiler-known behavior. |
| `String_Builder` | [string type](#string-type) | Built from `[dynamic]u8`. |
| `C_String` | [C string views](#c-string-views) | Owned zero-terminated `[dynamic]u8` buffer for foreign APIs that retain strings. |
| `Small_Array(T, N)` | [fixed-capacity arrays](#fixed-capacity-arrays) | Inline growable container implemented through ordinary methods and operators. |
| `interfaces.Equatable`, `Ordered`, `Hashable`, `Numeric`, `Integral`, `Cloneable`, `Iterator`, `Iterable`, `Sequence`, `Mutable_Sequence`, `Growable_Sequence` | [standard interface catalogue](#standard-interface-catalogue) | Ordinary structural declarations exported by `base:interfaces`; the compiler exposes built-in operations, associated members, and opaque iterators needed to satisfy them. |
| `Little_Endian(T)`, `Big_Endian(T)` | [basic types](#basic-types) | Distinct storage wrappers supplied by binary-format libraries. |
| `meta.Field`, `meta.Enum_Value` | [compile-time reflection](#compile-time-reflection) | Opaque compile-time-only descriptors exported through `base:meta` and constructed only by compiler reflection built-ins. |
| `Allocator_Error`, `Allocator`, `mem.Scratch`, `mem.Arena` | [allocators](#allocators), fallible operations | `core:mem` / `base:runtime`. The final build selects the provider behind `mem.default_allocator()`. |
| `Logger` | [build-selected providers](#build-selected-providers) | Ordinary service handle supplied by `core:log`; the final build selects the backend used by the package-level logging procedures. |
| `Trace_Span`, `Time` | [explicit runtime environments](#explicit-runtime-environments) | Representative runtime handles supplied by tracing and time libraries; they have no compiler-known propagation. |
| `Source_Code_Location` | `#caller_location`, `#location` | `base:runtime`. |
| `Bit_Set(Enum)`, `Enum_Array(Enum, T)` | flag sets and [enum iteration](#iterating-an-enumeration) | Generic library containers. Hardware register layouts use integer masks and explicit accessors in version 1. |
| `Complex(T)`, `Quaternion(T)` | [library numeric types](#library-numeric-types) | Deliberately not primitive. |
| `shared(T)`, `weak(T)` | [shared ownership](#shared-ownership) | Library records with custom lifecycle hooks and an atomic control block. |
| `Atomic(T)` | [concurrency and the memory model](#concurrency-and-the-memory-model) | `core:sync` wrapper over compiler atomic intrinsics. |

The public APIs and layouts of these types belong to their packages; only the behavior required by the linked normative sections is part of the language contract.
