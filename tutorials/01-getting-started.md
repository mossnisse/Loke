# Getting started

This page installs the compiler, then builds and runs a first program.

## What you need

The compiler, `lokec`, runs on 64-bit Windows. It turns a Loke program into
LLVM IR and hands that to Clang, which produces the executable, so two tools
come first:

- **LLVM**, which provides Clang. Install it with
  `winget install LLVM.LLVM`, or from the [LLVM releases page](https://github.com/llvm/llvm-project/releases).
- **The Microsoft C++ build tools and the Windows SDK**, which provide the
  linker and the C runtime. Install
  [Build Tools for Visual Studio](https://visualstudio.microsoft.com/downloads/)
  and select the *Desktop development with C++* workload.

## Installing Loke

Download the latest `loke-v….zip` from the
[releases page](https://github.com/mossnisse/Loke/releases) and unzip it
somewhere permanent, such as `C:\loke`. The zip holds one directory with
`lokec.exe` and the `base`, `core`, and `runtime` directories beside it. Keep
them together: the compiler finds its library next to itself, so a copy of
`lokec.exe` on its own does not work.

Put that directory on your `PATH`. For the current PowerShell window:

```powershell
$env:PATH += ";C:\loke\loke-v0.7.1-windows-amd64"
```

To keep it for new windows as well, add the same directory to the user `Path`
under *Settings > System > About > Advanced system settings > Environment
Variables*.

Check that everything is found:

```powershell
lokec -version
lokec -print-toolchain
```

The first prints the version. The second prints where Clang and the Microsoft
tools are, and ends with `ready=yes` when a program can be built. If it ends
with `ready=no`, one of the two was not found;
[Toolchain troubleshooting](../readme.md#toolchain-troubleshooting) in the
readme says where lokec looks for each.

You can also build the compiler from source instead; the
[readme](../readme.md#building-from-source) explains how.

## A first program

Make a directory for these tutorials, and save this as `hello.loke` inside it:

```odin file=hello.loke
package main;

import "core:fmt";

main :: proc() {
	fmt.println("Hello from Loke!");
}
```

Build it and run it:

```powershell
lokec hello.loke
.\hello.exe
```

```text output=hello
Hello from Loke!
```

`lokec hello.loke` checks the program and writes `hello.exe` beside it. It
does not run the program; that is the second command. Use `-o` to choose the
name of the executable: `lokec hello.loke -o greeter.exe`.

Line by line:

- `package main;` says which package this file belongs to. A program starts in
  the package named `main`.
- `import "core:fmt";` makes the `fmt` package from the core library available
  under the name `fmt`. Nothing is imported unless you ask for it.
- `main :: proc() { ... }` declares a procedure named `main`, which is where
  the program starts. `::` declares something that never changes: here, the
  procedure itself.
- `fmt.println` prints its arguments and ends the line.

Statements end with a semicolon. A declaration that ends in a `}`, like `main`
here, needs none.

`fmt.println` takes any number of values, of any type, and puts a space
between them:

```odin file=println.loke
package main;

import "core:fmt";

main :: proc() {
	fmt.println("one", 2, 3.5, true);
	fmt.println();
	fmt.println("the line above is empty");
}
```

```text output=println
one 2 3.5 true

the line above is empty
```

## When something is wrong

The compiler checks the whole program before it writes anything. Here is a
program with a mistake, saved as `mistake.loke`:

```odin file=mistake.loke
package main;

import "core:fmt";

main :: proc() {
	count: int = "three";  // error: "three" is not an `int`
	fmt.println(count);
}
```

`count: int` declares a variable that holds an `int`, and `"three"` is not an
`int`. `lokec mistake.loke` says so and builds nothing:

```text error=mistake
error[L0310]: this constant is not a value of `int`
 --> mistake.loke:6:15
   |
6 | 	count: int = "three";  // error: "three" is not an `int`
   | 	             ^^^^^^^
```

A diagnostic names the problem, its code, and the file, line, and column. The
code, `L0310` here, is the same wherever the problem appears. When lokec
rejects a program its exit code is 1, so a script can stop there:

```powershell
lokec hello.loke
if ($LASTEXITCODE -eq 0) { .\hello.exe }
```

## Optimized builds

By default lokec builds quickly and does not optimize. For a program you will
run a lot, ask for optimization:

```powershell
lokec hello.loke -opt=speed
```

The levels are `none` (the default), `minimal`, `size`, `speed`, and
`aggressive`. The program means the same at every level; only its speed and
size change.

`lokec -h` lists every option.

Next: [Values and control flow](02-values-and-control-flow.md).
