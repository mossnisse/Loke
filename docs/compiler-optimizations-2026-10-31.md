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
blocks vectorization.

**The original proposal** was three steps that keep the semantics:

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

**What the first step found** (2026-11-15,
[Probes](#probes)) changes the other two:

- **Bounds checks do not block vectorization.** LLVM removes the check on
  `xs[i]` in a loop over `0 ..< xs.len()`. Where the bound is a separate `n`,
  or a second slice is indexed, it vectorizes up to the smallest of the bounds
  and leaves the panic to the scalar remainder. The slice header is one value
  at each access, so a reassigned slice is handled without the emitter
  tracking anything. The bounds half of the range-facts step, and the
  invalidation it needs, would buy nothing.
- **The checked addition in `xs[i + offset]` blocks it**, even when `offset`
  is computed before the loop. Nothing bounds `offset`, so LLVM cannot fold the
  intrinsic, and it takes no trip count from an overflow bit.
- **A checked multiplication invariant in the inner loop**, the `j*n` of
  `xs[i + j*n]`, blocks it at `-opt=speed` and not at `-opt=aggressive`. LLVM
  hoists the multiplication but leaves the branch on its overflow bit in the
  loop, behind an earlier bounds check, and unswitches that only at `-O3`. The
  multiplication is half of the obstacle, not the whole of it as the first
  step guessed.
- **The range facts as described do not reach the measured kernel.**
  `hand_multiply` in `bench/dense.loke` takes `n` as a parameter and never
  computes `n*n`, so no fact available before its loops bounds `i + j*n`. Only
  loop versioning would cover it.
- **A program can already write the fast form with every check kept**: slice
  once and index from zero, `column := out[mut j*n : j*n + n]` and then
  `column[i]`. The checked arithmetic runs once per column, and the loop is
  the first case above.

At `-opt=speed`, the same work takes 134 ms as written, 36 ms with wrapping
index arithmetic, and 33 ms with each column sliced once.

**What is recommended instead**, cheapest first:

1. Teach the slice-once form where users will find it. It needs no compiler
   change.
2. Let the bounds check stand in for the addition's overflow check. In
   `xs[a + b]` where one operand is known non-negative (a range binding whose
   start is non-negative, a length, a non-negative constant), the sum can
   overflow only upward, and the wrapped sum is then negative and fails the
   unsigned bounds comparison. So the emitter can add without a check, and
   test for overflow only in the cold block the bounds comparison already
   branches to, to choose between the two panic messages. This needs no loop
   analysis, no invalidation, and no second copy of a loop. It is not
   implemented; the probe's `+%` row stands for it, and shows it reaching full
   speed at `-opt=aggressive` and, at `-opt=speed`, only once the invariant
   multiplication is also written before the loop.
3. Leave range facts for arithmetic and loop versioning until a kernel is
   measured that neither of those covers.

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

1. The index addition whose overflow check the bounds check covers
   ([Checked arithmetic and bounds in loops](#checked-arithmetic-and-bounds-in-loops)).
   Then measure the dense kernels again. Range facts and loop versioning, which
   stood here, wait for a kernel that this and slicing once do not cover.

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
observation is from 2026-10-31. The index-arithmetic probe is from 2026-11-15,
at `b96b045f` with Clang 22.1.8.

**Which checks block vectorization.** Each loop below was compiled as its own
procedure with `-emit-ll` and optimized with `clang -O2`. `out` is a
`[]mut f64`, `a` a `[]f64`, and every other name an `int` parameter.

| Loop | Checks left | Vectorized |
| --- | --- | --- |
| `i in 0 ..< out.len()`: `out[i] = out[i]*f` | none | yes |
| `i in 0 ..< out.len()`: `out[i] = out[i] + a[i]*f` | bounds on `a`, in the scalar remainder | yes |
| `i in 0 ..< n`: `out[i] = out[i] + a[i]*f` | both bounds, in the scalar remainder | yes |
| `i in 0 ..< n`: `out[i + j*n] = out[i + j*n] + a[i + k*n]*f` | bounds and checked arithmetic | no |
| the same, with `j*n` and `k*n` computed before the loop | bounds and two checked additions | no |
| the same, with `+%` and `*%` | bounds | yes |
| the same, over `out[mut j*n : j*n + n]` and `a[k*n : k*n + n]` taken before the loop | bounds | yes |
| `c in 0 ..< columns`, inside `r in 0 ..< rows`: `out[r*columns + c] = 1.0` | bounds and checked arithmetic | no |

**What they cost.** `hand_multiply` from `bench/dense.loke` in four forms,
eight products of 256 by 256 matrices with `n` read at run time, in
milliseconds, each the fastest of seven runs. The timings repeat to within a
few milliseconds, and sizes of 64 and 512 give the same ratios at
`-opt=speed`:

| Form | `-opt=speed` | `-opt=speed -cpu=x86-64-v3` | `-opt=aggressive` |
| --- | --- | --- | --- |
| As written: `out[i + j*n]` | 134 | 118 | 119 |
| Checked `*`, wrapping `+%` | 103 | 91 | 36 |
| `+%` and `*%` | 36 | 37 | 35 |
| Checked, each column sliced once | 33 | 32 | 35 |

`bench/dense.loke` run with `-times` agrees: `Hand_Multiply 512` takes 134 ms,
and `Multiply 512`, the library's kernel, 21 ms.

One result is not explained. With `n` computed in the caller as
`511 + os.args.len()` rather than `64*os.args.len()`, and the kernels
inlined, the form as written ran as fast as the wrapping one, so LLVM can
remove these checks from some fact about `n`. A test of `n <= 1 << 30` before
the loops is not that fact: it changed nothing.

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
