# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### A field read out of a temporary record is dropped twice or never

[Evaluation order](design.md#evaluation-order) destroys a complete expression's
temporaries once, at its end. Reading a field of a record temporary by value
moves that field out, but the backend drops the whole temporary afterwards when
a call produced it, field included, and never drops a literal's other fields:

```odin
Tracked :: struct { id: int }
impl Tracked {
	retire :: hook(drop) proc(self: inout Tracked) { fmt.println("drop", self.id); }
}
Pair :: struct { a: Tracked, b: Tracked }
make_pair :: proc() -> Pair { return Pair{Tracked{1}, Tracked{2}}; }

main :: proc() {
	x := make_pair().a;                   // drop 2, drop 1, then `x` drops 1 again
	y := Pair{Tracked{3}, Tracked{4}}.b;  // drop 4 at the end; 3 is never dropped
}
```

The temporary should drop only the fields not moved out (`drop 2`), and `x`
and `y` should each drop once.
