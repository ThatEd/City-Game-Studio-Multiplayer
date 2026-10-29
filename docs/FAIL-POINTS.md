# What could still fail

Every subsystem that could break, why, and what would show it. This is the page to read before
claiming something works.

Labels: **proven** (a run showed it), **derived** (reasoned, not observed), **unknown** (nobody
looked), **wrong** (tried and failed).

---

## 1. Things that will crash rather than error

The worst class, because nothing is logged and the process just ends.

| Trap | State |
|---|---|
| A Variant member this build lacks | **proven.** `Dictionary.get()`, `Object.get()`, `Array.to_json()`, `Array.extend()`. The crash is `0xc0000005` at `0xae5633`, inside the member call. `build_mod.py check_native_killers()` rejects the known ones before packing |
| A missing class named in a script | **proven.** `TCPServer`, `JSON`, `NetworkedMultiplayerPeer`, `NetworkedMultiplayerENet`, `ColorRect`, `InputEventMouseButton`, `InputEventKey`, `InputEventAction`, `InputEvent`. `check_missing_classes()` rejects them; the mod probes the engine at boot and logs `class: X MISSING` |
| A null from a lookup, dereferenced | **proven.** `announce_game()` reads `game_data.id` unguarded and `get_game_by_id()` can return null. Guarded now |
| A per-save dictionary indexed without a check | **proven.** `game-theme.get_trend_by_theme()` indexes `__trend_data`, which is per-save. This was the "host crashes when a player makes a game" bug. `company.theme_known()` guards the transplant |
| Sizing something that is a count | **proven.** `record["studios"]` is a number; `.size()` on it killed the client when the relay replayed a record |
| Reading a `TYPE_ARRAY` field as an array without checking | guarded in the restore path now, after `layouts` was found to arrive as a count too |

**How to find one:** `--coop-trace-steps` logs `trace: <stage> ok` after each stage of `_process`. The
last marker before death names the call.

## 2. Silent compile failures

**Proven, and it cost three runs.** A `.gd` that fails to compile keeps running its *previous* version.
Every fix in that file is inert while nothing looks wrong. Half the file's functions are dropped, and
calls answer `Nonexistent function`.

Two defences, both needed:

- `build_mod.py check_gdscript()` refuses to pack a script that would not compile (unbalanced brackets,
  an identifier used outside its block, two statements joined on a line).
- `main.gd __probe_helpers()` compiles every mod script at boot and logs `compile: <path> ok|FAILED`.

**A trap inside the trap:** `reload()` returns `ERR_ALREADY_IN_USE` (22) when anything holds an instance.
`main.gd` holds one of `updater.gd`, so the probe reported a perfectly good file as broken for many
runs. It calls `reload(true)` and treats 22 as success. A check that cries wolf is worse than no check.

## 3. The world transfer

| Risk | State |
|---|---|
| A message too large | **proven.** One 8 MB message kills the build. The world is split per model, then per `WORLD_PART_SIZE` |
| A slow reader dropped mid-transfer | **proven, fixed.** `sendall()` on a non-blocking socket raised `BlockingIOError`, treated as a dead peer. The relay queues and retries; a 24×60 KB test case proves it |
| A joiner that never finishes | **unknown.** ~1 run in 12 sat on "Loading mods" at `inbox=65536`. Not diagnosed; the next step is keeping the joiner's log from the first byte |
| Joining before the host has a world | **proven, fixed.** The client reaches its own New Game and plays alone. `run-coop.ps1` waits for `selftest: ready` |
| A different game build | **unknown, undetected.** Nothing compares builds; the host's save is simply sent |

## 4. The clock

| Risk | State |
|---|---|
| A client moving time on its own | **proven blocked.** The host broadcasts the date; a client's correction is applied to it |
| A correction that does not repaint | **proven, fixed.** `set_raw_date()` emits nothing; the HUD paints on `month`. A live session showed a client whose model said 1978/01 and whose clock read AUG 1977 |
| A frozen clock that is not a bug | **proven.** `controllers/date.gd compute_state` freezes unless the game's main scene is on top. Any popup stops time. Two long sessions reached several in-game years once the popups were closed |
| Speed / pause disagreement | **proven.** Speed and paused travel with the clock; a mismatch is logged and reconciled |

## 5. The company split

| Risk | State |
|---|---|
| A client inheriting the host's console or users | **proven, fixed.** `isolate_store()` on join, and server usage held at zero while the company owns no console — because `_update_platforms` refills it every `end_of_week` |
| A restored player with no staff | **proven, fixed.** `restore_from_world()` furnishes the office and hires through the game's own `create_admin()` when the record holds nobody |
| Duplicate "Home" offices | **proven.** The game opens its own first studio and the mod opened another, so each join left one more. `ensure_single_home()` collapses them — only ones the mod created, i.e. named `Home` |
| A rival's theme this save does not know | **proven** — this is the crash in section 1 |
| Per-player progression diverging | **isolated, unmeasured.** `game-engine._owned`, `game-type`, `capacity`, `game-of-the-year`, `game-combos` |
| Buying another player out | **proven blocked** |

## 6. Rivals and the map

| Risk | State |
|---|---|
| Rivals simulated twice, diverging | **derived.** The client's simulation is muted on join and at `MUTE_INTERVAL`, and the world came from the host. A rival released *after* a client joined has not been watched on both sides |
| Two companies wanting the same tile | **derived.** A client's first office is placed on a free tile, and the company transplant happens before it is opened, so the host's tiles are already claimed |
| The map diverging over a long session | **unknown.** Not measured |

## 7. UI and interaction

| Risk | State |
|---|---|
| Pressing the wrong node | **proven.** Three nodes are called `release`. `findall` reports name **and** rect; the real one is at `(81,313)` |
| Release not publishing | **unconfirmed.** The press fires and spends money. `published` becoming 1 has not been watched |
| Popups stacking | **proven.** A tutorial and the disconnect popup can be up together |
| The Steam "not detected" dialog | **proven.** A `WindowDialog` in the store manager floats above every game popup. A test run closes it with the `steam` command |
| Screenshots of the wrong window | **proven.** `CopyFromScreen` grabbed a browser twice. `PrintWindow` is z-order independent |

## 8. The harness itself

Every one of these produced a false result rather than a failure.

| Trap | State |
|---|---|
| A test that runs to its full duration | **proven.** A crash is buried in 30 minutes of ordinary log. Runs now end when a peer dies |
| A claim made on a timer | **proven.** "main menu reached" on a timer said nothing. It now looks the scene up |
| The remote channel gated on a loaded game | **proven.** Menu commands — how a test enters a game — were unreachable exactly when needed |
| Rewriting the command file | **proven.** The poller tracked a sequence number, so a hand-written file below it was ignored. It remembers command text now |
| A "lines since" window | **proven.** A fast answer landed before the first read and was reported as silence |
| Two instances started together | **proven.** Whichever booted first set the terms |
| A 200 MB shared error log | **proven.** The first real error of a session was tens of thousands of lines in. Now per-run, emptied at start |
| One socket polled after death | **proven.** 4,618 identical engine errors, 1.1 MB, between the disconnect and Confirm. The poll now stops at a dead socket |

## 9. Not attempted at all

Split screen. A lobby. Steam invites. Three or more players. Rejoining without a world transfer.
Surviving a game patch.

## The order to try things in

1. Watch a Release actually publish (the node is known; the step is one press).
2. Look at the publish-offer list, the console panel and the map with human eyes.
3. Run a three-player session.
4. Play a full in-game year and compare per-player progression.
5. Diagnose the join stall by keeping the joiner's log from the first byte.
