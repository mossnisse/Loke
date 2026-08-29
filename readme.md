Loke is a private project to make a new programming language building on Odin.

It aims to add more high level language functionality and more possibilities for abstractions with good ergonomics and still have the possibilities to have low level access and control of the binary output similar to Odin and C.

It aims at making it easier to handle memory allocations and complex datatypes as strings and dynamic arrays, not making the language 100% memory safe as Rust.

Loke should be able to use compiled C libraries (C ABI) and have some compatibility C datatypes to make that work.

Procedures and that are called and packages that are improted should not change how the code works for the caller or importer in any unexpected ways. The opposite may be true. Having an parameter with an pointer to data that is manipulated is an nessary evil and is allowed.

Stuff like hidden allocations are allowed but procedures returning values that has to be manually hanndled should be clearly vissible that it is needed.

The normative language specification is in [design.md](design.md), and its grammar in [grammar.md](grammar.md). Open questions, differences from Odin, and non-normative design motivations are collected in [comments.md](comments.md).

## The compiler

`lokec` is written in Odin and lives in [src/](src). The build is decomposed in
[compiler-plan.md](compiler-plan.md), which records what each milestone M0–M6b
delivered; the current milestone is M7, planned in [m7-plan.md](m7-plan.md).

The current phase contracts, allocation ownership, and backend component map are
described in [compiler-architecture.md](compiler-architecture.md).

The **standard library** (`standard-library-plan.md`) is the first release of
ordinary Loke code over that foundation. `base:` stays reserved for declarations
that participate in the language or its runtime ABI; general-purpose code lives
in `core:`, in small packages a program imports by name, with no prelude:

```text
core:strings          UTF-8 algorithms and String_Builder
core:cstrings         owned zero-terminated buffers for foreign APIs
core:strconv          scalar parsing
core:fmt              value formatting and process diagnostics    (grown)
core:io               byte stream protocols and buffered helpers
core:encoding/utf16   UTF-8 to UTF-16 and back
core:path             lexical path operations
core:fs               files, directories, and file metadata
core:term             standard streams and terminal key input
core:os               arguments, exit, environment, process state (grown)
```

- **text.** `core:strings` adds search, trimming, splitting, joining and
  `String_Builder` to what the built-in `string` already owns. Its zero value is
  a usable, allocator-unbound builder; `finish` is one copy into string storage
  and keeps the buffer for reuse. Searching compares bytes, never subranges,
  because a view sliced through a code point is a runtime failure and a candidate
  offset is not known to be a boundary until it matches;
- **errors are values.** `core:io` owns one `Error` for `io`, `fs`, `term` and
  fallible process I/O: a normalized `Code`, a closed `Operation`, and the native
  number, all owned scalars, so an error never borrows a caller's path and never
  allocates to report a failure. It is nil on success, composes with `or_return`,
  and formats through its own package's `format`;
- **streams.** `io.Reader` and `io.Writer` are `slot` interfaces, so a concrete
  implementation is specialized and `dyn io.Writer` also exists — which is what
  lets `io.write_formatted` present a `fmt.Writer` that latches the first real
  write error instead of pretending a fallible file is an infallible sink;
- **ownership is visible.** `fs.File`, `fs.Directory_Reader` and `term.Raw_Mode`
  are move-only, have inert zero values, release themselves with `drop`, and
  offer an idempotent `close` a caller can use to observe a failure. Because a
  wedged terminal outlives the process that wedged it, `term.begin_raw` also
  registers a console control handler — the one place the library pays for a
  guarantee the language does not make, and nothing is registered until a caller
  asks for raw mode;
- **portable contract, platform implementation.** Windows x64 is the first
  target. Every platform call sits behind `when (LOKE_OS == .Windows)` inside the
  package that needs it, over `kernel32` foreign blocks; paths and environment
  strings cross UTF-8 to UTF-16 in exactly one place, and a native name that is
  not valid Unicode is reported as invalid data rather than silently changed.

`examples/greeting.loke` is the release's acceptance program: it prompts, reads
and writes a text file, and reports a failure, with no compiler-specific I/O
built-in anywhere in it. `examples/streaming.loke` shows a bounded read, a
fixed-buffer stream and an observed `close`; `examples/keys.loke` shows raw key
input with terminal restoration.

Requires Odin and LLVM (`winget install LLVM.LLVM`); `clang` is found through
`LOKE_CLANG`, the standard Windows LLVM installation, or `PATH`.

```
odin build src -out:lokec.exe
lokec.exe examples/hello.loke -o hello.exe && hello.exe
lokec.exe examples/greeting.loke -o greeting.exe && greeting.exe   # the library
lokec.exe examples/keys.loke -o keys.exe && keys.exe               # needs a console
lokec.exe tests/pkg/diamond -o diamond.exe          # a directory is one package
lokec.exe app -collection core=vendor/core -define:DEBUG=true
lokec.exe app -opt=speed -o app.exe                 # -O2 on the one clang call
lokec.exe tests/obj/lib.loke -build-mode=obj        # one object for a C host
lokec.exe tests/pkg/catalogue -collection base=base       # the interface catalogue
lokec.exe examples/hello.loke -parse-only
lokec.exe examples/hello.loke -dump-ast
lokec.exe tests/layout/types.loke -check-layout
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
./test-all.ps1                         # unit/integration + all five opt modes
```
