# Changelog

User-visible changes to the language, the compiler, and the standard library.
Each release's section is its GitHub release notes. A change lands under
**Unreleased**, and a break also gets an upgrade note under **Breaking
changes**. [releasing.md](releasing.md) has the version policy and the release
checklist.

## [Unreleased]

### Breaking changes

- Comments inside generic parameter types no longer introduce fictitious `$`
  bindings or hide real ones. Invalid independent defaults that were accepted
  because of comment text are now diagnosed at the declaration. Define the
  referenced name in the declaration's scope or correct the default; a `$name`
  written only in a comment does not declare a parameter.
- Two generic `impl` blocks that both give one instance a member of the same
  name, where neither block is more specialized, make a call of that member
  ambiguous (`L0391`); the first block's member used to win silently. Blocks
  with equal patterns declaring one name twice are an error (`L0409`). Remove
  one member, or make one block strictly more specialized, as
  `impl Pair(int, int)` is than both `impl Pair($A, int)` and
  `impl Pair(int, $B)`.
- A constant or file-scope initializer that builds an array or struct of more
  constant elements than the compile-time evaluator's 64 MB scratch budget
  holds, such as `Table :: [2000000]u8{1};`, is an error (`L0342`); the
  compiler used to fold it one element at a time, taking seconds or running out
  of memory. Leave a zero-initialized global without an initializer
  (`buffer: [2000000]u8;`), or fill a large table at run time.

### Changed

- Assigning or binding a place whose copy allocates, such as a `[dynamic]T` or
  `map[K]V`, copies it again, from the destination's `via` or the default
  allocator; 0.7.1 rejected it (`L0504`). A copy at a local's last use is a
  move instead, so `b := a` costs nothing when `a` is not used afterwards
  (design.md "Last-use transfer"). Every program 0.7.1 accepted means the same.

### Added

- `lokec -g` emits debug information at any `-opt` level: each procedure, its
  parameters and locals with their types, and the line of each statement, so a
  debugger can set a source breakpoint, show a Loke call stack, and inspect
  locals. An executable gets a `.pdb` beside it, and a panic in it prints each
  Loke frame, newest first, with its procedure, file, and line.
- `lokec -fmt` rewrites a file, or a directory's `.loke` files, in one layout:
  tabs by nesting, the author's line breaks, and one space where the rules put
  one (comments.md "Formatting"). It changes whitespace only and refuses a file
  that does not parse. `-fmt-check` lists the files it would change and exits 1,
  for CI.
- `lokec -doc` prints a package's public API as Markdown: each public
  declaration's signature, without procedure bodies or private struct fields,
  and the comments directly above it. It needs no `main`, and documents a
  standard-library directory such as `core\strings` as the package importers see.
- A `loke.project` file at or above the input lists `require <name> <path>`
  lines, and each name becomes a collection, so `import "shapes:area";` builds
  without `-collection` flags. Dependencies' own `loke.project` files are read
  too; one name naming two directories is an error, and `-collection` overrides
  a name (readme.md "Projects").
- `lokec -debug` sets `LOKE_DEBUG` to `true`; it used to be `false` always.
- A fixed array `[N]T` converts implicitly to a read-only `[]T` of its
  elements, as a `[dynamic]T` already did, so `total(primes)` needs no
  `primes[:]` (design.md "Fixed arrays").
- `Option.ok_or(error)` turns an absent value into a `Result` failure, so
  `settings.lookup_value("port").ok_or(Config_Error.Missing_Port) or_return`
  replaces a `switch` (design.md "Changing error domains").
- `fmt.concat_to(w, ...)` writes its arguments with nothing between them, for a
  `format` method that prints `(3, 4)`.

### Fixed

- A variable or composite literal whose type's layout is past the maximum
  size, such as `c: [9223372036854775807]int;`, is an error (`L0364`) where it
  is written; it was accepted, or with `= {}` never finished compiling.
- A zero value of a large array is written whole: a global
  `buffer: [16777216]u8;` compiles in a fraction of a second instead of 44, and
  a local `a := [1000000000]int{1};` compiles instead of crashing the compiler.
  A literal too large to fold is built at run time.
- An instance that two crossed generic `impl` blocks both apply to is valid
  while their shared member is not called; it used to be rejected as soon as
  the instance existed.
- A more specialized generic `impl` block supplies its member even when it is
  registered after the instance exists, as a `when` block can be; the
  general block's member is dropped from that instance, body unchecked.
- `lokec` no longer keeps a CPU core busy while it waits for clang, so several
  builds run side by side finish sooner instead of starving each other.
- A diagnostic whose span runs past its first line, such as a `switch` missing
  a case, no longer underlines a trailing `//` comment on that line.
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

- A diagnostic names a file relative to the working directory, with `/`, when
  the program is a directory or a note points into `base:` or `core:`; it used
  to print the whole path, mixing `/` and `\`.
- Inserting a `string_view` key into a `map[string]V` says that an inserted
  key must be an owned `string`, and suggests `.copy()`; it used to report a
  failed lookup.
- A case label that fails to parse, such as `case ..< 0:`, is one diagnostic;
  it used to be six, including a missing `return` for the enclosing procedure.

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
