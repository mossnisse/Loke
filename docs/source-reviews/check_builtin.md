# Source review of check_builtin.odin

Reviewed [check_builtin.odin](../../src/check_builtin.odin) at `ea622efe`.
The exhaustive dispatch is useful. The checker resolves per-intrinsic operand
rules and records types, constants, and runtime operand order. The evaluator
and LLVM backend consume those annotations. A linear argument scan and a
semantic-arena slice fit the small operand lists. [Call checking](../../src/check_calls.odin) · [Evaluator](../../src/eval.odin) · [LLVM calls](../../src/emit_llvm_calls.odin)

## Findings

1. **P2 · `offset_of` accepts enum members, lines 569–589.** `field_named`
   searches enum members as well as record fields. The enum's layout has no
   offsets, and `type_field_offset` returns zero for the index. As a result,
   `E :: enum { First, Second }` followed by
   `static_assert(offset_of(E, Second) == 0);` passes. Require a storage field
   before calling `type_field_offset`. Keep the existing visibility check for
   actual fields. [Built-in procedures](../design.md#built-in-procedures) · [Member lookup](../../src/types.odin) · [Layout](../../src/layout.odin)

2. **P2 · `unsafe.transmute` accepts code-pointer destinations, lines 725–735
   and 755–766.** `bits := uintptr(1); _ = unsafe.transmute(proc(), bits);`
   compiles and emits an LLVM `inttoptr`. The spec defines a procedure value
   as a code pointer and limits pointer destinations to `rawptr` and C
   pointers. Reject an underlying `.Proc` destination and add a regression
   for it. Keep the check destination-specific since the restriction is on
   what the operation can produce. [Procedure type](../design.md#procedure-type) · [Transmute](../design.md#unsafetransmute) · [LLVM transmute](../../src/emit_llvm_expr.odin)

3. **P2 · Defaults containing `caller_location()` report the declaration,
   lines 1009–1029 and 1085–1098.** A bare default `at := caller_location()`
   supplies the caller's location. In `line := caller_location().line`, the
   selector folds before argument binding, preserving the declaration line.
   The default-value rule permits ordinary expressions, and the location
   rule describes evaluation at each call that omits the default. Carry the
   call-site span into default checking for occurrences inside an expression,
   before folding, using the same rule for direct and overload calls. Test
   explicit arguments and a `caller_location()` outside a default as controls.
   [Caller location](../design.md#caller_location) · [Default values](../design.md#default-values) · [Argument binding](../../src/check_calls.odin)

4. **P3 · `source_location` rejects a public qualified procedure name, lines
   1063–1080.** `source_location(dependency.greet)` reports L0573 when
   `dependency.greet` names a public procedure in an imported package. The
   declaration forms the spec describes include procedures, and an imported
   procedure is normally named through its package alias. Reuse the
   package-qualified symbol lookup used for callees and retain the test
   procedure check. For a lexical variable, keep using its declaring scope to
   derive the surrounding procedure. [Source location](../design.md#source_location-or-source_locationentity) · [Qualified lookup](../../src/generic.odin)

5. **P3 · Metadata contract comment, lines 1103–1105.** The comment promises
   `nil` for an unknown `typeid`. The spec and generated code return the
   shared entry zero with kind `Invalid`. Correct the comment to match both
   and retain the read-only pointer result. [Type metadata](../design.md#type-and-typeid) · [LLVM table lookup](../../src/emit_llvm_type_info.odin) · [Existing regression](../../tests/run/m6a_type_info.loke)

6. **P3 · Public descriptions omit supported forms, lines 178–185 and
   327–355.** `unsafe.raw_data` accepts `string_view` and `cstring_view`
   as well as `string`, while the normative operand list and interface
   comment name only `string`. The panic checker deliberately accepts
   `panic()`, as the runtime test expects, while the built-in table presents
   `message` as a required parameter. Settle both public contracts explicitly
   and update their listings and tests together. [Raw data](../design.md#unsaferaw_data-procedure) · [Unsafe interface](../../core/unsafe/api.loki) · [Built-in procedures](../design.md#built-in-procedures) · [Panic test](../../tests/trap/runtime_panic.loke)

7. **Simplify · Plain arguments and repeated layout reads, lines 226–239
   and 737–742.** Share the predicate for a positional `.Value` argument
   between shape helpers, preserving their diagnostic order and letting
   conversions keep their own error text. Cache the two sizes in local
   variables for the transmute comparison and diagnostic. The shared layout
   cache already avoids recomputing them, so this removes repeated lookups.
   [Conversion caller](../../src/check_calls.odin) · [Layout cache](../../src/layout.odin)

8. **Boundary · Drop the redundant copy-reporting list, lines 8–14 and
   553–644.** The lifecycle walk and call-copy reporting repeat the same
   seven unevaluated built-ins. The copy-reporting loop already ignores
   every intrinsic argument because `new_builtin_symbol` always supplies a
   procedure type with zero parameters. Return early for built-in symbols
   in that reporter and leave the lifecycle walk responsible for recognizing
   unevaluated calls. [Built-in symbols](../../src/universe.odin) · [Copy reporting](../../src/check_calls.odin) · [Lifecycle walk](../../src/cfg.odin)

9. **Simplify · Reuse the result of reading a value in type position, lines
   615–644.** `operand_type` says it checks once, but `resolve_call_type`
   checks generic procedure calls to learn whether they return a type.
   A call that returns an ordinary value is checked again by the fallback.
   The reflection checker repeats the same type-reading sequence. Let the
   type reader expose when it already checked a value and let both callers
   use its answer. Preserve the distinct defaulting and diagnostics for
   reflection and layout. [Type-call resolution](../../src/check_types.odin) · [Reflection](../../src/reflect.odin)

## Verification

Ran focused programs through the fresh compiler with `-emit-ll`. A real
second `int` field produced offset 8, and the enum's `Second` incorrectly
produced 0 in the same program. The code-pointer destination emitted
`inttoptr`. The direct default passed location line 5, while the nested
default passed the declaration's line 3 at the call on line 6. A two-package
probe produced L0573 for the public qualified procedure. The `string_view`
input to `unsafe.raw_data` compiled. The remaining findings used source and
caller tracing. No standalone dead code surfaced.
