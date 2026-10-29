# Playing it

For someone who wants to actually play, not build. Read the warning first.

> **Do not do this on a save you care about.** The mod copies your game into a separate folder and
> disables autosave, so your real saves and your real install are not touched — but it is a
> prototype, it has crashed, and the game's own saves are the only backup you have. Back up
> `%APPDATA%\..\Local\City Game Studio\save` (or wherever your saves live) before you start.

## What you need

- Windows.
- The game, on Steam: **City Game Studio**, app id `726840`. Tested on Steam build `25723493`,
  game v1.29.0-rc3.
- Python 3 on `PATH` (the relay is a Python script).
- The same game build on both machines. The world transfer is the host's save; a mismatch is not
  detected, so keep them equal.

## 1. Build a modded copy

From this folder, with the path to **your** install:

```powershell
python build\build_mod.py `
    --install "C:\Program Files (x86)\Steam\steamapps\common\City Game Studio" `
    --out .\build\out
```

Expected last line: `verified: pack MD5s, autoload and mod files present`.

You now have a full second copy of the game in `build\out` with the mod inside. Your Steam install was
only read.

## 2. The easy way — one command

On **the machine that will host**:

```powershell
.\tools\run-coop.ps1 -Name mygame -Port 8330 -HostName You -ClientName Friend
```

This starts the relay, the host, waits for the host to load a world, then starts the client — both on
this machine, which is how it has been tested. Three log files appear in `build\out\coop\`.

**On two separate machines** you need the relay reachable from both. Run the relay on the host's PC:

```powershell
python server\coop_server.py --port 8330 --stores .\coop\store
```

then give the guest this folder (or just `build\out`) plus your local IP, and have them run:

```powershell
cd build\out
.\CityGameStudio64.exe --coop-join=<host ip> --coop-port=8330 --coop-autojoin --coop-company=new --coop-name=Friend
```

and you run:

```powershell
cd build\out
.\CityGameStudio64.exe --coop-host --coop-port=8330 --coop-name=You --coop-selftest
```

Wait until the host's log says `selftest: ready` **before** the guest starts. A client that starts
first opens its own New Game and plays alone.

## 3. What you should see

1. Both windows land in a game. The host's world is the world; the guest's clock follows the host's.
2. Each menu bar has a **Multiplayer** button at the end. It opens a panel where money, a technology,
   or the IP of a published game can be offered to the other player.
3. The **rival list** shows the other player by company name.
4. A guest who leaves and comes back is handed their company — money, offices, and the furniture in
   those offices — back.

## 4. What will annoy you

| | |
|---|---|
| **You cannot type an IP into a field yet** | Joining is a command-line flag. The menu has a Join button and an address box, but the tested route is the flag |
| **The clock looks frozen** | Any open popup stops game time. Close the tutorial and the inbox and it starts |
| **The "Steam not detected" window** | Covers the bottom of the New Game form when Steam is not running. Close it with its X |
| **Cursor focus between two windows** | Both instances want the mouse. Run them side by side; there is a `-WindowStyle` trap in normal use (never minimise the host) |
| **Ctrl-C on the relay** | Ends the session. The guest sees the disconnect screen and is returned to the menu, which is the intended behaviour |
| **Release may not publish** | The Release button fires but the project may stay in `HOLD`. Known, unconfirmed |

## 5. If it goes wrong

Every instance writes its own log to `build\out\coop\`:

| File | What is in it |
|---|---|
| `<run>-host.log`, `<run>-client.log` | everything the mod did, one line per event |
| `<run>-relay.log` | connections, roles, join requests, disconnects, what was stored |
| `coop-errors-<run>-<role>.log` | engine and script errors only |

The first thing to read is `coop-errors-*.log` — it is short by design now, and if it is long the
repeated line is the bug.

To stop everything:

```powershell
Get-Content build\out\pid-my* .txt | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
```

To ask a running instance what it thinks:

```powershell
.\tools\send.ps1 -Run mygame -Role host -Command "state"
```

## 6. Where the mod actually is

Nothing is installed into the game. `build\out\` is a copy; delete it and you are back to unmodified
Steam. The only files the mod adds are inside that copy's `data.pck` and one settings entry in its
`engine.cfb`.
