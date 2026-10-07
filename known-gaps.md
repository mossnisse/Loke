# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### Every statement is taken to be able to panic

[design.md "Panics and unwinding"](design.md#panics-and-unwinding) runs the
registered cleanups only when a panic happens. The checker models that unwind
from the start of every statement while a `defer` is registered, including
statements that cannot panic, so it rejects a cleanup order that only an
impossible panic would get wrong. This program is valid, since neither the
`if` condition nor dropping a `[dynamic]int` can panic, but `defer drop(arena)`
is `L0537`:

```odin
package main;
import "core:mem";
dropped_first :: proc(flag: bool) -> int {
    arena := mem.Arena.init();
    xs: [dynamic]int via arena.allocator() = {};
    defer drop(arena);      // L0537: a panic could unwind it before `xs`
    if (flag) {
        drop(xs);
        return 1;
    }
    drop(xs);
    return 2;
}
main :: proc() { _ = dropped_first(true); }
```

Registering the `defer` before `xs` is accepted and is the safer order anyway.
Narrowing the unwind points to the operations that can panic (calls, checked
indexing and arithmetic, conversions) would accept the program as written.

### A slot call on a temporary `dyn` view has no global effects

[design.md "Global write effects"](design.md#global-write-effects) makes a call
write whatever its callee may write, and a `dyn` slot call reaches every method
that fills the slot. The checker applies that when the view is a local, but not
when the receiver is the call that produced the view, so this program is
accepted although `touch` clears `cache` while `view` borrows it:

```odin
package main; import "core:fmt";
cache: [dynamic]int;
Touch :: interface($Self: type) { slot touch: proc(self: ^Self); }
Toucher :: struct {}
impl Toucher { touch :: proc(self: ^Toucher) { cache.clear(); } }
TOUCHER: Toucher = {};
view_of :: proc() -> dyn Touch { return (dyn Touch)(&TOUCHER); }
main :: proc() {
    view := cache[:];
    view_of().touch();      // should be L0512, as with `t := view_of(); t.touch();`
    fmt.println(view[0]);
}
```

`core:fmt`'s `format_any` keeps the recovered view in a local for this reason,
so printing still counts a `format` method's writes.

### A container's whole drop leaks the elements after a panicking hook

[design.md "What the unwind runs, and what it does not"](design.md#what-the-unwind-runs-and-what-it-does-not).

This prints `drop 1`, `drop 2`, then `outer cleanup`, and never `drop 3`. The array's cleanup is unregistered before `loke_rt_v1_dyn_drop` runs, as every cleanup is, so when element 2's hook panics nothing owes element 3 its drop. `clear` and a shrinking `resize` already shorten before each drop (`dyn_truncate` in `runtime/container.c`); a whole drop could do the same and stay registered until it finishes, and `loke_rt_v1_map_drop` likewise. `loke_rt_v1_map_remove` drops the key after copying the value out, so a panicking key hook leaves the copied value unowned.

```odin
package main;
import "core:fmt";
Tracked :: struct { id: int }
impl Tracked {
    release :: hook(drop) proc(self: inout Tracked) {
        fmt.println("drop", self.id);
        if (self.id == 2) { panic("drop failed"); }
    }
}
main :: proc() {
    defer fmt.println("outer cleanup");
    values := [dynamic]Tracked{Tracked{1}, Tracked{2}, Tracked{3}};
}
```

### Exact decimal narrowing loses the exponent or a second negation

[design.md "Unfixed constants"](design.md#unfixed-constants).

This prints `false 1.0000001 1.0`, although negating a literal twice must preserve its exact value before conversion to `f32`. `src/check_expr.odin` discards the retained decimal spelling on the second minus, causing intermediate `f64` rounding. Toggle the spelling's sign instead.

Separately, `x: f32 = 1e-9223372036854775808` prints `1.0` instead of underflowing to zero: `abs(min(int))` remains negative and `src/bigint.odin` skips its exponent loop. Large finite exponents also cause unnecessary arena-backed bigint work (`1e-1000000` exceeded a bounded 750 ms compile). Bound provable overflow/underflow before constructing powers and handle the signed minimum without `abs`.

```odin
package main; import "core:fmt";
main :: proc() {
    direct: f32 = 1.000000059604644775390625000001;
    negated: f32 = -(-1.000000059604644775390625000001);
    fmt.println(direct == negated, direct, negated);
}
```

### Compile-time local constants require a zero before their initializer

[design.md "Compile-time procedure evaluation"](design.md#compile-time-procedure-evaluation).

The valid `N :: 3` local constant makes this required evaluation fail with `L0311`. `src/eval.odin` calls `zero_value` before evaluating the written initializer, and an unfixed constant has no such zero. Evaluate the initializer first; require a default zero only when no initializer was written.

```odin
package main; compute :: proc() -> int { N :: 3; return N; } VALUE :: compute(); main :: proc() { _ = VALUE; }
```

### Compile-time evaluation rejects ordinary user operators

[design.md "Compile-time procedure evaluation"](design.md#compile-time-procedure-evaluation).

This is rejected with `L0341: a user operator has no compile-time meaning yet`, although the executed operator is an ordinary hermetic procedure. `src/eval.odin` explicitly rejects user unary, binary, slicing and assignment operators. Use the existing bound-call evaluator already used for user index operators, preserving overload fallback behavior.

```odin
package main; import "core:fmt";
Vec :: struct { x: int }
impl Vec { add :: operator(+) proc(a, b: Vec) -> Vec { return {a.x + b.x}; } }
compute :: proc() -> int { a := Vec{1}; b := Vec{2}; return (a + b).x; }
VALUE :: compute();
main :: proc() { fmt.println(VALUE, compute()); }
```

### Compile-time drop silently skips user hooks

[design.md "Compile-time procedure evaluation"](design.md#compile-time-procedure-evaluation).

This compiles and evaluates `VALUE` to 1 instead of diagnosing the reached panic in the drop hook. Explicit `drop` in `src/eval.odin` only writes zero storage; scope exit also processes written defers without executing custom managed drops. Execute the checked lifecycle operations on explicit drop and normal scope exit. Only explicit drop is directly reproduced here.

```odin
package main; T :: struct { n: int } impl T { release :: hook(drop) proc(self: inout T) { panic("drop ran"); } } compute :: proc() -> int { value := T{1}; drop(value); return 1; } VALUE :: compute(); main :: proc() { _ = VALUE; }
```

### A single dynamic-array spread reaches LLVM with the wrong carrier

[design.md "Variadic parameters"](design.md#variadic-parameters).

The checker accepts this, then linking fails with `L0403`: a `%loke.container` four-field dynamic-array header is passed where the variadic procedure expects a two-field slice. `src/check_calls.odin` accepts compatible spread carriers while the single-spread fast path in `src/emit_llvm_calls.odin` forwards the original value. Materialize the compatible carrier as the variadic pack before forwarding; the multiple-spread path already extracts data and length.

```odin
package main; sum :: proc(xs: ..int) -> int { result := 0; foreach (x in xs) { result += x; } return result; } main :: proc() { xs := [dynamic]int{1, 2}; _ = sum(..xs); }
```

### An inout result cannot return an existing map entry

[design.md "`inout` results"](design.md#inout-results).

This is rejected with `L0418: an inout result must return a place`. `src/check.odin` checks the return operand in value position, so map indexing never receives its place annotation. Check an `inout` return operand in `.Place` position, selecting an existing entry rather than insertion.

```odin
package main; import "core:fmt";
get :: proc(m: inout map[int]int) -> inout int { return inout m[0]; }
main :: proc() { m := map[int]int{0 = 1}; get(inout m) = 4; fmt.println(m[0]); }
```

### Dyn slot calls omit required argument mode validation

[design.md "Parameters"](design.md#parameters).

This compiles and prints 4, although `view.update(value)` must spell `view.update(inout value)`. `src/erased.odin` checks assignability but never validates the written argument mode. Reuse the ordinary call mode compatibility check before binding slot arguments.

```odin
package main;
import "core:fmt";
Update :: interface($Self: type) { slot update: proc(self: ^Self, target: inout int); }
Thing :: struct {}
impl Thing { update :: proc(self: ^Thing, target: inout int) { target = 4; } }
main :: proc() {
    thing: Thing = {};
    view: dyn Update = (dyn Update)(&thing);
    value := 1;
    view.update(value);
    fmt.println(value);
}
```

### File-scope when treats an offset_of field token as a lexical dependency

[design.md "Conditional compilation"](design.md#conditional-compilation).

This rejects `x` with `L0389` and consequently loses `VALUE`. `src/select.odin` treats the second `offset_of` argument as an expression needing lexical resolution, although it names a field token of `S`. Skip token arguments in this prepass as it already does for `build_config`, leaving the layout checker responsible for validating the field.

```odin
package main;
S :: struct { x: int }
when (offset_of(S, x) == 0) { VALUE :: 1; }
main :: proc() { _ = VALUE; }
```

### Static foreach accepts a reserved literal as its binding

[design.md "Predeclared names"](design.md#predeclared-names).

This compiles and prints 2 by shadowing the reserved literal `true`. `src/expand.odin` inserts static bindings directly into the scope without ordinary reserved-name validation. Validate written bindings before installing them. The spec permits these spellings as field/enum member names accessed by selector; that exception does not apply to a loop binding. Generic-name validation is a related unexecuted candidate.

```odin
package main; import "core:fmt";
main :: proc() { foreach ($true in [1]int{2}) { fmt.println(true); } }
```

### Reflection builtins accept invalid argument names and modes

[design.md "Parameters"](design.md#parameters) and ["Compile-time built-ins"](design.md#compile-time-built-ins).

Both calls below are accepted, although neither builtin has a parameter called `bogus` or an `inout` operand. `src/check_builtin.odin` omits its existing `builtin_arguments_ok` validation in the location and type-info handlers. Apply that shared argument-shape gate consistently.

```odin
package main; main :: proc() { x := 1; _ = source_location(bogus = inout x); id := typeid_of(int); _ = type_info_of(bogus = inout id); }
```

### Shared allocation failure ignores the allocator Trap policy

[design.md "Allocation failure"](design.md#allocation-failure).

With `-panic=unwind`, this prints `unwound` before a shared-allocation panic. The supplied `.Trap` allocator must terminate immediately without running that defer. `base/runtime/shared.loke` unconditionally calls `panic`; `core/slice/slice.loke`, `core/strings/strings.loke`, `core/strings/builder.loke` and `core/fmt/fmt.loke` contain the same wrapper pattern. Route ordinary failures through a shared policy operation carrying the original `Allocator_Error`, preserving the request size. Only shared construction was directly faulted.

```odin
package main;
import "core:fmt";
import "core:mem";
Payload :: struct { data: [2048]u8 }
main :: proc() {
    defer fmt.println("unwound");
    buffer: [256]u8 = {};
    arena := mem.Arena.from_buffer(&mut buffer[:], policy = .Trap);
    payload: Payload = {};
    handle := shared(move(payload), arena.allocator());
    fmt.println(handle.strong_count());
}
```

### Parsing negative zero as an integer panics

[standard-library.md "`core:strconv`"](standard-library.md#corestrconv).

This panics on a checked integer conversion instead of returning `.ok(0)`. `core/strconv/strconv.loke` computes unsigned `magnitude - 1` before converting the negative magnitude, so zero wraps to the largest `u64`. Guard zero before this conversion; `parse_int` inherits the same path.

```odin
package main;
import "core:fmt";
import "core:strconv";
main :: proc() {
    switch (strconv.parse_i64("-0")) {
    case .ok(v): fmt.println(v);
    case .err(e): fmt.println(e);
    }
}
```

### Windows process wait panics on high-bit exit statuses

[standard-library.md "`core:process`"](standard-library.md#coreprocess).

A Windows child that exits with code `0xffffffff` must yield `.ok(-1)`. Instead, `core/process/process.loke` checked-casts the `u32` code to `i32` and panics. Reinterpret the DWORD bits rather than range-checking them.

Build `exit-negative.exe` in the working directory from this Odin helper, then run the Loke program below:

```odin
package main
import os "core:os"
main :: proc() { os.exit(-1) }
```

```odin
package main;
import "core:fmt";
import "core:process";
main :: proc() {
    switch (process.run(process.Command{program = "./exit-negative.exe"})) {
    case .ok(code): fmt.println(code);
    case .err(error): fmt.println(error);
    }
}
```
