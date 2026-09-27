# Changelog

User-visible changes to the language, the compiler, and the standard library.
Each release's section is its GitHub release notes. A change lands under
**Unreleased**, and a break also gets an upgrade note under **Breaking
changes**. [releasing.md](releasing.md) has the version policy and the release
checklist.

## [Unreleased]

### Breaking changes

- Two generic `impl` blocks that both give one instance a member of the same
  name, where neither block is more specialized, are an error (`L0409`); the
  first block's member used to win silently. Remove one member, or make one
  block strictly more specialized, as `impl Pair(int, int)` is than both
  `impl Pair($A, int)` and `impl Pair(int, $B)`.

### Fixed

- A generic record instance first reached by a hypothetical check, such as an
  overload member whose signature names it, keeps its field errors: a later use
  reports them, instead of the compiler crashing or failing internally.
- A generic `impl` subject with a nested pattern, as in `impl Box([]$E)` or
  `impl Box(Box($E))`, applies to the instances it matches; it applied to none.
  A name bound twice, as in `impl Pair($T, $T)`, needs both arguments equal.
- A method whose receiver shares a parameter group with a generic parameter,
  as in `proc(self, value: $U)` or `proc(self, values: ..$U)`, is callable; the
  receiver used to be matched against `$U`.

- A local read in the declaration that introduces it, as in `x := x + 1;`, is
  an error (`L0500`) instead of reaching the backend as an internal failure.
- A compile-time call of a procedure whose body has errors reports that the
  body has errors (`L0344`) instead of an internal failure. This includes a
  `where` or interface predicate, which no longer runs such a body even when the
  errors are in a branch it would not take.
- A constant whose initializer reported an error, such as a literal naming a
  field the record lacks, is not evaluated, instead of failing internally.

### Documentation

- [tutorials/](tutorials/README.md): nine pages that teach Loke from installing
  it to a program in several packages and a call into C. The test suite builds
  and runs every program on them and checks what the page says it prints.
- A release attaches `perf.json`: compile time, compiler memory, and executable
  size for every example, and the run time of the programs in `bench/`.
  `perf.ps1` produces it and compares it with an earlier one.
- [releasing.md](releasing.md) states what a version promises before and
  after 1.0, where upgrade notes go, and the release checklist.

## [0.7.1] - 2026-09-27

The first published release: the v1 language specified by
[design.md](design.md) and [grammar.md](grammar.md), implemented by `lokec` with
no open entries in [known-gaps.md](known-gaps.md).

### Language

- Value semantics with visible ownership: strings, dynamic arrays, and maps are
  managed values with language-defined copy, move, and cleanup, and a copy that
  may allocate is written, never implied.
- Borrows, lifetimes, and places checked by the compiler, without Rust-style
  complete memory safety; explicit `unsafe` marks the trust boundary.
- Records, enums, unions, and methods; operators and indexing defined by
  records; interfaces used both as generic bounds and as erased `dyn` views.
- Monomorphized generics with `where` bounds, compile-time execution, and
  conditional compilation, in place of a preprocessor or macro system.
- Errors as values with `or_return`, `or_else`, and optional-ok, plus panics
  with unwinding.
- Allocators and regions, threads and atomics with a defined memory model, SIMD
  vectors, and C interoperability through the C ABI and C-compatible types.

### Compiler

- `lokec` checks a program or a package directory and builds an executable or
  object through LLVM IR and Clang, at five optimization levels (`-opt=none` to
  `-opt=aggressive`).
- Package imports, `-collection name=path` roots, foreign imports including
  NASM `.asm` sources, `-emit-ll`, `-check-layout`, and `-print-toolchain`.
- Diagnostics with stable codes (`L0001` onwards) and source spans.

### Standard library

- `base:` `runtime`, `meta`, and `interfaces`.
- `core:` `mem`, `unsafe`, `sync`, `simd`, `thread`, `fmt`, `strconv`,
  `strings`, `cstrings`, `encoding/utf16`, `endian`, `math`, `slice`,
  `container`, `log`, `io`, `path`, `fs`, `term`, and `os`, specified in
  [standard-library.md](standard-library.md).

### Platform and limits

- Windows x64 only. Building programs needs LLVM/Clang and the MSVC build tools
  with the Windows SDK; building `lokec` itself needs Odin `dev-2025-09`.
- The release is a zip of `lokec.exe` with the `base/`, `core/`, `runtime/`,
  and `examples/` trees it finds beside itself; unzip it anywhere.
- Not yet available: a package manager, a language server, debug information,
  and Linux or macOS targets ([future-plans.md](future-plans.md)).
