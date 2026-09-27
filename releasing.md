# Releasing

What a Loke version promises, where upgrade notes go, and how to cut a release.
[.github/workflows/release.yml](.github/workflows/release.yml) enforces the
parts a machine can check; this document is the rest.

## Version policy

A release is numbered `MAJOR.MINOR.PATCH` and is the value of `LOKE_VERSION`.
It versions the whole bundle: `lokec.exe` and the `base/`, `core/`, and
`runtime/` trees beside it are supported only as the matched set one release
ships, never mixed across releases.

The language version is separate. [design.md](design.md) specifies the v1
language, and every release implements the spec as of its own tag. A release
that changes the spec says so in its changelog section.

### Before 1.0

- **A minor release (`0.8.0`) may break source compatibility**: the language,
  the standard-library APIs, and the command line. Every break is listed with
  an upgrade note (see [Upgrade notes](#upgrade-notes)).
- **A patch release (`0.7.2`) only fixes**: compiler bugs, diagnostics,
  documentation, and runtime or library defects, with no intentional change to
  what a correct program means. Closing a spec divergence can reject a program
  the compiler wrongly accepted; that is a fix, and it is listed as a breaking
  change all the same.

### From 1.0

`1.0.0` is the first release whose language, standard-library APIs, and command
line stay source-compatible across minor releases. From then on only a major
release breaks them, and a minor release adds. What is not covered by the
promise:

- **Output of the compiler.** Generated code, object layout beyond the C ABI,
  runtime symbol names, and optimization results may change in any release.
  Objects built by different `lokec` releases are not linked together; the C
  ABI of `@(export)` and foreign declarations is the platform's and is kept.
- **Diagnostic text.** Messages may be reworded in any release. A diagnostic
  code (`L0001`…) keeps its meaning and is never reused for another one, and a
  warning never becomes an error in a patch release.
- **Inspection output.** What the options in [readme.md](readme.md)
  "Inspecting a compilation" print or write, such as `-dump-ast` trees and
  `-emit-ll` IR. The options themselves are kept.
- **Unspecified behavior.** Anything [design.md](design.md) and
  [standard-library.md](standard-library.md) do not specify.

### Supported releases

Only the latest release is supported. A fix ships as the next patch release;
nothing is backported. Each release records the Odin version that builds it
from source in [readme.md](readme.md) "Build and run".

## Upgrade notes

Upgrade notes live in [CHANGELOG.md](CHANGELOG.md), in a **Breaking changes**
subsection of the release that makes the change. Each entry names what stopped
working and how to change a program that relied on it, with a before and after
when the rewrite is not obvious. A commit that breaks compatibility adds its
entry under **Unreleased** in the same commit.

## Release checklist

1. `main` is green in CI, and [known-gaps.md](known-gaps.md) lists no gaps.
2. Choose the number by the [version policy](#version-policy): patch for fixes
   only, minor for anything else.
3. In [CHANGELOG.md](CHANGELOG.md), rename **Unreleased** to
   `[X.Y.Z] - YYYY-MM-DD`, add an empty **Unreleased** above it, and check that
   every breaking change has an upgrade note.
4. Set `LOKE_VERSION_STRING` in `src/build_config.odin`, and the
   `static_assert(LOKE_VERSION == ...)` in `src/front_end_test.odin` that pins
   it, to `X.Y.Z`.
5. Commit, push to `main`, and wait for CI.
6. Tag and push: `git tag -a vX.Y.Z -m "Loke X.Y.Z"`, then
   `git push origin vX.Y.Z`.
7. Watch the Release workflow. If it fails before publishing, fix the cause on
   `main`, delete the tag locally and on `origin`, and tag again. Once a release
   is published its tag never moves; a mistake ships as the next patch.
8. Open the release page and check the notes and the attached zip.
