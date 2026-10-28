# Working in this repository

Loke is a programming language; `lokec` is its compiler, written in Odin.
[readme.md](readme.md) covers getting started;
[compiler-guide.md](compiler-guide.md) covers the command line. Keep this file
short: link to detailed guidance rather than repeat it.

## Which document decides

| Question | Authority |
| --- | --- |
| What the language means | [design.md](design.md) (normative) |
| What parses | [grammar.md](grammar.md) (normative) |
| How to use the compiler | [compiler-guide.md](compiler-guide.md) |
| Why a choice was made, differences from Odin | [comments.md](comments.md) |
| Open questions and unresolved findings | [open-questions.md](open-questions.md) |
| How the compiler is built, and how to change it | [compiler-architecture.md](compiler-architecture.md) |
| Where the compiler disagrees with the spec | [known-gaps.md](known-gaps.md) |
| Standard library design and APIs | [standard-library.md](standard-library.md) |
| Later work | [future-plans.md](future-plans.md) |
| What each release changed | [CHANGELOG.md](CHANGELOG.md) |
| What a version promises, and how to release | [releasing.md](releasing.md) |

When the compiler and `design.md` or `grammar.md` disagree, the spec wins unless
the spec is being deliberately changed. Record an unfixed divergence in
`known-gaps.md` with a minimal reproduction; never reword the spec to match a
bug.

## Rules

- For behavior changes, update the affected specification, implementation,
  tests, and citing comments in the same commit.
- Source comments cite spec sections by exact heading: `design.md "Maps"`.
  Renaming a heading is an interface change; `check-citations.ps1` finds the
  citations it breaks.
- Rationale belongs in `comments.md` and open questions in `open-questions.md`,
  not in normative text.
- A user-visible change adds a line under **Unreleased** in `CHANGELOG.md` in
  the same commit, and a breaking one also adds an upgrade note there
  (see [Upgrade notes](releasing.md#upgrade-notes)).
- Findings from a review or audit end up in the repository: fixed ones in the
  commit message, open ones in `known-gaps.md` or `open-questions.md`. Add a
  regression test for a behavior fix; validate editorial fixes with relevant
  documentation checks. Agent memory is not project documentation.
- In repository documents, link files by relative path and heading anchor.
- To use a bundled package, read its `api.loki`; read its source only to
  change it. After changing a package's public API or doc comments, run
  `lokec <dir> -api` and commit the regenerated file
  (see [Interface files](compiler-guide.md#interface-files)).

## Testing

- For code changes, run the affected suite or `.\test-all.ps1`, the quick gate.
  Unit tests live in `src` and `lsp`; integration tests live in `tests`.
  Rebuild `lokec.exe` and `loke-lsp.exe` before direct integration runs after
  compiler changes.
- For documentation-only changes, check links by hand (no script checks them),
  run `check-citations.ps1`, and run any affected examples or tutorial tests. A
  full compiler gate is unnecessary.
- Run `.\test-all.ps1 -Full` locally only for changes targeting its additional
  coverage (optimization levels and the mutation fuzzer), or to investigate a
  CI failure. CI runs `-Full -RequireTools` on pushes to `main` and pull requests.
- Wait for tools and test suites to finish; do not poll them.

See [Testing and verification](compiler-architecture.md#testing-and-verification)
for commands, individual test selection, and troubleshooting. For performance
changes, measure before and after with `perf.ps1` as described there.
