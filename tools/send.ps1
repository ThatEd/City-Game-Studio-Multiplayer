# Sends one command to a running co-op instance over the remote channel and waits for its answer.
#
#   .\send.ps1 -Run K6 -Role host -Command "state"
#
# Commands are appended, never rewritten: the mod remembers which lines it has already run, and appending
# keeps the file readable as a transcript of what was asked.

param(
    [Parameter(Mandatory = $true)][string]$Run,
    [Parameter(Mandatory = $true)][string]$Role,
    [Parameter(Mandatory = $true)][string]$Command,
    [int]$Timeout = 30
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$logDir = Join-Path $root "build\out\coop"
$cmdFile = Join-Path $logDir "remote-$Run-$Role.cmd"
$logFile = Join-Path $logDir "$Run-$Role.log"

if (-not (Test-Path $logFile)) {
    throw "no log at $logFile - is run $Run running?"
}

# Sequence numbers only need to be distinct; the mod remembers the line text.
$seq = 1
if (Test-Path $cmdFile) {
    $last = Get-Content $cmdFile |
        Where-Object { $_ -match '^\s*(\d+)\s' } |
        ForEach-Object { [int]($_.Trim() -split '\s+')[0] } |
        Measure-Object -Maximum
    if ($last.Count -gt 0) { $seq = [int]$last.Maximum + 1 }
}
Add-Content -Path $cmdFile -Value "$seq $Command" -Encoding ASCII

$before = (Get-Content $logFile | Measure-Object -Line).Lines
$deadline = (Get-Date).AddSeconds($Timeout)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    # Searched over the whole log, by sequence number, not only the lines written since the command was
    # queued. A fast answer can land between the queue and the first read, and a "lines since $before"
    # window then never finds it - which is exactly how a healthy client was reported as not answering.
    $lines = Get-Content $logFile
    $end = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match "remote: --- end of $seq\b") { $end = $i; break }
    }
    if ($end -lt 0) { continue }
    $start = -1
    for ($i = $end; $i -ge 0; $i--) {
        if ($lines[$i] -match "remote: --- ${seq}:") { $start = $i; break }
    }
    if ($start -lt 0) { continue }
    $lines[($start + 1)..($end - 1)] |
        Where-Object { $_ -match 'remote:     ' } |
        ForEach-Object { ($_ -replace '.*remote:\s{5}', '') }
    exit 0
}

Write-Host "no answer to [$Command] within $Timeout s"
exit 1
