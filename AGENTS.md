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
- If a PowerShell host reports odin's stderr as `NativeCommandError`, run the
  commands inside `test-all.ps1` one by one from a POSIX shell instead.
