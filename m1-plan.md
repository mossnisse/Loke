# M1 — Full front end implementation plan

## Context

`compiler-plan.md` milestone M1: a complete lexer and parser for *all* of
[grammar.md](grammar.md), with error recovery and a test corpus. M0 shipped the
spine — driver, source manager, diagnostics, full lexer, subset parser, trivial
checker, textual-LLVM backend. M1 widens the front end only.

M1 stays syntax-only: new constructs work under `-parse-only` and `-dump-ast`;
the M0 program subset keeps type-checking, emitting LLVM, and running.

**Exit criteria**

- Every valid grammar production lexes and parses with zero diagnostics, and each
  is covered by a fixture that names the productions it exercises.
- Every node carries a span ending at its last **consumed** token; spans stay
  inside the file and nest monotonically.
- Malformed input produces a focused diagnostic, recovers to a later sentinel
  construct, and never crashes, loops, or overflows the stack.
- Existing M0 run, err and trap tests still pass.
- Mutation fuzzing over the valid corpus terminates safely with bounded spans.

---

## Decisions

| | Choice | Why |
|---|---|---|
| Syntax node domain | **One union.** Type forms (`^T`, `[]T`, `map[K]V`, `proc(...)`, `struct{...}`) become node kinds inside `Expr`. `Type_Syntax` goes away. | The grammar refuses to separate them: `Generic_Argument = Type \| Expression`, `Argument_Value = Expression \| Type`, `Primary = "(" Type ")"`, `Composite_Type`. `Matrix(f32, 4)` and `f(a, b)` are the same token stream. Separate domains means parsing the overlap twice plus a bridge union M2 must classify. This supersedes the comment at `src/ast.odin:166`, which predates the overlap being implemented. |
| Type positions | `parse_type` is a **restricted entry point** into that one domain, not a second grammar: it handles the distinctive forms itself and otherwise delegates to name / selector / generic-application / parenthesised parsing. | `x: 1 + 2;` still fails at parse with "expected a type", so strict syntax survives without a post-hoc shape gate. |
| M0 semantic gate | Report from the **default arm of the checker's dispatch**, code `L0350`. No separate pass. | Expanding the unions forces a dispatch arm in `check.odin` regardless; a separate pass is a whole second tree walker. "One error per outer construct, descendants skipped" falls out of not descending. `-parse-only`/`-dump-ast` already bypass it — `src/main.odin:59` never calls `check`. |
| Node granularity | Slices for list productions; one node with a kind flag for near-identical pairs. | `Identifier_List`, `Expression_List`, `Parameter_Names`, `Element_List`, `Argument_List`, `Type_Arguments`, `Bindings` and `Results` are slices. impl/extend, struct/union, top-level `when`/`when` statement, and proc definition/declaration each collapse to one node. |
| Goldens | Exact AST dumps for the **ambiguity fixtures only**; invariants for the bulk corpus. | Shape *is* the assertion for an ambiguity. Elsewhere "zero diagnostics + EOF consumed + spans bounded" catches the same regressions without rewriting the corpus on every dump tweak. |
| Sequencing | Four slices, each ending with a green `odin test`. | One big-bang AST replacement leaves `check.odin` and `emit_llvm.odin` uncompilable for the whole milestone. |

---

## Step 1 — Node domain, spans, dump (expressions and types)

`src/ast.odin`, `src/ast_dump.odin`, `src/parser.odin`.

- Collapse `Type_Syntax` into `Expr`. Keep `Expr_Error` and the existing
  error-node-instead-of-`nil` discipline. Keep `Expr_Base`'s checker annotations
  (`type`, `const_value`, `is_const`); they stay out of the dump.
- Add nodes for every literal kind (spelling only), unary and binary operators,
  the conditional and `or_else` forms, ranges, all postfix suffixes, composite
  literals and elements, arguments (positional, named, `inout`, `..` spread), and
  the type forms `^T`, `[^]T`, `[]T` / `[]mut T`, `[dynamic]T`, `[?]T`, `[N]T`,
  `map[K]V`, `distinct T`, `dyn I(...)`, `type`, `proc` types, `$T`, `$T: C`.
- **Span fix.** The parser tracks `last_consumed: Token`, updated in `advance`; a
  node's `hi` is `p.last_consumed.hi`, never the offending token's. Today
  `expect` returns the *unconsumed* offending token (`src/parser.odin:133`) and
  callers use it as the end token (`src/parser.odin:446`), so a declaration
  missing its `;` gets a span reaching into the next construct.
- **Depth cap.** A `depth` counter bounding *node nesting*, not parser recursion:
  the iterative loops for binary operators and postfix suffixes still build one
  node of depth per term, and every later phase walks the tree recursively. Past
  `MAX_NEST` emit one diagnostic, return an error node, and unwind. Without it
  `((((…` — or `1+1+1+…` — overflows the stack in the dump, and "never crashes"
  is unreachable. Measured ceiling on a 1 MB stack: 128.
- Store literal spelling only. Move the `int`-representability check out of
  `parse_int_text` (`src/parser.odin:745`, `L0218`) into the checker.
- Precedence exactly as grammar.md §Expressions: level 1 (`or_else`,
  `a if c else b`) associates **right**; level 2 (`..=`, `..<`) is
  **non-associative** — a second range operator is a diagnostic, not a nested
  range; levels 3–7 associate left; suffixes compose repeatedly.
- Extend `ast_dump` in lockstep. Deterministic, no addresses, no checker fields.

**Exit:** expression and type fixtures round-trip through `-dump-ast`; M0 tests green.

## Step 2 — Declarations, procedures, records, interfaces

- Variable and constant declarations, storage modifiers, `via`, `---`, and braced
  versus semicolon constant initializers.
- Every type form from step 1, generic parameters and arguments, `struct`,
  `enum`, `union`, `interface` bodies, requirements, `where` clauses.
- Procedure headers, definitions, declarations (`---`), groups, operator
  declarations and definitions, parameters, defaults, `inout`/`move` modes,
  variadics, and both result forms.
- `Constant_Decl` takes a single `Identifier` where `Variable_Decl` takes an
  `Identifier_List`, so `A, B :: 1;` needs a parse diagnostic — the shared
  name-list scan will otherwise accept it.

## Step 3 — Statements

Blocks; declarations; both `Assignment` forms; `if` / `for` / `foreach` with
`Init_Statement`; `when`; `defer`; `return` including `inout` values;
`break`/`continue`; value switches and type switches.

## Step 4 — Top-level items

Attributes; package clause; imports; foreign imports and blocks; `impl` and
`extend` with delegates; file-scope `when` and `Top_Level_Block`.

## Step 5 — Lexer completion

The audit is done: keywords, the operator table (including `&~=`, `..=`, `..<`,
`<<=`, `>>=`, `---`), escapes, hash names, nested comments, raw strings and
non-ASCII handling all match grammar.md. What is actually open:

- `0b12` lexes as `0b1` then `2` with **no diagnostic** (`src/lexer.odin:392`).
  After a base prefix, an ident-part character invalid for that base is an error.
- `1e` silently splits into `1` and identifier `e` (`src/lexer.odin:433`). An
  exponent marker with no digits is an error.
- `123abc` splits with no diagnostic. A number abutting an identifier start is an
  error.
- `\u` and `\U` escapes are not validated as Unicode scalars (surrogates,
  `> 10FFFF`).
- `token_display` (`src/lexer.odin:158`) has two identical branches — delete it.

Keep the `Error`-token-then-continue behaviour and the existing `L01xx` codes;
add new stable codes only for genuinely distinct failures.

---

## Resolved ambiguities — the exact lookaheads

Implement these verbatim; they are the checklist the ambiguity goldens test.

1. **Declaration vs simple statement** — optional attributes (skipped by matched
   parens), then `Ident ("," Ident)*` followed by `:`.
2. **Constant vs variable** — after the first `:`, a second `:` is a constant.
   `::` and `:=` are token pairs, so this is just the next token.
3. **Storage modifiers** — `static`, `thread_local` and `manual` (ordinary
   `Ident`s from the lexer) are modifiers only when followed by another modifier,
   a type-start token, or `=`. Otherwise they are type names.
4. **Constant body** — a type definition, interface, proc definition, proc group
   or brace-bodied operator definition ends at its outer `}` with no `;`, and a
   following `;` is a separate empty item. Everything else requires `;`, including
   a trailing composite literal.
5. **`via`** — exactly one `Unary_Expression`.
6. **Type switch** — parse the optional `Init_Statement` **first**, then
   `(Ident | "_")` followed by `in` selects a type switch. That is a two-token
   lookahead at a position reached only after an init statement, not a look at
   what follows `switch (`. Membership in a value switch needs `switch ((x in y))`.
7. **`delegate`** — contextual only at the start of an `impl`/`extend` member and
   followed by `(`.
8. **`slot`** — contextual only at the start of an interface requirement and
   followed by `Ident`, `:`, `proc`.
9. **Interface requirement** — a leading `(` opens `Bindings` when `Ident` and
   then `,` or `:` follow; a parenthesised expression requirement needs a second
   pair. Committing on the bare `(`, as this plan first said, leaves
   `((a + b).c()) -> T;` unspellable and contradicts grammar.md's own advice, so
   the three-token test is the rule and grammar.md now states it.
10. **`where` body brace** — a `no_composite_literal` parser flag, set for the
    clause's top level and cleared inside any `(`, `[` or argument list. This is
    the only place in the grammar where an expression abuts a body brace.
11. **Index vs slice** — after `[`: an optional expression, then `:` gives a slice
    with an optional second expression, `,` a multi-index, `]` a single index.
    Covers `[:]`, `[a:]`, `[:b]`.
12. **Generic application vs call** — one node either way, classified in M2. Bare
    names in generic and ordinary arguments stay unresolved; syntactically
    distinctive types parse immediately.
13. **`using`** — contextual at the start of a struct field. `self` needs no
    lookahead; it is an ordinary identifier.
14. **Composite literal at statement start** — `{` at statement position opens a
    block, so a typeless composite literal cannot begin an expression statement.
15. **Foreign block members** — parse with the same rule as `Constant_Decl`
    (brace-bodied members end at `}`, everything else needs `;`) rather than
    grammar.md's `Foreign_Decl`, which requires `;` unconditionally and so
    contradicts rule 4. The divergence is unobservable in valid code — a foreign
    procedure is always `---`-bodied — and "a foreign proc has no body" becomes a
    semantic rule. **Note it in grammar.md** as a wrinkle to fix.

---

## Diagnostics and recovery

- Delete `L0201 not supported in M0` from grammatical parsing. Parser diagnostics
  describe malformed syntax only.
- Preserve the existing `L02xx` codes for equivalent failures and allocate new
  ones by failure category. Codes are never renumbered or reused.
- Helpers: contextual-identifier matching, expected-token reporting,
  delimiter-aware synchronisation, token-set recovery, node-span extraction,
  contained-error detection.
- Recovery boundaries — top level: `;`, `}`, or a top-level starter; blocks: `;`,
  `}`, or a statement starter; switch bodies: `case` or `}`; lists: `,` or the
  matching close. Inner recovery never consumes an enclosing `}`. The existing
  `sync_to_boundary` (`src/parser.odin:204`) already tracks delimiter nesting —
  extend it rather than writing a second synchroniser.
- Suppress parser errors caused solely by an existing lexer `Error` token.
- Keep the progress guards on every repeating loop (`src/parser.odin:41`, `:526`).
- Located notes for unmatched delimiters, pointing at the opening token.

## Step 6 — M0 semantic compatibility

- Expand the dispatch in `src/check.odin` and `src/emit_llvm.odin` to the new
  unions. The checker's default arm reports `L0350` — "this construct is parsed
  but not yet compiled" — at the node's span and does not descend, so exactly one
  error is emitted per outer construct with no cascade. `emit_llvm`'s default arm
  is unreachable and asserts. `L0350` sits in the checker range (`L03xx`,
  currently through `L0325`); `L0299` would put a semantic diagnostic inside the
  parser's syntax-only block.
- Move integer representability from the parser to the checker (step 1). It
  renumbers from `L0218` to `L0351` with the move, for the same reason `L0350` is
  not `L0299`: `L02xx` is the parser's syntax-only block. Nothing referenced the
  old code.
- M0 semantics are otherwise unchanged: arithmetic, declarations, constants,
  scopes, `main`, `print_int`.
- Update `USAGE` in `src/main.odin:11` and `readme.md` to M1, documenting that the
  full syntax is available through `-parse-only` and `-dump-ast` while executable
  compilation still covers the M0 semantic subset.

## Step 7 — Tests

Corpora extending the harness shape already in `tests/corpus_test.odin`:

- `tests/syntax/*.loke` — valid syntax, run with `-parse-only`. Grouped by source
  items and attributes; declarations and types; records, interfaces, generics,
  procedures and operators; statements and both switch forms; expressions,
  suffixes, composites and argument forms. Each file's header comment names the
  productions it covers — that is how "every production parses" becomes checkable.
- For every file in that corpus assert zero diagnostics, tokens consumed through
  EOF, spans in bounds and monotonically nested, and a dump that completes.
- `tests/syntax/ambiguity/*.loke` + `.expected` — exact `-dump-ast` goldens for the
  fifteen rules above. Maintained by hand; add an update flag only if this set
  passes ~20 files.
- `tests/syntax_err/*.loke` + `.expected` — missing delimiters and semicolons,
  invalid lists, chained ranges, broken declarations, malformed control-flow
  headers, nested block errors. Every file ends with a valid sentinel construct
  and asserts it survives recovery.
- Extend the lexer goldens in `src/front_end_test.odin` to every token kind and
  the malformed-literal edges from step 5.
- Deterministic mutation fuzzing over the valid corpus: token deletion,
  duplication, substitution, delimiter imbalance. Assert termination, no panic,
  bounded spans and a dumpable AST; print the seed on failure.
- One explicit depth test: ~10k nested parentheses yields the nesting diagnostic,
  not a crash.
- Replace `tests/err/not_in_m0.*` with the `L0350` gate expectation.

The valid corpus, the goldens and the fuzzer run in-process in
`src/syntax_corpus_test.odin` rather than through `-parse-only`: spans and token
streams are what they assert and neither is visible from stdout. Only
`tests/syntax_err/` goes through the CLI harness, which already compares
diagnostics against `.expected` files. Node spans are asserted on the top-level
items rather than on every node — `ast_dump` is the one exhaustive walk over the
tree, and a second one written for the tests would need updating with every new
node kind.

---

## Verification

```bash
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
```

```bash
odin build src -out:lokec.exe
```

```bash
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
```

```bash
./lokec.exe examples/hello.loke -o hello.exe && ./hello.exe
```

Spot checks that the front end actually holds:

- A file using every grammar section parses clean under `-parse-only`.
- The same file with no flags reports `L0350` once per unsupported outer
  construct, not a cascade.
- A file with three separate syntax errors reports all three and still parses the
  construct after each.

## Deliberate shortcuts, and when they get paid

| Shortcut | Add when |
|---|---|
| Bare names and `Name(args)` left unclassified | M2 name resolution |
| No trivia or doc-comment attachment | A doc tool needs it |
| `MAX_NEST` fixed at 128, the depth the recursive checker and dump survive, rather than making those two iterative | A real program legitimately nests deeper |
| Ambiguity goldens maintained by hand | The set passes ~20 files |
| No name resolution, types, compile-time evaluation, package loading or codegen for newly parsed constructs | M2–M6, per `compiler-plan.md` |

## Assumptions

- `grammar.md` and `design.md` are normative; M1 does not redesign the language.
  The one exception is the `Foreign_Decl` semicolon wrinkle, recorded as a note.
- `parse(c, file, tokens) -> File`, `destroy_ast` and the existing CLI flags stay
  stable.
- No parser generator and no fuzzing framework: hand-written Odin, the existing
  per-file arena, the existing test infrastructure.
