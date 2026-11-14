package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Extract the real wrapper without running the gate or building its binaries.
@(private = "file")
GATE_WRAPPER :: `$ErrorActionPreference = 'Stop'; ` +
	`$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'test-all.ps1').Path, [ref]$null, [ref]$null); ` +
	`$wrapper = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Native' }, $true); ` +
	`. ([scriptblock]::Create($wrapper.Extent.Text)); `

// A launch failure must not inherit an earlier successful exit code. Stderr
// from a successful process still passes when redirected under PowerShell 5.
@(test)
gate_script_checks_native_outcomes :: proc(t: ^testing.T) {
	shells := make([dynamic]string, context.temp_allocator)
	append(&shells, "powershell.exe")
	probe, pwsh, probe_stderr, probe_err := exec(
		os.Process_Desc{command = []string{"powershell.exe", "-NoProfile", "-Command", `(Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source; exit 0`}},
		context.temp_allocator,
	)
	if !testing.expectf(t, probe_err == nil && probe.exit_code == 0, "cannot find PowerShell: %v\n%s", probe_err, string(probe_stderr)) {
		return
	}
	if path := strings.trim_space(string(pwsh)); path != "" {
		append(&shells, path)
	}
	cases := []struct { name, command: string, success: bool }{
		{"success", `Invoke-Native 'success' { cmd.exe /c 'exit 0' }`, true},
		{"stderr", `Invoke-Native 'stderr' { cmd.exe /c 'echo diagnostic 1>&2 & exit 0' } 2>&1 | Out-Null`, true},
		{"exit", `Invoke-Native 'exit' { cmd.exe /c 'exit 7' }`, false},
		{"launch", `Invoke-Native 'launch' { loke-test-no-such-command }`, false},
	}
	for shell in shells {
		for c in cases {
			script := fmt.tprintf("%s$global:LASTEXITCODE = 0; %s; Write-Output reached; exit 0", GATE_WRAPPER, c.command)
			state, stdout, stderr, err := exec(
				os.Process_Desc{command = []string{shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script}},
				context.temp_allocator,
			)
			testing.expectf(
				t, err == nil && (state.exit_code == 0) == c.success && strings.contains(string(stdout), "reached") == c.success,
				"%s Invoke-Native %s: exited %d (%v)\n%s%s", shell, c.name, state.exit_code, err, string(stdout), string(stderr),
			)
		}
	}
}

// Run both real unit-test command blocks against an isolated leaking package:
// tracking allocations alone logs a warning and exits zero, so the gate must
// explicitly make memory failures fatal.
@(test)
gate_script_rejects_unit_memory_leaks :: proc(t: ^testing.T) {
	script := GATE_WRAPPER + `
$odinPath = (Get-Command odin -CommandType Application -ErrorAction Stop).Source
$probeDir = Join-Path ([IO.Path]::GetTempPath()) ('loke-gate-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeDir | Out-Null
$probeSource = Join-Path $probeDir 'leak_test.odin'
$probeBinary = Join-Path $probeDir 'leak.exe'
try {
    $source = @'
package probe
import "core:testing"
@(test)
leaks :: proc(t: ^testing.T) {
    value := new(int)
    defer free(value)
    value^ = 42
    testing.expect(t, value^ == 42)
}
'@
    $units = $ast.FindAll({ param($n)
        $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Native' -and
        $n.CommandElements[1].Value -in 'compiler unit tests failed', 'language server unit tests failed'
    }, $true)
    if ($units.Count -ne 2) { throw 'did not find both unit-test commands' }
    foreach ($leaking in $false, $true) {
        Set-Content -LiteralPath $probeSource -Encoding UTF8 -Value $source
        foreach ($unit in $units) {
            $rejected = $false
            $probeOutput = New-Object 'Collections.Generic.List[object]'
            $command = $unit.Extent.Text.Replace('odin test src', '& $odinPath test $probeDir "-out:$probeBinary"').Replace('odin test lsp', '& $odinPath test $probeDir "-out:$probeBinary"')
            try { . ([scriptblock]::Create($command)) 2>&1 | ForEach-Object { $probeOutput.Add($_) } }
            catch { $rejected = $true }
            $report = $probeOutput -join [Environment]::NewLine
            if ($leaking) {
                if (-not $rejected -or $LASTEXITCODE -ne 1 -or $report -notmatch 'Memory failure in .*probe\.leaks') {
                    throw "unit-test gate did not reject a memory leak: $report"
                }
            } elseif ($rejected -or $LASTEXITCODE -ne 0) {
                throw "unit-test gate rejected a clean test: $report"
            }
        }
        $source = $source.Replace('    defer free(value)', '')
    }
    Write-Output rejected
} finally {
    Remove-Item -LiteralPath $probeSource, $probeBinary -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $probeDir -ErrorAction SilentlyContinue
}
`
	state, stdout, stderr, err := exec(
		os.Process_Desc{command = []string{"powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script}},
		context.temp_allocator,
	)
	testing.expectf(
		t, err == nil && state.exit_code == 0 && normalise(string(stdout)) == "rejected",
		"unit-test gate did not reject the leak: exited %d (%v)\n%s%s", state.exit_code, err, string(stdout), string(stderr),
	)
}
