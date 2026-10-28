# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A mutable borrow of a sibling field wrapped for a call conflicts with a switched payload

[Switch ownership](design.md#switch-ownership) allows writing beside a payload
binding. Passing `&mut h^.count` directly to a procedure now compiles, but
wrapping the same pointer in a record for the call is rejected with `L0511`:

```loke
package main;
Node :: struct { value: int }
Holder :: struct { first: Option(^mut Node), count: int }
Arg :: struct { side: ^mut int }
bump :: proc(a: Arg) { a.side^ += 1; }
peek :: proc(h: ^mut Holder) -> int {
    switch (h^.first) {
    case .some(node):
        bump(Arg{&mut h^.count}); // should be allowed: `count` is beside `first`
        return node^.value;
    case .none:
    }
    return 0;
}
main :: proc() {}
```

The borrow's path-specific `.Through` event is correct. The special case in
`prov_call_argument` in [src/cfg_provenance.odin](src/cfg_provenance.odin)
recognizes its marker only when it is directly among the argument's slots.
Packaging the pointer loses that marker, so the call gets a pathless `.Through`
event covering the whole pointee. Keep the borrow's target path through
aggregate values, or make call write checks operate on the actual carriers
that can be dereferenced instead of widening their origin's path.
