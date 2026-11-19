# Source review of doc.odin

Reviewed [doc.odin](../../src/doc.odin) at `ea622efe`. It builds one
package API model for the Markdown generator, interface-file writer and
editor documentation command. The separate output writers and formatter
pass serve distinct output requirements.

## Findings

1. **P2 · Public impl members disappear from the interface on some targets,
   lines 279–305 and 346–353.** The builder records private subjects by name
   across mutually exclusive branches, then relies on checked type information
   to recover methods of a public subject. In an untaken branch there is no
   checked type to inspect. Put private `Box :: struct {}` in
   `when (LOKE_DEBUG)`, and public `Box :: struct {}` and
   `impl Box { show :: proc(self) {} }` in its `else` in an
   `@(public)` package. The default interface contains `show` while the
   debug interface drops it. Put a private alias of a public type and its
   impl in the debug branch and the default interface omits the whole
   branch. The debug interface includes it.
   Resolve each impl's subject and any alias chain in its branch's
   declaration environment. Use the written environment for all branches
   when choosing which entries to emit. This also keeps references from
   reaching homonyms across exclusive branches.
   [Interface files](../compiler-guide.md#interface-files) ·
   [Private names in public declarations](../design.md#private-names-in-public-declarations)

2. **P2 · Escaped names cause required imports to vanish, lines 298–299,
   330–335 and 802–815.** In an `@(public)` package with a `dep`
   subpackage exporting `T`, use `import "./d\u0065p";` and
   `get :: proc() -> dep.T { return {}; }`. Checking succeeds.
   `-api` writes the qualified signature without its import and exits 0.
   The loader calculates the implicit binding from the decoded path, while
   the generator's helper uses the literal source bytes. Use the decoded
   binding calculation here for all imports, including unselected branches,
   and continue rendering the literal as written.
   [Loader binding](../../src/packages.odin#L332) ·
   [Pre-resolution binding helper](../../src/packages.odin#L423)

3. **P2 · Foreign calling-convention insertion reads comments as code,
   lines 483–496.** With a foreign block carrying
   `@(default_calling_convention="stdcall")`, a member
   `missing :: /** proc */ proc() -> i32 ---;` produces
   `missing :: /* proc "stdcall" */ proc() -> i32 ---;`.
   A member written `doubled :: proc /** explicit convention */ "c" () -> i32 ---;`
   makes `-api` fail with L0405. Both inputs check with L0260 for the
   unattached doc comment. A block without the attribute also loses its
   implicit `"c"` convention when its member is rendered as an ordinary
   declaration. Locate the actual procedure keyword and the next token
   with the lexer or parser spans. Provide the foreign block's effective
   default even if it has no attributes, using the same convention
   rule as the checker.
   [Foreign system](../design.md#foreign-system) ·
   [Foreign default](../../src/foreign.odin#L10) ·
   [Interface files](../compiler-guide.md#interface-files)

4. **P2 · Selectors of generic impl members lose private dependencies,
   lines 279–313 and 556–565.** In an `@(public)` package declare
   `Twin :: struct($A: type, $B: type) {}`,
   `Box :: struct($T: type) { v: T }`, and
   `impl Box($T) { @(private) Hidden :: type_of(T{}); }`.
   With `expose :: proc(x: $T) -> Twin(Box(T).Hidden, int) { return {}; }`,
   the interface renders the signature and omits `Hidden`. The unresolved
   selector fallback handles bare identifiers only. A concrete selection also
   fails with `impl Box(int) { Inner :: int; }`,
   `impl Box(string) { @(private) Inner :: int; }`, and
   `Closed :: Twin(Box(string).Inner, int);`, checking warns that `Closed`
   names private `Box.Inner` and the generator still omits that specialization.
   Follow selected instance symbols to the written member declaration. For
   unresolved selectors, look up the member in the applicable template
   or specialization of the receiver.
   [Private names in public declarations](../design.md#private-names-in-public-declarations) ·
   [Checker selector lookup](../../src/private_names.odin#L648)

5. **P3 · The reachability walk leaks shadowed private declarations,
   lines 572–575, 609–617 and 666–674.** Given both package-private
   `hidden :: proc(x: Secret) {}` and a private impl member
   `Public.hidden :: proc() {}`, placing a public `group :: proc{hidden};` in the same
   block reaches *both* procedures and the package procedure's private
   `Secret`. Use `group_member`'s block-first lookup, or the same rule on
   the branch's declarations when that branch was never checked. The walk
   also ignores interface requirement bindings. A private type `hidden`
   is shown solely because `Get :: interface($T: type) { (hidden: T)
   hidden.get() -> int; }` mentions the parameter. Scope the requirement
   bindings for its expressions and restore the scope between requirements.
   [Explicit procedure overloading](../design.md#explicit-procedure-overloading) ·
   [Group lookup](../../src/private_names.odin#L266) ·
   [Interface bodies](../design.md#interface-bodies)

6. **P3 · The Markdown page includes private names used only on another
   target, lines 268–274, 717–726 and 845–870.** With an unconditional
   private `Secret :: struct {}` and a public
   `get :: proc() -> Secret { return {}; }` present only under
   `when (LOKE_DEBUG)`, the default `-doc` page lists `Secret` with a note
   that a public declaration names it. The active API contains no such
   reference. Share the declaration model while taking the reference closure
   over the active branches for Markdown and over all branches for the
   interface file.
   [Interface files](../compiler-guide.md#interface-files)

7. **P3 · Newline normalization changes raw string values, lines 62–65
   and 121–126.** A public constant `TEXT` containing `left`, a physical
   CRLF, and `right` inside backticks satisfies
   `static_assert(TEXT == "left\r\nright");`. The generated interface
   contains a bare LF in that literal. The assertion fails when appended to
   a source copy of the interface. Preserve the value while normalizing
   generated layout. For example, render such raw tokens as ordinary strings
   with explicitly escaped newlines. The comparison should distinguish
   changes inside the string from checkout line endings outside it.
   [String and character literals](../design.md#string-and-character-literals) ·
   [Literal decoding](../../src/lexer.odin#L825)

## Simplification and boundaries

- The monotone private-declaration closure at lines 268–274 scans the entire
  tree again after each successful round. Reverse-ordered dependency chains
  can force quadratic work, with deeper branch trees adding repeated
  `shown_branches` traversals at lines 677–730. A branch-aware declaration
  index for finding 1 can also support a worklist keyed by declaration and
  activation of impl or branch ancestors. Keep output in its existing source
  order independently of visitation order.
- When rendering a struct at lines 447–451, select its public projection
  before calling `shown_text`. The discarded full declaration still
  allocates, and stripping any ordinary comments can set the file-wide
  damage flag from a private field that never reaches either output.
  Read the optional terminator adjacent to the declaration span.
- The checker and API model both reconstruct group and selector lookup.
  The shared traversal in `expr_children` already handles expression shape.
  Share declaration lookup or a written-declaration identity across those
  consumers while keeping their different rules for which dependencies to
  report. No unused production entry point surfaced.

## Verification

Focused `loke-source-review.exe <dir> -api` and `-doc` runs at
`ea622efe` reproduced all seven findings. The conditional interface
cases were run with and without `-debug`. The raw-string comparison
used the same compile-time assertion against the original and the
generated literal. No compiler source or checked-in tests changed.
