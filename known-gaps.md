# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### The local time zone requires a Windows registry key

[Time zones](standard-library.md#time-zones) defines the local zone as the
zone the system's clock shows. A custom, fixed-rule Windows zone set with
`SetTimeZoneInformation` can have an empty `TimeZoneKeyName`. Windows still
uses its supplied offsets and transitions, but `system_rule` in
[zone.loke](core/time/zone.loke) always calls
`GetTimeZoneInformationForYear`, which needs a registered zone.

On a system with that legacy configuration, this program panics instead of
printing the local time:

```loke
package main;
import "core:fmt";
import "core:time";
main :: proc() {
    instant := time.parse_time("2026-07-01T12:00:00Z") or_else panic("a time");
    fmt.println(time.local_zone().to_local(instant));
}
```

A read-only probe reproduced the failing lookup without changing the system
setting: a `System_Zone` with an empty key, bias -60, daylight bias -60,
the last Sundays of March and October at 02:00 and 03:00, and
`dynamic_daylight_time_disabled = 1`. `GetTimeZoneInformationForYear(2026,
...)` returned zero with Windows error 2, so `system_rule` panics. The fixed
rule conversion `SystemTimeToTzSpecificLocalTime` succeeded and returned
14:00 for the instant above.

Decode the supplied zone's own rule when no registry key is available.
Microsoft documents the legacy configuration under
[SetTimeZoneInformation](https://learn.microsoft.com/en-us/windows/win32/api/timezoneapi/nf-timezoneapi-settimezoneinformation).
Found reviewing `4e84bec2` on 2026-10-31.

### Disabling dynamic Windows rules also disables fixed annual daylight saving

[Time zones](standard-library.md#time-zones) promises the zone the system's
clock shows. `system_rule` in [zone.loke](core/time/zone.loke) treats
`DynamicDaylightTimeDisabled` alone as disabling all daylight saving.
Windows also uses that flag for a fixed set of annual transitions: disabling
dynamic updates and disabling daylight saving are distinct. Microsoft
documents that disabling daylight saving also clears both transition dates
under
[DYNAMIC_TIME_ZONE_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/api/timezoneapi/ns-timezoneapi-dynamic_time_zone_information).

Use the program in [The local time zone requires a Windows registry
key](#the-local-time-zone-requires-a-windows-registry-key) with a registered
zone whose dynamic updates are disabled but whose standard and daylight
transition dates are retained. In a read-only probe with an installed zone
at -09:00 standard and -08:00 daylight, both returned transition months
remained nonzero (November and March). For 2026-07-01T12:00:00Z, Windows'
fixed-rule conversion returned 04:00, while `offset_in` returned -09:00,
making Loke show 03:00. No system setting was changed for the probe.

Preserve the supplied annual transitions when dynamic updates are off, and
distinguish that mode from cleared transition dates. Found reviewing
`4e84bec2` on 2026-10-31.

### Multiple assignment still rereads carriers stored in fields or whole records

[Evaluation order](design.md#evaluation-order) evaluates every destination
before any write, so the second destination below is `x.head`, reached
through the original `holder.pointer`:

```loke
package main;
Node :: struct { value: int }
Pair :: struct { head: ^mut Node, tail: ^mut Node }
Outer :: struct { pointer: ^mut Pair }
main :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3}; d := Node{4};
    x := Pair{&mut a, &mut b};
    y := Pair{&mut c, &mut d};
    holder := Outer{&mut x};
    holder.pointer, holder.pointer^.head = &mut y, holder.pointer^.tail;
    h := x.head;
    b.value = 7; // accepted, should be L0511: h points at b
    h^.value = 1;
}
```

This compiles with `5322493c`. Writing
`holder.pointer^.head = holder.pointer^.tail; holder.pointer = &mut y;`
instead reports `L0511` at `b.value = 7`. Replacing the multiple assignment
with `holder, holder.pointer^.head = Outer{&mut y}, holder.pointer^.tail;`
also compiles incorrectly.

`prov_assign` in [cfg_provenance.odin](src/cfg_provenance.odin) gathers
`written` only from bare identifiers for which `prov_slot_for_symbol`
returns one carrier slot. A field assignment contributes none, and neither
does a bare identifier holding a whole record. Destination preparation is
conditional on that list being nonempty, so these stores still read their
carriers after the first write. Prepare all multiple-assignment destinations
before writes, and preserve the carrier contents that field or aggregate
stores can replace. Cover both field and whole-record replacement. This is
a remaining unsound case after `d1ee2a57`, whose bare-carrier examples are
fixed. Found reviewing that commit on 2026-10-30.

### A public type alias in a generic `impl` is not read for private names

[Private names in public declarations](design.md#private-names-in-public-declarations)
reports a public declaration that names a private type. A public type alias
inside a non-generic `impl` is reported, but the same alias in a generic
`impl` is not:

```loke
package shapes;
@(private) Corner :: struct { x: int }
@(public) Box :: struct($T: type) { value: T }
@(public) Plain :: struct { value: int }
impl Plain {
    @(public) Inner :: Corner; // L0740
}
impl Box($T) {
    @(public) Inner :: Corner; // should warn L0740 too
}
```

A member of a generic `impl` is checked per instance, so its template has no
symbol, and `read_public_decl` in [src/private_names.odin](src/private_names.odin)
walks an alias's target only through its symbol. Reading the alias's type
instead would miss a private alias of a public type, which the syntax walk
reports. Found while closing the matching gap for constants on 2026-10-30.
