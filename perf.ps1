[CmdletBinding()]
param(
    # The compiler to measure; by default the lokec.exe test-all.ps1 builds.
    [string]$Lokec,
    # Where to write the record as JSON, for a later -Baseline.
    [string]$Out,
    # An earlier record: each figure is shown with its change from it.
    [string]$Baseline,
    # Timings are the fastest of this many runs. `1..0` would be two runs, so
    # fewer than one is refused.
    [ValidateRange(1, 2147483647)]
    [int]$Repeat = 3
)

# Records what later changes to the compiler are compared against
# (future-plans.md "Ongoing quality engineering"): for every example and
# benchmark, the front end's time (`-emit-ll`, no clang), the whole build's time
# at -opt=speed, lokec's peak working set, and the executable's size; for each
# benchmark in bench/, also its run time, after its output matches its
# .expected. Timings are noisy on shared CI runners, so nothing here fails on a
# slower figure; a wrong output fails.

$ErrorActionPreference = 'Stop'
# The record reads the same on every machine: `12.5`, never `12,5`.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
# Windows PowerShell has no $PSScriptRoot yet where the parameters' defaults are.
if (-not $Lokec) { $Lokec = "$PSScriptRoot/lokec.exe" }
$Lokec = (Resolve-Path $Lokec).Path
$work = Join-Path ([IO.Path]::GetTempPath()) "loke-perf-$PID"

# A process's peak working set is readable after it exits, through the handle
# .NET keeps open, but Process.PeakWorkingSet64 is not.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LokePerfMemory {
    [StructLayout(LayoutKind.Sequential)]
    struct Counters {
        public uint cb, PageFaultCount;
        public UIntPtr PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage,
            QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage,
            PagefileUsage, PeakPagefileUsage;
    }
    [DllImport("psapi.dll", SetLastError = true)]
    static extern bool GetProcessMemoryInfo(IntPtr process, out Counters counters, uint size);
    public static ulong PeakWorkingSet(IntPtr process) {
        Counters counters;
        if (!GetProcessMemoryInfo(process, out counters, (uint)Marshal.SizeOf(typeof(Counters))))
            throw new System.ComponentModel.Win32Exception();
        return counters.PeakWorkingSetSize.ToUInt64();
    }
}
'@

# Runs a program to completion: its exit code, stdout, stderr, wall time in
# milliseconds, and peak working set in bytes.
function Invoke-Measured([string]$exe, [string[]]$arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo $exe
    $info.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($info)
    $stderr = $process.StandardError.ReadToEndAsync()
    $stdout = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    $clock.Stop()
    $result = [pscustomobject]@{
        Code   = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr.Result
        Ms     = $clock.Elapsed.TotalMilliseconds
        Peak   = [LokePerfMemory]::PeakWorkingSet($process.Handle)
    }
    $process.Dispose()
    $result
}

function Get-Fastest([string]$exe, [string[]]$arguments, [string]$what) {
    $runs = foreach ($i in 1..$Repeat) {
        $run = Invoke-Measured $exe $arguments
        if ($run.Code -ne 0) { throw "$what exited with $($run.Code)`n$($run.Stdout)$($run.Stderr)" }
        $run
    }
    $runs | Sort-Object Ms | Select-Object -First 1
}

New-Item -ItemType Directory $work -Force | Out-Null
# A failed build, run, or output still removes the work directory, and only it.
try {
    $programs = @(Get-ChildItem "$PSScriptRoot/examples/*.loke") + @(Get-ChildItem "$PSScriptRoot/bench/*.loke")
    $records = foreach ($source in $programs) {
        $name = "$($source.Directory.Name)/$($source.Name)"
        Write-Host "Measuring $name"
        $check = Get-Fastest $Lokec @('-emit-ll', $source.FullName, '-o', "$work/out.ll") "lokec -emit-ll $name"
        $exe = "$work/$($source.BaseName).exe"
        $build = Get-Fastest $Lokec @('-opt=speed', $source.FullName, '-o', $exe) "lokec -opt=speed $name"
        $record = [ordered]@{
            program  = $name
            check_ms = [math]::Round($check.Ms)
            build_ms = [math]::Round($build.Ms)
            peak_mb  = [math]::Round(($check.Peak, $build.Peak | Measure-Object -Maximum).Maximum / 1MB, 1)
            exe_kb   = [math]::Round((Get-Item $exe).Length / 1KB)
            run_ms   = $null
        }
        if ($source.Directory.Name -eq 'bench') {
            $run = Get-Fastest $exe @() $name
            $expected = (Get-Content -Raw ($source.FullName -replace '\.loke$', '.expected')) -replace "`r`n", "`n"
            $actual = $run.Stdout -replace "`r`n", "`n"
            if ($actual -ne $expected) { throw "$name printed`n$actual`nbut bench expects`n$expected" }
            $record.run_ms = [math]::Round($run.Ms)
        }
        [pscustomobject]$record
    }
} finally {
    if ((Split-Path -Leaf $work) -eq "loke-perf-$PID" -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

if ($Out) { ConvertTo-Json @($records) | Set-Content -Encoding utf8 $Out }

$before = @{}
if ($Baseline) {
    foreach ($old in (Get-Content -Raw $Baseline | ConvertFrom-Json)) { $before[$old.program] = $old }
}
$columns = 'check_ms', 'build_ms', 'peak_mb', 'exe_kb', 'run_ms'
$lines = @(
    '| program | front end (ms) | build -opt=speed (ms) | lokec peak (MB) | exe (KB) | run (ms) |',
    '| --- | ---: | ---: | ---: | ---: | ---: |'
)
foreach ($record in $records) {
    $cells = foreach ($column in $columns) {
        $value = $record.$column
        $old = if ($before.ContainsKey($record.program)) { $before[$record.program].$column }
        if ($null -eq $value) { '' }
        elseif ($old) { '{0} ({1:+0;-0;0}%)' -f $value, (100 * ($value - $old) / $old) }
        else { "$value" }
    }
    $lines += "| $($record.program) | $($cells -join ' | ') |"
}
$lines
if ($env:GITHUB_STEP_SUMMARY) {
    @('## Performance', '') + $lines | Add-Content -Encoding utf8 $env:GITHUB_STEP_SUMMARY
}
