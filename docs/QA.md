# Quality assurance, and what it does not cover

Three layers, deliberately separated, because they fail in different ways and a claim needs to say
which one backs it.

| Layer | Command | Needs a game? | Proves |
|---|---|---|---|
| Relay | `python -I server/run_tests.py` | no | framing, routing, storage, disconnect handling |
| Pack tool | `python -I tools/godotpck/run_tests.py` | no | reading, extracting, patching Godot packs |
| Mod source | part of `python -I run_all_tests.py` | no | the engine would compile and accept the code |
| In-game | `--coop-verify` on two live instances | **yes** | the two worlds agree on the things asserted |

`python -I run_all_tests.py` runs the first three. All three pass on a machine with no game installed,
which is the point — a fresh clone is the real test.

## The relay suite: 16 cases

```
ok   world reaches the joiner, also later
ok   join request reaches the host
ok   clock is broadcast to every client
ok   client company reaches the host and is kept
ok   host company table fans out
ok   no host is an answered error
ok   departure reported to the host
ok   a departure reaches the other players
ok   a world is only sent to the player who asked
ok   a broken log handle does not kill the relay
ok   a returning player gets their company back
ok   a leaving client keeps its last company
ok   the stored company survives a new relay
ok   clients are told when the host leaves
ok   a slow reader still receives the whole world
ok   the auto flag reaches the host
```

Three of these were **rewritten** when the contract changed, not loosened:

- "client company goes only to the host" became "reaches the host and is kept". The relay now keeps
  the client's record too, because the host it would otherwise rely on is the one that dies. What the
  case still forbids is fanning a client's traffic out to other clients.
- "a leaving client keeps its last company" is new, and it is the end-to-end version of the bug: the
  host publishes, the client plays on, the host dies, the client hands its record over.
- "the auto flag reaches the host" is new, and it is a bug that cost a whole class of runs: the relay
  dropped `auto` when forwarding `join_request`, so every unattended join arrived looking interactive
  and the client waited for a lobby nobody could press.

The last four are three-player bugs, and all four were invisible with two players:

-  departure reaches the other players — the relay told only the host. With two players there
  is nobody else to tell, so a third client kept a departed player listed as present for a whole run.
-  world is only sent to the player who asked — every join re-sent the entire world to every client
  already in it, which those clients ignored. Hundreds of parts of a multi-megabyte transfer per join.
-  broken log handle does not kill the relay — the worst of them. Started with stdout redirected,
  print() raised and the exception left serve_forever(): the relay died one message into a session
  while all three games stayed healthy, and the players saw only a world that stopped updating.
-  world is only sent to the player who asked and  departure reaches the other players both come from
  the same run.

### Cases that were lying

	he stored company survives a new relay and  leaving client keeps its last company failed about one
run in three and passed on rerun. Both asserted on state the relay had not reached yet, behind fixed
	ime.sleep() calls; both now wait for the condition. Four consecutive clean runs after the change.

 broken log handle does not kill the relay had the same defect in the other direction: its first version
drove the relay over the socket and passed **with the print guard removed**, because the message-handling
wrapper added at the same time caught the exception first. It now calls log() directly with both outputs
broken, and was proven to fail with the guard removed and to pass with it restored. A case that passes in
both directions is worse than none.

## The in-game suite

Turned on with `--coop-verify=<seconds>`. Each assertion prints `verify PASS`/`FAIL` with the values
it compared, on **both** machines, so a disagreement is visible from either log. It covers:

- the same week on both machines, and the clock label on screen matching the model
- the client owning no console, no store platforms and no server users
- each side seeing the other as a competitor with the right name and office count
- trade results agreeing on both machines
- the client having no conventions of its own planned, running or attended, while knowing the shared
  catalogue
- the client not holding the host's company models

Counts recorded: **25 checks on a fresh game**, 26 on a mid-game save (that save already has a company
name, so one assertion that is skipped on a fresh game runs), and **29 on both machines** once the two
stale checks below were corrected.

### The two checks that were lying

A 1500 s run reported `27 passed, 2 failed` on the host and `28 passed, 1 failed` on the client. Both
were defects in the *checks*, not in the session:

| Check | What was wrong | Now |
|---|---|---|
| `date does not run ahead of the world` | measured the local date against `__host_raw`, which nothing ever set **on the host** — it sent its clock inline and never recorded its own values, so "the world" was a value from the join, twenty weeks stale. A host failing its own check | the host records the values it broadcasts. `local 31 vs world 31` |
| `this machine knows the shared convention catalogue` | counted `generated + announced`, which hold only conventions generated *this session* — legitimately empty in a young game. The list a player sees is `list_existing_conventions()` | asks the game for the list it would show a player, and reports the other two alongside. `126 entr(ies); 0 generated here, 0 announced` |
| `my date is ahead of where it was a minute ago` (playtest) | expected a week to pass. On a client whose date model is *not* frozen while the host's is, the client ticks to the next week and `__pull_date_back()` puts it back every three seconds — the sync working. The check read that as the date failing to advance, and failed seven rounds in a row while `our dates agree`, `our speed agrees` and `our pause state agrees` all passed | recognises a date being *held* (`__pull_count` rising) as the sync refusing to let this machine move on, says so once, and passes. Both machines now pass all eight rounds |
| `own company has money` (verify) | failed on a machine whose sync was perfect, because a gift had been allowed to overdraw the giver to **-5373**. Nothing checked affordability, at the offer or at the apply | refused at the offer and again at the apply, because an offer can outlive the money it was made against. The poisoned balance had also been *stored* by the relay and handed back to the next session, so the failure outlived the run until the store record was repaired |

Both failed on healthy machines, which is worse than not checking at all: a suite that cries wolf
teaches you to skim its output, and this project has already lost runs to a check that was quietly
inert. Every assertion is now verified in **both** directions — it must be seen to fail when the thing
it measures is broken, and to pass when it is not.

## What none of it covers

This is the honest part, and it is why the README's "where it stands" table is split three ways.

| | |
|---|---|
| Nobody has looked at the publish-offer list, the console panel or the map | the assertions read model values; a panel that renders them wrongly would pass |
| Release from the UI | the press fires and spends money; `published` becoming 1 has not been watched |
| Rivals released after a client joined | the mute is applied periodically, but the case has not been observed on both sides |
| Per-player progression over a year | `game-engine`, `game-type`, `capacity`, `game-of-the-year`, `game-combos` are isolated; their effect over a played year is unmeasured |
| Four or more players | three now run together — 32/32 on all three machines including the full disconnect path on both clients — but the relay has never carried more, and has never been under load from more than three |
| A long session under load | the longest was several in-game years in one hand-driven session |
| A date model that is *not* frozen on the client | in an automated run the host's date stays frozen and the client's does not, so the client ticks and is pulled back every three seconds. That exercises the correction path constantly, but both machines running and advancing *together* is only proved by the hand-driven runs |
| Two kinds that are refused, not untested | `acquired` has never been on the wire and should not be: the buyout guard refuses a player's company by design. `session_request` has never been sent by anything. 29 of 30 kinds have run |

## Driving the real UI, not a script

The distinction that matters: `play.gd` calls the game's own controllers, which proves the sync layer
and proves nothing about the buttons a player presses. A second channel (`--coop-remote`) drives the
**real controls** instead — see [REMOTE.md](REMOTE.md).

Four bugs exist only because of this, and no assertion suite could have found them: a project form that
needs a genre and a theme before Start enables, a Steam dialog covering the bottom half of the form,
the wrong `release` node among three, and a clock label that disagreed with the model.

## The harness's own failure modes

Each of these produced a *false result*, which is worse than a failure:

- a test that runs to its full duration buries a crash
- a claim made on a timer ("main menu reached")
- a channel unreachable before a game loads
- a rewritten command file silently ignored
- a "lines since" window that misses a fast answer
- two instances started at once, so whichever booted first set the terms
- a 200 MB shared error log hiding the current run
- a probe that called a healthy script broken (`reload=22`)

They are listed here rather than buried because the next person will otherwise rebuild them.

## Running a two-instance session

```powershell
.\tools\run-coop.ps1 -Name K1 -Port 8330
```

and then, in the logs:

| Look for | Means |
|---|---|
| `registered as host` / `registered as client` | the relay accepted the role |
| `world received (N models), booting` | the client got the world |
| `company choice ... -> restored ...` | the client has its own company |
| `verify PASS` lines | the in-game suite is running |
| `coop-errors-<run>-<role>.log` | short is healthy; a repeated line is the bug |

## The long run: two in-game years and what "passing" means

The short runs prove the plumbing. Only a long run finds the faults that live on a boundary — a year
end, a monthly cycle, a report — and those are where this mod failed for weeks.

```powershell
.\tools\run-coop.ps1 -Name TWOYR -Port 8980 -Speed 6 -Company new -Seconds 1500 -Verify 60 -MapSize 4
```

`-Speed 6` is the game's own fastest speed (the clock holds it there; `controllers/currency.gd` forces
1x on a money warning and `__hold_test_speed()` puts it back), `-MapSize 4` is the 120-tile map with 12
competitors, and one in-game year is 48 weeks, so **two years is 96 weeks** and 1500 s at 6x covers
considerably more than that on this hardware.

What a passing run looks like, from the run recorded in `NOTES.md`:

```
host   : quit after 1500 s
client : month changed to 1990/8, calendar repainted      <- 14 in-game years
         verify: 29 passed, 0 failed    (on both machines)
```

A run is only a pass if **all** of these hold, and the first one is not optional:

1. **Neither process died before its own `--coop-quit`.** A crash leaves no error; check
   `Get-WinEvent -FilterHashtable @{LogName='Application'}` for `0xc0000005`, and check the process is
   still listed. Four crashes were found this way, all at offsets the log never mentions.
2. Both machines report the same `verify` totals and no `verify FAIL`.
3. `company written ... as coop-<session>-<player>` appears on the client after the host leaves.
4. `main menu is up, ending this run` follows it. A run that saves and then sits on the disconnect
   screen until `--coop-quit` is a **failure** of the return path, even though everything before it
   worked — that is exactly how the dead `__linger_on_disconnect()` was found.

### Reading a long run cheaply

The log is dominated by per-second `net: status=` and per-frame `trace:` lines. Filter them out first:

```powershell
Get-Content .\build\out\coop\TWOYR-client.log |
  Where-Object { $_ -notmatch 'trace:|net: status|dispatching|dispatched|message\(s\) in' } |
  Select-Object -Last 40
```

and then ask the one question that matters, which is not "did it run" but "did both machines see the
same world":

```powershell
Select-String -Path .\build\out\coop\TWOYR-*.log -Pattern 'month changed|overshoot|pulled back|verify (PASS|FAIL)'
```
