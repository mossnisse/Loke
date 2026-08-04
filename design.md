# file format

Loke source code has to be in utf8 wihtout an BOM mark to be considered valid. That is choosen to handle unicode string literals.

# Code blocks

A code block is surrounded by braces (`{}`) and creates a scope for the variables declared inside it.

## Statements

Statements are terminated by a semicolon (`;`).

## Control-flow headers

Every control-flow statement — `if`, `for`, `switch`, `when` — puts its header inside parentheses, and every body uses braces (`{}`) or the `do` shorthand for a single statement. There are no exceptions to remember: if a construct takes a condition, that condition is parenthesised.

```odin
if (x >= 0) { }
for (i := 0; i < 10; i += 1) { }
switch (value) { }
when (ODIN_DEBUG) { }
```

A `switch` with no condition is written `switch { }`, since there is no header to parenthesise.

This differs from Odin, which leaves the parentheses off. The uniform rule keeps the header visually separate from the body brace and removes the ambiguity Odin resolves with a special parsing rule for composite literals in condition position.

# Identifiers

Identifiers are case-sensitive and match `[A-Za-z_][A-Za-z0-9_]*`. The single identifier `_` is the discard identifier and does not introduce a binding. Unicode remains valid in comments and literals, but identifiers containing non-ASCII characters are rejected. Whether a later language version should admit Unicode identifiers is recorded under [Open questions](#identifier-character-set).

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

Automatic cleanup participates in the same ordering as `defer`. Completing initialization of a managed local registers an implicit `defer drop(value)` at that point, including when an allocation failure under the `.Error` policy initializes it to zero. User-written defers and implicit cleanups execute together in reverse registration order. A defer that refers to an already initialized managed local therefore runs before that local is dropped. On `return`, result expressions are evaluated and copied or moved into result storage before scope-exit actions begin; defers cannot change the already-prepared result.

Storage placement and ownership are separate concepts. Three modifiers control them:

- `stack` requires a fixed-size value to live in the current stack frame. This is a guarantee, not a hint: it lets embedded and real-time code state that a declaration must not touch the allocator, and the compiler rejects the declaration if it cannot honour it.
- `heap` places a fixed-size value on the heap while keeping lexical lifetime and automatic cleanup. Its purpose is values too large for a stack frame — a declaration that would otherwise overflow the stack at runtime becomes a heap allocation with identical semantics.
- `manual` disables automatic cleanup for an owning value. It is intended for arenas, foreign ownership, custom containers, and low-level allocator code.

Without a modifier the compiler chooses placement, and that choice never changes the meaning of a program — only whether it fits.

```odin
small: stack Matrix4;         // guaranteed no allocation
large: heap [1_000_000]f64;   // 8 MB: would overflow a stack frame
buffer: manual [dynamic]u8 = make([dynamic]u8, allocator=my_allocator);

// A manual owner must be released explicitly.
delete(buffer);
```

`drop(value)` may be used to release a managed value before the end of its scope. It resets the variable to its zero value, so dropping it again is harmless.

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

If a clone cannot allocate, the assignment fails according to the allocator's failure policy described under [Allocation failure](#allocation-failure). The destination keeps its previous value; a failed assignment never leaves a half-copied value.

# Borrows and lifetimes

Loke is not memory safe in the sense that Rust is, and does not try to be. It checks one specific and very common class of error — using a view into a container after that container has been moved, released, or reallocated — and it does so with rules that are entirely local to a single procedure body. Everything outside those rules is the programmer's responsibility, and this section states exactly where the line falls.

## What a borrow is

A **borrow** is a non-owning view of storage that some other value owns. Borrows arise in five ways:

- a slice expression over an owner: `numbers[:]`, `numbers[1:4]`
- a procedure argument: storage reached through a default parameter is borrowed immutably, while an `inout` parameter borrows the caller's variable mutably
- the address-of operator applied to an owner or one of its elements: `&numbers[0]`
- an iterator obtained from a collection, and the `&value` form of a `for` loop
- a user-defined `operator([])` returning `inout T`, or `operator([:])`

A borrow is not a value you can own. It has no cleanup, it is never dropped, and assigning it copies the view rather than the storage.

An owning temporary created while evaluating an expression lives until the end of that complete expression. A borrow derived from the temporary may be used during that expression, including by a called procedure, but it cannot be assigned, returned, stored, or otherwise made live after the expression. The compiler diagnoses such an escape at the call or assignment that would extend the borrow.

## The one rule

> While a borrow of an owner is live, that owner may not be moved, dropped, or reallocated through any name.

An owner is *reallocated* by any operation that may change where its backing storage lives or how long it is: `append`, `resize`, `reserve`, `shrink`, `clear`, `remove`, map insertion, and any user operation taking `inout self` that is not annotated otherwise.

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
scratch := [dynamic]u8 using context.temp_allocator;
view := scratch[:];
free_all(context.temp_allocator);  // ERROR
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

This is deliberately coarse. A procedure taking two slices and returning one is treated as returning a borrow of both. At the call site, a returned borrow is rejected if any attributed argument is a temporary whose lifetime ends with the call's complete expression. The imprecision costs an occasional unnecessary copy; it buys a model with no lifetime annotations anywhere in the language.

## What is not checked

These are real holes, they are intentional, and no diagnostic will catch them:

- **Borrows stored in memory.** Putting a slice in a struct field, a global, a container, or a captured context escapes the analysis entirely. Once a borrow is stored, its validity is yours to maintain.
- **Borrows across procedure boundaries beyond the coarse rule above.** If a procedure stores a borrowed parameter somewhere that outlives the call, nothing detects it.
- **Anything reached through a raw pointer.** `^T` arithmetic, `[^]T` multi-pointers, `raw_data`, `transmute`, and the `unsafe` package are outside the model by construction.
- **Threads.** Borrow liveness is analysed per procedure body; sending a borrow to another thread is not tracked. Use `shared(T)` or an owned copy.
- **Foreign code.** A borrow passed to a C function may be retained by that function. The `foreign` boundary is a trust boundary.

If you need a view whose lifetime you cannot prove locally, take an owned copy with `clone`, or use `shared(T)`.

## Debug-mode detection

Because the escape holes above are real, an implementation is encouraged to make them *detectable* rather than silent. When `ODIN_DEBUG` is set, managed containers may carry a generation counter that is bumped on every reallocation, with slices carrying the generation they were created from and trapping on mismatch.

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

A `manual` owner is exempt from the reallocation and drop checks, since the whole point of `manual` is that the programmer is tracking lifetime themselves. Borrows of a `manual` owner are still ordinary borrows and still cannot be returned from the procedure that created the owner — that check depends only on scope, not on ownership mode.

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

Numerical literals are written similarly to most other programming languages. Underscores are allowed for readability: `1_000_000_000` (one billion). A number containing a decimal point is a floating-point literal: `1.0e9` (one billion). Numeric literals do not have complex- or quaternion-specific suffixes; library numeric types use ordinary constructors and conversions.

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

For more information regarding value declarations in general, please see the Odin FAQ and Ginger Bill’s article On the Aesthetics of the Syntax of Declarations.

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

Loke programs consist of packages. A package is a directory of source files, all of which have the same package declaration at the top. Execution starts in the package’s main procedure.

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

Every source file must contain its package declaration. Package versions are selected by the build system or package manager and are not part of import syntax in this language version. Possible versioned imports are recorded under [Open questions](#package-and-import-versioning).

## Exported names

All declarations in a package are public by default.

The private attribute can be applied to an entity to prevent it from being exported from a package.

```odin
@(private)
my_variable: int; // cannot be accessed outside this package
```

You may also make an entity private to the file instead of the package.

```odin
@(private="file")
my_variable: int; // cannot be accessed outside this file
```

`@(private)` is equivalent to `@(private="package")`.

### Authoring a package

A package is a directory of source files, all of which have the same package declaration at the top, e.g. package main. Each source file must have the same package name. A directory cannot contain more than 1 package.

### Organizing packages

Packages may be thematically organized by placing them in subdirectories of another package. For example: core:image/png and core:image/tga, as subdirectories of core:image. Nesting these packages is a helpful taxonomy. It does not imply a dependency: core:foo/bar does not need to import core:foo and reference anything from it.

Public-by-default visibility is the rule for this language version. Whether a later version should reverse the default is recorded under [Open questions](#default-visibility).

# Control flow statements

## for statement

The language has one loop statement: `for`.

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

The loop header is parenthesised and the body uses braces or `do`, as for every control-flow statement:

```odin
for (i := 0; i < 10; i += 1) { }
for (i := 0; i < 10; i += 1) do single_statement();
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

### Range-based for loop

The basic for loop

```odin
for (i := 0; i < 10; i += 1) {
	fmt.println(i);
}
```

can also be written

```odin
for (i in 0..<10) {
	fmt.println(i);
}
// or
for (i in 0..=9) {
	fmt.println(i);
}
```

where a..=b denotes a closed interval [a,b], i.e. the upper limit is inclusive, and a..<b denotes a half-open interval [a,b), i.e. the upper limit is exclusive.

Certain built-in types can be iterated over:

```odin
some_string := "Hello, 世界";
for (character in some_string) {
	fmt.println(character);
}

some_array := [3]int{1, 4, 9};
for (value in some_array) {
	fmt.println(value);
}

some_slice := []int{1, 4, 9};
for (value in some_slice) {
	fmt.println(value);
}

some_dynamic_array := [dynamic]int{1, 4, 9};
for (value in some_dynamic_array) {
	fmt.println(value);
}

some_map := map[string]int{"A" = 1, "C" = 9, "B" = 4};
for (key in some_map) {
	fmt.println(key);
}
```

Alternatively a second index value can be added:

```odin
for (character, index in some_string) {
	fmt.println(index, character);
}
for (value, index in some_array) {
	fmt.println(index, value);
}
for (value, index in some_slice) {
	fmt.println(index, value);
}
for (value, index in some_dynamic_array) {
	fmt.println(index, value);
}
for (key, value in some_map) {
	fmt.println(key, value);
}
```

The iterated values are copies and cannot be written to.

When iterating a string, the characters will be runes rather than bytes. `for ... in` assumes the string is encoded as UTF-8.

```odin
str: string = "Some text";
for (character in str) {
	assert(type_of(character) == rune);
	fmt.println(character);
}
```

You can iterate arrays and slices by-reference with the address operator:

```odin
for (&value in some_array) {
	value = something;
}
for (&value in some_slice) {
	value = something;
}
for (&value in some_dynamic_array) {
	value = something;
}
// does not impact the second index value
for (&value, index in some_dynamic_array) {
	value = something;
}
```

Map values can be iterated by-reference, but their keys cannot since map keys are immutable:

```odin
some_map := map[string]int{"A" = 1, "C" = 9, "B" = 4};

for (key, &value in some_map) {
	value += 1;
}

fmt.println(some_map["A"]); // 2
fmt.println(some_map["C"]); // 10
fmt.println(some_map["B"]); // 5
```

Note: It is not possible to iterate a string in a by-reference manner as strings are immutable.

### for reverse iteration

The #reverse directive makes a range-based for loop iterate in reverse.

```odin
array := [?]int { 10, 20, 30, 40, 50 };

#reverse for (x in array) {
	fmt.println(x); // 50 40 30 20 10
}
```

### for loop unrolling

The #unroll directive takes a for loop and expands it at compile-time to the individual statements, repeated for as many times as the loop would normally iterate. This may result in performance improvements or provides the ability to repeat a set of instructions a limited number of times without explicitly writing each out in repetition.

Please note that #unroll may only be used with ranged for loops that have constant intervals known at compile-time.

```odin
x: [4]u8 = 0xFF;
y: [4]u8 = 0x88;
#unroll for (i in 0..<len(x)) {
	x[i] ~= y[i];
}
```

### Design notes

Keeping one loop keyword is compact, while mandatory parentheses make loop headers easier to scan.

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

A switch statement is another way to write a sequence of if-else statements. The default case is denoted as a case without any expression.

```odin
switch (arch := ODIN_ARCH; arch) {
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

foo() does not get called if i==0. If all the case values are constants, the compiler may optimize the switch statement into a jump table (like C).

A switch statement without a condition is the same as switch true. This can be used to write a clean and long if-else chain and have the ability to break if needed

```odin
switch {
case x < 0:
	fmt.println("x is negative");
case x == 0:
	fmt.println("x is zero");
case:
	fmt.println("x is positive");
}
```

A switch statement can also use ranges like a range-based loop:

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

### `#partial switch`

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
case:    fmt.println("?");
}

#partial switch (f) {
case .A: fmt.println("A");
case .D: fmt.println("D");
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

#partial switch (_ in f) {
case bool: fmt.println("bool");
}
```

## defer statement

A defer statement defers the execution of a statement until the end of the scope it is in. It is registered when execution reaches the `defer` statement and participates in the unified LIFO scope-exit ordering described under [Managed values and storage](#managed-values-and-storage).

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

Note: Loke’s defer differs from Go’s defer, which is function-exit and relies on a closure stack system. Whether `defer` earns its place in the final language is tracked under [Open questions](#retaining-defer); its semantics while present are defined above.

## when statement

The when statement is almost identical to the if statement but with some differences:

- Each condition must be a constant expression because a `when` statement is evaluated at compile time.
- Statements within a branch do not create a new scope.
- The compiler checks only the branch belonging to the first true condition.
- An initial statement is not allowed in a `when` statement.
- `when` statements are allowed at file scope.

Example:

```odin
when (ODIN_ARCH == .i386) {
	fmt.println("32 bit");
} else when (ODIN_ARCH == .amd64) {
	fmt.println("64 bit");
} else {
	fmt.println("Unsupported architecture");
}
```

The when statement is very useful for writing platform specific code. This is akin to the #if construct in C’s preprocessor. However, it is type checked.

See the Conditional compilation section for examples of built-in constants you can use with when statements.

### Branch statements

### break statement

A for loop, conditional, or a switch statement can be left prematurely with a break statement. It leaves the innermost construct, unless a label of a construct is given:

```odin
for (cond) {
	switch {
	case:
		if (cond) {
			break; // break out of the `switch` statement
		}
	}

	break; // break out of the `for` statement
}

loop: for (cond1) {
	for (cond2) {
		break loop; // leaves both loops
	}
}

outer: if (cond) {
	ok := check_something();
	if (!ok) {
		break outer; // label names are required with conditionals
	}
}

exit: {
    if (true) {
        break exit; // works with labeled blocks too
    }
    fmt.println("This line will never print.");
}
```

## continue statement

As in many programming languages, a continue statement starts the next iteration of a loop prematurely:

```odin
for (cond) {
	if (get_foo()) {
		continue;
	}
	fmt.println("Hellope");
}
```

## fallthrough statement

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
	switch {
	case n < 1:
		return 0;
	case n == 1:
		return 1;
	}
	return fibonacci(n-1) + fibonacci(n-2);
}

fmt.println(fibonacci(3)); // 2
```

For more information regarding value declarations in general, please see the Odin FAQ.

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

By default, procedures use the `loke` calling convention. It uses the platform C ABI as a base but differs in a couple of ways:

- It may pass a value indirectly when that’s more efficient on the target system, and
- It includes a pointer to the current context as an implicit additional argument.

Indirect passing is an ABI lowering only and is not observable language semantics. An implementation may use registers, a callee-local slot, or a caller-provided address as long as the parameter behavior below is preserved. Source programs cannot rely on the address chosen by the ABI.

A default parameter is a callee-local immutable binding. Trivial values may be copied into it. For a managed value such as a string or dynamic array, the binding contains a non-owning view of the argument's representation: passing it does not clone its allocation and does not transfer ownership, and storage reached through it is an immutable borrow subject to [Borrows and lifetimes](#borrows-and-lifetimes). Taking the address of the binding borrows the callee-local slot, not the caller's variable. Use `inout` when the parameter must alias the caller's variable and `move` when ownership must transfer.

```odin
sum :: proc(values: [dynamic]int) -> int {
	// `values` is a read-only borrow; no array copy is made.
	result := 0;
	for (value in values) {
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

A mutable borrow prevents the owner from being moved, dropped, or reallocated through another name while the borrow is live. See [Borrows and lifetimes](#borrows-and-lifetimes) for the complete rule and for the cases it deliberately does not cover.

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
	for (n in nums) {
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

As of the dev-2023-07 release, mixing named and positional arguments is allowed. This is often useful when a procedure has a lot of arguments or you want to customize default values.

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

Default values are assigned at the start of the procedure call and can be overwritten. They may also be assigned to named results.

Note: These default values must be compile time known values, such as a constant value or nil (if the type supports it).

### Explicit procedure overloading

Unlike other languages, Loke provides the ability to explicitly overload procedures:

```odin
bool_to_string :: proc(b: bool) -> string {...};
int_to_string  :: proc(i: int)  -> string {...};

to_string :: proc{bool_to_string, int_to_string};
```

### Rationale behind explicit overloading

Named procedure groups make overload sets visible and give every implementation an ordinary name that can be called directly. Methods and operators use the same overload-resolution rules, but their call syntax selects from the visible group automatically.

The language does not reject an abstraction merely because it can be used badly. Operator overloading, implicit conversions, extension methods, and custom lifecycle hooks can all make unfamiliar code harder to read, but they also make well-designed domain types dramatically clearer. The goal is to make good programs possible, trust the programmer, and provide tools that reveal what the compiler selected.

Ambiguity is still a compile-time error because a program must have deterministic meaning. This is a name-resolution rule, not a judgment about whether an abstraction is tasteful.

Explicit overloading has many advantages:

- Explicitness of what is overloaded
- Able to refer to the specific procedure if needed
- Clear which scope the entity name belongs to
- Ability to specialize parametric polymorphic procedures if necessary, which have the same parameter but different bounds (see where clauses)
- A direct named form for debugging or disambiguating method and operator calls

```odin
foo :: proc{
	foo_bar,
	foo_baz,
	foo_baz2,
	another_thing_entirely,
}
```

# Basic types

Odin’s basic types are:

bool b8 b16 b32 b64

`bool` is the ordinary logical type. The explicitly sized boolean types exist for data layout and foreign interoperability; whether they all remain necessary is recorded under [Open questions](#sized-boolean-types).

```odin
// integers
int  i8 i16 i32 i64 i128
uint u8 u16 u32 u64 u128 uintptr

// endian specific integers
i16le i32le i64le i128le u16le u32le u64le u128le // little endian
i16be i32be i64be i128be u16be u32be u64be u128be // big endian
```

f16 f32 f64 // floating point numbers

```odin
// endian specific floating point numbers
f16le f32le f64le // little endian
f16be f32be f64be // big endian
```

Complex and quaternion numbers are not primitive types. Libraries implement them as ordinary structs with operator overloads, conversions, formatting, and generic algorithms. The base language does not reserve names or provide special promotion rules for them.

```odin
rune // signed 32 bit integer
	 // represents a Unicode code point
	 // is a distinct type to `i32`
     // give up handle multi code point symbols, it's an deep rabit hole.

// text
string  // immutable, valid UTF-8
cstring // immutable, zero-terminated C interoperability value

// raw pointer type
rawptr

// runtime type information specific type
typeid
any
```

The uintptr type is pointer sized, and the int, uint types are the “natural” register size, which is guaranteed to greater than or equal to the size of a pointer (i.e. size_of(uint) >= size_of(uintptr)). When you need an integer value, you should default to using int unless you have a specific reason to use a sized or unsigned integer type

Note: The exact `string` representation is implementation-defined, but byte length is available in O(1). `cstring` is the explicit zero-terminated form used for C interoperability.

## Zero values

Variables declared without an explicit initial value are given their zero value.

The zero value is:

- 0 for numeric and rune types
- false for boolean types
- "" (the empty string) for strings
- nil for pointer, typeid, and any types.

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

# Cast operator

The cast operator can also be used to do the same thing:

```odin
i := 123;
f := cast(f64)i;
u := cast(u32)f;
```

This is useful in some contexts but has the same semantic meaning.

# Transmute operator

The transmute operator is a bit cast conversion between two types of the same size:

```odin
f := f32(123);
u := transmute(u32)f;
```

This is akin to doing the following pointer cast manipulations:

```odin
f := f32(123);
u := (^u32)(&f)^;
```

However, transmute does not require taking the address of the value in question, which may not be possible for many expressions.

# Untyped types

In the type system, certain expressions will have an “untyped” type. An untyped type can implicitly convert to a “typed” type.

```odin
I :: 42;        // untyped integer, implicitly converts to a built-in numeric type that can represent it
F :: 1.37;      // untyped float, implicitly converts to a built-in numeric type that can represent it
S :: "Hellope"; // untyped string,  will implicitly convert to string and cstring
B :: true;      // untyped boolean, will implicitly convert to bool, b8, b16, etc.
```

(The more formal name for these “untyped” types is existential or abstract types.)

## Auto-cast operation

The auto_cast operator automatically casts an expression to the destination’s type if possible:

```odin
x: f32 = 123;
y: int = auto_cast x;
```

Note: This operation is only recommended to be used for prototyping and quick tests. Please do not abuse it.

### Built-in constants, values, and procedures

There are a few built-in constants and values which have different uses:

```text
false // untyped boolean constant equivalent to the expression 0!=0
true  // untyped boolean constant equivalent to the expression 0==0
nil   // untyped nil value used for certain values
---   // untyped undefined value used to explicitly not initialize a variable
```

--- is useful if you want to explicitly not initialize a variable with any default value:

```odin
x: int; // initialized with its zero value
y: int = ---; // uses uninitialized memory
```

This is the default behaviour in C, whilst the default behaviour here is to zero the memory.

Note: --- is not a contract in that all memory is uninitialized, but that it may be. For example, as a side-effect of an implementation detail, padding in a struct must be zeroed to permit trivial bitwise memory comparison.

# Built-in procedures

For the full list of builtin-procedures, see the documentation for package builtin.

There are two kinds of built-in procedures:

- Compiler defined
- Core library defined

# string type

`string` is an immutable, owning UTF-8 value. It behaves like a simple local variable: it can be assigned, returned, and stored without requiring `make`, `delete`, or `defer`.

```odin
first := "hello";
second := first; // cheap value copy; immutable backing storage may be shared
message := first + " world";
```

A string literal uses static storage. A string created at runtime owns a managed backing buffer. Implementations may use reference counting, small-string optimization, interning, or another representation, but these choices do not change language semantics. Because strings are immutable, sharing their backing storage is never observable as mutable aliasing.

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

String iteration yields Unicode scalar values by default. Byte iteration is explicit:

```odin
// by runes
x := "ABC";
for (codepoint, index in x) {
	fmt.println(index, codepoint);
	// 0 A
	// 1 B
	// 2 C
}

// by bytes
for (byte, index in x.bytes()) {
	fmt.println(index, byte);
	// 0 65
	// 1 66
	// 2 67
}
```

String indices used by low-level APIs are byte offsets. Unicode procedures that operate on runes or grapheme clusters state that unit in their names.

## String format printing

The core:fmt library supports printing strings from byte arrays in structs, when additional tag information is supplied.

User-defined types can provide a visible `format(value, writer, options)` overload. Formatting procedures are ordinary overloads and can be called directly when custom formatting syntax would be unclear.

```odin
Foo :: struct {
	a: [L]u8 `fmt:"s"`, // whole buffer is a string
	b: [N]u8 `fmt:"s,0"`, // 0 terminated string
	c: [M]u8 `fmt:"q,n"`, // string with length determined by n, and use %q rather than %s
	n: int `fmt:"-"`, // ignore this from formatting
}
```

# cstring type

`cstring` is an immutable, valid-UTF-8, zero-terminated, managed value for C interoperability. A literal can use static storage. Converting a runtime string allocates only when a trailing zero is not already available, and the resulting value is cleaned up automatically.

`cstring_view` is a non-owning, zero-terminated view of bytes received from foreign code — the type a C `char const *` maps to. It is a borrow with no known owner, so the compiler cannot check its validity; keeping it alive for as long as it is used is the programmer's responsibility, as with anything crossing the [foreign boundary](#what-is-not-checked). Converting a view to `string` scans for the terminator, validates UTF-8, and creates an owned string, which is the safe thing to do with it promptly. Aliasing conversions that skip the copy live in the [`unsafe` package](#the-unsafe-package).

```odin
str:  string  = "Hellope";
cstr: cstring = "Hellope"; // constant literal
cstr2 := str.to_cstring(); // managed runtime conversion
text2 := string(cstr);     // validates and creates an owned string
nstr  := len(str);  // O(1)
ncstr := len(cstr); // O(n)
```

Foreign calls may use a temporary conversion directly. The temporary remains valid for the complete call:

```odin
c_api(str.to_cstring());
```

# string type conversions

Safe conversions return managed values or explicitly borrowed views. They never hide a mutable alias.

`string_view` is an immutable, validated UTF-8 borrow represented by a pointer and a byte length. It has the same byte, rune, and iteration operations as `string`, but it has no allocator and does not own or terminate its storage. A `string_view` derived from a slice is a borrow of that slice's owner and cannot outlive it. Creating one from a pointer whose owner the compiler cannot identify requires `unsafe.string_view`.

A conversion that validates input has **optional-ok semantics**: it produces `(value, ok: bool)`. On invalid input, `value` is the zero value and `ok` is false. It can be handled with the comma-ok form or with `or_else`; postfix `?` is not a conversion or error-propagation operator.

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

There is no `const` qualifier in the language. Borrows are immutable unless declared `inout`, so a view obtained from a `string` — which is immutable to begin with — is read-only by construction and needs no annotation.

## From string to X

| To | Action | Code |
| --- | --- | --- |
| `[]u8` | borrow | `st.bytes()` |
| `string` | share | `new_string := st` |
| `string` | copy | `st.clone()` |
| `cstring` | copy | `st.to_cstring()` |
| `[]rune` | stream | `for (rune in st) { ... }` |
| `[dynamic]rune` | copy | `st.to_runes()` |
| `[^]u8` | borrow | `raw_data(st.bytes())` |

## From cstring to X

| To | Action | Code |
| --- | --- | --- |
| `string` | copy/share | `string(st)` |
| `[^]u8` | borrow | `raw_data(st)` |

## From a string literal to X

| To | Action | Code |
| --- | --- | --- |
| `string` | share static storage | `newstr: string = st` |
| `cstring` | share static storage | `newstr: cstring = st` |

## From []u8 to X

| To | Action | Code |
| --- | --- | --- |
| `string` | validate and copy, optional-ok | `string(st)` |
| `string_view` | validate and borrow, optional-ok | `string_view(st)` |
| `[^]u8` | borrow | `raw_data(st)` |

## From []rune to string

| Action | Code |
| --- | --- |
| validate and copy, optional-ok | `string.from_runes(st)` |

## From [^]u8 to cstring

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
+       sum                        integers, enums, floats, arrays of numeric types, constant strings
-       subtraction                integers, enums, floats, arrays of numeric types
*       multiplication             integers, floats, arrays of numeric types
/       division                   integers, floats, arrays of numeric types
%       modulo (truncated)         integers
%%      remainder (floored)        integers

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

- Boolean values are comparable.
- Integers values are comparable and ordered.
- Floating-point values are comparable and ordered, defined by the IEEE-754 standard.
- Rune values are comparable and ordered.
- String values are comparable and ordered, lexically byte-wise.
- Pointer values are comparable and ordered.
- Multi-pointer values are comparable and ordered.
- Enum values are comparable and ordered.
- Bit-set values are comparable.
- Struct values are comparable if all their fields are comparable or a visible comparison overload is provided.
- Union values are comparable if all their variants are comparable or a visible comparison overload is provided.
- Array and enumerated array values are comparable if values of the element type are comparable.
- typeid is comparable.
- Simd vectors are comparable.

Bit-set values use different logic compared to integers when comparison operators are used: please see the section of bit sets

## Logical operators

Logical operators apply to boolean values. The right operand is evaluated conditionally

```text
&&      conditional AND    a && b  is "b if a else false"
||      conditional OR     a || b  is "true if a else b"
!       NOT                !a      is "not a"
```

## Compound binary operator and assign

Like many other languages, there is a shorthand for performing a binary operation and assigning the result to the first operand e.g. x = x + 5. All arithmetic and logical binary operators have this shorthand

```text
+=       sum and assign                   a += b is a = a + b
-=       subtraction and assign           a -= b is a = a - b
*=       multiplication and assign        a *= b is a = a * b
/=       division and assign              a /= b is a = a / b
%=       modulo (truncated) and assign    a %= b is a = a % b
%%=      remainder (floored) and assign   a %%= b is a = a %% b

|=       bitwise or and assign            a |= b is a = a | b
~=       bitwise xor and assign           a ~= b is a = a ~ b
&=       bitwise and and assign           a &= b is a = a & b
&~=      bitwise and-not and assign       a &~= b is a = a &~ b
<<=      left shift and assign            a <<= b is a = a << b
>>=      right shift and assign           a >>= b is a = a >> b

&&=      conditional AND and assign       a &&= b is a = a && b
||=      conditional OR and assign        a ||= b is a = a || b
```

## Address operator

For an operand x of type T, the address operation &x generates a pointer of ^T to x. The operand must be addressable, meaning that either a variable, pointer indirection, or slice/dynamic array indexing operator; or a field selector of an addressable struct operand; or an array index operation of an addressable array; or a type assertion of an addressable union or any; or a compound literal value.

For an operand x of pointer type ^T, the pointer indirection x^ denotes the variable of type T pointed to by x. If x is an invalid address, such as nil, an attempt to evaluate x^ will result in platform specific behaviour - on most platforms this will be a segmentation fault.

```odin
&x;
&a[foo(123)];
&Foo{1, 2};
p^;
pproc(a)^;

x: ^int = nil;
x^;      // causes a runtime panic
```

## Ternary operators

```odin
x if cond else y;    // ternary runtime conditional expression
x when cond else y;  // ternary compile-time conditional expression
cond ? x : y;        // equivalent to "x if cond else y"
```

## Other operators

- or_else
        see section on or_else
- or_return
        see section on or_return
- in - set membership (e in A, A contains element e)
        Used for bit_set types and map types
- not_in - not set membership (e not_in A, A does not contain e)
        Used for bit_set types and map types
- ..= - inclusive range
- ..< - half open range

The range operations ..= and ..< are only possible within certain contexts:

```odin
for (x in a..<b) {}
for (x in a..=b) {}

switch (x) {
case a..<b:
case c..=d:
}
```

bit_set[a..<b]
bit_set[a..=b]

```odin
foo := [?]int{0..=3 = 1}; // initialises as: [1, 1, 1, 1]
bar := [?]int{0 = 0, 1..<3 = 1}; // initialises as: [0, 1, 1]
```

Within a `for` header, `in` introduces range iteration. Use a boolean-producing expression or procedure call for a condition-only loop:

```odin
for (x in y) {}    // range loop
for (contains(y, x)) {}  // condition-only loop
```

## Operator precedence

Unary operators have the highest precedence.

There are seven precedence levels for binary (and ternary) operators.

```text
Precedence    Operator
     7           *   /   %   %%   &   &~  <<   >>
     6           +   -   |   ~    in  not_in
     5           ==  !=  <   >    <=  >=
     4           &&
     3           ||
     2           ..=    ..<
     1           or_else     ?    if  when
```

Binary operators of the same precedence associate from left to right. For instance x / y * z is the same as (x / y) * z.

## Integer operators

For two integers values x and y, the integer quotient q = x/y and remainder r = x%y satisfies the following relationships:

```odin
x = q*y + r   and |r| < |y|;
```

with x/y truncated towards zero (truncated division).

For two integers values x and y, the integer quotient q = x/y and remainder r = x%%y satisfies the following relationships:

```odin
r = x - y*floor(x/y);
```

The exception to these rules are when the dividend x is the most non-negative value for the integer type of x, and the quotient q = x/-1 is equal to x (and r or m = 0) due to two’s complement integer overflow.

If the divisor is a constant, it must not be zero. If the divisor is zero at runtime, a runtime panic occurs.

The shift operators shift the left operand by the shift count specified by the right operand, which must be non-negative. The shift operators implement arithmetic shifts if the left operand is a signed integer and logical shifts if the left operand is an unsigned integer. There is not an upper limit on the shift count. Shifts behave as if the left operand is shifted n times by 1 for a shift count of n. Therefore, x<<1 is the same as x*2 and x>>1 is the same as x/2 but truncated towards negative infinity.

```odin
// These are equivalent:
x << y;
x << y if y < 8*size_of(x) else 0;

x >> y;
x >> y if y < 8*size_of(x) else 0;
```

### Integer overflow

For unsigned integers, the operations +, -, *, and << are computed modulo 2n, where n is the bit width of the unsigned integer’s type. In a sense, these unsigned integer operations discard the high bits upon overflow, and programs may rely on “wrap around”.

For signed integers, the operations +, -, *, /, and << may legally overflow and the resulting value exists and is deterministically defined by the signed integer representation. Overflow does not cause a runtime panic. A compiler may not optimize code under the assumption that overflow does not occur. For instance, x < x+1 may not be assumed to be always true.

## Floating-point operators

For floating-point types:

- +x is the same as x
- -x is the negation of x

The result of a floating-point related division by zero is not specified beyond the IEEE-754 standard; a runtime panic will occur.

An implementation may combine multiple floating-point operations into a single fused operation, and produce a result that differs from the value obtained by executing and rounding the instructions individually.

# User-defined abstractions

## Design principle

Users must be able to create types that are as convenient to use as built-in types. A vector should support arithmetic, a matrix should support indexing, a range should support iteration, and a resource-owning type should participate in automatic cleanup.

The language trusts programmers to choose abstractions that fit their domain. Operator overloading can be abused, just as procedures, macros, inheritance, generics, and pointer arithmetic can be abused. Preventing all questionable uses would also prevent many clear and useful programs. Readability is supported through lexical scoping, normal named forms, compiler diagnostics, documentation tools, and code review rather than through a blanket ban.

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

There is no orphan rule requiring either the type or the operation to come from the current package. Extension declarations participate only when their declaring name is visible through normal lexical scope and imports. If two equally good extensions are visible, the use is ambiguous and the programmer must call one by its qualified procedure name.

Field lookup takes priority over method-call sugar. Inherent and extension methods otherwise use normal overload resolution. Methods can be collected into explicit procedure groups just like free procedures.

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
| --- | --- |
| Unary | `+`, `-`, `!`, `~` |
| Arithmetic | `+`, `-`, `*`, `/`, `%`, `%%` |
| Bitwise and shifts | `|`, `~`, `&`, `&~`, `<<`, `>>` |
| Comparison | `==`, `!=`, `<`, `<=`, `>`, `>=` |
| Membership and ranges | `in`, `not_in`, `..=`, `..<` |
| Compound assignment | `+=`, `-=`, `*=`, `/=`, `%=`, `%%=`, `|=`, `~=`, `&=`, `&~=`, `<<=`, `>>=` |
| Structural syntax | `[]`, `[]=`, `[:]`, `()` |

`!=` falls back to `!(left == right)` when `==` is available and no more specific `!=` overload exists. A compound assignment falls back to the corresponding binary operator followed by ordinary assignment. A direct compound overload can avoid a temporary or allocation:

```odin
impl Big_Int {
	add_assign :: operator(+=) proc(left: inout Big_Int, right: Big_Int) {
		left.add_in_place(right);
	}
}
```

Assignment (`=`), declaration (`:=`), member access (`.`), address-of, pointer dereference, `move`, and `drop` are not ordinary overloadable operators. They are tied to storage and lifetime rules; user-defined value behavior is provided by the lifecycle hooks described below.

`&&`, `||`, `or_else`, and the ternary operators control whether an operand is evaluated. They are not ordinary eager procedure calls and are not overloadable until the language has a general model for lazy parameters. This preserves their evaluation contract rather than restricting domain-specific abstractions.

## Operator lookup and overload resolution

Operator lookup considers built-in operations, inherent implementations, and visible extension implementations. Operators may be defined for any operand types, including types from other packages and built-in types. No special restriction requires a locally declared operand.

Lexical scope is considered before type ranking, so a local or explicitly imported operator set can shadow an outer one for the types it covers.

**Built-in operations cannot be shadowed.** If every operand of an expression is a built-in type, the built-in operation always wins, regardless of what is in scope. `a + b` on two `int`s means integer addition in every file of every program.

This is a deliberate limit on an otherwise permissive feature. The argument for operator overloading is that a domain type should read like a built-in one; that argument does not extend to making the built-in types themselves read differently depending on which imports happen to be above the cursor. Redefining arithmetic on primitives is the one use that cannot be made locally reviewable, because the reader cannot tell from the expression that anything unusual is in play. Domain behavior on primitives should use a `distinct` type, which is cheap and makes the intent visible at the declaration:

```odin
Meters :: distinct f64;

impl Meters {
	add :: operator(+) proc(left, right: Meters) -> Meters { ... }
}
```

The named procedure remains available when shadowing between two user-defined operator sets would otherwise be unclear.

Candidates are ranked using the same rules as named procedure overloads:

1. Exact type and parameter-mode matches.
2. Borrow and mutability adjustments that do not create a value.
3. Built-in lossless conversions.
4. One user-declared implicit conversion per argument.
5. Parametric candidates whose constraints are satisfied.

Return type may help check a candidate against an already-known destination type, but procedures cannot be overloaded by return type alone. Two candidates with the same best rank produce a compile-time ambiguity. The compiler diagnostic must list every viable candidate and the conversions each one requires.

The compiler and language server should provide a **show desugaring** action that displays the selected named procedure for a method, operator, conversion, index, or iteration expression. This makes powerful abstractions inspectable without weakening them.

## Indexing, slicing, and callable values

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

`operator([:])` defines slicing. It must return either an owning value or a borrow derived from the receiver, in which case the result is treated as a borrow of the receiver under [Borrows and lifetimes](#borrows-and-lifetimes) — the same treatment a built-in slice expression gets. `operator(())` makes a value callable:

```odin
impl Polynomial {
	evaluate :: operator(()) proc(self: Polynomial, x: f64) -> f64 {
		...
	}
}

y := polynomial(2.5);
```

Bounds checking remains the responsibility of the overload. Libraries may provide checked and unchecked types, and compiler tooling may warn about unchecked implementations without rejecting them.

## Iteration protocol

Iteration uses ordinary methods rather than a special privileged container representation. A value is iterable when `iter(value)` returns an iterator with a compatible `next` method.

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
	next :: proc(self: inout Countdown_Iterator) -> Maybe(int) {
		if (self.current <= 0) {
			return nil;
		}
		value := self.current;
		self.current -= 1;
		return value;
	}
}

for (value in Countdown{3}) {
	fmt.println(value);
}
```

`next_ref` may return `Maybe(inout T)` to support `for (&value in collection)`. `iter_reverse` supports reverse iteration. An iterator obtained from a collection is a borrow of that collection, so mutating the collection while iterating it is rejected by the rules in [Borrows and lifetimes](#borrows-and-lifetimes).

## Construction and conversions

Struct literals remain the simplest construction mechanism. An `init` overload provides validated, computed, or overloaded construction through type-call syntax:

```odin
impl Vector2 {
	init :: proc(x, y: f32) -> Vector2 {
		return {x, y};
	}

	init :: proc(value: f32) -> Vector2 {
		return {value, value};
	}
}

a := Vector2(1, 2);
b := Vector2(5);
```

A procedure marked `@(conversion)` participates in explicit `Target(value)` conversion. Adding `@(implicit)` also permits it during overload resolution, assignment, return, and argument passing:

```odin
Meters :: distinct f64;
Kilometers :: distinct f64;

impl Meters {
	@(conversion)
	to_kilometers :: proc(value: Meters) -> Kilometers {
		return Kilometers(f64(value) / 1000.0);
	}
}

distance_m := Meters(1500);
distance_k := Kilometers(distance_m); // explicit user conversion
```

### Resolving `T(...)`

The form `T(...)` has three possible meanings — a built-in conversion, an `init` construction, and a user `@(conversion)` — so the language fixes one resolution order for all of them:

1. **Built-in conversion.** If `T` is a built-in or `distinct` type and exactly one argument is given whose type has a built-in conversion to `T`, that conversion is used. This case is decided first and cannot be overridden, for the same reason built-in operators cannot be shadowed: `int(x)` must not change meaning based on imports.
2. **`init` overloads.** Otherwise, visible `init` overloads for `T` are considered using ordinary overload resolution, including the zero-argument and multi-argument forms.
3. **User conversions.** Otherwise, visible procedures marked `@(conversion)` whose return type is `T` are considered. Conversion lookup examines the source type, target type, and visible extensions.

Resolution stops at the first stage that produces a match. Within a stage, equal-ranked matches are ambiguous rather than being selected by declaration order, and the diagnostic must list the candidates from that stage only.

A consequence worth stating plainly: a single-argument `init` on a `distinct` type over a built-in cannot be reached through `T(x)` when `x` is of the underlying type, because stage 1 claims it. Call it by name, or give it a distinguishing parameter. This is the cost of keeping casts unambiguous, and it is the intended trade.

Programmers may mark narrowing or expensive conversions as implicit if that is appropriate for their domain. The compiler may warn, and projects may elevate that warning to an error, but the language permits it. At most one user-defined implicit conversion is applied to each argument during a single overload resolution step; longer conversion chains must be written explicitly so lookup remains finite and deterministic.

## Lifecycle hooks and resource types

User-defined records receive field-wise `clone`, `move`, and `drop` behavior by default. An `impl` block may replace `clone` or `drop` for a type that owns a resource.

```odin
File :: struct {
	handle: os.Handle,
}

impl File {
	clone :: delete;

	drop :: proc(self: inout File) {
		if (self.handle != os.invalid_handle) {
			os.close(self.handle);
			self.handle = os.invalid_handle;
		}
	}
}
```

`Name :: delete;` disables a compiler-generated operation, making `File` move-only. No signature is written, because the signature of a lifecycle hook is fixed by the type. `move(value)` remains a compiler primitive: it transfers the representation and resets the source to its zero state. `drop(value)` invokes the user hook when present and then resets the value. Fields are dropped in reverse declaration order after the containing type's drop hook returns.

Copy assignment of a copyable user type behaves conceptually as follows, with self-assignment handled by the compiler:

```odin
temporary := source.clone();
drop(destination);
destination = move(temporary);
```

An explicit `try_clone` may return an allocation error. Ordinary assignment uses `clone` and follows the active allocator's failure policy described under [Allocation failure](#allocation-failure).

## Concepts and generic operators

A `concept` names a compile-time structural requirement. A type satisfies a concept when every requirement in its body holds; no separate `implements` declaration is required.

```odin
Additive :: concept($T: typeid) {
	T(0) -> T;
	T + T -> T;
}

sum :: proc(values: []$T) -> T
	where Additive(T) {
	result := T(0);
	for (value in values) {
		result += value;
	}
	return result;
}
```

### Concept bodies

A concept body is a semicolon-terminated list of requirements. There are exactly three forms:

```
requirement := expression "->" type ";"      // expression form
             | expression ";"                // validity form
             | "const" identifier ":" type ";"  // associated constant form
```

**Expression form** — `expr -> Type;` requires that `expr` compiles for the concept's parameters and that its result is convertible to `Type`. Within a concept body, a type name used where a value is expected denotes *some value of that type*, not the typeid itself. So `T + T -> T` reads "adding two values of `T` is valid and yields something convertible to `T`", and `T(0) -> T` requires construction from the literal `0`.

**Validity form** — `expr;` requires only that the expression compiles, with no constraint on its result type.

**Associated constant form** — `const NAME: Type;` requires a constant of that name and type in the type's `impl` block.

Method and operator requirements are written as ordinary calls on values of the parameter types. Lifecycle requirements name the hook:

```odin
Container :: concept($T: typeid, $Element: typeid) {
	len(T) -> int;
	T[int] -> Element;
	iter(T);
	const ZERO: Element;
}

Cloneable :: concept($T: typeid) {
	T.clone() -> T;
}
```

Concepts compose by naming one another, and a concept used as a value in `where` is a compile-time boolean:

```odin
Ordered :: concept($T: typeid) {
	Equatable(T);
	T < T -> bool;
}
```

Requirement checking is non-recursive at the point of use: the compiler checks that each listed requirement holds for the concrete arguments, and does not attempt to prove requirements about types that do not yet exist. Concepts constrain static polymorphism only; runtime interfaces and dynamic dispatch are separate features.

A failed requirement must be reported as the specific line of the concept body that did not hold, together with the concrete type that failed it. A concept that reports only "constraint not satisfied" is a defect in the implementation.

Standard library concepts should remain small and composable, for example `Equatable`, `Ordered`, `Hashable`, `Iterable(T)`, `Cloneable`, and `Formattable`. Maps require compatible `==` and `hash` operations for their key type. The compiler checks that both operations exist but trusts the programmer to preserve the semantic rule that equal values produce equal hashes.

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
| `clone(value, using allocator)` | Explicit independent copy |

These procedures use normal overload groups and can also be called through method syntax when they have a receiver. Libraries are free to define additional protocols without compiler support.

## Library numeric types

Complex numbers and quaternions are standard-library abstractions rather than base-language types. They use the same structs, methods, operators, conversions, concepts, and formatting hooks available to every program. This is an intentional test of the abstraction model: a user-defined numeric type should not need compiler privileges to feel natural.

For example, a library can define a complex type entirely in ordinary code:

```odin
Complex_F64 :: struct {
	real, imaginary: f64,
}

impl Complex_F64 {
	init :: proc(real: f64, imaginary: f64 = 0) -> Complex_F64 {
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

	@(conversion)
	@(implicit)
	from_scalar :: proc(value: f64) -> Complex_F64 {
		return {value, 0};
	}
}

z := Complex_F64(1, 2);
w := z*z + 2.0;
```

The standard library may offer generic `Complex(T)` and `Quaternion(T)` families and concepts for their supported scalar types, but these declarations have no special relationship with the compiler. Scalar promotion is provided by visible `@(implicit)` conversions. Equality, arithmetic, conjugation, norms, parsing, and formatting are ordinary overloads or procedures. Matrix support for these scalar domains is likewise a library abstraction rather than a built-in matrix rule.

The same facilities must be sufficient for third-party fixed-point, decimal, rational, dual, interval, unit-aware, SIMD, and domain-specific numeric types. Standard-library implementations should be readable examples, not compiler intrinsics disguised as library code.

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

A distinct type may define its own methods, operators, constructors, conversions, concepts, formatting, and lifecycle hooks. It does not inherit the underlying type's user-defined overloads unless they are explicitly re-exported or delegated.

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
for (i in 0..=4) {
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
y := grid[1, 2];      // 6: shorthand for grid[1][2]
```

Nested fixed arrays are one contiguous value; they are not arrays of pointers. Their layout is row-major in declaration order, with the rightmost index varying fastest. For `a: [D0][D1]...[Dn]T`, the scalar elements of `a[0]` precede those of `a[1]`. In two dimensions, `a[row, column]` has the flat element offset `row*Columns + column`.

Built-in indexing accepts a comma-separated index list. For nested fixed arrays, slices, or dynamic arrays, indices are applied from left to right, so `a[i, j, k]` is exactly equivalent to `a[i][j][k]`. Every index expression is evaluated once from left to right, and each indexing step performs its normal bounds check. It is a compile-time error if an intermediate value is not indexable.

Only nested fixed arrays have the single contiguous layout described above. `[][]T` is a slice of slices and `[dynamic][dynamic]T` is a dynamic array of independently managed dynamic arrays; their inner containers may have different lengths and, for dynamic arrays, separate allocations. They are therefore potentially jagged. Comma indexing is still only shorthand and does not make them rectangular or contiguous.

This equivalence applies only to built-in nested containers. For a user-defined type, `value[i, j]` is one call to a visible `operator([])` accepting two indices, whereas `value[i][j]` performs two separate indexing operations. This lets a library implement rectangular, column-major, strided, sparse, or otherwise specialized storage without pretending that it is a nested array.

The base language has no `matrix` keyword or built-in matrix type and assigns no mathematical meaning to multidimensional arrays. Array programming remains component-wise and applies recursively to compatible nested arrays. A rectangular dynamically sized container should be a library type containing one flat `[dynamic]T`, its dimensions, and an `operator([])` for multi-index access. Matrix multiplication, transposition, determinants, scalar-as-identity conversions, and shape-changing operations likewise belong in math libraries implemented with generic structs, concepts, and operators.

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

Array access is bounds checked by default, both at compile-time (with constant indices) and at runtime. This can be disabled and enabled at a per block level with the #no_bounds_check and #bounds_check directives, respectively:

```odin
#no_bounds_check {
	x[n] = 123; // n could be in or out of range of valid indices
}
```

`#no_bounds_check` can be used to improve performance when the bounds are known not to be exceeded.

### Array programming

Loke’s fixed-length arrays support component-wise array programming.

Example:

```odin
Vector3 :: [3]f32;
a := Vector3{1, 4, 9};
b := Vector3{2, 4, 8};
c := a + b;  // {3, 8, 17}
d := a * b;  // {2, 16, 72}
e := c != d; // true
```

### `swizzle` procedure

The `swizzle` procedure constructs an array by selecting elements with compile-time indices. Arrays do not have implicit `.xyzw` or `.rgba` fields; vector libraries may provide named access on their own types.

```odin
a := [3]f32{10, 20, 30};
b := swizzle(a, 2, 1, 0);
assert(b == [3]f32{30, 20, 10});

c := swizzle(a, 0, 0);
assert(c == [2]f32{10, 10});
assert(c == 10); // assert all elements == 10
```

## Slices

Slices look similar to arrays however, their length is not known at compile time. The type []T is a slice with elements of type T. In practice, slices are much more common than arrays.

A slice is formed by specifying two indices, a low and high bound, separated by a colon:

a[low : high]

This selects a half-open range which includes the lower element, but excludes the higher element.

```odin
fibonaccis := [6]int{0, 1, 1, 2, 3, 5};
s: []int = fibonaccis[1:4]; // creates a slice which includes elements 1 through 3
fmt.println(s); // 1, 1, 2
```

Slices do not store any data; they describe a section of data owned by something else. Internally, a slice stores a pointer to the data and an integer length.

**A slice is a borrow.** It is not an owning value: it has no allocator, it is never cleaned up at scope exit, and it cannot be a `manual` owner. Creating a slice over a dynamic array or map therefore constrains that container for as long as the slice is live, and the rules in [Borrows and lifetimes](#borrows-and-lifetimes) apply in full:

```odin
numbers := [dynamic]int{1, 2, 3};
view := numbers[:];
numbers.append(4);   // ERROR: `numbers` may reallocate while `view` is live
fmt.println(view[0]);
```

A slice over a fixed array is a borrow of that array's storage, and so is bound by the array's scope in the same way. A slice over a string literal borrows static storage and is therefore valid for the whole program.

To keep the data past the owner's lifetime, take an owned copy: `slice.clone(view)` produces a `[dynamic]T` you own.

The built-in len proc returns the slice’s length.

```odin
x: []int = ...;
length_of_x := len(x);
```

### Slice literals

A slice literal is like an array literal without the length. This is an array literal:

[3]int{1, 6, 3}

This is a slice literal which creates the same array as above, and then creates a slice that references it:

[]int{1, 6, 3}

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

A slice literal can be sorted in ascending order as follows:

```odin
s := []int{1, 6, 3, 5 ,7, 3, 0};
slice.sort(s);
```

or in descending order

```odin
r := []int{1, 6, 3, 5 ,7, 3, 0};
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

The allocator used by a managed dynamic array is stored with its allocation so automatic cleanup always uses the correct allocator. A declaration may select another allocator without becoming manual:

```odin
temporary: [dynamic]u8 using context.temp_allocator;
```

Copy initialization uses the allocator active at the declaration. Assignment into an existing array preserves the destination's allocator policy. `move` transfers both the allocation and its allocator. `clone(using allocator)` is available when a specific allocator is required.

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

### Inject / Assign to a dynamic array

`insert` adds an element and shifts later elements upwards. Its index must be in `0..=len(x)`. Ordinary indexed assignment never changes the length.

`set_grow` is the explicit operation for assigning beyond the current end. It grows the array and zero-initializes any skipped elements. Keeping this behavior separate prevents a misspelled index from silently resizing an array.

```odin
x: [dynamic]int;
x.reserve(16);
x.insert(0, 10);
x.set_grow(3, 10); // grows to length 4
fmt.eprintln(x[:], len(x), cap(x)); // [10, 0, 0, 10] 4 16
x[3] = 20;
x.set_grow(4, 30);
fmt.eprintln(x[:], len(x), cap(x)); // [10, 0, 0, 20, 30] 5, 16
x.append(40, 50, 60);
fmt.eprintln(x[:], len(x), cap(x)); // [10, 0, 0, 20, 30, 40, 50, 60] 8 16
```

### Removing from a dynamic array

Removing from a dynamic array can be done in several ways using the built-in procedures:

- `pop` removes and returns the last element as `Maybe(T)`.
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
temporary: [dynamic]int using context.temp_allocator;
temporary.reserve(64);
```

`drop` releases a managed value early and resets it to its zero value. Normal code can simply let scope cleanup perform the same operation.

```odin
drop(b);
assert(len(b) == 0);
```

Low-level code may opt out with `manual` and use `make` and `delete`. A `manual` value cannot be implicitly assigned to a managed owner, because that would silently move a lifetime the programmer had taken responsibility for. The transfer must be written with `move`, which is the same primitive used everywhere else ownership changes hands:

```odin
raw: manual [dynamic]int = make([dynamic]int, 0, 64, my_allocator);
owned := move(raw); // `owned` is managed; `raw` becomes empty and needs no `delete`
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

### [dynamic; N]T fixed capacity dynamic array

Loke supports a fixed capacity dynamic array [dynamic; N]T. It implements most dynamic array procedures while being able to remain on the stack.

Short Example:

```odin
x: [dynamic; 8]int;
fmt.println(len(x), cap(x)); // 0 8
x.append(1, 2, 3);
fmt.println(len(x), cap(x)); // 3 8
fmt.println(x[:]); // [1, 2, 3]
```

n.b. This replaces the core library container dynamic array Small_Array(N, T).

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

using can also be used with an enumeration to bring the fields into the current scope:

```odin
main :: proc() {
	Foo :: enum {A, B, C};
	using Foo;
	a := A;

	
}
```

Note: Implicit selector expression is preferred to using an enumeration as using does pollute the current scope.

### Iterating an Enumeration

Enums can be trivially for looped in odin. This way we can loop through the entire enum and do things like printing or inserting into an Enumerated Array.

```odin
Direction :: enum{North, East, South, West};

for (direction, index in Direction) {
	fmt.println(index, direction);
	// 0 North
	// 1 East
	// 2 South
	// 3 West
}
```

### Enumerated Array

Enumerated Arrays allow the use of an Enum to be used as indices to a fixed array.

We’ll extend the Direction enum used previously to add direction vectors.

```odin
Direction :: enum{North, East, South, West};

Direction_Vectors :: [Direction][2]int {
	.North = {  0, -1 },
	.East = { +1,  0 },
	.South = {  0, +1 },
	.West = { -1,  0 },
}

assert(Direction_Vectors[.North] == { 0, -1 });
assert(Direction_Vectors[.East] == { 1, 0 });
assert(Direction_Vectors[cast(Direction) 2] == { 0, 1 });
```

The #partial directive can be used to initialize an enumerated array partially.

The #sparse directive can be used to initialize an enumerated array with an Enum which does not have contiguous values.

```odin
arr: [enum {A, B, C}]int;
arr = #partial { // without partial the compiler would complain
	.A = 42,
}
fmt.println(arr); // [.A = 42, .B = 0, .C = 0]
```

## Bit sets

The bit_set type models the mathematical notion of a set. A bit_set’s element type can be either an enumeration or a range:

```odin
Direction :: enum{North, East, South, West};

Direction_Set :: bit_set[Direction];

Char_Set :: bit_set['A'..='Z'];

Number_Set :: bit_set[0..<10]; // bit_set[0..=9]
```

Bit sets are implemented as bit vectors internally for high performance. The zero value of a bit set is either nil or {}.

```odin
x: Char_Set;
x = {'A', 'B', 'Y'};
y: Direction_Set;
y = {.North, .West};
```

Bit sets support the following operations:

- A + B - union of two sets (equivalent to A | B)
- A - B - difference of two sets (A without B’s elements) (equivalent to A &~ B)
- A & B - intersection of two sets
- A | B - union of two sets (equivalent to A + B)
- A &~ B - difference of two sets (A without B’s elements) (equivalent to A - B)
- A ~ B - symmetric difference (Elements that are in A and B but not both)
- A == B - set equality
- A != B - set inequality
- A <= B - subset relation (A is a subset of B or equal to B)
- A < B - strict subset relation (A is a proper subset of B)
- A >= B - superset relation (A is a superset of B or equal to B)
- A > B - strict superset relation (A is a proper superset of B)
- e in A - set membership (A contains element e)
- e not_in A - not set membership (A does not contain element e)

Bit sets are often used to denote flags. This is much cleaner than defining integer constants that need to be bitwise or-ed together.

If a bit set requires a specific size, the underlying integer type can be specified:

```odin
Char_Set :: bit_set['A'..='Z'; u64];
#assert(size_of(Char_Set) == size_of(u64));
```

To get the number of elements set, its cardinality, of a bit_set, use the built-in card procedure:

```odin
x: Direction_Set;
x = {.North, .West};
count := card(x);
assert(count == 2);
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

Note: Unlike C, Loke has no pointer arithmetic. If you need a form of pointer arithmetic, please use the ptr_offset and ptr_sub procedures in the "core:mem" package.

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

We could write p^.x, however, it is nice to not have to explicitly dereference the pointer. This is very useful when refactoring code to use a pointer rather than a value, and vice versa.

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

### Struct directives

Structs can be annotated with different memory layout and alignment requirements:

struct #align(4)           {...} // align to 4 bytes
struct #raw_union          {...} // all fields share the same offset (0). This is the same as C's union
struct #packed             {...} // remove padding between fields
struct #min_field_align(4) {...} // all fields must have a minimum alignment of 4 bytes (equivalent to `#pragma pack(4)` in C extensions)
struct #max_field_align(4) {...} // all fields must have a maximum alignment of 4 bytes
struct #simple             {...} // The struct's comparibleness is treated as if it can be `memcmp` and does not need any other special behaviour

### `#all_or_none`

The directive #all_or_none can be applied to a struct. This prevents partial initialization of the struct compound literal, by requiring it is either all or the fields are specified or none of the fields are specified.

```odin
Foo :: struct #all_or_none {
	a: int,
	b: int,
	c: int,
}

test :: proc() {
	// No fields set
	a := Foo{};

	// This is an error.
	b := Foo{
		a = 10,
	}

	// All fields set
	c := Foo{
		a = 10,
		b = 10,
		c = 10,
	}
}
```

### Struct field tags

Struct fields can be tagged with a string literal to attach meta-information which can be used with runtime-type information. Usually this is used to provide transactional information info on how a struct field is encoded to or decoded from another format, but you can store whatever you want within the string literal

```odin
User :: struct {
	flag: bool, // untagged field
	age:  int    "custom whatever information",
	name: string `json:"username" xml:"user-name" fmt:"q"`, // `core:reflect` layout
}
```

Within Odin’s core library, the standard convention is to store a key that denotes the package and then a subsequence "value". For example, json keys are processed and used by core:encoding/json package, fmt keys are processed by core:fmt.

If multiple information is to be passed in the "value", usually it is specified by separating it with a common (,), e.g.

name: string `json:"username,omitempty",

n.b. Field tags also exist for bit_field record types.

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

### Union tags

Applying the #no_nil tag to a union type states it does not have a nil value. Unions with #no_nil must have at least two variants and the first variant is its default type:

```odin
Value :: union #no_nil {bool, string};
v: Value;
_, ok := v.(bool);
assert(ok);
```

The #shared_nil tag normalizes each variant’s nil value into nil on assignment. If you assign nil or zero values to a union with #shared_nil the union will be nil. Unions with #shared_nil require all variants to have a nil value.

```odin
Error :: union #shared_nil {
	File_Error,
	Memory_Error,
}

File_Error :: enum {
	None = 0,
	File_Not_Found,
	Cannot_Open_File,
}

Memory_Error :: enum {
	None = 0,
	Allocation_Failed,
	Resize_Failed,
}

shared_nil_example :: proc() {
	an_error: Error;
	an_error = File_Error.None;

	assert(an_error == nil);
}
```

Unions also have the #align tag, like structures:

union #align(4) {...} // align to 4 bytes

## Maps

A map maps keys to values. Its zero value is empty and immediately usable. Like a dynamic array, a map is managed by default and releases its backing storage automatically.

Any type can be a map key when it provides compatible `==` and `hash(value, seed)` overloads. Built-in key types provide these automatically; user-defined key types satisfy the same structural `Equatable` and `Hashable` concepts.

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

Modifying existing map slots needs to be done in two steps. However assigning to a struct field is prohibited.

```odin
Test :: struct {
	x: int,
	y: int,
}

m := map[string]Test{
	"Bob" = { 0, 0 },
	"Chloe" = { 1, 1 },
}

value, ok := &m["Bob"];
if (ok) {
	value^ = { 2, 2 };
}

fmt.println(m["Bob"]); // { 2, 2 }
m["Bob"] = { 3, 3 };
fmt.println(m["Bob"]); // { 3, 3 }
m["Chloe"].x = 0; // PROHIBITED
```

### Map Container Calls

The built-in map also supports all the standard container calls that can be found with the dynamic array.

Short:

- len(some_map) returns the amount of slots used up
- cap(some_map) returns the capacity of the map - the map will reallocate when exceeded
- some_map.clear() removes all entries while retaining capacity
- some_map.reserve(capacity) reserves the requested element count
- some_map.shrink() reduces excess capacity

## Bit Fields

A bit_field is a record type akin to a bit-packed struct. Note: bit_field is not equivalent to bit_set as it has different semantics and use cases. bit_field fields are accessed by using a dot:

```odin
Foo :: bit_field u16 { // backing type must be an integer or array of integers
    x: i32     | 3, // signed integers will be signed extended on use
    y: u16     | 2 + 3, // general expressions
    z: My_Enum | foo.SOME_CONSTANT, // ability to define the bit-width elsewhere
    w: bool    | 2 when foo.SOME_CONSTANT > 10 else 1,
}

v := Foo{};
v.x = 3; // truncates the value to fit into 3 bits
fmt.println(v.x); // accessing will convert `v.x` to an `i32` and do an appropriate sign extension
```

A bit_field is different from a struct in that you must specify the backing type. This backing type must be an integer or a fixed-length array of integers. This is useful if there needs to be a specific alignment or access pattern for the record.

```odin
Foo :: bit_field u32 {...};
Foo :: bit_field [4]u8 {...};
```

Notes:

- If all of the fields in a bit_field are 1-bit in size and are a boolean, please consider using a bit_set instead.
- Odin’s bit_field and C’s bit-fields might not be compatible
        Odin’s bit_fields have a well defined layout (Least-Significant-Bit)
        C’s bit fields on structs are undefined and are not portable across targets and compilers

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

Loke supports the following calling conventions:

- loke - default convention used for a Loke proc. It may pass values larger than 16 bytes indirectly and passes an implicit context pointer on each call. Indirect passing is an ABI detail and does not change parameter ownership, mutability, address identity, or lifetime.
- contextless - This is the same as `loke` but without the implicit context pointer.
- stdcall or std – This is the stdcall convention as specified by Microsoft.
- cdecl or c – This is the default calling convention generated of a procedure in C.
- fastcall or fast - This is a compiler dependent calling convention.
- none - This is a compiler dependent calling convention which will do nothing to parameters.

Most calling conventions exist only to interface with foreign Windows code.

The default calling convention is `loke`, unless a declaration is within a foreign block, where it is `cdecl`.

A procedure type with a different calling convention can be declared like the following:

proc "c" (n: i32, data: rawptr)
proc "contextless" (s: []int)

Procedure types are only compatible with the procedures that have the same calling convention and parameter types.

When binding to C libraries you’ll often end up using proc "c" and also set the current context. For this you’ll need to explicitly set the context.

## typeid type

A typeid is a unique identifier for a type. This construct is used by the any type to denote what the underlying data’s type is.

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

## any Type

An any type can reference any data type. Internally it contains a pointer to the underlying data and its relevant typeid. This is a very useful construct in order to have a runtime type safe printing procedure.

Note: The any value is only valid for as long as the underlying data is still valid. Passing a literal to an any will allocate the literal in the current stack frame.

Note: It is highly recommended that you do not use this unless you know what you are doing. Its primary use is for printing procedures.

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

Interacting with Multi-Pointers is easiest using the builtin raw_data() call which can return a Multi-Pointer.

```odin
a: [^]int;
fmt.println(a); // <nil>
b := [?]int { 10, 20, 30 };
a = raw_data(b[:]);
fmt.println(a, a[1], b); // 0x7FFCBE9FE688 20 [10, 20, 30]
```

The current language name is *multi-pointer*. Alternative terminology is recorded under [Open questions](#multi-pointer-terminology).

## raw_data procedure

raw_data is a built-in procedure which returns the underlying data of a built-in data type as a Multi-Pointer.

```odin
raw_data([]$E)              -> [^]E;    // slices
raw_data([dynamic]$E)       -> [^]E;    // dynamic arrays
raw_data(^[$N]$E)           -> [^]E;    // fixed and enumerated arrays
raw_data(^#simd[$N]$E)      -> [^]E;    // SIMD vectors
raw_data(string)            -> [^]byte;
```

For a nested fixed array, `raw_data` exposes one array level at a time. If `grid` has type `[Rows][Columns]T`, then `raw_data(&grid)` has type `[^][Columns]T`, while `raw_data(&grid[0])` has type `[^]T` and points at the first scalar element of the contiguous row-major storage.

## using statement

`using` brings entities declared in a scope or namespace into the current scope. It can be applied to import names, struct fields, procedure fields, and struct values.

```odin
import "foo";
bar :: proc() {
	// imports all the exported entities from the `foo` package into this scope
	using foo;
}
```

### Using statement with structs

Let’s take a very simple entity struct:

```odin
Vector3 :: struct{x, y, z: f32};
Quaternion_F32 :: struct{x, y, z, w: f32}; // ordinary library-defined type
Entity :: struct {
	position: Vector3,
	orientation: Quaternion_F32, // library-defined type
}
```

It can be used like this:

```odin
foo :: proc(entity: ^Entity) {
	fmt.println(entity.position.x, entity.position.y, entity.position.z);
}
```

The entity members can be brought into the procedure scope by using it:

```odin
foo :: proc(entity: ^Entity) {
	using entity;
	fmt.println(position.x, position.y, position.z);
}
```

The using can be applied to the parameter directly:

```odin
foo :: proc(using entity: ^Entity) {
	fmt.println(position.x, position.y, position.z);
}
```

It can also be applied to sub-fields:

```odin
foo :: proc(entity: ^Entity) {
	using entity.position;
	fmt.println(x, y, z);
}
```

We can also apply the using statement to the struct fields directly, making all the fields of position appear as if they are on Entity itself:

```odin
Entity :: struct {
	using position: Vector3,
	orientation: Quaternion_F32, // library-defined type
}
foo :: proc(entity: ^Entity) {
	fmt.println(entity.x, entity.y, entity.z);
}
```

## Subtype polymorphism

It is possible to get subtype polymorphism, similar to inheritance-like functionality in C++, but without the requirement of vtables or unknown struct layout:

```odin
foo :: proc(entity: Entity) {
	fmt.println(entity.x, entity.y, entity.z);
}

Frog :: struct {
	ribbit_volume: f32,
	using entity: Entity,
}

frog: Frog;
// Both work
frog.x = 123;
foo(frog);
```

Note: using can be applied to arbitrarily many things, which allows the ability to have multiple subtype polymorphism (but also its issues).

Note: using’d fields can still be referred by name.

# Error handling

## or_else expression

or_else is an infix binary operator that allows the user to define default values for certain expressions with optional-ok semantics.

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

or_else can be used with type assertions too, as they have optional-ok semantics.

```odin
v: union{int, f64};
i: int;
i = v.(int) or_else 123;
i = v.? or_else 123; // Type inference magic
assert(i == 123);

m: Maybe(int);
i = m.? or_else 456;
assert(i == 456);
```

## or_return operator

The concept of or_return will work by popping off the end value in a multiple valued expression and checking whether it was not nil or was false, and if so, set the end return value to value if possible. If the procedure only has one return value, it will do a simple return. If the procedure had multiple return values, or_return will require that all parameters be named so that the end value could be assigned to by name and then an empty return could be called.

```odin
Error :: enum {
	None,
	Something_Bad,
	Something_Worse,
	The_Worst,
	Your_Mum,
}

caller_1 :: proc() -> Error {
	return .None;
}

caller_2 :: proc() -> (int, Error) {
	return 123, .None;
}
caller_3 :: proc() -> (int, int, Error) {
	return 123, 345, .None;
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
	caller_1() or_return
	// which is functionally equivalent to
	if (err1 := caller_1(); err1 != nil) {
		return err1;
	}

	// Multiple return values still work with `or_return` as it only
	// pops off the end value in the multi-valued expression
	n0, n1 = caller_3() or_return;

	return .None;
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
	caller_1() or_return

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

A couple of ways are provided for doing this, and each of them have their uses.

## File suffixes

Often, you want to separate multiple implementations of a package based on the OS or the architecture.

Your .odin files can have a magic suffix that will cause the compiler to either include or exclude them based on the target platform or architecture, or both.

For example, foobar_windows.odin would only be compiled on Windows, foobar_linux.odin only on Linux, and foobar_windows_amd64.odin only on Windows AMD64.

## when statements

Sometimes you only want to compile a block of code if a certain compile-time expression evaluates to true. This can be done using the when statements:

```odin
when (ODIN_OS == .Linux) {
	// Do Linux stuff
}
```

The compiler provides a set of builtin constants which are available in all files in a compilation, and which can be used in a when condition. Here is a comprehensive list of them:
| Name | Description |
| --- | --- |
| ODIN_ARCH | An enum value indicating what the CPU architecture of the target is. (.amd64, .i386, .arm32, .arm64, .wasm32, .wasm64p32, .riscv64) |
| ODIN_ARCH_STRING | A string indicating what the CPU architecture of the target is. ("amd64", "i386", "arm32", "arm64", "wasm32", "wasm64p32", "riscv64") |
| ODIN_BUILD_MODE | An enum value indicating what type of compiled output the user desires. (.Executable, .Dynamic, .Static, .Object, .Assembly, or .LLVM_IR) |
| ODIN_BUILD_PROJECT_NAME | Name of the folder that contains the entry point. |
| ODIN_COMPILE_TIMESTAMP | An i64 containing the time at which the executable was compiled, in nanoseconds. This is compatible with the time.Time type, i.e. time.Time{_nsec=ODIN_COMPILE_TIMESTAMP} |
| ODIN_DEBUG | true if the -debug command line switch is passed, which enables debug info generation. |
| ODIN_DEFAULT_TO_NIL_ALLOCATOR | true if the -default-to-nil-allocator command line switch is passed, which sets the initial allocator to an allocator that does nothing. |
| ODIN_DEFAULT_TO_PANIC_ALLOCATOR | true if the -default-to-panic-allocator command line switch is passed, which sets the initial allocator to an allocator that panics if allocated from. |
| ODIN_DISABLE_ASSERT | true if the -disable-assert command line switch is passed, which removes all calls to assert from the compilation. |
| ODIN_ENDIAN | An enum value indicating the endianness of the target. (.Little, .Big) |
| ODIN_ENDIAN_STRING | A string indicating the endianness of the target. ("little", "big") |
| ODIN_ERROR_POS_STYLE | An enum value set using the -error-pos-style switch, indicating the source location style used for compile errors and warnings. (.Default (Odin), .Unix) |
| ODIN_FOREIGN_ERROR_PROCEDURES | true if the -foreign-error-procedures command line switch is passed, which inhibits generation of runtime error procedures, so that they can be in a separate compilation unit. |
| ODIN_MICROARCH_STRING | A string describing the microarchitecture used for code generation. Can be set using the -microarch command line switch. E.g. "sandybridge". |
| ODIN_MINIMUM_OS_VERSION | An integer value representing the minimum OS version set using -minimum-os-version. Calculated as major * 10_000 + minor * 100 + revision, and defaults to 0 if not specified. |
| ODIN_NO_BOUNDS_CHECK | true if the -no-bounds-check command line switch is passed, which disables bounds checking at runtime. |
| ODIN_NO_CRT | true if the -no-crt command line switch is passed, which inhibits linking with the C Runtime Library, a.k.a. LibC. |
| ODIN_NO_ENTRY_POINT | true if the -no-entry-point command line switch is passed, which makes the declaration of a main procedure optional. |
| ODIN_NO_RTTI | true if the -no-rtti command line switch is passed, which inhibits generation of full Runtime Type Information. |
| ODIN_NO_TYPE_ASSERT | true if the -no-type-assert command line switch is passed, which disables type assertion checking program wide. |
| ODIN_OPTIMIZATION_MODE | An enum value indicating the optimization level selected using the -o command line switch. (.None, .Minimal, .Size, .Speed, .Aggressive) |
| ODIN_OS | An enum value indicating what the target operating system is. |
| ODIN_OS_STRING | A string indicating what the target operating system is. |
| ODIN_PLATFORM_SUBTARGET | An enum value indicating the platform subtarget, chosen using the -subtarget switch. (.Default, .iOS, .Android) |
| ODIN_ROOT | Path to the folder containing the Odin compiler executable. |
| ODIN_SANITIZER_FLAGS | A bit_set indicating the sanitizer flags set using the -sanitize command line switch. (.Address, .Memory, and .Thread). |
| ODIN_TEST | true if the code is being compiled via an invocation of odin test. |
| ODIN_USE_SEPARATE_MODULES | true by default, false if the -use-single-module command line switch is passed to force a unity build. By default each package is compiled into an object file, then linked together. |
| ODIN_VALGRIND_SUPPORT | true if Valgrind integration is supported on the target. |
| ODIN_VENDOR | String which identifies the compiler being used. The official compiler sets this to "odin". |
| ODIN_VERSION | A string that represents the Odin compiler version being used. (e.g: dev-2023-04) |
| ODIN_VERSION_HASH | A string containing the Git hash part of the Odin version. Empty if .git could not be detected at the time the compiler was built. |
| ODIN_WINDOWS_SUBSYSTEM | An enum value indicating the desired Windows PE subsystem, chosen using the -subsystem switch. (.Console (default), .Windows, or .Unknown on non-Windows platforms. |
| ODIN_WINDOWS_SUBSYSTEM_STRING | A string indicating the desired Windows PE subsystem, chosen using the -subsystem switch. ("CONSOLE" (default), "WINDOWS", or "" on non-Windows platforms. |
| __ODIN_LLVM_F16_SUPPORTED | true if LLVM supports the f16 type. |

See the tracking allocator for an example of something that uses the ODIN_DEBUG constant in a when statement.

## Command-line defines

Sometimes you want to do something conditionally based on some compile-time parameters of some sort, but globally, across the entire project. This is how you define those.

You may define a constant using the -define command line switch. e.g: -define:FOO=true. You can then fetch its value as a constant in your code like this:

```odin
FOO :: #config(FOO, false); // defines `FOO` as a constant with the default value of false
BAR :: #config(BAR_DEBUG, true); // name can be different compared to the constant 

when (FOO) {
	// only evaluated when `FOO` is true
} else {
	// only evaluate when `FOO` is false
}
```

The value for a command line define may be an integer, boolean, or string. Currently, no other types are supported.

You can read up further on Built-in procedures here.

## Build tags

This feature allows you to cover more edge-case situations where you want some code to be compiled on several platforms.

However, overly-liberal use of this feature can make it hard to reason about what code is included or not, based on the target platform or architecture. File Suffixes are typically a nicer approach if they cover what you need.

For the sake of demonstration, let’s take POSIX: You could use foobar_unix.odin, which has no special meaning to the compiler at all, and use a tag in the file itself.

Here’s an example of a file that will only be included on Linux or Darwin:

```odin
#+build linux, darwin
package foobar;
```

The opposite, excluding the file on both Linux and Darwin, is achieved like this:

```odin
#+build !linux
#+build !darwin
package foobar;
```

## Advanced Build Tags

### `#+vet`

Can be used to enable or disable vetting options on a per-file basis.

Possible Options:

- unused
- unused-variables
- unused-imports
- shadowing
- using-stmt
- using-param
- style
- semicolon
- deprecated
- cast
- tabs
- unused-procedures
- explicit-allocators

### `#+test`

The file is completely ignored from parsing and type checking EXCEPT during odin test.

### `#+ignore`

The file is completely ignored from parsing and type checking.

### `#+private`

Using #+private before the package declaration will automatically add @(private) to everything in that file:

```odin
#+private
package foo;
```

And #+private file will be equivalent to automatically adding @(private="file") to each declaration. This means that to remove the private-to-file association, you must apply a private-to-package attribute @(private) to the declaration.

### `#+feature`

Enables a specific feature or changes the behaviour of a specific aspect of the language

- `#+feature no-implicit-allocation` rejects operations that may allocate unless they use an explicit allocator or a `manual` owner.
- `#+feature integer-division-by-zero:<option>` controls integer division by zero:
  - `trap` traps on division, modulo, or remainder by zero.
  - `zero` makes `x/0 == 0`, `x%0 == x`, and `x%%0 == x`.
  - `self` makes `x/0 == x`, `x%0 == 0`, and `x%%0 == 0`.
  - `all-bits` makes `x/0 == ~T(0)`, `x%0 == x`, and `x%%0 == x`.
- `#+feature global-context` enables globals that require `context` in global scope. By default, `context` does not exist there.

### `#+no-instrumentation`

Disables instrumentation within the entire file

# Memory and the context system

## Implicit context system

In each scope, there is an implicit value named context. This context variable is local to each scope and is implicitly passed by pointer to any procedure call in that scope (if the procedure has the loke calling convention).

The main purpose of the implicit context system is for the ability to intercept third-party code and libraries and modify their functionality. One such case is modifying how a library allocates something or logs something. In C, this was usually achieved with the library defining macros which could be overridden so that the user could define what they wanted. However, not many libraries supported this in many languages by default which meant intercepting third-party code to see what it does and to change how it does it was not possible.

```odin
main :: proc() {
	c := context; // copy the current scope's context

	context.user_index = 456;
	{
		context.allocator = my_custom_allocator();
		context.user_index = 123;
		supertramp(); // the `context` for this scope is implicitly passed to `supertramp`
	}

	// `context` value is local to the scope it is in
	assert(context.user_index == 456);
}

supertramp :: proc() {
	c := context; // this `context` is the same as the parent procedure that it was called from
	// From this example, context.user_index == 123
	// A context.allocator is assigned to the return value of `my_custom_allocator()`

	// The memory management procedure uses the `context.allocator` by default unless explicitly specified otherwise
	ptr := new(int);
	free(ptr);
}
```

By default, the context value has default values for its parameters which is decided in the package runtime. These defaults are compiler specific.

To see what the implicit context value contains, please see the definition of the Context struct in package runtime.

## Allocators

The language uses deterministic managed memory for ordinary owning values and retains explicit allocators for systems programming. Managed values are not garbage-collected: the compiler inserts cleanup at the end of their lexical lifetime.

Dynamic arrays, maps, runtime strings, and other managed containers remember the allocator responsible for their backing storage. By default they use `context.allocator`; a declaration can select another allocator with `using`.

```odin
bytes: [dynamic]u8 using context.temp_allocator;
bytes.reserve(4096);
```

The allocator affects where backing storage comes from, but does not change value semantics or whether cleanup is automatic. Use the `manual` declaration modifier to opt out of automatic cleanup.

All allocations are preferably done through allocators. The core library takes advantage of allocators through the implicit context system. The following call:

```odin
ptr := new(int);
```

is equivalent to this:

```odin
ptr := new(int, context.allocator);
```

The allocator from the context is implicitly assigned as a default parameter to the built-in procedure new.

The implicit context stores two different forms of allocators: context.allocator and context.temp_allocator. Both can be reassigned to any kind of allocator. However, these allocators are to be treated slightly differently.

- context.allocator is for “general” allocations, for the subsystem it is used within.
- context.temp_allocator is for temporary and short lived allocations, which are to be freed once per cycle/frame/etc.

By default, `context.allocator` is an OS heap allocator and `context.temp_allocator` is a scratch allocator backed by a growing arena. `free_all(context.temp_allocator)` clears that arena. The compiler rejects `free_all` while a live managed value or borrow still refers to storage from that allocator.

The following low-level procedures are built in and are also available in package `mem` with enforced allocator errors. Normal managed strings, arrays, and maps do not need them.

- new - allocates a value of the type given. The result value is a pointer to the type given.

```odin
ptr := new(int);
ptr^ = 123;
x: int = ptr^;
```

- new_clone - allocates a clone of the value passed to it. The resulting value of the type will be a pointer to the type of the value passed.

```odin
x: int = 123;
ptr: ^int;
ptr = new_clone(x);
assert(ptr^ == 123);
```

- make - creates manually owned backing storage for a dynamic array or map. The result must initialize a `manual` owner, or be transferred to a managed owner with `move`. Slices are borrows and cannot be manual owners.

```odin
dynamic_array_zero_length: manual [dynamic]int = make([dynamic]int);
dynamic_array_with_length: manual [dynamic]int = make([dynamic]int, 32);
dynamic_array_with_length_and_capacity: manual [dynamic]int = make([dynamic]int, 16, 64);

made_map: manual map[string]int = make(map[string]int);
made_map_with_reservation: manual map[string]int = make(map[string]int, 64);
```

- free - frees the memory at the pointer given. Note: only free memory with the allocator it was allocated with.

```odin
ptr := new(int);
free(ptr);
```

- free_all - frees all the memory of the context’s allocator (or given allocator). Note: not all allocators support this procedure.

```odin
free_all();
free_all(context.temp_allocator);
free_all(my_allocator);
```

- delete - releases a `manual` owner created by `make`. Calling `delete` on a managed value is an error; use `drop` for early managed cleanup.

```odin
delete(manual_dynamic_array);
delete(manual_map);
```

To see more uses of allocators and allocation-related procedures, please see package mem in the core library.

## Allocation failure

Managed values allocate implicitly. A dynamic array grows on `append`, a string is built by concatenation, and an assignment clones its source. None of these have a place to return an error, so the language needs one answer for what happens when the allocator cannot satisfy them.

Each allocator carries a **failure policy**, part of the allocator value and therefore selectable per subsystem through the context:

| Policy | Behaviour on failure |
| --- | --- |
| `.Panic` | Raise a runtime panic reporting the requested size and the allocator. The default. |
| `.Trap` | Abort the process immediately without unwinding. For freestanding and embedded targets. |
| `.Error` | Fail the operation and set the context's allocation-error flag. Existing destinations remain unchanged; value-producing operations yield zero. |

`.Panic` is the default because the alternative — silently continuing with a truncated container — is the failure mode that produces corrupted output rather than a stopped program. Programs that cannot accept a panic set the policy explicitly.

Under `.Error`, a failed mutation is a no-op: an `append` does not extend and assignment to an existing destination leaves that destination unchanged. A failed value-producing operation has no existing destination to preserve, so it produces the zero value of its result type. Thus a failed declaration initializes its variable to zero, a failed concatenation evaluates to an empty string, and a failed clone used as a return value returns the zero value. Any partial temporary state is cleaned up before execution continues.

The allocation-error flag is sticky: the first failure remains recorded until `mem.last_allocation_error()` reads and clears it. Successful allocations do not clear an earlier failure. This policy gives every expression a defined value while allowing code such as a server shedding load to inspect the error at a chosen boundary; code that must distinguish failure at one exact operation should use the explicit fallible forms below.

Where failure must be handled at a specific call site rather than by policy, use the explicit forms, which return an error regardless of the active policy:

```odin
copy, err := source.try_clone();
if (err != nil) {
	return err;
}

ok := numbers.try_append(value);
```

`make`, `new`, and the other `manual` primitives always report errors through their return values and ignore the policy, since they already have somewhere to put an error.

For more information regarding memory allocation strategies in general, please see Ginger Bill’s Memory Allocation Strategy series.

## Tracking allocator

In the core collection you’ll find a tracking allocator that warns you if your program is leaking memory or if it does bad frees. Here’s how to set it up:

```odin
package main;

import "core:fmt";
import "core:mem";

main :: proc() {
	when (ODIN_DEBUG) {
		track: mem.Tracking_Allocator;
		mem.tracking_allocator_init(&track, context.allocator);
		context.allocator = mem.tracking_allocator(&track);

		defer {
			if (len(track.allocation_map) > 0) {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map));
				for (_, entry in track.allocation_map) {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location);
				}
			}
			mem.tracking_allocator_destroy(&track);
		}
	}
	
	do_stuff();
}
```

This uses a when statement to only enable the tracking allocator when the -debug compilation flag is set. Since it sets the tracking allocator on the context in the beginning of main, the rest of the program will use this tracking allocator.

Note that when blocks do not have a real scope, the curly braces {} are just there to group code. Any changes to the context within a when block are valid after the when block ends.

By default, the tracking allocator will panic if a bad free occurs. It will print a message that informs you where that bad free happened. You can override that behavior by overriding track.bad_free_callback:

```odin
// This will add the bad frees to `track.bad_free_array`,
// you must manually check the contents of that array.
track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array;
```

## Explicit context Definition

Procedures which do not use the `loke` calling convention must explicitly assign the context if something within the body requires it.

```odin
explicit_context_definition :: proc "c" () {
	// Try commenting the following statement out below
	context = runtime.default_context();

	fmt.println("\n#explicit context definition");
	dummy_procedure();
}

dummy_procedure :: proc() {
	fmt.println("dummy_procedure");
}
```

Here is another example of setting an error callback for vendor:glfw:

```odin
error_callback :: proc "c" (code: i32, desc: cstring_view) {
	context = runtime.default_context(); // set the current context
	fmt.println(desc, code); // fmt.* calls use the loke calling convention
}
glfw.SetErrorCallback(error_callback);
```

## Logging System

As part of the implicit context system, there is a built-in logging system.

To see more uses of loggers, please see package log in the core library.

# Foreign system

It is sometimes necessary to interface with foreign code, such as a C library. This is achieved through the foreign system. You can “import” a library into the code using the same semantics as a normal import declaration:

foreign import kernel32 "system:kernel32.lib"

This foreign import declaration will create a “foreign import name” which can then be used to associate entities within a foreign block.

```odin
foreign import kernel32 "system:kernel32.lib"
foreign kernel32 {
	ExitProcess :: proc "stdcall" (exit_code:  u32) ---;
}
```

The compiler can also automatically build and link imported assembly files. Depending on the host system, clang, as, or nasm may be used to compile the assembly. Recognized file extensions for assembly files are: asm, s, and S.

For examples, see base/runtime/entry_*.asm.

```odin
foreign import lowlevel "lowlevel.asm"
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

Foreign procedure declarations have the cdecl/c calling convention by default unless specified otherwise. Due to foreign procedures not having a body declared within this code, you need to append the --- symbol to the end to distinguish it as a procedure literal without a body and not a procedure type.

The attributes system can be used to change specific properties of entities declared within a block:

```odin
@(default_calling_convention = "std")
foreign kernel32 {
	@(link_name="GetLastError") get_last_error :: proc() -> i32 ---;
}
```

Available attributes for foreign blocks:

- default_calling_convention=<string> - The default calling convention for procedures declared within this foreign block.
- link_prefix=<string> - This prefix is prepended to the linkage names of the entities except where the link name has been explicitly overridden.
- link_suffix=<string> - This suffix is appended to the linkage names of the entities except where the link name has been explicitly overridden.
- private=<string> - The default private level for all entities. Defaults to "package" if not set but may be set to "file".
- require_results - All procedures declared within this foreign block must have their return values used.

## Using a vendor library

As described in the Foreign System we often want to use existing C libraries. Because the foreign system is inherited from Odin unchanged, Odin's collection of maintained bindings and ports under `vendor:` can be used with little or no modification.

Note: Case notation should remain the same as the original authors intended, to make porting code easier.

Let’s run through how we could use the vendor:glfw library. The code will be based on their Quick Guide but we will simplify it to only show using glfw.

```odin
package main;

import "base:runtime";
import "core:fmt";
import "vendor:glfw";

error_callback :: proc "c" (code: i32, desc: cstring_view) {
	context = runtime.default_context();
	fmt.println(desc, code);
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if (key == glfw.KEY_ESCAPE && action == glfw.PRESS) {
		glfw.SetWindowShouldClose(window, glfw.TRUE);
	}
}

main :: proc() {
	glfw.SetErrorCallback(error_callback);

	if (!glfw.Init()) {
		panic("EXIT_FAILURE");
	}
	defer glfw.Terminate();

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 2);
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 0);

	window := glfw.CreateWindow(640, 480, "Simple example", nil, nil);
	if (window == nil) {
		panic("EXIT_FAILURE");
	}	
	defer glfw.DestroyWindow(window);

	glfw.SetKeyCallback(window, key_callback);

	glfw.MakeContextCurrent(window);
	// ...
	glfw.SwapInterval(1);
	// ...

	for (!glfw.WindowShouldClose(window)) {
		// ...

		glfw.SwapBuffers(window);
		glfw.PollEvents();
	}
}
```

As we can see there is little difference to how someone would use vendor:glfw in this case. It’s not always perfect but often good enough to port existing code quickly.

# Parametric polymorphism

Parametric polymorphism, commonly referred to as “generics”, allow the user to create a procedure or data that can be written generically so it can handle values in the same manner.

Note: the nickname “parapoly” is usually used for this, following Odin.

## Explicit parametric polymorphism

Explicit parametric polymorphism means that the types of the parameters of a proc or of the data fields of a struct (when intended to potentially be used with multiple possible types) must be explicitly provided. This is similar to how C++ allows the use of templates to fill out the body of a procedure or data structure with the types that are given at compile-time as input to the template parameters, but here explicit parametric polymorphism is safer and cleaner to work with.

### Procedures using explicit parametric polymorphism (parapoly)

As a reminder, all parameters passed into a function are immutable in the sense that they can’t have their value changed using = directly. A useful idiom is var := var, which expresses a variable shadowing itself. When used at the top of a procedure the compiler understands the use case of enabling local modification of the otherwise immutable parameter variable, and won’t complain about the shadowing when you compile with -vet.

```odin
sin_tau :: proc(angle_in_cycles: f64) -> f64 {
    angle_in_cycles := angle_in_cycles;   // Allows `angle_in_cycles` to have its value changed
    
    TAU :: 2 * math.PI;
    angle_in_cycles *= TAU;
    return math.sin(angle_in_cycles);
}
assert(math.abs(sin_tau(0.25) - 1) <= 0.001);   // sin_tau(0.25) is approximately 1
assert(math.abs(sin_tau(0.75) - -1) <= 0.001);  // sin_tau(0.75) is approximately -1
```

However, to specify that a parameter must be a compile-time constant, which is not the same thing as an immutable parameter, and may sometimes be necessary (e.g. for parapoly) or desirable (e.g. to enforce compile-time computation), the parameter’s name must be prefixed with a dollar sign $. The following example takes two compile-time constant parameters and then uses them to initialize an array of known length:

```odin
make_f32_array :: #force_inline proc($N: int, $val: f32) -> (res: [N]f32) {
	for (_, i in res) {
		res[i] = val*val;
	}
	return;
}

array := make_f32_array(3, 2);
```

Types can also be explicitly passed by specifying that the typeid parameter is constant:

```odin
my_new :: proc($T: typeid) -> ^T {
	return (^T)(alloc(size_of(T), align_of(T)));
}

ptr := my_new(int);
```

### Data types using explicit parametric polymorphism (parapoly)

Structures and unions may have polymorphic parameters and the syntax for doing so is similar to procedure call syntax. Parapoly struct:

```odin
Table_Slot :: struct($Key, $Value: typeid) {
	occupied: bool,
	hash:    u32,
	key:     Key,
	value:   Value,
}
slot: Table_Slot(string, int);
```

Parapoly union:

```odin
Error :: enum {Foo0, Foo1, Foo2};
Param_Union :: union($T: typeid) #no_nil {T, Error};
r: Param_Union(int);
r = 123;
r = Error.Foo0;
```

The $ prefix is optional for record data types as all parameters must be “constant”.

## Implicit parametric polymorphism

Implicit implies that the type of a parameter is inferred from its input. In this case, the dollar sign $ can be placed on the type.

Note: the name “polymorphic name” is usually used for this, following Odin.

### Procedures using implicit parametric polymorphism (parapoly)

```odin
foo :: proc($N: $I, $T: typeid) -> (res: [N]T) {
	// `N` is the constant value passed
	// `I` is the type of `N`
	// `T` is the type passed
	fmt.printf("Generating an array of type %v from the value %v of type %v\n",
			   typeid_of(type_of(res)), N, typeid_of(I));
	for (i in 0..<N) {
		res[i] = i*i;
	}
	return;
}

T :: int;
array := foo(4, T);
for (v, i in array) {
	assert(v == T(i*i));
}
```

## Specialization

In some cases, you may want to specify that a type must be a specialization of a certain type.

```odin
// Only allow types that are specializations of a (polymorphic) slice
make_slice :: proc($T: typeid/[]$E, len: int) -> T {
	return make(T, len);
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
	slots:     []Table_Slot(Key, Value),
}

// Only allow types that are specializations of `Table`
allocate :: proc(table: ^$T/Table, capacity: int) {
	...
}

// find :: proc(table: ^$T/Table, key: T.Key) -> (T.Value, bool) {
find :: proc(table: ^Table($Key, $Value), key: Key) -> (Value, bool) {
	...
}
```

## where clauses

A bound on polymorphic parameters to a procedure or record can be expressed using a where clause immediately before opening {, rather than at the type’s or constant’s first mention. Additionally, where clauses can apply bounds to arbitrary types, rather than just polymorphic type parameters.

Some cases that a where clause may be useful:

- Sanity checks for parameters:

```odin
simple_sanity_check :: proc(x: [2]int);
	where len(x) > 1,
		  type_of(x) == [2]int {
	fmt.println(x);
}
```

- Parameter polymorphism checks for procedures:

```odin
cross_2d :: proc(a, b: $T/[2]$E) -> E;
	where intrinsics.type_is_numeric(E) {
	return a.x*b.y - a.y*b.x;
}
cross_3d :: proc(a, b: $T/[3]$E) -> T;
	where intrinsics.type_is_numeric(E) {
	x := a.y*b.z - a.z*b.y;
	y := a.z*b.x - a.x*b.z;
	z := a.x*b.y - a.y*b.x;
	return T{x, y, z};
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
foo :: proc(x: [$N]int) -> bool;
	where N > 2 {
	fmt.println(#procedure, "was called with the parameter", x);
	return true;
}

bar :: proc(x: [$N]int) -> bool;
	where 0 < N,
		  N <= 2 {
	fmt.println(#procedure, "was called with the parameter", x);
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

- Restrictions on parametric polymorphic parameters for record types:

```odin
Foo :: struct($T: typeid, $N: int);
	where intrinsics.type_is_integer(T),
	      N > 2 {
	x: [N]T,
	y: [N-2]T,
}

T :: i32;
N :: 5;
f: Foo(T, N);
#assert(size_of(f) == (N+N-2)*size_of(T));
```

## -> operator (selector call expressions)

The -> operator is called the selector call expression operator and is extremely useful for call procedures stored in vtables. Component Objective Model (COM) APIs is a great example of where this kind of thing is extremely useful (such as the Direct3D11 package).

```odin
x->y(123)
// is equivalent to
x.y(x, 123);
```

As the -> operator is effectively syntactic sugar, all of the same semantics still apply, meaning subtyping through using will still work as expected to allow for the emulation of type hierarchies.

# Attributes

Attributes modify the compilation details or behaviour of declarations.

## Attribute categories

### User tag which is ignored by the compiler

```odin
    @(tag=<string>) – works on ANY declaration
```

### Non-User Code

```odin
    @(builtin) — marks builtin declarations in Odin’s base:runtime package. Cannot be used in user code
```

### Foreign Blocks

```odin
    @(default_calling_convention=<string>) – foreign blocks
    @(link_prefix=<string>) – foreign blocks and declarations within foreign blocks
    @(link_suffix=<string>) – foreign blocks and declarations within foreign blocks
    @(private=<string?>)– all declarations except import statements
    @(require_results) – procedure declarations and foreign blocks
```

### Procedure Groups

```odin
    @(objc_is_class_method=<boolean>)
    @(objc_name=<string>)
    @(objc_type=<type>)
    @(require_results)
```

### Procedure Declarations

```odin
    @(cold)
    @(conversion)
    @(deprecated=<string>)
    @(disabled=<boolean>)
    @(enable_target_feature=<string>)
    @(entry_point_only)
    @(export=<boolean?>)
    @(fini)
    @(init)
    @(instrumentation_enter)
    @(instrumentation_exit)
    @(implicit)
    @(link_name=<string>)
    @(link_prefix=<string>)
    @(link_suffix=<string>)
    @(link_section=<string>)
    @(linkage=<string>)
    @(no_instrumentation=<boolean?>)
    @(no_sanitize_address)
    @(no_sanitize_memory)
    @(objc_implement=<boolean?>)
    @(objc_is_class_method=<boolean>)
    @(objc_name=<string>)
    @(objc_selector=<string>)
    @(objc_type=<type>)
    @(optimization_mode=<string>)
    @(require=<boolean?>)
    @(require_results)
    @(require_target_feature=<string>)
    @(test)
```

### Variable Declarations

```odin
    @(export=<boolean?>)
    @(link_name=<string>)
    @(link_prefix=<string>)
    @(link_section=<string>)
    @(link_suffix=<string>)
    @(linkage=<string>)
    @(private=<string>?) – globals only
    @(require=<boolean?>)
    @(rodata)
    @(static) – locals variable declarations only
    @(thread_local=<string?>)
```

### Constant Value Declarations

```odin
    @(private=<string>?)
```

### Type Declarations

```odin
    @(objc_class=<string>)
    @(objc_context_provider=<procedure>)
    @(objc_implement=<boolean?>)
    @(objc_ivar=<type>)
    @(objc_superclass=<type>)
    @(private=<string>?)
    @(raddbg_type_view=<string?>)
```

## Attribute reference

### `@(builtin)`

Marks builtin procs in Odin’s “base:runtime” package. Cannot be used in user code.

### `@(cold)`

A hint to the compiler that this procedure is rarely called, and thus “cold”.

### `@(conversion)`

Marks a one-parameter procedure as an explicit conversion to its return type. The procedure becomes a candidate for `Target(value)` when it is visible through the source type, target type, an extension, or ordinary lexical scope.

### `@(implicit)`

Allows a `@(conversion)` procedure to participate in implicit conversion and overload resolution. At most one user-defined implicit conversion is applied to each argument in a single resolution step. The compiler may warn about expensive or narrowing implicit conversions, but they remain legal.

### `@(default_calling_convention=<string>)`

This attribute can be attached to a foreign block to specify the default calling convention for all procedures in the block. Example:

```odin
@(default_calling_convention = "std")
foreign kernel32 {
	@(link_name="LoadLibraryA") load_library_a  :: proc(c_str: ^u8) -> Hmodule ---;
}
```

### `@(deprecated=<string>)`

Mark a procedure as deprecated. Running odin build/run/check will print out the message for each usage of the deprecated proc.

```odin
@(deprecated="'foo' deprecated, use 'bar' instead")
foo :: proc() {
    ...
}
```

### `@(disabled=<boolean>)`

If the provided boolean is set, the procedure will not be used when called.

### `@(enable_target_feature=<string>)`

Enables or disables a specific feature needed for the target.

```odin
@(enable_target_feature="sse2,ssse3")
byteswap :: proc "contextless" (x: x86.__m128i) -> x86.__m128i {
	return x86._mm_shuffle_epi8(x, _BYTESWAP_INDEX);
}

// clang-style `+`/`-` prefixes are also supported.
@(enable_target_feature="+sse2,+ssse3,-avx")
byteswap2 :: proc "contextless" (x: x86.__m128i) -> x86.__m128i {
	return x86._mm_shuffle_epi8(x, _BYTESWAP_INDEX);
}
```

This attribute is primarily useful when maintaining backward compatibility while allowing the use of newer CPU features, by providing multiple implementations.

When using the - prefix to disable a target feature, it is strongly recomended for the procedure to be marked with the #force_inline or #force_no_inline directive, as functions that are automatically inlined may silently use the disabled feature anyway.

### `@(entry_point_only)`

Marks a procedure that can be called within the entry point only.

### `@(export=<boolean?>)`

Exports a variable or procedure symbol, useful for producing DLLs.

### `@(init)`

This attribute may be applied to any procedure that neither takes any parameters nor returns any values. All suitable procedures marked in this way by @(init) will then be called at the start of the program before main is called. The exact order in which all such intialization functions are called is deterministic and hence reliable. The order is determined by a topological sort of the import graph and then in alphabetical file order within the package and then top down within the file.

### `@(fini)`

Like @(init) but run at after the main procedure finishes.

### `@(instrumentation_enter)`

Attaches to a procedure declaration to mark as the procedure to use for instrumentation profiling on enter. It must have the signature: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location).

```odin
@(instrumentation_enter)
spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
	spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc);
}
```

### `@(instrumentation_exit)`

Attaches to a procedure declaration to mark as the procedure to use for instrumentation profiling on exit. It must have the signature: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location).

```odin
@(instrumentation_exit)
spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
	spall._buffer_end(&spall_ctx, &spall_buffer);
}
```

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

### `@(link_prefix=<string>)`

This attribute can be attached to variable and procedure declarations, either when exporting or inside a foreign block. So if functions are prefixed with ltb_ in the library, you can attach this and not specify that on the procedure on the Loke side; conversely, foreign procedures must match the exported procedure’s name with its link prefix. Example:

```odin
@(link_prefix = "ltb_")
foreign foo {
    testbar :: proc(baz: int) ---; // This now refers to ltb_testbar
}

@(export, link_prefix="ltb_")
foo :: proc "c" () -> int {
	return 42;
}
```

### `@(link_section=<string>)`

Specify the link section for a global variable.

```odin
@(link_section=".foo")
my_global: i32;
```

Specify the link section for a procedure.

```odin
@(link_section=".bar")
my_procedure :: proc "c" () -> i32 {
	return 1337;
}
```

### `@(link_suffix=<string>)`

This attribute can be attached to variable and procedure declarations, either when exporting or inside a foreign block. This is similar to link_prefix, except that it appends to the end of the link name instead of prepending to the start.

```odin
@(link_suffix = "_x86")
foreign foo {
	testbar :: proc(baz: int) ---; // This now refers to testbar_x86
}

@(export, link_suffix="_x86")
foo :: proc "c" () -> int {
	return 42;
}
```

### `@(linkage=<string>)`

Allows the ability to specify the specific linkage of a declaration. Allow linkage kinds: "internal", "strong", "weak", and "link_once".

### `@(no_instrumentation=<boolean?>)`

Disables instrumentation for the specified procedure. If no boolean is specified, the default state is true.

### `@(no_sanitize_address)`

If set, the procedure will not be instrumented by AddressSanitizer when using the -sanitize:address build flag, which permits the procedure and all called procedures to read and write to any memory that may be marked as invalid by the sanitizer.

This attribute will typically be used in the procedures that make up a memory allocator.

### `@(no_sanitize_memory)`

Disables checks for memory santization for the specified procedure.

### `@(objc_class=<string>)`

Specifies the name of the Objective-C class for a type.

```odin
@(objc_class="NSAutoreleasePool")
AutoreleasePool :: struct {using _: Object};
```

### `@(objc_context_provider=<procedure>)`

Specifies the procedure to use to give a default context for. It must be a procedure that takes 1 parameter (a signle point to the @(objc_type) value) and only returns runtime.Context.

n.b. Prefer not to use this if possible.

### `@(objc_implement=<boolean?>)`

Specifies whether this declaration is an implementation of an Objective-C class or not on the Loke side.

### `@(objc_is_class_method=<boolean>)`

Specifies whether the procedure or procedure groups is bound the class type or the variable (i.e. + vs - in Objective-C).

### `@(objc_ivar=<type>)`

Specifies the type to be used as the instance variable (ivar) with the associated Objective-C class type.

See the [Objective-C ivar documentation](https://developer.apple.com/documentation/objectivec/ivar?language=objc).

### `@(objc_name=<string>)`

Specifies the name to be used as the bound “method” (NOT the internal name)

### `@(objc_selector=<string>)`

Specifies the internal selector name for the Objective-C call.

### `@(objc_superclass=<type>)`

Specifies the superclass for the class type.

### `@(objc_type=<type>)`

Specifies the associated Objective-C class type for a procedure/procedure-group.

### `@(optimization_mode=<string>)`

Set the optimization mode of a procedure. Valid modes are "none" and "favor_size".

```odin
@(optimization_mode="favor_size")
skip_whitespace :: proc(t: ^Tokenizer) {
    for (;;) {
        switch (t.ch) {
        case ' ', '\t', '\r', '\n':
            advance_rune(t);
        case:
            return;
        }
    }
}
```

### `@(private=<string?>)`

Prevents a top level element from being exported with the package.

```odin
@(private)
my_variable: int; // cannot be accessed outside this package
@private // parenthesis can be dropped on no arguments
my_other_variable: int;
```

You may also make an entity private to the file instead of the package.

```odin
@(private="file")
my_variable: int; // cannot be accessed outside this file

@(private) is equivalent to @(private="package").
```

Using #+private before the package declaration will automatically add @(private) to everything in that file:

```odin
#+private
package foo;
```

And #+private file will be equivalent to automatically adding @(private="file") to each declaration. This means that to remove the private-to-file association, you must apply a private-to-package attribute @(private) to the declaration.

### `@(raddbg_type_view=<string?>)`

Adds custom a debug watch window rendering for the RAD Debugger. If no custom view rule as a string is set, then the compiler will generate a specific view from the struct fields tags (reading the fmt:"..." style declarations).

### `@(require=<boolean?>)`

Requires that the declaration is added to the final compilation and not optimized out.

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

### `@(require_target_feature=<string>)`

Forces a procedure to require a specific target feature on use. e.g. @(require_target_feature="sha512,sse4.1")

### `@(rodata)`

A global or static variable with the @(rodata) attribute will live in the read-only data block of the program. This means that the value cannot be changed.

In most cases, using a constant is a better idea. One example where @(rodata) is useful is this case:

```odin
@(rodata)
numbers := []int {
	7,
	42,
	628,
}

main :: proc() {
	index := 1;
	n := numbers[index];
	fmt.println(n);
}
```

If you instead used a constant numbers array (`NUMBERS :: []int {}`), then it would not be possible to index `numbers` using a variable, because constants only exist at compile time.

### `@(static)`

This attribute can be applied to a variable to have it keep its state even when going out of scope. This is the same behavior as a static local variable in C.

```odin
test :: proc() -> int {
    @(static) foo := 0;
    foo += 1;
    return foo;
}

main :: proc() {
    fmt.println(test()); // prints 1
    fmt.println(test()); // prints 2
    fmt.println(test()); // prints 3
}
```

### `@(tag=<string>)`

An attribute that user-level code can use but will be ignored by the compiler. This is useful for metaprogramming purposes. If more custom tags are required, use the flag -ignore-unknown-attributes.

### `@(test)`

Allows procedures with the attribute @(test) to be run with the command odin test directly.

```odin
import "core:testing";

@(test)
foo :: proc(_: ^testing.T) {
}
```

### `@(thread_local=<string?>)`

Can be applied to a variable at file scope

```odin
@(thread_local) foo: int
```

# Directives

Directives are a way of extending the core behaviour of the language. They have the form #directive_name.

## Record layout directives

### `#packed`

This tag can be applied to a struct. Removes padding between fields that’s normally inserted to ensure all fields meet their type’s alignment requirements. Fields remain in source order.

This is useful where the structure is unlikely to be correctly aligned (the insertion rules for padding assume it is), or if the space-savings are more important or useful than the access speed of the fields.

Accessing a field in a packed struct may require copying the field out of the struct into a temporary location, or using a machine instruction that doesn’t assume the pointer address is correctly aligned, in order to be performant or avoid crashing on some systems. (See intrinsics.unaligned_load.)

struct #packed {x: u8, y: i32, z: u16, w: u8}

### `#raw_union`

This tag can be applied to a struct. Struct’s fields will share the same memory space which serves the same functionality as unions in C language. Useful when writing bindings especially.

struct #raw_union {u: u32, i: i32, f: f32}

### `#align`

This tag can be applied to a struct or union. When #align is passed an integer N (as in #align N), it specifies that the struct will be aligned to N bytes. The struct’s fields will remain in source-order.

```odin
Foo :: struct #align(4) {
    b: bool,
}
Bar :: union #align(4) {
    i32,
    u8,
}
```

### `#no_nil`

This tag can be applied to a union to not allow nil values.

```odin
A :: union {int, bool};
B :: union #no_nil {int, bool};

// Possible states of A:
{} // nil
{int}
{bool}

// Possible states of B:
{int} // default state
{bool}
```

## Control-flow directives

### `#partial`

By default all cases of an enum or union have to be covered in a switch statement. The reason for this requirement is because it makes accidental bugs less likely. However, the #partial tag allows you to not have to write out cases that you don’t need to handle:

```odin
Foo :: enum {
    A,
    B,
    C,
}

test :: proc() {
    bar := Foo.A;

    // All cases required, removing any would result in an error
    switch (bar) {
    case .A:
    case .B:
    case .C:
    }

    // Partially state wanted cases
    #partial switch (bar) {
    case .A:
    case .B:
    }
}
```

The #partial directive can also be used to initialize an enumerated array.

## Procedure parameter directives

### `#no_alias`

This tag can be applied to a procedure parameter that is a pointer. This is a hint to the compiler that this parameter will not alias other parameters. This is equivalent to C’s __restrict.

```odin
foo :: proc(#no_alias a, b: ^int) {};
```

### `#any_int`

`#any_int` enables implicit casts to a procedure’s integer type at the call site. A parameter with `#any_int` must be an integer.

```odin
foo :: proc(#any_int a: int) {};
x : i32;
foo(x); // This is now allowed without an explicit cast
```

### `#caller_location`

`#caller_location` sets a parameter’s default value to the location of the code calling the procedure. The location value has the type `Source_Code_Location`. `#caller_location` may only be used as a default value for procedure parameters.

```odin
package example_caller_location;

import "core:fmt";

print_caller_location :: proc(loc := #caller_location) {
	fmt.println(loc);
	fmt.println(#procedure, "called by", loc.procedure);
}

main :: proc() {
	print_caller_location();
	// C:/some/dir/example_caller_location.odin(11:2)
	// print_caller_location called by main
}
```

### `#caller_expression or #caller_expression(<param>)`

`#caller_expression` gives a procedure the entire call expression or the expression used to create a parameter. `#caller_expression` may only be used as a default value for procedure parameters.

```odin
package example_caller_expression;

import "core:fmt";

entire_expression :: proc(greeting: string, count: int, expr := #caller_expression) {
    fmt.println(expr);
}

param_expression :: proc(greeting: string, count: int, count_expr := #caller_expression(count)) {
    fmt.println(count_expr);
}

main :: proc() {
	entire_expression("Hellope!", 1 + 1);
	// entire_expression("Hellope!", 1 + 1)
	param_expression("Yo", 2 + 2);
	// 2 + 2
}
```

### `#c_vararg`

Used to interface with vararg functions in foreign procedures.

```odin
foreign foo {
    bar :: proc(n: int, #c_vararg args: ..any) ---;
}
```

### `#by_ptr`

Used to interface with const reference parameters in foreign procedures. The parameter is passed by pointer internally.

```odin
foreign foo {
    bar :: proc(#by_ptr p: T) ---;
}
```

to represent

void bar(const T*)

### `#optional_ok`

Allows skipping the last return parameter, which needs to be a bool

```odin
import "core:fmt";

foo :: proc(x: int) -> (value: int, ok: bool) #optional_ok {
    return x + 1, true;
}

main :: proc() {
    for (x := 0; x < 11; x = foo(x)) {
        fmt.printf("v: %v\n", x);
    }
}
```

### `#optional_allocator_error`

Allows skipping the last return parameter, which needs to be a runtime.Allocator_Error

```odin
import "base:runtime";
import "core:strings";
import "core:fmt";

add_greetings :: proc(name: string) -> (string, runtime.Allocator_Error) #optional_allocator_error {
	result, err := strings.join({"Hello", name}, ", ");
	return result, err;
}

main :: proc() {
	msg := add_greetings("Bill");
	fmt.println(msg);
}
```

## Expression directives

### `#type`

This tag doesn’t serve a functional purpose in the compiler, this is for telling someone reading the code that the expression is a type. The main case is for showing that a procedure signature without a body is a type and not just missing its body, for example:

```odin
foo :: #type proc(foo: string);

bar :: struct {
    gin: foo,
}
```

### `#sparse`

This directive may be used to create a sparse enumerated array. This is necessary when the enumerated values are not contiguous.

```odin
Key :: enum {
	Bronze =  1,
	Silver =  5,
	Gold   = 10,
}

Key_Descriptions :: #sparse[Key]string {
	.Bronze = "a blocky bronze key",
	.Silver = "a shiny silver key",
	.Gold   = "a glittering gold key",
}
```

### `#force_inline and #force_no_inline`

Specify whether a procedure literal or call will be forced to inline (#force_inline) or forced to never inline #force_no_inline. This is not a suggestion to the compiler. If the compiler cannot inline the procedure, it will (currently) silently ignore the directive.

This is enabled all optization levels except -o:none which has all inlining disabled.

### `#must_tail`

Explicitly state that a procedure call must be optimized as a tail call. This must be attached to procedure calls with the preserve/none, preserve/most, or preserve/all calling conventions.

## Statement directives

### `#bounds_check and #no_bounds_check`

The #bounds_check and #no_bounds_check flags control Odin’s built-in bounds checking of arrays and slices. Any statement, block, or function with one of these flags will have their bounds checking turned on or off, depending on the flag provided. Valid uses of these flags include:

```odin
proc_without_bounds_check :: proc() #no_bounds_check {
    #bounds_check {
        #no_bounds_check fmt.println(os.args[1]);
    }
}
```

By default, the compiler has bounds checking enabled program-wide where applicable, and it may be turned off by passing the -no-bounds-check build flag.

### `#type_assert and #no_type_assert`

`#no_type_assert` bypasses the underlying call to `runtime.type_assertion_check` when placed at the head of a statement or block that would normally perform a type assertion. `#type_assert` re-enables type assertions if they were disabled in an outer scope.

```odin
Number :: union {
	int,
	f64,
}

proc_without_type_assertions :: proc(a: any, b: Number, m: Maybe(int)) -> int #no_type_assert {
	c := 0;
	#type_assert {
		// These statements will assert that the assumptions about the types of
		// the underlying values are correct, because we have overriden the
		// outer scope's `#no_type_assert` status.
		c += a.(int);
		c += m.(int); // A `Maybe` can only be its type or the nil type.
	}
	return c + b.(int); // This will not assert that `b` is an int.
}
```

By default, the compiler has type assertions enabled program-wide where applicable, and they may be turned off by passing the -no-type-assert build flag. Note that -disable-assert does not also turn off type assertions; -no-type-assert must be passed explicitly.

## Built-in directives

### `#assert(<boolean>)`

Unlike assert, #assert runs at compile-time. #assert breaks compilation if the given bool expression is false, and thus #assert is useful for catching bugs before they ever even reach run-time. It also has no run-time cost.

```odin
#assert(SOME_CONST_CONDITION);
```

### `#panic(<string>)`

Panic runs at compile-time. It is functionally equivalent to an #assert with a false condition, but #panic has an error message string parameter.

```odin
#panic(message);
```

### `#config(<identifier>, default)`

Checks if an identifier is defined through the command line, or gives a default value instead.

Values can be set with the -define:NAME=VALUE command line flag.

### `#defined`

Checks if an identifier is defined. This may only be used within a procedure’s body.

```odin
n: int;
when #defined(n) { fmt.println("true"); }
if (#defined(int)) { fmt.println("true"); }
when #defined(nonexistent_proc) == false { fmt.println("proc was not defined"); }
```

### `#file, #directory, #line, #procedure`

Return the current file path, directory, line number, or procedure name, respectively. Used like a constant value. file_name :: #file

### `#exists(<string-path>)`

Returns true or false if the file at the given path exists. If the path is relative, it is accessed relative to the source file that references it.

```odin
config_exists :: #exists("config.ini");
```

### `#branch_location`

When used within a defer statement, this directive returns a runtime.Source_Code_Location of the point at which the control flow triggered execution of the defer. This may be a return statement or the end of a scope.

```odin
package main;

import "base:runtime";
import "core:fmt";

find_exit :: proc(v: bool, exit: ^runtime.Source_Code_Location) {
	defer {
		exit ^= #branch_location
	}
	if (v == true) {
		return;
	} else {
		return;
	}
}

main :: proc() {
	result_true:  runtime.Source_Code_Location;
	result_false: runtime.Source_Code_Location;

	find_exit(true,  &result_true);
	find_exit(false, &result_false);

	fmt.println(result_true);  // prints line 11
	fmt.println(result_false); // prints line 13
}
```

### `#location() or #location(<entity>)`

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

### `#load(<string-path>) or #load(<string-path>, <type>)`

Returns a []u8 of the file contents at compile time. This means that the loaded data is baked into your program. Optionally, you can provide a type name as second argument; interpreting the data as being of that type.

```odin
foo := #load("path/to/file");
bar := #load("path/to/file", string);
fmt.println(bar);

// If a file's size is not a multiple of the `size_of(type)`, then any remainder is ignored.
baz := #load("path/to/file", []f32);
```

`#load` also works with `or_else` to provide default content when the file is not found.

```odin
foo := #load("path/to/file", string) or_else "Hellope";
fmt.println(foo);
```

### `#hash(<string-text>, <string-hash>)`

Returns a constant integer of the hash of a string literal at compile time.

Available hashes:

```odin
    "adler32"
    "crc32"
    "crc64"
    "fnv32"
    "fnv64"
    "fnv32a"
    "fnv64a"
    "murmur32"
    "murmur64"

hash :: #hash("interesting-string", "fnv32a");
```

### `#load_hash(<string-path>, <string-hash>)`

Returns a constant integer of the hash of a file’s contents at compile time.

This procedure has the same list of available hashes as #hash.

```odin
hash :: #load_hash("path/to/file", "crc32");
```

### `#load_directory(<string-path>)`

Loads all files within a directory, at compile time. All the data of those files will be baked into your program. Returns []Load_Directory_File, where Load_Directory_File looks like so:

```odin
Load_Directory_File :: struct {
	name: string,
	data: []byte, // immutable data
}
```

name is the name of the file and data is the contents of the file.

# Useful idioms

The following are useful idioms which are emergent from the semantics of the language.

## Basic idioms

### Ternary operator

The following two snippets are identical:

```odin
bar := condition ? 1 : 42;

bar := 1 if condition else 42;
```

You can also use ternary expressions with constants at compile-time:

```odin
DEBUG_LOG_SIZE :: 1024 when ODIN_DEBUG else 0;
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

foos := make([]Foo, num);

// By-value basic range-based loop, with implicit indexing
for (v, j in foos) {
	using v;
	fmt.println(j, v, f, i);
}

// Alternative range-based loop, with explicit indexing
for (_, j in foos) {
	using foo := foos[j]; // copy
	fmt.println(j, foo, f, i);
}

// By-reference range-based explicit indexing loop
for (_, j in foos) {
	using foo := &foos[j]; // "reference", changes to `f` or `i` are visible outside this scope
	fmt.println(j, foo, f, i);
}

// By-reference range-based through pointer
for (&v, j in foos) {
	using v; // `v` is now a variable reference as `foos` was passed by pointer
	fmt.println(j, v, f, i);
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

### Maybe(T)

Maybe(T) is a union which either returns a type T or nil. In other languages this is often seen as Option(T), Result(T), etc.

Loke has multiple return values, so Maybe(T) is used less frequently or rarely in the core library. Instead of doing -> Maybe(int) you could transform it to -> (int, bool).

```odin
halve :: proc(n: int) -> Maybe(int) {
	if (n % 2 != 0) do return nil;
	return n / 2;
}

half, ok := halve(2).?;
if (ok) do fmt.println(half);       // 1
half, ok = halve(3).?;
if (!ok) do fmt.println("3/2 isn't an int");

n := halve(4).? or_else 0;
fmt.println(n);                   // 2
```

## Advanced idioms

Subtype polymorphism with run-time type-safe down-casting:

```odin
Entity :: struct {
	id:   u64,
	name: string,

	variant: union{^Frog},
}

Frog :: struct {
	using entity: Entity,
	volume: f32,
	jump_height: i32,
}

new_entity :: proc($T: typeid) -> ^T {
	e := new(T);
	e.variant = e;
	return e;
}

entity: ^Entity = new_entity(Frog);
switch (e in entity.variant) {
case ^Frog:
	fmt.println("Ribbit:", e.volume);
}
```

### Implicit Type Conversions

The language is strongly and distinctly typed by default. Built-in implicit conversions are limited, but users may add visible `@(implicit)` conversion procedures for domain types. Overload resolution applies at most one user-defined implicit conversion to each argument.

- ^T -> rawptr
- [^]T -> rawptr
- [^]T <-> ^T
- All types to any (must be specialized/non-polymorphic)
- Any of its variants to the union
- T -> [N]T
- T -> #simd[N]T
- distinct proc <-> proc (same base types)
- Subtypes through using
- Untyped integers -> built-in numeric types that can represent them without truncation
- Untyped floats -> built-in numeric types that can represent them without truncation
- Untyped booleans -> all boolean related types
- Untyped rune -> all rune types
- Untyped strings -> all string types
- User-defined `@(implicit)` conversions whose procedures are visible in the current scope; this is how literals enter library numeric types

# Open questions

Decisions that are deliberately not yet made. Each one is recorded here rather than left implicit in normative prose. Earlier sections define the rule implementations must follow for the current language version; these questions concern possible later changes.

## Identifier character set

Should identifiers remain ASCII-only or adopt a normalized subset of Unicode identifiers? The current version accepts ASCII identifiers only. Unicode would improve native-language naming, but normalization, confusable characters, font support, and input ergonomics require a precise security policy before the rule can expand.

## Shadowing

Should inner scopes be allowed to shadow outer local variables? The current version rejects it except for the explicit parameter-copy idiom. Allowing shadowing is familiar and sometimes concise, while rejecting it prevents accidental reuse and makes references easier to follow.

## Package and import versioning

Should import paths encode package versions, and should a package declaration remain mandatory in every file? The current version requires the declaration and leaves dependency versions to the build system or package manager. A future package design may need reproducible version selection without making source imports depend on a particular registry.

## Default visibility

Should declarations be private rather than public by default? The current version is public-by-default with `@(private)` as the opt-out. Private-by-default reduces accidental API surface, while public-by-default matches the inherited Odin model.

## Retaining defer

Does scope-based `defer` provide enough clarity and utility to remain in the final language? Its current semantics are fully defined, including its ordering with automatic cleanup. The remaining question is whether explicit resource types and managed cleanup make most uses unnecessary.

## Unified compile-time model

Can `when`, build tags, attributes, and built-in directives be expressed through a smaller general compile-time facility without losing fast parsing, clear diagnostics, or predictable tooling? The current constructs remain normative until a replacement has complete syntax and staging rules.

## Sized boolean types

Are `b8`, `b16`, `b32`, and `b64` all necessary in addition to `bool`? They currently remain available for explicit layout and foreign interoperability. Removing some of them would simplify the basic type set but could push representation concerns into casts or wrapper types.

## Multi-pointer terminology

Is *multi-pointer* the clearest name for `[^]T`, or would *bounded-form pointer*, *C pointer*, or another term better communicate its unchecked indexing and foreign-memory role? The syntax and semantics are independent of the eventual name.

## Pure procedures

Should there be a form of procedure, distinct from `proc`, that is guaranteed by the compiler to be free of side effects?

The appeal is compile-time evaluation, safe reordering, and clearer contracts on `concept` requirements such as `hash` and `compare`. The cost is a second procedure kind, an effect system to police it, and the usual problem that a genuinely useful purity rule has to permit local mutation and allocation, at which point it stops being simple. Not required by anything in this document.

## Tuples

Should multiple return values be a real tuple type rather than a special form?

Today `a, b := swap(1, 2)` is a language rule that applies to return values and nothing else. A first-class tuple would unify multiple returns, multiple declaration, and pattern matching under one construct, and would let a tuple be stored, passed, and named. The counter-argument is that Odin's approach works, costs nothing, and never tempts anyone to return a tuple where a struct with named fields would document the code better.

## Toolchain identifiers

The `ODIN_*` compile-time constants and the source file extension are inherited unchanged in this document. Whether Loke renames them (`LOKE_OS`, `.loke`) or keeps Odin's for tooling compatibility is unresolved. The default calling convention is consistently named `loke`; this question concerns only the remaining toolchain-facing names.

## Runtime polymorphism

`concept` covers static polymorphism only. Dynamic dispatch — trait objects, interfaces, vtables — is repeatedly deferred to "a separate feature" in this document and has no design. Anything needing heterogeneous collections of behaviour currently has to use a union or a struct of procedure pointers.

## Borrow checking across procedure boundaries

The rule in [Borrows and lifetimes](#borrows-and-lifetimes) treats a returned borrow as derived from every borrowed argument whose storage is reachable through a parameter. It rejects results attributed to temporary arguments before they can escape, so it is sound but coarse and can force copies in code that does not need them. Whether that imprecision is acceptable in practice can only be answered by writing a real library against it.
