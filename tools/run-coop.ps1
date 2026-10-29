# Starts a relay, a host and a client from one build folder, and prints what to do next.
#
# Four live sessions in a row were launched by hand from a chat transcript: the flags drifted, one run
# used a port the relay was not on, and two runs shared a log name so their lines interleaved. Naming
# the run once here means the relay, both instances and every log file agree, and the next test is one
# command instead of a paragraph.
#
#   .\run-coop.ps1 -Name K2 -Port 8330 -Host Highland -Client Tester
#
# Each name must be unique per run because logs are appended.

param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$Port = 8330,
    [string]$HostName = "Highland",
    [string]$ClientName = "Tester",
    [int]$Seconds = 900,
    [string]$Stores = "coop\store",
    [switch]$NoClient,
    [switch]$MapLarge
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$out = Join-Path $root "build\out"
$exe = Join-Path $out "CityGameStudio64.exe"
$logDir = Join-Path $out "coop"
$server = Join-Path $root "server\coop_server.py"

if (-not (Test-Path $exe)) {
    throw "no game at $exe - build it first with build\build_mod.py"
}
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$shared = @(
    "--coop-port=$Port",
    "--coop-remote",
    "--coop-noautosave",
    "--coop-quit=$Seconds"
)
if ($MapLarge) { $shared += "--coop-map=4" }

# Only the host creates a game. A client's world comes from the host, and a client that runs the new-game
# dialogue ends up playing its own copy instead: in run K5 both sides entered selftest, and the client
# booted a local game at the same second the host did.
$hostArgs = @("--coop-host", "--coop-name=$HostName", "--coop-log=$Name-host", "--coop-selftest") + $shared
$clientArgs = @(
    "--coop-join=127.0.0.1", "--coop-autojoin", "--coop-company=new",
    "--coop-name=$ClientName", "--coop-log=$Name-client"
) + $shared

# The relay first: a client that starts before it retries, but a host that starts before it cannot
# register, and a run with no host looks exactly like a broken client.
$relayLog = Join-Path $logDir "$Name-relay.log"
# The relay appends so a restart keeps the run; a new run must not inherit the old one's lines.
Remove-Item $relayLog -ErrorAction SilentlyContinue
Remove-Item (Join-Path $logDir "$Name-host.log"), (Join-Path $logDir "$Name-client.log") -ErrorAction SilentlyContinue
$relay = Start-Process -FilePath "python" `
    -ArgumentList @($server, "--port", "$Port", "--log", $relayLog, "--stores", $Stores) `
    -WorkingDirectory $root -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 1

$hostProc = Start-Process -FilePath $exe -ArgumentList $hostArgs -WorkingDirectory $out -PassThru
$hostProc.Id | Set-Content (Join-Path $out "pid-$Name-host.txt")

# Wait for the host to actually be serving a world before starting the client.
#
# Every earlier session started both together, and whichever booted faster set the terms: a client that
# reached the new-game dialogue first played its own world and never joined. The client's own join retry
# makes a slow host harmless, but a host with no world yet is not something a client can wait out - the
# relay has no world to hand it and the client falls back to a local game.
$hostLog = Join-Path $logDir "$Name-host.log"
$deadline = (Get-Date).AddSeconds(120)
$ready = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path $hostLog) {
        if (Select-String -Path $hostLog -Pattern "selftest: ready|selftest: game state is loaded" -Quiet) {
            $ready = $true
            break
        }
    }
    Start-Sleep -Milliseconds 500
}
if (-not $ready) {
    Write-Warning "host did not report a served world within 120 s; starting the client anyway"
}

$clientProc = $null
if (-not $NoClient) {
    $clientProc = Start-Process -FilePath $exe -ArgumentList $clientArgs -WorkingDirectory $out -PassThru
}

$hostProc.Id | Set-Content (Join-Path $out "pid-$Name-host.txt")
if ($clientProc) { $clientProc.Id | Set-Content (Join-Path $out "pid-$Name-client.txt") }

$relay.Id | Set-Content (Join-Path $out "pid-$Name-relay.txt")

Write-Host "run $Name on port $Port"
Write-Host "  relay  pid $($relay.Id)   log $relayLog"
Write-Host "  host   pid $($hostProc.Id)   log $(Join-Path $logDir "$Name-host.log")"
if ($clientProc) {
    Write-Host "  client pid $($clientProc.Id)   log $(Join-Path $logDir "$Name-client.log")"
}
Write-Host ""
Write-Host "remote commands: append a numbered line to $logDir\remote-$Name-<role>.cmd"
Write-Host "stop everything:  Get-Content $out\pid-$Name-*.txt | ForEach-Object { Stop-Process -Id \$_ -Force -ErrorAction SilentlyContinue }"
