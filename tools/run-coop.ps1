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
    [switch]$MapLarge,
    # -Lobby starts the client *without* deciding its company, so the lobby appears and a human (or
    # send.ps1) can press a row. -Company pre-decides, which is what an unattended run wants.
    [switch]$Lobby,
    [string]$Company = "new",
    # -Speed sets the game speed for both machines (1/2/4/6). -Verify seconds runs the in-game
    # assertion suite on each; -Map picks a map size (0..4, 4 is the huge one).
    [int]$Speed = 0,
    [int]$Verify = 0,
    [int]$MapSize = -1,
    # -DisconnectGrace seconds the client is given *after* the host quits, so the disconnect path (save,
    # hand-over, screen, return to the menu) can complete. See the note at $hostArgs.
    [int]$DisconnectGrace = 90
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
    "--coop-noautosave"
)
if ($MapLarge) { $shared += "--coop-map=4" }
if ($Speed -gt 0) { $shared += "--coop-speed=$Speed" }
if ($Verify -gt 0) { $shared += "--coop-verify=$Verify" }
if ($MapSize -ge 0) { $shared += "--coop-map=$MapSize" }

# Only the host creates a game. A client's world comes from the host, and a client that runs the new-game
# dialogue ends up playing its own copy instead: in run K5 both sides entered selftest, and the client
# booted a local game at the same second the host did.
#
# The two quit timers must NOT be the same. `--coop-quit` ends an instance's own process, and a run whose
# host and client both stop at second N never exercises the disconnect path at all: the client is killed
# at the same moment it is told the host is gone, mid-save. That is how run FIN finished - "company
# written", then `quit after 900 s`, with no menu line - which reads exactly like the dead-linger bug it
# had just been fixed for. The host stops first and the client is given a grace window on top, so the
# save, the hand-over, the disconnect screen and the return to the menu all have room to happen.
$hostArgs = @("--coop-host", "--coop-name=$HostName", "--coop-log=$Name-host", "--coop-selftest",
    "--coop-quit=$Seconds") + $shared
$clientArgs = @(
    "--coop-join=127.0.0.1", "--coop-autojoin",
    "--coop-name=$ClientName", "--coop-log=$Name-client",
    "--coop-quit=$($Seconds + $DisconnectGrace)"
) + $shared
if (-not $Lobby) {
    # An unattended run has nobody to press the lobby, so it is told its own answer up front.
    $clientArgs += "--coop-company=$Company"
}

# The relay first: a client that starts before it retries, but a host that starts before it cannot
# register, and a run with no host looks exactly like a broken client.
$relayLog = Join-Path $logDir "$Name-relay.log"
# The relay appends so a restart keeps the run; a new run must not inherit the old one's lines.
Remove-Item $relayLog -ErrorAction SilentlyContinue
Remove-Item (Join-Path $logDir "$Name-host.log"), (Join-Path $logDir "$Name-client.log") -ErrorAction SilentlyContinue
# stderr is captured, and the process is hidden, for the same reason as tools/run-three.ps1: started with
# its streams redirected, `print()` raises OSError(22) in this relay, and that exception used to leave
# serve_forever() and kill the relay mid-session while both games stayed healthy. The relay's own log()
# cannot raise any more, but a stray print elsewhere still could - so the output goes somewhere it can
# succeed, and the err file is what says why a relay died if one ever does.
$relayErr = Join-Path $logDir "$Name-relay.err.log"
Remove-Item $relayErr -ErrorAction SilentlyContinue
$relay = Start-Process -FilePath "python" `
    -ArgumentList @($server, "--port", "$Port", "--log", $relayLog, "--stores", $Stores) `
    -WorkingDirectory $root -PassThru -WindowStyle Hidden `
    -RedirectStandardError $relayErr
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
# A host loading at 6x takes longer to settle than at 1x, and a large map longer still: three minutes was
# observed. The wait is generous on purpose - a client that starts first gets its join_request answered by
# nobody, then sits in the menu while the host runs on, which looks like a broken lobby.
$deadline = (Get-Date).AddSeconds(360)
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
    Write-Warning "host did not report a served world within 360 s; starting the client anyway"
}
# Even once the host is ready it has to have registered with the relay, or the client's join_request is
# addressed to a host that is not there yet.
$relayLog0 = Join-Path $logDir "$Name-relay.log"
$rdl = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $rdl) {
    if ((Test-Path $relayLog0) -and (Select-String -Path $relayLog0 -Pattern "role host:" -Quiet)) { break }
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 3

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
