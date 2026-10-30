# Three players on one relay: one host and two clients.
#
# The census showed that no run has ever had a third participant, so every path that is only exercised
# with more than two players - a lobby summary listing more than one company, the company table fanning
# out to two clients, a departure reaching a player who is not the departing one - had never run at all.
#
#   .\run-three.ps1 -Name TRI1 -Port 8370 -Seconds 600
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$Port = 8370,
    [int]$Seconds = 600,
    [int]$DisconnectGrace = 90,
    [int]$Speed = 4,
    [int]$Verify = 150,
    [string]$SecondName = "Rivalry",
    [string]$ThirdName = "Underdog"
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
foreach ($role in @("host", "client", "second")) {
    Remove-Item (Join-Path $logDir "$Name-$role.log") -ErrorAction SilentlyContinue
}

$relayErr = Join-Path $logDir "$Name-relay.err.log"
Remove-Item $relayErr -ErrorAction SilentlyContinue
$relay = Start-Process -FilePath "python" `
    -ArgumentList @($server, "--port", "$Port", "--log", $relayLog, "--stores", "coop\store") `
    -WorkingDirectory $root -PassThru -WindowStyle Hidden `
    -RedirectStandardError $relayErr
Start-Sleep -Seconds 1

$shared = @("--coop-port=$Port", "--coop-noautosave", "--coop-speed=$Speed",
    "--coop-verify=$Verify", "--coop-map=2", "--coop-offer-auto")

$hostArgs = @("--coop-host", "--coop-name=$SecondName", "--coop-log=$Name-host", "--coop-selftest",
    "--coop-remote", "--coop-quit=$Seconds") + $shared

$hostProc = Start-Process -FilePath $exe -ArgumentList $hostArgs -WorkingDirectory $out -PassThru
$hostLog = Join-Path $logDir "$Name-host.log"
$deadline = (Get-Date).AddSeconds(360)
while ((Get-Date) -lt $deadline) {
    if ((Test-Path $hostLog) -and
        (Select-String -Path $hostLog -Pattern "selftest: ready|selftest: game state is loaded" -Quiet)) { break }
    Start-Sleep -Milliseconds 500
}
$rdl = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $rdl) {
    if ((Test-Path $relayLog) -and (Select-String -Path $relayLog -Pattern "role host:" -Quiet)) { break }
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 3

# The first client decides its own company, then the second joins the world that already has two players
# in it - that ordering is what puts a second company in the other client's lobby summary.
$clientArgs = @("--coop-join=127.0.0.1", "--coop-autojoin", "--coop-name=Tester",
    "--coop-log=$Name-client", "--coop-company=new", "--coop-remote",
    "--coop-quit=$($Seconds + $DisconnectGrace)") + $shared
$clientProc = Start-Process -FilePath $exe -ArgumentList $clientArgs -WorkingDirectory $out -PassThru

$waitJoin = (Get-Date).AddSeconds(300)
while ((Get-Date) -lt $waitJoin) {
    if ((Test-Path (Join-Path $logDir "$Name-client.log")) -and
        (Select-String -Path (Join-Path $logDir "$Name-client.log") -Pattern "is in, time may move|world complete" -Quiet)) {
        break
    }
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 8

$secondArgs = @("--coop-join=127.0.0.1", "--coop-autojoin", "--coop-name=$ThirdName",
    "--coop-log=$Name-second", "--coop-company=new", "--coop-remote",
    "--coop-quit=$($Seconds + $DisconnectGrace)") + $shared
$secondProc = Start-Process -FilePath $exe -ArgumentList $secondArgs -WorkingDirectory $out -PassThru

$hostProc.Id | Set-Content (Join-Path $out "pid-$Name-host.txt")
$clientProc.Id | Set-Content (Join-Path $out "pid-$Name-client.txt")
$secondProc.Id | Set-Content (Join-Path $out "pid-$Name-second.txt")
$relay.Id | Set-Content (Join-Path $out "pid-$Name-relay.txt")

Write-Host "three-player run $Name on port $Port"
Write-Host "  host   pid $($hostProc.Id)   [$SecondName]"
Write-Host "  client pid $($clientProc.Id)   [Tester]"
Write-Host "  second pid $($secondProc.Id)   [$ThirdName]"
