# When the host goes away

The state a client is in when its authority vanishes is the worst one this mod can produce: the clock
came from somewhere that no longer exists, the company table came from there too, and nothing it does
reaches anyone. Leaving it in a frozen world is indistinguishable from the game being broken.

So it is handled explicitly, and this page records what is proven.

## The sequence, from a real run

Host killed while a client was playing. One second of the client's log:

```
WARN net: the relay says the host has left the session
INFO net: company written in 0 ms
INFO net: company handed to the relay on the way out
INFO clock: freeze is now True (paused=False)
```

and on screen, the game's own warning popup — *The host left the session* — with a Confirm button.

Pressing Confirm, through the same channel a player's click goes through:

```
INFO net: returning to the main menu after the host left
INFO test: main menu is up, ending this run
```

That last line carries its weight. The first version said *main menu reached* because **a timer had
expired**. It would have printed the same thing onto a blank screen. It now looks the main menu scene
up and says so only once it is found. This is the difference between a working flow and a working
intention.

### The return was dead code once

Between the screen appearing and the return is a linger timer, so a player reads the message before the
menu replaces it. `__watch_peers()` used to `return` as soon as `__disconnect_notified` was set - which
is set at the same moment as the screen - so the timer that does the returning never ran. The client sat
on the disconnect screen until `--coop-quit` ended the run. Run TRC2 finished at 600 s with this in the
log and no menu line at all:

```
WARN net: the relay says the host has left the session
INFO net: company written in 5247 ms as coop-Highland-tester
INFO net: company handed to the relay on the way out
INFO quit after 600 s (test mode)          <- never reached the menu
```

Found by reading the log of a run that had otherwise passed. `__watch_peers()` now calls
`__linger_on_disconnect()` on that path instead of returning, and the same test afterwards reads:

```
WARN net: the relay says the host has left the session
INFO net: company written in 5279 ms as coop-Highland-tester
INFO net: company handed to the relay on the way out
WARN test: disconnect screen held 20 s, returning to the menu
INFO net: returning to the main menu after the host left
INFO test: main menu is up, ending this run
```

## Where the save goes

Two copies, on purpose:

| Copy | Where | Why |
|---|---|---|
| The player's own save | the game's own `save_manager.save_game()`, the same path the Save button takes | a returning player has a normal save of their own |
| The company record | handed to the relay over the still-open socket | the host that would have published it is the one that just died |

The second is what makes "come back later" work. The relay keeps a record per player, on disk
(`--stores <dir>`), so it survives a relay restart and a *different* host can serve the same player.

## The three relay bugs this needed

Each one alone broke the feature, and each was found by running it, not by reading it.

**1. The client's last minutes had no copy anywhere.** The relay kept every player's company from the
host's periodic company table. Between the host's last publish and its death — minutes of play — nothing
existed outside the dead process. The client now hands its own record over, and the relay accepts a
`company` message from a client as a record to keep (it still forwards it to the host as usual, so the
world stays consistent while both are alive).

**2. There was no window to hand it over in.** `drop()` told the clients the host was gone *and closed
their sockets in the same call*. The client's answer had nowhere to go. The relay now keeps those
sockets open for `HOST_LEFT_GRACE` (20 s) and reaps them if the client does not close its own — and it
logs which of the two happened:

```
client did not close its own socket, closing it here
```

**3. The stored company could never be delivered.** `restore_from_world()` read `studios`; a stored
record has `offices` and `layouts`. The company arrived, was recognised, and was then discarded for
having "no offices", so the player got a brand new one. Both shapes are read now.

There is a fourth, smaller one: `studios` in a record is a **count**, not a list, and the first attempt
to report `record["studios"].size()` crashed the client outright at that line.

## A returning player, measured

Run L4. The store held: name `Tester Studio`, currency `299704`, 1 office, 1 layout.

What the client ended up with:

```
money 299706
offices 1
staff (developers:1), (orphans:[]), (seated_ok:True), (total:1)
server users 0
own consoles 0
```

and in the shared log:

```
restore: reopened the office on this map with 4 piece(s) of the saved layout
```

The money matches (two currency ticks of drift), the office is on the **new** host's map — its tiles
are not the old ones — and the furniture came across. The two numbers that were wrong for months, the
inherited server users and the console, are both zero.

## What is still not right

| | |
|---|---|
| A tutorial popup can overlap the disconnect popup | both are the game's own popups and nothing de-duplicates them (seen in a run) |
| The game's calendar throws during the menu transition | `gui/calendar.gd:89` calls `date_model.month_progression()` unguarded while `main_menu()` resets the models. Not ours, does not crash |
| Rejoining mid-session | works, but it is a full world re-transfer |
| Three players, one leaving | untested |

## Testing it

`run-coop.ps1` plus `Stop-Process` on the host pid is the whole test. What to look for:

1. the relay log: `disconnected host:`, then `told client: ... the host is gone`
2. the client log: `the relay says the host has left the session`, `company written`, `handed to the relay`
3. the client's screen: the popup (screenshot with `tools/capture-window-print.ps1`)
4. `send.ps1 -Run <run> -Role client -Command "press confirm"`, then `main menu is up`
5. `coop/store/<player>.json` exists and holds the player's latest company

A client that does *not* react shows a healthy socket and keeps logging normally — that is what the
bug looked like before `host_left` existed.
