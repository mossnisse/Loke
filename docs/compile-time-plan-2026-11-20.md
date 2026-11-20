# Compile-time measurements and plan (2026-11-20)

This report measures where a `lokec` build spends its time at `1cded689`, tests
several changes on copies of the emitted IR, and plans the ones worth making.
No compiler source changed for it. A figure here is an observation on one
machine, not a threshold.

## Summary

- clang takes 85–90% of a default build. The front end (`-emit-ll`) is
  160–350 ms of builds that take 1.3–1.9 s, and up to 5.5 s at `-opt=speed`.
- 54–87% of the emitted IR is functions nothing reaches. clang compiles all of
  it at `-opt=none`.
- Union storage is spelled in bytes and moved as whole values, so a `Result` or
  `Option` copy becomes dozens of single-byte loads and stores. Per IR line,
  clang's instruction selection is about 7 times slower on this output than on
  C.
- Emitting only reachable functions, spelling union payloads in words, and
  copying aggregates with `memcpy` cut clang's time 3–5 times in experiments
  whose programs still printed their expected output.
- Inside the front end, provenance analysis is 37–49% of the time and IR
  emission 23–32%.
- [Step 1](#1-emit-only-what-is-reachable) of the plan is done: a default build
  is 9–72% faster and one at `-opt=speed` 1–31%.

## Conditions

- Windows 10, build 19045, x64; 6 logical processors; processor identifier
  `Intel64 Family 6 Model 158 Stepping 12, GenuineIntel`.
- Odin `dev-2026-10-nightly:84bc3fc`; clang 22.1.8, target
  `x86_64-pc-windows-msvc`; MSVC 14.44.35207; Windows SDK 10.0.26100.0.
- `lokec` built from `1cded689` with `odin build src -o:speed`, as
  `release.yml` builds it. CPU level `x86-64`.
- No test suite or other compiler workload ran during a measurement.
- Timings are the fastest of 3 to 7 runs, as each table says. Those taken from
  PowerShell with a stopwatch include about 10 ms of process start; those taken
  from Git Bash include about 50 ms, and are marked.

The rewriting scripts and the profiling harness were throwaway and are not in
the repository. [Method](#method) says what each did.

## Whole builds

Fastest of 5, in ms, from PowerShell. The default optimization mode is
`-opt=none`.

| Program | `-parse-only` | `-emit-ll` | `-opt=none` | default | `-opt=speed` |
| --- | ---: | ---: | ---: | ---: | ---: |
| `examples/hello.loke` | 8 | 21 | 201 | 198 | 233 |
| `examples/lexer.loke` | 9 | 166 | 1389 | 1392 | 3988 |
| `examples/corpus_runner.loke` | 8 | 224 | 1806 | 1825 | 5481 |
| `bench/geometry.loke` | 9 | 353 | 1893 | 1877 | 2366 |
| `bench/linalg.loke` | 8 | 266 | 1498 | 1501 | 1670 |
| `bench/provenance.loke` | 7 | 21 | 198 | 198 | 245 |
| `bench/workspace` | | 160 | 1319 | 1328 | 1018 |

`bench/workspace` builds faster at `-opt=speed` than at `-opt=none`: an
optimizing build discards the unreachable functions before generating code for
them.

## What clang does with the module

### Compile and link, separately

The module compiled with `clang -c` and linked in a second command, against
the one command `lokec` runs. `-opt=none`, fastest of 3, in ms.

| Module | One command | `clang -c` | Link | Link with lld | Object (KB) | Executable (KB) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `hello.ll` | 145 | 58 | 100 | 104 | 24 | 276 |
| `lexer.ll` | 1267 | 1045 | 105 | 101 | 1452 | 1682 |
| `corpus_runner.ll` | 1511 | 1454 | 103 | 100 | 1967 | 2159 |
| `geometry.ll` | 1464 | 1378 | 102 | 102 | 2329 | 2354 |

The link is about 100 ms whatever the module. For `hello.loke`, the 198 ms
build less 21 ms of front end and 145 ms of clang leaves about 30 ms in
`lokec`'s own link step: finding the MSVC toolset and SDK, and hashing the
runtime sources to find the prebuilt set.

### Passes at `-opt=none`

`clang -c lexer.ll -O0 -ftime-report`: 1.057 s in passes, of which
`X86 DAG->DAG Instruction Selection` is 0.861 s (81%). The fast register
allocator is 0.039 s and the assembly printer 0.037 s. Within instruction
selection:

| Phase | Wall (s) |
| --- | ---: |
| Instruction Scheduling | 0.325 |
| Instruction Selection | 0.132 |
| DAG Combining 1 | 0.084 |
| DAG Combining 2 | 0.055 |
| Instruction Creation | 0.040 |

### The fast instruction selector is not used

At `-O0` clang selects instructions with FastISel and falls back to the slower
SelectionDAG for what FastISel cannot lower.
`-mllvm -fast-isel-report-on-fallback -Rpass-missed=sdagisel` on `lexer.ll`
reports 2356 misses, in all 822 of its 822 functions. The commonest:

| Missed instruction | Count |
| --- | ---: |
| `ret` of a struct or union value | 628 |
| `load` of a struct or union value | 401 |
| `store` of a struct or union value | 286 |
| `store` of an aggregate `zeroinitializer` | 180 |
| `ret i1` | 73 |
| `switch` | 64 |

Turning FastISel off (`-mllvm -fast-isel=false`) slows `clang -c` by 1–15%
([experiment table](#reachable-functions-only)), so it contributes little now.

### Instruction selection per line

The C runtime's `container.c`, compiled to IR at `-O0`, is 5679 lines of
FastISel-friendly IR; `lexer-live.ll` is the 13,138 reachable lines of
`lexer.ll`. Instruction selection time from `-ftime-report`:

| Module | Lines | With FastISel (ms) | Without (ms) |
| --- | ---: | ---: | ---: |
| `container.c` as IR | 5679 | 5.2 | 27.8 |
| `lexer-live.ll` | 13,138 | 399 | 455 |

Without FastISel that is 4.9 µs a line for the C and 35 µs a line for Loke's
output. Of the 3030 loads and stores in `lexer-live.ll`, 1277 move a whole
struct or union. A union's storage is spelled with its payload and padding in
bytes:

```llvm
%union.Result.$5bdynamic$5du8.Allocator_Error.113 = type { i64, [24 x i8], i8, [7 x i8] }
```

SelectionDAG splits a first-class load of that type into 33 loads, one per
scalar member, and the store that follows into 33 stores.

### Passes at `-opt=speed`

`clang -c lexer-live.ll -O2 -ftime-report`: 2.46 s in passes.

| Pass | Wall (s) |
| --- | ---: |
| InstCombinePass | 0.622 |
| SLPVectorizerPass | 0.509 |
| X86 DAG->DAG Instruction Selection | 0.496 |
| Greedy Register Allocator | 0.131 |
| Machine Instruction Scheduler | 0.111 |
| SROAPass | 0.106 |

The experiments below show that most of the InstCombine and SLP vectorizer time
is spent on the byte-wise union moves.

## What the module holds

| Module | Size (KB) | Lines | Functions | Reachable | Unreachable lines |
| --- | ---: | ---: | ---: | ---: | ---: |
| `hello.ll` | 72 | 1729 | 68 | 13 | 87% |
| `lexer.ll` | 1901 | 43,012 | 822 | 154 | 72% |
| `corpus_runner.ll` | 2666 | 58,569 | 1103 | 317 | 54% |
| `geometry.ll` | 5421 | 119,585 | 1999 | 378 | 72% |
| `linalg.ll` | 4458 | 99,396 | 1672 | 240 | 78% |
| `workspace.ll` | 1891 | 42,966 | 854 | 73 | 87% |

Reachable means reachable from a definition that is neither `internal` nor
`private` (`wmain`, `loke_rt_v1_sink_write`, and the two thread-local hooks),
following every `@name` in function bodies and global initializers. The
unreachable functions are the non-generic procedures of imported packages that
the program never calls: `core:math.fused_multiply_add`,
`core:fs.replace_atomic_native`, and `core:time.resolve_in` are the largest in
`lexer.ll`. `emit_package_items` in [emit_llvm.odin](../src/emit_llvm.odin)
emits every procedure of every package.

## Experiments on the emitted IR

Each experiment rewrote a copy of the `.ll` text and timed clang on it.

### Reachable functions only

`live` is the module without its unreachable functions and globals. Fastest of
3, in ms, from PowerShell. `LTO` is the whole `-opt=speed` command with
`-flto -fuse-ld=lld` and the prebuilt bitcode runtime.

| Module | `-O0` | `-O0` live | `-O0` without FastISel | `-O2` | `-O2` live | LTO | LTO live |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hello` | 58 | 38 | 59 | 48 | 45 | 178 | 173 |
| `lexer` | 1020 | 489 | 1072 | 2608 | 2445 | 3663 | 3005 |
| `corpus_runner` | 1232 | 730 | 1315 | 3515 | 3185 | 4944 | 4524 |
| `geometry` | 1399 | 373 | 1614 | 1518 | 1057 | 1873 | 1462 |
| `workspace` | 962 | 74 | 1032 | 578 | 277 | 837 | 503 |

### Union payloads in words, and `memcpy`

- **Words:** in a union whose storage starts with `i64` or `ptr`, payload
  padding of `8k` bytes is spelled `[k x i64]` and the explicit `[7 x i8]` tail
  after the tag is left to the struct's own padding.
  `{ i64, [24 x i8], i8, [7 x i8] }` becomes `{ i64, [3 x i64], i8 }`, the same
  size and alignment. Unions aligned to 4 or less were left alone.
- **`memcpy`:** a `load` of an aggregate whose only use is the `store` on the
  next line becomes `llvm.memcpy`, and a `store` of an aggregate
  `zeroinitializer` becomes `llvm.memset`. In `lexer-live.ll` that rewrites 138
  copies and 213 zero stores and leaves 481 aggregate loads, which feed a
  `store` elsewhere (194), an `extractvalue` (160), a `ret` (160), or a call
  argument (96).

`clang -c` in ms, fastest of 3, from Git Bash:

| Variant | `lexer` `-O0` | `corpus_runner` `-O0` | `geometry` `-O0` | `lexer` `-O2` | `corpus_runner` `-O2` | `geometry` `-O2` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| As emitted | 1075 | 1430 | 1481 | 2757 | 3866 | 1549 |
| Words and `memcpy`, all functions | 464 | 606 | | | | |
| Live | 554 | 880 | 439 | 2456 | 3597 | 1169 |
| Live, words | 233 | 377 | 379 | 988 | 1894 | 1031 |
| Live, words, `memcpy` | 208 | 324 | 346 | 564 | 1006 | 1096 |

`geometry` has no figure for the second row: the script mishandled a constant
of a 4-aligned union there, and clang rejected the module.

Object sizes in KB:

| Variant | `lexer` `-O0` | `corpus_runner` `-O0` | `geometry` `-O0` | `lexer` `-O2` | `corpus_runner` `-O2` |
| --- | ---: | ---: | ---: | ---: | ---: |
| As emitted | 1452 | 1967 | 2329 | 139 | 212 |
| Live | 577 | 1063 | 573 | | |
| Live, words | 229 | 427 | 477 | | |
| Live, words, `memcpy` | 154 | 304 | 412 | 56 | 115 |

The `memcpy` rewrite alone, on the modules as emitted, took `lexer` from 1098
to 860 ms and `geometry` from 1502 to 1265 ms.

### The rewritten modules still run

`bench/geometry.loke`, `bench/collections.loke`, `bench/containers.loke`, and
`bench/binary.loke`, each emitted, reduced to reachable functions, and given
both rewrites, were linked against the prebuilt runtime at `-O0` and at `-O2`
with LTO. All eight executables printed their `.expected` output.
`bench/linalg.loke` was not checked, for the script fault above.

### What the three changes would give

For `examples/lexer.loke`, from the figures above:

| Build | Now (ms) | Estimate (ms) |
| --- | ---: | ---: |
| default | 1392 | about 500 |
| `-opt=speed` | 3988 | about 1300 |

The estimate adds the front end (166 ms), `clang -c` on the rewritten live
module (208 or 564 ms), and the link (about 100 ms, or the 560 ms the LTO link
added to `clang -c` in the first table). The LTO link was not timed on a module
with both rewrites.

## Inside the front end

### Phases

A harness calling `init_session`, `check_session`, and `emit_session_ir`,
built `-o:speed`. Fastest of 7, in ms.

| Program | Check | Emit | IR (KB) |
| --- | ---: | ---: | ---: |
| `examples/hello.loke` | 6.7 | 1.0 | 72 |
| `examples/lexer.loke` | 115.2 | 29.2 | 1900 |
| `examples/corpus_runner.loke` | 156.4 | 38.0 | 2665 |
| `bench/geometry.loke` | 233.3 | 93.1 | 5420 |
| `bench/linalg.loke` | 171.5 | 68.8 | 4458 |
| `bench/workspace` | 114.6 | 28.0 | 1890 |

### Provenance construction

The repository's probe, `bench/provenance_profile`:

| Program | Check (ms) | Body builds | Replay passes | Normalization (ms) | Replay (ms) | Materialization (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `examples/lexer.loke` | 104.1 | 1584 | 861 | 37.0 | 4.1 | 4.2 |
| `bench/geometry.loke` | 211.4 | 3935 | 818 | 78.1 | 3.7 | 3.6 |
| `bench/workspace` | 104.4 | 1551 | 832 | 36.9 | 4.1 | 4.1 |
| `examples/corpus_runner.loke` | 141.2 | 1936 | 1191 | 52.3 | 6.0 | 6.2 |

Normalization, the construction walk of
[Normalized provenance input](compiler-architecture.md#normalized-provenance-input),
is 35–37% of checking. `examples/lexer.loke` has 514 checked bodies and 1584
builds: each body is built once collecting global writes
(`collect_body_effects`), once or more settling result summaries
(`summarize_body`), and once for diagnostics (`analyze_provenance`);
`thread_summaries.odin` builds bodies as well. The summary passes build in
`.Prov_Summary` mode and the diagnostic pass in `.Prov_Diagnose`. The walk in
`cfg.odin` only tests the mode against `.Lifecycle`, but
[provenance_results.odin](../src/provenance_results.odin) and
[provenance_retention.odin](../src/provenance_retention.odin) tell the two
apart in six places: a diagnosing build reports result diagnostics, and a
summary build records which callee summaries it consulted.

### Procedure profile

The same harness with Odin's `@(instrumentation_enter)` and
`@(instrumentation_exit)` hooks, which time every procedure with the cycle
counter. The hooks roughly double the run time and charge most to small, often
called procedures, so the inclusive shares of large procedures are usable and
the self times of small ones are not: `bounds_check_error` shows 7.6% self
time over 13.2 million calls, each of which is an inlined compare in an
ordinary build.

Inclusive share of front-end time:

| Procedure | `examples/lexer.loke` | `bench/geometry.loke` |
| --- | ---: | ---: |
| `check_session` | 76.6% | 67.7% |
| `analyze_program_provenance` | 49.4% | 37.0% |
| `build_flow_graph` | 42.1% (2098 calls) | 34.7% (5246 calls) |
| `settle_result_summaries` | 18.8% | 12.3% |
| `analyze_provenance` | 17.4% | 13.0% |
| `compute_global_writes` | 13.2% | 11.7% |
| `load_package_dir`, with lexing and parsing | 13.9% | 11.5% |
| `check_package_bodies` | 11.5% | 12.0% |
| `emit_llvm_module` | 23.1% | 31.9% |
| `fmt.sbprintf`, all callers | 15.0% (84,631 calls) | 21.9% (283,351 calls) |

`fmt.sbprintf` is about two thirds of emission time. Odin's map internals
(`dynamic_map_internal.odin`) hold 11.6% of self time on the lexer example,
with 33,290 calls of `map_grow_dynamic`; given the bias above, that needs a
sampling profile before anything is changed for it.

### How the compiler is built

`-emit-ll` in ms, fastest of 7, from Git Bash:

| Program | `-o:speed` | `-o:speed -no-bounds-check` | `-o:minimal` | `-o:speed`, compiling with `-g` |
| --- | ---: | ---: | ---: | ---: |
| `examples/lexer.loke` | 220 | 199 | 453 | 241 |
| `bench/geometry.loke` | 406 | 397 | 950 | 454 |
| `examples/corpus_runner.loke` | 247 | 254 | 587 | 288 |

`test-all.ps1` without `-Full` builds `lokec` with `-o:minimal`, so its front
end is 2.1–2.4 times slower than a release's. `-g` grows the module from 1.9 to
3.1 MB for the lexer example and from 5.5 to 9.3 MB for geometry; a `-g` build
of the lexer example takes 1649 ms.

## Plan

In this order. Each step is measured with `perf.ps1` before and after, as
[Testing and verification](compiler-architecture.md#testing-and-verification)
describes, with the record added under `bench/baselines` and a line in
`CHANGELOG.md`.

### 1. Emit only what is reachable

A pass over the finished module text at the end of `emit_llvm_module`, before
`attach_debug_info`, in a file of its own.

- Split the text into `define` bodies, globals, and everything else.
- Scan each body and each global initializer for `@name` references.
- Keep what is reachable from every definition that is neither `internal` nor
  `private`, and from every global with external linkage. Drop the rest.
- Keep the order of what remains, so the module is the same text less the
  dropped definitions.

It reads only the module text, so no part of the emitter has to say what it
refers to: witness tables, type information, format thunks, and hooks are
followed because their names appear.

Things to settle:

- `attach_debug_info` and `debug_subprogram` name functions by symbol; they
  must skip a dropped one.
- An object build's exports and a test build's test procedures are roots
  already, by linkage. Confirm with the `tests/pkg` and object-build cases.
- Tests that look for a function in the `.ll`, in
  [emit_llvm_test.odin](../src/emit_llvm_test.odin) and the corpus, may name
  one that is now dropped.
- `-check-layout` and `-emit-ll` should see the same module a build does.

Expected: `clang -c` at `-opt=none` falls 40–90% and objects shrink by half or
more. An optimizing build gains less, since LLVM already drops dead internal
functions early.

**Done** on 2026-11-20, as `prune_unreachable` in
[emit_llvm_prune.odin](../src/emit_llvm_prune.odin);
[LLVM and toolchain](compiler-architecture.md#llvm-and-toolchain) has the two
rules it relies on. Whole builds, before and after, in ms:

| Program | `-opt=none` | `-g` | `-opt=speed` |
| --- | ---: | ---: | ---: |
| `examples/lexer.loke` | 1176 / 710 | 1437 / 842 | 3320 / 3122 |
| `examples/corpus_runner.loke` | 1536 / 1037 | 1836 / 1222 | 4777 / 4246 |
| `bench/geometry.loke` | 1690 / 770 | 2140 / 942 | 2086 / 1706 |
| `bench/linalg.loke` | 1353 / 522 | 1728 / 648 | 1482 / 1154 |
| `bench/workspace` | 1166 / 330 | 1409 / 419 | 920 / 639 |

The front end's time is unchanged, and an executable built at `-opt=none` is
5–81% smaller. The records are `reachable-emission-before.json` and
`reachable-emission.json` under `bench/baselines`, whose `README.md` has the
conditions. How the open points settled:

- A dropped definition's debug markers are in its text and go with it, and the
  natvis rules name only the witness tables that are left.
- Exports, test procedures, and the hooks the runtime calls are roots by
  linkage; the object, package, and test corpora pass unchanged.
- Seven `tests/ll` cases looked for a procedure nothing called. Five now reach
  it from `main`. The other two expected a shape that only unrelated `core`
  code had supplied, `select i1` and a `core:fmt` witness table, and now name
  what their own program emits.
- `-check-layout` builds a module of its own and is unaffected; `-emit-ll`
  writes the module a build compiles.
- LLVM no longer verifies the lowering of unreached code, which every build
  used to do for every bundled procedure. [Step 4](#4-emit-on-demand) removes
  that lowering altogether, so the coverage has to come from tests that call
  what they test.

### 2. Spell union payload padding in words

In `union_storage_definition` ([emit_llvm_union.odin](../src/emit_llvm_union.odin))
and the union constants in [emit_llvm_const.odin](../src/emit_llvm_const.odin),
which read the same `Union_Members`.

- Spell payload padding as an array of the head's integer type when its size
  is a multiple of the head's, and as bytes otherwise.
- Omit the tail member when the struct's own alignment pads to the same size.
  The tag stays the last member, so its index does not move.

Things to settle:

- A first-class load or store no longer copies the tail bytes. Check that no
  equality, hash, or map thunk reads a union's tail or payload padding bytes
  ([emit_llvm_equality.odin](../src/emit_llvm_equality.odin)).
- `-check-layout` must still agree with LLVM for every union in the tests.
- Unions aligned to 4, 2, and 16 or more need the same treatment with their own
  head type; the experiment only covered 8.

Expected: with step 1, `clang -c` falls a further 50% at both `-opt=none` and
`-opt=speed` on programs that use `Result` and `Option` heavily, and little on
numeric code such as `bench/geometry.loke`.

### 3. Copy and zero aggregates with `memcpy` and `memset`

Where the emitter copies an aggregate from one place to another, or zeroes
one, emit `llvm.memcpy` or `llvm.memset` with the type's size instead of a
first-class `load` and `store`. Scalars and small vectors stay as they are.

Find the sites by the pattern in the emitted text rather than by guessing:
a `load` of an aggregate used once by a `store`, and `store … zeroinitializer`.
`emit_copied_expr` and the result-slot stores of `emit_return_values` are the
likely centres.

Expected: a further 10–25% of `clang -c` at `-opt=none`, about 40% at
`-opt=speed` after step 2, and smaller objects.

### 4. Emit on demand

Stop writing bodies that step 1 would drop. `symbol_name` in
[emit_llvm_names.odin](../src/emit_llvm_names.odin) is where a body asks for a
procedure's name: record the symbol there, and emit procedure bodies from a
worklist that starts at the entry point, exports, tests, and file-scope
initializers. Write the kept bodies in declaration order so the module does not
depend on worklist order. Step 1's pass stays, as the check that nothing
unreachable was written and for what the worklist does not govern.

Do this only after step 1 has landed and its roots are known to be right.

Expected: emission time falls with the share of unreachable code, 55–85% on
these programs, which is 15–25% of the front end.

### 5. Build each body's provenance input once

A spike first, then a decision. The three whole-program passes rebuild every
body's normalized input, and the
[phase rules](compiler-architecture.md#normalized-provenance-input) already
say operations hold no facts and replay reads current summaries. Keeping a
body's frozen input and operations between the passes would turn two of the
three builds into replays.

Things the spike must answer:

- How much memory the kept input costs. The largest body's build uses about
  1 MB of analysis arena, and the arena is reset after every body today.
- Whether what `collect_body_effects` and `summarize_body` read from the
  construction graph (`effect_writes`, `effect_calls`, `summary_callees`) can
  come from a replayed graph.
- Whether the six places that tell `.Prov_Summary` from `.Prov_Diagnose` act
  during the walk or during replay. One kept input serves both modes only if
  what they decide is not recorded in it.
- Whether construction diagnostics are still reported once.

Expected, if it works: about 20% of checking time. That is 2–4% of a build and
most of what the language server can gain, since it never runs clang.

## Considered and not planned

- **Aggregates passed and returned through memory.** `sret` results and
  pointer parameters for large aggregates would remove most remaining FastISel
  misses, but change the internal calling convention across the emitter.
  Measure the misses again after steps 1–3 before deciding.
- **Replacing `fmt` in the emitter.** 341 call sites. Step 4 removes most of
  the calls; a faster formatter for the few hot helpers (`emit_value`) can
  follow if emission still matters.
- **`-no-bounds-check` for the compiler.** 0–10% of the front end, and a
  compiler bug becomes memory corruption instead of a reported crash.
- **Not checking unused library bodies.** The largest front-end saving, but it
  would stop reporting errors in code the program does not call, which is a
  language decision ([open-questions.md](open-questions.md)), not an
  optimization.
- **One clang process per package, in parallel.** Needs the module split, with
  shared types and cross-module linkage. Steps 1–3 take more for less.
- **Caching toolchain discovery.** About 30 ms a build.
- **Writing bitcode instead of text.** A new backend output for a parse that is
  a small part of clang's time.

## Method

- **Whole builds:** each command run as a process from PowerShell and timed
  with `Stopwatch`; output written to a scratch directory.
- **clang alone:** the `.ll` from `-emit-ll`, compiled with the flags `lokec`
  passes (`-O0` or `-O2`, `-march=x86-64`, `-ffp-contract=off`,
  `-Wno-override-module`), linked against the matching set under
  `runtime/prebuilt`, with the toolset flags `lokec -print-toolchain` prints.
- **Reachability:** a script that reads `define` bodies and globals from the
  `.ll`, collects the `@name` tokens in each, and walks from the externally
  visible ones.
- **Rewrites:** scripts over the `.ll` text, as
  [Union payloads in words, and `memcpy`](#union-payloads-in-words-and-memcpy)
  describes. The `memcpy` size is the constant expression
  `ptrtoint (ptr getelementptr (%T, ptr null, i32 1) to i64)`.
- **Front-end phases and profile:** an Odin program importing `src` as a
  package, as `bench/provenance_profile` does, timing the three session calls;
  with `-define:PROF=true`, instrumentation hooks that keep a frame stack and,
  per procedure, calls, self cycles, and inclusive cycles.
