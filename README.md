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
| **Playable** | A host and a client join, boot the same world, and each runs a company. Both appear in each other's rival list by name, with their own money, offices and released games. Time is the host's; a client cannot move it alone. Money, technology and a game's IP can be handed to the other player and both sides agree. When the host leaves, the client is told on screen, saves, and is returned to the main menu. A returning player is handed their company and their office interiors back. |
| **Only tested by a machine** | Everything above is asserted by an in-game suite (`--coop-verify`) on both machines and by 12 relay cases. What has *not* been looked at by a human is the publish-offer list, the console panel and the map. Release from the UI is **unconfirmed**: the button fires and spends money, but nobody has watched the project leave `HOLD`. |
| **Not done** | Split screen. A lobby. Three or more players at once (the protocol is host-plus-N, but only two have ever run). Rejoining mid-session without a fresh world transfer. Steam invite/friends list — joining is a typed address today. |

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
python -I server/run_tests.py           # the relay alone, 12 cases
python -I tools/godotpck/run_tests.py   # the pack tool alone
```

With the game installed:

```powershell
python build\build_mod.py `
    --install "B:\Steamlibrary\steamapps\common\City Game Studio" `
    --out .\build\out
```

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
| A 0xc0000005 with no message | A Variant member that does not exist. The faulting offset `0xae5633` is the member call, not your code. |
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
