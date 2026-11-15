# Compiler optimization review (2026-10-31)

Compiler-only material moved from the [language design review](design-review-2026-10-31.md#summary).
These observations and proposals preserve the language's specified behavior and
need no language-design change. This review is non-normative. Measurements and probes retain
the dates and compiler revisions of the original review; they have not been rerun
for this split.

Alias facts remain in the [language review](design-review-2026-10-31.md#alias-facts-from-the-one-rule)
because they require an unchecked-code aliasing contract. Compiler-chosen union
layout is recorded [there](design-review-2026-10-31.md#performance-opportunities-and-actual-semantic-limits) too:
design.md has left the layout to the compiler since 2026-11-11, and choosing
further niches waits on a measurement.

## Contents

- [Compiler context](#compiler-context)
- [Container fast paths](#container-fast-paths)
- [Checked arithmetic and bounds in loops](#checked-arithmetic-and-bounds-in-loops)
- [Small values and the existing ABI](#small-values-and-the-existing-abi)
- [Semantic constraints](#semantic-constraints)
- [Suggested order](#suggested-order)
- [Adopted optimizations](#adopted-optimizations)
- [Probes](#probes)

## Compiler context

The emitter produces one textual LLVM module for the whole program and hands
it to Clang at `-O0` through `-O3`, so cross-package inlining is free. Above
`-opt=none`, where `lld-link` sits beside Clang, the runtime is linked as
bitcode with `-flto`, so the optimizer sees it too. Within that design these
were the remaining opportunities, largest first; the first has since landed in
another form.

## Container fast paths

`x.append(v)` on a `[dynamic]int` lowered to a call of
`loke_rt_v1_dyn_append` with a table of function pointers for the element's
clone and drop, and a map lookup called `loke_rt_v1_map_find` with `key_hash`
and `key_equal` through pointers on every probe. Rust and Go both specialize
these; it was the single largest difference between Loke's collections and
theirs. Linking the runtime as bitcode
([Adopted optimizations](#adopted-optimizations)) made `bench/collections.loke`
9% faster, but LLVM still called `dyn_append` and `map_find` out of line from
its hot loops.

**The original proposal** was to emit the fast paths in the module as IR,
specialized per element type: `append` as "if `len < cap` store and increment,
else call grow", and map probing with the key's `hash` and `==` called
directly. Its cost was a second implementation of the probe sequence, in the
emitter, to agree with the runtime's growth and rehash forever.

**What landed** (2026-11-15) gets the specialization without that copy. The
operation table is a constant of the module, so a runtime function inlined
into a program already has a constant element size and direct thunk calls; only
their size kept LLVM from inlining them. `runtime/container.c` now splits
`dyn_append`, `map_find`, and `map_entry` into a small `always_inline` path
and an out-of-line remainder, with one probe shared by every map operation
([Container fast paths](compiler-architecture.md#container-fast-paths),
rationale under
[Container fast paths stay in the C runtime](comments.md#container-fast-paths-stay-in-the-c-runtime)).
The emitter is unchanged.

**What is left.** `dyn_reserve`, `pop`, `insert`, `remove`, and map removal
are still calls; none has been measured as hot. An optimized build that does
not link bitcode gains nothing. A program with very many lookup sites carries
the probe loop at each, which one emitted function per map type would bound if
it is ever measured to matter.

## Checked arithmetic and bounds in loops

Checked `+`, `-`, `*` lower to `llvm.*.with.overflow` plus a branch, weighted
unlikely, to a call of the `cold noreturn` panic entry. The measured cost is
in [Overflow checks in index arithmetic](open-questions.md#overflow-checks-in-index-arithmetic):
3.5 to 5.7 times on a column-major product, because the branch per element
blocks vectorization. Three steps keep the semantics and remove most of the
cost:

- **Find out why LLVM does not already remove the checks.** It folds an
  overflow intrinsic whose operands it can bound (IndVarSimplify through
  `eliminateOverflowIntrinsic`, and correlated value propagation). On the
  measured kernel the likely obstacle is the multiplication by a run-time
  extent, which no range bounds; confirm that before building an analysis.
- **Range facts for loop bindings and lengths.** A `foreach (i in 0 ..< n)`
  binding is in `[0, n)`; a slice or array length is at most
  `MAX_INT / size_of(T)`; a constant is itself. From these, `i + 1` is
  provably in range; so is `i * stride` for a constant stride when `n` is a
  length whose element size is at least the stride, and
  `row * columns + column` when `row < rows`, `column < columns`, and
  `rows * columns` was computed, checked, before the loop. The emitter can then
  write `add nsw` and a plain `getelementptr` instead of the checked forms. The
  same facts remove the bounds check on `xs[i]` inside a loop over
  `0 ..< xs.len()` only when the compiler proves the index is in bounds for
  the view used at that access. A sufficient condition is an unchanged valid
  header throughout the loop, including across calls and writes through mutable
  aliases. Slice type alone proves no such invariance: `xs = xs[:0]` can
  replace its header while the range retains its original bound, and a later
  `xs[i]` must still panic ([Probes](#probes)). Read-only elements do not make
  the slice variable constant. Track this fact for both slices and dynamic
  arrays, invalidating it when a write or call can change it.
- **Loop versioning** for the remaining affine index expressions: check once
  before the loop that the maximum index fits, and run an unchecked body when
  it does, the checked body otherwise. LLVM does this for runtime alias checks
  but not for overflow intrinsics, so it is the compiler's to do, at the cost
  of a second copy of the loop.

## Small values and the existing ABI

The earlier claim that slices and `Option(^T)` need a new register-passing ABI
was incorrect. `LARGE_VALUE_BYTES` is 4,096 bytes, and smaller ordinary values
already travel as LLVM values. An LLVM aggregate does not imply an indirect
machine argument: the assembly probe receives a slice in `rcx` and `rdx` and
an `Option(^int)` in `rcx` alone ([Probes](#probes)). The option already uses
the null niche specified under [Representation](design.md#representation),
and so do `Result(Unit, ^T)` and `Status(^T)`, since a `Unit` payload counts as
nothing there. There is no demonstrated small-value ABI change to recommend
here. Any further change needs a measured case; exposing a slice's pointer for
attributes under
[the alias proposal](design-review-2026-10-31.md#alias-facts-from-the-one-rule) is no longer
a reason to change its LLVM signature, since that proposal now uses scoped
metadata.

## Semantic constraints

Do not add a fast-math mode, relax the no-contraction rule, or make overflow
checking depend on the optimization level. The reproducibility contract
(`core:math/repro`, `core:random`, lockstep) is one of Loke's distinctive
promises, and every proposal above keeps it. Where a kernel wants a reassociated
reduction, a separately named operation says so, for example
`simd.reduce_add_unordered`, as the open question proposes.

## Suggested order

1. Range facts and loop versioning for checked arithmetic
   ([Checked arithmetic and bounds in loops](#checked-arithmetic-and-bounds-in-loops)),
   with bounds proofs that account for reassigned slices, aliases, and calls.
   Then measure the dense kernels again.

The language review's [alias proposal](design-review-2026-10-31.md#alias-facts-from-the-one-rule)
would be measured after that, once its language and correctness prerequisites
hold.

## Adopted optimizations

These were proposed by the original review and have landed. Commit references
and measurements are retained from that review, except the last entry's.

- **The program-ending runtime entries are `cold noreturn`**, and the branch
  to a checked operation's panic carries weights (`9e0c7f4f`). No run-time
  change beyond noise; it states what LLVM had inferred.
- **The runtime is linked as bitcode** in optimized builds where `lld-link` is
  available (`5b6a4da6`): run time 2 to 9% lower at `-opt=speed`, executables
  5 to 30% smaller, optimized builds 6 to 12% longer.
- **Unwind bookkeeping publishes only the locals a replay reads**
  (`c43c7e20`), so a procedure that registers nothing keeps no frame, live
  flags, or environment: `bench/dense.loke` 14% faster, within 5% of
  `-panic=abort`.
- **The container fast paths are inlined from the runtime**
  ([Container fast paths](#container-fast-paths)), in C rather than as emitted
  IR: at `-opt=speed`, appending `int`s 17% faster, `map[int]int` lookups and
  updates 19%, `map[string]int` 5%, `bench/collections.loke` 9% (medians of
  nine interleaved runs) and 15% in `perf.ps1`, executables at most 3 KB
  larger.

## Probes

The emitted-IR and reassigned-slice probes were run again on 2026-11-01 with
`lokec.exe` built from the sources at `4173b622`. The register-passing
observation is from 2026-10-31.

**Emitted IR carries no alias attributes.** For

```loke
sum :: proc(xs: []int) -> int {
	total := 0;
	foreach (x in xs) { total += x; }
	return total;
}
```

`lokec -emit-ll` produced (abridged):

```text
declare void @loke_rt_v1_panic(ptr) cold noreturn
...
define internal i64 @loke.p.sum(%struct.anon.143 %arg0) {
  ...
foreach.body.464:
  %t469 = getelementptr inbounds i64, ptr %t461, i64 %t467
  %t470 = load i64, ptr %t469
  %t471 = load i64, ptr %total.458
  %t472 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %t471, i64 %t470)
  %t473 = extractvalue { i64, i1 } %t472, 1
  br i1 %t473, label %int.overflow.474, label %ok.475, !prof !{!"branch_weights", i32 1, i32 1048575}
int.overflow.474:
  call void @loke_rt_v1_panic(ptr @.msg.4)
  unreachable
```

The slice parameter is an LLVM aggregate, so no `noalias` or `readonly` can be
attached to its data pointer in this ABI. The `%uframe`, `%ulive`, and `%uenv`
allocas and the per-iteration store into `%uenv` that the 2026-10-31 probe
showed are gone, since `sum` registers no cleanup. The container runtime
boundary was read from `runtime/loke_rt.h` and
`src/emit_llvm_containers.odin`: `append`, `insert`, `pop`, `remove`,
`resize`, `clone`, `drop`, and every map operation are calls into prebuilt C
taking a `loke_rt_container_ops_v1` table.

**A reassigned slice keeps the range's bound.** This program is accepted and
panics with `index out of range` and exit code 3:

```loke
package main;
import "core:fmt";

main :: proc() {
	values := [2]int{10, 20};
	xs := values[:];
	foreach (i in 0 ..< xs.len()) {
		xs = xs[:0];
		fmt.println(xs[i]);
	}
}
```

The range bound does not shrink when the slice is reassigned. The panic is
required behavior for a bounds-removal optimization to preserve.

**Small arguments travel in registers.** On 2026-10-31, Clang assembly
generated from emitted IR with `-S -O0` showed that the `sum(xs: []int)`
procedure above receives the slice's two words in `rcx` and `rdx`. A
procedure taking `Option(^int)` received its single word in `rcx`. These
observations check the small-argument ABI claim; they are not performance
measurements or a claim about every aggregate shape.
