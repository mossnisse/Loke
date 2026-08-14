Loke is a private project to make a new programming language building on Odin.

It aims to add more high level language functionality and more possibilities for abstractions with good ergonomics and still have the possibilities to have low level access and control of the binary output similar to Odin and C.

It aims at making it easier to handle memory allocations and complex datatypes as strings and dynamic arrays, not making the language 100% memory safe as Rust.

Loke should be able to use compiled C libraries (C ABI) and have some compatibility C datatypes to make that work.

Procedures and that are called and packages that are improted should not change how the code works for the caller or importer in any unexpected ways. The opposite may be true. Having an parameter with an pointer to data that is manipulated is an nessary evil and is allowed.

Stuff like hidden allocations are allowed but procedures returning values that has to be manually hanndled should be clearly vissible that it is needed.

The normative language specification is in [design.md](design.md), and its grammar in [grammar.md](grammar.md). Open questions, differences from Odin, and non-normative design motivations are collected in [comments.md](comments.md).

## The compiler

`lokec` is written in Odin and lives in [src/](src). The build is decomposed in
[compiler-plan.md](compiler-plan.md); the current milestone is M4a, planned in
[m4a-plan.md](m4a-plan.md), after M3 in [m3-plan.md](m3-plan.md), M2 in
[m2-plan.md](m2-plan.md), M1 in [m1-plan.md](m1-plan.md) and M0 in
[m0-plan.md](m0-plan.md). [m4b-plan.md](m4b-plan.md) is the other half of M4.

M1 completed the front end: every construct in [grammar.md](grammar.md) lexes and
parses, so `-parse-only` and `-dump-ast` accept any valid program.

M2 compiles the static, non-generic, non-managed core of the language to a
Windows executable:

- every scalar type — `bool`, `i8`–`i128`, `u8`–`u128`, `int`, `uint`,
  `uintptr`, `byte`, `f16`/`f32`/`f64`, `rune`, `rawptr` — with exact
  arbitrary-precision constant folding, so `u128`'s maximum and `i128`'s minimum
  are ordinary constants;
- `struct`, `enum`, `[N]T`, `^T`, `distinct`, procedure types, and type aliases,
  including aggregate constants and recursive structural equality;
- every built-in operator, conversions `T(v)`, `x if c else y`, indexing, field
  selection, `&`/`^`, and composite literals;
- assignment in all its forms, `if`/`for`/`switch`, `break`, `continue`,
  `defer`, and `return`;
- procedures with value and `inout` parameters, defaults, named arguments,
  multiple and named results, recursion, and procedure values.

M3 adds the compile-time engine and packages:

- one tree-walking interpreter over the typed AST, with frames, locals,
  mutation, loops, `defer`, recursion, and `inout` aliases, so an ordinary
  procedure can supply a constant, an array length, or an enum value — and the
  same procedure still compiles for run time;
- `assert` and `panic` in either phase: diagnosed with the compile-time call
  stack when evaluation reaches them, lowered to the runtime trap seam
  otherwise;
- natural target layout, with `size_of`, `align_of`, `offset_of`, and fixed-array
  `len` folded to `int`. Their operands are inspected, never evaluated;
- untyped compile-time strings — joined, compared, and measured — plus
  `#assert(condition[, message])`, `#config(NAME, default)`, and
  `-define:NAME=VALUE`. Storing one in a runtime binding is still one `L0350`;
- `when` at file and procedure scope, as structural source selection: an
  unselected branch is parsed and nothing else;
- directory packages, multi-file packages, relative and `collection:` imports,
  the import DAG with cycles reported as a path of import statements,
  `@(public)`/`@(private)` visibility, and one LLVM module emitted in dependency
  order with package-qualified symbol names.

Evaluation is bounded: 1,000,000 steps, 256 explicit frames, and 64 MiB of
scratch memory. Exceeding one is a diagnostic, never a silent fallback to
generating runtime code. Reading a mutable file-scope variable, calling
`print_int`, or letting a pointer escape is rejected on an executed path.

An import path prefix resolves only through `-collection name=path`; there is no
implicit `core:` root and no core library yet.

M4a makes user-defined types as capable as built-in ones at concrete types:

- one overload-resolution engine — viability filtering, per-argument conversion
  ranks, vector partial ordering, and the four tie-breakers — shared by named
  procedure groups, methods, operators, `init`, and indexing. An ambiguity lists
  every maximal candidate, its conversion vector, and the tie-breaker where
  selection failed;
- `proc{...}` groups, `impl` and `extend` blocks, the three receiver forms,
  associated constants and types, `Type.member` access, and field lookup taking
  priority over method-call sugar. An `extend` block changes lookup only inside
  its own package;
- `init` overloads with the two-stage `T(...)` resolution — a built-in or
  `distinct` conversion first, `init` overloads otherwise — and `@(implicit)`
  one-argument conversions reachable only from an untyped constant;
- `operator(sym)` declarations and groups, the `!=` and compound-assignment
  fallbacks, `operator([])`/`([]=)`/`([:])` with place-position selection, and
  `delegate(...)` on `distinct` types. A built-in operation on built-in operands
  cannot be shadowed: `int + int` keeps its meaning in every file;
- `union` with a tagged representation, `@(align=N)`, a nil zero value, `v.(T)`
  in both its trapping and comma-ok phases, the type switch with exhaustiveness
  reporting, and the error protocol — optional-ok results, `or_else`, and
  `or_return` with its named-result and definite-initialization rules.

Everything else — generics, interfaces, runtime `string`, slices, maps,
`foreach`, `typeid`, `any_view`, and `#location`/`#caller_location` — parses and
reports one diagnostic at the enclosing construct.

Requires Odin and LLVM (`winget install LLVM.LLVM`); `clang` is found through
`LOKE_CLANG`, the standard Windows LLVM installation, or `PATH`.

```
odin build src -out:lokec.exe
lokec.exe examples/hello.loke -o hello.exe && hello.exe
lokec.exe tests/pkg/diamond -o diamond.exe          # a directory is one package
lokec.exe app -collection core=vendor/core -define:DEBUG=true
lokec.exe examples/hello.loke -parse-only
lokec.exe examples/hello.loke -dump-ast
lokec.exe tests/layout/types.loke -check-layout
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
```
