# Releasing

## Version policy

`LOKE_VERSION` identifies a `MAJOR.MINOR.PATCH` release and the
[language specification](design.md) at its tag. Record spec changes in
[CHANGELOG.md](CHANGELOG.md).

Choose the version by the change to the language, library APIs, or command line:

| Change | Before 1.0 | From 1.0 |
| --- | --- | --- |
| Fixes only | Patch | Patch |
| Compatible additions | Minor | Minor |
| Intentional source incompatibility | Minor | Major |

A patch must preserve the meaning of correct programs. Fixing a spec divergence
may reject previously accepted code; include an upgrade note for that break.

These rules apply to every release:

- Keep `lokec.exe`, `loke-lsp.exe`, `base/`, `core/`, and `runtime/` from the
  same release. Do not mix compiled objects from different compiler releases.
- The [VS Code extension](editors/vscode/README.md) ships in the bundle but is
  not versioned with it: its `package.json` version stays `0.1.0`, which its
  install commands name.
- The platform C ABI is preserved. Generated code, non-C-ABI layout, runtime
  symbols, optimization results, diagnostic wording, and
  [inspection output](compiler-guide.md#inspecting-a-compilation) may change.
- Diagnostic codes retain their meaning and are never reused. A patch never
  turns a warning into an error.
- Compatibility covers behavior specified by [design.md](design.md) and
  [standard-library.md](standard-library.md); unspecified behavior is excluded.
- A change to any result of [`core:math/repro`](standard-library.md#coremathrepro)
  increments its `RESULTS_VERSION`, and a change to any value a seeded
  [`core:random`](standard-library.md#reproducibility) generator gives, a
  distribution's through `core:math/repro` included, increments
  `random.SEQUENCE_VERSION`, each in the commit that makes the change, with an
  upgrade note. A replay records both, so a release that changes neither
  replays the last one's recordings.

Only the latest release is supported; fixes ship as patches, with no backports.
The required Odin version is recorded in three places that change together:
[Building from source](readme.md#building-from-source), the Odin install step
of [ci.yml](.github/workflows/ci.yml), and the same step of
[release.yml](.github/workflows/release.yml).

## Upgrade notes

Every compatibility-breaking commit adds an entry under **Unreleased → Breaking
changes** in [CHANGELOG.md](CHANGELOG.md). Explain what stopped working and how
to update affected code, with a before/after example when needed. These entries
become the release's upgrade notes.

## Release checklist

1. Confirm `main` is green in CI and that the `## Gaps` section of
   [known-gaps.md](known-gaps.md) reads exactly `None.`; the release workflow
   checks that text and refuses anything else. Run
   `.\test-all.ps1 -Exhaustive` locally, about 25 minutes, which CI does not.
   Choose `X.Y.Z` using the [version policy](#version-policy).
2. Rename **Unreleased** in [CHANGELOG.md](CHANGELOG.md) to
   `[X.Y.Z] - YYYY-MM-DD`, add an empty **Unreleased** above it, and check the
   upgrade notes.
3. Update `LOKE_VERSION_STRING` in [src/build_config.odin](src/build_config.odin)
   and the `static_assert(LOKE_VERSION == ...)` in
   [src/front_end_test.odin](src/front_end_test.odin) to `X.Y.Z`.
4. Commit, push to `main`, and wait for CI. Its Performance summary compares
   the run with the latest release's `perf.json`. Slowdowns do not fail CI, so
   explain or fix any it shows before tagging.
5. Tag the tested commit with `git tag -a vX.Y.Z -m "Loke X.Y.Z"`, then
   `git push origin vX.Y.Z`.
6. Wait for the [Release workflow](.github/workflows/release.yml), then check
   the published notes, zip, and `perf.json` used as the next release's baseline.

If the workflow fails, check whether publication occurred. Before publication,
retry transient failures at the same tag. If the source needs fixing, update
`main`, repeat CI, then replace the local and remote tag with the tested commit.
**Never move a published tag**; corrections ship in a new patch release.
