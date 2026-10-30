# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

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

### A storing call rejects a named read-only reborrow

[Weakening and reborrows](design.md#weakening-and-reborrows) says that copies
of a read-only reborrow extend its loan without suspending the read-only
carrier itself. Passing such a copy to a
[`stored` parameter](design.md#retaining-a-borrow) is legal:

```loke
package main;
Node :: struct { value: int }
Holder :: struct { head: ^Node }
sink :: proc(value: int) {}
keep :: proc(p: ^mut Holder, @(escape=stored) n: ^Node) { p^.head = n; }
caller :: proc(p: ^mut Holder, @(escape=stored) r: ^mut Node) {
    read: ^Node = r;
    keep(p, read); // L0641, should be allowed
    sink(p^.head^.value);
}
main :: proc() {}
```

This compiled before `bb65c244` and is rejected by that commit.
`prov_reborrow_retained` in [cfg_provenance.odin](src/cfg_provenance.odin)
links `read` to the destination with `passes_on` left false, so the call's
own use of its read-only argument conflicts with the stored copy. Ordinary
copies in `prov_reborrow` set `passes_on` for read-only sources. Apply the
same rule to retained copies, and cover a named read-only reborrow as well
as the implicit weakening of a mutable argument. Found reviewing `bb65c244`
on 2026-10-30.

### Loading a stored named read-only copy loses its mutable source

[Weakening and reborrows](design.md#weakening-and-reborrows) keeps the mutable
source of a read-only reborrow suspended through copies, including copies
stored through a pointer and subsequently loaded:

```loke
package main;
Node :: struct { value: int }
Holder :: struct { head: ^Node }
sink :: proc(value: int) {}
caller :: proc(p: ^mut Holder, @(escape=stored) r: ^mut Node) {
    read: ^Node = r;
    p^.head = read;
    h := p^.head;
    r^.value = 1; // should be L0641: h still reborrows r
    sink(h^.value);
}
main :: proc() {}
```

This compiles both before and after `bb65c244`. Its new
`prov_slot_reborrows_mutable` in
[cfg_provenance.odin](src/cfg_provenance.odin) only recognizes an immediate
mutable source. Here the stored slot derives from `read`, which is read-only,
so `prov_reborrow_loaded` leaves the load's copies pending and the later use
of `h` does not keep `r` suspended. Resolve the transitive reborrow ancestry
when activating loaded read-only copies, including named intermediates.
Found reviewing `bb65c244` on 2026-10-30; this remains outside the direct
mutable-to-read-only store covered by that commit's regression cases.
