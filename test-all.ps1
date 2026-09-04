[CmdletBinding()]
param(
    [switch]$SkipOptimizationMatrix
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$savedFlags = [Environment]::GetEnvironmentVariable('LOKE_TEST_FLAGS', 'Process')

Push-Location -LiteralPath $repoRoot
try {
    # Cheapest check first: a renamed design.md heading breaks every comment that
    # cites it, and nothing else would notice.
    & "$repoRoot/check-citations.ps1"
    if ($LASTEXITCODE -ne 0) { throw "design.md citation check failed ($LASTEXITCODE)" }

    & odin test src -define:ODIN_TEST_TRACK_MEMORY=false
    if ($LASTEXITCODE -ne 0) { throw "compiler unit tests failed ($LASTEXITCODE)" }

    # An unused local or a shadowed name is how a rename or a deleted branch goes
    # quiet instead of failing, so the shipped binary is built under both vets.
    & odin build src -out:lokec.exe -vet-unused -vet-shadowing
    if ($LASTEXITCODE -ne 0) { throw "compiler build failed ($LASTEXITCODE)" }

    # This is also the example gate: the ten programs under examples/ are
    # compiled from their real sources here, and the ones with fixed output are
    # compared against it. They are the only corpus that doubles as documentation.
    [Environment]::SetEnvironmentVariable('LOKE_TEST_FLAGS', $null, 'Process')
    & odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
    if ($LASTEXITCODE -ne 0) { throw "baseline integration tests failed ($LASTEXITCODE)" }

    if (-not $SkipOptimizationMatrix) {
        foreach ($mode in @('minimal', 'size', 'speed', 'aggressive')) {
            Write-Host "Checking run/trap corpus at -opt=$mode"
            [Environment]::SetEnvironmentVariable('LOKE_TEST_FLAGS', "-opt=$mode", 'Process')
            & odin test tests `
                -define:ODIN_TEST_TRACK_MEMORY=false `
                -define:ODIN_TEST_NAMES=programs_run,programs_trap
            if ($LASTEXITCODE -ne 0) {
                throw "optimization corpus failed at -opt=$mode ($LASTEXITCODE)"
            }
        }
    }
}
finally {
    [Environment]::SetEnvironmentVariable('LOKE_TEST_FLAGS', $savedFlags, 'Process')
    Pop-Location
}
