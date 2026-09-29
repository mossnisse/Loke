# Packages

A package is a directory of `.loke` files. Every program so far has been one
package in one file. This page builds one from two packages and three files, and
shows how a package decides what the others can use.

## A program in two packages

The program keeps track of stock on a shelf. Its files are laid out like this:

```text
inventory/
    main.loke
    stock/
        shelf.loke
        report.loke
```

`inventory` is the `main` package, where the program starts:

**`inventory/main.loke`**

```odin file=inventory/main.loke
package main;

import "core:fmt";
import "stock";

main :: proc() {
	shelf: stock.Shelf = {};
	shelf.add("apples", 12);
	shelf.add("pears", 3);
	shelf.add("plums", 0);
	shelf.add("apples", 5);

	fmt.println("apples:", shelf.count("apples"));
	fmt.println("cherries:", shelf.count("cherries"));
	stock.print_report(shelf);
}
```

`inventory/stock` is the package `stock`, in two files. The first declares the
`Shelf` type and its methods:

**`inventory/stock/shelf.loke`**

```odin file=inventory/stock/shelf.loke
package stock;

// Items and how many of each are in stock. Only what is marked `@(public)` can
// be used by the packages that import this one.
@(public)
Shelf :: struct {
	counts: map[string]int,
}

impl Shelf {
	@(public)
	add :: proc(self: inout, item: string_view, amount: int) {
		if (item in self.counts) {
			self.counts[item] += amount;
		} else {
			self.counts[item.copy()] = amount;
		}
	}

	@(public)
	count :: proc(self, item: string_view) -> int {
		return self.counts.lookup_value(item) or_else 0;
	}
}
```

The second prints a report, using a helper that only the package can call:

**`inventory/stock/report.loke`**

```odin file=inventory/stock/report.loke
package stock;

import "core:fmt";

LOW :: 5;

@(public)
print_report :: proc(shelf: Shelf) {
	names: [dynamic]string = {};
	foreach (name, _ in shelf.counts) {
		names.append(name);
	}
	names.sort();
	foreach (name in names) {
		fmt.println(name, shelf.counts[name], status(shelf.counts[name]));
	}
}

// Not public: only this package can call it.
status :: proc(amount: int) -> string {
	if (amount == 0) { return "out"; }
	if (amount < LOW) { return "low"; }
	return "ok";
}
```

To build a package made of several files, give lokec its directory. From the
directory that holds `inventory`:

```powershell
lokec inventory -o inventory.exe
.\inventory.exe
```

```text output=inventory
apples: 17
cherries: 0
apples 17 ok
pears 3 low
plums 0 out
```

lokec compiles every `.loke` file directly inside `inventory` as the `main`
package, and follows its imports from there. It does not look into
subdirectories on its own: `stock` is compiled because `main.loke` imports it.

## Imports

`import "stock";` names a directory relative to the file that imports it. The
package is then used through its name, as in `stock.Shelf`. An import with a
prefix, such as `"core:fmt"`, comes from a *collection* instead: `core:` and
`base:` are the libraries that come with the compiler. A library of your own that
lives elsewhere gets a name the same way: a `loke.project` file beside
`main.loke` with the line `require shapes ../shapes` lets any file import
`"shapes:area"` (readme.md "Projects").

Every file in a package starts with the same `package` line, and each file lists
its own imports: `report.loke` imports `core:fmt` because it uses it, and
`shelf.loke` does not.

Two packages may not import each other, directly or through others. Code that
both need goes in a third package that both import.

## What a package shows

Everything in a package is private to it unless marked `@(public)`, so a package
decides exactly what the others can use. The files of one package see all of
each other's declarations, public or not: `report.loke` uses `Shelf` from
`shelf.loke`, and the private `status` and `LOW` are its own.

From `main`, the public names work as expected: `stock.Shelf`,
`stock.print_report`, and the `add` and `count` methods. The private ones are
rejected. Calling `stock.status(3)` from `main` is the error "`status` is not
public in package `stock`", with a note pointing at its declaration.

The same rule covers fields. `Shelf`'s `counts` field is not public, so `main`
cannot read `shelf.counts` or build a `Shelf` with a literal that sets it; it has
to go through `add` and `count`. That is what lets `stock` change how it stores
its counts later without breaking the programs that use it. As
[Records](03-records-enums-unions.md#records) showed, the same rule decides which
fields `fmt` prints.

A few more rules keep that promise:

- A literal of another package's record must name its fields, as
  `geometry.Point{x = 3, y = 4}`, never list them by position as
  `geometry.Point{3, 4}`. The package that declares the fields may reorder them.
- For the same reason, `a, b := value` can take apart only a record from your
  own package.
- A method is public when marked `@(public)`, like any other declaration.

`@(public)` in front of the `package` line makes every declaration in that file
public unless it is marked `@(private)`. It suits a package whose whole purpose
is to be used by others.

[design.md "Packages"](../design.md#packages) has the full rules.

Next: [A command-line tool](07-a-command-line-tool.md).
