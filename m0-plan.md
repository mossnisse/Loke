# M0 — Vertical slice implementation plan

## Context

`compiler-plan.md` decomposes the Loke compiler into components (B1–B17) and
milestones (M0–M8). **M0 is the first step**: a thin end-to-end slice that proves
the whole spine exists — driver, source manager, diagnostics, lexer, parser, a
trivial type check, and a real Windows `.exe` through the textual-LLVM path
(decision A5).

The repo today is design documents only (`design.md`, `grammar.md`,
`comments.md`, `compiler-plan.md`) — **no code exists**. This plan is the
from-scratch build of `lokec` in Odin, up to M0's exit criterion:

> `main :: proc(){ ... }` compiles and prints. The whole spine and the backend
> seam exist.

Deliberately *not* in M0: MIR (B13, arrives at M6), packages/imports (B5),
generics (B9), ownership/borrows (B11/B12), the runtime (B14), arenas/interning
(A8). Decision **A6** (runtime seed language) stays unanswered because M0 links
no runtime at all.

Environment already verified on this box: Odin `dev-2025-09` at `C:\odin`,
MSVC 14.44 toolset, Windows SDK 10.0.26100, `lld-link.exe` bundled with Odin.
**LLVM is not installed** — step 0 fixes that.

Decisions taken with the user:

| | Choice |
|---|---|
| LLVM path | Install LLVM; driver shells out to `clang out.ll -o out.exe` (one process does llc + link + CRT startup; clang auto-detects the installed MSVC libs) |
| Print | Temporary compiler builtin `print_int(x: int)` lowering to `printf` — no runtime, no package loader, no `string` type |
| Subset | Strictly minimal: `main`, int variables/constants, int arithmetic, `print_int`, `return;`. **Full** lexer, subset parser |

---

## Layout

```
src/            lokec, one file per component
  main.odin       B1  driver, CLI, exit codes, toolchain discovery
  source.odin     B2  source manager + diagnostics engine
  lexer.odin      B3  full lexer per grammar.md §Lexical structure
  ast.odin        B4  node types, every node carries a Span
  parser.odin     B4  recursive descent, subset + recovery
  check.odin      B8  scopes, the two types, constant folding
  emit_llvm.odin  B16 typed AST -> textual .ll, then invoke clang
  front_end_test.odin  E   lexer/parser golden tests + malformed-input bounds
tests/
  corpus_test.odin     E   end-to-end corpus runner
  run/*.loke      + .expected  (compile, run, diff stdout)
  err/*.loke      + .expected  (compile, expect these diagnostics)
  trap/*.loke                  (compile, run, expect failure)
examples/hello.loke
```

Build: `odin build src -out:lokec.exe`. No build script, no makefile.

---

## Step 0 — Toolchain prerequisite

```bash
winget install LLVM.LLVM
```

Verify `clang --version` resolves. Nothing else to install; clang finds the MSVC
toolset and Windows SDK already present.

---

## Step 1 — Driver + source manager + diagnostics (B1, B2)

`source.odin` is the backbone of the whole error-quality goal — build it first
and never let a later phase drop a span.

- `Source_File{ path, text: []u8, line_starts: []int }`; `Span{ file: u32, lo, hi: u32 }`.
  Line/col is computed by binary search on `line_starts` at *render* time only.
- Reject a UTF-8 BOM at load (grammar §Source encoding).
- `Diagnostic{ severity, code: string, span, message, notes: []Note }`. Codes are
  stable strings from the start (`L0001`…) — retrofitting them later is churn.
- **Accumulate, never abort.** Phases run to completion and the driver reports at
  a phase boundary; exit 1 if any error was emitted.
- Renderer, one procedure, rustc-shaped:

  ```
  error[L0104]: expected an expression
   --> examples/hello.loke:3:14
    |
  3 |     x := 1 + );
    |              ^ found `)`
  ```

- CLI: `lokec <file.loke> [-o out.exe] [-emit-ll] [-keep-temps]`.
  Exit codes: `0` ok, `1` user diagnostics, `2` internal/toolchain failure.
- Memory: one default allocator, nothing freed, process exits.
  `// ponytail: no arenas/interning (A8); add when a compile is slow or big enough to notice.`

**Exit:** `lokec missing.loke` and `lokec bom.loke` produce a clean rendered
diagnostic and exit 1.

## Step 2 — Lexer (B3) — complete, not a subset

The lexical spec is small and fully written down; implementing it once beats
implementing it twice. This is the one part of M0 that is finished work.

- Tokens for every operator in grammar §Operators and punctuation, every reserved
  keyword, all literal forms, `Hash_Name`, EOF, and an `Error` kind.
- **`::` and `:=` are token pairs, not tokens.** `x := 1` lexes `x` `:` `=` `1`.
  Getting this wrong is the single most likely reflex error in the whole step —
  it is what makes `x: int = 1`, `x: = 1`, and `x := 1` one declaration form.
- Longest match, with `&~=`, `..=`, `..<`, `<<=`, `>>=`, and `---` as the cases
  that break a naive one-or-two-char scanner.
- Nested block comments via a depth counter.
- Contextual keywords (`static`, `self`, `slot`, `using`, `delegate`,
  `thread_local`, `manual`) lex as plain identifiers — position is the parser's
  problem. Same for `nil`/`true`/`false` and the built-ins, which are
  predeclared identifiers and shadowable.
- `#name` restricted to `#assert`, `#config`, `#location`, `#caller_location`;
  anything else is a lexical error (grammar §Compile-time names).
- Non-ASCII outside strings, comments and rune literals is an error.
- Literals: `0b`/`0o`/`0x` and decimal with `_` separators (not leading), floats
  with exponent, string escapes per the `Escape` production, raw strings in
  backticks (may span lines), runes.
- On a bad character emit an `Error` token and keep going — the parser must still
  be able to produce a useful message.

**Exit:** golden token dumps for a file exercising every token kind; malformed
inputs yield error tokens plus diagnostics, never a crash.

## Step 3 — AST + parser (B4) — subset with real recovery

- Every node embeds `Span`. No node without one.
- Grammar covered in M0:
  - `Source_File = Package_Clause Top_Level_Item*`
  - `Top_Level_Item`: `Declaration` and `";"`.
  - `Constant_Decl` with a `Proc_Definition` brace body (`main :: proc() { … }`),
    and with a `Semicolon_Constant_Value` expression (`N :: 3;`).
  - `Variable_Decl` in all three spellings: `x: int = e;`, `x: = e;` / `x := e;`,
    `x: int;`.
  - `Block`, and statements: `Declaration`, `Simple_Statement ";"`,
    `Return_Statement`, `";"`.
  - Expressions: levels **6** and **7** only (`+ - | ~`, then `* / % & &~ << >>`),
    `Unary_Expression` for `+ -`, and `Postfix_Expression` with the call suffix.
    Primaries: `Int_Literal`, `Identifier`, `"(" Expression ")"`.
- Everything else in the grammar is **recognized and diagnosed**, not met with
  "unexpected token": on `struct`, `import`, `if`, `foreach`, `or_else`, `[`, a
  selector `.`, etc., emit `L02xx not supported in M0` pointing at that construct
  and resynchronize. This costs a switch arm each and is the difference between a
  usable prototype and a hostile one.
- Declaration-vs-statement uses the grammar's bounded scan: a comma-separated
  identifier list followed by `:` is a declaration.
- Recovery: synchronize on `;`, `}`, and top-level keywords. A parse error never
  aborts the file.

**Exit:** `examples/hello.loke` parses to the expected AST dump; a corpus of
malformed files each yields a recovering diagnostic at the right span.

## Step 4 — Check (B8, minimal) + constant folding

- Types in M0: `int` (i64), `untyped_int`, `void`. That is the whole type system;
  B7's interned type table arrives with M2.
- Two passes per the B6 shape: collect top-level declarations (order-independent),
  then resolve bodies (order-dependent). Block scopes; `_` binds nothing and
  cannot be read; **shadowing is rejected** (design's open-question default).
- `untyped_int` constants default to `int` on assignment or use; check they fit
  i64 and diagnose overflow at the literal's span.
- Declaration semantics: `x: int;` is the zero value; `x: int : e;` requires a
  constant `e`; a constant's value is folded now.
- Fold integer literal arithmetic; constant division or modulo by zero is a
  diagnostic, not a trap.
- Require package `main` with exactly one `main :: proc()`: no parameters, no
  results (design §Program entry and exit).
- `print_int` is a predeclared builtin symbol, `proc(int)`.
  `// ponytail: M0 scaffolding standing in for core:fmt; delete when B14/M6 lands.`
- Annotate AST nodes in place with their type and constant value — that *is* the
  typed AST of A1.

**Exit:** correct programs check clean; type errors, unknown names, shadowing,
a missing or mis-signed `main`, and non-constant constant initializers each give
a specific code and span.

## Step 5 — LLVM emit + link (B16/B17, minimal)

Typed AST straight to textual `.ll`. **No MIR in M0** — B13 is M6 work; keeping
codegen to this one file is what makes it replaceable then.

- Preamble: `target triple = "x86_64-pc-windows-msvc"`, `declare i32 @printf(ptr, ...)`,
  and a private `c"%lld\0A\00"` format constant.
- Loke `main` emits as `@loke_main`; emit a C `define i32 @main()` wrapper that
  calls it and returns 0. The wrapper is where internal runtime startup belongs,
  so the shape is right from day one.
- **Every local is an `alloca` plus load/store.** No SSA construction, no phi
  nodes — LLVM's `mem2reg` does that. This is the single largest laziness win in
  M0; do not hand-roll it.
- Folded constants emit as literals. `print_int(e)` emits a `printf` call.
- Then: `clang <out.ll> -o <out.exe>`. Find clang on `PATH`, else `$LOKE_CLANG`,
  else exit 2 with a diagnostic naming `winget install LLVM.LLVM`.
- `-emit-ll` writes the `.ll` and stops; `-keep-temps` leaves it beside the exe.
  Both pay for themselves the first time codegen is wrong.

**Exit:** `lokec examples/hello.loke -o hello.exe` produces an exe that prints.

## Step 6 — Test corpus (E)

Small `@(test)` procedures use `core:testing`; `odin test src` exercises the
lexer/parser directly and `odin test tests` runs the external compiler corpus.
No framework.

- `tests/run/*.loke` + `.expected`: compile, run the exe, diff stdout.
- `tests/err/*.loke` + `.expected`: compile, assert the rendered diagnostics
  (exact count, error code, line/column, and message) — the error-quality goal as a testable artifact, per
  `compiler-plan.md` §E.
- `tests/trap/*.loke`: compile and assert that the executable takes its explicit
  runtime-failure path.
- Seed it with the golden token/AST dumps from steps 2 and 3.

Parser fuzzing is M1's, not M0's.

---

## Verification

```bash
odin build src -out:lokec.exe
```

```bash
./lokec.exe examples/hello.loke -o hello.exe && ./hello.exe
```

Expected: `42` (or whatever `examples/hello.loke` computes).

```bash
odin test src
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
```

Manual spot-checks that the spine actually holds:

- `./lokec.exe examples/hello.loke -emit-ll` — eyeball the `.ll`; it should be
  short and obviously correct.
- A file with three separate errors reports **all three**, not the first.
- A file using `struct` or `import` reports "not supported in M0" at that
  keyword, not a parse-noise cascade.
- `echo 'package main;' > empty.loke && ./lokec.exe empty.loke` — a clear
  "no `main` procedure" diagnostic, exit 1.

## Deliberate shortcuts, and when they get paid

| Shortcut | Add when |
|---|---|
| No MIR — AST straight to `.ll` | M6 (B13), when lowering needs explicit cleanup/control flow |
| `alloca` + `mem2reg` instead of SSA construction | Only if a debug backend without LLVM ever lands (A4, out of v1 scope) |
| `print_int` builtin instead of `core:fmt` | M6, with the seed runtime (B14) |
| No semantic arenas or interning | The syntax AST gained a per-file arena in the M1 foundation; identifier and semantic-type interning arrive with package/type-system work (A8) |
| Two hard-coded types instead of B7's interned table | M2 |
| Ad-hoc integer folding instead of the B10 interpreter | M3 |
