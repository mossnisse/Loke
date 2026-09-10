# Loke examples

These programs are small enough to read in one sitting, but each exercises a
different part of the language:

- `hello.loke` — the smallest useful program.
- `greeting.loke` — prompting, text-file I/O, and typed error handling.
- `streaming.loke` — bounded reads, fixed-buffer streaming, and explicit close errors.
- `keys.loke` — raw terminal input and automatic terminal restoration.
- `game_of_life.loke` — fixed arrays, custom indexing operators, `inout`, and ranges as values.
- `word_frequency.loke` — strings and borrowed views, maps, dynamic arrays, and closed-range iteration.
- `aliasing.loke` — places and overlap: disjoint mutable slices and elements loaned at once, a mutable borrow returned as an `inout` result, and `@(escape=stored)`.
- `arena_pipeline.loke` — allocators, `via`, local arena and scratch regions, and reusable reset.
- `shapes.loke` — interfaces dispatched two ways: specialized generics and erased `dyn`.
- `config_parser.loke` — unions, `or_return`, optional-ok, `or_else`, `defer`, lifecycle hooks, and `indexed()`.
- `tokens.loke` — declaring a union, variant switches, and `case` lists that match ranges.
- `compile_time.loke` — ordinary procedures run during compilation, `build_config`, `static_assert`, `when`, static expansion over reflection, and folded layout.

From the repository root, compile and run any example with:

```powershell
.\lokec.exe examples\hello.loke -o hello.exe
.\hello.exe
```

`compile_time.loke` takes a build value, which changes the size of the tables it
computes during compilation:

```powershell
.\lokec.exe examples\compile_time.loke -o compile_time.exe -define:SIEVE_LIMIT=200
```

`fmt.println` takes any number of values of any printable type and separates
them with a space, so the examples print ordinary readable output.
`game_of_life.loke` intentionally prints one bare population count per
generation. `base:` and `core:` packages are found beside the compiler
automatically, so no collection flags are needed.

## How these are checked

`odin test tests` compiles all twelve from these sources — not from copies — and
compares the output of the ones that produce a fixed result. `greeting` is run
twice in a scratch directory with supplied input, so the second run has to find
what the first wrote; `streaming` is run against a real file, a missing one, and
one past its own read limit. Every example must be classified in
`tests/corpus_test.odin`, so a new one cannot arrive unchecked.

### Checking `keys` by hand

`keys` is the one example a test cannot drive: it needs a real console, and
redirected input is `Not_A_Terminal` on purpose. Run it from a terminal —

```powershell
.\lokec.exe examples\keys.loke -o keys.exe
.\keys.exe
```

— and confirm three things:

1. ordinary keys, arrows, and modified keys are each reported once per press,
   with `ctrl+`/`alt+` prefixes where they apply, and holding one down repeats
   it — the console reports a held key as one record carrying a count;
2. Escape prints `escape` and exits;
3. the terminal is left usable: typing echoes again, and Ctrl+C works. Closing
   the window mid-run must also leave a usable terminal, which is the console
   control handler rather than the drop.
