# `src/emit_llvm_entry.odin` review

Reviewed [`src/emit_llvm_entry.odin`](../../src/emit_llvm_entry.odin) at
`e1aab600`. The file owns the executable startup sequence, test dispatch,
object CPU constructor, and provider publication. Keep the baseline CPU
check ahead of entry calls and keep fallible entry reporting in its own unwind
frame. Formatting owns the failure payload's representation and cleanup,
while the runtime owns provider re-entry and completion state. These are
separate live paths. [CPU levels](../compiler-guide.md#cpu-levels) ·
[Fallible entry formatting](../../src/emit_llvm_format.odin#L66) ·
[Provider state](../../runtime/alloc.c#L119)

## Findings

### Named test arguments reach provider factories before selection [P2]

`emit_test_entry` calls `open_program_entry` before selecting a test.
`open_program_entry` caches the arguments and calls the provider initializer.
Only the later `loke_rt_v1_test_select` consumes the selector. A factory can
therefore observe the selector through `os.args`, although the test procedure
contract exposes only the executable path. An invalid selector can also run
the factory and terminate inside it before the required diagnostic and exit
status `2`. The current test-by-name fixture has no selected provider. Split
argument preparation from provider initialization and run test selection
between them. Keep thread attachment before provider execution and leave
allocator-before-logger publication in the provider body.
[Startup](../../src/emit_llvm_entry.odin#L22) ·
[Test selection call](../../src/emit_llvm_entry.odin#L122) ·
[Runtime selection](../../runtime/args.c#L119) ·
[Test procedures](../design.md#test-procedures) ·
[Test-by-name fixture](../../tests/corpus_test.odin#L1177)

For a regression, build this root with `-build-mode=test`.

```loke
@(default_allocator="./provider:factory")
package example;

@(test)
one :: proc() {}
```

Put this in the sibling `provider` directory.

```loke
@(public)
package provider;

import "core:mem";
import "core:os";

factory :: proc() -> Allocator {
    assert(os.args.len() == 1);
    return mem.default_allocator();
}
```

The current call order gives the factory an argument count of `2` when the
executable is run with `one` or an unknown name. After consuming the selector
first, `one` can pass and an unknown name can report the selection error.
This behavior follows from the source order. The proposed regression was
not run. [Argument count API](../../core/os/api.loki#L35) ·
[Provider initialization](../design.md#provider-initialization)

## Simplification and boundaries

- L101–120 `shrink:` Keep a runner name and its fallibility bit in one row,
  and fill the separate LLVM name-table entries in the same pass. Reuse the
  test symbol already read for its result. The name table still belongs in
  module storage because the C selector consumes a contiguous array of
  string pointers. [Test preparation](../../src/emit_llvm_entry.odin#L101)
- L125–127 `shrink:` Use `emit_value` for selection and the `-1` comparison,
  removing two manually assigned SSA names. [SSA helper](../../src/emit_llvm.odin#L691)
- L128–149 `delete:` Generate `test.failed` on first use by a fallible test.
  A package with zero or only void tests currently emits a block with no
  predecessor. Keep the two simple exits when both are reachable. Sharing the
  LLVM return would require a join and a status value. [Test exits](../../src/emit_llvm_entry.odin#L128)
- L153–156 `shrink:` End the reporter comment with “Returns the emitted name.”
  The generated function returns the exit status, while its emitter returns
  the name to the caller. [Failure reporter](../../src/emit_llvm_entry.odin#L153)

The runner preparation and SSA edits can remove roughly five source lines.
Lazy failure-label creation removes dead generated IR in the void-only case.
Ordered slices fit this direct dispatch and match the root package's test
order. With a name, the runtime looks it up linearly, then generated dispatch
still visits each test branch. Measure large packages before adding another
table or a separate dispatch path. [Test collection](../../src/test_procedures.odin#L66) ·
[Named and ordered dispatch](../../src/emit_llvm_entry.odin#L129)

## Verification

Static review traced the entry call order, name matching, termination,
provider publication, and failure cleanup. Inspected the existing
[entry IR expectations](../../tests/ll/m7_entry.expected),
[CPU constructor expectations](../../tests/ll/cpu_level_object.expected), and
[provider ordering fixture](../../tests/pkg/m8_providers/provider/provider.loke).
