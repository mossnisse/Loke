# Loke

Loke is an experimental general-purpose programming language that builds on ideas from Odin.

It aims to provide higher-level language features and ergonomic abstractions
while preserving low-level access and control over generated binaries comparable
to Odin and C.

Loke is intended to make memory allocation and compound types such as strings
and dynamic arrays easier to manage. It does not attempt to provide Rust-style
complete memory safety.

The language supports compiled C libraries through the C ABI and provides
C-compatible data types for interoperability.

Loke aims to be expressive enough that separate preprocessors, macro systems,
and bespoke build scripts are unnecessary.

Procedure calls and package imports should not change a caller's behavior in
unexpected ways. Mutation through an explicitly passed mutable pointer is
allowed because the possibility is visible at the call boundary. Hidden
allocations are also allowed, but a returned value that requires manual cleanup
should make that responsibility clear in its type or API.

The normative language specification is in [design.md](design.md), and its grammar in [grammar.md](grammar.md). Open questions, differences from Odin, and non-normative design motivations are collected in [comments.md](comments.md).

## The compiler

`lokec` is written in Odin and lives in [src/](src). The v1 compiler implements
the language described by `design.md`, subject to the documented
[known gaps](known-gaps.md). Its pipeline, phase contracts, allocation ownership,
and source-code map are documented in
[compiler-architecture.md](compiler-architecture.md). Longer-term work is
summarized in [future-plans.md](future-plans.md). Contributor conventions,
for people and coding agents alike, are in [AGENTS.md](AGENTS.md).

### Build and run

The current compiler targets **Windows x64**. You need:

- **Odin**, on `PATH`, to build `lokec` from source. The tree builds with
  `dev-2025-09-nightly`; Odin nightlies change often, so another one may not.
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
| `-log-level=debug\|info\|warning\|error\|off` | Set the compiled `LOKE_LOG_LEVEL` used by `core:log`. Default: `debug`. |

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

#### Default allocator and logger

The root package keeps its allocator and logger choices in source. The value
names a public zero-argument provider factory; its package does not also need
to be imported:

```odin
@(
	default_allocator = "./providers:allocator_factory",
	default_logger = "./providers:logger_factory",
)
package main;
```

Relative provider paths resolve from this file. Collection-qualified paths such
as `"platform:runtime:allocator_factory"` work as well. Only the root package
may use these attributes, so an import cannot change the program's
process-wide policy, and each may be written once across a multi-file root
package. An `obj` build selects the same way.

### Inspecting a compilation

| Option | Result |
| --- | --- |
| `-parse-only` | Lex and parse one source file, then stop. No import discovery, type checking, or executable. |
| `-dump-ast` | Print that file's syntax tree, then stop at the same stage. |
| `-emit-ll` | Check the program and write LLVM IR, without invoking Clang or linking. The `.ll` path is derived from `-o`. |
| `-keep-temps` | Keep the build's temporaries: the generated LLVM IR, and any object NASM assembled for a `.asm` foreign import. Normally both are removed after the Clang step. |
| `-check-layout` | Build and run an LLVM layout probe and compare sizes, alignments, and field offsets with the compiler's calculations. Requires the native toolchain. |
| `-print-toolchain` | Print the Clang, MSVC toolset, and `-isystem`/`-L` flags a link would use on this machine, and whether one could run at all (`ready=yes`), then stop. Takes no input. |

The parsing modes take a **file**, not a package directory:

```powershell
.\lokec.exe examples\hello.loke -parse-only
.\lokec.exe examples\hello.loke -dump-ast
.\lokec.exe examples\hello.loke -emit-ll -o hello.exe  # writes hello.ll only
.\lokec.exe tests\layout\types.loke -check-layout
```

`.\lokec.exe -h` prints the built-in usage summary and `-version` the compiler
version.
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
libraries; the object does not bundle them.

Every host thread must attach to the runtime before calling a Loke export and
detach before the thread exits:

```c
void loke_rt_v1_thread_attach(void);
void loke_rt_v1_thread_detach(void);

int main(void) {
    loke_rt_v1_thread_attach();
    /* Call Loke exports here. */
    loke_rt_v1_thread_detach();
    return 0;
}
```

If the object's root package selected a provider, it also exports
`loke_rt_v1_program_init()`. Call that once on the attached startup thread,
after `loke_rt_v1_thread_attach()` and before calling any Loke export or
starting worker threads. Repeated calls after initialization are harmless. An
object built without a selected provider does not export this initializer.

An `.asm` import cannot be included in this single-object build: assemble it
separately and link it at the host's final link step.

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

For compiler development, the test script checks spec citations and backend
layering, runs unit tests, rebuilds `lokec.exe` with Odin's vet checks, then runs
integration tests and the run/trap corpus across all five optimization modes:

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
odin build src -out:lokec.exe -vet-unused -vet-shadowing
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
```

## Standard library

The **standard library** is ordinary Loke code over the compiler and runtime
foundation; [standard-library.md](standard-library.md) documents its design
rules and each package's API. `base:` stays reserved for declarations that
participate in the language or its runtime ABI. General-purpose code lives in
`core:`, in small packages a program imports by name, with no prelude:

```text
core:container        fixed-capacity and enum-indexed containers and sets
core:cstrings         owned zero-terminated buffers for foreign APIs
core:encoding/utf16   UTF-8 to UTF-16 conversion and back
core:endian           endian-specific storage wrappers
core:fmt              value formatting and process diagnostics
core:fs               files, directories, and file metadata
core:io               byte-stream protocols and shared I/O errors
core:log              logging through the build-selected provider
core:math             elementary functions, complex numbers, and quaternions
core:mem              allocators, arenas, and scratch regions
core:os               arguments, exit, environment, and process state
core:path             lexical path operations
core:simd             cross-lane SIMD operations
core:slice            slice algorithms
core:strconv          scalar parsing
core:strings          UTF-8 algorithms, iterators, and String_Builder
core:sync             atomics, fences, and one-time initialization
core:term             standard streams and terminal key input
core:unsafe           explicit unchecked operations and conversions
```
