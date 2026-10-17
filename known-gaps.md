# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### Process output does not cancel promptly after a stderr read failure

`core/process/process.loke:159-208` disagrees with
[the process output contract](standard-library.md#coreprocess): either failed
pipe read must end the child. The stderr worker only publishes its result;
the parent checks it after reading stdout to EOF and joining the worker.

Minimal reproduction: call `process.output` on a child that writes enough
stderr to fail the parent's capture allocation, then keeps stdout open. With
the integration harness's failing allocator, a child that waits three seconds
after its stderr write makes `output` wait about 3.4 seconds before returning
`Out_Of_Memory`. A child that holds stdout open indefinitely prevents return.
The stdout failure branch already kills before joining. Give either reader a
way to terminate the child immediately on failure.

### Concurrent standard logging can split records across lines

`core/log/log.loke:70-76` implements the
[standard logger's line per record](standard-library.md#corelog) as five
independent formatting calls. Calls from two Loke threads can interleave
prefixes, levels, messages, and line endings.

```loke
package main;
import "core:log";
import "core:thread";
worker :: proc() {
    foreach (_ in 0 ..< 1000) { log.info("RECORD"); }
}
main :: proc() {
    first := thread.spawn(worker);
    second := thread.spawn(worker);
    first.join();
    second.join();
}
```

One run produced 598 malformed lines out of 2,000, including
`[[Info] RECORDInfo] RECORD` and empty lines. Compilation reports L0707
warnings but permits the program. Serialize a complete standard record, and
remove the stale source comment saying Loke cannot start threads. Custom
provider thread safety remains the provider's responsibility.

### Floating parsing follows the mutable C numeric locale

The [existing strconv question](open-questions.md#open-questions-in-corestrconv)
identifies this limitation. The review reproduced a concrete disagreement
with the [decimal parsing contract](standard-library.md#corestrconv): after
the C numeric locale changes to one using a decimal comma,
`strconv.parse_f64("1.5")` succeeds with `1.0` instead of `1.5`.

```loke
package main;
import "core:fmt";
import "core:strconv";
foreign loke_runtime {
    @(link_name="setlocale")
    set_numeric_locale :: proc "c" (category: i32, locale: cstring_view)
        -> Option(cstring_view) ---;
}
main :: proc() {
    _ = set_numeric_locale(4, "Swedish_Sweden.1252");
    fmt.println((strconv.parse_f64("1.5") or_else -1.0) == 1.5);
}
```

On a system where that locale is available, this prints `false`; it prints
`true` under the `C` locale. `core/strconv/strconv.loke:125` calls `strtod`
with no explicit locale and no end pointer. Use an explicit C numeric locale
or a locale-independent conversion, and verify full conversion consumption.
