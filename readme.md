Loke is a private project to make a new programming language building on Odin.

It aims to add more high level language functionality and more possibilities for abstractions with good ergonomics and still have the possibilities to have low level access and control of the binary output similar to Odin and C.

It aims at making it easier to handle memory allocations and complex datatypes as strings and dynamic arrays, not making the language 100% memory safe as Rust.

Loke should be able to use compiled C libraries (C ABI) and have some compatibility C datatypes to make that work.

Procedures and that are called and packages that are improted should not change how the code works for the caller or importer in any unexpected ways. The opposite may be true. Having an parameter with an pointer to data that is manipulated is an nessary evil and is allowed.

Stuff like hidden allocations are allowed but procedures returning values that has to be manually hanndled should be clearly vissible that it is needed.

The normative language specification is in [design.md](design.md), and its grammar in [grammar.md](grammar.md). Open questions, differences from Odin, and non-normative design motivations are collected in [comments.md](comments.md).

## The compiler

`lokec` is written in Odin and lives in [src/](src). The build is decomposed in
[compiler-plan.md](compiler-plan.md); the current milestone is M1, planned in
[m1-plan.md](m1-plan.md), after M0 in [m0-plan.md](m0-plan.md).

M1 completes the front end: every construct in [grammar.md](grammar.md) lexes and
parses, so `-parse-only` and `-dump-ast` accept any valid program. Compiling to an
executable still covers the M0 subset — integer arithmetic, declarations,
constants, blocks, `main`, `print_int` — and reports `L0350` for the rest.

Requires Odin and LLVM (`winget install LLVM.LLVM`); `clang` is found through
`LOKE_CLANG`, the standard Windows LLVM installation, or `PATH`.

```
odin build src -out:lokec.exe
lokec.exe examples/hello.loke -o hello.exe && hello.exe
lokec.exe examples/hello.loke -parse-only
lokec.exe examples/hello.loke -dump-ast
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
```
