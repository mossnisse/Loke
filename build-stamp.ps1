# Prints the Odin flag that stamps a build with the revision it comes from:
#     odin build src -out:lokec.exe (.\build-stamp.ps1)
# `lokec -version` reports the stamp (compiler-guide.md "Inspecting a
# compilation"). It is `git describe` output: `v0.9.0` at a release tag, and
# past one `v0.9.0-14-g01989c09`. A checkout with no release tag, such as a
# shallow clone, gets `g` and the commit, as describe writes it after a tag; an
# all-digit hash would otherwise reach Odin as an integer.
# `-dirty` marks uncommitted changes: describe's own check covers tracked files,
# and this adds any untracked file under src or lsp, which Odin compiles in all
# the same. Outside a git checkout it prints nothing, since Odin rejects an
# empty define, and the build reports itself unstamped.
$ErrorActionPreference = 'Continue'
$stamp = git -C $PSScriptRoot describe --tags --match 'v[0-9]*' --dirty --always 2>$null
if ($LASTEXITCODE -ne 0) { return }
if ($stamp -notmatch '^v') { $stamp = "g$stamp" }
if ($stamp -notmatch '-dirty$' -and (git -C $PSScriptRoot ls-files --others --exclude-standard -- src lsp)) {
    $stamp += '-dirty'
}
# A tag may hold characters that would need escaping in the LSP's JSON and the
# LLVM IR that carry the stamp.
$stamp = $stamp -replace '[^A-Za-z0-9._+-]', '_'
"-define:LOKEC_REVISION=$stamp"
