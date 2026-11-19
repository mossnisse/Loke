# `src/customization.odin` review

Reviewed [`src/customization.odin`](../../src/customization.odin) at `ea622efe`.

## Findings

### Folded lengths discard receiver evaluation [P2]

At lines 25–33, `fold_standard_customization_call` stores the length as an
ordinary constant even when producing the receiver has effects. LLVM lowering
explicitly visits the receiver for a directly folded `len()` call. It misses
the receiver when the enclosing expression folds, as in
`make_array(inout count).len() + 1`. The compile-time evaluator returns the
constant before dispatching the call, so even an isolated
`make_array(inout count).len()` skips the receiver there. A procedure that
initializes `count` to zero, calls that expression with a `make_array` that
increments `count`, and returns `count` produces zero in both cases. Keep the
known length separate from the constant value used to skip evaluation. Let
runtime and compile-time evaluation visit the receiver exactly once, and
cover a folded parent expression as well as a direct call in the regression.
[Standard customization procedures](../design.md#standard-customization-procedures) ·
[LLVM expression lowering](../../src/emit_llvm_expr.odin) ·
[Compile-time evaluator](../../src/eval.odin) ·
[Direct-call regression](../../tests/run/standard_members.loke)

### Generated hash skips the nearest distinct type's policy [P2]

Lines 48–54 synthesize a wrapper's `hash` from the key policy. The policy's
`key_pair` goes from the requested type directly to its fully unwrapped
representation. If `Key :: distinct int` declares an always-equal `==`
and a `hash` returning its seed, then `Wrapped :: distinct Key` hashes
`Wrapped(1)` like an integer instead of returning that seed. The same key
policy drives maps and structural hashes. Walk the distinct chain until a
type declares either half of the policy, and require both at that level.
Use the same chain for comparison and hash signature discovery so map keys,
structural components, and direct calls agree. Test a wrapper around a
distinct scalar with a custom pair alongside the existing struct-wrapper test.
[Distinct types](../design.md#distinct-types) · [Maps](../design.md#maps) ·
[Key policy](../../src/hash.odin) · [Equality lookup](../../src/operators.odin) ·
[Distinct key regression](../../tests/run/distinct_key_pair.loke)

## Simplification and compiler boundaries

- Lines 13–20 append `len` and `cap` separately on dynamic arrays and maps.
  Each append allocates a replacement member slice in
  the semantic arena. Stage the one or two IDs in a fixed-size local slice
  and append once, keeping `type_is_container` as the test for capacity.
  Use explicit parameter modes at the two construction shapes and remove the
  helper at lines 74–84, whose mode slicing assumes at most two parameters.
  [Member storage and procedure synthesis](../../src/semantic.odin)
- Lines 60–69 perform a structural equality walk to list custom parts, then
  the hashability query walks the same shape and consults those policies
  again. Keep signature resolution in the checker. Move this shared
  preparation beside the map key policy in `hash.odin` so both call paths
  use the same traversal rules, especially when a distinct layer declares
  only one operation. The emitter and evaluator should consume the settled
  policy. [Key policy](../../src/hash.odin) ·
  [Structural equality traversal](../../src/operators.odin)

## Verification

Used `loke-source-review.exe` with `-emit-ll`. The folded runtime expression
emitted a return of the zero-initialized counter with no call to
`make_array`. The direct call emitted a call to `make_array` at runtime.
With that same direct call, the compile-time assertion
`static_assert(result() == 1)` reported `L0387` and the assertion against
zero passed. The hash assertions
`Wrapped(1).hash(7) == 7` and `Twice(1).hash(7) == 7`, where
`Twice :: distinct Wrapped`, both reported `L0387`. As controls, `Key`'s
own hash returned the seed and `Wrapped`'s agreed with `int`'s. Verified the
report's relative links and heading anchors. `check-citations.ps1` and
`bundle.ps1` passed.
