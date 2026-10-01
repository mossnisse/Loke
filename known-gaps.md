# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### An `inout` marker on a variadic argument is accepted

[design.md "Parameter semantics and ABI lowering"](design.md#parameter-semantics-and-abi-lowering)
makes `inout x` a parameter-mode marker for an `inout` parameter. The compiler
rejects it on an ordinary value parameter (`L0370`, "this parameter is not
`inout`"), but not on an argument bound to a variadic `..any` parameter: the
program below compiles and prints `a 3`, with the marker silently ignored.

```odin
package main;
import "core:fmt";

main :: proc() {
	n := 3;
	fmt.println("a", inout n); // should be L0370; compiles
}
```

Found while writing `examples/lexer.loke`, where a find-and-replace put the
marker on a `fmt.eprintln` argument.
