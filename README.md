> **Which build these results describe.** Everything below was measured on Steam `buildid` **25723493**
> (game v1.28.1). Steam has since installed an **unstable build, `buildid` 25961418**, which has been checked
> only for the basics: the mod builds against it, boots, and reaches a live game (see
> [docs/NOTES.md](docs/NOTES.md) pass 38). Its scripts are now **encrypted** (`GDEC`, `FileAccessEncryptedv3`,
> 32-byte key) and **0 of 932 decompile**, so what its new features do cannot be read - only observed through the
> live models. Treat every detailed claim in this README as belonging to the older build until re-verified.

# City Game Studio Multiplayer

Competitive co-op for **City Game Studio** — one player hosts their save, a second joins over a relay
and runs their **own competing studio** inside the host's world. Not shared control: two companies,
both visible to each other, both really on the map.

This repository is self-contained. `python -I run_all_tests.py` passes on a clean clone with no game
installed.

---

## Where it stands, honestly

**It is a working prototype you can play a session of, and it is not something you should install on
a save you care about.**

What that means, split by whether it has actually been seen:

| | |
|---|---|
| **Playable** | A joining player picks who they are in a **lobby** - either the game's own company setup (name, logo, specialisation) or an existing company to take over - and only then is the world sent. Each player's save is stored per session and per player. A host and a client join, boot the same world, and each runs a company. Both appear in each other's rival list by name, with their own money, offices and released games. Time is the host's; a client cannot move it alone. Money, technology and a game's IP can be handed to the other player and both sides agree. When the host leaves, the client is told on screen, saves, and is returned to the main menu. A returning player is handed their company and their office interiors back. |
| **Only tested by a machine** | Everything above is asserted by an in-game suite (`--coop-verify`) on both machines, by a two-bot playtest (`--coop-play`, 8 rounds of 14 assertions each) and by 16 relay cases. The longest run so far went **1976 -> 1985 on the 120-tile map at 6x, with 29/29 assertions passing on both machines and neither process dying**. **Three players have now run together**: 32/32 on all three machines, with the full disconnect path on both clients. Every message kind the mod can send has crossed the wire except two, and both are explained below. What has *not* been looked at by a human is the publish-offer list, the console panel and the map. Release from the UI is **unconfirmed**: the button fires and spends money, but nobody has watched the project leave `HOLD`. |
| **Never on the wire, on purpose** | `acquired` is the message that tells players a company was bought out. It has never been sent, and should not be: the buyout guard refuses a player's company, so try as it might `--coop-buytest` gets "refused a buyout of coop-tester - that company belongs to a player". `session_request` is handled and never sent by anything. So 29 of 30 kinds have run, and the two that have not are accounted for rather than untested. |
| **Not done** | Split screen. Four or more players (the protocol is host-plus-N and three now work, but the relay has never carried more). Rejoining mid-session without a fresh world transfer. Steam invite/friends list - joining is a typed address today. |

There is no installer. It runs from a build folder and is launched with flags, which is the actual
barrier between this and "someone can play it tonight". See
[`docs/PLAY.md`](docs/PLAY.md) for the honest steps.

### Why it needs a relay at all

This shipped build of the engine has no `TCPServer` — verified by probing the exe, not assumed
(`NetworkedMultiplayerPeer`, `NetworkedMultiplayerENet` and `JSON` are missing too). The game can only
dial out. So a small Python process is the hub: the host connects to it and the client connects to it,
and it moves messages between them. It is not a server you need a machine for — both players run it on
one machine, or one of them runs it.

---

## The lobby, and how a player chooses

Joining does not drop a player into someone else's studio. The client stays in the main menu and a lobby
lists what this world offers:

- **Start a new company** opens the game's own company setup - name, randomise, logo, the logo drawer,
  genre specialisation - and creates it when confirmed.
- **Take over a company** lists the world's companies (the host's, AI rivals, and players from earlier
  sessions) and hands over the one picked, through the game's own acquisition path.

The world is **not** transferred until the choice is made. That ordering is the whole design: sending the
world first means the client has already booted into a game, and there is nothing left to ask. See
[docs/LOBBY.md](docs/LOBBY.md).

## Saves

A co-op save is named after the session and the player, `user://coop-<session>-<player>.cgs`, so it can
never overwrite a single-player save or another session's. The file stays on the machine that wrote it;
what travels is the *name*, on the company record, so the relay can tell a returning player which save is
theirs. See [docs/SAVES.md](docs/SAVES.md).

## What it syncs, and what it deliberately does not

The mod treats "the world" and "a company" as different things. That split is the whole design.

**The host owns the world** — map, date, rivals, conventions catalogue. It is transferred once, on
join, in pieces (a single 8 MB message kills this engine build).

**Each machine keeps its own company.** 28 models are replaced from the player's own copy rather than
the host's: identity, staff, currency, fanbase, games, sales, ports, remakes, reviews, marketing,
recruitment, conventions *plans*, consoles, stores, achievements, and so on. The list is `COMPANY_MODELS`
in [`mod/coop/main.gd`](mod/coop/main.gd).

That split is what stops the bug this project spent longest on: a client that inherited the host's
`digital-store` and `server` models appeared to own a console and 3 million users. The store and server
are explicitly emptied for a client, and a client that owns no console holds its server usage at zero.

**Deliberately not synced**, because they are per-player progression and there is no design for sharing
them yet: `game-engine` ownership, `game-type` genre unlocks, `capacity`, `game-of-the-year`,
`game-combos`. They are isolated correctly — each player has their own — but their effect over a full
played year has not been watched.

---

## Layout

```
City Game Studio Multiplayer/
  README.md                     this file
  LICENSE                       MIT
  run_all_tests.py              one command: relay + pack tool + mod compile checks
  docs/                         one page per topic; start at docs/INDEX.md
  build/build_mod.py            builds a runnable copy; refuses to ship code the engine would reject
  mod/
    coop/                       the mod itself (GDScript, injected as plaintext)
    scripts/                    two engine scripts it replaces or adds
  server/                       the relay, its tests, and a fake client
  tools/
    run-coop.ps1                starts relay + host + client, one command
    send.ps1                    sends one remote command to a running instance
    capture-window-print.ps1    screenshots a game window without stealing focus
    godotpck/                   read/extract/patch Godot packs (vendored; the build depends on it)
```

`local/` next to this folder is git-ignored and holds the things that must not be published: the
extracted game scripts, the patched `data.pck`, evidence, and the owner's saves.

---

## Quick start

Nothing below needs a game, except building.

```bash
python -I run_all_tests.py              # ALL OK: relay, pack tool, mod compile checks
python -I server/run_tests.py           # the relay alone, 13 cases
python -I tools/godotpck/run_tests.py   # the pack tool alone
```

With the game installed:

```powershell
python build\build_mod.py `
    --install "<game dir>" `
    --out .\build\out
```

`<game dir>` is the folder holding `CityGameStudio64.exe` and `data.pck` — for a Steam library that is
`...\steamapps\common\City Game Studio`.

That writes a **complete copy** of the game into `build\out` with the mod injected, and verifies the
pack's MD5s, the autoload entry and every mod file after writing. The retail install is opened
read-only and never written to.

Then:

```powershell
.\tools\run-coop.ps1 -Name K1 -Port 8330
```

starts the relay, waits for the host to load a world, then starts the client. Three logs land in
`build\out\coop\`.

---

## Things that will bite you

Every one of these was paid for with a session that produced nothing.

| Trap | What actually happens |
|---|---|
| Adding `TCPServer` to a mod script | It is not in this engine build. Naming a missing class is a **compile error**, and a `.gd` that fails to compile keeps running its *previous* version silently — so the symptom is "my fix did nothing". |
| `Dictionary.get()`, `Object.get()`, `Array.to_json()`, `Array.extend()` | Also absent. They are `Invalid call` at runtime, or a hard crash inside the engine, not an error you can catch. |
| A 0xc0000005 with no message | A Variant member that does not exist. The faulting offset `0xae5633` is the member call, not your code. Disassemble it: `cmp esi, dword ptr [rdi + 0x38]` inside `_VariantCall::FuncData::call`, where `rdi` is a lookup that came back empty. The offset names the *kind* of fault, never the member — that has to come from the log. |
| Rewinding the date model | `models/date.gd` queues `end_of_week`/`month`/`year` as the date crosses, and emits one per frame; `set_raw_date()` touches neither the queue nor `_tick`. A client pulled back a week replays that boundary and dies at `0xae5633`. Every backwards move must call `__discard_overshoot()`. `build_mod.py check_date_rewind()` enforces it. |
| Starting the client first | The client reaches the New Game dialogue and plays its own world. The host must be serving a world before the client starts; `run-coop.ps1` waits for that. |
| `-WindowStyle Minimized` | Kills the host at ~14 s inside `RichTextLabel::Line`. Not a mod bug. Use a normal window. |
| A popup is open | The game's clock freezes while any popup is up (`controllers/date.gd`). A stuck date is usually one popup away from moving. |
| `File.open(path, READ_WRITE)` on a missing file | Fails silently. This is why remote answers are written into the log rather than a side file. |
| Pressing a node found by name alone | Three nodes are called `release`. Use `findall` to get names *and* rects. |
| Trusting a test that ran to completion | A crash leaves a log that ends in ordinary work. Test runs now end when a peer dies. |

---

## Credit and licence

The engine's pack format and settings blob are handled by
[`tools/godotpck`](tools/godotpck/README.md), from the
[Co-op Anything](https://github.com/cranebeaker/coop-anything) hub, vendored here so this repository
stands alone. The findings it was built on are that hub's
[City Game Studio write-up](https://github.com/cranebeaker/coop-anything/tree/main/games/city-game-studio).

MIT — see [LICENSE](LICENSE). Nothing here contains game files, assets, saves, or decompiled binaries.
Build on and patch your own copy; follow its licence.
