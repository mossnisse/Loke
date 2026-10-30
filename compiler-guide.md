# Compiler guide

This is the command-line reference for `lokec`. Start with
[Getting started](tutorials/01-getting-started.md) for installation and a first
program, or [Building from source](readme.md#building-from-source) to build the
compiler. The commands below use PowerShell from the repository root;
examples under `tests/` require a source checkout.

- [Inputs and output paths](#inputs-and-output-paths)
- [Common options](#common-options)
- [Build configuration](#build-configuration)
- [Import collections](#import-collections)
- [Projects](#projects)
- [Interface files](#interface-files)
- [Running tests](#running-tests)
- [Default allocator and logger](#default-allocator-and-logger)
- [Inspecting a compilation](#inspecting-a-compilation)
- [Building an object for a C host](#building-an-object-for-a-c-host)
- [Language server](#language-server)
- [Toolchain troubleshooting](#toolchain-troubleshooting)

## Inputs and output paths

```text
lokec <file.loke | directory> [options]
```

Each invocation accepts one root input:

- A **file** compiles that file as the root package, plus its imports. Other
  `.loke` files beside it are not automatically included in the root package.
- A **directory** compiles all `.loke` files directly inside it as one package,
  plus its imports. It does not recursively compile every subdirectory.

Executable builds require a root package named `main` with a `main` procedure
that takes no parameters. It may return nothing, an `i32` exit status, or a
fallible result such as `Status(E)`, whose failure is reported after cleanup
with exit status 1; see
[Program entry and exit](design.md#program-entry-and-exit). For a multi-file
package, pass its directory:

```powershell
.\lokec.exe tests\pkg\diamond -o diamond.exe
```

Use `-o <path>` to choose an output location. Without it, `examples\hello.loke`
produces `examples\hello.exe`, and `tests\pkg\diamond` produces
`tests\pkg\diamond.exe`. Object builds use `.obj` instead. Create the
destination directory first if it does not exist, and quote paths containing
spaces. Output files at the selected path can be overwritten.

Compile examples individually: `examples/` contains separate programs, not one
multi-file package. [Examples](examples/README.md) describes each one.
`greeting.loke` writes `greetings.txt` in the working directory; `keys.loke`
requires a real console and exits on Escape.

Program arguments go to the built executable:

```powershell
.\lokec.exe tests\os\args.loke -o args.exe
if ($LASTEXITCODE -eq 0) { .\args.exe first "two words" }
```

## Common options

| Option | Purpose and default |
| --- | --- |
| `-o <path>` | Set the executable or object output path. Defaults to the input path with `.exe`, `.obj`, or, for a test build, `.test.exe`. |
| `-test` | Build the root package's tests and run each in its own process; see [Running tests](#running-tests). |
| `-opt=<mode>` | Set optimization: `none` (default), `minimal`, `size`, `speed`, or `aggressive`. These map to Clang `-O0`, `-O1`, `-Os`, `-O2`, and `-O3`. |
| `-cpu=<level>` | Set the instruction set the build may use: `x86-64` (default), `x86-64-v2`, or `x86-64-v3`; see [CPU levels](#cpu-levels). |
| `-panic=unwind\|abort` | Select whether a panic runs registered cleanup before termination. Default: `unwind`. |
| `-define:NAME=VALUE` | Supply a project-wide `build_config` value. Repeat for different names. |
| `-collection name=path` | Map an import prefix to a directory; `-collection:name=path` is the same. Repeat for different prefixes. |
| `-copy-cost=N` | Warn about copies that may allocate, and about copies of at least `N` inline bytes. Default: `512`; use `-copy-cost=off` to disable both. |
| `-build-mode=exe\|obj\|test` | Produce an executable (default), one relocatable object, or a test executable without running it. |
| `-runtime=<dir>` | Override the C runtime source directory, normally `runtime/` beside the compiler. |
| `-log-level=debug\|info\|warning\|error\|off` | Set the compiled `LOKE_LOG_LEVEL` used by `core:log`. Default: `debug`. |
| `-fmt`, `-fmt-check` | Rewrite a file, or a directory's `.loke` files, in the canonical layout (see [Formatting](comments.md#formatting)); `-fmt-check` only lists the files that would change and exits 1 if there are any. Only whitespace changes. |
| `-doc` | Print the package's public API as Markdown and stop: the [doc comments](design.md#doc-comments) of its `package` clauses, then each public declaration's signature and public struct field, with its doc comment, then a page for each package of the project it imports. A doc comment is a `///` line or a `/** */` block; other comments are not shown. A standard-library directory works too: `lokec core\strings -doc`. |
| `-api`, `-api-check` | Write the [interface file](#interface-files) `api.loki` in the directory of the root package and of each package of the project it imports, and stop; `-api-check` writes nothing, lists the interface files `-api` would change, and exits 1 if there are any. The input must be a directory. |
| `-g` | Emit debug information at any `-opt` level: procedures, local variables and their types, and a line for each statement, loop update, and block's closing `}`. An executable gets a `.pdb` beside it, carrying natvis rules that show a string's text, a map's entries, and the value an `any_view` or `dyn` points at in Visual Studio and WinDbg, and a panic prints the Loke call stack after its report. |
| `-debug` | Set `LOKE_DEBUG` to `true`. It does not imply `-g`, and `-g` does not imply it. |

Under `-g`, 128-bit integers and enums are shown as two unsigned 64-bit fields,
`low` and `high`. Signed values use two's complement; this avoids CodeView's
64-bit enumerator limit.

For an optimized executable:

```powershell
.\lokec.exe examples\word_frequency.loke -opt=speed -o word_frequency.exe
```

## CPU levels

`-cpu` selects one of the standard x86-64 microarchitecture levels. Each adds
to the one before it:

| Level | The processor needs |
| --- | --- |
| `x86-64` | SSE2, which every 64-bit x86 processor has. The default. |
| `x86-64-v2` | SSE3, SSSE3, SSE4.1, SSE4.2, POPCNT, CMPXCHG16B, and LAHF/SAHF |
| `x86-64-v3` | AVX, AVX2, BMI1, BMI2, F16C, FMA, LZCNT, and MOVBE, with an operating system that saves the AVX registers |

The level reaches Clang as `-march` for the generated module and the runtime
alike, and the runtime's [prebuilt objects](compiler-architecture.md#runtime-and-library-boundary)
are kept per level. A level changes speed, never results: `a*b + c` is not
fused at any level ([Floating-point operators](design.md#floating-point-operators)),
since every Clang command also passes `-ffp-contract=off`. At `x86-64-v3`,
`math.fma` is a single instruction, with the result the integer arithmetic of
the other levels computes; a constant `math.fma` has that result too.
`math.fma_is_instruction()` is then true, and `core:math/repro` takes its
exact products from the instruction, with the same results.

A procedure marked [`@(cpu_dispatch="x86-64-v3")`](design.md#cpu_dispatchstring)
also has a copy for that level in a build for a lower one, which its calls run
where the processor has the level. `core:math/repro`'s `f64` functions are
marked, so a baseline executable runs them with the FMA instruction on a
processor with `x86-64-v3`, most of the way to a `x86-64-v3` build's speed,
with the same results either way. The runtime asks the processor once per
process. Setting the environment variable `LOKE_DISPATCH_CPU` to a level caps
the copies that run at that level, and a value naming no level runs none, so
a test can take the other path on any processor:

```powershell
$env:LOKE_DISPATCH_CPU = "x86-64"
```

A program built for a level runs only on a processor that has it. An
executable built above `x86-64` therefore checks the processor before any
other code runs: its entry is baseline code whose first act is the check. On a
processor without the level it writes, for example,

```text
loke: this processor does not support x86-64-v3, which the program was built for
```

to standard error and exits with status 3. A program for distribution to
machines you do not control is usually built for `x86-64`; `x86-64-v2` costs
almost nothing on current hardware.

An [object build](#building-an-object-for-a-c-host) has no entry, so above
`x86-64` it carries a baseline static constructor that makes the same check,
which the host's C runtime runs during its startup: before the host's `main`,
or while a DLL loads. A host's own static constructor that calls an
export may run first, so it checks for itself. The runtime exports
`int32_t loke_rt_v1_cpu_supports(int32_t level)` and
`void loke_rt_v1_require_cpu(int32_t level)`, with `level` 0, 1, or 2 for the
three levels in order; the second reports and exits as the executable does.
`int32_t loke_rt_v1_cpu_dispatch(int32_t level)` is the first with
`LOKE_DISPATCH_CPU` applied, which dispatched procedures ask. All three are
baseline code, so a host may call them before anything else, for
example to choose between a baseline and a `x86-64-v3` build of a DLL before
loading one. The host also compiles the runtime sources for the object's
level: `-print-toolchain -cpu=<level>` prints the `-march` and
`-ffp-contract=off` flags with the rest.

## Build configuration

`-define` supplies values read by `build_config(NAME, default)` in source; it is
not a textual macro. Values are parsed as `true`/`false`, integers, or otherwise
strings. A name may be defined only once per invocation. Quote the whole option
when its value contains spaces, for example `'-define:APP_NAME=My App'`.

The compile-time example uses `build_config(SIEVE_LIMIT, 50)`:

```powershell
.\lokec.exe examples\compile_time.loke -define:SIEVE_LIMIT=200 -o compile_time.exe
if ($LASTEXITCODE -eq 0) { .\compile_time.exe }
```

## Import collections

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

## Projects

A `loke.project` file names the directories a program's collections come from,
so a build needs no `-collection` flags. `lokec` reads the nearest one at or
above its input:

```text
# Each line: require <name> <path>. The path is relative to this file.
require shapes ../shapes
require json vendor/json
```

Source then imports `"shapes:area"` as if `-collection shapes=../shapes` had
been passed. A dependency's own `loke.project` is read too, and one name must
name one directory across all of them: two manifests requiring one name as
different directories is `L0399`. A `-collection` for a name replaces every
manifest's directory for it, which is how a dependency is patched or vendored.
Moving or vendoring a dependency that only this manifest requires changes one
line here and no source. Replacing one that another manifest also requires,
as `require json vendor/json` above when `../shapes/loke.project` still says
`require json ../json`, needs the `-collection` as well, since the manifests
alone conflict:

```powershell
.\lokec.exe app -collection json=app\vendor\json -o app.exe
```

`base` and `core` cannot appear in a manifest; they default to the bundled
library, but an explicit `-collection` can override either. Dependencies are
local directories for now ([open-questions.md "Package and import versioning"](open-questions.md#package-and-import-versioning)).

## Interface files

A package's interface file, `api.loki`, is its public API as Loke source: what
an importer can name, each declaration after its
[doc comment](design.md#doc-comments), without bodies. Every comment in the
file is for the package's users, so a doc comment of one line is written `//`
and a longer one as a `/* */` block; one whose text contains `/*` or `*/`
stays in `//` lines. It is generated from the package and checked in beside its `.loke` files, so it
shows up in a directory listing, a search, and a code review. To use a
package, read its `api.loki`; read its source only to change it.

```powershell
.\lokec.exe shapes -api          # write shapes\api.loki, and one per project package
.\lokec.exe shapes -api-check    # list the stale ones, and exit 1 if there are any
```

A name the compiler supplies to a bundled package, such as `mem.Arena` or
`unsafe.transmute`, is declared in the package's source with
[`@(intrinsic)`](design.md#intrinsic), so its interface file and `-doc` show it
like any other declaration.

Every package in `core/` and `base/` has one, and the test suite runs
`-api-check` on each, so a change to a bundled package's public API shows up
as a diff of its `api.loki` in the same commit. A project can run
`-api-check` in its own build the same way.

The file holds, in order:

- a comment saying it is generated, then the doc comments of the package's
  `package` clauses, file by file, and the `package` clause;
- an import for each package the written declarations and conditions name,
  except one written inside a `when`, which stays in its branch;
- each public declaration, in the order of the package's file names and then
  of the source. A procedure is its signature with a `---` body; a struct
  shows its public fields and says when it has others; anything else is shown
  as written. Of the comments, only doc comments are kept;
- the public members of an `impl`, in an `impl` block;
- a file-scope `when` with its condition as written, and every branch that
  holds something shown, so the file is the same on every target. `-doc`
  shows only the branch taken.

A private declaration is shown too once a shown one names it, after a comment
saying it is private: a type that a public procedure returns or a public field
has, and the members of its `impl`; a procedure that a public overload group
gathers; a constant in a default value; and whatever those name in turn. An
importer cannot name such a declaration, but does reach it. A name is followed
to the declaration the checker resolved it to, so a parameter spelled like a
private type does not reach the type, and a private alias reaches the type it
names. In syntax the checker never resolved, an untaken `when` branch or a
generic template, a name a parameter or `$` name binds still means that
binding, so the file is the same with and without `-debug`. A member selected
through its type, as `Boxed.DEFAULT`, and a constant in `@(align=N)` are
followed too. Tests and variables are never shown.

A public member of a foreign block is shown as a plain declaration, with the
block's `default_calling_convention` written into its signature and the
block's `require_results` among its attributes. `-api` checks the packages as
[`-doc`](#common-options) does, so a `package main` needs no `main`.

The file is valid Loke that [`-fmt`](#common-options) leaves unchanged, but no
compilation reads it: the `.loke` files stay the only source of the package,
and the `.loki` extension keeps the file out of it. `-api-check` compares the
text without carriage returns, so a checkout that turned its line ends into
CRLF does not make it stale.

## Running tests

`-test` builds the root package's [test procedures](design.md#test-procedures)
into a test executable, then runs each test in a process of its own, so a panic
ends only its test. The package need not be `main`:

```powershell
.\lokec.exe tests\test\outcomes.loke -test
```

```text
ok   parses_a_digit
FAIL returns_its_failure (tests/test/outcomes.loke:21:1)
     error: Not_A_Digit
ok   prints_and_passes
FAIL fails_an_assert (tests/test/outcomes.loke:31:1)
     shown before the assert
     loke: panic: assertion failed
     loke: panicked
...
3 passed, 3 failed
```

A passing test's output is hidden; a failing one's standard output and then
standard error follow its name and declaration. `lokec` exits 1 when a test
fails, and 2 when the executable cannot be run. Only the root package's tests
run; to test an imported package, pass its directory.

The executable is written to `-o`, by default the input path with `.test.exe`,
and stays there. Run it with a test's name to repeat that test alone, under a
debugger or with `-g` for a panic's call stack, or with no argument to run every
test until the first failure. `-build-mode=test` builds it without running it.

## Default allocator and logger

The root package keeps its allocator and logger choices in source. The value
names a public zero-argument provider factory; its package does not also need
to be imported:

```loke
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

## Inspecting a compilation

| Option | Result |
| --- | --- |
| `-parse-only` | Lex and parse one source file, then stop. No import discovery, type checking, or executable. |
| `-dump-ast` | Print that file's syntax tree, then stop at the same stage. |
| `-dump-tokens` | Print that file's tokens, one `lo hi Kind` line each with the byte span, then stop after lexing. |
| `-emit-ll` | Check the program and write LLVM IR, without invoking Clang or linking. The `.ll` path is derived from `-o`. |
| `-keep-temps` | Keep the build's temporaries: the generated LLVM IR, the `-g` natvis rules, and any object NASM assembled for a `.asm` foreign import. Normally they are removed after the Clang step. |
| `-check-layout` | Build and run an LLVM layout probe and compare sizes, alignments, and field offsets with the compiler's calculations. Requires the native toolchain. |
| `-print-toolchain` | Print the Clang, MSVC toolset, and `-isystem`/`-L` flags a link would use on this machine, and whether one could run at all (`ready=yes`), then stop. Takes no input. |

The parsing modes take a **file**, not a package directory:

```powershell
.\lokec.exe examples\hello.loke -parse-only
.\lokec.exe examples\hello.loke -dump-ast
.\lokec.exe examples\hello.loke -dump-tokens
.\lokec.exe examples\hello.loke -emit-ll -o hello.exe  # writes hello.ll only
.\lokec.exe tests\layout\types.loke -check-layout
```

`.\lokec.exe -h` prints the built-in usage summary and `-version` the compiler
version.
Compiler exit codes are `0` for success, `1` for source/configuration diagnostics
or a failing test under `-test`, and `2` for invalid command-line usage or
backend/toolchain failure. In PowerShell, inspect `$LASTEXITCODE` immediately
after the command.

## Building an object for a C host

```powershell
.\lokec.exe tests\obj\lib.loke -build-mode=obj -o widget.obj
```

An object build accepts a root package without `main` and emits no executable
entry point. Declarations marked `@(export)` provide symbols to the host.
The final C host link must supply the required Loke runtime and foreign
libraries; the object does not bundle them. To link the example object with
[its C host](tests/obj/host.c), use an x64 Visual Studio developer PowerShell
with Clang on `PATH`, from the repository root:

```powershell
$runtimeSources = (Get-ChildItem runtime\*.c).FullName
clang tests\obj\host.c widget.obj @runtimeSources -I runtime -rtlib=compiler-rt -o widget-host.exe
if ($LASTEXITCODE -eq 0) { .\widget-host.exe }
```

The host exits with code `0` on success. `-rtlib=compiler-rt` supplies the
128-bit arithmetic helpers the runtime needs. An object built with `-cpu` also
needs the runtime compiled for its level, and checks the processor before the
host's `main`; see [CPU levels](#cpu-levels).

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

A host may call an export, a callback Loke handed it,
`loke_rt_v1_program_init`, or `loke_rt_v1_thread_detach` with its own
floating-point environment, such as another rounding mode or flush-to-zero:
the Loke code each runs, the providers' factories and the thread-local drops
included, runs in Loke's environment, and the host gets its own back on
return ([Floating-point operators](design.md#floating-point-operators)). A C
function the object calls must return with Loke's environment intact; build
the object with `-debug` to have each such call checked.

If the object's root package selected a provider, it also exports
`loke_rt_v1_program_init()`. Call that once on the attached startup thread,
after `loke_rt_v1_thread_attach()` and before calling any Loke export or
starting worker threads. Repeated calls after initialization are harmless. An
object built without a selected provider does not export this initializer.

An assembly import (`.asm`, `.s`, or `.S`) cannot be included in this
single-object build: assemble it separately and link it at the host's final
link step.

## Language server

`loke-lsp.exe` is a [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
server for editors. Keep it beside `lokec.exe`, `base/`, and `core/`; it finds
the bundled library the same way. An editor starts it with no arguments and
talks to it on stdin and stdout. `loke-lsp -version` prints its version.
For VS Code and VSCodium, [editors/vscode](editors/vscode/README.md) holds an
extension that starts the server and highlights Loke source; its README says
how to build and install it.

The server publishes diagnostics for open `.loke` documents as you type,
including unsaved edits. Each one is a diagnostic `lokec` reports for the same
inputs, with its code (such as `L0310`) and notes. A diagnostic belongs to the
document version it was computed from; when a later edit arrives first, the
server discards the stale result and checks again.

The server also answers these requests for open documents, from the same check
that produced the diagnostics:

- **Hover** shows the declaration of the name under the cursor and its
  [doc comment](design.md#doc-comments), as [`-doc`](#common-options) shows it. A
  procedure shows its signature, a type or constant its declaration, and a
  variable, parameter, or field its type.
- **Go to definition** jumps to where the name is declared, including in an
  imported package or the bundled library.
- **Document symbols** list the file's package-level declarations, with the
  fields of each record and the members of each enum inside it.
- **Completion** after `value.` offers the fields and methods of `value`'s
  type, the members of an enum or union named before the `.`, or the public
  declarations of an imported package. Elsewhere it offers every name in scope
  at the cursor, innermost first, then the keywords. It offers nothing inside a
  comment or a literal, or after a bare `.` whose type comes from context.
- **Signature help** shows the parameters of the call whose argument list holds
  the cursor, and which one is being written. It follows named arguments, and a
  method call's receiver is not counted.
- **Find references** lists every use of the binding under the cursor, in every
  program the server checks. A local of the same name in another scope is a
  different binding.
- **Rename** changes the binding's declaration and every use, in every program
  the server checks, including a named argument for a parameter and a
  record literal's field name. It refuses rather than guess, and says why:
  - when a program that loads the binding's file has errors;
  - when the new name is already visible where the binding is used, or a
    local with the new name is declared later where the binding is visible,
    so the meaning would change or a local would shadow another;
  - when the binding's type, or the type a selector reaches it through,
    already has a member with the new name, including a promoted field;
  - when a method's old or new name is one the compiler or an interface looks
    up by name, such as `call`, `next`, or `format`, or when a parameter is
    renamed to or from `self`;
  - when the old name appears where the compiler recorded no binding for it,
    such as an inactive `when` branch, a generic that is never instantiated,
    an interface slot, or a named result;
  - when the new name is a contextual keyword that would be read as the
    keyword at a renamed use, as `[n]int` renamed to `[dynamic]int`;
  - when the binding is predeclared, or belongs to or is used by the bundled
    library.

These work in unfinished code: a statement the compiler could not parse to the
end, such as `value.` or `call(first, `, is still checked for the names and
types it contains. A name the compiler could not resolve, such as one from a
missing import, has no hover or definition. A request waits for the check of
the text it was asked about, and references and rename wait for every program;
if the document changes first, the server answers that the content was
modified, and the editor asks again. References and rename see only the
programs of open documents, together with the packages those programs load,
so a program that is not open and uses the binding is not changed.

Two more operations reuse the command-line tools:

- **Format document** lays out the document's unsaved text as
  [`-fmt`](#common-options) would write the file, without waiting for a check.
  Only whitespace changes, and formatting the result again changes nothing.
  The editor's tab size and spaces setting are ignored, because the layout is
  fixed. Text `-fmt` refuses, such as a document that does not parse, is
  refused with the line of the first error.
- **Documentation** is the command `loke.documentation`, which an editor sends
  as `workspace/executeCommand` with an open document's URI as its only
  argument. It answers with the [interface file](#interface-files) `-api`
  writes for the document's package, checked through the document's root,
  described below, and using unsaved text. It waits for the root's check, as
  other requests do, and fails when `lokec -api` would fail because the
  program has errors. How the text is shown is up to the editor; the bundled
  extension opens it as a Loke document. The server does not check an
  `api.loki` the editor opens.

Each open document is checked through a root, which is what `lokec` would be
given:

- A document that another open document's program imports is checked as part
  of that program. It keeps the collections the program's
  [`loke.project`](#projects) supplies, which its own directory may lack. If
  more than one such program exists, the outermost importer is used. When the
  importing documents close, the document is checked through its own root
  again.
- Otherwise the root is the document's directory, so a package split across
  files is checked as one package, together with everything it imports.
- If two or more files in that directory declare `main` outside any brackets,
  the directory holds separate programs, as `examples/` does, so each file is
  its own root. A `main` in a comment or a string does not count.
- A root package named `main` is checked as `lokec <root>` checks it. Any other
  package is checked as `lokec -doc <root>` checks it, without requiring an
  entry point.

Unsaved text in any open document is used by every root, so an edit to an
imported package updates its importers' diagnostics. After its first check, a
root rechecks from the first package an edit reached and reuses the packages
before it, the bundled library among them. Adding or removing files, or
changing imports, manifests, or file attributes, checks the whole program
again. Reuse costs memory: up to 64 MiB per root, about 57 MiB for a program
of five packages. Errors found in files that are not open, such as an imported
package, are published for those files too.

The nearest [`loke.project`](#projects) is read as `lokec` reads it. Changes
made outside the editor are picked up when the editor reports changed files:
the server asks to watch `**/*.loke` and `**/loke.project` when the editor
supports it.

Editors pass configuration as `initializationOptions`. These options apply until
the server restarts:

```json
{
  "collections": ["shapes=../shapes"],
  "defines": ["VERBOSE=true"]
}
```

Each entry means what the same `-collection` or `-define` value means. A
relative collection path is relative to the first workspace folder.

## Toolchain troubleshooting

- **Clang cannot be found:** `lokec` checks `LOKE_CLANG` first, then the standard
  Windows LLVM installation directories, then `PATH`. To select an installation
  for the current PowerShell session, set
  `$env:LOKE_CLANG = 'C:\Program Files\LLVM\bin\clang.exe'`.
- **Clang reports `invalid cpu feature string for builtin` in `cpu.c`:** the
  runtime needs Clang 18 or later, whose compiler-rt detects the
  [CPU levels](#cpu-levels). `lokec -print-toolchain` names the Clang it
  uses; install a newer LLVM, or select one with `LOKE_CLANG`.
- **A `.asm` import cannot be assembled (`L0632`):** a foreign import of a
  `.asm` file is assembled with NASM, which `lokec` finds through `LOKE_NASM`
  and then `PATH`. Install NASM, or set `$env:LOKE_NASM` to its `nasm.exe`.
  Clang assembles `.s` and `.S` files itself.
- **C headers or runtime libraries cannot be found:** check that the MSVC C++
  toolset and Windows SDK are installed. An x64 Visual Studio developer shell
  can provide the required include and library environment.
- **Bundled packages or runtime sources cannot be found:** keep `base/`, `core/`,
  and `runtime/` beside the compiler, or select their locations with
  `-collection base=...`, `-collection core=...`, and `-runtime=...`.
- **An output file cannot be written:** make sure its parent directory exists
  and the previous executable is not still running.
