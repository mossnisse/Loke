[CmdletBinding()]
param(
    # The compiler to measure; by default the lokec.exe test-all.ps1 builds.
    [string]$Lokec,
    # The language server to measure; by default the loke-lsp.exe test-all.ps1
    # builds. Without one, only the compiler is measured.
    [string]$Lsp,
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
# .expected. bench/workspace, a program of several packages, is measured the
# same way, and loke-lsp is timed editing it: opening it, edits to its root
# package and to a library package, and completion while a statement is
# unfinished, each from the notification to the server's answer, and the
# server's peak working set. Timings are noisy on shared CI runners, so nothing
# here fails on a slower figure; a wrong output fails.

$ErrorActionPreference = 'Stop'
# The record reads the same on every machine: `12.5`, never `12,5`.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
# Windows PowerShell has no $PSScriptRoot yet where the parameters' defaults are.
if (-not $Lokec) { $Lokec = "$PSScriptRoot/lokec.exe" }
$Lokec = (Resolve-Path $Lokec).Path
if (-not $Lsp) { $Lsp = "$PSScriptRoot/loke-lsp.exe" }
$Lsp = if (Test-Path $Lsp) { (Resolve-Path $Lsp).Path }
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

# A loke-lsp process spoken to over its pipes, as an editor would.
function Start-Lsp {
    $info = New-Object Diagnostics.ProcessStartInfo $Lsp
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    # A byte order mark before the first header would end the conversation.
    $plain = New-Object Text.UTF8Encoding $false
    if ($info.PSObject.Properties['StandardInputEncoding']) {
        $info.StandardInputEncoding = $plain
        $process = [Diagnostics.Process]::Start($info)
    } else {
        # Windows PowerShell's .NET takes the encoding from the console's input.
        $saved = [Console]::InputEncoding
        [Console]::InputEncoding = $plain
        try { $process = [Diagnostics.Process]::Start($info) } finally { [Console]::InputEncoding = $saved }
    }
    [pscustomobject]@{
        Process = $process
        In      = $process.StandardInput.BaseStream
        Out     = $process.StandardOutput.BaseStream
        Buffer  = New-Object byte[] 65536
        Count   = 0
    }
}

function Send-Lsp($server, [hashtable]$message) {
    $message.jsonrpc = '2.0'
    $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $message -Depth 10 -Compress))
    $header = [Text.Encoding]::ASCII.GetBytes("Content-Length: $($body.Length)`r`n`r`n")
    $server.In.Write($header, 0, $header.Length)
    $server.In.Write($body, 0, $body.Length)
    $server.In.Flush()
}

# Messages the server sends until `$done` accepts one, which is returned. A
# server silent for a minute has failed.
function Wait-Lsp($server, [scriptblock]$done) {
    while ($true) {
        $head = [Text.Encoding]::ASCII.GetString($server.Buffer, 0, [math]::Min($server.Count, 256))
        $end = $head.IndexOf("`r`n`r`n")
        if ($end -ge 0) {
            $length = [int]($head.Substring(0, $end) -replace '(?s).*Content-Length:\s*(\d+).*', '$1')
            $total = $end + 4 + $length
            if ($server.Count -ge $total) {
                $message = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($server.Buffer, $end + 4, $length))
                [Array]::Copy($server.Buffer, $total, $server.Buffer, 0, $server.Count - $total)
                $server.Count -= $total
                if (& $done $message) { return $message }
                continue
            }
        }
        if ($server.Count -eq $server.Buffer.Length) {
            $larger = New-Object byte[] (2 * $server.Buffer.Length)
            [Array]::Copy($server.Buffer, $larger, $server.Count)
            $server.Buffer = $larger
        }
        $read = $server.Out.ReadAsync($server.Buffer, $server.Count, $server.Buffer.Length - $server.Count)
        if (-not $read.Wait(60000)) { throw 'loke-lsp sent nothing for a minute' }
        if ($read.Result -le 0) { throw 'loke-lsp closed its output' }
        $server.Count += $read.Result
    }
}

# A reply that reports an error, or whose result `$valid` rejects, fails the
# measurement instead of counting as a sample. `@($null).Count` is 1, so a
# check on items has to look at the items themselves.
function Assert-LspReply($reply, [string]$what, [scriptblock]$valid) {
    if ($null -ne $reply.error) { throw "loke-lsp answered $what with error $($reply.error.code): $($reply.error.message)" }
    if (-not (& $valid $reply.result)) { throw "loke-lsp answered $what without the expected result" }
}

function Get-Median([double[]]$values) {
    [math]::Round(($values | Sort-Object)[[math]::Floor($values.Count / 2)])
}

# The server editing bench/workspace. Every figure runs from sending the
# notification to receiving what it causes, so each includes the server's
# 150 ms pause for further edits; edits and completions are medians of ten.
function Measure-Lsp {
    $root = (Resolve-Path "$PSScriptRoot/bench/workspace").Path
    $mainUri = 'file:///' + ("$root/main.loke" -replace '\\', '/')
    $lexerUri = 'file:///' + ("$root/lexer/lexer.loke" -replace '\\', '/')
    $main = (Get-Content -Raw "$root/main.loke") -replace "`r`n", "`n"
    $lexer = (Get-Content -Raw "$root/lexer/lexer.loke") -replace "`r`n", "`n"
    $brokenMain = $main.Replace('report.print(summary, outcome);', 'report.print(summary, outcome, 1);')
    $brokenLexer = ([regex]'at := from;').Replace($lexer, 'at := from + true;', 1)
    $server = Start-Lsp
    try {
        Send-Lsp $server @{ id = 1; method = 'initialize'; params = @{ capabilities = @{} } }
        $reply = Wait-Lsp $server { param($m) $m.id -eq 1 }
        Assert-LspReply $reply 'initialize' { param($r) $null -ne $r.capabilities.completionProvider }
        Send-Lsp $server @{ method = 'initialized'; params = @{} }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Send-Lsp $server @{ method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $mainUri; languageId = 'loke'; version = 1; text = $main } } }
        Send-Lsp $server @{ id = 2; method = 'textDocument/documentSymbol'; params = @{ textDocument = @{ uri = $mainUri } } }
        $reply = Wait-Lsp $server { param($m) $m.id -eq 2 }
        $open = $clock.Elapsed.TotalMilliseconds
        $symbols = { param($r) @($r | Where-Object { $null -ne $_.name }).Count -gt 0 }
        Assert-LspReply $reply 'the document symbols of main.loke' $symbols
        Send-Lsp $server @{ method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $lexerUri; languageId = 'loke'; version = 1; text = $lexer } } }
        Send-Lsp $server @{ id = 3; method = 'textDocument/documentSymbol'; params = @{ textDocument = @{ uri = $lexerUri } } }
        $reply = Wait-Lsp $server { param($m) $m.id -eq 3 }
        Assert-LspReply $reply 'the document symbols of lexer.loke' $symbols

        # Each edit adds or removes an error, so each is answered by a publication.
        $versions = @{ $mainUri = 1; $lexerUri = 1 }
        $timeEdit = {
            param($uri, $text)
            $versions[$uri] += 1
            $version = $versions[$uri]
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Send-Lsp $server @{ method = 'textDocument/didChange'; params = @{ textDocument = @{ uri = $uri; version = $version }; contentChanges = @(@{ text = $text }) } }
            $null = Wait-Lsp $server { param($m) $m.method -eq 'textDocument/publishDiagnostics' -and $m.params.uri -eq $uri -and $m.params.version -eq $version }
            $clock.Elapsed.TotalMilliseconds
        }
        $edits = foreach ($i in 1..10) { & $timeEdit $mainUri $(if ($i % 2) { $brokenMain } else { $main }) }
        $libraryEdits = foreach ($i in 1..10) { & $timeEdit $lexerUri $(if ($i % 2) { $brokenLexer } else { $lexer }) }

        # Typing `report.` or `words.` on a line of its own, then asking.
        $at = $main.IndexOf("`tsummary :=")
        $line = ($main.Substring(0, $at) -split "`n").Count - 1
        $completions = foreach ($i in 1..10) {
            $operand = ('report', 'words')[$i % 2]
            $versions[$mainUri] += 1
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Send-Lsp $server @{ method = 'textDocument/didChange'; params = @{ textDocument = @{ uri = $mainUri; version = $versions[$mainUri] }; contentChanges = @(@{ text = $main.Insert($at, "`t$operand.`n") }) } }
            Send-Lsp $server @{ id = 100 + $i; method = 'textDocument/completion'; params = @{ textDocument = @{ uri = $mainUri }; position = @{ line = $line; character = $operand.Length + 2 } } }
            $reply = Wait-Lsp $server { param($m) $m.id -eq 100 + $i }
            $elapsed = $clock.Elapsed.TotalMilliseconds
            Assert-LspReply $reply "completion after ``$operand.``" { param($r) @($r.items | Where-Object { $null -ne $_.label }).Count -gt 0 }
            $elapsed
        }

        Send-Lsp $server @{ id = 4; method = 'shutdown' }
        $reply = Wait-Lsp $server { param($m) $m.id -eq 4 }
        Assert-LspReply $reply 'shutdown' { param($r) $null -eq $r }
        Send-Lsp $server @{ method = 'exit' }
        if (-not $server.Process.WaitForExit(30000)) { throw 'loke-lsp did not exit' }
        [pscustomobject][ordered]@{
            program         = 'bench/workspace (loke-lsp)'
            open_ms         = [math]::Round($open)
            edit_ms         = Get-Median $edits
            library_edit_ms = Get-Median $libraryEdits
            completion_ms   = Get-Median $completions
            server_peak_mb  = [math]::Round([LokePerfMemory]::PeakWorkingSet($server.Process.Handle) / 1MB, 1)
        }
    } finally {
        if (-not $server.Process.HasExited) { $server.Process.Kill() }
        $server.Process.Dispose()
    }
}

New-Item -ItemType Directory $work -Force | Out-Null
# A failed build, run, or output still removes the work directory, and only it.
try {
    $programs = @(Get-ChildItem "$PSScriptRoot/examples/*.loke") + @(Get-ChildItem "$PSScriptRoot/bench/*.loke") + @(Get-Item "$PSScriptRoot/bench/workspace")
    $records = foreach ($source in $programs) {
        $folder = Split-Path -Leaf (Split-Path -Parent $source.FullName)
        $name = "$folder/$($source.Name)"
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
        if ($folder -eq 'bench') {
            $run = Get-Fastest $exe @() $name
            # A package directory's expected output sits beside it.
            $expectedPath = if ($source.PSIsContainer) { "$($source.FullName).expected" } else { $source.FullName -replace '\.loke$', '.expected' }
            $expected = (Get-Content -Raw $expectedPath) -replace "`r`n", "`n"
            $actual = $run.Stdout -replace "`r`n", "`n"
            if ($actual -ne $expected) { throw "$name printed`n$actual`nbut bench expects`n$expected" }
            $record.run_ms = [math]::Round($run.Ms)
        }
        [pscustomobject]$record
    }
    if ($Lsp) {
        Write-Host 'Measuring bench/workspace in loke-lsp'
        $records = @($records) + @(Measure-Lsp)
    } else {
        Write-Warning 'No loke-lsp.exe to measure; build it or pass -Lsp'
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
# A Markdown table of the records with these columns, each figure followed by
# its change from the baseline.
function Format-Records([object[]]$rows, [string[]]$columns, [string]$header) {
    $lines = @($header, ('| --- |' + (' ---: |' * $columns.Count)))
    foreach ($record in $rows) {
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
}
$lines = Format-Records @($records | Where-Object { $null -eq $_.open_ms }) @('check_ms', 'build_ms', 'peak_mb', 'exe_kb', 'run_ms') `
    '| program | front end (ms) | build -opt=speed (ms) | lokec peak (MB) | exe (KB) | run (ms) |'
$servers = @($records | Where-Object { $null -ne $_.open_ms })
if ($servers.Count -gt 0) {
    $lines += ''
    $lines += Format-Records $servers @('open_ms', 'edit_ms', 'library_edit_ms', 'completion_ms', 'server_peak_mb') `
        '| language server | open (ms) | edit (ms) | library edit (ms) | completion (ms) | server peak (MB) |'
}
$lines
if ($env:GITHUB_STEP_SUMMARY) {
    @('## Performance', '') + $lines | Add-Content -Encoding utf8 $env:GITHUB_STEP_SUMMARY
}
