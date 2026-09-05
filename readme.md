Loke is a project to make a new programming language building on Odin.

It aims to add more high level language functionality and more possibilities for abstractions with good ergonomics and still have the possibilities to have low level access and control of the binary output similar to Odin and C.

It aims at making it easier to handle memory allocations and complex datatypes as strings and dynamic arrays, not making the language 100% memory safe as Rust.

Loke should be able to use compiled C libraries (C ABI) and have some compatibility C datatypes to make that work.

The language should be expressive enough making precompilers/macros and building scripts unecessary.

Procedures and that are called and packages that are imported should not change how the code works for the caller or importer in any unexpected ways. The opposite may be true. Having an parameter with an pointer to data that is manipulated is an nessary evil and is allowed.

Stuff like hidden allocations are allowed but procedures returning values that has to be manually hanndled should be clearly vissible that it is needed.

The normative language specification is in [design.md](design.md), and its grammar in [grammar.md](grammar.md). Open questions, differences from Odin, and non-normative design motivations are collected in [comments.md](comments.md).

## The compiler

`lokec` is written in Odin and lives in [src/](src). The v1 compiler implements
the language described by `design.md`. Its pipeline, phase contracts, allocation
ownership, and source-code map are documented in
[compiler-architecture.md](compiler-architecture.md). Longer-term work is
summarized in [future-plans.md](future-plans.md).

### Build and run

The current compiler targets **Windows x64**. You need:

- **Odin**, on `PATH`, to build `lokec` from source.
- **LLVM/Clang**, to compile the generated LLVM IR and link executables. On Windows, LLVM can be installed with `winget install LLVM.LLVM`.
- **MSVC C++ build tools and the Windows SDK**, including the C runtime headers and libraries, for executable builds.

The commands below use PowerShell from the repository root. Build the compiler:

```powershell
odin build src -out:lokec.exe
```

After a successful build, compile and run a program:

```powershell
.\lokec.exe examples\hello.loke -o hello.exe
if ($LASTEXITCODE -eq 0) { .\hello.exe }
```

`lokec` checks the program, generates LLVM IR, and invokes Clang to produce the executable. It does **not** run the program. The exit-code check avoids running an older executable if compilation fails.

Keep `lokec.exe` beside the repository's `base/`, `core/`, and `runtime/` directories. These are located relative to the compiler executable, not the shell's working directory; copying only `lokec.exe` is not a complete installation.

Program arguments go to the generated executable, not to `lokec`. The argument test program prints its argument count and values:

```powershell
.\lokec.exe tests\os\args.loke -o args.exe
if ($LASTEXITCODE -eq 0) { .\args.exe first "two words" }
```

More programs are listed in [examples/README.md](examples/README.md).
`greeting.loke` prompts for input and writes `greetings.txt` in the working directory; `keys.loke` requires a real console and exits on Escape.

### Inputs and output paths

```text
lokec <file.loke | directory> [options]
```

Each invocation accepts one root input:

- A **file** compiles that file as the root package, plus its imports. Other `.loke` files beside it are not automatically included in the root package.
- A **directory** compiles all `.loke` files directly inside it as one package, plus its imports. It does not recursively compile every subdirectory.

Executable builds require a root package named `main` with a `main :: proc()` entry point. For a multi-file package, pass its directory:

```powershell
.\lokec.exe tests\pkg\diamond -o diamond.exe
```

Use `-o <path>` to choose an output location. Without it, `examples\hello.loke` produces `examples\hello.exe`, and `tests\pkg\diamond` produces `tests\pkg\diamond.exe`. Object builds use `.obj` instead. Create the destination directory first if it does not exist,
and quote paths containing spaces. Output files at the selected path can be overwritten.

Compile examples individually: `examples/` contains separate programs, not one multi-file package.

### Common options

| Option | Purpose and default |
| --- | --- |
| `-o <path>` | Set the executable or object output path. Defaults to the input path with `.exe` or `.obj`. |
| `-opt=<mode>` | Set optimization: `none` (default), `minimal`, `size`, `speed`, or `aggressive`. These map to Clang `-O0`, `-O1`, `-Os`, `-O2`, and `-O3`. |
| `-panic=unwind\|abort` | Select whether a panic runs registered cleanup before termination. Default: `unwind`. |
| `-define:NAME=VALUE` | Supply a project-wide `build_config` value. Repeat for different names. |
| `-collection name=path` | Map an import prefix to a directory. Repeat for different prefixes. |
| `-copy-cost=N` | Warn about copies of at least `N` inline bytes or copies whose lifecycle clone may allocate. Default: `512`; use `-copy-cost=off` to disable. |
| `-build-mode=exe\|obj` | Produce an executable (default) or one relocatable object. |
| `-runtime=<dir>` | Override the C runtime source directory, normally `runtime/` beside the compiler. |

For an optimized executable:

```powershell
.\lokec.exe examples\word_frequency.loke -opt=speed -o word_frequency.exe
```

#### Build configuration

`-define` supplies values read by `build_config(NAME, default)` in source; it is
not a textual macro. Values are parsed as `true`/`false`, integers, or otherwise
strings. A name may be defined only once per invocation. Quote the whole option
when its value contains spaces, for example `'-define:APP_NAME=My App'`.

The compile-time example uses `build_config(SIEVE_LIMIT, 50)`:

```powershell
.\lokec.exe examples\compile_time.loke -define:SIEVE_LIMIT=200 -o compile_time.exe
if ($LASTEXITCODE -eq 0) { .\compile_time.exe }
```

#### Import collections

`base:` and `core:` resolve to directories beside `lokec.exe` automatically.
Ordinary use of the bundled library needs no collection flags. For example,
`import "core:fmt";` resolves to the `fmt/` package inside that `core/` directory.

An explicit collection replaces the default for that prefix. This command uses
the repository's `core/` explicitly:

```powershell
.\lokec.exe examples\hello.loke -collection core=core -o hello.exe
```

Custom collections use the same form: `-collection vendor=path\to\packages`
lets source import `"vendor:package_name"`. Collection paths supplied on the
command line are relative to the shell's working directory; relative imports
in source are resolved from the importing file.

### Inspecting a compilation

| Option | Result |
| --- | --- |
| `-parse-only` | Lex and parse one source file, then stop. No import discovery, type checking, or executable. |
| `-dump-ast` | Print that file's syntax tree, then stop at the same stage. |
| `-emit-ll` | Check the program and write LLVM IR, without invoking Clang or linking. The `.ll` path is derived from `-o`. |
| `-keep-temps` | Keep generated LLVM IR after a normal executable or object build. Normally it is removed after the Clang step. |
| `-check-layout` | Build and run an LLVM layout probe and compare sizes, alignments, and field offsets with the compiler's calculations. Requires the native toolchain. |

The parsing modes take a **file**, not a package directory:

```powershell
.\lokec.exe examples\hello.loke -parse-only
.\lokec.exe examples\hello.loke -dump-ast
.\lokec.exe examples\hello.loke -emit-ll -o hello.exe  # writes hello.ll only
.\lokec.exe tests\layout\types.loke -check-layout
```

Run `.\lokec.exe` without arguments to print the built-in usage summary.
Compiler exit codes are `0` for success, `1` for source/configuration diagnostics,
and `2` for invalid command-line usage or backend/toolchain failure. In
PowerShell, inspect `$LASTEXITCODE` immediately after the command.

### Building an object for a C host

```powershell
.\lokec.exe tests\obj\lib.loke -build-mode=obj -o widget.obj
```

An object build accepts a root package without `main` and emits no executable
entry point. Declarations marked `@(export)` provide symbols to the host.
The final C host link must supply the required Loke runtime and foreign
libraries; the object does not bundle them. An `.asm` import cannot be included
in this single-object build: assemble it separately and link it at the host's
final link step.

### Toolchain troubleshooting

- **Clang cannot be found:** `lokec` checks `LOKE_CLANG` first, then the standard
  Windows LLVM installation directories, then `PATH`. To select an installation
  for the current PowerShell session, set
  `$env:LOKE_CLANG = 'C:\Program Files\LLVM\bin\clang.exe'`.
- **C headers or runtime libraries cannot be found:** check that the MSVC C++
  toolset and Windows SDK are installed. An x64 Visual Studio developer shell
  can provide the required include and library environment.
- **Bundled packages or runtime sources cannot be found:** keep `base/`, `core/`,
  and `runtime/` beside the compiler, or select their locations with
  `-collection base=...`, `-collection core=...`, and `-runtime=...`.
- **An output file cannot be written:** make sure its parent directory exists
  and the previous executable is not still running.

### Compiler tests

For compiler development, the test script runs unit tests, rebuilds `lokec.exe`,
then runs integration tests and the run/trap corpus across all five optimization
modes:

```powershell
.\test-all.ps1
```

Known divergences between the specification and the compiler are recorded in
[known-gaps.md](known-gaps.md), each with a reproduction. The test corpus does
not cover them, which is why they are written down.

Use `.\test-all.ps1 -SkipOptimizationMatrix` for unit tests, a rebuild, and the
baseline integration suite only. The suites can also be run separately:

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
```

## Standard library

The **standard library** ([standard-library-plan.md](standard-library-plan.md)) is the first release of
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
  allocates to report a failure. A fallible call answers `Result(T, Error)`,
  composes with `or_return`, and formats through its own package's `format`;
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
