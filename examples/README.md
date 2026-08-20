# Loke examples

These programs are small enough to read in one sitting, but each exercises a
different part of the language:

- `hello.loke` — the smallest useful program.
- `mandelbrot.loke` — floating-point arithmetic, loops, functions, and a numerical fractal silhouette.
- `game_of_life.loke` — fixed arrays, custom indexing operators, `inout`, and ranges.
- `robot_arena.loke` — structs, managed strings, enums, methods, and custom operators.
- `spaceship_manifest.loke` — generics plus compile-time and runtime reflection.
- `word_frequency.loke` — strings and borrowed views, maps, dynamic arrays, and iteration.
- `arena_pipeline.loke` — allocators, `via`, local arena and scratch regions, and reusable reset.
- `shapes.loke` — interfaces dispatched two ways: specialized generics and erased `dyn`.
- `config_parser.loke` — unions, `or_return`, optional-ok, `or_else`, `defer`, and lifecycle hooks.
- `compile_time.loke` — ordinary procedures run during compilation, `#config`, `#assert`, `when`, static expansion over reflection, and folded layout.

From the repository root, compile and run any example with:

```powershell
.\lokec.exe examples\mandelbrot.loke -o mandelbrot.exe
.\mandelbrot.exe
```

`compile_time.loke` takes a build value, which changes the size of the tables it
computes during compilation:

```powershell
.\lokec.exe examples\compile_time.loke -o compile_time.exe -define:SIEVE_LIMIT=200
```

`fmt.println` takes any number of values of any printable type and separates
them with a space, so the examples print ordinary readable output. The five
older programs predate that and print bare integers; their comments describe
what each number means. `base:` and `core:` packages are found beside the
compiler automatically, so no collection flags are needed.
