# The remote-control channel

`--coop-remote` turns a running instance into something that can be driven and interrogated one command
at a time, through a file. It is an instrument, not a script: nothing runs unless you ask.

The distinction it exists for: `play.gd` calls the game's own controllers, which proves the sync layer
and proves nothing about the buttons a player presses. This channel presses the real buttons.

## How to use it

An instance named `K1-host` reads `coop/remote-K1-host.cmd` next to the executable, one command per
line, prefixed by a number:

```
1 state
2 tree
3 press confirm
```

Answers are written into **that instance's own log**, line by line:

```
INFO remote: command 3 [press confirm]
INFO remote: --- 3: press confirm (running)
INFO remote: --- 3: press confirm
INFO remote:     pressed [confirm] via its pressed signal (1 handler(s))
INFO remote: --- end of 3
```

Two things about that output are deliberate:

- **The answer goes into the log, not a side file.** `File.open(path, READ_WRITE)` on a file that does
  not exist yet fails in this build, so a side file silently never got written and every command looked
  like it had never run.
- **A `(running)` line is printed before the command executes**, so a command that kills the process
  still leaves a marker: the last `(running)` without an answer names it.

`tools/send.ps1` does the queueing and waiting:

```powershell
.\tools\send.ps1 -Run K1 -Role host -Command "state"
```

## Commands

| Command | What it does |
|---|---|
| `state` | the whole picture: date, money, fanbase, offices, staff with seating, game counts, other players, server users, consoles, store platforms, rivals |
| `date` | the clock: raw, year, month, week, paused, started, speed |
| `date run` / `date pause` | press play/pause, through the game's own controller |
| `date speed <n>` | 1/2/4/6, as the speed buttons do |
| `tree` | the game menu bar and every open popup |
| `dialogs` | every node in the tree with visibility — long, use deliberately |
| `find <name>` | is it there, visible, disabled |
| `findall <name>` | **every** node with that name plus its screen rect. Three are called `release` |
| `paths <name>` | like `findall`, with the full path of each |
| `press <name>` | emit `pressed` on the first match |
| `presspath <path>` | press by path, searching popups first |
| `pressroot <path>` | press by path from the scene root — for HUD nodes `presspath` cannot reach |
| `clickpath <path>` | synthesise a click on a non-Button that handles input itself |
| `innodes <scene> <command>` | run a command inside a scene's subtree |
| `fill <name> <value>` | set a text field |
| `call <name> <method>` | call a method on the first match |
| `menu <button>` | list a game menu button's submenu |
| `menuitem <button> <index>` | press a submenu entry |
| `close` | press the close button on the topmost popup |
| `steam` | close the "Steam not detected" dialog |
| `grep <prefix>` | paths in the tree starting with a prefix |
| `own` | per-player progression: unlocked genres, owned engines, capacities, conventions |
| `shot` | a marker, for aligning a screenshot with the log |

## The traps this channel has, all of which cost a run

**It used to be gated on `models.is_loaded()`.** The menu commands are how a test gets *into* a game, so
the channel was silent exactly when it was needed. Commands that need models say so themselves now.

**Rewriting the command file did nothing.** The poller tracked a high-water sequence number, so a
hand-written file whose numbers were lower than the last one run was ignored, with no message. It now
remembers commands **by their text**: a rewritten file works whatever numbers it carries, and polling
the same file again does not repeat itself.

**`send.ps1` searched only the lines written since it queued.** A fast answer arrived before the first
read and was reported as silence. It searches the whole log by sequence number now.

**`press` by name can hit the wrong node.** Three nodes are called `release`; the one that matters is in
the project card, not the 48×48 icon in the ReleasedProject panel. Use `findall` first, always.

**A node that is not a `Button` ignores `press`.** Genre cards handle clicks in `_input()` and this build
cannot synthesise an input event (`InputEvent.new()` is absent). `clickpath` emits the signal their own
`_input` would have emitted, with the right arguments.

## Reading a run

A healthy session, in order:

```
remote: ready, 28 of 28 helper(s) loaded
date now: raw=7 ... week=3          (host)
date now: raw=7 ... week=3          (client)   <- must match
state ... staff (developers:1), (seated_ok:True)
state ... server users 0 / own consoles 0 / store platforms 0    (client)
```

`28 of 28` is not decoration. Every helper here is `static`, and asking `has_method()` on the autoload
once reported `0 of 28 loaded` on a perfectly good file. The count is measured against an instance of
the script.

## When a command kills the instance

The last `remote: --- N: <command> (running)` in the log is the one that did it. Cross-check
`coop-errors-<run>-<role>.log` and, if you suspect a Variant member, re-run the stage with
`--coop-trace-steps`.
