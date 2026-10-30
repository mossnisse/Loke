# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### Nine constant self-reslices still prevent an element store from replacing its contents

[Values that contain borrows](design.md#values-that-contain-borrows) lets a
store replace the contents of one known element. The reaching-definition
analysis added by the fix-gaps-1030 branch recognizes constant self-reslices
before a loop, but `publish_view_of` in [borrow.odin](src/borrow.odin) still
gives up at `depth > 8`, even for identity reslices:

```loke
package main;
Node :: struct { value: int }
Counted :: struct { head: ^mut Node, tail: ^mut Node, count: int }
main :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3}; d := Node{4};
    arr := [2]Counted{{&mut a, &mut b, 0}, {&mut c, &mut d, 0}};
    s := &mut arr[:];
    s = &mut s[0:]; s = &mut s[0:]; s = &mut s[0:];
    s = &mut s[0:]; s = &mut s[0:]; s = &mut s[0:];
    s = &mut s[0:]; s = &mut s[0:]; s = &mut s[0:];
    for (round := 0; round < 2; round += 1) {
        h := s[0].head;
        h^.value = 1;
        s[0].head = s[0].tail;
    }
}
```

This reports `L0641` at `s[0].tail`; removing one reslice makes it compile.
All nine definitions have the same constant start and length. The new
`publish_view_def` cache already detects a definition reached while its own
answer is being evaluated, so the old depth argument and cutoff can be
removed. An isolated compiler without them accepts the reproduction and
passes the borrow matrix and diagnostics suite, including reslices inside
loops and disagreeing branches. Found reviewing `81a9342c` against its
`main` parent on 2026-10-30. This is a remaining limitation of the closure,
rather than a new rejection of previously accepted code.

### Integer builtin registrations break dense scalar constraints

[`core:math/dense`](standard-library.md#coremathdense) accepts `f64` for
factorizations through `linalg.Scalar`, whose private associated `Real` type
is admitted by the [interface requirements](design.md#interface-bodies).
After `723d216d`, this ordinary program is rejected:

```loke
package main;
import "core:fmt";
import "core:math/dense";
main :: proc() {
    matrix := dense.Matrix(f64).identity(2);
    switch (dense.qr(matrix.view())) {
    case .ok: fmt.println("ok");
    case .err: fmt.println("err");
    }
}
```

The diagnostic is `L0444: f64 does not satisfy Scalar(f64)`. The existing
[QR](tests/trap/dense_qr_wide.loke),
[SVD](tests/trap/dense_svd_relative.loke), and
[eigensolver](tests/trap/dense_eigen_square.loke) trap cases fail at
compilation for the same reason, before reaching their intended checks.
[lib_dense.loke](tests/run/lib_dense.loke) also stops compiling, reporting
unresolved `T.Real` return types. These programs compile with the parent
compiler and library.

The trigger was isolated further using the same archived parent library:
the parent compiler accepts the examples, the new compiler rejects them,
and removing just the five new `contribute_builtin` calls from an isolated
compiler variant makes the minimal example and all three trap cases compile
again. The constant-rotation simplification in that variant cannot run in
this experiment, because the parent library has no new bit-operation calls.
This isolates the trigger to the new registrations in
[stdlib.odin](src/stdlib.odin); the underlying constraint-resolution cause
has not been established. Adding builtin symbols must preserve the existing
associated-type and extension requirements. Keep these integration cases
and add a focused compiler regression for the resolution failure when fixing
it. Found reviewing `723d216d` on 2026-10-30.

### Index-set storage counts overflow for valid positive capacities

The [index-set storage helpers](standard-library.md#corecontainer-index-sets)
return the words or bytes needed for a nonnegative capacity. Both helpers
in [index_set.loke](core/container/index_set.loke) add the rounding increment
before dividing, which overflows near `int.MAX` even though the answer fits:

```loke
package main;
import "core:container";
import "core:fmt";
main :: proc() {
    cap: int = 9223372036854775807;
    fmt.println(container.words_for_bits(cap));
    // Run separately with bytes_for_bits(cap) to reproduce its overflow.
}
```

Both calls panic with signed integer overflow, without allocating any set.
The correct results are `144115188075855872` words and
`1152921504606846976` bytes. Compute `cap/divisor` plus one when
`cap % divisor != 0`, rather than adding to `cap`. Apply the same arithmetic
to the fixed set's array-length expression, and cover zero, exact multiples,
and the upper `int` boundary. Found reviewing `723d216d` on 2026-10-30.

Confirmed independently when reviewing merge `4008ea61` against its first
parent on the same date: both helpers still panic for the capacity above,
using a compiler rebuilt from the merge.

### A multiple assignment's destination goes through its carrier's new value

[Evaluation order](design.md#evaluation-order) evaluates every destination of
a multiple assignment before any is written, and
[Values that contain borrows](design.md#values-that-contain-borrows) puts a
store where the carrier it goes through points. `prov_assign` in
[src/cfg_provenance.odin](src/cfg_provenance.odin) instead handles each
target in turn, so a later destination reached through a carrier an earlier
target redefines is taken to go through the new value (unsound):

```loke
package main;
Node :: struct { value: int }
Pair :: struct { head: ^mut Node, tail: ^mut Node }
main :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3}; d := Node{4};
    x := Pair{&mut a, &mut b};
    y := Pair{&mut c, &mut d};
    p := &mut x;
    p, p^.head = &mut y, p^.tail; // stores into x.head
    h := x.head;                  // points at b
    b.value = 7;                  // accepted, should be L0511
    h^.value = 1;
}
```

Writing `p^.head = p^.tail; p = &mut y;` instead reports `L0511` at
`b.value = 7`. A store into an element of a local view a multiple assignment
also reassigns is not narrowed to one element, so the narrowing adds nothing
to it. Closing it needs each destination's carriers read before the first
write, as the values already are (`prov_capture_slots`). Found while
closing the self-resliced view case on 2026-10-30.

### A store through a slice parameter at a variable index joins into the parameter

[Weakening and reborrows](design.md#weakening-and-reborrows) borrows a place
reached through a view for that place only, so storing `head` beside a borrow
of `count` is allowed. Through a slice parameter at an index that is not a
constant, it is rejected once a loop repeats it:

```loke
package main;
Node :: struct { value: int }
Counted :: struct { head: ^mut Node, tail: ^mut Node, count: int }
sink :: proc(value: int) {}
sliced :: proc(s: []mut Counted, k: int) {
    for (round := 0; round < 2; round += 1) {
        count := &s[k].count;
        s[k].head = s[k].tail; // L0641, should be allowed
        sink(count^);
    }
}
main :: proc() {}
```

The same body compiles with `s[0]` in place of `s[k]`, without the loop, or
over a fixed array or a local view, at a constant or a variable index;
`s[round]`, and `count := &s[0].count` beside a store into `s[k].head`, are
rejected too. A store through a view parameter lands in one element's own
slots only at a constant index (`prov_view_element` in
[src/cfg_provenance.odin](src/cfg_provenance.odin)). Any other store joins
into the parameter itself (`publish_into_loan` in
[src/borrow.odin](src/borrow.odin)), so the next iteration's copy of
`s[k].tail` holds the loans of the storage `count` borrows. A slot for the
elements at unknown indices, which such a store joins into without touching
the parameter, would close it. Found refreshing open-questions.md "Caller
storage contents" on 2026-10-30.

### A generic `impl`'s constant is not read by the type of its value

[Private names in public declarations](design.md#private-names-in-public-declarations)
reads a public constant with no written type by the type of its value. A
member of a generic `impl` is checked per instance, so its template has no
symbol and no type, and only its written syntax is read:

```loke
package shapes;
@(private) Corner :: struct { x: int }
@(public) Box :: struct($T: type) { value: T }
impl Box($T) {
    @(public) ORIGIN :: Corner{}; // should warn L0740, as it does in a non-generic `impl`
}
```

`read_public_decl` in [src/private_names.odin](src/private_names.odin) reads
the type from the constant's symbol. Reading it from the syntax would guess:
`Corner{}` names its type, but `size_of(Corner)` names a type and has another.
Writing the type, `ORIGIN: Corner : Corner{}`, is reported. Found while adding
the warning on 2026-10-30.
