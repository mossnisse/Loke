[CmdletBinding()]
param(
    [switch]$SkipOptimizationMatrix
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$savedFlags = [Environment]::GetEnvironmentVariable('LOKE_TEST_FLAGS', 'Process')

Push-Location -LiteralPath $repoRoot
try {
    & odin test src -define:ODIN_TEST_TRACK_MEMORY=false
    if ($LASTEXITCODE -ne 0) { throw "compiler unit tests failed ($LASTEXITCODE)" }

    & odin build src -out:lokec.exe
    if ($LASTEXITCODE -ne 0) { throw "compiler build failed ($LASTEXITCODE)" }

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
