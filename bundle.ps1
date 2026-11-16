# What a release zip holds, and a check that its documents' links to one
# another resolve inside it. release.yml stages the zip with this script and
# checks the installed bundle with it; test-all.ps1 checks a staging of the
# documents, so a link to a document the zip leaves out, such as a
# bench/.../README.md, fails CI on main rather than the release after tagging.
#
#   .\bundle.ps1                 stage the documents in a temporary directory and check them
#   .\bundle.ps1 -Out <dir>      stage the whole bundle in <dir>, binaries included, and check it
#   .\bundle.ps1 -Check <dir>    check an installed bundle
#
# Only links to `.md` files count: a document may link to a source file, such as
# ../src/checker.odin, which reads on GitHub and dangles harmlessly in the zip.
[CmdletBinding()]
param([string]$Out, [string]$Check)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# The bundle beside the two binaries: the root documents and LICENSE, and these
# trees. Without -Out only the documents are copied, which is all the check reads.
function Copy-Bundle([string]$Dest, [bool]$DocsOnly) {
    $trees = 'base', 'core', 'docs', 'editors', 'runtime', 'examples', 'tutorials'
    New-Item -ItemType Directory $Dest -Force | Out-Null
    Get-ChildItem -LiteralPath $repoRoot -File -Filter *.md | Copy-Item -Destination $Dest
    if ($DocsOnly) {
        foreach ($tree in $trees) {
            foreach ($doc in Get-ChildItem -LiteralPath (Join-Path $repoRoot $tree) -Recurse -File -Filter *.md) {
                $target = Join-Path $Dest ($doc.FullName.Substring($repoRoot.Length + 1))
                New-Item -ItemType Directory (Split-Path $target) -Force | Out-Null
                Copy-Item -LiteralPath $doc.FullName $target
            }
        }
    } else {
        Copy-Item (Join-Path $repoRoot 'lokec.exe'), (Join-Path $repoRoot 'loke-lsp.exe'), (Join-Path $repoRoot 'LICENSE') $Dest
        Copy-Item ($trees | ForEach-Object { Join-Path $repoRoot $_ }) $Dest -Recurse
        # A compile cache lokec rebuilds on demand, never shipped.
        Remove-Item (Join-Path $Dest 'runtime\prebuilt') -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Every relative link to a `.md` file, with or without an #anchor, must name a
# file inside $Root; a link with a scheme (https:) is not the bundle's.
function Test-Links([string]$Root) {
    $Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $missing = @()
    foreach ($doc in Get-ChildItem -LiteralPath $Root -Recurse -Filter *.md -File) {
        $links = [regex]::Matches((Get-Content -LiteralPath $doc.FullName -Raw), '\]\(([^)#]+\.md)(?:#[^)]*)?\)')
        foreach ($link in $links) {
            $target = $link.Groups[1].Value
            if ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $doc.DirectoryName $target) -PathType Leaf)) {
                $missing += "$($doc.FullName.Substring($Root.Length + 1)) links to $target"
            }
        }
    }
    if ($missing) {
        $missing | ForEach-Object { Write-Host $_ }
        throw "$($missing.Count) link(s) name a document the release bundle does not ship"
    }
}

if ($Check) {
    Test-Links $Check
} elseif ($Out) {
    Copy-Bundle $Out $false
    Test-Links $Out
} else {
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) "loke-bundle-$PID"
    try {
        Copy-Bundle $stage $true
        Test-Links $stage
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
