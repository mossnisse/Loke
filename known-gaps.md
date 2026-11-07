# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A pointer parameter's owner read takes a sibling handle's region

[Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)
says a handle's region does not back a sibling owner. A read of owners alone through a
carrier that a record parameter holds takes only what the owners there are in
(`Loaded_Read` in [carrier_shape.odin](src/carrier_shape.odin)), but a read through a
pointer parameter itself is not a loaded read: its region is the parameter's own, which a
call substitutes with the argument's whole storage region, handles included
(`prov_substitute_region` in [provenance_regions.odin](src/provenance_regions.odin)). So
the read through `holder: ^Holder` is rejected where the same read through
`reader: Reader`, holding `^Holder`, is accepted
([record_carrier_parameter_regions](tests/run/record_carrier_parameter_regions.loke)):

```loke
package main;
import "core:mem";
import "core:strings";
Holder :: struct { allocator: mem.Allocator, text: string }
read_text :: proc(holder: ^Holder) -> string { return holder^.text; }
caller :: proc(@(allocator_reset) allocator: mem.Allocator) -> int {
    buffer := [4096]u8{};
    other := mem.Arena.from_buffer(&mut buffer[:]);
    kept: string = "";
    { source := Holder{allocator, strings.copy("text", other.allocator())}; kept = read_text(&source); }
    free_all(allocator); // L0537, though `text` is in `other`
    return int(kept.bytes()[0]);
}
main :: proc() {}
```

This is an over-rejection, not a soundness gap. A fix records what was read for the
parameter's own region too, and substitutes a read of owners alone with the argument's
storage region less its allocator handles. Narrowed on 2026-11-07 from "An unknown-target
owner read loses its actual allocator dependency", whose record-parameter half is fixed.
