# Source comments cite the spec documents by section name, roughly 700 times. A
# renamed heading breaks every citation silently, so the convention is only
# worth having if it is checked. Exits non-zero and lists every citation with no
# matching heading, and every citation in a doc comment of a bundled package.
#
# Matching is ordinal (case-sensitive) on purpose: a hashtable lookup ignores
# case, which let three citations drift to a lower-case spelling of a real
# heading and still pass.
[CmdletBinding()]
param([string[]]$Specs = @('design.md', 'standard-library.md', 'compiler-architecture.md'))

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location -LiteralPath $repoRoot
try {
    # The tutorials link to the sections they teach from as `design.md "X"`.
    $sources = @(Get-ChildItem -Recurse -File -Include *.odin, *.loke, *.c, *.h |
        Where-Object { $_.FullName -notlike '*\tests\tmp\*' }) +
        @(Get-ChildItem -File tutorials/*.md)

    $texts = @{}
    foreach ($file in $sources) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($null -ne $text) { $texts[$file.FullName] = $text }
    }

    $broken = @()
    $checked = 0
    foreach ($spec in $Specs) {
        $headings = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal)
        foreach ($line in Get-Content -LiteralPath $spec) {
            if ($line -match '^#+\s+(.*?)\s*$') {
                [void]$headings.Add($Matches[1])
                [void]$headings.Add($Matches[1].Replace('`', ''))
            }
        }

        # `design.md "X"` and `standard-library "X"` are both written, so
        # the extension is optional. The name may wrap onto the next comment
        # line before its opening quote.
        $base = [regex]::Escape([System.IO.Path]::GetFileNameWithoutExtension($spec))
        $pattern = "$base(?:\.md)?\s+(?:(?:///?|\*)\s*)?`"([^`"]+)`""

        foreach ($path in $texts.Keys) {
            $text = $texts[$path]
            $rel = $path.Substring($repoRoot.Length + 1)
            foreach ($m in [regex]::Matches($text, $pattern)) {
                $checked++
                $line = ($text.Substring(0, $m.Index) -split "`n").Count
                # A citation may wrap across comment lines; fold it back to one line.
                $name = [regex]::Replace($m.Groups[1].Value, '\s*(\r?\n)\s*(///?|\*)?\s*', ' ').Trim()
                if (-not $headings.Contains($name)) {
                    $broken += "{0}:{1}: {2} `"{3}`" is not a heading" -f $rel, $line, $spec, $name
                }
                # design.md "Doc comments": a bundled package's doc comments are
                # for its users, and a spec citation is for its maintainers.
                $start = $text.LastIndexOf("`n", $m.Index) + 1
                if ($rel -match '^(core|base)\\' -and $text.Substring($start).TrimStart().StartsWith('///') -and
                    -not $text.Substring($start).TrimStart().StartsWith('////')) {
                    $broken += "{0}:{1}: {2} `"{3}`" is cited in a doc comment; cite it in a // comment" -f $rel, $line, $spec, $name
                }
            }
        }
    }

    if ($broken.Count -gt 0) {
        $broken | Sort-Object | ForEach-Object { Write-Host $_ }
        Write-Host "$($broken.Count) problem(s) in $checked citation(s)"
        exit 1
    }
    Write-Host "$checked spec citations: all resolve"
}
finally { Pop-Location }
exit 0
