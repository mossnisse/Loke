# M6b implementation plan — managed containers and allocator regions

## Context

[M6a](m6a-plan.md) fixes the versioned C runtime, allocator handle, failure and
panic strategies, standard package roots, text/runtime metadata, formatting,
variadic ABI, and M5b registration hooks. **M6b** is the managed-container half:
dynamic arrays and maps, allocator binding with `via`, iteration and
invalidation, real local arena/scratch regions, and the remaining conversion and
compile-time-evaluation debts that require those types.

This document intentionally fixes the boundary and step order now. Its detailed
operation-by-operation decisions are written just in time when M6b starts,
using the implemented M6a ABI rather than guessing around it.

## Scope

### In M6b

| Area | Contents |
|---|---|
| Dynamic arrays | `[dynamic]T` representation, literals and zero value, length/capacity, all mutating/fallible operations, lifecycle, `make`, slicing, and formatting |
| Maps | `map[K]V` representation and coherence, lookup/comma-ok/`in`, insertion places, `find`, operations, lifecycle, `make`, and formatting |
| Allocator policy | Eager `via`, lazy default binding, copy/move/clone destination rules, failure policy, compile-time-constant zero values, and stored provider handles |
| Iteration and borrows | Value/by-reference dynamic-array iteration, key/value and by-reference map iteration, opaque iterators, and invalidation registration for every reallocating or slot-invalidating operation |
| Regions | `mem.Arena` and `mem.Scratch`, local region roots, successful reset, exact M5b owner/borrow escape fixtures, and removal of M5b’s conservative flow-insensitive narrowing |
| Remaining handoffs | `string.to_runes`, `unsafe.raw_data([dynamic]E)`, dynamic/map formatting, and compile-time temporary managed owners |

### Deferred after M6

MIR/no-LLVM code generation; `String_Builder`, `C_String`, `Small_Array`,
`shared(T)`/`weak(T)`, sorting; foreign ABI completion; and the standing v1
trust boundaries.

## Decisions

The full decision table is written when M6b starts. It must preserve these fixed
inputs from M6a:

- `Allocator` remains the pointer-sized `loke_rt_allocator_v1` handle. An arena
  embeds one record with its own state and canonical region identity; containers
  store that handle without copying the arena owner.
- A zero dynamic array or map is all-zero, allocator-unbound, compile-time
  constant, and immediately usable. Explicit `via` evaluates and binds at the
  declaration; otherwise the first allocation loads `mem.default_allocator()`.
- Mutating operations publish no partial state. Ordinary forms apply the
  allocator policy; `try_` forms return `Allocator_Error` and leave the original
  value unchanged.
- Map hashing/equality retains the inherent-only `Hashable` coherence rule.
  Formatting uses M6a’s owning-package coherence and formatter table.
- Every operation that can relocate storage or invalidate a slot is registered
  through M5b’s existing root-invalidation hook; allocator dependence uses the
  existing region hook.
- Compile-time map iteration remains rejected because its order is
  nondeterministic.

Diagnostics reserve L0576–L0600.

## Steps

### 1. Dynamic arrays

Implement representation, zero/literal construction, `append`, `insert`,
`pop`, `remove`, `remove_unordered`, `clear`, `resize`, `reserve`, `shrink`,
`len`, `cap`, indexing and indexed-assignment panic, all applicable `try_`
forms, `make`, `manual`, lifecycle, slices, and formatting. Fix and test the
growth policy in the detailed plan; it remains an implementation choice rather
than a language guarantee.

### 2. Maps

Implement representation, coherent hash/equality selection, literals,
`m[k]` single/comma-ok lookup, `in`, inserting assignment places including
field/index chains and `inout`, `find`, `remove`, `clear`, `reserve`, `shrink`,
`len`, `cap`, fallible forms, `make`, lifecycle, and formatting. Preserve
missing-key zero behavior and do not make iteration order reproducible.

### 3. Allocator binding and owner semantics

Implement eager `via`, lazy default binding, destination-policy copy and clone,
assignment preserving an already-bound destination allocator, move transferring
the source allocator, revival after drop/move, allocator-selected failure, and
constant zero initialization for file-scope, static, and thread-local owners.

### 4. Iteration and invalidation

Add compiler-contributed iterable/sequence members and opaque iterators for
dynamic arrays and maps, including the two-name map exception and permitted
by-reference forms. Register every reallocating, removing, clearing, shrinking,
dropping, moving, and slot-inserting operation with M5b and test last-use
acceptance plus live-view/iterator rejection.

### 5. Arena and scratch regions

Implement move-only `mem.Arena` and `mem.Scratch` owners over the M6a allocator
record, including fixed-buffer and provider-backed construction, reset, drop,
and `allocator()`. Register their local region roots, enable successful
`free_all`, retire the flow-insensitive region-identity and in-scope-owner
narrowings, and activate the parked `bad_view`/`bad_owner` examples plus the
explicitly-dropped-manual-owner success case.

### 6. Remaining gates, evaluator, and documentation

Enable `string.to_runes`, `unsafe.raw_data([dynamic]E)`, and managed temporary
owners on executed compile-time paths with deterministic allocator/sandbox
accounting. Retire M6b gates, audit all container operations against lifecycle,
panic, formatter, root, and region hooks, and update design/readme/compiler-plan
only when implementation lands.

## Verification

The detailed plan must retain the full M6a suite and add:

- operation/state-machine tests for both containers, including allocation
  failure leaving the original value unchanged;
- copy/move/drop tests proving allocator selection and exactly-once element
  lifecycle;
- view, iterator, `find`, insertion-place, and reallocation invalidation tests;
- map coherence tests across packages and nondeterministic compile-time
  iteration rejection;
- arena/scratch owner and borrow escape diagnostics, successful local reset,
  copied allocator identity, nested regions, and explicitly dropped manual
  owners;
- constant zero values at file, static, and TLS duration;
- `to_runes`, dynamic unsafe access, and formatting of nested containers;
- evaluator memory-limit diagnostics for managed compile-time temporaries.

## Deliberate shortcuts

### Earlier shortcuts M6b repays

| Earlier shortcut | M6b replacement |
|---|---|
| Dynamic arrays/maps and their invalidations are gated | Complete managed containers wired into M5b |
| Default allocator is the only successful provider | Arena and scratch records with distinct local regions |
| M5b region identity is flow-insensitive and over-blocks dropped manual owners | Flow-sensitive local-provider identities and lifecycle-aware reset proof |
| One string/unsafe conversion row waits for dynamic arrays | `to_runes` and dynamic `raw_data` |
| Evaluator rejects temporary managed owners | Bounded compiler-owned managed temporaries |

### Shortcuts retained after M6b

The post-M6 and v1 trust-boundary list in [m6a-plan.md](m6a-plan.md) remains in
force. In particular, the annotated typed AST still lowers directly to textual
LLVM; MIR waits for a second consumer.

## Assumptions

- M6a’s runtime C ABI and public Loke layouts are frozen inputs. M6b may add
  callbacks or metadata only through versioned extension, not by reinterpreting
  existing records.
- M5b’s hooks accept local region roots and container invalidations without a
  new provenance analysis.
- The detailed M6b plan is written from the implemented M6a tree immediately
  before M6b code begins.
