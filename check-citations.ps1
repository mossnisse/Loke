# Source comments cite design.md by section name, roughly 500 times. A renamed
# heading breaks every citation silently, so the convention is only worth having
# if it is checked. Exits non-zero and lists every citation with no matching
# heading.
[CmdletBinding()]
param([string]$Spec = 'design.md')

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location -LiteralPath $repoRoot
try {
    $headings = @{}
    foreach ($line in Get-Content -LiteralPath $Spec) {
        if ($line -match '^#+\s+(.*?)\s*$') {
            $headings[$Matches[1]] = $true
            $headings[$Matches[1].Replace('`', '')] = $true
        }
    }

    $sources = Get-ChildItem -Recurse -File -Include *.odin, *.loke, *.c, *.h |
        Where-Object { $_.FullName -notlike '*\tests\tmp\*' }

    $broken = @()
    foreach ($file in $sources) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($null -eq $text) { continue }
        foreach ($m in [regex]::Matches($text, 'design\.md\s+"([^"]+)"')) {
            # A citation may wrap across comment lines; fold it back to one line.
            $name = [regex]::Replace($m.Groups[1].Value, '\s*(\r?\n)\s*(//|\*)?\s*', ' ').Trim()
            if (-not $headings.ContainsKey($name)) {
                $line = ($text.Substring(0, $m.Index) -split "`n").Count
                $rel = $file.FullName.Substring($repoRoot.Length + 1)
                $broken += "{0}:{1}: design.md `"{2}`" is not a heading" -f $rel, $line, $name
            }
        }
    }

    if ($broken.Count -gt 0) {
        $broken | Sort-Object | ForEach-Object { Write-Host $_ }
        Write-Host "$($broken.Count) design.md citation(s) name no heading"
        exit 1
    }
    Write-Host "design.md citations: all resolve"
}
finally { Pop-Location }
exit 0
