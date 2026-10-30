[CmdletBinding()]
param(
    # The quick run is every check once, at the default optimization level. Full
    # adds what multiplies the cost: the whole corpus again at each -opt level,
    # the checker mutation fuzzer, and lokec and loke-lsp built optimized, as a
    # release is. CI runs it; use it locally for changes targeting that extra
    # coverage or to investigate a CI failure (AGENTS.md).
    [switch]$Full,
    # Turns the harness's tool skips into failures: nasm and a C host toolset are
    # not shipped here, and without this a machine missing one still runs green
    # with that coverage gone.
    [switch]$RequireTools,
    # Adds core:math/repro's exhaustive f32 comparison, every bit pattern through
    # each first approximation and the path behind it: about 25 minutes, so a
    # release step rather than CI's (releasing.md "Release checklist").
    [switch]$Exhaustive
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 turns each line a native command writes to stderr into
# an error record once this script's output is redirected (`*>`, `2>&1`, or a
# pipe into `Tee-Object`), and 'Stop' would end the run at odin's first
# `[INFO]` line. A tool's exit code alone decides whether it failed. PowerShell
# 7, which CI uses, passes stderr through untouched.
function Invoke-Native([string]$Failure, [scriptblock]$Command) {
    $ErrorActionPreference = 'Continue'
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Failure ($LASTEXITCODE)" }
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$savedFlags = [Environment]::GetEnvironmentVariable('LOKE_TEST_FLAGS', 'Process')
$savedRequireTools = [Environment]::GetEnvironmentVariable('LOKE_TEST_REQUIRE_TOOLS', 'Process')
$savedFull = [Environment]::GetEnvironmentVariable('LOKE_TEST_FULL', 'Process')
$savedExhaustive = [Environment]::GetEnvironmentVariable('LOKE_TEST_EXHAUSTIVE', 'Process')
if ($Full) {
    [Environment]::SetEnvironmentVariable('LOKE_TEST_FULL', '1', 'Process')
}
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

    # Nor does the checker reach into the backend: a helper both sides need
    # lives with its semantic owner. The driver and session API run the emitter.
    $emitter = Get-ChildItem src/emit_llvm*.odin | Where-Object { $_.Name -notlike '*_test.odin' }
    $emitterProcs = $emitter |
        Select-String -Pattern '^(\w+) :: (#force_inline )?proc' -CaseSensitive -Context 1, 0 |
        Where-Object { $_.Context.PreContext[0] -ne '@(private = "file")' } |
        ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
    $frontEnd = Get-ChildItem src/*.odin | Where-Object {
        $_.Name -notlike '*_test.odin' -and $_.Name -notlike 'emit_llvm*' -and $_.Name -notin @('main.odin', 'session.odin')
    }
    # A file-private procedure of the same name, such as the evaluator's
    # `bind_local`, is the front end's own.
    $frontProcs = $frontEnd | Select-String -Pattern '^(\w+) :: (#force_inline )?proc' -CaseSensitive |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
    $emitterProcs = $emitterProcs | Where-Object { $_ -cnotin $frontProcs }
    $reverse = $frontEnd |
        Select-String -Pattern "(?<![\w.])($($emitterProcs -join '|'))\(" -CaseSensitive |
        Where-Object { $_.Line -notmatch '^\s*//' }
    if ($reverse) {
        $reverse | ForEach-Object { Write-Host "$($_.Filename):$($_.LineNumber): $($_.Line.Trim())" }
        throw "front-end files call an emitter procedure"
    }

    # Whether a check's findings belong to the program is one question,
    # `committing` in source.odin; a raw depth test elsewhere is how an
    # enrollment used to slip through a probe (compiler-architecture.md
    # "Checking and overload resolution").
    $depth = Get-ChildItem src/*.odin |
        Where-Object { $_.Name -notlike '*_test.odin' -and $_.Name -ne 'source.odin' } |
        Select-String -Pattern '\bspeculation_depth\b' -CaseSensitive
    if ($depth) {
        $depth | ForEach-Object { Write-Host "$($_.Filename):$($_.LineNumber): $($_.Line.Trim())" }
        throw "speculation_depth is read outside source.odin; ask committing(c)"
    }

    # Memory tracking stays on here: the unit tests are where a leak in the
    # compiler shows up, and it costs a fraction of a second. Vet covers the test
    # code too; `-vet-packages` keeps it out of Odin's own `core:testing`.
    Invoke-Native 'compiler unit tests failed' { odin test src -vet-unused -vet-shadowing -vet-packages:lokec }

    # An unused local or a shadowed name is how a rename or a deleted branch goes
    # quiet instead of failing, so the shipped binary is built under both vets.
    # A release is optimized, which makes the compiler two to three times faster
    # but takes about a minute per binary to build, so the full gate, which
    # release.yml runs first, tests that build and the quick one Odin's default.
    $optimization = if ($Full) { '-o:speed' } else { '-o:minimal' }
    Invoke-Native 'compiler build failed' { odin build src -out:lokec.exe -vet-unused -vet-shadowing $optimization }

    # The language server compiles in the whole compiler, so it is rebuilt with
    # it; the integration harness talks to the binary over real pipes.
    Invoke-Native 'language server unit tests failed' { odin test lsp -vet-unused -vet-shadowing -vet-packages:lsp }
    Invoke-Native 'language server build failed' { odin build lsp -out:loke-lsp.exe -vet-unused -vet-shadowing $optimization }

    # This is also the example gate: every program under examples/ is
    # compiled from its real source here, and the ones with fixed output are
    # compared against it. They are the only corpus that doubles as documentation.
    [Environment]::SetEnvironmentVariable('LOKE_TEST_FLAGS', $null, 'Process')
    Invoke-Native 'baseline integration tests failed' {
        odin test tests -define:ODIN_TEST_TRACK_MEMORY=false `
            -vet-unused -vet-shadowing -vet-packages:tests
    }

    # Every test that compiles with LOKE_TEST_FLAGS reruns at each level: the
    # run/trap corpus, multi-package programs, the examples, the tutorials,
    # the floating-point cases rebuilt at each CPU level, core:math/repro's
    # probe, the dispatched procedures' copies, and their object code.
    $matrix = @(
        'programs_run', 'programs_trap', 'packages_run',
        'examples_compile_and_run', 'example_greeting_appends_to_its_file',
        'example_streaming_reads_its_input', 'example_dice_replays_its_seed',
        'tutorials_compile_and_run', 'cpu_levels_compute_what_baseline_does',
        'repro_functions_round_correctly', 'dispatched_procedures_compute_what_their_copies_do',
        'object_code_keeps_each_level_where_it_may_run'
    ) -join ','
    if ($Full) {
        foreach ($mode in @('minimal', 'size', 'speed', 'aggressive')) {
            Write-Host "Checking the optimization corpus at -opt=$mode"
            [Environment]::SetEnvironmentVariable('LOKE_TEST_FLAGS', "-opt=$mode", 'Process')
            Invoke-Native "optimization corpus failed at -opt=$mode" {
                odin test tests `
                    -define:ODIN_TEST_TRACK_MEMORY=false `
                    -define:ODIN_TEST_NAMES=$matrix
            }
        }
    }
    if ($Exhaustive) {
        Write-Host "Comparing core:math/repro's f32 first approximations exhaustively"
        [Environment]::SetEnvironmentVariable('LOKE_TEST_FLAGS', $null, 'Process')
        [Environment]::SetEnvironmentVariable('LOKE_TEST_EXHAUSTIVE', '1', 'Process')
        Invoke-Native 'exhaustive f32 comparison failed' {
            odin test tests `
                -define:ODIN_TEST_TRACK_MEMORY=false `
                -define:ODIN_TEST_NAMES=tests.repro_f32_first_approximations_agree_exhaustively
        }
    }
}
finally {
    [Environment]::SetEnvironmentVariable('LOKE_TEST_FLAGS', $savedFlags, 'Process')
    [Environment]::SetEnvironmentVariable('LOKE_TEST_REQUIRE_TOOLS', $savedRequireTools, 'Process')
    [Environment]::SetEnvironmentVariable('LOKE_TEST_FULL', $savedFull, 'Process')
    [Environment]::SetEnvironmentVariable('LOKE_TEST_EXHAUSTIVE', $savedExhaustive, 'Process')
    Pop-Location
}
