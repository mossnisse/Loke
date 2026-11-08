# Prints the Odin flag that stamps a build with the revision it comes from:
#     odin build src -out:lokec.exe (.\build-stamp.ps1)
# `lokec -version` reports the stamp (compiler-guide.md "Inspecting a
# compilation"). It is `git describe` output: `v0.9.0` at a release tag, and
# past one `v0.9.0-14-g01989c09`, with `-dirty` for uncommitted changes. A
# checkout with no release tag gets `g` and the commit, as describe writes it
# after a tag; an all-digit hash would otherwise reach Odin as an integer.
# Outside a git checkout it prints nothing, since Odin rejects an empty define,
# and the build reports itself unstamped.
$ErrorActionPreference = 'Continue'
$stamp = git -C $PSScriptRoot describe --tags --match 'v[0-9]*' --dirty --always 2>$null
if ($LASTEXITCODE -ne 0 -or -not $stamp) {
    $global:LASTEXITCODE = 0
    return
}
if ($stamp -notmatch '^v') { $stamp = "g$stamp" }
"-define:LOKE_BUILD=$stamp"
