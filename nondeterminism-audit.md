# Nondeterminism and undefined behavior audit

2026-10-28. This is a review of the current language contract and the shipped
Windows x64 compiler/runtime, not a proposed change to the contract. The
normative rules are in [design.md](design.md) and [grammar.md](grammar.md).
Library contracts are in [standard-library.md](standard-library.md). A program
can be reproducible only after fixing its inputs, build configuration, target,
and relevant external state.

## Answer to the argument-order question

```loke
a := proc1(proc2(c), proc3(d));
```

`proc2(c)` is evaluated to completion before `proc3(d)` starts. `proc1` is
called only after both arguments have been prepared. If `proc2` panics or
diverges, `proc3` is never evaluated. Side effects performed on the calling
thread by `proc2` before it returns are visible to `proc3`; work it starts on
another thread still follows the synchronization rules. This is required by
[Evaluation order](design.md#evaluation-order),
implemented by the source-ordered operand loop in
[emit_bound_call](src/emit_llvm_calls.odin), and exercised by
[m7_argument_order.loke](tests/run/m7_argument_order.loke). It is not a choice
left to LLVM or the host C calling convention.

The rule also covers named arguments in **written** order, even if their names
select parameters in another order. A method evaluates its receiver first.
Omitted defaults run after supplied arguments, in parameter order. Built-in and
overloaded binary operators evaluate left then right. Literal elements run in
source order, including named struct fields and map key before value. A simple
or multiple assignment evaluates every right-hand value, then every destination
place, then writes left to right. A compound assignment evaluates its place
once before its right operand. `&&`, `||`, `or_else`, and conditional expressions
evaluate only selected operands. A complete expression destroys its temporaries
in reverse completed-initialization order. These are all specified in
[Evaluation order](design.md#evaluation-order); the assignment and call lowering
in [emit_llvm_stmt.odin](src/emit_llvm_stmt.odin) and
[emit_llvm_calls.odin](src/emit_llvm_calls.odin) follow that schedule.

## Classification

| Class | Meaning | Examples |
| --- | --- | --- |
| Defined order | Side-effect order is part of the program | Calls, literals, operators, assignments, defer/drop |
| Unspecified result | The operation has a bounded contract but no single result or order | Map traversal, equal-key sort ties |
| External or platform dependent | Different inputs or implementations can produce different valid results | Scheduling, addresses, clocks, C math library |
| Undefined behavior | The language makes no useful guarantee after a violated safety obligation | A data race, invalid pointer dereference, invalid ownership |
| Diagnosed error or panic | A defined failure, **not** undefined behavior | Integer overflow, bounds error, negative shift count |

The distinction matters: an unspecified map order still produces the map's
entries; a data race has no such bound. A current implementation's repeatable
choice does not turn an unspecified result into a language guarantee.

## Intentionally unspecified or nonreproducible results

| Area | Contract and consequence | Evidence |
| --- | --- | --- |
| Map iteration | Order can differ even for an unmodified map, so a loop with side effects can change output order. Collect and sort keys when order matters. Compile-time execution rejects map traversal. The runtime seeds each table from an atomic counter and its address and scans occupied slots. | [Maps](design.md#maps), [Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation), [container.c](runtime/container.c), [emit_llvm_iteration.odin](src/emit_llvm_iteration.odin) |
| Sorting and search | Sorts are not stable: equal-comparing elements can change relative order. An invalid comparator still yields a permutation and terminates, but order is unspecified. Binary search of an unsorted slice yields an unspecified index. The comparator's invocation schedule is not promised; do not use its side effects as an ordered log. | [Sorting slices](design.md#sorting-slices), [Slice queries and copies](design.md#slice-queries-and-copies) |
| SIMD extrema | When lanes compare equal, `reduce_min` and `reduce_max` may return either, including the differing bits of `-0.0` and `+0.0`. NaN lanes are skipped unless all are NaN. Add and multiply reductions, by contrast, fold left to right. | [`core:simd`](design.md#coresimd) |
| Implicit copies | Last-use transfer may elide a copy and its matching drop. The count of implicit copy-hook calls is unspecified. Copy hooks must preserve logical value and may not write global, static, or thread-local state. Explicit `clone` always calls the hook. | [Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types), [Last-use transfer](design.md#last-use-transfer) |
| Concurrent execution | Tasks and independent threads can interleave. Atomic reads have the outcomes allowed by the C++20-style memory model, rather than one chosen read; release/acquire, locks, joins, and channel commits add the stated ordering. Concurrent channel sends are ordered by commit, and waiters have no fairness promise. A pool task can run on a worker or a helping worker, affecting TLS and which thread executes a final `Shared(T)` drop. | [Concurrency and the memory model](design.md#concurrency-and-the-memory-model), [Structured concurrency](design.md#structured-concurrency), [`core:thread`](standard-library.md#corethread) |
| Addresses and representation | Pointer ordering is a total address order within one run, but address-space randomization can change it between runs. C ABI layout depends on the target; union tag encoding is deliberately unspecified for `unsafe.transmute`. A NaN literal's payload is implementation-defined. | [Comparison operators](design.md#comparison-operators), [`unsafe.transmute`](design.md#unsafetransmute), [Foreign-ABI-safe types](design.md#foreign-abi-safe-types), [String and character literals](design.md#string-and-character-literals) |
| `core:math` | The listed transcendental functions, including `sin`, `exp`, `pow`, and `hypot`, can differ in the last bits across processor paths, platforms, or optimization levels. Plain floating operations are evaluated and rounded separately, without contraction or reassociation, but that does not make calls into the C math library bitwise portable. | [`core:math`](standard-library.md#coremath), [Deterministic math functions](open-questions.md#deterministic-math-functions), [Floating-point operators](design.md#floating-point-operators) |
| Randomness | An explicitly seeded generator and its integer/unit draw mappings are reproducible. Entropy-seeded state is not. Some distributions use the nondeterministic math functions; even a fixed seed can then produce different values or consume a different number of draws on another machine. | [`core:random` Reproducibility](standard-library.md#reproducibility), [Random distributions across platforms](open-questions.md#random-distributions-across-platforms) |
| Process and system services | Clocks, entropy, environment, process I/O, filesystem contents, and concurrent changes to them are external inputs. `fs.read_directory` streams native enumeration without sorting; its documentation does not yet explicitly promise or disclaim an order. | [`core:time`](standard-library.md#coretime), [Filesystem operations](standard-library.md#filesystem-operations), [`core:random`](standard-library.md#corerandom), [`core:process`](standard-library.md#coreprocess) |
| Unspecified storage | `x: T = ---` is an unsafe assertion for plain data. It suppresses initialization checks and allows reads even though the bytes are unspecified; a foreign out-parameter must fill every part read before use. Ordinary `x: T;` instead starts dead and is checked. The exact consequence of reading bytes that do not represent a valid `T` needs clarification below. | [Built-in values](design.md#built-in-values), [Variable declarations](design.md#variable-declarations) |

## Undefined behavior and unchecked obligations

The spec explicitly calls these **undefined behavior**:

- Conflicting non-atomic accesses in different threads with no happens-before
  ordering are a data race. The compiler checks scoped tasks more strongly but
  cannot prove all pointer, foreign, and unscoped-thread accesses safe.
  [Concurrency and the memory model](design.md#concurrency-and-the-memory-model)
  and [What is not checked](design.md#what-is-not-checked) define the boundary.
- Dereferencing a dangling, misaligned, or otherwise invalid `^T` is undefined.
  An unchecked conversion or foreign call can manufacture such a pointer even
  though checked `^T` values are non-null. See
  [Address operator](design.md#address-operator) and
  [The `unsafe` package](design.md#the-unsafe-package).
- Invalid ownership is undefined: for example, a copy hook that shares
  exclusively owned storage, or a drop hook that leaves a live alias. See
  [Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types).
- A build-selected allocator factory returning shorter-lived storage is
  undefined. See [Provider initialization](design.md#provider-initialization).
- After `unsafe.take(place)`, treating the emptied storage as still holding a
  value is explicitly undefined. The `@(initialized)` live count is a trusted
  assertion that its prefix actually contains values. See
  [Uninitialized capacity](design.md#uninitialized-capacity).

Other unsafe obligations are stated without always naming the failure
"undefined behavior": a C pointer index or slice has no bounds check;
`unsafe.free` checks neither allocation identity nor allocator; runtime
`unsafe.transmute` does not diagnose an invalid destination representation;
a foreign enum result promises a declared member; and raw pointers, unchecked
views, or foreign code can hide lifetimes and aliases. Such violations can cause
invalid loads, double frees, or corrupt values. Their exact language-level
consequence should be specified rather than inferred from what LLVM happens to
do. See [C pointers](design.md#c-pointers),
[`unsafe.transmute`](design.md#unsafetransmute),
[Integer conversion](design.md#integer-conversion), and
[What is not checked](design.md#what-is-not-checked).

A broken `==`/`hash` coherence law is **not** itself undefined behavior: map
lookups may miss and iteration may repeat or skip, but the implementation must
still avoid unchecked memory access. An invalid sort comparator likewise keeps
the result a permutation. These are deliberately bounded failures under
[Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types)
and [Sorting slices](design.md#sorting-slices).

## Defined failure cases that can look like C undefined behavior

Integer `+`, `-`, `*`, `/`, and unary `-` panic on overflow, at every optimization
level; compile-time overflow is diagnosed. Integer division by zero panics, and
`MIN % -1` is zero. Negative shift counts panic (or fail compilation when
constant); counts at or beyond the operand width have fixed zero/sign-bit
results. Out-of-range indexing and slicing panic. Invalid float-to-integer
conversions panic. Floating division by zero follows IEEE-754. See
[Integer operators](design.md#integer-operators),
[Integer overflow](design.md#integer-overflow),
[Floating-point operators](design.md#floating-point-operators), and
[Panics and unwinding](design.md#panics-and-unwinding).

The backend guards LLVM division, remainder, shift, overflow, and
float-to-integer operations before their otherwise poison-producing cases; see
[emit_llvm_expr.odin](src/emit_llvm_expr.odin),
[emit_llvm_simd.odin](src/emit_llvm_simd.odin), and
[emit_llvm_calls.odin](src/emit_llvm_calls.odin). That is a source review, not a
proof that every generated path is free of backend bugs.

## Compiler and build reproducibility

Source files are sorted before package preparation, import edges are followed
in source order, and emission uses deterministic dependency order. The compiler
architecture describes one module in that order; see
[Driver and phase order](compiler-architecture.md#driver-and-phase-order) and
[packages.odin](src/packages.odin). Required compile-time procedure evaluation
rejects runtime randomness, clocks, files, threads, and map traversal, so a
constant cannot silently inherit those values. Target and project build
constants are explicit inputs. See
[Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)
and [Build constants](design.md#build-constants).

With the same source, path, and options, two fresh `-emit-ll` invocations for
`m7_argument_order` produced identical SHA-256 hashes; the same was true for
`m6b_maps`, which exercises maps and generated container code. This is evidence
for those two programs, not a byte-for-byte reproducible-build guarantee for
all executable, object, or debug artifacts. The compiler may also fold a call
to the C math library using the **build** machine's implementation at an
optimized level; the result can differ from another build or from a runtime
call on another processor. That behavior is explicitly documented under
[Deterministic math functions](open-questions.md#deterministic-math-functions).

## Implementation gap and audit follow-ups

1. **P1 — existing borrow-checker soundness gap.**
   [known-gaps.md](known-gaps.md#growing-a-container-two-pointers-away-during-its-own-traversal-compiles)
   contains a minimal program in which a `foreach` traverses a dynamic array
   through one nested pointer while another nested pointer appends to it.
   The compiler accepts it although the append may reallocate storage the loop
   still traverses. Fix the provenance reborrow at the unnamed inner pointer
   and add a regression rejection case. This audit did not execute the bad
   program or observe a crash.
2. **P2 — clarify invalid representations and `---`.** The spec permits an
   unchecked read of unspecified plain storage and says a runtime transmute
   with an invalid representation is not diagnosed, but does not explicitly
   distinguish an arbitrary valid value from undefined behavior when the bits
   are invalid for `bool`, an enum, or `rune`. Resolve this in
   [Open questions](open-questions.md#invalid-representations-at-unsafe-boundaries).
3. **P3 — state directory enumeration order.** The current implementation
   forwards the native enumeration. State explicitly whether callers may rely
   on any ordering and whether a directory modified during iteration has a
   stable snapshot. See
   [Open questions](open-questions.md#directory-enumeration-order-and-mutation).
4. **P3 — continue cross-machine math work.** The behavior is already
   documented and measured in
   [Deterministic math functions](open-questions.md#deterministic-math-functions)
   and [Random distributions across platforms](open-questions.md#random-distributions-across-platforms).

## Verification performed

- Reviewed the cited language and library sections, call/assignment/iteration
  emission, the map runtime, numeric guards, and the existing known gap.
- Compiled and ran `m7_argument_order`, `map_evaluation_order`, and `m2_assign`
  from `tests/run/` at `-opt=none` and `-opt=speed`; all six outputs matched
  their checked-in `.expected` files.
- Emitted LLVM IR twice each for `m7_argument_order` and `m6b_maps` from fresh
  compiler invocations; each pair was byte-identical by SHA-256.
- This is a targeted source and runtime audit, not exhaustive proof over every
  program, target, optimizer path, or interleaving. No unsynchronized race or
  invalid pointer was executed as a test.
