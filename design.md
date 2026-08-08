# file format

Loke source code has to be in UTF-8 without a BOM mark to be considered valid. That is chosen to handle Unicode string literals.

# Code blocks

A code block is surrounded by braces (`{}`) and creates a scope for the variables declared inside it.

## Statements

Statements are terminated by a semicolon (`;`) unless their outermost form ends in a declaration or statement block. `if`, `for`, `foreach`, `switch`, `when`, a bare block, a `defer` of any of them, procedure definitions, record definitions, interface definitions, procedure groups, and brace-bodied operator definitions are therefore terminated by their closing `}`. The same applies to the top-level `impl`, `extend`, and `foreign` blocks. A semicolon is still required after an expression even when that expression happens to end in a composite literal such as `Point{1, 2}`: literal braces are values, not declaration or statement blocks.

A lone `;` is an empty statement and is permitted at file scope too, so a redundant semicolon after a brace-bodied form is accepted as a separate empty statement:

```odin
Foo :: struct {}
Bar :: struct {};   // the trailing `;` is a separate empty declaration
x :: Point{1, 2};   // a composite-literal expression still needs `;`
```

Newlines are never significant: there is no automatic semicolon insertion.

## Control-flow headers

Every control-flow statement — `if`, `for`, `foreach`, `switch`, `when` — puts its header inside parentheses and its body inside braces (`{}`). There are no single-statement body exceptions: if a construct takes a condition, that condition is parenthesised and its body is braced.

```odin
if (x >= 0) { }
for (i := 0; i < 10; i += 1) { }
foreach (value in values) { }
switch (value) { }
when (LOKE_DEBUG) { }
```

# Identifiers

Identifiers are case-sensitive and match `[A-Za-z_][A-Za-z0-9_]*`. The single identifier `_` is the discard identifier and does not introduce a binding. Unicode remains valid in comments and literals, but identifiers containing non-ASCII characters are rejected.

# Variable declarations

A variable declaration declares a new variable for the current scope.

```odin
x: int; // declares `x` to have type `int`
y, z: int; // declares `y` and `z` to have type `int`
```

Variables are initialized to zero by default unless specified otherwise.

Declarations have to be unique within a scope. A local declaration also cannot shadow a local variable in an enclosing scope. The one exception is the explicit parameter-copy idiom described under [Shadowing Parameters](#shadowing-parameters): `x := x` may shadow the immutable parameter `x` with a mutable local copy in the procedure body.

```odin
x := 10;
x := 20; // Redeclaration of `x` in this scope
y, z := 20, 30;
test, z := 20, 30; // not allowed since `z` exists already
```

## Managed values and storage

Owning values such as `string`, `[dynamic]T`, and `map[K]V` behave like ordinary local variables by default. Their small headers are stored inline with the variable, while any variable-sized backing storage may be allocated on the heap. The compiler releases that backing storage automatically when the value leaves scope.

```odin
numbers := [dynamic]int{1, 4, 9};
message := string("hello");

numbers.append(16);
// `numbers` and `message` are released automatically at the end of the scope.
```

This is called **managed lexical storage**. It provides stack-variable behavior without requiring the complete value to fit on the stack. Cleanup occurs on normal scope exit, `return`, `break`, and `continue`.

### Values that outlive every scope

A managed value declared at file scope or with [`static`](#storage-modifiers) is **never dropped automatically.** Its storage lives for the duration of the process and is reclaimed by the operating system at exit.

Such a value is reported as still-reachable by a leak checker. Anything whose release is externally observable — flushing a file, closing a socket, or releasing a lock held in shared memory — must use [`@(fini)`](#fini), an explicit `drop` at the end of `main`, or a scope inside `main` that owns the value. A `static` local behaves identically and is never dropped automatically.

```odin
cache: map[string]int;             // released by the OS at exit, no drop runs

main :: proc() {
	log_file := open_log();        // managed local: dropped at the end of `main`
	run(log_file);
}
```

Automatic cleanup participates in the same ordering as `defer`. Completing initialization of a managed local registers an implicit `defer drop(value)` at that point. User-written defers and implicit cleanups execute together in reverse registration order. A defer that refers to an already initialized managed local therefore runs before that local is dropped. On `return`, result expressions are evaluated and moved into result storage before scope-exit actions begin; defers cannot change the already-prepared result. A managed value is always moved into result storage, never cloned, so returning one costs nothing beyond the move. See [Named results](#named-results) for how this applies to named result variables.

### Storage modifiers

Storage duration and ownership are separate concepts, and a declaration answers them in two independent slots written after its `:`.

**Duration** — where the variable lives and for how long. The three are mutually exclusive, and omitting all of them gives ordinary lexical storage.

- `stack` requires a fixed-size value to live in the current stack frame. This is a guarantee, not a hint: it lets embedded and real-time code state that a declaration must not touch the allocator, and the compiler rejects the declaration if it cannot honour it.
- `static` gives the variable one instance with process lifetime, keeping its value across calls, exactly like a static local in C.
- `thread_local` is `static` with one instance per thread.

**Ownership** — `manual` disables automatic cleanup for an owning value. It is intended for arenas, foreign ownership, custom containers, and low-level allocator code. It combines with any duration.

```odin
small:   stack Matrix4;            // guaranteed no allocation
counter: static int;               // keeps its value across calls
current: thread_local ^Task;       // one per thread
buffer:  manual [dynamic]u8;       // released explicitly
scratch: stack manual [64]u8;      // this frame, cleanup is mine

large: [1_000_000]f64;             // compiler may place this large local on the heap
```

A modifier may also be written where the type is inferred:

```odin
counter: static = 0;
raw: manual := make([dynamic]int);
```

Without `stack`, the compiler chooses placement. It may place a large fixed-size local on the heap when that avoids an impractical stack frame. This choice never changes program meaning, address identity, or lexical cleanup — only whether the program fits. Code that needs an explicitly allocated stable object uses `new`; a second placement-forcing modifier is unnecessary.

File-scope, `static`, and `thread_local` declarations are **constant-initialized**. Their initializer must be a compile-time constant and may not perform a runtime call or allocation; omitting it uses the type's zero value. File-scope and `static` storage is ready before `@(init)` procedures run. Each thread's `thread_local` storage is ready before that thread begins executing Loke code. Runtime initialization belongs in an `@(init)` procedure, an explicit `once` value from `core:sync`, or ordinary caller-owned state. This removes hidden initialization guards, recursion during initialization, and a special concurrency rule from the language.

**These are declaration modifiers, not type constructors.** They do not participate in type identity: `manual [dynamic]int` and `[dynamic]int` are the same type, differing only in who releases the value. Ownership can be transferred between them with `move` without a conversion.

They are also not [attributes](#attributes), even though they attach to the same declarations. An attribute carries information about a declaration for a tool — its symbol name, its visibility, whether it is exported. A storage modifier changes what the program does: how long the variable exists, whether its address is stable, whether cleanup runs at scope exit, and whether a borrow of it may outlive the procedure. That belongs in the declaration, next to the type it qualifies.

`static` and `thread_local` interact with the rest of the language in three ways worth stating:

- Neither registers automatic cleanup, per [Values that outlive every scope](#values-that-outlive-every-scope) above.
- A `static` has a stable address for the whole process, and a `thread_local` instance has one for the lifetime of its thread. Unlike a borrow of an ordinary local, either borrow may be returned to its caller. Sending a `thread_local` borrow to another thread or retaining it after the originating thread exits is outside the local borrow analysis and is invalid.
- A managed file-scope, `static`, or `thread_local` owner initially binds the program's build-selected default allocator. `via` is not permitted on these declarations because their initialization may not evaluate a runtime allocator expression. Code that needs another allocator constructs an owner explicitly during `@(init)` or thread startup and moves it into the persistent variable.

```odin
allocation_error: Allocator_Error;
buffer, allocation_error = make([dynamic]u8, allocator=my_allocator);
if (allocation_error != nil) { panic("buffer allocation failed"); }

// A manual owner must be dropped explicitly.
drop(buffer);
```

`drop(value)` is the one explicit cleanup operation for an owning value. It runs the value's cleanup, resets the variable to its zero value, and marks the variable dead. Scope exit performs the same operation automatically for managed owners and does nothing for manual owners.

Liveness for cleanup is tracked per variable. Where control flow makes it statically undecidable — a `drop` or `move` on only one branch — the compiler inserts a hidden boolean drop flag for that variable and cleanup tests it. Assigning to a dead variable revives it. Cleanup is therefore never driven by comparing a value against its zero state. A `drop` hook is called exactly once per completed initialization, and the type's zero value must be the inert state described under [Zero values](#zero-values).

Built-in owning types receive compiler-defined cleanup. User-defined types receive field-wise `clone`, `move`, and `drop` behavior by default and may replace the generated `clone` or `drop` operation when they manage a custom resource.

Structs and fixed arrays containing managed fields receive compiler-generated copy, move, and cleanup operations recursively. Self-assignment is safe. Cyclic ownership is possible only through explicit pointer or `shared(T)` types, not through ordinary value fields.

Multiple declarations such as `y, z := 20, 30;` remain valid. More general tuple destructuring and pattern matching can be designed separately because they do not affect storage lifetime.

# Assignment statements

The assignment statement assigns a new value to a variable/location:

```odin
x: int = 123; // declares a new variable `x` with type `int` and assigns a value to it
x = 637; // assigns a new value to `x`
```

= is the assignment operator.

You can assign multiple variables with it:

```odin
x, y := 1, "hello"; // declares `x` and `y` and infers the types from the assignments
y, x = "bye", 5;
```

Note: := is two tokens, : and =. The following are all equivalent:

```odin
x: int = 123;
x:     = 123; // default type for an integer literal is `int`
x := 123;
```

Assignment has value semantics. Assigning an owning mutable value creates an independent value; it never creates an undocumented alias to the same allocation.

```odin
a := [dynamic]int{1, 2, 3};
b := a; // deep copy: modifying `b` does not modify `a`
b[0] = 99;
assert(a[0] == 1);
```

`move(value)` explicitly transfers ownership without copying. The moved-from variable is reset to its zero value and may be assigned again.

```odin
c := move(a); // transfers the allocation
assert(len(a) == 0);
```

The compiler may replace a copy with a move when it can prove that the source value is no longer used. This optimization never changes observable behavior. A shallow alias of an owning mutable value is not provided; shared ownership must use an explicit library type such as `shared(T)`.

If a clone cannot allocate, assignment invokes the destination allocator's failure policy described under [Allocation failure](#allocation-failure). The destination keeps its previous value; a failed assignment never leaves a half-copied value.

# Borrows and lifetimes

Loke is not memory safe in the sense that Rust is, and does not try to be. It checks one specific and very common class of error — using a view into a container after that container has been moved, released, or reallocated — and it does so with rules that are entirely local to a single procedure body. Everything outside those rules is the programmer's responsibility, and this section states exactly where the line falls.

## What a borrow is

A **borrow** is a non-owning view of storage that some other value owns. Borrows arise through these language forms and through library view types declared to carry the same provenance:

- a slice expression over an owner: `numbers[:]`, `numbers[1:4]`
- a procedure argument: storage reached through a default parameter is borrowed immutably, while an `inout` parameter borrows the caller's variable mutably
- the address-of operator applied to an owner or one of its elements: `&numbers[0]`
- an iterator obtained from a collection, and the `&value` form of a `foreach` loop
- a user-defined `operator([])` returning `inout T`, or `operator([:])`
- construction of a view such as `string_view` or `any_view` from owned storage

A borrow is not a value you can own. It has no cleanup, it is never dropped, and assigning it copies the view rather than the storage.

Every borrow also has a **capability**. An immutable borrow permits reads only. An exclusive mutable borrow permits reads and writes through that borrow. When the borrow aliases the owner variable itself through `inout`, it may also update the owner's header when storage is reallocated; an interior borrow such as `[]mut T` cannot do that. The capability is part of the static type of a slice (`[]T` versus `[]mut T`) and part of the parameter or result mode for other references (`T` versus `inout T`). A mutable capability may be weakened to an immutable one implicitly; the reverse conversion does not exist.

An owning temporary created while evaluating an expression lives until the end of that complete expression. A borrow derived from the temporary may be used during that expression, including by a called procedure, but it cannot be assigned, returned, stored, or otherwise made live after the expression. The compiler diagnoses such an escape at the call or assignment that would extend the borrow.

## The one rule

> While an immutable or interior borrow of an owner is live, that owner may not be moved, dropped, or **invalidated**. An exclusive mutable borrow of the owner variable created by `inout` may mutate or invalidate the owner through that borrow itself, but the owner cannot be accessed through a competing name until the mutable borrow's last use.

An owner is *invalidated* by any operation that may change where its backing storage lives, how long it is, or which elements it still contains: `append`, `resize`, `reserve`, `shrink`, `clear`, `remove`, map insertion, and any user operation taking `inout self`. Invalidation through the unique `inout` path is allowed because that path updates the caller's owner header; existing element or slice borrows still prevent the call.

Reallocation is the common cause but not the only one. `clear` keeps the same allocation and capacity, and `remove` may too, yet both make the elements a live view describes no longer the elements the owner has. Treating every user `inout` operation as invalidating is conservative, but keeps effects out of procedure annotations and makes the rule visible from the parameter mode alone.

A borrow is **live** from the point it is created to the point of its last use, within the procedure body that created it. This is a use-based extent, not a scope-based one: a borrow that is never used again stops constraining its owner immediately.

```odin
numbers := [dynamic]int{1, 2, 3};

view := numbers[:];
fmt.println(view[0]);   // last use of `view`
numbers.append(4);      // OK: the borrow is no longer live

second := numbers[:];
numbers.append(5);      // ERROR: `numbers` is reallocated while `second` is live
fmt.println(second[0]);
```

The diagnostic for this error must name the borrow, the point it was created, the operation that invalidated it, and the later use that made it live.

## What is checked

Within a single procedure body, all of the following are compile-time errors:

```odin
// 1. Use of a borrow after the owner is reallocated.
view := numbers[:];
numbers.append(4);
fmt.println(view[0]);          // ERROR

// 2. Use of a borrow after the owner is dropped or moved.
view := numbers[:];
drop(numbers);
fmt.println(view[0]);          // ERROR

other := move(numbers);
fmt.println(view[0]);          // ERROR

// 3. Returning a borrow derived from a local owner.
bad :: proc() -> []int {
	local := [dynamic]int{1, 2, 3};
	return local[:];            // ERROR: `local` is released at scope exit
}

// 4. Two live mutable borrows of the same owner, or a mutable borrow
//    overlapping a live immutable one.
view := numbers[:];
sort_in_place(inout numbers);   // ERROR: `numbers` is borrowed by `view`
fmt.println(view[0]);

// 5. Releasing an allocator whose storage is still borrowed.
arena := mem.Arena();
scratch := [dynamic]u8 via arena.allocator();
view := scratch[:];
free_all(arena.allocator());       // ERROR
fmt.println(view[0]);
```

Returning a borrow derived from storage reachable through a **parameter** is allowed, and the result is treated as a borrow of every borrowed argument the procedure received:

```odin
first_half :: proc(values: []int) -> []int {
	return values[:len(values)/2];   // OK
}

numbers := [dynamic]int{1, 2, 3, 4};
view := first_half(numbers[:]);    // OK: `view` borrows `numbers`

bad := first_half([dynamic]int{1, 2, 3, 4}[:]);
// ERROR: the returned borrow would outlive the temporary argument
```

The default parameter binding itself is a callee-local read-only value. Taking `&parameter` borrows that local binding and such a pointer cannot be returned. The rule above concerns storage reached through a borrowed argument, such as the elements described by a slice or dynamic-array header. An `inout` parameter instead aliases the caller's variable, so a borrow explicitly returned from it is attributed to that caller variable.

When a procedure accepts multiple borrowed arguments, a returned borrow is attributed to all of them. At the call site, the result is rejected if any attributed argument is a temporary whose lifetime ends with the call's complete expression.

## What is not checked

These are real holes, they are intentional, and no diagnostic will catch them:

- **Borrows stored in memory.** Putting a slice in a struct field, a global, a container, or a service object escapes the analysis entirely. Once a borrow is stored, its validity is yours to maintain.
- **Borrows across procedure boundaries beyond the coarse rule above.** If a procedure stores a borrowed parameter somewhere that outlives the call, nothing detects it.
- **Anything reached through a raw pointer.** `^T` arithmetic, `[^]T` multi-pointers, `unsafe.raw_data`, and the rest of the `unsafe` package are outside the model by construction.
- **Threads.** Borrow liveness is analysed per procedure body; sending a borrow to another thread is not tracked. Use `shared(T)` or an owned copy.
- **Foreign code.** A borrow passed to a C function may be retained by that function. The `foreign` boundary is a trust boundary.

If you need a view whose lifetime you cannot prove locally, take an owned copy with `clone`, or use `shared(T)`.

Allocator-wide invalidation is the one effect that is propagated across an ordinary procedure boundary. A parameter marked [`@(allocator_reset)`](#allocator_reset) states that a successful call may release every allocation belonging to the allocator region passed for that parameter. The effect is part of the procedure type and is substituted at the call site, so a wrapper around `free_all` cannot hide the invalidation from the caller. This remains a local check: the caller compares the effect with the managed owners and borrows live at that call.

## Debug-mode detection

Because the escape holes above are real, an implementation is encouraged to make them *detectable* rather than silent. When `LOKE_DEBUG` is set, managed containers may carry a generation counter that is bumped on every reallocation, with slices carrying the generation they were created from and trapping on mismatch.

This is an implementation-defined debugging aid, not a language guarantee: it must not change the meaning of a correct program, and release builds are expected to omit it. It exists so that the class of bug the static rules cannot reach still fails loudly in test runs instead of corrupting memory in production.

## The `unsafe` package

Operations that create a borrow the compiler cannot relate to an owner live in the core package `unsafe`. It is an ordinary package with no compiler privileges beyond containing these procedures; importing it is visible in the import list, greppable, and reviewable, which is the entire mechanism.

```odin
import "core:unsafe"

view := unsafe.cstring_view(ptr);   // no owner is known for `ptr`
bytes := unsafe.as_bytes(some_string);
```

Everything in `unsafe` is a promise by the programmer that a lifetime holds which the compiler cannot see. A project that wants to forbid this can lint on the import; the language does not, because foreign interop and allocator implementations need it.

## Relationship to `manual`

A `manual` owner participates in the same borrow, move, reallocation, and liveness checks as a managed owner. The modifier suppresses only automatic cleanup at scope exit; it is not an `unsafe` escape from the borrow rules. A live borrow therefore prevents `drop`, move, and reallocation regardless of whether cleanup is automatic.

`drop` consumes either a managed or manual owner, resets the variable to its zero value, and marks the variable dead until it is assigned again. Dropping a definitely dead variable is a compile-time error. This tracking concerns the owner variable and its checked borrows; aliases manufactured through raw pointers or `core:unsafe` remain the programmer's responsibility.

# Literals

## String and character literals

String literals are enclosed in double quotes and character literals in single quotes. Special characters are escaped with a backslash \.

```odin
"This is a string"
'A'
'\n' // newline character
"C:\\Windows\\notepad.exe"
```

Raw string literals are enclosed in single back ticks.

`C:\Windows\notepad.exe`

The length of a string can be found using the built-in len proc:

```odin
len("Foo");
len(some_string);
```

If the string passed to len is a compile-time constant, the value from len will be a compile-time constant.

### Escape Characters

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

Numerical literals are written similarly to most other programming languages. Underscores are allowed for readability: `1_000_000_000` (one billion). A number containing a decimal point is a floating-point literal: `1.0e9` (one billion).

Binary literals are prefixed with 0b, octal literals with 0o, and hexadecimal literals with 0x. A leading zero does not produce an octal constant (unlike C).

If a number constant can be represented by a type without precision loss, it will automatically convert to that type.

```odin
x: int = 1.0; // A float literal but it can be represented by an integer without precision loss
```

Constant literals are “untyped” which means that they can implicitly convert to a type.

```odin
x: int; // `x` is typed as being of type `int`
x = 1; // `1` is an untyped integer literal which can implicitly convert to `int`
```

# Constant declarations

Constants are entities (symbols) which have an assigned value. The constant’s value cannot be changed. The constant’s value must be able to be evaluated at compile time:

```odin
x :: "what"; // constant `x` has the untyped string value "what"
```

Constants can be explicitly typed like a variable declaration:

```odin
y : int : 123;
z :: y + 7; // constant computations are possible
```

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

This is why the language needs no separate read-only-data declaration. A table you want in the binary's read-only section, indexed at runtime, *is* a constant, and saying so is the whole declaration:

```odin
NAMES :: [?]string{"north", "east", "south", "west"};

heading :: proc(category: int) -> string {
	return NAMES[category];
}
```

Placing a constant in a *particular* linker section is a toolchain concern and uses an [extension attribute](#extension-attributes) such as `@(link.section=".rodata.hot")`.

A constant's value is still required to be computable at compile time, so a constant can never hold a managed owner, a pointer to non-static storage, or anything else whose lifecycle would need to run. Materialization therefore never has to consider cleanup: it emits bytes.

# Comments

Comments can be anywhere outside of a string or character literal. Single line comments begin with //:

```odin
// A comment

my_integer_variable: int; // A comment for documentation
```

Multi-line comments begin with /* and end with */. Multi-line comments can be also be nested (unlike in C):

```odin
/*
	You can have any text or code here and
	have it be commented.
	/*
		NOTE: comments can be nested!
	*/
*/
```

# Packages

Loke programs consist of packages. Loke source files use the `.loke` extension. A package is a directory of source files, all of which have the same package declaration at the top. Execution starts in the package’s main procedure.

## Program entry and exit

An executable is built from a package named `main` containing exactly one procedure named `main`. Its signature is `main :: proc()`: no parameters, no results, the `loke` calling convention. Command-line arguments are read from `os.args`, and the exit status is set with `os.exit(code)` or defaults to 0 when `main` returns normally.

`main` takes no arguments and returns nothing because both would be a second, weaker spelling of something the program already has. An `argv` parameter cannot describe the platform's real argument encoding on every target, and a returned status would compete with `os.exit` while running before `@(fini)` procedures — leaving two exit paths with different cleanup.

The full startup and shutdown order is:

1. Runtime initialization, including the build-selected allocator and logging providers.
2. `@(init)` procedures, in the deterministic order given under [`@(init)`](#init).
3. `main`.
4. `@(fini)` procedures, using the same deterministic ordering relation as `@(init)` but reversed.

`os.exit` runs `@(fini)` procedures and then terminates. Managed values at file scope are [never dropped](#values-that-outlive-every-scope) at any point in this sequence.

## Import statement

The following program imports the fmt and os packages from the core library collection.

```odin
package main;

import "core:fmt";
import "core:os";

main :: proc() {
}
```

The core: prefix is used to state where the import is meant to look; this is called a library collection. If no prefix is present, the import will look relative to the current file.

Note: By convention, the package name is the same as the last element in the import path. "core:fmt" package comprises of files that begin with the statement package fmt. However, this is not enforced by the compiler, which means the default name for the import name will be determined by the last element in the import path if possible.

A different import name can be used over the default package name:

```odin
import "core:fmt";
import foo "core:fmt"; // reference a package by a different name
```

An import name is a lexical alias and nothing more. Two names for the same package refer to the same declarations, and an alias never creates a second instance of a package or of anything it owns.

Every source file must contain its package declaration. Package versions are selected by the build system or package manager and are not part of import syntax.

### Import cycles

Import cycles between packages are rejected. The import graph must be a directed acyclic graph, and the compiler reports the cycle as a path of import statements.

This is largely a consequence of a rule that already exists rather than an independent restriction: [`@(init)`](#init) ordering is defined as a topological sort of the import graph, and a cycle has no such sort. Declarations *within* a package may refer to each other freely and in any order, and a genuine mutual dependency is expressed by merging the packages or extracting the shared declarations into a third package that both import.

## Exported names

All declarations in a package are private to that package by default. A package's API is the set of declarations it marks public, so exporting is always a deliberate act.

The public attribute exports an entity from its package.

```odin
@(public)
my_variable: int; // visible to importers of this package
@(public)
my_other_variable: int;
```

The private attribute narrows visibility below the default, to the file:

```odin
@(private="file")
my_variable: int; // cannot be accessed outside this file
```

`@(private)` and `@(private="package")` name the default explicitly. They are redundant on their own, but they are how a declaration opts out of a file-wide public package attribute.

### Authoring a package

A package is a directory of source files, all of which have the same package declaration at the top, e.g. package main. Each source file must have the same package name. A directory cannot contain more than 1 package.

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

### Basic for loop

A basic for loop has three components separated by semicolons:

- The initial statement: executed before the first iteration
- The condition expression: evaluated before every iteration
- The post statement: executed at the end of every iteration

The loop will stop executing when the condition is evaluated to false.

```odin
for (i := 0; i < 10; i += 1) {
	fmt.println(i);
}
```

The loop header is parenthesised and the body is braced, as for every control-flow statement:

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

where a..=b denotes a closed interval [a,b], i.e. the upper limit is inclusive, and a..<b denotes a half-open interval [a,b), i.e. the upper limit is exclusive.

Certain built-in types can be iterated over:

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

Alternatively a second index value can be added:

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

The iterated values are copies and cannot be written to.

When iterating a string, the characters will be runes rather than bytes. `foreach` assumes the string is encoded as UTF-8.

```odin
str: string = "Some text";
foreach (character in str) {
	assert(type_of(character) == rune);
	fmt.println(character);
}
```

You can iterate mutable arrays and slices by-reference with the address operator. For slices, the expression must have type `[]mut T`; `[]T` supports by-value iteration only:

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

Note: It is not possible to iterate a string in a by-reference manner as strings are immutable.

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

The condition is parenthesised and the body is braced.

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
case .i386, .wasm32, .arm32:
	fmt.println("32 bit");
case .amd64, .wasm64p32, .arm64, .riscv64:
	fmt.println("64 bit");
case .Unknown:
	fmt.println("Unknown architecture");
}
```

Switch is like the one in C or C++, except that only the selected case runs. This means that a break statement is not needed at the end of each case. Another important difference is that the case values need not be integers nor constants.

To achieve a C-like fall through into the next case block, the keyword fallthrough can be used.

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

`switch` always has a subject. Boolean condition chains use `if`, `else if`, and `else`; there is no implicit `switch (true)` form. This keeps every value switch structurally identical and prevents two control-flow constructs from expressing the same condition-chain syntax.

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

Deferred code may not transfer control out of the deferred statement. A `return` or `or_return` anywhere in the deferred statement is an error. A `break`, `continue`, or `fallthrough` is legal only when its target loop or switch is wholly inside the deferred statement; it cannot target a construct surrounding the original `defer`. A deferred statement also may not contain another `defer`. Procedure literals nested in the deferred syntax are checked as independent procedures and are not subject to these restrictions merely because their declarations occur there.

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

You can defer an entire block too:

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
		n = 456; // This won't affect `n`
	}
	n = 123;
	return;
}
```

## when statement

The when statement is almost identical to the if statement but with some differences:

- Each condition must be a constant expression because a `when` statement is evaluated at compile time.
- Statements within a branch do not create a new scope.
- The compiler checks only the branch belonging to the first true condition.
- An initial statement is not allowed in a `when` statement.
- `when` statements are allowed at file scope.

The contents of a `when` branch match its location. Inside a procedure, a selected branch contains ordinary statements. At file scope, it contains top-level items, so it may conditionally provide imports, foreign declarations, `impl` or `extend` blocks, and declarations, but not executable expression statements. In either location the braces used by `when` do not introduce a scope; the selected contents behave as if they had appeared directly at the surrounding location.

Example:

```odin
when (LOKE_ARCH == .i386) {
	fmt.println("32 bit");
} else when (LOKE_ARCH == .amd64) {
	fmt.println("64 bit");
} else {
	fmt.println("Unsupported architecture");
}
```

The when statement is very useful for writing platform specific code. This is akin to the #if construct in C’s preprocessor. However, it is type checked.

See the Conditional compilation section for examples of built-in constants you can use with when statements.

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

There are no statement labels or multi-level breaks. Code that must leave several nested constructs can return from the procedure or move that control flow into a separate procedure.

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

### fallthrough statement

fallthrough can be used to explicitly fall through into the next case block:

```odin
switch (i) {
case 0:
	foo();
	fallthrough;
case 1:
	bar();
}
```

## Procedures

A procedure is something that can do work, which some languages call functions or methods. A procedure literal is defined with the proc keyword:

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

**Procedure literals do not capture.** A procedure literal may refer to constants, types, and file-scope entities, but not to local variables or parameters of an enclosing procedure. There are no closures, and a procedure value is therefore always a single code pointer with no environment. State that a callback needs is passed explicitly, usually as a `rawptr` or typed user-data parameter alongside the procedure value.

This is what keeps [Borrows and lifetimes](#borrows-and-lifetimes) local: without capture, no borrow can escape a procedure body by being closed over.

### Parameters

Procedures can take zero or many parameters. The following example is a basic procedure that multiplies two integers together:

```odin
multiply :: proc(x: int, y: int) -> int {
	return x * y;
}
fmt.println(multiply(137, 432));
```

When two or more consecutive parameters share a type, you can omit the other types from previous names, like with variable declarations. In this example: x: int, y: int can be shortened to x, y: int, for example:

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

A normal `value: T` parameter never becomes an `inout` parameter merely because of its machine-level representation. For a trivial value, it behaves as an immutable callee-local value. For a managed owner—including a struct or fixed array containing managed fields—the parameter is a non-owning immutable borrow for the duration of the call. Passing it does not clone its allocation or transfer ownership, and storage reached through it is protected by [Borrows and lifetimes](#borrows-and-lifetimes).

After applying those rules, the ABI may transport a parameter in registers, in an argument slot, or indirectly through a hidden pointer. Indirect transport normally points to temporary argument storage prepared by the caller:

```text
source:   inspect(value)
lowered:  temporary = argument representation
          inspect_lowered(&temporary)
```

The temporary remains valid until the call completes. It is not source-level pointer syntax, cannot be retained by the callee, and does not grant permission to modify the caller's variable. Taking `&value` inside the procedure behaves as taking the address of a callee-local binding, not the address of the caller's variable. An optimizer may reuse the caller's storage only when it proves that the difference is completely unobservable under these rules.

This lowering is an implementation detail of the `loke` calling convention. A foreign procedure follows its declared foreign ABI instead, including that ABI's rules for passing aggregates.

#### Large-parameter diagnostics

Parameter size is never a type error. A large type also does not by itself require a warning: hidden-pointer lowering may already avoid moving the representation, and replacing a value parameter with a pointer would change its aliasing, lifetime, nil, and mutation semantics.

An implementation should instead provide a configurable performance warning for an expensive copy or `clone` that remains necessary at a call site. The diagnostic should report the operation and approximate cost rather than merely the type's size:

```text
warning: this call copies 8192 bytes into parameter `value`
note: the copy could not be elided
help: use `move(value)` if the callee should take ownership
help: use a slice, view, or typed pointer only if aliasing is intended
```

The threshold is target-specific and is not part of the language semantics. The warning should be more prominent when the copy occurs in a loop or when a non-trivial `clone` may allocate. It must not recommend `inout` solely as an optimization, because `inout` grants mutation rights and changes which aliases are legal.

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

Use `inout` for a mutable borrow and `move` when a procedure must take ownership:

```odin
sort_in_place :: proc(values: inout [dynamic]int) {
	values.sort();
}

store_for_later :: proc(values: move [dynamic]int) {
	stored_values = move(values);
}

sort_in_place(inout numbers);
store_for_later(move(numbers));
```

**Both non-default modes are required at the call site, not just at the declaration.** An argument to an `inout` parameter must be written `inout expr`, and an argument to a `move` parameter must be written `move(expr)`. Omitting the marker is an error naming the parameter and the mode it needs. This is what makes a call readable without consulting the callee's signature: a reader can see at the call which arguments may be modified and which are being given away.

The two are spelled differently because they are different kinds of thing. `move(x)` is an [expression](#assignment-statements) that produces a value and resets `x`, and it is equally usable in an assignment or a `return`. `inout x` is not an expression and produces no value; it selects a parameter mode and may appear only in an argument position, in an [`operator([])` result](#indexing-and-slicing), and where a mutable receiver is passed. Method-call syntax supplies the marker implicitly for its receiver: `numbers.sort()` calls an `inout self` method without the caller writing `inout`, because the receiver's mutability is already visible in the mutating verb. See [Borrows and lifetimes](#borrows-and-lifetimes) for the complete rule and for the cases it deliberately does not cover.

### Shadowing Parameters

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

### Variadic Parameters

Procedures can be variadic, taking a varying number of arguments:

```odin
sum :: proc(nums: ..int) -> (result: int) {
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

A procedure can return any number of results. For example:

```odin
swap :: proc(x, y: int) -> (int, int) {
	return y, x;
}
a, b := swap(1, 2);
fmt.println(a, b); // 2 1
```

### Named results

Return values may be named. If so, they are treated as variables defined at the top of the procedure, like input parameters. A return statement without arguments returns the named return value (or values). “Naked” return statements should only be used in short procedures as it reduces clarity when reading.

A named result is an ordinary local variable, not the caller's result storage. A `return` — bare or not — **moves** the named result variables into result storage, and only then do scope-exit actions run. This is why a `defer` cannot change a named result: by the time it runs, the result has already been moved out and the local is dead. Because the transfer is a move rather than a copy, a managed named result costs nothing extra, and its scope-exit cleanup is suppressed by the same liveness tracking described under [Managed values and storage](#managed-values-and-storage).

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

Assigning default values to named results is also possible:

```odin
conditionally_blue :: proc(red: bool) -> (color := "blue") {
    if (red) {
        return "red";
    }
    return;
}
```

### Named arguments

When calling a procedure, it is not clear in which order parameters might appear. Therefore, the arguments can be named, like a struct literal, to make it clear which argument a parameter is for:

```odin
create_window :: proc(title: string, x, y: int, width, height: int, monitor: ^Monitor) -> (^Window, Window_Error) {...};

window, err := create_window(title="Hellope Title", monitor=nil, width=854, height=480, x=0, y=0);
```

Mixing named and positional arguments is allowed. This is often useful when a procedure has a lot of arguments or you want to customize default values.

Positional arguments are not allowed after named arguments.

```odin
foo :: proc(value: int, name: string, x: bool, y: f32, z := 0) { };
foo(134, "hellope", x=true, y=4.5);
```

### Default values

The create_window procedure may be easier to use if default values are provided, which will be used if they are not specified:

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

The compiler-provided `#caller_location` expression is also valid as a
default and denotes the source location of the call. Named result initializers
use similar syntax, but initialize result variables on procedure entry rather
than supplying omitted arguments; those result variables may subsequently be
assigned by the procedure body.

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

Loke’s basic types are:

bool

`bool` is the ordinary logical type, and the only one. It is one byte, matching C's `_Bool`.

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

A dedicated `b32` would remove the `!= 0` from one family of C booleans while leaving every other family to convert anyway — a type, an ABI class, and an implicit-conversion rule bought for one line per binding, in the one place where a wrapper is already being written.

```odin
// integers
int  i8 i16 i32 i64 i128
uint u8 u16 u32 u64 u128 uintptr

byte // predeclared alias for `u8`, not a distinct type
```

f16 f32 f64 // floating point numbers

Endian-qualified numbers are library types such as `Little_Endian(u32)` and `Big_Endian(f64)`, implemented as distinct storage wrappers with conversions and operators. They are not primitive types. This keeps byte-order policy out of arithmetic promotion and lets protocol libraries define the exact load, store, and formatting behavior they need.

Complex and quaternion numbers are not primitive types. Libraries implement them as ordinary structs with operator overloads, conversions, formatting, and generic algorithms. The base language does not reserve names or provide special promotion rules for them.

```odin
rune // signed 32 bit integer
	 // represents a Unicode code point
	 // is a distinct type to `i32`
     // no attempt is made to handle multi-code-point symbols; that is a deep rabbit hole.

// text
string  // immutable, valid UTF-8

// raw pointer type
rawptr

// runtime type information specific type
typeid
any_view
```

The uintptr type is pointer sized, and the int, uint types are the “natural” register size, which is guaranteed to greater than or equal to the size of a pointer (i.e. size_of(uint) >= size_of(uintptr)). When you need an integer value, you should default to using int unless you have a specific reason to use a sized or unsigned integer type

Note: The exact `string` representation is implementation-defined, but byte length is available in O(1). Foreign calls use `cstring_view` and temporary zero-terminated conversions rather than a second owning string type.

## Zero values

Variables declared without an explicit initial value are given their zero value.

The zero value is:

- `0` for numeric and rune types
- `false` for `bool`
- `""`, the empty string, for `string`
- an empty, immediately usable value with no backing allocation for `[dynamic]T` and `map[K]V`. `len` and `cap` are 0, and appending or inserting is legal without any prior construction
- `nil` for pointer, multi-pointer, `rawptr`, procedure, `typeid`, slice, `string_view`, `cstring_view`, union, `any_view`, `shared(T)`, and `weak(T)` types. A nil slice or view has length 0 and points to no storage; a nil union holds no variant

Aggregate zero values are formed recursively from their fields. A type with a custom `drop` hook has an additional invariant: its zero value must be an inert, valid state on which `drop` performs no external action. This is required because an omitted initializer still completes an initialization and therefore registers cleanup. A resource whose machine representation uses zero for a live handle must carry a separate validity field, translate the handle representation, or disallow direct representation as an owning value.

The expression {} can be used for all types to act as a zero type. This is not recommended as it is not clear and if a type has a specific zero value shown above, please prefer that.

### Type conversion

The expression T(v) converts the value v to the type T.

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

Unlike C, assignments between values of a different type require an explicit conversion.

# transmute procedure

`transmute(T, value)` is a bit cast conversion between two types of the same size. Both the source and destination must have a **trivial lifecycle**: they have no custom `clone` or `drop`, contain no managed owner, and are recursively bitwise-copyable. This prevents a bit cast from duplicating an owning representation or manufacturing a value whose cleanup invariant was never established.

```odin
f := f32(123);
u := transmute(u32, f);
```

It is an ordinary compile-time built-in procedure, not an operator: `transmute` is a predeclared identifier rather than a keyword, its first argument is a type in the same way `size_of(T)` and `new(T)` take one, and it binds like any other call. Nothing about a bit cast needs its own syntax — the earlier `transmute(T)value` spelling bought a reserved word and a unary binding rule for a form that already looked like a call.

This is akin to doing the following pointer cast manipulations:

```odin
f := f32(123);
u := (^u32)(&f)^;
```

However, `transmute` does not require taking the address of the value in question, which may not be possible for many expressions. `transmute` cannot reinterpret a managed or resource-owning value. Low-level code may inspect or manipulate such representations through raw storage in `core:unsafe`, but it is then responsible for establishing exactly one initialized owner; the language provides no safe bit-cast shortcut around lifecycle hooks.

# Untyped types

In the type system, certain expressions will have an “untyped” type. An untyped type can implicitly convert to a “typed” type.

```odin
I :: 42;        // untyped integer, implicitly converts to a built-in numeric type that can represent it
F :: 1.37;      // untyped float, implicitly converts to a built-in numeric type that can represent it
S :: "Hellope"; // untyped string, implicitly converts to string
B :: true;      // untyped boolean, implicitly converts to bool
```

(The more formal name for these “untyped” types is existential or abstract types.)

### Built-in constants, values, and procedures

There are a few built-in constants and values which have different uses:

```text
false // untyped boolean constant equivalent to the expression 0!=0
true  // untyped boolean constant equivalent to the expression 0==0
nil   // untyped nil value used for certain values
---   // marker used to explicitly leave a typed variable uninitialized
```

`---` is useful when measured low-level code wants to omit initialization that it will immediately overwrite. It is an initializer marker rather than a general expression, so the variable's type must be written explicitly:

```odin
x: int; // initialized with its zero value
y: int = ---; // uses uninitialized memory
```

This is an explicit unsafe optimization, not the default behaviour. It is permitted only for types with a trivial lifecycle. Evaluating a value, field, or element whose bytes have not been initialized since the declaration is undefined behaviour. Taking its address or selecting a place in order to write it is allowed; every part later read must first have been written. The compiler may assume that no uninitialized value is ever read.

Types containing managed owners or custom `clone` or `drop` hooks cannot use `---`, because merely leaving their ownership representation uninitialized would make scope-exit cleanup invalid. Ordinary declarations remain zero-initialized.

Note: --- is not a contract in that all memory is uninitialized, but that it may be. For example, as a side-effect of an implementation detail, padding in a struct must be zeroed to permit trivial bitwise memory comparison.

# Built-in procedures

There are two kinds of built-in procedures:

- Compiler defined
- Core library defined

For the full list, see the documentation for package `builtin`. The compiler-defined ones used by normative text in this document are:

| Procedure | Result |
| --- | --- |
| `len(value)`, `cap(value)` | Element or byte count, and capacity. Constant when the operand is constant |
| `size_of(T)`, `align_of(T)` | Size and alignment in bytes; compile-time constants. Accept a type or an expression |
| `offset_of(T, field)` | Byte offset of a field; a compile-time constant |
| `type_of(expr)` | The static type of an expression, usable where a type is expected |
| `typeid_of(T)` | The [`typeid`](#typeid-type) for a type |
| `type_info_of(id)` | `^runtime.Type_Info` for a `typeid` |
| `assert(condition, message := "")` | Runtime check; panics when false. Removed by `-no-assert` |
| `panic(message)` | Raises a runtime panic at the call site |
| `new`, `new_clone`, `make`, `free`, `free_all`, `drop` | [Allocation and release](#allocators) |
| `transmute(T, value)` | Bit cast between two same-sized types with a [trivial lifecycle](#transmute-procedure) |
| `move(value)` | Keyword form, not a call; see [assignment](#assignment-statements) |

`assert` and `panic` are runtime operations. [`#assert`](#assertboolean) is the compile-time check; `#assert(false, message)` is the compile-time unconditional-failure form. A compile-time check that silently degraded to a runtime one would be a defect, so the `#` spelling remains distinct.

# string type

`string` is an immutable, owning UTF-8 value. It behaves like a simple local variable: it can be assigned, returned, and stored without requiring explicit construction, cleanup, or `defer`.

```odin
first := "hello";
second := first; // cheap value copy; immutable backing storage may be shared
message := first + " world";
```

A string literal uses static storage. A string created at runtime owns a managed backing buffer. Implementations may use reference counting, small-string optimization, interning, or another representation, but these choices do not change language semantics. Because strings are immutable, sharing their backing storage is never observable as mutable aliasing.

If an implementation shares backing storage between string values, copying and
dropping those values must be safe across threads. A reference-counted
representation must therefore use an atomic count. Code that does not want
shared ownership can pass `[]u8` or `string_view`, neither of which is an owner.

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
builder: String_Builder;
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

**Pointers carry no such capability: there is no `^const T`.** The asymmetry is deliberate, and it is worth stating what it costs. Read-only access to a *sequence* is spelled `[]T`. Read-only access to a *single value* is spelled by an ordinary `value: T` parameter, which is already an immutable borrow for a managed owner and never copies its allocation; `inout T` is what opts into mutation. Between them these cover every case where the compiler could have checked the promise anyway, because both are procedure-local and the [borrow rules](#borrows-and-lifetimes) apply to them in full.

What remains uncovered is a `^T` stored in a struct field or passed through `rawptr`, and there a read-only qualifier would have been decoration rather than a check: borrows stored in memory are outside the analysis by construction, so `^const T` would document an intention the compiler could not enforce and would then have to be propagated through every signature that touches one. A pointer in Loke means an address whose validity and access discipline the programmer is asserting. Code that wants a checked read-only view of one element passes `[]T` of length one or restructures to take the value.

## From string to X

| To | Action | Code |
| --- | --- | --- |
| `[]u8` | borrow | `st.bytes()` |
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
+       sum                        integers, enums, floats, constant strings
-       subtraction                integers, enums, floats
*       multiplication             integers, floats
/       division                   integers, floats
%       modulo (truncated)         integers

|       bitwise or                 integers, enums
~       bitwise xor                integers, enums
&       bitwise and                integers, enums
&~      bitwise and-not            integers, enums
<<      left shift                 integer << integer >= 0
>>      right shift                integer >> integer >= 0
```

Except for shift operations, if one operand is an untyped constant and the other operand is not, the constant is implicitly converted to the type of the other operand (if possible).

The right operand in a shift expression must have an unsigned integer type or be an untyped constant representable by a typed unsigned integer. If the left operand of a non-constant shift expression is an untyped constant, it is first implicitly converted to the type it would assume if the shift expression were replaced solely by the left operand alone (with type inference and hinting rules applied).

## Comparison operators

```text
==      equal
!=      not equal
<       less
<=      less or equal
>       greater
>=      greater or equal
&&      short-circuiting logical and
||      short-circuiting logical or
```

In any comparison, the first operand must be assignable to the type of the second, or vice versa.

The equality operators == and != apply to operands that are comparable. The ordering operators <, <=, >, and >= apply to operands that are ordered. These terms and the result of the comparisons are defined as follows:

- `bool` values are comparable.
- Integers values are comparable and ordered.
- Floating-point values are comparable and ordered, defined by the IEEE-754 standard.
- Rune values are comparable and ordered.
- String values are comparable and ordered, lexically byte-wise.
- Pointer and multi-pointer values are comparable. Equality compares addresses. Ordering compares the addresses as unsigned `uintptr` values, producing a total order within one execution even for pointers to unrelated allocations. Address-space randomization means that this order need not be reproducible between executions. On a target where a pointer cannot be represented losslessly by `uintptr`, ordering pointers is not supported and use of `<`, `<=`, `>`, or `>=` on them is a compile-time error.
- Enum values are comparable and ordered.
- Struct values are comparable if all their fields are comparable or a visible comparison overload is provided.
- Union values are comparable if all their variants are comparable or a visible comparison overload is provided.
- Array values are comparable if values of the element type are comparable.
- typeid is comparable.
- `Simd(T, N)` vectors are comparable.

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
%=       modulo (truncated) and assign    a %= b is a = a % b

|=       bitwise or and assign            a |= b is a = a | b
~=       bitwise xor and assign           a ~= b is a = a ~ b
&=       bitwise and and assign           a &= b is a = a & b
&~=      bitwise and-not and assign       a &~= b is a = a &~ b
<<=      left shift and assign            a <<= b is a = a << b
>>=      right shift and assign           a >>= b is a = a >> b
```

## Address operator

For an operand x of type T, the address operation &x generates a pointer of ^T to x. The operand must be addressable, meaning that either a variable, pointer indirection, or mutable-slice/dynamic-array indexing operator; or a visible [`operator([])` returning `inout T`](#indexing-and-slicing); or a field selector of an addressable non-packed struct operand; or an array index operation of an addressable array; or a type assertion of an addressable union; or a compound literal value. An `any_view`, an element reached through `[]T`, and an individual field of an `@(packed)` struct are not addressable.

There is exactly one operand form for which `&` is not single-valued. `&m[key]` on a built-in map has [optional-ok semantics](#optional-ok-results), producing `(^T, bool)`, because the key may be absent and `&` never inserts. This is a property of built-in map indexing, not a general rule about `&`; every other addressable operand yields one pointer.

For an operand x of pointer type ^T, the pointer indirection x^ denotes the variable of type T pointed to by x. Explicit `x^` and implicit dereferences such as `x.field` test for nil and raise a runtime panic before accessing memory. This is a language guarantee; an implementation may use a hardware fault only when it preserves the same observable panic behaviour. Dereferencing a non-nil address that is dangling, misaligned, or otherwise invalid is undefined behaviour. Such an address can arise only through an unchecked lifetime hole, raw-pointer manipulation, or foreign code.

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

- A call evaluates its receiver, if any, and then its supplied arguments from left to right. It then evaluates omitted default arguments once, in parameter order. Each default uses the lexical scope of its procedure declaration.
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
     6           +   -   |   ~    in
     5           ==  !=  <   >    <=  >=
     4           &&
     3           ||
     2           ..=    ..<
     1           or_else     if
```

Binary operators of the same precedence associate from left to right. For instance x / y * z is the same as (x / y) * z.

**Level 1 is the exception: it associates from right to left.** This is what makes both of its forms chain the way they read:

```odin
a if c1 else b if c2 else d   // a if c1 else (b if c2 else d)
x or_else y or_else z         // x or_else (y or_else z)
```

The conditional groups as an else-if chain rather than inside out. `or_else` needs the same grouping to type-check at all: its left operand must be an [optional-ok expression](#optional-ok-results) and its result is an ordinary value, so under left association the outer `or_else` would receive an already-resolved value on its left and no chain of fallbacks could be written.

The postfix forms — call `()`, index `[]`, slice `[:]`, selector `.`, dereference `^`, type assertion `.(T)`, and `or_return` — are not in the table because they bind tighter than every unary and binary operator. They associate left to right among themselves. `-x^` is `-(x^)`, `f() or_return + 1` is `(f() or_return) + 1`, and `a.b().(T) or_else c` is `(a.b().(T)) or_else c`. `or_return` is postfix rather than binary because it takes no right operand; [Other operators](#other-operators) lists it alongside the binary forms only for discoverability.

## Integer operators

For two integers values x and y, the integer quotient q = x/y and remainder r = x%y satisfies the following relationships:

```odin
x = q*y + r   and |r| < |y|;
```

with x/y truncated towards zero (truncated division).

Floored remainder is the library procedure `floor_mod(x, y)`. It is useful but uncommon, and does not require a second remainder operator, precedence entry, overload family, and compound-assignment form.

The exception to these rules is when the dividend x is the most negative value for the integer type of x, and the quotient q = x/-1 is equal to x (and r = 0) due to two’s complement integer overflow.

If the divisor is a constant, it must not be zero. If the divisor is zero at runtime, a runtime panic occurs.

The shift operators shift the left operand by the shift count specified by the right operand, which must be non-negative. The shift operators implement arithmetic shifts if the left operand is a signed integer and logical shifts if the left operand is an unsigned integer. There is not an upper limit on the shift count. Shifts behave as if the left operand is shifted n times by 1 for a shift count of n. Therefore, x<<1 is the same as x*2 and x>>1 is the same as x/2 but truncated towards negative infinity.

A shift count at or beyond the width of the left operand is therefore not undefined; it is simply the limit of that repeated single-bit shift:

- `x << y` is `0` once `y >= 8*size_of(x)`, for both signed and unsigned `x`.
- `x >> y` is `0` once `y >= 8*size_of(x)` for unsigned `x` or non-negative signed `x`, and `-1` for negative signed `x`, because an arithmetic shift replicates the sign bit.

```odin
u: u32 = 1;
i: i32 = -1;
assert(u >> 32 == 0);
assert(i >> 32 == -1); // arithmetic shift saturates at the sign bit
assert(i << 32 == 0);
```

This differs from C, where such a shift count is undefined behaviour. Defining it costs a masked or saturating shift sequence on targets whose instruction does something else, and buys a rule that does not silently change meaning under optimization.

### Integer overflow

For unsigned integers, the operations +, -, *, and << are computed modulo 2n, where n is the bit width of the unsigned integer’s type. In a sense, these unsigned integer operations discard the high bits upon overflow, and programs may rely on “wrap around”.

For signed integers, the operations +, -, *, /, and << may legally overflow and the resulting value exists and is deterministically defined by the signed integer representation. Overflow does not cause a runtime panic. A compiler may not optimize code under the assumption that overflow does not occur. For instance, x < x+1 may not be assumed to be always true.

This costs real optimization, and on the most common type. Undefined signed overflow is what lets a C compiler widen a 32-bit induction variable to a 64-bit register without a check, prove a loop terminates, and strength-reduce the resulting address arithmetic. Defining overflow gives that up on exactly the loops a systems language cares about — and `int` is the recommended default type, so it gives it up by default. The trade is the same one made for [shift counts](#integer-operators): a rule that does not change meaning under optimization is worth more than the code it costs, because the alternative is a program whose correctness depends on a flag. Code in a measured hot loop that wants the wider assumption states it — by using an explicitly sized unsigned type, hoisting the bound, or narrowing the index range — rather than inheriting it silently from every arithmetic expression in the program.

## Floating-point operators

For floating-point types:

- +x is the same as x
- -x is the negation of x

Floating-point division by zero follows IEEE-754 and does not panic: a non-zero dividend produces `+Inf` or `-Inf` according to the signs of the operands, and `0.0/0.0` produces a NaN. Integer division by zero panics. Default floating-point exception handling is non-stop; a program that wants trapping behaviour installs it through the target's floating-point environment.

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

Code that wants method syntax for a foreign extension declares a small local forwarding extension. This is an explicit opt-in at the point where the additional behavior becomes part of lookup, and ordinary ambiguity diagnostics apply within that package. No orphan or global coherence rule is needed.

Field lookup takes priority over method-call sugar. Inherent and extension methods otherwise use normal overload resolution. Methods can be collected into explicit procedure groups just like free procedures.

### Receiver forms

`self` may be written in four ways, and no other form of receiver exists:

| Receiver | Meaning |
| --- | --- |
| `self` | Immutable borrow of the value |
| `self: inout Type` | Exclusive mutable borrow of the caller's variable |
| `self: move Type` | Consumes the receiver |
| `self: ^Type` | Ordinary pointer parameter, with no method-call sugar |

The first three are reached through `value.method()`, and the call site supplies the `inout` or `move` marker implicitly, as described under [Parameter semantics](#parameter-semantics-and-abi-lowering). A `^Type` receiver is not a receiver mode at all — it is a normal first parameter that happens to be named `self`, so it must be called as `Type.method(pointer)` and exists only for code that genuinely manipulates an address, such as an intrusive data structure. Mutating methods use `inout self`; pointer receivers are not the way to spell mutation.

### Generic types

An `impl` or `extend` block may name a generic type by writing its shape, binding the parameters with `$` exactly as a [specialized](#specialization) procedure parameter does. The bound names are in scope throughout the block:

```odin
Table :: struct($Key, $Value: typeid) {
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

table: Table(string, int);
table.insert("a", 1);
value, ok := table.find("a");
```

Where the receiver's type is written out rather than inferred — `inout` and `move` receivers, and every non-receiver mention — the bound names are used without `$`, because `$` marks a binding site and these are uses.

A block may also be written for one specialization, `impl Table(string, int) { ... }`, in which case its methods apply only to that instantiation. When both are visible, the more specialized block wins by tie-breaker 4 of [overload resolution](#operator-lookup-and-overload-resolution). Constraints use a `where` clause on the individual procedure, not on the block.

This is what lets a generic container satisfy an [interface](#interfaces-and-generic-operators): requirements such as `(v: T) v.clone() -> T` are written in method syntax, so a generic type with no way to declare methods could never satisfy one.

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
2. Built-in lossless conversion.
3. A user [`@(implicit)`](#implicit-conversion-from-constants) conversion. Reachable only for an argument that is an untyped constant, so it applies to at most one step and cannot chain.

Rank 3 sits below rank 2 so that a constant always prefers a built-in destination: given `foo :: proc{foo_f64, foo_complex}`, the call `foo(2.0)` selects `foo_f64` at rank 2 rather than converting into `Complex_F64` at rank 3.

The ranks form a vector; they are not added and argument order does not break ties. Candidate A is better than candidate B when A is no worse for every argument and strictly better for at least one. Crossed vectors such as `(0, 2)` and `(2, 0)` are intentionally ambiguous.

When conversion vectors are identical, the following tie-breakers apply in order:

1. A fixed-arity candidate beats a variadic candidate.
2. A candidate requiring fewer omitted default arguments wins.
3. A non-parametric candidate beats a parametric candidate.
4. Between parametric candidates, a structural specialization beats an unspecialized parameter. Otherwise candidate A is more specific than B when A's normalized constraint set syntactically entails B's and the reverse does not hold. If neither direction holds, the call is ambiguous.

Constraint entailment uses a portable syntactic algorithm. Constraints are normalized as an unordered conjunction. Interface composition is expanded transitively, redundant identical atoms are removed, and bound names are alpha-renamed. After that normalization, A entails B only when every atom in B occurs identically in A. Algebraic implications such as `N > 3` implying `N > 2`, or two differently written expressions computing the same boolean, are not used for overload selection. Implementations may diagnose or optimize with stronger reasoning, but stronger reasoning must not change which programs compile or which overload is selected.

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

Place position selects *which operation runs*. It does not by itself decide whether a missing element is **created**, which is a property of the container: a dynamic array never creates one and traps on an out-of-range index, while a built-in map inserts a zero element for an absent key. `&` is a place position for the purpose of overload selection but never creates an element in any container; see [Maps](#maps) for the built-in case and the `&m[key]` form it uses instead.

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

grid: Sparse_Grid;
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

Iteration uses ordinary methods rather than a special privileged container representation. A value is iterable when `iter(value)` returns an iterator with a compatible `next` method. The built-in containers, ranges, and [enum types](#iterating-an-enumeration) are lowered directly by the compiler and do not participate in the protocol. `next` has [optional-ok semantics](#optional-ok-results): it returns `(T, bool)`, and a false `bool` ends the loop with the first result unobserved.

```odin
Countdown :: struct {
	start: int,
}

Countdown_Iterator :: struct {
	current: int,
}

impl Countdown {
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

By-reference `foreach` is a built-in-container facility in version 1. Mutable fixed arrays, mutable slices, dynamic arrays, and map values support `foreach (&value in collection)` directly. The user iteration protocol has only value-producing `next`; there is no `next_ref` protocol method or general storable `inout` local.

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

The parameter type must be a built-in numeric, boolean, rune, or string type, so that there is an untyped constant kind that can reach it. The constant converts to that parameter type by the ordinary [untyped-constant rule](#untyped-types), which already rejects anything not representable without precision loss, and the procedure is then called normally.

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

- **Nothing is hidden at runtime.** Every conversion of a runtime value is written in the source, so a reader never has to know which conversions are in scope to see where a value changes type.
- **Chains cannot form.** An untyped constant is not a user type, so a constant can take at most one user conversion and there is no need for a rule capping conversion depth or an argument that lookup terminates.
- **Narrowing is already handled.** Precision loss is caught by the constant-representability rule at compile time, so the language does not need to permit lossy implicit conversions and then advise implementations to warn about them.

### Resolving `T(...)`

The form `T(...)` has two possible meanings — a built-in conversion or an `init` overload — so the language fixes one resolution order:

1. **Built-in conversion.** If `T` is a built-in or `distinct` type and exactly one argument is given whose type has a built-in conversion to `T`, that conversion is used. This case is decided first and cannot be overridden, for the same reason built-in operators cannot be shadowed: `int(x)` must not change meaning based on imports.
2. **`init` overloads.** Otherwise, visible `init` overloads for `T` are considered using ordinary overload resolution, including the zero-argument and multi-argument forms.

Resolution stops at the first stage that produces a match. Within a stage, equal-ranked matches are ambiguous rather than being selected by declaration order, and the diagnostic must list the candidates from that stage only.

A consequence worth stating plainly: a single-argument `init` on a `distinct` type over a built-in cannot be reached through `T(x)` when `x` is of the underlying type, because stage 1 claims it. Call it by name, or give it a distinguishing parameter. This is the cost of keeping casts unambiguous, and it is the intended trade. `@(implicit)` only grants an additional constant-only path to an `init` overload; it does not affect explicit `T(x)` resolution.

## Lifecycle hooks and resource types

User-defined records receive field-wise `clone`, `move`, and `drop` behavior by default. An `impl` block may replace `clone` or `drop` for a type that owns a resource.

```odin
File :: struct {
	handle: os.Handle,
	valid:  bool,
}

impl File {
	clone :: ---; // no clone operation exists for this type

	drop :: proc(self: inout File) {
		if (self.valid) {
			os.close(self.handle);
			self.valid = false;
		}
	}
}
```

`Name :: ---;` disables a compiler-generated operation, making `File` move-only. No signature is written, because the signature of a lifecycle hook is fixed by the type. The spelling reuses the existing [uninitialized-storage marker](#built-in-constants-values-and-procedures) as a declaration marker. `move(value)` remains a compiler primitive: it transfers the representation and resets the source to its zero state. `drop(value)` invokes the user hook when present and then resets the value. Fields are dropped in reverse declaration order after the containing type's drop hook returns.

A `drop` hook is called **exactly once per completed initialization**. Whether a variable still owns its value is tracked by the compiler, with a hidden drop flag where control flow requires one, as described under [Managed values and storage](#managed-values-and-storage) — it is never inferred by comparing the value against its zero state. The hook must nevertheless accept the type's inert zero value, because default initialization is a completed initialization. In the `File` example, `valid` distinguishes a default value from an acquired POSIX file descriptor whose numeric handle may legitimately be zero. The hidden drop flag separately prevents a value that has already been moved or dropped from being cleaned up again.

Copy assignment of a copyable user type behaves conceptually as follows, with self-assignment handled by the compiler:

```odin
temporary := source.clone();
drop(destination);
destination = move(temporary);
```

An explicit `try_clone` may return an allocation error. Ordinary assignment uses `clone` and follows the destination's bound allocator policy described under [Allocation failure](#allocation-failure).

## Interfaces and generic operators

An `interface` names a set of compile-time structural requirements. A type satisfies an interface implicitly when every requirement in its body holds; no separate `implements` declaration is required. Interfaces constrain generic code and do not hold runtime values.

```odin
Additive :: interface($T: typeid) {
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

An interface body is a semicolon-terminated list of requirements. A requirement may be preceded by a **binding list**, which introduces names standing for values of the given types:

```
Requirement = Bindings? Expression "->" Type ";"               // expression form
            | Bindings? Expression ";"                         // validity form
            | "const" Identifier "." Identifier ":" Type ";" // associated constant form

Bindings    = "(" Binding_Group ("," Binding_Group)* ")"
Binding_Group = Identifier ("," Identifier)* ":" Type
```

A requirement that begins with `(` is always a binding list. A requirement whose own expression must start with a parenthesis needs a second pair.

Inside a requirement, a type name always means the type. Values come only from the binding list. This is the whole disambiguation rule: `T` never silently switches between meaning the type and meaning a value of it, so `T(0)` is unambiguously construction while `(a, b: T) a + b` is unambiguously addition of two values.

**Expression form** — `expr -> Type;` requires that `expr` compiles for the interface's parameters and bindings, and that its result is convertible to `Type`.

**Validity form** — `expr;` requires only that the expression compiles, with no constraint on its result type.

**Associated constant form** — `const Owner.NAME: Type;` requires `NAME` to be a constant of the given type in `Owner`'s `impl` block. `Owner` must name one of the interface's type parameters. Naming the owner keeps interfaces with several type parameters unambiguous.

Method and operator requirements are written as ordinary calls on bound values. Lifecycle requirements name the hook:

```odin
Container :: interface($T: typeid, $Element: typeid) {
	(c: T)          len(c) -> int;
	(c: T, i: int)  c[i] -> Element;
	(c: T)          iter(c);
	const T.ZERO: Element;
}

Cloneable :: interface($T: typeid) {
	(v: T) v.clone() -> T;
}
```

Interfaces compose by naming one another, and an interface application used in `where` is a compile-time boolean:

```odin
Ordered :: interface($T: typeid) {
	Equatable(T);
	(a, b: T) a < b -> bool;
}
```

A bound name is a value of that type for checking purposes only; the compiler never constructs one, so an interface may name a type that has no reachable constructor.

Requirement checking is non-recursive at the point of use: the compiler checks that each listed requirement holds for the concrete arguments, and does not attempt to prove requirements about types that do not yet exist. An interface application such as `Ordered(T)` is a compile-time predicate. Interfaces do not denote runtime types in version 1 and cannot be used as variable, field, parameter, or result types.

A failed requirement must be reported as the specific line of the interface body that did not hold, together with the concrete type that failed it. An interface diagnostic that reports only "constraint not satisfied" is a defect in the implementation.

Standard library interfaces should remain small and composable, for example `Equatable`, `Ordered`, `Hashable`, `Iterable(T)`, `Cloneable`, `Formattable`, `Numeric`, and `Integral`. The last two replace what other languages express with type-predicate intrinsics: `Numeric(T)` requires `T(0)`, `T(1)`, the four arithmetic operators, and `Ordered(T)`, and is satisfied by the built-in numeric types and by any user type that supplies the same operations. Maps require compatible `==` and `hash` operations for their key type. The compiler checks that both operations exist but trusts the programmer to preserve the semantic rule that equal values produce equal hashes.

### Choosing between interfaces, `where`, and specialization

Three mechanisms can constrain a generic parameter, and they overlap. The intended division of labour:

- **`interface`** — requirements about what a type *can do*: operators, methods, lifecycle hooks, and associated constants.
- **[`where` clauses](#where-clauses)** — predicates over *values*, such as `N > 2` or `len(x) > 1`. A `where` clause of the form `where intrinsics.type_is_numeric(E)` is better written as an interface, and the standard library should not add new type-predicate intrinsics for constraints an interface can express.
- **[Specialization](#specialization)** — structural shape, written directly in the parameter type as in `values: []$E` or `table: ^Table($Key, $Value)`, where the point is to *destructure* the type and bind its parts rather than to test it.

All three remain in the language: they answer different questions, and collapsing them would cost more in expressiveness than the overlap costs in learning. But a constraint that could be written any of the three ways should be written as an interface, because only an interface produces the per-requirement diagnostic described above.

## Runtime polymorphism

Interfaces constrain static generic code only. There are no interface values,
trait objects, or implicit dynamic dispatch. Closed heterogeneous sets use
unions; open runtime behavior uses ordinary procedure tables, `any_view` plus
explicit type checks, or a library-defined record of callbacks.

## Standard customization procedures

Not every customization needs punctuation. The standard library recognizes ordinary overloadable procedures for common behavior:

| Procedure | Purpose |
| --- | --- |
| `len(value)` | Number of logical elements or bytes, as defined by the type |
| `cap(value)` | Current capacity when meaningful |
| `hash(value, seed)` | Hashing for maps and sets |
| `format(value, writer, options)` | Formatting and printing |
| `compare(left, right)` | Three-way ordering when useful |
| `iter(value)` | Forward iteration |
| `iter_reverse(value)` | Reverse iteration |
| `clone(value, allocator := mem.default_allocator())` | Explicit independent copy |

These procedures use normal overload groups. Each is written as a free call — `len(x)`, `hash(key, seed)`, `clone(value)` — and that spelling is canonical and always available.

**Method syntax is not a second spelling for every procedure.** `x.f()` resolves only to a procedure declared with a `self` receiver in an `impl` or `extend` block for `x`'s type, or to a built-in container operation such as `append`, `remove`, `reserve`, or `sort`. There is no uniform-call rule that rewrites `f(x)` as `x.f()`, so an ordinary free procedure never gains a method spelling by accident, and a reader who sees `x.f()` knows a declaration for `f` exists that named `x`'s type.

A type may of course declare one of the procedures above as a method, and many should:

```odin
impl Ring_Buffer {
	len :: proc(self) -> int { return self.count; }
}

buffer: Ring_Buffer;
n := len(buffer);        // always valid: the overload group
m := buffer.len();       // also valid: `Ring_Buffer` declared it with `self`
```

The asymmetry with the built-in containers — `len(x)` but `x.append(v)` — is deliberate. `len` and `cap` are queries that generic code calls on a type parameter, where a free call keeps the interface requirement (`(c: T) len(c) -> int`) readable and uniform across built-in and user types. The mutators are operations on a specific receiver and read better in the position that names it. Libraries are free to define additional protocols without compiler support.

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

You can alias a named type with another name:

```odin
My_Int :: int;
#assert(My_Int == int);
```

## Distinct types

A distinct type allows for the creation of a new type with the same underlying semantics.

```odin
My_Int :: distinct int;
#assert(My_Int != int);
```

A distinct type may define its own methods, operators, constructors, conversions, interfaces, formatting, and lifecycle hooks. It does not inherit the underlying type's user-defined overloads unless they are explicitly re-exported or delegated.

Aggregate types (struct, enum, union) will always be distinct even when named.

```odin
Foo :: struct {};
#assert(Foo != struct{});
```

## Fixed arrays

An array is a simplified fixed length container. Each element in an array has the same type. An array’s index can be any integer, character, or enumeration type.

An array can be constructed like the following:

```odin
x := [5]int{1, 2, 3, 4, 5};
foreach (i in 0..=4) {
	fmt.println(x[i]);
}
```

Fixed arrays are equivalent to a struct with a field for each element. They are just a number of values in a row in memory.

The notation x[i] is used to access the i-th element of x; and 0-index based (like C).

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

Construct an array with designated initializers:

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

The built-in len proc returns the array’s length.

```odin
x: [5]int;
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

Slices look similar to arrays; their length is not known at compile time. The type `[]T` is a read-only slice of `T`, while `[]mut T` is a slice whose elements may be modified. Both are non-owning views with the same runtime representation. Mutability is a static capability and has no ABI cost.

A mutable slice implicitly weakens to a read-only slice. A read-only slice never converts to a mutable slice, including when its original owner happens to be mutable. Slicing a mutable, addressable array or dynamic array produces `[]mut T`; slicing an immutable parameter, a string, or an existing `[]T` produces `[]T`.

A slice is formed by specifying two indices, a low and high bound, separated by a colon:

a[low : high]

This selects a half-open range which includes the lower element, but excludes the higher element.

```odin
fibonaccis := [6]int{0, 1, 1, 2, 3, 5};
s: []int = fibonaccis[1:4]; // creates a slice which includes elements 1 through 3
fmt.println(s); // 1, 1, 2
```

Slices do not store any data; they describe a section of data owned by something else. Internally, a slice stores a pointer to the data and an integer length.

**A slice is a borrow.** It is not an owning value: it has no allocator, it is never cleaned up at scope exit, and it cannot be a `manual` owner. Creating a slice over a dynamic array therefore constrains that container for as long as the slice is live, and the rules in [Borrows and lifetimes](#borrows-and-lifetimes) apply in full:

```odin
numbers := [dynamic]int{1, 2, 3};
view: []int = numbers[:]; // mutable capability is weakened to read-only
numbers.append(4);   // ERROR: `numbers` may reallocate while `view` is live
fmt.println(view[0]);
```

A slice over a fixed array is a borrow of that array's storage, and so is bound by the array's scope in the same way. A slice over a string literal borrows static storage and is therefore valid for the whole program.

To keep the data past the owner's lifetime, take an owned copy: `slice.clone(view)` produces a `[dynamic]T` you own.

The built-in len proc returns the slice’s length. Assignment to an element and by-reference iteration require `[]mut T`:

```odin
x: []mut int = ...;
x[0] = 10;
foreach (&value in x) {
	value += 1;
}
length_of_x := len(x);
```

### Slice literals

A slice literal is like an array literal without the length. This is an array literal:

[3]int{1, 6, 3}

This is a slice literal which creates the same array as above, and then creates a read-only slice that references it:

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
a: [6]int;
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
s: []int;
if (s == nil) {
	fmt.println("s is nil!");
}
```

### Sort slices

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

Dynamic arrays are mutable owning values whose lengths may change at runtime. The array header behaves like a local value, while its backing storage is managed automatically and may grow on the heap.

```odin
x: [dynamic]int;
x.append(10); // the zero value is immediately usable
```

Along with `len`, dynamic arrays provide `cap` to report their current underlying capacity. Assignment creates an independent array, while `move` transfers its backing allocation:

```odin
x := [dynamic]int{1, 2, 3};
y := x;       // deep copy
z := move(x); // allocation transfer; x becomes empty
```

The allocator used by a managed dynamic array is stored with its allocation so automatic cleanup always uses the correct allocator. A declaration may select another allocator without becoming manual, using the `via` modifier. `via` is a declaration modifier and not a form of `using`; it selects storage, it does not bring names into scope.

**`via` appears on declarations only.** A procedure that needs an allocator takes an ordinary parameter for it, conventionally named `allocator` and defaulted to `mem.default_allocator()`, and callers supply it like any other argument. The two are not competing spellings of one feature: `via` answers a question a call cannot, namely which allocator an owner is bound to for its whole lifetime including the cleanup that runs after the declaring statement is long past, while a parameter is an ordinary value that the [runtime default](#default-values) rules already handle.

```odin
temporary: [dynamic]u8 via scratch_allocator;
```

**A managed owner binds its allocator at its declaration, not at its first allocation.** A zero-valued container has no backing storage yet, but it already records which allocator it will use, taken from `via` if present and from `mem.default_allocator()` otherwise. This is what makes a zero value "immediately usable" mean something definite: the first `append` far from the declaration allocates from the allocator the declaration chose.

```odin
numbers: [dynamic]int;                            // binds the program default here
scratch: [dynamic]int via arena.allocator();      // binds this arena here

fill(inout numbers);                              // continues using the bound default
fill(inout scratch);                              // continues using the bound arena
```

Copy initialization likewise uses the allocator active at the declaration. Assignment into an existing array preserves the destination's allocator policy. `move` transfers both the allocation and its allocator. `clone(value, allocator)` is available when a specific allocator is required.

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
x: [dynamic]int;
x.append(123);
x.append(4, 1, 74, 3); // append multiple values at once

y: [dynamic]int;
y.append(..x[:]); // append a slice
```

Ordinary mutating operations use the allocator's configured failure policy, which normally reports an out-of-memory panic. Fallible variants such as `try_append` and `try_reserve` return `Allocator_Error` for code that needs to recover.

The `try_` prefix is a library-wide convention with one meaning: *report the failure this operation would otherwise panic on, and leave the value unchanged.* What it reports depends on what can fail. An operation that can fail only by allocating returns `Allocator_Error`; an operation on a container that never allocates, such as [`Small_Array(T, N)`](#fixed-capacity-arrays), has no allocator error to report and returns `bool`. The prefix names the contract, not the result type.

### Inject / Assign to a dynamic array

`insert` adds an element and shifts later elements upwards. Its index must be in `0..=len(x)`.

**Ordinary indexed assignment never changes the length.** `x[i] = v` for `i >= len(x)` is an out-of-range index and traps like any other, so a misspelled or off-by-one index cannot silently resize an array into zero-filled padding that no later read can distinguish from real data. Assigning past the end is written as the two operations it is:

```odin
x: [dynamic]int;
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

`resize` already grows and zero-fills, and `append` already extends by one, so a dedicated grow-and-assign operation would be a third spelling of a composition of those two — carrying its own name, `try_` variant, and bounds contract to save one line in code that is rare by design.

### Removing from a dynamic array

Removing from a dynamic array can be done in several ways using the built-in procedures:

- `pop` removes and returns the last element with [optional-ok semantics](#optional-ok-results), as `(T, bool)`; on an empty array the value is zero and `ok` is false.
- `remove_unordered` removes and returns an element in O(1) by moving the last element into its location.
- `remove` removes and returns an element while preserving order.

```odin
x: [dynamic]int;
x.append(1, 2, 3, 4, 5); // [1, 2, 3, 4, 5]
x.pop(); // [1, 2, 3, 4]
x.remove(0); // [2, 3, 4]
x.remove_unordered(0); // [4, 3]
```

Other variants can be found in the built-in procedures documentation.

### Slice & Sort a dynamic array

Although dynamic arrays and slices are different concepts, dynamic arrays can be ‘sliced’ and sorted as follows:

```odin
s: [dynamic]int;
s.append(1, 6, 3, 5, 7, 3, 0); // [1, 6, 3, 5, 7, 3, 0]
s.sort(); // [0, 1, 3, 3, 5, 6, 7]
```

### Creating and releasing slices and dynamic arrays

Managed dynamic arrays need no explicit construction or deletion. Their zero value is usable, literals create managed values, and capacity can be reserved separately:

```odin
a: [dynamic]int;        // len(a) == 0, cap(a) == 0
b := [dynamic]int{1, 2, 3};
c: [dynamic]int;
c.resize(6);            // len(c) == 6; new elements are zero
c.reserve(32);          // capacity is at least 32

// with an explicit allocator:
scratch := mem.Scratch();
temporary: [dynamic]int via scratch.allocator();
temporary.reserve(64);
```

`drop` releases an owner and resets it to its zero value. Normal managed code can simply let scope cleanup perform the same operation.

```odin
drop(b);
assert(len(b) == 0);
```

Low-level code may opt out of scope-exit cleanup with `manual` and use the explicitly fallible `make` constructor. `make` returns an ordinary owning value; the destination declaration determines whether cleanup is automatic. Moving an existing manual owner into a managed variable still requires `move`, for the same reason every ownership transfer does:

```odin
raw: manual [dynamic]int;
allocation_error: Allocator_Error;
raw, allocation_error = make([dynamic]int, 0, 64, my_allocator);
if (allocation_error != nil) { panic("array allocation failed"); }
owned := move(raw); // `owned` is managed; `raw` becomes empty and needs no `drop`

managed, managed_error := make([dynamic]int, 0, 64, my_allocator);
// `managed` is cleaned up automatically because its declaration is not manual.
```

### Clearing a dynamic array

Instead of deleting the array you often want to simply clear the dynamic array. This will set the length len() to be 0, while the capacity cap remains the same.

```odin
x: [dynamic]int;
x.append(1, 2, 3, 4, 5); // [1, 2, 3, 4, 5]
fmt.println(len(x)); // 5
x.clear(); // []
fmt.println(len(x)); // 0
```

### Resize / Reserve with a dynamic array

Often enough we also want to resize or reserve a specific amount for a dynamic array. It’s important to understand the difference between the two operations.

- resize will try to resize memory of a passed dynamic array to the requested element count (setting the len, and possibly cap).
- reserve will try to reserve memory of a passed dynamic array to the requested element count (setting the cap).
- shrink will shrink the capacity of a dynamic array down to the current length, or the given capacity.

```odin
x: [dynamic]int;
fmt.println(len(x), cap(x)); // 0 0
x.append(1, 2, 3); // [1, 2, 3]
fmt.println(len(x), cap(x)); // 3 8
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
x: Small_Array(int, 8);
x.append(1, 2, 3);
fmt.println(len(x), cap(x)); // 3 8
```

## Enumerations

Enumeration types define a new type whose values consist of the ones specified. The values are ordered, for example:

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
Foo :: enum u8 {A, B, C}; // Foo will only be 8 bits
```

### Implicit Selector Expression

An implicit selector expression is an abbreviated way to access a member of an enumeration, in a context where type inference can determine the implied type. It has the following form:

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

### Iterating an Enumeration

An enum *type* can be iterated directly, yielding its declared members in declaration order. This supports tasks such as printing every member or populating a library-defined `Enum_Array(Enum, T)`.

This is a compiler special case, not an instance of the [iteration protocol](#iteration-protocol). The protocol is defined over values via `iter(value)`, and a type is not a value: there is no `impl` on a `typeid` in which an `iter` overload for `Direction` could be declared. The compiler recognizes an enum type in the iterable position of a `foreach` header and lowers it directly. It is the only type accepted there; `foreach (x in int)` and `foreach (x in Some_Struct)` are errors.

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

Loke has pointers. A pointer is a memory address of a value. The type ^T is a pointer to a T value. Its zero value is nil.

```odin
p: ^int;
```

The & operator takes the address of its operand (if possible):

```odin
i := 123;
p := &i;
```

The ^ operator dereferences the pointer’s underlying value:

```odin
fmt.println(p^); // read `i` through the pointer `p`
p^ = 1337;       // write `i` through the pointer `p`
```

Note: C programmers may be used to using * to denote pointers. The ^ syntax is borrowed from Pascal. This is to keep the convention of the type on the left and its usage on the right:

```odin
p: ^int; // ^ on the left
x := p^; // ^ on the right
```

Pointer arithmetic is not an operator. `core:mem.ptr_offset` and
`core:mem.ptr_sub` provide explicit address calculations.

## Structs

A struct is a record type. It is a collection of fields. Struct fields are accessed by using a dot:

```odin
Vector2 :: struct {
	x: f32,
	y: f32,
}
v := Vector2{1, 2};
v.x = 4;
fmt.println(v.x);
```

Struct fields can be accessed through a struct pointer:

```odin
v := Vector2{1, 2};
p := &v;
p.x = 1335;
fmt.println(v);
```

For a pointer to a struct, `p.field` is equivalent to `p^.field`.

### Struct literals

A struct literal can be denoted by providing the struct’s type followed by {}. A struct literal must either provide all the arguments or none:

```odin
Vector3 :: struct {
	x, y, z: f32,
}
v: Vector3;
v = Vector3{}; // Zero value
v = Vector3{1, 4, 9};
```

You can list just a subset of the fields if you specify the field by name (the order of the named fields does not matter):

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

Struct fields can be tagged with a string literal to attach meta-information which can be used with runtime-type information. Usually this is used to provide transactional information info on how a struct field is encoded to or decoded from another format, but you can store whatever you want within the string literal

```odin
User :: struct {
	flag: bool, // untagged field
	age:  int    "custom whatever information",
	name: string `json:"username" xml:"user-name" fmt:"q"`, // `core:reflect` layout
}
```

Within Loke’s core library, the standard convention is to use a key that denotes the consuming package followed by a value. For example, `json` tags are processed by `core:encoding/json`, while `fmt` tags are processed by `core:fmt`.

If multiple pieces of information are to be passed in the "value", usually they are specified by separating them with a comma (`,`), e.g.

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

// type assert but with an explicit boolean check. This will not panic
s2, ok := v.(string);
```

A type assertion is single-valued where the asserted type is the only expected result, and it panics if the union does not currently hold that variant. In a comma-ok destination or as the left operand of `or_else` it instead has [optional-ok semantics](#optional-ok-results), producing `(T, bool)` and never panicking.

The asserted type is always written. There is no form that infers it from context: a union has several variants by construction, so the type is the part of the expression carrying the information, and eliding it would save a few characters at the cost of making the reader resolve an inference to know what the code does.

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

Any type can be a map key when it provides compatible `==` and `hash(value, seed)` overloads. Built-in key types provide these automatically; user-defined key types satisfy the same structural `Equatable` and `Hashable` interfaces.

```odin
m: map[string]int;
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

If an element of a key does not exist, the zero value of the element will be returned. Checking to see if an element exists can be done in two ways:

```odin
elem, ok := m[key]; // `ok` is true if the element for that key exists
```

or

```odin
ok := key in m; // `ok` is true if the element for that key exists
```

The first approach is called the “comma ok idiom”.

You can also initialize maps with map literals:

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

- **`m[key]` as an assignment target inserts.** If the key is absent, the zero value of the element type is inserted first and the resulting slot is the location. This is the same behaviour `m[key] = elem` already has, extended to field and index chains so that the two do not disagree. It applies to the target of an assignment or compound assignment and to an argument passed as `inout`. Insertion may reallocate the map, so the index is a mutable borrow of `m` for the duration of the statement.

  This is the opposite of the choice made for [dynamic arrays](#inject--assign-to-a-dynamic-array), where `x[i] = v` past the end traps instead of growing. The two containers differ in what a wrong subscript costs. A dynamic-array index is positional and dense: a misspelled or off-by-one index is a plausible mistake, and silently growing turns it into zero-filled padding that no later read can distinguish from real data. A map key is the caller's own value in the caller's own key space, `m[key] = elem` is already defined as insert-or-update, and a map has no notion of a gap to fill. Refusing to insert for `m[key].field = v` alone would make the field chain disagree with the plain assignment directly above it without preventing any mistake.
- **`&m[key]` never inserts.** `&` is a [place position](#indexing-and-slicing) for selecting the mutable indexing operation, but it is not one of the creating forms above: taking the address of an entry is a lookup, and a lookup that silently grew the map would make `&m[key]` unusable for asking whether a key is present. It therefore has optional-ok semantics, yielding a pointer to the existing slot and a `bool`:

```odin
value, ok := &m["Bob"];
if (ok) {
	value^ = { 2, 2 };
}
```

### Map Container Calls

The built-in map also supports all the standard container calls that can be found with the dynamic array.

Short:

- len(some_map) returns the amount of slots used up
- cap(some_map) returns the capacity of the map - the map will reallocate when exceeded
- some_map.clear() removes all entries while retaining capacity
- some_map.reserve(capacity) reserves the requested element count
- some_map.shrink() reduces excess capacity

## Procedure type

A procedure type is internally a pointer to a procedure in memory. nil is the zero value a procedure type.

Examples:

```odin
proc(x: int) -> bool
proc(c: proc(x: int) -> bool) -> (i32, f32);
```

Or you can assign them to a variable:

```odin
Callback :: proc() -> int;
a: Callback; // nil 
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

Compiler- or target-specific conventions use namespaced extension strings rather than portable aliases. The portable set is deliberately limited to conventions with a stable cross-toolchain meaning.

The default calling convention is `loke`, unless a declaration is within a foreign block, where it is `c`.

A procedure type with a different calling convention can be declared like the following:

proc "c" (n: i32, data: rawptr)

Procedure types are compatible only when calling convention, parameter and result types, parameter modes, variadic shape, and type-level parameter effects match. In particular, `@(allocator_reset)` is part of the parameter's procedure type: a reset-capable procedure cannot be stored in a procedure value whose type hides that effect. Declaration-only attributes such as visibility and deprecation do not participate in type compatibility.

## typeid type

A typeid is a unique identifier for a type. This construct is used by `any_view` to denote the underlying data's type.

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

## any_view type

`any_view` is a non-owning type-erased value, used for formatting, logging, reflection, and other call-oriented APIs. Internally it is a pointer plus a `typeid`, and creating one borrows its source. Its zero value is nil.

It may be a local variable or parameter, but it cannot be a result type, global, struct or union field, container element, or captured/stored value. The ordinary local borrow checker ensures a local `any_view` does not outlive or overlap an invalidating operation on its source. A temporary converted for a call remains valid through that complete call expression.

**A variadic `..any_view` parameter is the one exception to the container rule.** This is what `fmt.println(a, b, c)` and every other formatting API is built on: the caller's arguments are converted to `any_view` and passed as a `[]any_view` whose backing storage the caller materializes for the duration of the call.

```odin
println :: proc(args: ..any_view) { ... }
```

The exception is narrow and does not reintroduce escape. The slice and its elements are borrows of the caller's argument temporaries, live for exactly that complete call expression; the callee may read, index, iterate, and forward the slice to another `..any_view` parameter, but it may not store the slice or any element of it anywhere that outlives the call. A `[]any_view` cannot be produced any other way — there is no `any_view` array, dynamic array, or slice-of-`any_view` local — so this is a calling form rather than a general container type. The [`@(c_vararg)`](#c_vararg) attribute is a separate thing: there the notation is signature-only and the compiler passes the original concrete arguments under the C default argument promotions.

Conversion from a concrete value to `any_view` is implicit when an `any_view` parameter or local destination is expected, and it never allocates. It supports runtime type assertions and type switches.

```odin
print_value :: proc(value: any_view) { ... }
print_value(42); // the temporary lives through the call
```

There is no owning counterpart. Type erasure is call-scoped: a procedure may
inspect an erased value but cannot retain one.

Code that needs to retain a value of one of several types uses a union. Code that needs open runtime behaviour uses a procedure table or a library-defined record of callbacks. Code that needs to retain something genuinely arbitrary owns it concretely and passes an `any_view` at the point of use.

## Multi Pointers

Multi-pointers are a way to describe foreign (C-like) pointers which act like arrays (pointers that map to multiple items). The type [^]T is a multi-pointer to T value(s). Its zero value is nil.

```odin
p: [^]int;
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
a: [^]int;
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

An **optional-ok expression** is a built-in producer with that logical result shape or a procedure call whose final result is `bool`. A comma-ok destination receives every result. `or_else` consumes the final `bool` and either yields the preceding results or evaluates its fallback. The term describes this shared status protocol; it does not invent a universal plain single-value behavior. For example, a missing map lookup yields zero in its documented single-value form, while a failed single-value union assertion panics.

## or_else expression

`or_else` is an infix binary operator that supplies fallback values for an [optional-ok expression](#optional-ok-results).

```odin
m: map[string]int;
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
v: union{int, f64};
i: int;
i = v.(int) or_else 123;
assert(i == 123);
```

`or_else` works with any optional-ok expression, so it applies equally to a map index, a validating conversion, a type assertion, and a procedure returning `(T, bool)`:

```odin
n := numbers.pop() or_else 0;
text := string(bytes) or_else "";
```

## or_return operator

`or_return` is an error-propagation operator for an expression whose final result is a status value. The operand is evaluated exactly once. The status is successful when it is `true` for `bool`, or `nil` for a nil-comparable type; no other truthiness rules apply.

On success, `or_return` removes the final status and yields the preceding result values. A single-valued operand therefore yields no value and may only be used as a statement. On failure, control returns from the innermost enclosing procedure:

- If the procedure has one result, the failed status must be assignable to it and is returned directly.
- If the procedure has multiple results, every result must be named. The failed status must be assignable to the final result; it is assigned there and a bare `return` is performed. Earlier named results retain their current values.

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
	// It is more common that your procedure returns multiple values
	// If `or_return` is used within a procedure that returns multiple 
	// values (2+), then all the returned values must be named 
	// so that a bare `return` statement can be used

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
    x := caller_4() or_return;

    if (x < 5) {
        ok = true;
    }

    return;
}
```

# Conditional compilation

Conditional source selection uses `when`. Selecting files, generating source, discovering tests, and applying project-wide lint or feature policy are build-system responsibilities rather than additional language mechanisms. The reference commands are `loke build`, `loke run`, `loke check`, and `loke test`.

## when statements

Sometimes you only want to compile a block of code if a certain compile-time expression evaluates to true. This can be done using the when statements:

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

Sometimes you want to do something conditionally based on some compile-time parameters of some sort, but globally, across the entire project. This is how you define those.

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
logger may own buffers or synchronization. The provider must arrange any required
initialization before `@(init)` procedures run and remains available until all
`@(fini)` procedures finish.

`mem.default_allocator()` returns the allocator handle supplied by the selected
allocator provider. It is an ordinary runtime call or load, not a compile-time
allocator value. A managed owner without `via`, and an allocation procedure whose
allocator argument is omitted, binds that handle when the owner or operation is
initialized. Once bound, later calls continue to use the recorded allocator.

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
Nothing is inherited merely because one procedure called another.

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
Handler :: struct($S: typeid) {
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

Dynamic arrays, maps, runtime strings, and other managed containers remember the allocator responsible for their backing storage. By default they bind `mem.default_allocator()`; a declaration can select another allocator with `via`.

```odin
scratch := mem.Scratch();
bytes: [dynamic]u8 via scratch.allocator();
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
carrying the same allocator-reset effect, while a live managed value or borrow
still refers to storage from that allocator.

Allocator values have a region identity in addition to their allocation procedures and failure policy. Copying an allocator value preserves that identity, and every allocation records it. This is what lets the compiler recognize that two local allocator values refer to the same region. When static provenance cannot prove two allocator values distinct, the lifetime check conservatively treats their regions as possibly identical. Across a procedure call the identity is propagated through a parameter marked `@(allocator_reset)`; a Loke procedure that resets an allocator received as a parameter must mark that parameter, and the compiler verifies the promise transitively. The attribute is part of procedure-type compatibility, so indirect calls preserve the same effect.

Resetting a region is intentionally explicit. There is no zero-argument `free_all`; code must name the allocator being reset. A procedure may reset a region it created locally, because no caller-owned value can belong to it. It may not hide a reset of a global or other pre-existing allocator: such an allocator is taken through an `@(allocator_reset)` parameter instead.

```odin
release_scratch :: proc(@(allocator_reset) allocator: Allocator) {
	free_all(allocator);
}

arena := mem.Arena();
scratch := [dynamic]u8 via arena.allocator();
view := scratch[:];
release_scratch(arena.allocator()); // ERROR while `scratch` or `view` is live
```

The following low-level procedures are built in and are also available in package `mem` with enforced allocator errors. Normal managed strings, arrays, and maps do not need them.

- `new(T, allocator=mem.default_allocator()) -> (^T, Allocator_Error)` allocates a zero-initialized value of the type given. The pointer result is nil on failure.

```odin
ptr, err := new(int);
if (err != nil) { panic("integer allocation failed"); }
ptr^ = 123;
x: int = ptr^;
```

- `new_clone(value, allocator=mem.default_allocator()) -> (^T, Allocator_Error)` allocates a clone of the value passed to it. The pointer result is nil on failure.

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

- free - frees the memory at the pointer given. Note: only free memory with the allocator it was allocated with.

```odin
ptr, err := new(int);
if (err != nil) { panic("integer allocation failed"); }
free(ptr);
```

- `free_all(@(allocator_reset) allocator: Allocator)` frees every allocation in the allocator's region. Not all allocators support this procedure. The explicit argument and effect annotation make the invalidation visible through wrappers and indirect calls.

```odin
free_all(my_allocator);
```

- `drop` releases either a managed or manual owner. It consumes the owner, resets the variable to zero, and marks it dead until reassignment. Scope exit invokes it automatically only for managed owners; calling it explicitly on a definitely dead variable is an error.

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
allocator into a subsystem. `.Panic` may unwind according to the runtime's panic
rules; `.Trap` does not. In either case a partially constructed temporary is
cleaned up when unwinding permits it, and an existing assignment destination is
not modified before all required allocation and cloning succeeds.

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

Within one thread, evaluations are ordered by the rules under [Evaluation order](#evaluation-order). Evaluation and ownership transfer of a new thread's arguments happen before its first operation. Its final operation happens before a successful join returns. A mutex unlock happens before the next successful lock of that mutex, and a release atomic operation happens before an acquire operation that observes it. These edges, together with ordinary sequenced-before order, form the **happens-before** relation.

Two accesses conflict when they touch overlapping bytes and at least one is a write. If conflicting non-atomic accesses from different threads are not ordered by happens-before, the program has a data race and its behavior is undefined. Ordinary variables, pointers, container headers, reference counts, and struct fields are not implicitly atomic. This rule permits conventional optimizing compilers while making synchronization requirements explicit.

The `core:sync` package provides `Atomic(T)` for booleans, integer types, enums with supported integer backing types, and pointers. Its operations are backed by compiler intrinsics and accept `.Relaxed`, `.Acquire`, `.Release`, `.Acquire_Release`, or `.Sequentially_Consistent` ordering where meaningful. Relaxed operations are atomic but create no inter-thread ordering. Acquire and release create the happens-before edge described above. Sequentially consistent operations additionally participate in one total order. Unsupported type, operation, or ordering combinations are compile-time errors; the implementation may use a lock when the target lacks a lock-free instruction.

Moving an ordinary owning value to another thread transfers that owner and is allowed when no checked borrow remains in the sending thread. Copying creates the same independent value it would create within one thread. Raw pointers, stored borrows, foreign handles, and unchecked views may also be transferred, but the compiler does not prove that their pointees remain alive or race-free. There are no implicit `Send` or `Sync` interfaces.

Threads and retained tasks receive only the arguments explicitly moved or copied
into them. A request environment, logger, clock, scratch owner, or other service
handle is transferred like any other value, and transferring a handle does not
make its underlying state thread-safe.

## Shared ownership

`shared(T)` is an explicit library owner for one stable, heap-allocated `T` payload and an atomic strong-reference count. Its zero value is nil. `shared(value)` clones and allocates; `shared(move(value))` transfers the value into the allocation. Assignment invokes its custom `clone` hook and increments the strong count rather than cloning `T`; `move` transfers one handle; `drop` decrements the count with release ordering, performs an acquire fence when it observes the final reference, and then drops the payload exactly once. Construction uses `mem.default_allocator()`, or one supplied through its ordinary `allocator` parameter, follows that allocator's failure policy, and has an explicit `try_shared` form for local error handling. A `shared(T)` variable may also be declared `via` an allocator like any other managed owner.

The atomic reference count makes copying and dropping handles safe across threads. It does **not** make concurrent access to `T` safe. `handle.get()` returns a non-owning `^T` whose lifetime is attributed to that handle; callers must use a mutex, atomics within `T`, immutability, or another protocol before conflicting access. The borrow may not outlive the handle used to obtain it, but the compiler does not correlate aliases obtained from different shared handles.

Strong-reference cycles are permitted and leak until explicitly broken. `weak(T)` is the non-owning companion: it keeps the control block but not the payload alive, and `upgrade` returns `(shared(T), bool)`. Libraries that build cyclic graphs should use weak back-edges or explicit teardown.

Immutable `string` implementations that share backing storage use the same thread-safe lifetime principle: their reference-count operations, when present, are atomic, while the bytes themselves never change. This requirement does not make mutable containers safe for concurrent access.

# Foreign system

It is sometimes necessary to interface with foreign code, such as a C library. This is achieved through the foreign system. You can “import” a library into the code using the same semantics as a normal import declaration:

## Foreign-ABI-safe types

A procedure using a foreign calling convention, a variable declared in a foreign block, or an exported foreign symbol must have a representation the target ABI can describe. The following types are foreign-ABI-safe:

- fixed-width integers, `int`, `uint`, `uintptr`, `bool`, `rune`, `f32`, and `f64`; their size and alignment follow their Loke definitions and their argument classification follows the target C ABI for a scalar of that representation. `bool` uses C `_Bool`, and `int` and `uint` use the ABI class matching their target-selected width. `f16`, 128-bit integers, and other target extensions are safe only when that target ABI defines their C-compatible classification;
- `rawptr`, `^T`, and `[^]T`, lowered as C pointers; the pointed-to type need not be foreign-ABI-safe because the foreign function receives only an address;
- procedure pointers whose declared calling convention and complete signature match the foreign declaration;
- enums with an explicit foreign-ABI-safe integer backing type;
- plain structs with a trivial lifecycle whose fields are recursively foreign-ABI-safe. Their field order, padding, alignment, and by-value argument classification follow the target C ABI for the equivalent C record. A fixed array is permitted as a record field and has the equivalent C array layout;
- `cstring_view`, lowered to `char const *`. It may be used as a parameter or result and never claims ownership.

Managed containers, `string`, slices, dynamic arrays, maps, tagged unions, `any_view`, and records with custom lifecycle hooks are not foreign-ABI-safe. Interfaces are compile-time declarations and do not denote ABI values. A fixed array is not permitted as a top-level C parameter because C adjusts such parameters to pointers; write `[^]T` or `^T` explicitly. A packed record is safe only when the bound C declaration uses the same target-specific packing convention; portable bindings should instead copy through an ordinary ABI record.

The base language has no overlapping-record or C-union type. Portable bindings pass a C union as `rawptr` and expose typed wrapper accessors. A binding generator may use a target-specific extension for a union passed by value, but that representation is not portable Loke source.

A default foreign parameter is passed by value. `p: inout T` lowers to `T *`, while `@(by_ptr) p: T` lowers to `T const *`. Foreign parameters cannot use the `move` mode: a C call does not implicitly acquire Loke cleanup responsibility. Exported Loke procedures follow the same restrictions and must declare the foreign calling convention expected by their callers.

These rules define representation, not lifetime. A pointer, `cstring_view`, or `inout` argument is borrowed only for the call as far as the compiler can see. Foreign code that retains it crosses the trust boundary described under [What is not checked](#what-is-not-checked); the programmer must keep the storage alive and synchronize access. Returning a pointer likewise transfers no ownership unless the binding wraps it in an explicitly documented Loke resource type.

foreign import kernel32 "system:kernel32.lib";

This foreign import declaration will create a “foreign import name” which can then be used to associate entities within a foreign block.

```odin
foreign import kernel32 "system:kernel32.lib";
foreign kernel32 {
	ExitProcess :: proc "stdcall" (exit_code: u32) ---;
}
```

The compiler can also automatically build and link imported assembly files. Depending on the host system, clang, as, or nasm may be used to compile the assembly. Recognized file extensions for assembly files are: asm, s, and S.

For examples, see base/runtime/entry_*.asm.

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

If a library exports global variables, you can import those as well.

```odin
foreign lib {
	x: i32;
}
```

Foreign procedure declarations have the `c` calling convention by default unless specified otherwise. Because a foreign procedure has no Loke body, its declaration ends with `---` to distinguish it from a procedure type.

The attributes system can be used to change specific properties of entities declared within a block:

```odin
@(default_calling_convention = "stdcall")
foreign kernel32 {
	@(link_name="GetLastError") get_last_error :: proc() -> i32 ---;
}
```

Available attributes for foreign blocks:

- default_calling_convention=<string> - The default calling convention for procedures declared within this foreign block.
- link_name=<string> - Sets the exact foreign symbol name for an individual declaration.
- private=<string> - Restricts all entities in the block to the file. Only "file" is meaningful; package visibility is the default.
- public - Exports all entities declared within the block. Bindings usually want this, or `@(public)` on the package declaration.
- require_results - All procedures declared within this foreign block must have their return values used.

# Generics

Generics let a procedure or data type bind compile-time type or value parameters and use them throughout its definition.

The `$` prefix always marks the declaration or inference of a generic parameter. It is required wherever such a parameter is introduced and is not written when the bound name is subsequently used.

## Explicit generic parameters

An explicit generic parameter is supplied by the caller. A parameter of type `typeid` receives a type; other parameter types receive compile-time constant values.

### Procedures with explicit generic parameters

To specify that a procedure parameter is supplied at compile time rather than merely immutable at runtime, prefix its declared name with `$`. The following example takes two compile-time constant parameters and uses them to initialize an array of known length:

```odin
make_f32_array :: proc($N: int, $val: f32) -> (res: [N]f32) {
	foreach (_, i in res) {
		res[i] = val*val;
	}
	return;
}

array := make_f32_array(3, 2);
```

Types can also be explicitly passed by specifying that the typeid parameter is constant:

```odin
my_new :: proc($T: typeid) -> ^T {
	ptr, err := new(T);
	if (err != nil) { panic("allocation failed"); }
	return ptr;
}

ptr := my_new(int);
```

### Generic data types

Structures and unions declare generic parameters using the same parameter-list shape as procedures. Generic struct:

Arguments whose parameter type is `typeid` are types; arguments to any other parameter are compile-time constant expressions. Bare names are resolved after parsing, so both `Buffer(Element, Count)` and `Buffer(u8, 4096)` use the same argument syntax. A value argument is not restricted to an identifier.

```odin
Table_Slot :: struct($Key, $Value: typeid) {
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
Param_Union :: union($T: typeid) {T, Error};
r: Param_Union(int);
r = 123;
r = Error.Foo0;
```

Record and union generic parameters always require `$`, just like compile-time procedure parameters. This keeps every binding site visually explicit even though all record and union parameters are necessarily compile-time values.

## Inferred generic parameters

An inferred generic parameter is bound from the type or shape of a runtime argument. In this case `$` appears at the binding position inside the parameter type.

### Procedures with inferred generic parameters

```odin
foo :: proc($N: $I, $T: typeid) -> (res: [N]T) {
	// `N` is the constant value passed
	// `I` is the type of `N`
	// `T` is the type passed
	fmt.printf("Generating an array of type %v from the value %v of type %v\n",
			   typeid_of(type_of(res)), N, typeid_of(I));
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

In some cases, you may want to specify that a parameter must have a particular structural shape rather than any type at all. **Write the shape directly in the parameter type**, marking the parts to bind with `$`:

```odin
// Only allow read-only slices, binding their element type.
// A []mut E argument may call this through capability weakening.
first_slice_value :: proc(values: []$E) -> (E, bool) {
	if (len(values) == 0) {
		return {}, false;
	}
	return values[0], true;
}

Table_Slot :: struct($Key, $Value: typeid) {
	occupied: bool,
	hash:     u32,
	key:      Key,
	value:    Value,
}
Table :: struct($Key, $Value: typeid) {
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

There is no separate `$T: typeid/Shape` form binding a name to the *whole* matched type alongside its parts. The shape is already written in the parameter type, so a name for the aggregate would be a second spelling of a constraint the signature has already stated; where the aggregate is needed — as a result type, say — it is written out:

```odin
swapped :: proc(pair: [2]$E) -> [2]E {
	return [2]E{pair[1], pair[0]};
}
```

## where clauses

A bound on generic parameters to a procedure or record can be expressed using a `where` clause immediately before the opening `{`. Every bound is a compile-time boolean expression evaluated while the declaration is instantiated.

The clause is part of the same declaration as the signature it constrains. No semicolon separates them; the declaration is terminated by its body, exactly as it would be without the clause. Multiple bounds are separated by commas and all must hold.

A bound may reference generic type and value parameters in scope from the declaration or an enclosing generic `impl`, plus constants, types, interface applications, and compile-time built-ins. It may not depend on a runtime parameter, local variable, mutable global, or runtime procedure call. A declaration with no generic parameters in scope therefore cannot have a `where` clause. Runtime preconditions are ordinary `if` and `assert` statements in the procedure body.

Some cases that a where clause may be useful:

- Generic parameter checks for procedures. The bound here is about what `E` *can do*, so it is written as an [interface](#interfaces-and-generic-operators) rather than as a type predicate:

```odin
// A fixed array has no `.x`/`.y` swizzle selectors; index it.
cross_2d :: proc(a, b: [2]$E) -> E
	where Numeric(E) {
	return a[0]*b[1] - a[1]*b[0];
}
cross_3d :: proc(a, b: [3]$E) -> [3]E
	where Numeric(E) {
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

- Restrictions on generic parameters for record types. Note the division of labour: `Integral(T)` is a capability requirement and is an interface, while `N > 2` is a predicate over a value and is what a `where` clause is for:

```odin
Foo :: struct($T: typeid, $N: int)
	where Integral(T),
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

Attributes modify declarations, parameters, statements, blocks, or type literals. The syntax is always `@(name)` or `@(name=value, ...)`; there is no separate annotation grammar for layout and control flow.

## Attribute categories

### Foreign Blocks

```odin
    @(default_calling_convention=<string>) – foreign blocks
    @(private=<string?>)– all declarations except import statements
    @(public) – all declarations except import statements
    @(require_results) – procedure declarations and foreign blocks
```

### Procedure Groups

```odin
    @(require_results)
```

### Procedure Declarations

```odin
    @(deprecated=<string>)
    @(export)
    @(fini)
    @(init)
    @(implicit)
    @(link_name=<string>)
    @(require_results)
```

Optimization and code-generation annotations such as `@(compiler.no_alias)` and `@(compiler.must_tail)` are [extension attributes](#extension-attributes), not base-language ones.

### Procedure Parameters

```odin
    @(allocator_reset) – `Allocator` parameters whose region may be reset
    @(by_ptr) – foreign declarations only
    @(c_vararg) – final variadic parameter of a foreign declaration
```

### Variable declaration attributes

```odin
    @(export)
    @(link_name=<string>)
    @(private=<string>?) – globals only
    @(public) – globals only
```

Every one of these concerns linkage or visibility: which symbol a declaration produces and who may name it. Storage duration and ownership are not attributes; they are [storage modifiers](#storage-modifiers) written in the declaration itself. Read-only data is not an attribute either; it is what a [constant](#constant-declarations) already is.

### Constant Value Declarations

```odin
    @(private=<string>?)
    @(public)
```

### Type Declarations

```odin
    @(private=<string>?)
    @(public)
```

## Attribute reference

### `@(implicit)`

Allows a one-argument overload belonging to its target type's `init` group to be applied without being written, **only where the argument is an untyped constant**. Its parameter type must be a built-in numeric, boolean, rune, or string type. A runtime value always requires the explicit `Target(value)` form. See [Implicit conversion from constants](#implicit-conversion-from-constants).

`@(implicit)` on a procedure that is not a one-argument `init` overload is an error.

### `@(default_calling_convention=<string>)`

This attribute can be attached to a foreign block to specify the default calling convention for all procedures in the block. Example:

```odin
@(default_calling_convention = "stdcall")
foreign kernel32 {
	@(link_name="LoadLibraryA") load_library_a  :: proc(c_str: ^u8) -> Hmodule ---;
}
```

### `@(deprecated=<string>)`

Mark a procedure as deprecated. Running `loke build`, `loke run`, or `loke check` prints the message for each use of the deprecated procedure.

```odin
@(deprecated="'foo' deprecated, use 'bar' instead")
foo :: proc() {
    ...
}
```

### `@(export)`

Emits a variable or procedure symbol into the object file so that a C consumer or a DLL can link against it. This is distinct from [`@(public)`](#public), which controls whether other Loke packages may name the declaration; the two are independent and a declaration may need both.

It takes no argument. A boolean parameter would only be useful for opting out of an enclosing export default, and no construct establishes one — a foreign block or package clause can carry `@(public)`, never `@(export)`. Conditional export is written with `when` around the declaration.

### `@(init)`

This attribute may be applied to any procedure that neither takes parameters nor returns values. All such procedures are called before `main` in one total, deterministic order:

1. A dependency package runs before every package that imports it.
2. When several packages are ready, the package with the lexicographically smaller canonical import path runs first. Comparison is by UTF-8 bytes.
3. Within a package, files are ordered by their normalized package-relative path, using `/` as the separator and the same UTF-8 byte comparison.
4. Within a file, procedures run in source order.

The build system assigns each resolved package one canonical import path before this ordering is computed, so aliases and host filesystem enumeration never affect initialization order.

### `@(fini)`

Like `@(init)`, but run after `main` finishes. The set of `@(fini)` procedures is ordered by the same package, file, and source-position rules and then run in reverse; a `@(fini)` procedure does not need a corresponding `@(init)` procedure.

### `@(link_name=<string>)`

This attribute can be attached to variable and procedure declarations, either when exporting or inside a foreign block. This specifies what the variable/proc is called in the library. Example:

```odin
foreign foo {
    @(link_name = "bar")
    testbar :: proc(baz: int) ---;
}

@(export, link_name="lib_foo")
foo :: proc "c" () -> int {
	return 42;
}
```

### `@(private=<string?>)`

Restricts a top level element to the file it is declared in.

```odin
@(private="file")
my_variable: int; // cannot be accessed outside this file
```

`@(private)` and `@(private="package")` both name package visibility, which is already the default. They are only load-bearing in a file whose package declaration has `@(public)`, where they exclude one declaration from the file-wide export.

Applying `@(private="file")` to the package declaration is equivalent to adding it to every declaration in that file:

```odin
@(private="file")
package foo;
```

To remove that file-private association from one declaration, apply `@(private)` to it.

### `@(public)`

Exports a top level element from its package. Without it, a declaration is visible only within its own package.

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

`@(public)` and `@(private="file")` are mutually exclusive on the same package declaration. Within a public-default file, `@(private)` and `@(private="file")` narrow an individual declaration back down.

### `@(require_results)`

Ensures procedure return values are acknowledged, meaning that in any scope where a procedure p having procedure attribute @(require_results) is called, the scope must explicitly handle the return values of procedure p in some way, such as by storing the return values of p in variables or explicitly dropping the values by setting _ equal them.

```odin
@(require_results)
foo :: proc() -> bool {
    return true;
}

main :: proc() {
    foo(); // won't compile
    _ = foo(); // Ok
}
```

### Storage duration and ownership

These are deliberately *not* attributes. `stack`, `static`, `thread_local`, and `manual` are [storage modifiers](#storage-modifiers) written in the declaration, because they change what the program does rather than describing it for a tool:

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

- `@(compiler.no_alias)` on a pointer parameter, the equivalent of C's `restrict`. It asserts that the parameter does not alias the others; violating it is undefined behaviour, and no Loke rule depends on it.
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

#### `#caller_location`

`#caller_location` sets a parameter’s default value to the location of the code calling the procedure. The location value has the type `Source_Code_Location`. `#caller_location` may only be used as a default value for procedure parameters.

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

Marks an `Allocator` parameter whose region may be reset by a successful call. The effect is part of the procedure type. At each call site the compiler substitutes the supplied allocator's region identity and rejects the call while a managed owner or borrow from that region is live.

A Loke procedure is verified: every `free_all` operation on a region that existed before procedure entry, and every call through another reset-capable parameter, must be covered by one of the procedure's own `@(allocator_reset)` parameters. A procedure may freely reset a region it created locally. Foreign procedures carrying the attribute are programmer promises. A pre-existing allocator that may be reset must be passed explicitly; hidden resets through globals are not permitted.

# Compile-time built-ins

## `#assert(<boolean>)`

Unlike `assert`, `#assert` runs at compile time. It accepts an optional constant message string and breaks compilation if the condition is false. It has no runtime cost.

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

foos: [dynamic]Foo;
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

The defer if idiom is equivalent to an if statement inside of a defer. It is merely a shorthand that comes about from the natural evaluation of if as a statement in its own right; it does not optionally defer a statement on the basis of a boolean condition at the time of evaluation, but it evaluates the condition once the deferred block is acted upon.

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

A procedure that may not produce a value returns `(T, bool)` — the same [optional-ok shape](#optional-ok-results) used by map indexing, validating conversions, type assertions, `pop`, and the [iteration protocol](#iteration-protocol). There is no `Option`, `Maybe`, or `Result` type in the language or the core library, because multiple return values already express this and a wrapper type would give the same idea a second spelling that every API then has to choose between.

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

The convention is that the `bool` comes last and is named `ok`, and that the value is the zero value when `ok` is false. An error that carries information returns an error value instead and is propagated with [`or_return`](#or_return-operator); `bool` is for the case where "absent" is the whole story. Nothing prevents a library from declaring `Option :: union($T: typeid) {T}` for its own use — it is an ordinary union — but the core library does not, and no language construct is aware of it.

## Advanced idioms

### Implicit Type Conversions

The language is strongly and distinctly typed by default. Built-in implicit conversions are limited, and the only user-defined ones apply to untyped constants. A runtime value never changes type without the change appearing in the source.

- ^T -> rawptr
- [^]T -> rawptr
- [^]T <-> ^T
- Concrete values to `any_view` when an `any_view` parameter or local destination is expected; the result is a checked non-escaping borrow
- Any of its variants to the union
- T -> Simd(T, N)
- distinct proc <-> proc (same base types)
- Untyped integers -> built-in numeric types that can represent them without truncation
- Untyped floats -> built-in numeric types that can represent them without truncation
- Untyped booleans -> `bool`
- Untyped rune -> all rune types
- Untyped strings -> `string`, `string_view`, or `cstring_view` when the destination supplies the required lifetime
- Untyped constants into a user type through a visible [`@(implicit)`](#implicit-conversion-from-constants) conversion; this is how literals enter library numeric types, and it is the only user-defined implicit conversion

# Library types assumed by this specification

Several types are used in normative text above but are supplied by the library. They are listed here so that an implementer knows what the core library owes the language. `Atomic(T)` is backed directly by compiler intrinsics; the remaining types use ordinary language facilities.

| Type | Used by | Status |
| --- | --- | --- |
| `String_Builder` | [string type](#string-type) | Built from `[dynamic]u8`. |
| `C_String` | [C string views](#c-string-views) | Owned zero-terminated `[dynamic]u8` buffer for foreign APIs that retain strings. |
| `Small_Array(T, N)` | [fixed-capacity arrays](#fixed-capacity-arrays) | Inline growable container implemented through ordinary methods and operators. |
| `Little_Endian(T)`, `Big_Endian(T)` | [basic types](#basic-types) | Distinct storage wrappers supplied by binary-format libraries. |
| `Allocator_Error`, `Allocator`, `mem.Scratch`, `mem.Arena` | [allocators](#allocators), fallible operations | `core:mem` / `base:runtime`. The final build selects the provider behind `mem.default_allocator()`. |
| `Logger` | [build-selected providers](#build-selected-providers) | Ordinary service handle supplied by `core:log`; the final build selects the backend used by the package-level logging procedures. |
| `Trace_Span`, `Time` | [explicit runtime environments](#explicit-runtime-environments) | Representative runtime handles supplied by tracing and time libraries; they have no compiler-known propagation. |
| `Source_Code_Location` | `#caller_location`, `#location` | `base:runtime`. |
| `Bit_Set(Enum)`, `Enum_Array(Enum, T)` | flag sets and [enum iteration](#iterating-an-enumeration) | Generic library containers. Hardware register layouts use integer masks and explicit accessors in version 1. |
| `Complex(T)`, `Quaternion(T)` | [library numeric types](#library-numeric-types) | Deliberately not primitive. |
| `shared(T)`, `weak(T)` | [shared ownership](#shared-ownership) | Library records with custom lifecycle hooks and an atomic control block. |
| `Atomic(T)` | [concurrency and the memory model](#concurrency-and-the-memory-model) | `core:sync` wrapper over compiler atomic intrinsics. |

The public APIs and layouts of these types belong to their packages; only the behavior required by the linked normative sections is part of the language contract.
