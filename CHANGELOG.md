# Changelog

User-visible changes to the language, the compiler, and the standard library.
Each release's section is its GitHub release notes. A change lands under
**Unreleased**, and a break also gets an upgrade note under **Breaking
changes**. [releasing.md](releasing.md) has the version policy and the release
checklist.

## [Unreleased]

### Breaking changes

- An unfixed float no longer converts implicitly to an integer even when it is
  integral, as in `value: int = 1.0` (`L0353`). Write `int(1.0)`, or the
  integer literal `1`.
- `main` with an `inout` result or a foreign calling convention, as in
  `main :: proc "c" ()`, is an error (`L0303`). An `inout i32` result exited
  with an address-derived status; return the status by value from a `loke`
  `main`.
- A parameter other than `self` with no type and no default, as in
  `read :: proc(other) -> int` inside an `impl`, is an error (`L0408`). It
  took the `impl` type; write it, as in `other: Counter`.
- `nil` is not a union value (`L0310`, or `L0373` for `U(nil)`), even for a
  union with `@(zero=name)`. `result == nil` used to compare with the all-zero
  first variant. Name the variant instead: `result == .ok` for a
  `Result(Unit, E)`, `option == .none` for an `Option`.
- A constant zero integer divisor is an error (`L0319`) even when the dividend
  is not constant, as in `value / 0`, `value % 0`, and `value /= 0`. These
  compiled to a run-time panic; remove the division, or divide by a variable.
- An `inout` marker on an argument to a variadic parameter, as in
  `fmt.println("a", inout n)`, is an error (`L0370`). It was accepted and
  ignored; delete the marker, since a variadic pack receives a copy.
- Standard output and standard error are binary on Windows: `fmt.println` and
  panic reports end lines with `\n`, as `term.stdout()` already did, instead of
  `\r\n`. A program whose output must end lines with `\r\n` writes them.
- Allocator lifetime checks reject handles used after their provider ends,
  including handles derived from temporary providers. Bind the provider to a
  local that outlives its handles, allocations, and child providers. `new_clone`
  also rejects escaped or stale borrows hidden in its allocation; keep the
  borrowed source alive or clone an owning value instead.
- Foreign boundaries reject enums without a written backing type, enums backed
  by `i128` or `u128`, and zero-sized records, including nested fields (`L0619`).
  These could use incompatible C layouts or calling conventions. Write the
  backing type matching the foreign declaration, such as `enum i32`; pass
  unsupported types through pointers or an explicit compatible representation.
- Unmatched UTF-16 surrogates in `Raw_Mode.read_key` now return `Invalid_Data`
  for `Read_Key` instead of dropping a high half or producing a non-scalar
  character. Handle this error when processing injected console input. A valid
  following key, its modifiers, and all repeats remain available.
- Generic argument matching now follows cache identity: the converted argument
  type and value. Floating arguments use their exact IEEE-754 encoding,
  including inside aggregates and `dyn` applications. A repeated name requires
  the same converted type and no longer matches `0.0` with `-0.0`; use distinct
  names and a numeric `where` comparison when that equality is intended. NaNs
  with identical encodings now match, and different payloads or signalling bits
  retain distinct instances.
- Colon annotations on inferred generic bindings, such as `x: $T: []int`, are
  rejected (`L0258`); their constraints were silently ignored. Write `x: []int`
  for a fixed element type, `x: []$E` to infer the element, or `x: $T` with a
  `where` bound. Explicit parameters such as `$T: type` are unchanged.
- `get_environment`, `set_environment`, and `unset_environment` reject empty
  names or names containing `=` as `Invalid_Data` before calling the platform.
  An invalid-name lookup previously looked like a missing variable, while
  setters reported `Other`. Validate input names and handle `Invalid_Data`.
- A union's `impl` or `extend` block can no longer declare a member named `as`,
  which is now the compiler-defined `value.as(.name)`. Rename the member.
- An inherent `format` must match `fmt.Formattable`'s concrete slot. Generic
  format methods and methods borrowing or mutating the writer/options arguments
  are now diagnosed. Use `proc(self: ^, writer: fmt.Writer, options: fmt.Options)`;
  plain `self` remains accepted. Previously these could silently use default
  formatting or emit an invalid call.
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

- Debug builds preserve outputs ending in `.ll` or `.natvis`, including case
  variants. Deferred locals remain visible at every emitted exit, exported
  names stay literal, and `else if` conditions have their own source locations.
  Debuggers show 128-bit integers and enums as exact `low` and `high` words
  rather than saturating wide enum constants.
- Open questions and unresolved findings now live in
  [open-questions.md](open-questions.md); [comments.md](comments.md) keeps design
  rationale and differences from Odin.
- `Enum.from_int` accepts an argument of any integer type, including a
  `distinct` integer, so `Suit.from_int(code)` works with a `code: int` and a
  `Suit :: enum u8`. A value the backing type can't hold gives `.none`, as any
  other undeclared value does.
- Tutorials assume prior programming experience and focus on Loke's syntax,
  borrowing, and mutation rules. They distinguish runes from displayed
  characters and clarify panic cleanup and generic type inference.
- Assigning or binding a place whose copy allocates, such as a `[dynamic]T` or
  `map[K]V`, copies it again, from the destination's `via` or the default
  allocator; 0.7.1 rejected it (`L0504`). A copy at a local's last use is a
  move instead, so `b := a` costs nothing when `a` is not used afterwards
  (design.md "Last-use transfer"). Every program 0.7.1 accepted means the same.
- Under `-g`, a debugger shows each local only inside the block that declares
  it, so two loops that each declare `i` no longer show two `i`s at once.
- Under `-g`, the PDB carries natvis rules, so Visual Studio and WinDbg show a
  string's text, a map's entries, and an `any_view`'s value. A map's debug type
  is named `map$<n>` so the rules can match it, `string`'s is `string$` because
  WinDbg ignores natvis for a type named `string`, and `-keep-temps` keeps the
  `.natvis` file.
- Under `-g`, a debugger shows the value a `dyn` view points at. Each witness
  table is a `witness$<n>` global in the PDB, and a `dyn` type is named
  `dyn$<n>` so the natvis rules can match it.
- Under `-g`, the cleanup a block runs on exit has the line of its closing
  `}`, and a `for` loop's condition and update, and a `foreach` loop's step,
  have the loop header's line, rather than the last statement's.
- Under `-g`, a deferred statement has its own line when the scope exit runs
  it, rather than the exit's.
- `-doc` opens a package's page with the comments above its `package` clauses,
  shows a public struct field's comments, and adds a page for each package of
  the project the root imports. A declaration or package clause with
  attributes now gets the comment above them; it used to get none.

### Added

- `lokec <file> -dump-tokens` prints the file's tokens, one `lo hi Kind` line
  each with the byte span, and stops after lexing.
- `examples/lexer.loke` is the compiler's lexer written in Loke. It prints a
  file's tokens as `-dump-tokens` does, and agrees with it token for token, or
  lexes every `.loke` file beneath a directory and prints the totals.
- `core:process` starts child processes: `spawn` takes a `Command` naming the
  program, its arguments, an inherited or replaced environment, a working
  directory, and whether each standard handle is inherited, the null device,
  or a pipe; `Child` has `wait`, `kill`, `id`, and the pipes, and `run` spawns
  and waits. A name is found on `PATH` only, each argument reaches the child as
  given, and the child inherits its three standard handles and nothing else.
  `io.Operation` gains `Spawn`, `Wait`, and `Kill`. `output` runs a command
  and collects its status, stdout, and stderr, reading both pipes at once; it
  closes a piped stdin, and a failed read ends the child and returns the error.
- `examples/corpus_runner.loke` is the compiler's corpus harness written in
  Loke: it compiles each case, a file or a package directory, runs it, and
  compares its output, or under `-diagnostics` and `-syntax` checks what its
  errors say, or under `-ir` checks the shapes its LLVM IR holds and, when
  `lokec -print-toolchain` finds clang, that LLVM assembles it, running a case
  per processor at once.
- `thread.processor_count` answers how many threads can run at once.
- `value.as(.name)` reads one union variant without a `switch`: it yields
  `Option(P)` holding a copy of the payload when `name` is active, and `.none`
  otherwise, so `shape.as(.circle) or_else 0` works.
- `fmt.Formattable` is the structural interface used by printing. Custom and
  compiler-generated `format` methods support generic constraints and borrowed
  `dyn fmt.Formattable` views; mixed variadic arguments keep their existing API.
- Six tutorial lessons cover borrowing and lifetimes, compile-time evaluation,
  allocator use, resource ownership, default allocator providers, and reflection
  with custom formatting. The core route reaches a command-line tool before
  generics; examples remain executable tests, without learning exercises.
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

- A cycle through a qualified associated constant, as in
  `impl Item { Count :: Item.Count; }`, reports `L0324`. It was accepted, and
  using the constant failed in the backend with `L0405`.
- A constant array, struct, or union converts to its own type and between a
  distinct type and its underlying one, as in `Wrapped(BASE)` and
  `Choice(CHOSEN)`. They reported `L0373`.
- An explicit conversion of a typed integer constant keeps its low bits, as at
  run time: `u8(i32(300))` is 44. It reported `L0373`. An unfixed constant
  such as `u8(300)` must still fit.
- `a == b` with `a: ^mut T` and `b: ^T`, and `a if flag else b`, weaken the
  mutable pointer to `^T` (design.md "Comparison operators"). They reported
  `L0354`.
- A user `operator([:])` gives its endpoints their expected type, so
  `box[.Start:.End]` resolves the implicit selectors. It reported `L0385`.
- A built-in index may be a rune, as in `xs[index]` for `index: rune`
  (design.md "Fixed arrays"). It reported `L0362`.
- A field, an index, or a built-in method applied to a parenthesized
  `or_return`, as in `(items() or_return).len()`, reads the payload. It used to
  emit a nil check on the carrier itself, and LLVM rejected the IR.
- `nil` passed where a generic parameter must infer its type, as in `f(nil)`
  for `f :: proc(x: $T)`, says `nil` has no type to infer it from, instead of
  "`$T` is not bound here" in an instance named `f(<invalid>)`.
- A file-scope `when` condition that names a type only through an anonymous
  record's field, as in `size_of((a: Later))`, waits for the branch declaring
  it instead of reporting the name unknown.
- A diagnostic on a line that is not valid UTF-8 shows each run of bad bytes as
  U+FFFD instead of echoing them, so diagnostics are always UTF-8 text.
- A temporary made in an operand that may not run (the right of `&&` or `||`,
  a conditional expression's arm, an `or_else` fallback) is dropped only when
  it was made. `count == 5 && name() == "x"` released a `string` that was never
  written when `count` was not 5, and crashed.
- A program can import both `core:fs` and `core:thread`: the two declared
  `CloseHandle` with different types, which failed with `L0600`.

- Provider lifetime checks follow nested and recursive record/container types
  without dropping dependencies beyond eight levels. Handles remain usable
  after moving a provider or resetting it with `free_all`.
- Allocations preserve the borrows stored in their pointees, including through
  helper procedures and `try_new_clone`, while retaining field precision and
  the allocation-base provenance needed by checked `free`.
- Foreign ABI checks reuse completed type checks within a traversal, avoiding
  exponential work on shared record types while preserving cycle handling and
  deferred signatures.
- Fixed arrays with copy hooks generate linear-size failure cleanup instead of
  quadratic cleanup, avoiding compiler stalls on large arrays.
- Invalid index conversions stop before bounds checking, avoiding cascading
  diagnostics. Generic field errors include every instantiation's context,
  repeated causes print once, value arguments use readable spellings, and long
  instantiation names are abbreviated.
- The terminal contract now specifies control-character values for Ctrl+letter
  keys, with regressions for Ctrl+C, Ctrl+I, and Ctrl+M.
- `path.volume` includes the server and share in extended UNC roots, so
  `base` and `directory` stop at the share and `fs.create_directories` begins
  below it. Extended paths remain unchanged by `clean`.
- Windows path errors 161 and 267 now normalize to `Invalid_Path` consistently
  in process and filesystem operations, retaining their native error numbers.
- A bare payload variant passed to a call that is itself being called, as in
  `pick(.io)(3)`, is rejected (`L0425`) as it is anywhere else; it compiled to
  a wrong value.
- A plain value read out of a container backed by a local arena, such as
  `return ys[0];` for a `[dynamic]int`, can be returned directly; it was
  rejected (`L0592`) as if it were backed by the arena, while the same value
  bound to a local first was accepted.
- The runtime objects `lokec` caches beside itself are rebuilt when the C
  build that made them changes, such as a new `LOKE_CLANG`, a reinstalled
  clang, or different MSVC or Windows SDK headers; they used to be reused
  whenever they were newer than the runtime sources.
- Several builds running at once after the runtime changed no longer fail at
  the link with `could not open .../runtime/prebuilt/.../alloc.o`: each
  runtime build keeps its own cached set, which is never replaced while
  another build may read it. The old `runtime/prebuilt/<mode>` directories are
  no longer used and can be deleted.
- A deferred `drop(arena)` or `free_all(arena.allocator())` is checked at each
  exit with the owners live at that exit. An owner of the region still live at
  one exit was missed when another exit, such as an early `return` after
  `drop(xs)`, had it dead; the reset is now reported (`L0537`).
- A procedure whose allocator-region facts take many passes to settle, such as
  a loop assigning a long chain of allocator handles in reverse order, keeps
  one analysis graph in memory instead of one per pass: a 128-handle chain
  used 100 MB of scratch and now uses under 1 MB.
- Tutorial examples reject negative time components and report overflowing
  expense totals as input errors. The command-line tutorial accepts long
  category names without panicking; its output now uses one space between
  names and amounts. Checked examples cover these cases and integer limits.
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

- [design.md](design.md) qualifies ownership and last-use transfer summaries,
  groups argument modes under parameter semantics, and makes copy-cost warnings
  explicitly optional. It distinguishes parameter storage from carried borrows
  and procedure-type effects from inferred global writes.
- [comments.md](comments.md) separates current rationale from design history and
  compiler notes, explains borrow-checking terms, and corrects stale pointer,
  map, and `Option` descriptions. Callable proposals are in
  [open-questions.md](open-questions.md#callable-records-procedures-and-closures).
- Stale open questions are removed or corrected against the current compiler
  and tutorials. The completed compiler audit is recorded in
  [comments.md](comments.md#compiler-architecture-audit-2026-09-28), with its
  regression citations updated.
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
