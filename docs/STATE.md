# The honest state of co-op

Every subsystem, one line each, with how it was checked. If a claim has no evidence label it has no
business being here.

Labels: **proven** = a command ran and its output is in `docs/NOTES.md`; **derived** = reasoned from
proven facts; **unknown** = nobody looked; **wrong** = tried, failed, kept so it is not retried.

---

## Can someone play this today?

**Yes, two people, one session, with caveats — and no installer.**

| | |
|---|---|
| Two players in one world | **proven.** Two live instances, same week on both, each seeing the other as a rival |
| Either player runs a company | **proven.** Both sides have their own money, offices, staff, games |
| Trading money / technology / game IP | **proven** by assertion on both machines |
| Host leaving handled | **proven** on screen — popup, save, main menu |
| Returning player gets their company back | **proven.** €299,706 against €299,704 stored, office re-interiorated |
| Three or more players | **unknown.** The protocol is host-plus-N and the relay fans out, but only two have run |
| Installing it for a non-technical player | **wrong.** There is no installer. Two PowerShell commands and a game copy are required |
| Split screen | **unknown.** Not attempted for this game |
| Steam invite / friends list | **wrong.** Joining is a typed IP:port |

---

## The world

| Subsystem | State | Evidence |
|---|---|---|
| World transfer on join | Works, split into per-model messages because one 8 MB message kills the build | **proven** — 53 models, ~8.85 MB, `world received (53 models), booting` |
| Transfer size limit | `WORLD_PART_SIZE` chunks; a slow reader must not be dropped | **proven** — the relay queues and retries; 24×60 KB test case |
| Late joiner | Host re-sends the world on `join_request` and the relay caches it | **proven** — "world reaches the joiner, also later" |
| Map | Host's map is the world's; a client's office tiles are the host's tiles | **proven** |
| Date / clock | Host is authoritative; a client that drifts is corrected, and the correction emits `month` so the HUD repaints | **proven** — clock on screen asserted against the model |
| Rivals | Simulated on both machines from the same world snapshot; the client's simulation is muted | **derived.** A rival released *after* a client joined has not been watched on both sides |
| Conventions | Catalogue (`generated`, `announced`) is the world's and is transferred; `planned`/`running`/`archived`/`autoattend` are per-player | **proven** — client 0 planned / 0 running / 0 archived, auto-attend off, catalogue present |

## The company

28 models are replaced from the player's own copy. Full list in `COMPANY_MODELS` in
[`../mod/coop/main.gd`](../mod/coop/main.gd).

| Subsystem | State | Evidence |
|---|---|---|
| Identity (name, player name, logo) | Per-player | **proven** — `Highland Studio` vs `Tester Studio` in each other's lists |
| Currency, fanbase | Per-player | **proven** |
| Staff and offices | Per-player; a restored player is re-seated and the office furnished | **proven** — `staff (developers:1), (seated_ok:True)` |
| Interiors (furniture layout) | Carried in the company record and restored onto a new map | **proven** — `reopened the office on this map with 4 piece(s) of the saved layout` |
| Games, sales, reviews, ports, remakes | Per-player; a rival's games are transplanted with their theme **only if this save's trend table knows it** | **proven** — the missing trend entry was the crash cause |
| Digital store | Emptied for a client. Otherwise it inherits the host's platforms and userbase | **proven** — client 0 store platforms, host 16 |
| Server usage | Held at zero for a client that owns no console, on every `end_of_week` | **proven** — 58,783 leaked in one tick before the fix, 0 after |
| Consoles | A rival's console is registered as a platform *they* own, not the client's | **proven** — client 0 own consoles |
| Staff simulation | Each machine simulates its own company's staff | **derived** |
| Buying out another player | Blocked | **proven** — buyout guard installed, tested |

## Per-player progression that is *not* synced

These are isolated correctly — each player has their own — but there is no design for sharing them,
and their effect over a played year has not been watched:

| Model | What it holds |
|---|---|
| `game-engine._owned` | which engines a company has researched |
| `game-type` unlocks | unlocked genres |
| `capacity` | which project capacities are unlocked |
| `game-of-the-year` | awards won |
| `game-combos` | combo bonuses earned |

Consequence: two players at the same date can have different engine and genre reach. Measured at one
date, both knew the same 18 of 64 genres — but that was a fresh game.

## Sessions and lifecycle

| Subsystem | State | Evidence |
|---|---|---|
| Host leaves → client told | The relay broadcasts `host_left` before closing; the client reacts immediately | **proven** — "clients are told when the host leaves" |
| Disconnect screen | Game's own warning popup, Confirm returns to the main menu | **proven on screen** (evidence shot) |
| Main menu actually reached | Checked by looking the scene up, not by a timer | **proven** — the first version printed success on a timer and was wrong |
| Client saves on disconnect | Through the game's own `save_manager.save_game()` | **proven** — `company written in 0 ms` |
| Company survives the host | Client hands its record to the relay; the relay keeps it across restarts | **proven** — `a leaving client keeps its last company`, `the stored company survives a new relay` |
| Client rejoins mid-session | Works, but it is a full world re-transfer, not a delta | **derived** |
| A client leaving voluntarily | Host pauses and must confirm carrying on | **proven** — `--coop-continue-without` |
| Test runs end on a peer death | Host quits after 45 s of client silence; client quits when its host is gone | **proven** |

## Known breakage and rough edges

| | |
|---|---|
| Release from the UI | **unconfirmed.** The button fires and spends money; `published` becoming 1 has not been watched. The correct node is `.../IndevProject/.../container/release` at `(81,313)` — three nodes share the name |
| Publish-offer list, console panel, map | **unknown.** Never looked at by a human |
| Tutorial popup overlapping the disconnect popup | **proven.** Both are game popups and both can be up at once |
| The game's own calendar errors on the way back to the menu | **proven, not ours.** `gui/calendar.gd:89` calls `date_model.month_progression()` unguarded during `main_menu()` teardown. Does not crash |
| An intermittent join stall | **unknown.** About 1 run in 12: the joiner sits on "Loading mods" with `inbox=65536`. Not diagnosed |
| Surviving a game patch | **wrong.** Every patched script must be re-applied per build, and a patch may re-encrypt the scripts |
| `print()` | Disabled by the game's config. All logging goes to files next to the exe |

## What has actually run against a real game

Not "the suite exists" — ran, and how much:

| What | How much |
|---|---|
| Two-instance sessions | 20+ runs across the project's history, the last six instrumented |
| Continuous play, both machines | Several in-game years in one hand-driven session (1976→1978, same week on each check) |
| Automated assertion suite | 25 checks on each machine on a fresh game; 26 on a mid-game save |
| Relay suite | 12 cases |
| Pack tool suite | 5 twin tests + format cases |
| Human looking at the screen | The disconnect flow, the restored office, the new-game form, the design step, the rival list. **Not** the publish-offer list, the console panel, the map |
