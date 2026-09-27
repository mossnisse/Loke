# Strings and containers

This page covers text, arrays, and maps, and the rules for who owns them: when a
value is copied, when it is shared, and when it is cleaned up.

## Strings

A `string` is text, always valid UTF-8, and it cannot be changed once made.
Operations on it say which unit they count in: `len` is in bytes, and
`rune_count` is in characters.

```odin file=text.loke
package main;

import "core:fmt";
import "core:strings";

main :: proc() {
	city := "Göteborg";
	fmt.println(city.len(), "bytes,", city.rune_count(), "characters");

	// Each character, with the byte offset where it starts.
	foreach (letter, offset in city.rune_offsets()) {
		fmt.println(offset, letter);
	}

	first_two := city[0:3];             // a view of bytes 0, 1, and 2
	fmt.println(first_two);

	greeting := "Hej, " + city + "!";
	fmt.println(greeting);

	fmt.println(strings.contains(greeting, "borg"), strings.to_upper("abc"));
	foreach (part in strings.split("red, green ,blue", ",")) {
		fmt.println(strings.trim_space(part));
	}

	builder: strings.String_Builder = {};
	foreach (i in 1 ..= 3) {
		if (i > 1) { builder.append(", "); }
		builder.append("step ");
		builder.append(rune('0' + i));
	}
	fmt.println(builder.finish());
}
```

```text output=text
9 bytes, 8 characters
0 G
1 ö
3 t
4 e
5 b
6 o
7 r
8 g
Gö
Hej, Göteborg!
true ABC
red
green
blue
step 1, step 2, step 3
```

- `ö` takes two bytes, so the string is 9 bytes but 8 characters. A `foreach`
  over a string gives characters, as `rune` values. `rune_offsets()` adds the
  byte offset where each one starts.
- `city[0:3]` is a *view*: it points into `city` rather than copying it. The
  bounds are byte offsets, and must fall between characters; `city[0:2]` would
  cut `ö` in half and panic.
- `+` makes a new string. For text built from many pieces, a
  `String_Builder` is faster: `append` adds to it and `finish` returns the
  string.
- The `core:strings` package has the searching, splitting, and trimming
  procedures. [standard-library.md](../standard-library.md#corestrings) lists
  them.

A view of a string has its own type, `string_view`. A procedure that only reads
text takes a `string_view`, and a `string` converts to one automatically, so it
accepts both. A view never owns its text; `.copy()` makes a `string` from it
when you need to keep the text.

## Arrays and slices

A fixed array has a length that is part of its type, as `[5]int`. A dynamic
array, `[dynamic]int`, grows as you append to it. A slice, `[]int`, is a view of
part of either one.

```odin file=arrays.loke
package main;

import "core:fmt";

total :: proc(values: []int) -> int {
	sum := 0;
	foreach (value in values) {
		sum += value;
	}
	return sum;
}

main :: proc() {
	// A fixed array: the length is part of the type.
	primes := [5]int{2, 3, 5, 7, 11};
	fmt.println(primes, primes.len(), primes[0]);

	// A dynamic array grows as you append to it.
	scores: [dynamic]int = {};
	scores.append(72);
	scores.append(95, 88, 61);
	fmt.println(scores, scores.len());

	scores[0] = 75;
	scores.sort();
	fmt.println(scores);
	fmt.println(scores.pop() or_else 0, scores);

	// A slice is a view of part of an array.
	middle := primes[1:4];
	fmt.println(middle, total(primes[:]), total(scores));

	// `&` in a `foreach` changes each element in place.
	foreach (&score in scores) {
		score += 5;
	}
	foreach (score, index in scores.indexed()) {
		fmt.println(index, score);
	}
}
```

```text output=arrays
[2, 3, 5, 7, 11] 5 2
[72, 95, 88, 61] 4
[61, 75, 88, 95]
95 [61, 75, 88]
[3, 5, 7] 28 224
0 66
1 80
2 93
```

- An index is checked: `scores[10]` panics instead of reading past the end.
  Assigning to an index never grows the array; `append` does.
- `pop` removes the last element. The array might be empty, so `pop` returns an
  `Option`, and `or_else 0` supplies a value for that case.
  [Errors](05-errors.md) explains both.
- `total` takes a `[]int`, so it accepts a slice of a fixed array, `primes[:]`,
  and a dynamic array, which converts to a slice of its elements.
- A `foreach` over a container gives each element without copying it. Write
  `&score` to change the elements, and `.indexed()` to number them.

## Maps

A map stores values under keys. `counts[key] = value` adds or replaces an entry.
Reading `counts[key]` requires the key to be there, and panics if it is not;
`lookup_value` asks without that requirement.

```odin file=maps.loke
package main;

import "core:fmt";
import "core:strings";

main :: proc() {
	text := "the cat and the dog and the bird";

	counts: map[string]int = {};
	foreach (word in strings.fields(text)) {
		if (word in counts) {
			counts[word] += 1;
		} else {
			counts[word.copy()] = 1;
		}
	}
	fmt.println(counts.len(), "different words");
	fmt.println("the:", counts["the"]);
	fmt.println("fish:", counts.lookup_value("fish") or_else 0);

	// A map has no order, so sort the keys to print them in a fixed one.
	words: [dynamic]string = {};
	foreach (word, _ in counts) {
		words.append(word);
	}
	words.sort();
	foreach (word in words) {
		fmt.println(word, counts[word]);
	}

	counts.remove("the");
	fmt.println("the" in counts);
}
```

```text output=maps
5 different words
the: 3
fish: 0
and 2
bird 1
cat 1
dog 1
the 3
false
```

- `strings.fields` splits text at spaces into views of it. A map stores its keys,
  so a new key must be a `string` of its own: `word.copy()`. Looking a key up,
  with `in` or `counts[word]`, works on the view directly.
- `foreach (key, value in counts)` visits every entry, in no particular order;
  the order can change from one run to the next. Sort the keys, as here, when
  the order matters.

## Who owns what

Strings, dynamic arrays, and maps own memory. You never free it yourself: when
the variable that owns it goes out of scope, the memory is released.

What happens when you assign one to another variable depends on the type. A
`string` cannot change, so a copy can safely share the same text, and copying it
costs nothing. A dynamic array or map *can* change, so assigning one **copies
it**: the new variable gets a second container of its own, which means
allocating memory and copying every element.

```odin file=copies.loke
package main;

import "core:fmt";

main :: proc() {
	first := [dynamic]int{1, 2, 3};
	second := first;        // a copy: a second array
	second.append(4);
	fmt.println(first, second);

	third := second;        // nothing reads `second` again: it moves
	fmt.println(third);
}
```

```text output=copies
[1, 2, 3] [1, 2, 3, 4]
[1, 2, 3, 4]
```

A copy costs time and memory in proportion to the container, and nothing on the
line shows it, so Loke skips it where it can. When the variable you copy from
is never read again, as `second` is not after `third := second;`, the assignment
hands the container over instead of copying it.
[design.md "Last-use transfer"](../design.md#last-use-transfer) has the exact
rule. Large copies are also reported: the compiler warns when one copies 512
bytes or more of a value itself (`-copy-cost=N` changes the limit).

When you want to be sure which of the two happens, say so:

```odin file=ownership.loke
package main;

import "core:fmt";

// Reading a container needs no copy: the parameter borrows the caller's.
largest :: proc(values: []int) -> int {
	best := values[0];
	foreach (value in values) {
		if (value > best) { best = value; }
	}
	return best;
}

// A new container made here is handed to the caller, not copied.
evens_up_to :: proc(limit: int) -> [dynamic]int {
	result: [dynamic]int = {};
	for (n := 0; n <= limit; n += 2) {
		result.append(n);
	}
	return result;
}

main :: proc() {
	original := [dynamic]int{4, 8, 15};

	extra := original.clone();      // always a copy
	extra.append(16);
	fmt.println(original, extra);

	moved := move(original);        // the same array under a new name
	fmt.println(moved);
	// `original` has no value now; using it again would be an error.

	fmt.println(largest(moved), largest(extra));
	fmt.println(evens_up_to(10));

	names := [dynamic]string{"Ada", "Grace"};
	first_name := names[0];         // strings copy freely: no allocation
	fmt.println(first_name);
}
```

```text output=ownership
[4, 8, 15] [4, 8, 15, 16]
[4, 8, 15]
15 16
[0, 2, 4, 6, 8, 10]
Ada
```

- `.clone()` makes an independent copy, even where plain assignment would
  move.
- `move(original)` hands the container over without copying it. `original` has
  no value afterwards, and the compiler rejects any later read of it, the same
  way it rejected the unassigned variable on the
  [previous page](02-values-and-control-flow.md#every-variable-has-a-value-before-it-is-read).
- Passing a container to a procedure copies nothing: the procedure borrows it
  for the call. Returning a container made inside the procedure hands it to the
  caller, also without a copy.

## Views must not outlive what they view

A slice or `string_view` points into memory that something else owns, so the
compiler checks that the owner stays valid while the view is in use. Appending
to a dynamic array can move its elements to new memory, so it may not happen
while a slice of the array is still used:

```odin file=invalidate.loke
package main;

import "core:fmt";

main :: proc() {
	numbers := [dynamic]int{1, 2, 3};
	first_two: []int = numbers[0:2];
	numbers.append(4);
	fmt.println(first_two);
}
```

```text error=invalidate
error[L0512]: `numbers` cannot be modified here: a read-only slice of it is still in use
 --> invalidate.loke:8:2
   |
8 | 	numbers.append(4);
   | 	^^^^^^^^^^^^^^^^^
  = note: invalidate.loke:6:2: `numbers` is the local this slice borrows
  = note: invalidate.loke:7:21: the slice is created here
  = note: invalidate.loke:9:14: and is still used here, which keeps it live
```

The notes point at the three places involved. A view is in use until its last
read, so moving `fmt.println(first_two);` above the `append` makes the program
valid. The same check stops a procedure from returning a view of its own local
variables, which would point at memory that is gone.

The rules are the same everywhere, and short: assignment copies unless the
source is not used again, `move` hands a value over, and a view may not outlive
or conflict with what it views. [design.md "Borrows and lifetimes"](../design.md#borrows-and-lifetimes)
has the full version.

Next: [Errors](05-errors.md).
