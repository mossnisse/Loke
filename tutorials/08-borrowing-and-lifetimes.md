# Borrowing and lifetimes

The command-line tool mostly passed values around. When a procedure needs to
change existing data or return a view into it, its signature must describe that
relationship. This page builds on [Pointers and mutation](02-values-and-control-flow.md#pointers-and-mutation)
and [Who owns what](04-strings-and-containers.md#who-owns-what).

## Choosing a parameter

Use the narrowest form that expresses what the procedure needs:

| Parameter | What the procedure can do | Typical call |
| --- | --- | --- |
| `value: T` | Read a value for the call; an owning container is borrowed without cloning | `inspect(value)` |
| `value: inout T` | Change the caller's variable | `update(inout value)` |
| `value: ^T` | Read through a pointer, possibly returning a view into its storage | `view(&value)` |
| `value: ^mut T` | Write through a pointer | `update(&mut value)` |
| `values: []T` | Read a sequence without owning it | `sum(values)` |
| `values: []mut T` | Change elements without resizing the owner | `adjust(&mut values[:])` |
| `value: move T` | Take ownership | `consume(move(value))` |

`inout` exposes the variable directly. A pointer uses postfix `^` to access
its referent. Neither allocates memory. A `move` parameter is different: the
caller gives up the value, and the callee becomes responsible for it.

## Returning a view

A view can leave a procedure when its storage belongs to the caller:

```odin file=borrowed_results.loke
package main;

import "core:fmt";
import "core:strings";

first_word :: proc(text: string_view) -> string_view {
	foreach (word in strings.fields(text)) {
		return word;
	}
	return text[0:0];
}

largest :: proc(values: []mut int) -> ^mut int {
	assert(values.len() > 0, "largest needs an element");
	best := 0;
	foreach (index in 1 ..< values.len()) {
		if (values[index] > values[best]) { best = index; }
	}
	return &mut values[best];
}

main :: proc() {
	message := "hello from Loke";
	word := first_word(message);
	fmt.println(word);

	scores := [3]int{10, 30, 20};
	best := largest(&mut scores[:]);
	best^ += 5;
	fmt.println(scores);
}
```

```text output=borrowed_results
hello
[10, 35, 20]
```

`word` borrows `message`; `best` borrows an element of `scores`. The compiler
tracks these relationships through the calls. Neither procedure creates an
owner for the returned view. `best` is no longer used after the assignment,
so reading all of `scores` at the next line is allowed.

An ordinary owning parameter, such as `text: string`, is only borrowed for
the call. Use `string_view` when returning a substring of the caller's text;
use `^Record` when returning a view into a caller's record. Return an owning
`string` or container when the result needs independent storage.

## Separate mutable borrows

Two mutable views may coexist when the compiler can prove they do not overlap:

```odin file=separate_borrows.loke
package main;

import "core:fmt";

increase :: proc(values: []mut int, amount: int) {
	foreach (&mut value in values) { value += amount; }
}

main :: proc() {
	values := [4]int{1, 2, 3, 4};
	left: []mut int = &mut values[0:2];
	right: []mut int = &mut values[2:4];
	increase(left, 10);
	increase(right, 20);
	fmt.println(left, right);
	fmt.println(values);
}
```

```text output=separate_borrows
[11, 12] [23, 24]
[11, 12, 23, 24]
```

The constant ranges establish the separation. A mutable borrow is exclusive
over the storage it covers until its last use. Disjoint fields and constant
indices can establish the same separation. Arbitrary runtime indices do not
necessarily give the compiler enough information; shorten the borrows so they
do not overlap in time when it cannot prove separation.

## A local cannot back a returned view

This procedure tries to return a pointer to its own local variable:

```odin file=escaping_local.loke
package main;

bad :: proc() -> ^int {
	local := 42;
	return &local; // error, local would go out of scope
}

main :: proc() {
	_ = bad();
}
```

```text error=escaping_local
error[L0526]: this pointer cannot be returned: `local` ends when this procedure returns
 --> escaping_local.loke:5:9
   |
5 | 	return &local; // error, local would go out of scope
   | 	       ^^^^^^
  = note: escaping_local.loke:4:2: `local` is declared here
  = note: escaping_local.loke:5:9: the pointer is created here
```

Return `42` as an `int` here. For larger data, return an owning record or
container, or take caller-owned storage as an argument. Changing the local's
name or hiding it behind another procedure cannot extend its lifetime.

The [container lesson](04-strings-and-containers.md#views-must-not-outlive-what-they-view)
shows the other common failure: appending to an array while a view into it is
still in use. Use that view before the append, or copy the data that must
survive it.

[design.md "Borrows and lifetimes"](../design.md#borrows-and-lifetimes)
describes the full rules, including APIs that retain a borrow in another owner.
The longer [aliasing example](../examples/aliasing.loke) shows such an API.

Next: [Compile-time programming](09-compile-time.md).
