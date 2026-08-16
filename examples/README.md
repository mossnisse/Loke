# Loke examples

These programs are small enough to read in one sitting, but each exercises a
different part of the language:

- `hello.loke` — the smallest useful program.
- `mandelbrot.loke` — floating-point arithmetic, loops, functions, and a numerical fractal silhouette.
- `game_of_life.loke` — fixed arrays, custom indexing operators, `inout`, and ranges.
- `robot_arena.loke` — structs, managed strings, enums, methods, and custom operators.
- `spaceship_manifest.loke` — generics plus compile-time and runtime reflection.

From the repository root, compile and run any example with:

```powershell
.\lokec.exe examples\mandelbrot.loke -o mandelbrot.exe
.\mandelbrot.exe
```

The examples use the compiler's stable integer output seam, so each value is
printed on its own line. Comments beside the output calls describe each small
program's output format. `base:` packages are found beside the compiler
automatically, so the examples do not need collection flags.
