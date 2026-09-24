[CmdletBinding()]
param(
    [switch]$SkipOptimizationMatrix,
    # Turns the harness's tool skips into failures: nasm and a C host toolset are
    # not shipped here, and without this a machine missing one still runs green
    # with that coverage gone.
    [switch]$RequireTools
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$savedFlags = [Environment]::GetEnvironmentVariable('LOKE_TEST_FLAGS', 'Process')
$savedRequireTools = [Environment]::GetEnvironmentVariable('LOKE_TEST_REQUIRE_TOOLS', 'Process')
if ($RequireTools) {
    [Environment]::SetEnvironmentVariable('LOKE_TEST_REQUIRE_TOOLS', '1', 'Process')
}

Push-Location -LiteralPath $repoRoot
try {
    # Cheapest check first: a renamed design.md heading breaks every comment that
    # cites it, and nothing else would notice.
    & "$repoRoot/check-citations.ps1"
    if ($LASTEXITCODE -ne 0) { throw "spec citation check failed ($LASTEXITCODE)" }

    # The backend consumes a checked compilation and never reaches back into the
    # checker; nothing else stops a convenient `^Checker` from creeping in.
    $layering = Get-ChildItem src/emit_llvm*.odin, src/emission_contract.odin |
        Where-Object { $_.Name -notlike '*_test.odin' } |
        Select-String -Pattern '\bChecker\b' -CaseSensitive
    if ($layering) {
        $layering | ForEach-Object { Write-Host "$($_.Filename):$($_.LineNumber): $($_.Line.Trim())" }
        throw "backend files name the checker's ``Checker``"
    }

    # Memory tracking stays on here: the unit tests are where a leak in the
    # compiler shows up, and it costs a fraction of a second. Vet covers the test
    # code too; `-vet-packages` keeps it out of Odin's own `core:testing`.
    & odin test src -vet-unused -vet-shadowing -vet-packages:lokec
    if ($LASTEXITCODE -ne 0) { throw "compiler unit tests failed ($LASTEXITCODE)" }

    # An unused local or a shadowed name is how a rename or a deleted branch goes
    # quiet instead of failing, so the shipped binary is built under both vets.
    & odin build src -out:lokec.exe -vet-unused -vet-shadowing
    if ($LASTEXITCODE -ne 0) { throw "compiler build failed ($LASTEXITCODE)" }

    # This is also the example gate: every program under examples/ is
    # compiled from its real source here, and the ones with fixed output are
    # compared against it. They are the only corpus that doubles as documentation.
    [Environment]::SetEnvironmentVariable('LOKE_TEST_FLAGS', $null, 'Process')
    & odin test tests -define:ODIN_TEST_TRACK_MEMORY=false `
        -vet-unused -vet-shadowing -vet-packages:tests
    if ($LASTEXITCODE -ne 0) { throw "baseline integration tests failed ($LASTEXITCODE)" }

    # Every test that compiles with LOKE_TEST_FLAGS reruns at each level: the
    # run/trap corpus, multi-package programs, and the examples.
    $matrix = @(
        'programs_run', 'programs_trap', 'packages_run',
        'examples_compile_and_run', 'example_greeting_appends_to_its_file',
        'example_streaming_reads_its_input'
    ) -join ','
    if (-not $SkipOptimizationMatrix) {
        foreach ($mode in @('minimal', 'size', 'speed', 'aggressive')) {
            Write-Host "Checking the optimization corpus at -opt=$mode"
            [Environment]::SetEnvironmentVariable('LOKE_TEST_FLAGS', "-opt=$mode", 'Process')
            & odin test tests `
                -define:ODIN_TEST_TRACK_MEMORY=false `
                -define:ODIN_TEST_NAMES=$matrix
            if ($LASTEXITCODE -ne 0) {
                throw "optimization corpus failed at -opt=$mode ($LASTEXITCODE)"
            }
        }
    }
}
finally {
    [Environment]::SetEnvironmentVariable('LOKE_TEST_FLAGS', $savedFlags, 'Process')
    [Environment]::SetEnvironmentVariable('LOKE_TEST_REQUIRE_TOOLS', $savedRequireTools, 'Process')
    Pop-Location
}
