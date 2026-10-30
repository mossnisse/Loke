# Loke

Loke is an experimental general-purpose programming language inspired by Odin.
It combines higher-level types and abstractions with explicit control over
memory allocation and C interoperability.

- Owning values clean up at scope exit: strings, containers, and boxes release
  their storage, and an open file closes.
- Local borrow checking tracks views and their lifetimes.
- Generics, interfaces, and compile-time execution support reusable code.
- `Option` and `Result` represent absence and failure as values.

Loke does not provide complete memory safety; see
[what is not checked](design.md#what-is-not-checked). The compiler, `lokec`, is
written in Odin and currently supports **Windows x64**. Releases are
**pre-1.0** and minor releases may break compatibility; see the
[version policy](releasing.md#version-policy) and [changelog](CHANGELOG.md).
Current implementation limits are in [known gaps](known-gaps.md).

## Getting started

Install **LLVM/Clang** and the **Microsoft C++ build tools with the Windows SDK**,
then download and extract a compiler bundle from the
[releases page](https://github.com/mossnisse/Loke/releases).
[Getting started](tutorials/01-getting-started.md) walks through installation
and adding the compiler to `PATH`.

Keep `lokec.exe`, `base/`, `core/`, and `runtime/` together. The compiler finds
these directories beside its executable, so you can invoke it from any working
directory. The bundle also includes `loke-lsp.exe`, the
[language server](compiler-guide.md#language-server) for editors, and the
[VS Code extension](editors/vscode/README.md) that starts it. In
PowerShell, check the installation:

```powershell
lokec -version
lokec -print-toolchain
```

The toolchain report should end with `ready=yes`. Otherwise, see
[Toolchain troubleshooting](compiler-guide.md#toolchain-troubleshooting).

## A first program

Save this as `hello.loke`:

```loke
package main;
import "core:fmt";

main :: proc() {
	x := 40;
	y: int = x + 2;
	fmt.println("The answer is", y);
}
```

Compile and run it in PowerShell:

```powershell
lokec hello.loke
if ($LASTEXITCODE -eq 0) { .\hello.exe }
```

```text
The answer is 42
```

`lokec` writes an executable; run that executable to start the program.
Use `-o <path>` to choose its output path, `-opt=speed` to optimize, and `-g`
for debug information. A file input builds that file and its imports; a
[directory input](compiler-guide.md#inputs-and-output-paths) builds all `.loke`
files directly inside it as one package. `lokec -h` lists the options.

Continue with the [tutorials](tutorials/README.md), or explore the
[examples](examples/README.md). The [language tour](examples/tour.loke) shows
records, methods, operators, typed errors, and ownership in one program.

## Building from source

In addition to the tools above, install **Odin** on `PATH`. CI uses
`dev-2026-10` (commit `84bc3fc`); other versions may not build this tree.
From the repository root:

```powershell
odin build src -out:lokec.exe
if ($LASTEXITCODE -eq 0) { .\lokec.exe examples\hello.loke -o hello.exe }
if ($LASTEXITCODE -eq 0) { .\hello.exe }
```

To build the language server too, run `odin build lsp -out:loke-lsp.exe`.
That build is quick to make. A release adds `-o:speed` to both commands: the
build takes about a minute each, and the compiler runs two to three times
faster.

## Documentation

| To learn about | Read |
| --- | --- |
| Using the language | [Tutorials](tutorials/README.md) and [examples](examples/README.md) |
| Compiler options, projects, and C-host builds | [Compiler guide](compiler-guide.md) |
| Standard-library packages and APIs | [Standard library](standard-library.md) |
| Language rules and syntax | [Design](design.md) and [grammar](grammar.md), both normative |
| Design rationale and differences from Odin | [Comments](comments.md) |
| Open questions and planned work | [Open questions](open-questions.md) and [future plans](future-plans.md) |

The library covers text, containers, files and paths, processes, threads,
synchronization, time, random numbers, JSON, logging, terminal input, math, and
allocators. Import the packages you use, such as `core:fmt` or `core:thread`.
Packages under `base:` hold only what the language itself depends on, such as
the interface catalogue in `base:interfaces`; import them like any other.

## Compiler development

Read [AGENTS.md](AGENTS.md) for contributor conventions and
[Compiler architecture](compiler-architecture.md) for the implementation.
Run the quick gate from the repository root:

```powershell
.\test-all.ps1
```

CI runs the full gate. [Testing and verification](compiler-architecture.md#testing-and-verification)
describes individual suites and optional tools; [Releasing](releasing.md)
covers the release process.

## License

Loke uses the [zlib License](LICENSE).
