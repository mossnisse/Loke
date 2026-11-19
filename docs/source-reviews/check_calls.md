# `src/check_calls.odin` review

Reviewed [`src/check_calls.odin`](../../src/check_calls.odin) at `ea622efe`.

## Findings

### Candidate-based calls expose conversion hooks by name [P2]

`associated_group` admits an associated generic procedure or group, and
`check_group_call` annotates the selected procedure at lines 361–377 and
460–485. The single-procedure and method paths apply `reject_direct_hook_call`
at lines 204 and 428. This allows a call by a generic hook's declaration name,
contrary to [Conversion hooks](../design.md#conversion-hooks).

```loke
package main;
Box :: struct($T: type) { value: T }
impl Box($T) {
    from :: hook(convert) proc(v: Box($U)) -> Box(T) where U != T {
        return Box(T){T(v.value)};
    }
}
main :: proc() { assert(Box(i32).from(Box(i64){7}).value == 7); }
```

The compiler emitted IR for both the named call and the permitted
`Box(i32)(Box(i64){7})`. A plain non-generic hook reported `L0412` when called
by name. The same bypass also reproduced for a group synthesized when crossed
generic `impl` blocks introduce hooks with the same name. User-written groups
check their members in [`src/check.odin`](../../src/check.odin) at lines 785–792.
Apply `reject_direct_hook_call` to the selected candidate in `check_group_call`
before recording it. Add a regression for both candidate paths and retain the
control for `Target(value)`.

### Group and direct calls disagree about a spread after omitted defaults [P2]

`bind_variadic_arguments` stops filling fixed parameters at the first spread
and fills their defaults at lines 1237–1249 and 1271–1275.
[`build_candidate`](../../src/overload.odin) at lines 476–516 puts the spread in
the next positional slot and rejects it if that slot precedes the pack. This
conflicts with the behavior of one member reached through a group under
[Variadic parameters](../design.md#variadic-parameters) and
[Default values](../design.md#default-values).

```loke
package main;
sum :: proc(start := 10, values: ..int) -> int { return start + values[0]; }
group :: proc{sum};
main :: proc() {
    values := []int{3};
    assert(sum(..values) == 13);
    assert(group(..values) == 13);
}
```

With only the direct call the compiler emits IR. The group call reports `L0392`
with a note that `..` spreads into a variadic parameter. A direct generic call
with a typed pack and the same defaulted prefix also reports `L0392`. The
[argument order test](../../tests/run/m7_argument_order.loke) already covers a
spread skipping a default on a direct call. Share the rule for the first spread
transitioning positional arguments into the pack, then use the usual
omitted-slot checks for any fixed parameters it skips. Verify direct, group,
and generic calls with a required prefix as well as a defaulted prefix.

### A group loses the pointee context for a typeless `..^T` element [P2]

The direct path at line 1324 passes each pack element to `pass_variadic_element`,
which recognizes typeless literals and supplies the pointee type in
[`src/variadic_lend.odin`](../../src/variadic_lend.odin). The group path at line
467 first collects argument types using `common_argument_type` in
[`src/overload.odin`](../../src/overload.odin) at lines 196–219, where a pack
with element `^Box` supplies `^Box` itself. The check fails before viability can
be tested. This is separate from the lifetime question in
[Literal elements that lend a temporary to a call](../open-questions.md#literal-elements-that-lend-a-temporary-to-a-call).

```loke
package main;
Box :: struct { value: int }
count :: proc(values: ..^Box) -> int { return values[0]^.value; }
group :: proc{count};
main :: proc() {
    assert(count({3}) == 3);
    assert(group({3}) == 3);
}
```

With only the direct call the compiler emits IR. The group call reports `L0376`
that `^Box` cannot be built from a composite literal. The same error occurs
with `count :: proc($T: type, values: ..^T) -> int { return values.len(); }`
called as `count(Box, {3})`, which reaches the deferred-typing path. Share the
context rule for lending elements between overload collection, deferred typing
at lines 939–952, and pack binding. Cover both call shapes in regressions.

## Simplification

- `written_arguments` at lines 969–978 creates an `Argument` slice solely for
  the synchronous chosen-variadic binder. Its contents are read while binding
  and the resulting call stores individual expressions and evaluation order.
  Allocate this adapter in `context.temp_allocator`, or use the written slot
  data already carried by the candidate when unifying the placement rules.
- The three order buffers at lines 760, 899, and 1226 allocate semantic storage
  even when the call uses natural slot order. Build the order in temporary
  storage and retain only a non-natural order, or detect the common identity
  case before allocating. Keep synthesized defaults after the written pack in
  variadic calls, as required by [Evaluation order](../design.md#evaluation-order).

## Responsibilities and verification

Call routing and result settlement belong here. Candidate ranking belongs in
[`src/overload.odin`](../../src/overload.odin). The findings identify duplicated
placement and contextual typing at their boundary. Keep the shared rules for
which slots and types the arguments can take distinct from overload ranking
and semantic evaluation. Named slot lookup already has one shared implementation
at lines 658–669. Its short linear scan fits ordered parameter declarations.
Separate written and slot order also remains necessary for evaluation.
No branch or helper proved dead in the reviewed call paths.

Ran the examples with `loke-source-review.exe <file> -emit-ll` from the
repository root, using scratch files under `tests/tmp`. The outcomes above
are compiler acceptance and diagnostics through IR emission. Checked all 12
relative links and their heading anchors.
