# Source comments cite the spec documents by section name, roughly 700 times. A
# renamed heading breaks every citation silently, so the convention is only
# worth having if it is checked. Exits non-zero and lists every citation with no
# matching heading.
#
# Matching is ordinal (case-sensitive) on purpose: a hashtable lookup ignores
# case, which let three citations drift to a lower-case spelling of a real
# heading and still pass.
[CmdletBinding()]
param([string[]]$Specs = @('design.md', 'standard-library-plan.md', 'compiler-architecture.md'))

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location -LiteralPath $repoRoot
try {
    $sources = Get-ChildItem -Recurse -File -Include *.odin, *.loke, *.c, *.h |
        Where-Object { $_.FullName -notlike '*\tests\tmp\*' }

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

        # `design.md "X"` and `standard-library-plan "X"` are both written, so
        # the extension is optional.
        $base = [regex]::Escape([System.IO.Path]::GetFileNameWithoutExtension($spec))
        $pattern = "$base(?:\.md)?\s+`"([^`"]+)`""

        foreach ($path in $texts.Keys) {
            $text = $texts[$path]
            foreach ($m in [regex]::Matches($text, $pattern)) {
                $checked++
                # A citation may wrap across comment lines; fold it back to one line.
                $name = [regex]::Replace($m.Groups[1].Value, '\s*(\r?\n)\s*(//|\*)?\s*', ' ').Trim()
                if (-not $headings.Contains($name)) {
                    $line = ($text.Substring(0, $m.Index) -split "`n").Count
                    $rel = $path.Substring($repoRoot.Length + 1)
                    $broken += "{0}:{1}: {2} `"{3}`" is not a heading" -f $rel, $line, $spec, $name
                }
            }
        }
    }

    if ($broken.Count -gt 0) {
        $broken | Sort-Object | ForEach-Object { Write-Host $_ }
        Write-Host "$($broken.Count) of $checked citation(s) name no heading"
        exit 1
    }
    Write-Host "$checked spec citations: all resolve"
}
finally { Pop-Location }
exit 0
