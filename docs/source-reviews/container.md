# `src/container.odin` review

Reviewed [`src/container.odin`](../../src/container.odin) at `ea622efe`.

## Findings

### Sort loses an inherited comparison [P2]

`resolve_element_order_policy` at lines 437–449 looks for an inherent `<`
on the exact element type and then checks for built-in ordering. It skips an
inherent comparison on the underlying type of a `distinct`. For example,
`Reverse :: distinct int` can define `<` as `int(a) > int(b)`. Sorting
`[dynamic]Twice{1, 2}`, where `Twice :: distinct Reverse`, emits an ascending
integer comparison. A distinct wrapper around a struct that supplies `<`
instead reports `L0651`. Ordinary `<` on the wrapped struct also fails, so
the comparison path needs the same inheritance rule. Walk the distinct chain
for inherent `<`, giving the nearest applicable declaration precedence, then
use built-in ordering. Keep the comparison shared by the compile-time evaluator
and LLVM lowering. [Distinct types](../design.md#distinct-types) ·
[Ordering rules](../design.md#comparison-operators) ·
[Operator lookup](../../src/operators.odin) · [Evaluator](../../src/eval_containers.odin) ·
[LLVM comparator](../../src/emit_llvm_containers.odin)

### Resizing to zero rejects elements with no zero value [P2]

`check_container_element` at lines 516–524 requires a zero value for every
`resize` call. With `Choice :: union { number: i32, flag: bool }`, a
`[dynamic]Choice` can append `.number(1)` but `values.resize(0)` reports
`L0424`. A zero length can only truncate, and the runtime and evaluator
already handle that case before zero-filling. Check the bound count at direct
call sites and exempt constant zero, mirroring `make`. Keep the requirement
when an unrestricted resize procedure is taken as a value or the count may
grow the array. Cover `try_resize(0)` and both receiver spellings as well as
the existing growth rejection. [Zero values](../design.md#zero-values) ·
[Dynamic array operations](../design.md#dynamic-array-container-operations) ·
[Runtime resize](../../runtime/container.c) · [Growth rejection](../../tests/err/zero_values.loke)

### Comments describe earlier insertion and allocation rules [P3]

Lines 208–210 say a `try_` insertion always copies and has no move-only
form. The move-only regression exercises fallible array and map insertions,
including dropping an owned element on failure. Lines 552–559 also say that
`make` and `try_make` return a two-value tuple, even though line 657 gives
`make` an owning container result and `try_make` a `Result`. Rewrite the
first comment to describe which spelling the helper identifies. Update the
second to describe the actual result forms. [Container insertion](../design.md#container-insertion) ·
[Container creation](../design.md#creating-and-releasing-slices-and-dynamic-arrays) ·
[Fallible move-only regression](../../tests/run/move_only_try_insertion.loke)

## Simplification and compiler boundaries

- Lines 241–259 and 315–350 allocate and immediately delete fixed-size lists
  of 17 and 15 symbol IDs. These are staging buffers because `add_members`
  copies the IDs into semantic storage. Use the compiler's temporary
  allocator for both buffers, or fixed-capacity stack arrays if the member
  construction stays straightforward. Keep the single commit to the owner
  and its declaration order. [Member storage](../../src/semantic.odin)
- Lines 208–214 recover fallibility from the member name for argument lowering
  and evaluation, while the LLVM member body tests for a union result at line
  453. Share the signature rule. The allocation status has type
  `c.alloc_result_type`, while `.Map_Find_Or_Insert` distinguishes a pointer
  from a `Result`. This keeps `Option`-returning operations outside the
  fallible cases and needs no new symbol field.
  [LLVM member body](../../src/emit_llvm_containers.odin) ·
  [LLVM argument handling](../../src/emit_llvm_calls.odin) · [Evaluator](../../src/eval_containers.odin)
- Keep the dense `CONTAINER_OP_EFFECTS` table. All its flags have readers, and
  its exhaustive rows let provenance and lowering ask about a new operation
  without duplicating lists of operation names. The checker should continue
  to settle the exact element/comparator policy and bind call operands before
  evaluation or emission. The runtime owns the storage algorithms and uses
  the header layout the compiler supplies. [Provenance](../../src/provenance_global_effects.odin) ·
  [Runtime container ABI](../../runtime/container.c)

## Verification

Ran focused `-emit-ll` probes using `loke-source-review.exe`. Constant-zero
resize reported `L0424`. The wrapped struct sort reported `L0651`, the bare
comparison reported `L0355`, and the integer wrapper emitted `icmp slt` in its
sort thunk. The existing move-only regression and the runtime/evaluator resize
branches were inspected in source. Verified the report's relative links and
heading anchors. `check-citations.ps1` and `bundle.ps1` passed.
