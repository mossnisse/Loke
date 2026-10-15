# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### Delegated operators stay in their package

[Delegating operators](design.md#delegating-operators) generates inherent
overloads, and inherent operators are found wherever the type is used
([Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution)).
The generated ones are found only inside the declaring package:

```loke
// meters/meters.loke
@(public)
package meters;
Meters :: distinct f64;
impl Meters {
    delegate(+);
}

// main.loke
package main;
import "core:fmt";
import "meters";
main :: proc() {
    a := meters.Meters(1.5);
    fmt.println(f64(a + a));
}
```

`a + a` is reported with L0318, "`+` does not apply to `Meters` and
`Meters`". The same expression inside package `meters` compiles. `core:time`
writes `Duration`'s `+` and `%` out by hand until this is fixed.

### `delegate(-)` omits unary minus

`delegate` generates "the underlying type's overloads of that operator", and
`f64` and the integers have a unary `-` as well as a binary one. Only the
binary overload is generated:

```loke
package main;
Meters :: distinct f64;
impl Meters {
    delegate(-);
}
main :: proc() {
    a := Meters(1.5);
    b := -a;
}
```

`-a` is reported with L0392: "`delegate-` does not apply: it takes 2
arguments, found 1". Declaring the unary `-` by hand beside the delegation is
then a redeclaration (L0420), so a type that wants both writes both by hand,
as `time.Duration` does. `delegate(~)` on a `distinct u32` likewise gives
binary `~` and no complement.
