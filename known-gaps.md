# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A record built around a carrier parameter loses what the carrier views

[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)
says a value read through a carrier is in what the carrier views. A carrier parameter
whose targets the body cannot name, stored in a record the body builds, keeps no region
there: the record's content records owners, and what a carrier views only where its
targets are known (`prov_viewed_region` in
[provenance_regions.odin](src/provenance_regions.odin) falls back to the content at the
carrier's place only for a parameter's own). So the read through `reader.holder` is in no
region and the caller's reset compiles while the copy lives on. The same read through a
local copy of the pointer, `pointer := holder; pointer^.text`, is `L0537`:

```loke
package main;
import "core:mem";
import "core:strings";
Holder :: struct { allocator: mem.Allocator, text: string }
Reader :: struct { holder: ^Holder }
read_text :: proc(holder: ^Holder) -> string { reader := Reader{holder}; return reader.holder^.text; }
caller :: proc(@(allocator_reset) allocator: mem.Allocator) -> int {
    kept: string = "";
    { source := Holder{allocator, strings.copy("text", allocator)}; kept = read_text(&source); }
    free_all(allocator); // compiles, though `kept` is the arena's text
    return int(kept.bytes()[0]);
}
main :: proc() {}
```

This is a soundness gap. A fix records, where a carrier is stored in a record, what it
views as that place's content, as a view a read through it decides
(`region_read_through`). Passing the record to a callee, as `inner(Reader{holder})` or
`get(Reader{holder})^.text`, has it too. Found on 2026-11-08 while fixing "A read through
a carrier a call returned names no region".
