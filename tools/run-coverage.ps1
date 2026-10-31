# Launches a run whose purpose is coverage: every optional channel the mod has is turned on at once,
# so the message kinds that only appear on an optional path are put on the wire.
#
# run-coop.ps1 deliberately exposes only the flags an ordinary session needs. A coverage run is not an
# ordinary session: it asks for ping, a trade, and an explicit lobby pick, and it must not start the
# client until the host is serving a world.
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$Port = 8360,
    [int]$Seconds = 420,
    [int]$DisconnectGrace = 90,
    [int]$Speed = 4,
    [int]$Verify = 120,
    [string]$Gift = "money:20000",
    [switch]$TraceSteps,
    # --coop-buytest=<player id> makes the buying machine try to acquire that player's whole company,
    # which is the only path that produces the `acquired` message.
    [string]$BuyTest = "",
    # --coop-play=<seconds> is the two-bot run; it is the only thing that produces a `digest`.
    [int]$Play = 0,
    # Release and publish finished projects. Off by default in the mod because publishing changes the
    # game list on the wire and something in the rival-game path used to crash this build at 0xae5633 -
    # which the overshoot discard fixed. This switch is what exercises a real release.
    [switch]$PlayRelease
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $root
$out = Join-Path $root "build\out"
$exe = Join-Path $out "CityGameStudio64.exe"
$logDir = Join-Path $out "coop"
$server = Join-Path $root "server\coop_server.py"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$relayLog = Join-Path $logDir "$Name-relay.log"
Remove-Item $relayLog -ErrorAction SilentlyContinue
Remove-Item (Join-Path $logDir "$Name-host.log"), (Join-Path $logDir "$Name-client.log") -ErrorAction SilentlyContinue

$relay = Start-Process -FilePath "python" `
    -ArgumentList @($server, "--port", "$Port", "--log", $relayLog, "--stores", "coop\store") `
    -WorkingDirectory $root -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 1

$shared = @("--coop-port=$Port", "--coop-remote", "--coop-noautosave",
    "--coop-speed=$Speed", "--coop-verify=$Verify", "--coop-map=2", "--coop-ping")
# -TraceSteps makes every stage of _process write a marker, so an intermittent native crash leaves a log
# whose last marker names the call that died. The 0x5111bb fault has no GDScript traceback at all.
if ($TraceSteps) {
    $shared += "--coop-trace-steps"
    $shared += "--coop-trace"
}

# The host holds the world and does not trade; the client gives money away. Both have -ping on, which
# is the only thing that produces a `ping`/`pong` pair.
#
# `--coop-offer-auto` has to be on the *recipient*, not the sender: __maybe_accept() returns early
# unless the machine receiving the offer has it. A run that armed only the sender sent the offer, logged
# "auto=True" for the sender (which is not asked), and the host declined it - so the accept half of the
# protocol was still untested while the log looked like it had been exercised.
$hostArgs = @("--coop-host", "--coop-name=Highland", "--coop-log=$Name-host", "--coop-selftest",
    "--coop-offer-auto", "--coop-quit=$Seconds") + $shared
$clientArgs = @("--coop-join=127.0.0.1", "--coop-autojoin", "--coop-name=Tester",
    "--coop-log=$Name-client", "--coop-quit=$($Seconds + $DisconnectGrace)",
    "--coop-company=new", "--coop-offer-auto", "--coop-gift=$Gift") + $shared
# The host does the buying: it is the authority and it is the machine whose rival list the other player's
# company appears in.
if ($BuyTest -ne "") { $hostArgs += "--coop-buytest=$BuyTest" }
if ($Play -gt 0) {
    $hostArgs += "--coop-play=$Play"
    $clientArgs += "--coop-play=$Play"
}
if ($PlayRelease) {
    $hostArgs += "--coop-play-release"
    $clientArgs += "--coop-play-release"
}

$hostProc = Start-Process -FilePath $exe -ArgumentList $hostArgs -WorkingDirectory $out -PassThru
$hostLog = Join-Path $logDir "$Name-host.log"
$deadline = (Get-Date).AddSeconds(360)
while ((Get-Date) -lt $deadline) {
    if ((Test-Path $hostLog) -and
        (Select-String -Path $hostLog -Pattern "selftest: ready|selftest: game state is loaded" -Quiet)) {
        break
    }
    Start-Sleep -Milliseconds 500
}
$rdl = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $rdl) {
    if ((Test-Path $relayLog) -and (Select-String -Path $relayLog -Pattern "role host:" -Quiet)) { break }
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 3

$clientProc = Start-Process -FilePath $exe -ArgumentList $clientArgs -WorkingDirectory $out -PassThru

$hostProc.Id | Set-Content (Join-Path $out "pid-$Name-host.txt")
$clientProc.Id | Set-Content (Join-Path $out "pid-$Name-client.txt")
$relay.Id | Set-Content (Join-Path $out "pid-$Name-relay.txt")

Write-Host "coverage run $Name on port $Port (gift $Gift)"
Write-Host "  host   pid $($hostProc.Id)"
Write-Host "  client pid $($clientProc.Id)"
