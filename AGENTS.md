# Working in this repository

Loke is a programming language; `lokec` is its compiler, written in Odin.
[readme.md](readme.md) covers building, running, and the command line. This file
tells agents (and humans) where each kind of knowledge lives and how to keep it
true. Keep it short: point to a document rather than repeat it.

## Which document decides

| Question | Authority |
| --- | --- |
| What the language means | [design.md](design.md) (normative) |
| What parses | [grammar.md](grammar.md) (normative) |
| Why a choice was made, open questions, differences from Odin | [comments.md](comments.md) |
| How the compiler is built, and how to change it | [compiler-architecture.md](compiler-architecture.md) |
| Where the compiler disagrees with the spec | [known-gaps.md](known-gaps.md) |
| Standard library design and APIs | [standard-library.md](standard-library.md) |
| Later work | [future-plans.md](future-plans.md) |
| What each release changed | [CHANGELOG.md](CHANGELOG.md) |
| What a version promises, and how to release | [releasing.md](releasing.md) |

When the compiler and `design.md` disagree, the spec wins unless the spec is
being deliberately changed. Record an unfixed divergence in `known-gaps.md` with
a minimal reproduction; never reword the spec to match a bug.

## Rules

- Change the spec, the implementation, the tests, and any comment citing the
  changed section in the same commit.
- Source comments cite spec sections by exact heading: `design.md "Maps"`.
  Renaming a heading is an interface change; `check-citations.ps1` finds the
  citations it breaks.
- Rationale belongs in `comments.md`, not in normative text.
- A user-visible change adds a line under **Unreleased** in `CHANGELOG.md` in
  the same commit, and a breaking one also adds an upgrade note there
  (`releasing.md` "Upgrade notes").
- Findings from a review or audit end up in the repository: fixed ones in the
  commit message and a regression test, open ones in `known-gaps.md` or
  `comments.md`. Agent memory is not project documentation.
- Link repository files by relative path and heading, not by absolute path or
  line number.

## Testing

`.\test-all.ps1` is the gate; `-SkipOptimizationMatrix` is the quick version.
[compiler-architecture.md](compiler-architecture.md) "Testing and verification"
lists the suites. Useful while iterating:

- Rerun one test alone before believing a failure:
  `odin test tests -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_NAMES=<name>`.
- `LOKE_TEST_FLAGS="-opt=speed"` passes flags to every run/trap/pkg compile in
  the corpus; output must match at every `-opt` level.
- The pages in `tutorials/` are tests too: rewording a diagnostic or changing
  what a program prints can fail `tutorials_compile_and_run`, which names the
  page and the block to update.
- For a change meant to be faster: `.\perf.ps1 -Out before.json` first, then
  `.\perf.ps1 -Baseline before.json` after rebuilding `lokec.exe`.
- If a PowerShell host reports odin's stderr as `NativeCommandError`, run the
  commands inside `test-all.ps1` one by one from a POSIX shell instead.
