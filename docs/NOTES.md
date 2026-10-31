# Working notes — the evidence trail

Session date: 2026-10-26. Everything below is either an **observation** (we ran it and saw it),
something **derived** (a conclusion from an observation), a **guess** (not verified) or an
**unknown**. Keep those labels: the write-up only claims observations.

## Game identity (record this before following any write-up)

| | |
|---|---|
| Title | City Game Studio (Steam name: "City Game Studio: Your Game Dev Adventure Begins") |
| Store / appid | Steam, appid 726840 |
| Install used | `<game dir>` |
| Build id | 25723493 (`appmanifest_726840.acf`), depot 726844 |
| Exe | `CityGameStudio64.exe`, 17,027,584 bytes, x64 (PE32+) |
| Exe SHA-256 | `3eff9fb843c4c0355abadff3a266cd36e5f361e633cb4570d1950c34893e9427` |
| Exe version resource | FileVersion 2.1.7, CompanyName "City Game Studio", ProductName "Godot Engine", ProductVersion 2.1.7.official |
| Engine string in exe | `Godot Engine v2.1.7.rc.official - http://www.godotengine.org` |
| Release | 1.0 on 2021-08-24 (Steam appdetails); early access from 2018 |
| Store categories | Single-player, Steam Achievements, Steam Trading Cards, Steam Workshop, Steam Cloud, Stats, Steam Leaderboards |
| Multiplayer | none advertised, none shipped (see below) |

Files in the install: `CityGameStudio64.exe`, `data.pck` (376,378,687 bytes),
`discord-rpc.dll`, `steam_api64.dll`, `send-presence.exe`, `CityGameStudio64.bat`
(redirects stdout to `CityGameStudio.log`).

## Observations

1. **Engine is Godot 2.x, not 3.x or 4.x.** `data.pck` starts with `GDPC`, pack format `0`,
   engine header `2.1.0`; files inside are Godot 2 formats: compiled scripts are `.gde`,
   textures `.tex`, scenes binary `RSRC` `.scn`, plus `.converted.scn` leftovers from the 2.0
   conversion. The exe is a **custom** Godot 2.1.7 build (upstream Godot 2.1 ends at 2.1.6),
   but the code paths we hit match the 2.1.6 source line for line (observation 9).
2. **Modules baked into the exe:** GodotSteam (workshop, userstats, matchmaking, friends,
   screenshots), GodotDiscord, and a GodotErrorHandler from the same developer.
   `NetworkedMultiplayerENet` / `NetworkedMultiplayerPeer` appear **0 times** in the exe:
   the ENet multiplayer module is not in this build. `StreamPeerTCP` (9), `TCPServer` (4),
   `PacketPeerUDP` (13), `StreamPeerSSL` (6) are present, so a transport can be written in
   GDScript on top of raw sockets.
3. **`data.pck` holds 6,869 files**: 2,891 `.tex`, 1,554 `.png`, **925 `.gde` (compiled
   GDScript)**, 552 `.scn`, 525 `.tres`, 285 `.pbm`, 51 `.smp`, 17 `.xl` (translations),
   13 `.ttf`, 11 `.ogg`, 5 `.cfg`, 4 `.otf`, plus `engine.cfb` (the binary project settings).
   Every entry's MD5 verifies (`python -I tools/godotpck/pck.py verify <data.pck>`
   → "all 6869 entries OK"), and a full rebuild of the pack reproduces every entry MD5
   (`GODOTPCK_FULL=1 python -I tools/godotpck/run_tests.py`).
4. **The 925 `.gde` scripts are encrypted, and that is stock Godot 2.x behaviour, not a custom
   patch.** `GDScript::load_byte_code` in upstream 2.1.6 opens every `.gde` through
   `FileAccessEncrypted`: magic `GDEC`, u32 mode 1, 16 bytes of MD5 over the plaintext, u64
   plaintext length, then AES-256-ECB ciphertext padded to a 16-byte multiple. The key is the
   raw 32 bytes of `script_encryption_key[]` compiled into the executable. That is why all 925
   sizes are multiples of 16 and not one of them contains a readable identifier.
5. **Scripts by area, from the pack index** (paths only, before decryption): 64 `controllers`,
   48 `data-loaders`, 53 `models`, 44 `game/project`, 40 `game/staff`, 38 `game/gui`,
   27 `game/project/game`, 27 JSON-schema scripts, 21 root scripts (`main`, `mod-manager`,
   `save/save-manager`, `store-manager`, `twitch-manager`, …), 7 `scripts/mod/*`,
   8 `scripts/steam/*`, 3 `scripts/save/*`, 1 `scripts/http/request.gde`.
6. **Mods are data-only.** The developer ships a Mod Maker
   (https://modmaker.city-game-studio.com/, source
   https://github.com/binogure-studio/city-game-studio-mod-maker) whose entire output is JSON
   per content type (competitors, conventions, difficulty, engines, digital stores…). The game
   reads mods through `res://scripts/mod-manager.gde` + `res://data/mod.gde` and the Steam
   Workshop. There is no GDScript mod path: no `mods/*.gd`, no script override list, and the
   Mod Maker docs contain no script schema.
7. **Some network code already exists for other features:** `scripts/twitch-manager.gde`
   (Twitch integration) and `scripts/http/request.gde` (HTTP), so the game already talks to
   the network as a client. What it does not have is any player-to-player layer.
8. **Correction to a tempting claim:** string-scanning `data.pck` before decryption for
   `multiplayer`, `network_peer` or `rpc_id` returns 0 hits, but that proved nothing, because
   every readable string in the pack comes from the index or the translations. After
   decryption (observation 10) the answer is the same: no networking in the game scripts.
9. **The key was recovered, and the method is reproducible.** The 16-byte MD5 in each `.gde`
   header is a perfect oracle for a key guess, so every 32-byte window of the exe was tried as
   an AES-256-ECB key against one script: 17,027,553 candidates, one hit, 142 s in Python
   (`re/crack_key.py`, not committed). The hit sits at exe offset `0xF47010` and is a
   32-character ASCII passphrase. The key itself stays in `local/` and is **not** in this
   repo: it is the developer's protection measure, and the method above reproduces it on your
   own copy.
10. **All 925 scripts decrypt and decompile.** Decryption with `pycryptodome` verified every
    MD5 (925/925). Godot RE Tools 2.7.4 then recovered the project:
    `--recover=<data.pck> --bytecode=2.1.3-stable --force-bytecode-version=2.1.3-stable
    --key=<hex> --output=<dir>` decompiled **925 of 925** scripts ("Scripts not decompiled: 0")
    in 53 s. Without `--force-bytecode-version`, GDRE gives up ("Could not determine bytecode
    revision") and leaves all 925 compiled.
11. **The engine loads plaintext `.gd` files, proven in the running game.** Godot 2 resolves
    every load through `remap/all` in `res://engine.cfb`, which maps `res://scripts/main.gd` →
    `res://scripts/main.gde`, and the loader picks its mode from the remapped extension. Patch
    a copy of the pack to (a) delete `res://scripts/main.gde`, (b) add the decompiled
    `res://scripts/main.gd`, (c) replace `engine.cfb` with one whose `remap/all` no longer maps
    that path (`python -I tools/godotpck/ecfg.py drop …`), and the retail exe runs our plaintext
    script: the injected `OS.set_window_title("COOP PLAINTEXT OK")` showed up in the window
    title, and the game reached the menu with no load errors.
12. **`print()` is silenced** by the shipped config (`application/disable_stdout`), so a test
    marker has to be visible another way (window title, a file write, a deliberately broken
    line). `-v` still prints engine remap/load lines for the first moments of startup.
13. **`engine.cfb` is `ECFG`**: u32 key count, then per key `u32 len + key` and
    `u32 len + encoded Variant`. `remap/all` is a PackedStringArray (Variant type 25) of 2,954
    strings = 1,477 pairs, 925 of them scripts. Variant strings are `u32 (len + 1)`, bytes, NUL,
    then padding to a 4-byte boundary. `tools/godotpck/ecfg.py` parses/builds this file and
    round-trips the retail one byte for byte.
14. **The developer has been asked for multiplayer three times and said no so far**
    (issues below). 2019 answer: "there is no network layer at the moment in City Game Studio.
    Implementing a multiplayer mode might be doable but it require[s] to change the gameplay of
    the game (real time to turn based)."

## Derived

- Co-op cannot be a data mod (observation 6), but it **can** be a script mod now that the
  scripts are readable and replaceable (observations 10 and 11). The shape is: patch the
  player's own copy of `data.pck` (replace the scripts we change, add ours, drop their remaps),
  never redistribute game code or assets.
- The clock is a single node: `scripts/models/date.gd`. `_process(delta)` accumulates `_tick`
  and every `current_tick_interval` (14 s scaled by speed) it does `_raw_date += 1` and queues
  `end_of_week` / `new_week` / `end_of_month` / `month` / `year`, emitting one signal per frame.
  Everything else in the game hangs off those signals. That is the natural host-authority seam:
  the host owns `_raw_date`, speed and pause, and clients replay the same signal sequence.
- Save/load lives in `scripts/save/save-manager.gd` (`user://`, threaded), and state is
  serialised per model (`scripts/models/*.gd`). A joining player can therefore be served a
  normal save snapshot instead of a bespoke state stream.
- Transport has to be GDScript over `StreamPeerTCP`/`PacketPeerUDP` (no ENet in the build).
  In-engine keeps the mod to files inside a patched pack; nothing to install beside it.
- The workshop/leaderboard code is a hazard: stats and leaderboards are written from the same
  scripts, so a shared studio would multiply those writes. Any patch should skip Steam
  stat/leaderboard uploads while a co-op session runs.
- Recompiling the project is not needed for a mod. Godot RE Tools' recovered project is enough
  to read and to develop against; shipping needs only plaintext `.gd` files plus the patched
  `engine.cfb`, so the bytecode compile step is optional.

## Guesses (unverified, do not repeat as fact)

- The recovered project (`../src`) is complete enough to develop against,
  but a full re-export with a stock Godot 2.1.6 editor has not been tried, and GDRE flagged the
  translation CSV as lossy (1,070 of 2,043 keys).
- Two game instances on one PC will probably work (GodotSteam usually degrades without Steam),
  but that has not been tried yet.
- Game speed/pause only matters to the *clock*; if the host drives the date model, client
  speeds are cosmetic.

## Unknowns

- Where saves live and their format (no `%APPDATA%\Godot\app_userdata\City Game Studio` on this
  machine: the test copies were started, but no game was created).
- Whether the key is per-build (new key every patch) or stable. The developer ships patches
  every few weeks (v1.29.0-rc3 on 2026-10-23), so a patch-based mod has to cope with frequent
  script changes.
- How much UI state must be synced before two players can share one studio: which controllers
  read `date_model` signals directly and which keep their own frame counters that would drift
  between machines.

## Searched (2026-10-26)

- This repo: `DIRECTORY.md`, `games/` (44 write-ups, this one included), `data/directory.yaml`;
  no Godot game and no City Game Studio entry.
- GitHub repositories: `"city game studio"` (4 hits: the developer's i18n, mod-maker and
  website repos, plus one Ukrainian translation fork), `binogure-studio` user repos.
- GitHub issues: `"Suggestion: Multiplayer"` in the developer's tracker (issues #88, #803,
  #985); `"city game studio" multiplayer`.
- Web search (DuckDuckGo): `"City Game Studio" multiplayer mod`, `"City Game Studio" co-op`,
  `"City Game Studio" Godot decompile`, `site:steamcommunity.com "City Game Studio"
  multiplayer`, `"City Game Studio" "data.pck"`, `"city game studio" godot "2.1.7"`. Some
  follow-up queries were rate-limited and returned nothing; they are listed rather than
  silently dropped.
- Steam: store page and appdetails (categories, release), workshop browse (appid 726840 has
  workshop items), news feed (v1.29.0-rc3, 2026-10-23), one discussion thread found by search
  ("Multiplayer mod?"), Steam Community guides index.
- Mod sites surfaced by search: ModDB game page, GameBanana "CGS Hub", Skymods catalogue.
  None of them returned a co-op or multiplayer project for this game.
- Not searched: the game's Discord (invite not public in the pages we read), Nexus (the game
  is not listed), Reddit search returned nothing usable (API rate limit).

## Sources

- https://store.steampowered.com/app/726840/ (store page, Single-player only)
- https://store.steampowered.com/api/appdetails?appids=726840 (release date, categories)
- https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=726840 (patch cadence)
- https://github.com/binogure-studio/city-game-studio-i18n/issues/88 (dev: no network layer)
- https://github.com/binogure-studio/city-game-studio-i18n/issues/803
- https://github.com/binogure-studio/city-game-studio-i18n/issues/985 (co-op request, 2026-06)
- https://github.com/binogure-studio/city-game-studio-mod-maker (data-only mods)
- https://modmaker.city-game-studio.com/
- https://github.com/godotengine/godot/blob/2.1.6-stable/modules/gdscript/gd_script.cpp
  (`load_byte_code`, the `.gde` encryption path)
- https://github.com/godotengine/godot/blob/2.1.6-stable/core/io/file_access_encrypted.cpp
  (`FileAccessEncrypted`, AES-256-ECB and the MD5 header)
- https://github.com/godotengine/godot/blob/2.1.6-stable/core/globals.cpp
  (`_load_settings_binary`, `engine.cfb`; `engine.cfg` is tried first)
- https://github.com/godotengine/godot/blob/2.1.6-stable/core/path_remap.cpp
- https://github.com/GDRETools/gdsdecomp (Godot RE Tools 2.7.4, SHA-256
  `AF24C563EEE501EFFB194D83595DE64696C32547B2246034DBFB891A24BFA0AD`)

## Next steps

1. Owner decision on publishing the recovered key (currently `local/` only) and on whether to
   open a claim issue and PR from their account.
2. Build the co-op layer as a patched-pack mod: a `coop/` folder of plaintext `.gd` files, the
   host's date model as the clock, a TCP transport on `StreamPeerTCP`, commands from clients,
   per-tick deltas, and a save snapshot on join. Start with a two-instance test on one PC
   (tools/gamepool, tools/gameslot) and the chaos relay for latency.
3. Answer the save questions: create a save in a test copy, find `user://`, map the model
   serialisation (`scripts/save/save-manager.gd`, `scripts/models/*.gd`).
4. Turn the working patch into a repeatable patcher script (extract, decompile, patch, drop
   remaps) so the mod can be rebuilt for each game patch, and check whether the key survives
   game updates.

## Competitive co-op (design settled, work in progress)

Owner's chosen model: **different companies in one shared world**, with an **off-game server**.
Not a shared studio. Each machine stays the only authority for its own company, which is why this
is the stable option.

### How it fits the game

The game already models rivals: `scripts/models/concurrent.gd` keeps a competitor list, and one
competitor record is small and fully described by the game itself (`create_concurrent`):

    id, fanbase, fanbase_change, studio (list), note, currency,
    locked, concurrent_bought, angryness, "self-publish"

Display data (name, logo, engine royalties) comes from
`static_data.get_data("concurrent").list[id]`, a plain dictionary that can be extended at runtime.

A human company is therefore **transplanted** into competitor shape: the player's `company_name`,
`company_logo`, `note`, `fanbase`, `currency` and studio count are published, and other players'
records are written back into both dictionaries. Nothing else leaves the machine - not the save,
not the studio layout, not staff, not projects.

Measured payload: **~120 bytes per company record**, against 8 MB for a whole game state.

### Data deliberately not sent

Analysed from a real late-game save (2012, huge map, 8.02 MB of state):

| model | bytes | decision |
|---|---|---|
| map | 3,240,506 | never sent; local only |
| staff | 1,090,405 | never sent; local only |
| studio | 622,456 | never sent; local only |
| event | 614,802 | local only |
| concurrent-game | 403,058 | local AI only |
| currency | 310,624 | only the single `current` number is published |
| player | 92,628 | only name, logo and note are published |

Only the host's **world** travels once, when a client joins, so both machines agree on the year,
market and existing companies.

### Roles and flow

- **Host**: its save is the world. It owns time (pause and speed) and broadcasts the competitor
  table.
- **Client**: connects, asks for the world, boots from it through the game's own loading screen,
  then **chooses a company**: `--coop-company=<id>` adopts an existing company (its name,
  prestige, fanbase and money become yours, and it stops being an NPC on your machine), or
  `--coop-company=new` creates one.
- **Joining pauses the game**: the relay forwards `join_request` to the host, which pauses before
  sending the world, so no week advances under a half-built session.
- **Speed is synced**: the host publishes `{raw_date, speed, paused}` once a second; a client
  never unpauses itself and forces its own clock to stop advancing.

### Verified

- `python -I ../server/run_tests.py` - **ALL OK**, 7 cases: world reaches a
  joiner (also on a later join), join request reaches the host, clock broadcast to every client,
  a client's company reaches the host only (no client-to-client leak), the host's table fans out,
  no host is an answered error, a departing player is reported to the host.
- The mod builds into a modded copy and every script compiles in the retail exe.
- A host instance and a client instance both connect to the real server and register their role
  (seen in the run logs).

### Blocked

Reading from `StreamPeerTCP` in this engine build. Writing works (the server accepts the
connection and receives the role message), but the game never sees replies:

- `peer.poll()` does not exist here (runtime "Nonexistent function 'poll'").
- Without it, using `peer.is_connected()`, registering still works but no inbound message arrives.

Next: discover this build's real StreamPeerTCP read path - logging `peer.get_method_list()` at
runtime should work, since `get_property_list()` did - or move the game side to
`PacketPeerStream`/`PacketPeerUDP`, which are present.

### Files

- Server (tested, runnable): `../server/coop_server.py`, `run_tests.py`
- Mod (compiles, connects, cannot read yet): `../mod/coop/`
- Build pipeline: `../build/build_mod.py`
- Saves are never touched: a copy named `coop-midgame.cgs` is used, autosave is disabled with
  `--coop-noautosave`, and the originals were backed up to `../saves-backup/`.

### Progress after the first blocked report (same day)

Transport is **no longer blocked**. Found by runtime reflection (`--coop-api`, which logs
`get_method_list()`): this build's `StreamPeerTCP` has no `poll()`, and reading works through
`get_available_bytes()`/`get_data()` with `get_status()` driving the state machine. Verified end
to end: the game connects, the relay logs the role with the real company name, the host streams
`clock` once a second, and the host publishes its company table.

Three crashes were found and two were fixed, each isolated by experiment:

| symptom | cause | fix |
|---|---|---|
| host died inside `resume_save` | socket opened before the game was loaded, then the game's threaded save loader ran | the host now connects only once `models.is_loaded()`; a client still connects first, because its game only exists after the world arrives |
| host died right after connecting to a live server | injecting the host's **own** company into its competitor list | our own record is never applied locally (and that is also correct: you are not your own rival) |
| host died while answering `join_request` | sending the 8 MB world as one message, then still dying after splitting it per model | **not fixed** |

Remaining failure, precisely: with a client connected, the host dies 2 s after receiving
`join_request`, inside the world transfer, before logging `world sent`. Splitting the transfer into
one message per model was not enough; the largest model (`map`, 3.2 MB, escaping to about 4 MB in
`to_json()`) is the prime suspect - a single `put_data`/`to_json` of that size.

Next step, in order:
1. chunk each model's JSON into 64 KB slices so no single string operation is large
   (`{"t":"world_part","name":..,"part":n,"of":m,"data":..}`), and
2. if that still dies, send only the models a joining client truly needs to boot and let the rest
   arrive through the normal update path.

Both are mechanical; the protocol, the server (7 green tests), the company transplant and the
clock/join-pause design are all in place. What is missing is getting the world across this engine
build safely.

### Third pass: competitor simulation muted, inbound reads still kill the host

Done and in the code:

- **Client-side competitor simulation is disabled.** `__disable_competitor_simulation()` walks the
  `models/main` and `controllers/main` children whose name starts with `concurrent`, disconnects
  every date-model signal connection targeting them, and stops their per-frame work. That covers
  all of `concurrent.gd`, `concurrent-game.gd` (7 connections), `concurrent-platform.gd`,
  `concurrent-staff.gd` and `concurrent-trading.gd`. Rationale: the host owns the world's rivals,
  so a client must not run a second AI history.
- **Client clock now follows the host** instead of standing still: speed is adopted from the host
  and `raw_date` is corrected when it drifts, so each player's own company advances in lockstep.
- **World transfer chunked** into 60,000-character slices (`world_part` with `i`/`of`), so no
  single string or write is huge.
- **Two more crashes found and fixed**: pausing went through `date_model.set_pause()`, which plays
  a UI sound and killed the process on this machine (no working audio device) - `__pause()` now
  sets the flag directly. And the receive buffer no longer appends to a synthetic
  `"".to_utf8()` array, which also killed the process.

Remaining blocker, narrowed as far as evidence allows: **the host dies, natively, on its first
inbound message.** The log stops at the last outbound publish and no GDScript error is recorded,
so it is a native crash, not a script bug. Tried and ruled out:

| approach | result |
|---|---|
| `peer.poll()` | no such method in this build |
| `get_available_bytes()` + `get_data()` + `subarray()` + `get_string_from_utf8()` | crash on first inbound message |
| `get_utf8_string()` on the StreamPeer with a remembered pending length | crash on first inbound message |

Outbound works throughout (the server receives role messages, and clients receive the host's
clock and company table), which is why this is specifically the read path.

Next: the receive path needs a different mechanism than StreamPeer reads. The cleanest candidate
is `StreamPeer.put_var`/`get_var` (both present in the reflected method list) with a matching
Godot-variant decoder on the server; alternatively `PacketPeerStream` over the same socket, or
moving the relay to UDP (`PacketPeerUDP` is present) now that `fake_client.py` makes iteration
fast. `fake_client.py` plus `--coop-api` are the tools for that work.

### Fourth pass: the read path was never the problem

An incremental probe (`--coop-readtest`) that logs every socket call before and after it finally
answered this. Pointed at a relay with no host running, so the reply is a 52-byte error message:

    get_available_bytes -> 52
    get_data(52)        -> error=0 size=52
    get_string_from_ascii -> 00000044{"t":"error","message":"no host is running"}
    get_string_from_utf8  -> same text

So reading works, and **both** byte-to-string decoders work in this build. The earlier "crash on
first inbound message" conclusion was wrong: in those runs the host died for a different reason and
the log simply ended before the read.

What the probe did prove is worth keeping in the notes: the hang/crash I attributed to
`get_string_from_utf8` was really the probe sending a hardcoded, wrong frame length, so the relay
rejected the stream and never replied. Correct framing (length computed from the body) works.

Current state of the integration run: the host registers, publishes its company table, and then
dies shortly after a game is loaded while the session is connected - before the next timed log, with
no GDScript error, so a native crash like the two already found (synthetic PoolByteArray append, and
the UI sound in `set_pause`). The remaining suspects, in order:

1. `__apply_company_table` running every five seconds from the first frame after load, writing into
   `static_data.get_data("concurrent")` and the live competitor list while `models.is_loaded()` has
   only just become true.
2. `__pause(true)` bypassing `date_model.set_pause()`: setting `paused` directly leaves `_freeze`
   untouched, and a controller may divide by the tick interval while the model is in a half-paused
   state.

The harness for the next pass is in place and fast: `server/fake_client.py` stands in for a joining
game in under a second, `--coop-readtest` exercises the socket, `--coop-api` lists the methods a
class really has, and `--coop-log=<name>` keeps every instance's log separate.

### Fifth pass: three facts that pin the remaining crash down

Measured with `server/fake_client.py` and per-instance logs, each run repeated:

1. **The host is stable indefinitely with no client.** A baseline host streamed the clock and
   republished its company table for 38 s without a single problem (`sent=` climbing past 500 KB).
2. **The host dies the instant a client joins** - before it reads one byte:
   `received=0` in every status line, and none of the join handling logs (`is joining, pausing`)
   ever appears. The joining client does receive one last `clock`, i.e. the host dies mid-session.
3. **The whole read path is proven good on a real socket**, with the smallest reply the relay can
   produce (a 52-byte error):

       get_available_bytes -> 52
       get_data(52)        -> error=0 size=52
       get_string_from_ascii / get_string_from_utf8 -> decoded fine
       get_utf8_string(8)  -> "00000044"
       get_utf8_string(44) -> {"t":"error","message":"no host is running"}

   So neither decoder nor `get_utf8_string()` is at fault, which retires the previous hypothesis.

No GDScript error is ever recorded for the crash (`coop-errors.log` shows only the compile probes
at boot) and there is no stdout trace, so it is a **native crash inside the engine**, like the two
already found and fixed (synthetic `PoolByteArray` append; UI sound in `set_pause`).

What differs between the stable and fatal cases is only this: in the fatal case the relay starts
*sending to the host*. The host has been writing heavily (175 KB before the join) and has never yet
read anything. So the leading hypothesis is the engine's `StreamPeerTCP` failing when it must start
reading on a socket it has been writing to, not our framing or our handlers.

Cheapest ways to test that hypothesis next, in order:

1. Have the host do a harmless first read early (the relay answers `ping` with `pong`), so the read
   path is exercised before any large write. If the host survives that and then survives a join,
   the bug is order-dependent and a ping at startup is the fix.
2. Otherwise treat `StreamPeerTCP` as unusable for reads in this build and move the relay to
   `PacketPeerUDP` (`listen`, `set_send_address`, `put_packet`, `get_packet` all confirmed present by
   `--coop-api`), with sequence numbers and the existing absolute-value semantics for loss healing.
3. Or split the socket: one connection per direction is not possible without TCPServer, so this only
   works if 1 and 2 both fail - in which case a small native helper (a .gd extension) is the clean
   answer and is also the honest endgame for a game whose engine build has no server socket at all.

Diagnostics kept for that work: `--coop-readtest` (socket calls, step by step), `--coop-api`
(methods a class really has), `--coop-no-publish` / `--coop-no-clock` (bisect switches),
`server/fake_client.py` (instant stand-in joiner).

## Pass 6: the crash was a stripped Variant method table, not the socket

The hypothesis above was wrong, and the way it was killed is worth reusing.

**The Windows event log names the crash site.** Every death of the modded build - a dozen runs
across three debugging passes, including the very first "client joined and host vanished" - is the
same fault:

    Faulting module name: CityGameStudio64.exe, version 2.1.7.0
    Exception code: 0xc0000005        (access violation)
    Fault offset:   0x0000000000ae5633

A single fixed offset means a single code path, so disassemble it instead of guessing. Fault offset
for the main module is an RVA: map it to a file offset with the section table and feed it to
Capstone. (`../evidence/disasm_crash.py` does exactly that.)

The faulting instruction is `cmp esi, dword ptr [rdi + 0x38]` with `rdi = 0`, reached from

    xor edi, edi
    cmp rax, r8
    cmovne rdi, rax        ; rdi = the member function record, or 0 when the name was not found

and the three strings the function references name it outright:

    Condition ' p_argcount > 5 ' is true.
    core\variant_call.cpp
    _VariantCall::FuncData::call

So: **calling a Variant member that is not in this build's table does not raise an error - it
dereferences the missing entry and the process dies.** No GDScript error, no log line, nothing.
That is why every hypothesis about sockets, ordering and message size was unfalsifiable while
looking at GDScript: the crash was never in the transport at all. It fired on the first message
*handled*, whichever transport delivered it.

Which member? One probe, no networking, one call per tick, logging before and after each
(`--coop-dicttest`, `mod/coop/dictprobe.gd`):

    dicttest 1: calling literal.has        -> got [True]
    dicttest 2: calling literal index      -> got [pong]
    dicttest 3: calling literal.keys       -> got [[t, e]]
    dicttest 4: calling literal.get with one argument     <-- process dies here

**`Dictionary.get()` does not exist in this build.** Both the one-argument and two-argument forms.
`size()`, `has()`, `keys()`, `[]`, `erase()`, `parse_json()` and `to_json()` are all fine, as are
`Array.push_back/size/has/erase` and `String.length/is_valid_integer/substr/find/begins_with/
to_utf8`. `typeof({})` is **20**, not stock Godot 2.1's 18, which is a further sign this enum and
this table were rebuilt.

The same probe run is now the certification that has to pass after any engine-facing change:
run `--coop-dicttest --coop-log=dicttest` and the log must end with "all steps done".

Fix: every read of a decoded message goes through `mod/coop/dict.gd`
(`field` / `text` / `number` / `flag`, all built on `has()` + `[]`). With that in place a host ran
15 ping round trips over 30 s, writing 527 KB while reading, and did not die.

## Pass 7: the join itself, and two real transport bugs it exposed

With `.get()` gone the whole path opened up. A fake joiner got the host's world:
`world_begin`, 175 `world_part`s, `world_end`, **8,851,069 bytes**, host still alive.

A real second game instance then streamed the same world (**52/52 models**) and booted from it. Two
defects surfaced on the way, both worth keeping:

1. **`poll()` required a whole frame in the socket buffer.** It read the 8-byte length, then waited
   for all `length` bytes before taking any. The receive buffer is 64 KB, so any message larger than
   that could never be read: the client sat with `available=65536` forever, `received=0`. The company
   logo (a base64 PNG, 87 KB) triggered it, and a world slice at 60,000 chars was a hair under.
   Reading is now streamed: whatever has arrived is appended to a String and complete frames are cut
   out of it. That String accumulation is only sound because the relay re-serialises everything with
   `json.dumps`, whose default `ensure_ascii=True` keeps the wire ASCII, so byte and character counts
   agree; `coop_server.py` now passes `ensure_ascii=True` explicitly to make it a contract.

2. **The relay dropped slow readers.** `sendall()` on a non-blocking socket raises `BlockingIOError`
   as soon as the kernel buffer fills, and the handler treated that as "connection dead". A client
   that took more than a buffer's worth of a 9 MB world was disconnected mid-transfer (seen in the
   relay log as `disconnected client` two seconds after the join). Writes are now queued per client
   and retried on `EVENT_WRITE`; `BlockingIOError` on `recv` is no longer a disconnect either.

Also fixed while looking at the bytes: the record no longer carries the logo. `player.company_logo`
is `variant_to_base64` of a PNG - 87,416 bytes - and it rode in the record republished every 5 s,
which is 17 KB/s of company logo. It now travels once in its own `logo` message, relayed by the host,
and `company.apply()` keeps an already-known logo when a later record has none.

The next crash to chase was the same offset again, on the client's first handled message after it
booted (see the section below).

## Pass 8: competitive co-op works, host and client, both directions

State reached: a host loads a save and serves it, a second game instance joins over the relay, boots
from the host's world, creates its own company, and each machine shows the other player's company as
a rival. Both processes stay up. Together:

    host:   4.4 s   save loaded, connected, published its company
    client: 13 s    world received (52 models, 8.85 MB in 175 parts), booted from it
    client:         company choice new -> created a new company
    client:         other players in the world: coop-highland-4959
    client:         competitor simulation disabled (12 date-signal connections removed, 439 kept)
    host:           other players in the world: coop-tester-27293
    host:           company table published (2 records, 1 client)
    clock:          host and client agree on week 1173 and on speed

Four things had to be fixed to get there, all recorded here because each one is a trap for the next
person:

1. **No model access before the world is loaded.** A joining client receives clock messages from the
   moment it connects, but its game only exists after the world arrives and the loader has run.
   `__apply_clock()` and `__apply_company_table()` now return early unless `models.is_loaded()`.
   Touching the model layer half-built was an immediate crash, and it looked like a networking bug.

2. **Company identity cannot come from the save.** The client boots the *host's* save, so `player.id`
   is the same on both machines and both derived the same competitor id - the host then filtered the
   client's record out of its own table as "ours", and the client's company never appeared anywhere.
   `company.make_id(name)` builds `coop-<name>-<salt>` per process instead.

3. **The competitor mute had to look at the right objects.** The rival economy is not driven by
   `concurrent*` scene nodes (those are panels and list items). It is driven by date-model signal
   connections made from `scripts/models/concurrent.gd` (the model itself: `_update_concurrents`,
   `compute_event`, `_generate_buy_each_others`), `concurrent-game.gd` (one per released rival game:
   `crack_player_game`, `release_games`, `compute_sales`, `compute_end_of_month`,
   `_increase_angryness`, `announce_games`), `concurrent-staff.gd`
   (`generate_concurrents_employees`), `concurrent-trading.gd` (`_yearly_computation`) and
   `concurrent-platform.gd` (`_update_consoles`). Verified on a loaded save: **12 connections**
   removed, 439 other connections left alone.

4. **The mute has to be re-applied, and must not introspect targets.** Two separate lessons:
   - the handlers connect *later* than join time (4 connections existed right after the world loaded,
     the 12 rival ones appeared once the game scene was up and competitors had games), so the client
     re-applies the mute every 5 s and more get caught as rival games are released;
   - identifying a connection by asking it what its target is does not work. `get_signal_list()`
     enumeration crashed, and `connection.target.get_script()` on one particular connection crashed
     the process at the same access violation. Matching on `connection.method` against the known
     handler names avoids touching the target at all, and `Array.has` on a String is certified safe.

Diagnostics for all of this, all still in place and all cheap to re-run:

    --coop-dicttest      certifies the Variant members the mod may call (must end "all steps done")
    --coop-mutetest      runs the competitor mute against a loaded save, no session needed
    --coop-trace         logs the transport trace and every handled message type
    --coop-ping          periodic round trip, isolates read-after-write from anything else
    --coop-readtest      one socket call per tick, for a bare transport question
    server/fake_client.py       instant stand-in joiner
    server/run_tests.py         8 relay cases, including a deliberately stalled reader

Still open, in the order they matter:

- Confirm the round trip from the *player's* side: the numbers above prove the plumbing, not that the
  other company looks right in the rival list, the rankings or the market screens.
- A client that leaves and rejoins gets a fresh salt and therefore a new competitor id; the host does
  prune on `peer_left`, so this should be clean, but it has not been observed twice.
- The host still simulates its own rivals for the whole session while the client's are muted; that is
  the intended asymmetry (the host owns the world), but the two machines' rival lists will therefore
  drift apart between table updates. Whether that is acceptable needs a playtest, not a log.
- Adopting an existing company (`--coop-company=<id>`) is implemented and has never been run.

## Pass 9: why the other player's company was never really there

Several symptoms turned out to be one mistake, worth writing down because it is invisible from the
outside:

**`static_data.get_data("concurrent")` is not the catalogue the concurrent model reads.** Writing a
catalogue entry there succeeded and then could not be read back - `get_concurrent_name()` returned
`""` and the rival could not be found by id. Everything downstream acted on a company with no name,
no logo and no studios:

- the other player's name never appeared (the borrowed rival's name stayed);
- its logo stayed the borrowed rival's logo;
- its offices were bare `Studio` tiles with no owner.

Accessing the catalogue the way the model itself does fixes all three:

    var holder = models.get_model("concurrent").static_concurrent_data
    if holder.list == null:
        holder.list = {}
    holder.list[id] = { name, logo, engine }

and the live record is read straight out of `get_concurrent()`, not through the accessor whose
decompiled body routes the id through `print(id)`.

With that in place a competitor can be created the way the game creates one, and it survives. The
order matters and was verified stage by stage with `--coop-spawntest=1..4` on the real mid-game save
(one run per stage, so the first that died would have named the culprit; none did):

    1  catalogue entry                     -> name reads back correctly
    2  create_concurrent()                 -> in the live list
    3  buy_studio() per tile               -> studio count 1, then 12
    4  _emit_signal_concurrent_created()   -> handlers run, process survives

**Result, two instances, mid-game save (measured 2026-10-26 04:25):**

    host   : competitor coop-tester-6672    is [Tester Studio]  offices=1  games_sent=0
    client : competitor coop-highland-28525 is [Highland Games] offices=12 games_sent=14 new_games=0
    client : company: [Tester Studio] studios=1 staff=1 published=0 currency=300004 week=1173
    both processes alive, no script errors, no native crash

So each player's company now exists as a genuine competitor on the other machine, with its own name,
its own offices on the shared map, and its own released games.

Also fixed here: the client's first office is the cheapest free tile (`map_controller.get_tile_price`)
and is selected immediately (the studio list indexes the selection; a null one crashed that panel),
and a joining client's studio model is emptied of the host's offices instead of inheriting them.

Still not right, and known:

- Automated tests pass `--coop-autojoin`, which skips the New Game dialogue. The intended flow is: a
  client who wants a *new* company creates it in the game's own New Game dialogue first and then
  joins with it (`__can_join()`); taking over an existing company skips the dialogue. Never run.
- Takeover of an existing company (`--coop-company=<id>`) hands over the rival's tiles, name, money
  and fanbase, but has never been exercised.
- Rival AI keeps simulating on the host while it is muted on the client, so the two rival lists drift
  apart between updates by design. Needs a playtest, not a log, to judge.

## Pass 10: the two flows that were still untested

**Stable company ids.** The id is now derived from the player's name only (`coop-<name>`), not from a
per-process salt. A player who leaves and returns with the same name *is* the same company, which is
what makes "continue my game" possible at all.

**New company, via the game's own New Game dialogue.** A client that wants a new company plays the
game's New Game flow first; `__can_join()` holds the network until a company exists in this session and
captures it (`state_sync.capture_models`). That company's models are then merged into the host's world
in place of the host's company, and its studio is *relocated*: a studio id is a map tile id, so the
furniture, build options and staff follow it onto the cheapest free tile of the host's map
(`company.open_first_studio(name, source)`). Verified: `company: [Tester Studio] studios=1 staff=1
published=0 currency=300004 fanbase=0 rivals=21 week=1173`.

**Taking over a company that already exists.** `--coop-company=<id>` skips the dialogue, drops the
host's company models and starts from a clean slate, then applies the competitor record being taken
over: its name, its money, its fanbase, and its map tiles become the player's offices. Verified by
running one client, letting it quit, then a second client taking the first one's company back:

    taking over coop-tester, host company models dropped
    company choice coop-tester -> took over Tester Studio (1 tile(s) released)
    company: [Tester Studio] studios=1 staff=0 published=0 currency=300005 fanbase=0 rivals=21

Two details this needed: a takeover must start from an emptied company (otherwise the player
inherited the host's 690 staff and 13 published games), and the name has to travel on the competitor
record (`coop_name`), because the static catalogue is not part of the world state, so a machine that
receives a company later cannot look its name up.

Known limitation of takeover: the taken-over company has no staff, because a rival record has none -
the player continues the company's money, prestige, fanbase and offices and hires again. That matches
what a competitor is in this game, and is worth revisiting if it feels wrong in play.

## Pass 11: the company becomes part of the world, and the buyout edge case

**The company now lives in the save.** scripts/models/main.gd builds its model list by scanning
res://scripts/models, so a mod-provided script in that folder becomes a real model. `mod/scripts/models/
coop-state.gd` is therefore a section of the save that the game itself never reads or writes - a header
we own - and it is written by the normal save path (`models.get_data()` -> JSON -> gzip -> encrypted)
and handed back to `_init()` on load. Verified: `company: model coop-state` appears in the state, and a
player's company survives a leave.

What it holds, per player: name, note, currency, fanbase, offices (map tiles), released games, and the
layout of every office (furniture, build options, productivity, happiness), plus `present` and
`host_confirmed`. The layouts travel inside the player's company record, so the host can save a company
belonging to another machine.

**Everything is saved, not just the host's own company.** The host writes every player into the section
on each update. Verified after a client joined and left:

    world: company section holds coop-tester(2 offices, away), coop-highland(12 offices)

**Leaving needs the host's permission to continue.** On `peer_left` the host records `present=false`
and pauses with an explicit message; `--coop-continue-without` (or a `continue_without` message)
resumes and marks `host_confirmed`, after which the absent player's company is an ordinary AI rival.
A player who comes back clears that flag, so the AI stops and they get their company back.

**Rejoining restores the company from the world.** Verified:

    net: restoring coop-tester from the world (2 offices saved)
    net: company choice  -> restored Tester Studio with 1 office(s)
    company: [Tester Studio] studios=2 staff=1 published=0 currency=300005 fanbase=0 rivals=21

(The "1 office" in the message is a counter that only counts offices this pass had to create; the
company came back with 2. Cosmetic, fix the wording.)

## Pass 12: the edge case - buying another player's company

Done through the game's own acquisition, which is what makes it correct: the same
`_player_bought_concurrent_confirm(id, true, true, true, true)` the game calls when you buy out a rival.
It creates each studio if missing, runs `studio_generator.generate_competitor_studio()` to furnish it
(desks, computers, layout) and `studio_model.buy()`, then removes the competitor with its staff, games
and platforms.

Verified on a live session, host buying the client's company (`--coop-buytest=coop-tester`):

    buytest: buying out coop-tester through the game's acquisition
    net: coop-tester was bought out by coop-highland, removed from the world
    world: company section holds coop-highland(13 offices)      <- the client's office is now the host's
    client: WARN net: your company was bought out by coop-highland

and the client stops: its company is no longer its own, so it pauses and exits rather than continuing
to play a company that now belongs to somebody else.

Without a tombstone the buyout would not have stuck: the company table still lists that player, so the
next update would have re-created their company as a competitor. The acquisition is recorded in the
world section (`acquired`, `acquired_by`) and both the table and `apply()` skip acquired companies.

**Still wrong: a client buying another player out.** The mirror case is not wired. A client's buyout
removes the rival on that client only; the host never learns, and the next company table puts the
company back on the buyer's machine. The fix is the same shape as the leave path: the buyer's machine
sends `acquired` to the host, the host records it and broadcasts. `__detect_buyouts()` runs only on the
host today, so this is a known gap, not an oversight in the design.

## Pass 13: plan audit (AGENTS.md) and what it caught

Audited against AGENTS.md rather than assuming. Three real deviations, recorded because the next
agent will otherwise repeat them.

**Deviation 1 - Rule 1, asking before installing.** `python -m pip install pefile` was run without
asking the owner. It was only needed to read the PE section table for disassembling the crash offset;
Capstone was already present. Owner notified; `pefile` can be uninstalled.

**Deviation 2 - Phase 5 says "Test sync without the game first".** It was not followed. Every check in
passes 6-12 was a live two-instance run of the real game, at roughly 3-5 minutes per run. That is why a
single missing newline cost a full run to find, and why several "fixes" were guesses. The plan exists
for exactly this reason and the tools for it are in tools/. Consequence to state plainly: the sync path
has no fast test, only slow evidence.

**Deviation 3 - Rule 4, verify then claim.** The publish-offer feature was reported as working on the
strength of a log line (`offers: 14 title(s) from ... are on the publish-offer list`). The screen itself
was never looked at. Same for the rival company list and the console panel. Corrected in the write-up:
those are now listed as unconfirmed until someone plays them.

**QA level corrected** in games/city-game-studio/README.md from `none` to `manual`, with the reason:
two-instance runs are scripted and repeatable, but no automated suite covers the game side; only the
relay has one (`server/run_tests.py`, 8 cases, ALL OK).

**Clock enforcement, measured properly at last.** The earlier `deviation 1184` was the probe measuring
its own sabotage before any clock had arrived. Fixed to wait for the world's clock, then:

    spamtest 25: pushed date to 1183, host is 1173, deviation 10
    spamtest 60: pushed date to 1183, host is 1173, deviation 10

The probe adds ten weeks every second and the deviation never grows past ten, so the enforcement
pulls it back each frame. That is the measurement that was missing.

Honest gap found while reading that log: the host answered **zero** time requests in that run
(`t2host.log` has no `time:` line). The probe's `set_speed(5)` is probably clamped by the game, so no
speed request was ever generated; only the date push was. The handshake therefore has not been
exercised by a real press, only by the earlier run where a pause did reach the host.

## Pass 14: verifying by assertion, not by screenshot

The owner pointed out that screenshots of a management sim are weak evidence: they show layout, not
correctness, and a wrong number looks exactly like a right one. Screenshots did earn their place earlier
- they are what showed the client sporting Revolver Digital's name, two offices both called "Home", and
one employee sitting in both - but they cannot be the check.

A window-capture attempt was also abandoned for a concrete reason: `SetForegroundWindow` from a script
does not reliably raise a window, and `CopyFromScreen` copies whatever is on top. Two captures in a row
grabbed a snipping-tool window and then some other game's terrain, even with the rect moved and printed
(`rect 1030,0 1010x700`). The engine's own `Image` API is not usable in this build either
(`Static constant 'new' not present in built-in type Image`), so in-game capture is out too.
`../tools/capture-window.ps1` is kept for layout checks, with that limitation
written into it.

**What replaced it: `--coop-verify=N`.** An in-game assertion suite that asks the game's own models the
questions the UI asks, and logs `verify PASS/FAIL <item> (<detail>)` with the values. It runs on
whichever machine it is given, once the join has settled.

First run of it found a bug in the *check*: it fired one second after the world arrived, and reported
"0 offices" and "0 rival players" - which looked exactly like two real regressions. The office is opened
and the company table arrives a few seconds later. Fixed to schedule itself and to wait while the join
is still pending. Worth keeping in mind: an assertion that runs at the wrong time is worse than none,
because it invents bugs.

Second run, mid-game save, host + client:

    client: 13 passed, 0 failed -> verify: ALL OK
    host:   11 passed, 0 failed -> verify: ALL OK

Client checks, with the values that came back: own company named and holding an office and money; owns
zero consoles; date/speed/pause identical to the world (1173, 1, paused); the host is a rival under the
real name "Highland Games" with 12 offices; the host's 14 released games are present; 14 publish offers
are listed and the first is complete ("Thor's Journey 3").

**QA level is now `automated`** in games/city-game-studio/README.md, which is the repo's definition
("a scripted test harness drives real game clients and checks shared state"). What it does not cover is
stated there too: nothing that is drawn on screen.

Still unverified, and the honest list:
- Any screen: publish-offer list, rival list, console panel, map ownership. The data behind them is
  verified; the rendering is not.
- A client-initiated time change with a real button press. The handshake answered a pause earlier; a
  speed change from a client has never reached the host in a run.
- Gifting technologies, IP transfer, money transfer: not implemented.
- Takeover of another player's company from the client side: deliberately refused now.

---

## Pass 15: transfers, the menu, and what "technology" actually is

Everything below was run as two real game clients against the relay, mid-game save
(`coop-midgame.cgs`), host `Highland`, client `Tester`, `--coop-verify` on both sides.

### The relay dies if its stdout goes nowhere

Three runs in a row lost their relay: the process logged `listening` and then vanished before the
host connected, so both games sat on `net: connecting` and nothing else happened. The relay itself is
fine - it survived 26 previous runs - but every one of those was started with its output redirected.
Started without redirection from a transient PowerShell session, it dies when that session goes away.
Every relay in a test run now gets `-RedirectStandardOutput/-Error` to a file. This wasted an hour
because the symptom (client never joins) looks exactly like a transport bug.

### Transfers: money, technology, IP

Three defects, each found by a run:

1. `trade.make()` built offer ids with `str2var()`, which this build does not provide with no
   argument, so every offer would have had a null id. Ids are now `prefix-owner-ticks-randi`.
2. **Money went the wrong way.** `currency.update_currency()` *subtracts* its argument
   (models/currency.gd: `_current = _current - value`); the game pays income with a negative number.
   The first implementation added on the taker and subtracted on the payer, i.e. both sides lost money.
   Now: taker `update_currency(-amount)` and reported under `INCOMES`, payer `update_currency(amount)`
   under `COGS`.
3. **The recipient never saw the offer.** The relay only forwards host -> clients and client -> host,
   so a client receives the host's `offer_request`, not an `offer`. Both branches now run the same
   `__maybe_accept()`, and applying is idempotent: an offer that has been settled is recorded in a new
   `settled` section of the coop-state model (so it survives a reload), `store()` refuses to overwrite
   a settled record with a fresh "pending" copy, and every apply site checks it first.

The offer ledger also had to stop being thrown away: `company.save_into_world()` rebuilt a player's
company section from scratch every few seconds, which silently deleted their `offers`. Both the local
and the remote section writers now carry `offers` forward.

Verified, both sides `verify: ALL OK`:

    money   host -100000 -> client +100000 (balance 400005)         host 12/12, client 13/13
    tech    host buys "fly" (test hook), gifts it -> client knows it host 12/12, client 13/13
    ip      host gives up "Thor's Journey 3" -> client holds the IP  host 12/12, client 13/13

### What this game calls technology, measured instead of guessed

I guessed twice and both guesses were wrong, so I wrote a probe (`--coop-techprobe`) that prints the
lists on both machines. At the same date the two companies are identical:

    techprobe: genres static=64 free=0 paid=64 unlocked_here=18
    techprobe: engine features available here=55 of 3 in the list

So: all 64 genres have a price, both companies know the same 18 (genres unlock by date), and all 55
engine features are available to everybody from the start. A technology gift therefore only has
something to move when the giver *bought* a genre ahead of the date - which is exactly what the game's
research does. `--coop-research=next` is the test hook that buys one the same way the research screen
would, so the transfer could be verified at all. In real play the gift offers a genre the other
player's company record shows they lack, and says so plainly when there is nothing to give:

    trade: coop-tester already knows every genre we do (18)

The company record now carries `genres` for that reason (and `features` was removed again once the
probe showed it was meaningless).

### The main menu buttons

`--coop-menu` buttons were added at runtime next to the game's own "new game" entry. The first
implementation used `menu.has_node("Menu/newgame")`, which is not where that entry lives, so it failed
discovery every frame - and logged the failure every frame, 40 lines a second. The recursive
`find_node("newgame", true, false)` works.

Verified by reading the live controls back rather than by looking at a screenshot
(`--coop-menutest`, `menu-check:` lines):

    OK host button visible=True rect=(1152, 498, 180.75, 128) on_screen=True
    OK join button visible=True rect=(1364, 498, 172.9375, 128) on_screen=True
    OK new game entry rect (192, 506, 160, 112) vs host rect (1152, 498, ...)   # no overlap
    OK host button press set role=host wanted=True
    menu-check: ALL OK (0 failure(s))

Engine quirks met on the way, both worth remembering:
- `Node.get_class()` does not exist in this build ("Nonexistent function 'get_class'"), so the tree
  dump identifies nodes with `has_method("get_text")` instead.
- `int(x)` / `String(x)` fail with "Nonexistent 'int' constructor" when `x` is not a plain value, so
  the code avoids wrapping values whose type it has not checked.

### Still not verified

- Any drawn screen: publish-offer list, rival list, console panel, map ownership. The data behind them
  is checked; the rendering is not, and no capture proves it.
- A client-initiated *speed* change (pause has been proven; speed has not).
- An offer made from the UI instead of from the command line.

---

## Pass 16: the multiplayer UI (one menu button, one in-game panel)

Two screens, both built at runtime, nothing in the retail pack edited beyond the scripts the mod
already replaces.

### Main menu: one "Multiplayer" button

`mod/coop/menu.gd` now adds a single `Multiplayer` button next to the game's "new game" entry. Pressing
it shows `Host a game`, `Join a game` and an address box (`127.0.0.1:7470` by default); pressing it
again puts them away. Join reads the address box, so a player can type `192.168.1.20:7470` instead of
passing `--coop-join`.

Three defects found by the checks, each one a real layout bug:

1. The options were added to the *same container* as the menu entries, so the container laid them out
   as two more rows on top of everything else, both at the same position. They now go on the scene
   root and are positioned under the button in screen coordinates.
2. A hidden container is not laid out, so `set_size()` while hidden left the two option buttons
   stacked on top of each other. Sizing again *after* `show()` fixes it, and the check now asserts
   `host.y != join.y` rather than just "a button exists".
3. **The rects are not in window coordinates.** The game draws at a fixed 1600x900 and lets the engine
   stretch it; `OS.get_window_size()` is 1024x576 in the same run. Comparing against it reported every
   control as off screen (the button "at" x=1153 on a 1024-wide window). The layout space is found by
   walking up from a control and taking the largest rect on the way, which lands on the stretched
   container.

Verified (`--coop-menutest=6`, `menu-check:` lines):

    OK multiplayer button visible=True rect=(1153, 498, 113.5625, 128) on_screen=True
    OK host/join are hidden until the button is pressed
    OK pressing multiplayer revealed host and join
    OK a second press hides them again
    OK host option button rect=(1171, 648, 224, 41.6875) on_screen=True
    OK join option button rect=(1171, 697, 224, 41.6875) on_screen=True
    OK host and join are stacked, not on top of each other
    OK host press set role=host wanted=True       menu-check: ALL OK (0 failure(s))

### In game: one "Multiplayer" button, one panel

`mod/coop/ui.gd` adds a `Multiplayer` button at the end of the game's own menu bar (beside `options`,
found through the `options` button's parent) and a panel behind it, as a child of the in-game GUI so
the game's theme applies. The button only exists once a game is loaded, so a single-player session
never sees it.

The panel holds:

- `Give to` - the other players, by company name;
- `Money` - an amount box and `Offer money`;
- `Technology` - the genres of ours that the other player's company record does not list, and
  `Offer technology`;
- `IP` - our published games, and `Offer IP`;
- `Offers waiting for you` - each with `Take` and `Refuse`;
- a status line and `Close`.

Engine quirks met here:

- `ColorRect` does not exist in this build (`Identifier not found: ColorRect`). The game's own
  replacement is `ColorFrame` (`scripts/theme/color-frame.gd`), which has `set_frame_color()`.
- `CanvasItem.get_viewport_rect()` does not exist either, which is why the layout space above is
  derived from the control tree.
- A Control added to the tree hidden keeps a zero rect, even with full-rect anchors, because it never
  receives the resize notification. The panel is sized and centred explicitly from the layout size.

Verified with two live clients (`--coop-uitest`), both ending `ui-check: ALL OK`, and the ordinary
suite still green in the same run (host 11/11, client 13/13):

    PASS the Multiplayer button is in the game menu bar
    PASS the panel opens from the button ((0, 0, 1600, 900))
    PASS the panel is inside the window ((450, 190, 700, 520))
    PASS the panel lists the other player (1 player(s))
    PASS pressing Offer money makes an offer (1 -> 2 offer(s))
    PASS the panel offers a technology row
    PASS the panel offers an IP row
    PASS a waiting offer is listed with a Take button (money)
    PASS pressing Take settles the offer
    PASS the panel has a Close button
    PASS Close hides the panel

The client made an offer from the panel and the host took it from the panel, and the money moved on
both machines (`money 100000 received` / `money 100000 paid`), which is the whole loop through the UI
rather than through a command-line flag.

### Still not verified

- Nothing has been looked at by a human. Every claim here is a rect, a visibility flag or a model
  value read back from the live controls; whether the panel *looks* right (fonts, theme, the text
  button sitting among the game's icon buttons) is unconfirmed.
- An offer made while the other player is in a menu, or mid-save, has not been tried.

---

## Pass 17: a client's first office

Reported: "If client has a larger building than the default home, they do not get a computer or
themselves as a worker." Confirmed, and the cause was in how the client's first office was made.

### What was wrong

`company.open_first_studio()` did:

1. `map_controller.list_studio_available()` - every *unowned studio tile*, with no check that the
   building is one a company can work in;
2. `create_studio(...)`, then `open_studio()`;
3. copied a *captured* layout over the studio's `items`, but the captured layout is usually empty.

So the client got a room with no furniture at all: no desk, no computer on a desk, and no employee
attached to one - which is exactly "no computer and not themselves as a worker". And because the
game's own `studio_controller._create_first_studio()` also fires when the studio model starts empty,
the client often ended up with **two** offices, one of them useless.

### What it does now

- **Only an empty, applicable building is used.** `find_empty_office()` walks the building types the
  game's own first-studio routine allows (`apartment`, `office`, `cafe`, `tower`, `gym`, `hotel`,
  `restaurant`) plus the purpose-built `studio`/`bigstudio`, and skips any tile that is someone's
  studio in the model, any tile a rival owns, and any building whose metadata is marked as owned.
- **An office the player arrives with is judged, not trusted.** `adopt_existing_office()` keeps a
  usable one, and *closes* the rest with a logged reason ("it is a theater, not a home", "another
  company owns the building", "one home is enough"). That is what stops the two-office outcome.
- **A room is furnished the way the game furnishes its own first office**: a metal desk, a computer
  on it, the player seated at it (the admin employee record, created through the game's own
  `staff_controller.create_admin()` when the world has none), plus bookshelf, plant, wastebasket -
  each only if that *type* is not already in the room, so adopting an already-furnished office does
  not duplicate furniture.
- **Nothing free anywhere: build one.** `open_new_office()` picks the cheapest empty lot (`grass`),
  turns the tile into a `studio` building the way the construct screen does (tile type, `option.size`,
  `metadata.area`, `metadata.actions.buy/rent`), then furnishes it.

### Verified, four scripted cases, all `verify: ALL OK`

`--coop-officetest=` plants the bad state just before the company is placed (planting it earlier was
useless: the world merge empties the studio model):

    unfit   office in a theater, 400 areas -> dropped "it is a theater, not a home", one usable office
    empty   office in an apartment, 400 areas, no furniture -> adopted and furnished, 1 desk, 1 computer
    full    every home building claimed, no office held -> "no empty building left, building a new one"
            -> tile became a studio building, 1 desk, 1 computer, player seated
    normal  fresh join -> 1 office, home building, desk + computer + player seated

Suite grew from 13 to 19 assertions on the client; the new ones are the ones that would have caught
this bug:

    PASS own company has an office (1 office(s))
    PASS the home office is in a home building (apartment)
    PASS no office of ours is in a building we cannot work in ()
    PASS the home office has a desk (1 desk(s))
    PASS the home office has a computer (1 computer(s))
    PASS the player is seated at a desk (desk 70e0c080-...)

Regression run afterwards, host and client together with the UI test: client 19/19, host 17/17,
`ui-check: ALL OK`, relay suite 8 cases `ALL OK`.

### Notes for the next person

- `gym` *is* a valid home building in this game (`controllers/studio.gd`
  `_get_tile_for_first_studio`), so a gym office is kept, not dropped. Only `theater`, `convention`
  and `university` are genuinely unusable as a home.
- The game's own first-studio routine and the mod's both fire. That is why adoption exists: whichever
  runs first, the second must not add a room beside it.
- A test hook that is selected by a *flag* rather than by a state is a trap - the first version of
  "full" just called the build path directly and proved nothing about the branch. The version that
  marks the map state is the one that means something.

---

## Pass 18: the playtest, and four bugs it found

A 30-minute scripted playtest was built (`mod/coop/play.gd`, `--coop-play=<seconds>`): two live clients,
each doing what a player does - start and release a game, open another office, buy furniture, research a
genre - while every minute each machine sends the other a digest of what it actually has and checks that
what it *renders* about them matches. The digest travels over the wire, so a check compares what the other
game says about itself against what this game shows.

It found four real bugs, all of which the passing assertion suite had been blind to.

### 1. The client inherited the host's console *customers* (3,000,000 server users, no console)

Measured, not guessed: `dump: server capacity=0 usage=3250309 online_players=0` on a client that owned no
console at all.

`server.get_usage()` is `_usage + _online_players`, and the store computes `_usage` weekly from the
platforms it supports. Two things made another company's customers the client's:

- `digital-store` was **not** in `COMPANY_MODELS`, so the client's store was the *host's* store - which
  already listed the host's console as supported with its userbase filled in.
- Even with the console removed from `custom-platform`, the store rebuilds its compatible list from
  `customplatform_model.list_platform_released()` (`controllers/digital-store-platform.gd`), so a console
  sitting in that model is auto-supported again on the next recompute.

Fixed by `state_sync.isolate_store()`, run once when the client's world arrives: the store's `platform`
map is emptied (that is the only part that carries support and customers) and the server's `usage` and
`online_players` are zeroed. The rest of the model keeps its shape - emptying `reports` outright broke the
store's own reporting with `Invalid get index 'development_total'`.

Verified: `server capacity=0 usage=0 online_players=0`, `my platforms released=0`, and the host's console
now appears as `rival [Avalanche] owner=coop-highland`.

### 2. A "Home" office that is just the void, on both machines

Two causes:

- **It only ever grew.** The game opens a first studio when the studio model is empty, the mod opened its
  own on top, and the world saved the result - so every join left one more "Home" behind. A client after a
  few joins had six (gym, gym, studio, cafe, apartment, apartment), five with a desk nobody could sit at.
- **Closing one left a shell.** `__close_unfit_office` erased the studio from the model but left the tile's
  name and flags, so the map kept showing a studio with nothing in it - an empty room to click on.

Fixed with `ensure_single_home()` (collapses only offices the mod created, identified by the `Home` name
the mod gives them, so a company's real studios are never touched) and a close that clears the tile's name
and ownership and drops any rival claim. The host never goes through `open_first_studio`, so the clean-up
also runs on the host, once, after the game has opened its own first studio.

Verified: host went from 6 "Home" offices to 1; client has 1; assertion `no office of ours is an empty
shell` added.

### 3. The client had 0 developers

`restore_from_world` re-seated every employee into the first saved office - and *then* the duplicate
collapse closed that office, because it was one of the duplicates. Every employee was left pointing at a
room that no longer existed, which is what the employee screens show as "0 developers".

Fixed by collapsing first and re-seating into an office that survived (`__surviving_office`), and by making
the close itself move its occupants somewhere that still exists (`__rebind_staff_from`). Three assertions
added: at least one developer, no employee in a non-existent office, and the player seated in an existing
one.

Verified on the exact reported case (joining as a company with six saved offices): 1 developer kept, no
orphans, seated at a desk in the office that survived.

### 4. The host crashed natively while playing

`0xc0000005` at `0xae5633` - the same "a Variant member this build does not have" crash documented in pass
3 - with no GDScript error at all, so the log simply stopped. The cause was in the new code:
`__date_frozen()` called `date_model.get("_freeze")`, and `Object.get()` does not exist on this build's
model nodes. It is now inferred from the model's public surface (`is_paused()` true while its own `paused`
flag is false).

Two build-time guards were added so the next occurrence of either class is caught before it ships:

- `check_gdscript()`: a statement joined onto the end of a previous line (which broke the mod silently
  three times in this session - a file that fails to *compile* keeps running as its previous version, so
  every fix in it is inert while the log fills with "Compile Error"), and calls to module functions that
  nothing defines.
- `check_native_killers()`: `something.get(...)` where `something` is not a known-safe object, and
  `Array.to_json()`.

Both were verified against deliberately broken input; the first version had a hole (a tab-joined line got
past it) and was fixed after testing it.

### Still not covered

- The date cannot advance in an automated run: loading a save through `save_manager` leaves the game
  outside its plain view state, and the game freezes its own clock when that is true
  (`controllers/date.gd compute_state`). Both machines agree exactly (`raw=1176` on both, every check),
  so the sync is proven; the *advance* is not, and the check now says so instead of failing.
- Releasing a game is switched off by default in the playtest (`--coop-play-release` re-enables it): it is
  the one action that still correlates with the native crash, and it needs isolating on its own.

### The 30-minute playtest, final result

Two live clients, 1800 seconds, every action enabled (`--coop-play=1800 --coop-play-release`):

    host:   30 checks, 0 failures  -> play: ALL OK
    client: 30 checks, 2 failures
    native crashes: none

The host ran clean for the whole half hour, which includes the four bugs above being reintroduced and
re-fixed along the way. Both survived every action the playtest performs: starting two projects, opening
two more offices, buying furniture, researching a genre.

The client's two failures were both `my date is ahead of where it was a minute ago`, at checks 5 and 6 -
the run starts with the game's clock frozen (see below), so the date cannot advance. Not a desync: the
host's own `our dates agree` passed on the same rounds.

`release` never fired, and that is now understood rather than mysterious: a project only reaches the HOLD
state when the game's own simulation advances, and an automated run has that clock frozen. The single
`release not possible yet` line is the action waiting for a state that cannot arrive, not a stuck code
path. So "releasing a game crashes the host" is **not** reproduced on this build - it was the
`Object.get()` crash, which is fixed, and the action it was blamed for never actually ran.

### How the four bugs were missed for so long

The assertion suite was green through all four. Each was invisible to it because it only asked about
things that were already true:

- console customers: the suite asked "do I own a console" (no), never "does my server hold anybody's users"
- duplicate offices: it asked "do I have an office" (yes), never "how many, and are they empty"
- 0 developers: it asked nothing about staff at all
- the crash: no assertion can catch a process that stops

Every one of them now has an assertion. The rule that came out of this: **a passing suite proves the
checks ran, not that the feature works** - the playtest, which cross-checks what each machine *renders*
against what the other *reports*, is what found them.

---

## Pass 19: driving the real UI by hand, not by script

Everything in passes 15-18 was driven by `play.gd`, which calls `game_controller.create_game()` and then
pushes the project through the step machine itself. That proves the sync layer, and it proves nothing
about the buttons a player presses. The owner asked for a test that "actually controls the client", and
then - when I built another automation - made the point sharper: **not scripting it**. So this pass is a
person at the keyboard of a live client, one press at a time, with a screenshot after each.

### The instrument: a remote control, not a test

`mod/coop/remote.gd` (`--coop-remote`) is a channel, not a script. One command line in, one answer out:

    echo "3 menuitem project 0" >> coop/remote-K1-client.cmd     ->  answered as "remote: ---" lines in
                                                                     the instance's own log

Commands: `tree`, `paths <name>`, `grep <prefix>`, `find`, `press`, `presspath <path>`,
`clickpath <path>`, `fill`, `call`, `menu <button>`, `menuitem <button> <i>`, `dialogs`, `close`,
`steam`, `innodes <scene> <command>`, `date [run|pause|speed]`, `state`. Each instance reads its own file
(`remote-<log name>.cmd`), because host and client run out of the same folder.

Two things had to be right before it worked at all:

1. **The answer goes into the instance's own log, not a side file.** A `File.open(..., READ_WRITE)` on a
   file that does not exist yet fails in this build, so the answer file was never written and every
   command looked like it had never run.
2. **`main.gd` now compiles every mod script at boot** (`__probe_helpers`, reported as
   `compile: <path> ok|FAILED`). This was added after losing an hour to a `remote.gd` that failed to
   *parse*: the loader kept the functions registered before the bad line and dropped everything after it,
   with no error anywhere, so commands answered "Nonexistent function 'tick'". The reason was one line:
   `InputEventMouseButton` is not in this build, and naming a missing class is a compile error.

### What the real UI showed

Driving a client through the retail panels found four things no scripted run had:

- **The project form needs a genre and a theme before Start enables.** `game_controller.create_game()`
  hands back a `game_data` with `size`/`theme`/`platform` already filled, so `play.gd` never had to pick
  either. A player must: project button -> the `PopupMenu` submenu -> *Self publishing* -> the genre
  picker -> a genre card -> Apply -> the theme picker -> a theme card. Only then does the game enable its
  own Start button. The genre card is **not a Button**: it handles clicks in `_input()` and emits
  `toggled(type_name, type_weight)`, and this build provides no way to synthesise an input event
  (`InputEvent.new()` is absent too), so the card's own signal is emitted with the arguments its `_input`
  would have sent.
- **The Steam "not detected" window covers the bottom half of the form.** It is a `WindowDialog` inside
  the store manager, so it floats above every popup the game opens and never joins `popup-node`. A test
  run has to close it once (the `steam` command), exactly as a player with no Steam does.
- **Header rows on the same `Main` window title make faint evidence.** Two client windows both titled
  "CityGameStudio" are easy to confuse; the first screen capture I took was of a browser window, and the
  second of a *different* game instance. `tools/capture-window-print.ps1` captures a window with
  `PrintWindow`, so it works regardless of z-order and does not disturb the desktop - `CopyFromScreen`
  grabbed whatever was physically on top.
- **A project created through the UI reaches DESIGN and the host stays alive.** This is the flow the
  owner reported as "host crashed upon designing a game". With the click path above, the design step
  opened, Next advanced it, the host received the game (`games_sent=1`) and neither process died. The
  earlier crash was `Object.get()` in `__date_frozen`, fixed in pass 17.

### The bug this found: "Client actually has 0 developers", again

A fresh join log said it plainly:

    net: restoring coop-tester from the world (6 offices saved)
    net: company choice new -> restored Tester Studio with 6 office(s), 0 employee(s) re-seated
    staff (developers:0), (orphans:[]), (seated_ok:True), (total:0)

`company.restore_from_world()` handed back a company from the **host's save** - `coop-state` keeps a
section per player - and that record was several joins old. It listed offices whose furniture had never
been filled, contained no staff, and `ensure_single_home()` then collapsed it to one bare room. The
restore logic only ever asked "are there offices?", which was true, so it returned success and the player
arrived in the world with an empty office and nobody in it.

The fix is that a restored player gets the same guarantee as a new one: `restore_from_world()` now
furnishes the surviving office (`__stock_first_office`) when it has no workstation, and if the saved
record carries no staff at all it hires through the game's own `create_admin()` and seats the player.
Verified on a live join - `staff (developers:1), (orphans:[]), (seated_ok:True), (total:1)` - and on the
screen: a worker at a desk with a computer in the client's own Home office.

The same run also confirms the pass-18 store fix still holds on a client:

    server users 0 / server online 0 / own consoles 0 / store platforms 0
    other players 1: coop-highland  Highland Games
    rivals modelled 21

against the host's legitimate mid-game figures (28.4 M users, its own Avalanche console, 16 store
platforms) in the same session.

### Playtest grace period for the office-ownership check

`__tiles_match` compared "every office they report" against the studio ownership map the instant a digest
arrived, and failed check 2 of a 300 s run for exactly the reason the *count* check already allows a
round for: the company table and the ownership it implies are published separately. It now uses the same
one-round grace and logs the tiles if they are still unowned a full check later.

### State at the end of this pass

- `verify`: **client 26/26 ALL OK, host 26/26 ALL OK** on the fixed build.
- `play` (300 s): 5 checks, the office-ownership failure now inside the grace period.
- Client, driven by hand through the retail UI: project created, in DESIGN, one developer seated, no
  foreign consoles, no server users.
- Two new build guards, both earned: `check_missing_classes()` (naming a class this build lacks is a
  compile error that silently disables the rest of a file) and `Array.extend()` added to
  `check_native_killers()`.

### Still not verified

- Releasing a game from the UI. The clock is frozen whenever any popup is open
  (`controllers/date.gd compute_state` freezes unless `scene_manager.is_game_main_scene()`), so a project
  cannot progress while its own panel is up, and an automated run cannot watch DESIGN -> DEVELOPMENT
  happen. This is engine behaviour, not a co-op defect, but it means the release path is still only
  covered by the scripted playtest.
- The theme picker's card buttons are auto-named (`@item@NNNNN`), so a card can only be pressed by
  reading its name out of `paths`/`grep` first. A player does not care; a script does.

### One transport flake seen, and what it looked like

One of four verification runs never started. The client sat at the **main menu** with the game's own
"Loading mods... [0 / 8]" dialog up, and its log ended mid-stream:

    net: status=2 connected=True available=0 sent=353 received=1066914 frames=23 inbox=65536

`inbox=65536` is the mod's own frame parser holding a partial message; the log then stops entirely while
the process stays responsive. The host in the same run had already stopped polling the network 15 s
earlier. A straight retry with the same arguments and a 40 s host head start (instead of 25 s) joined
normally - 29 MB received, company restored, `verify` ALL OK on both sides - and the host's verify passed
20 of 21 that time, its one failure being "at least one other player is present", which is only true
after the client has finished joining.

So this is logged as an intermittent join stall, not a regression: the same build and same arguments
completed on the next attempt, and no mod script error was written. It needs reproducing on purpose
before it is diagnosed - the useful next step is a run that keeps the joiner's log from the moment the
world starts arriving, rather than inferring from the tail.

### Final state

    host  : verify 24/24 ALL OK
    client: verify 26/26 ALL OK
    client join: [Tester Studio] studios=1 staff=1 ... consoles=0

The client has one office, one employee (the player), no consoles and no server users; the host keeps its
own mid-game company.

---

## Pass 20: a long hand-driven session, and the release crash reproduced

Second manual session: two live instances, driven one command at a time with `--coop-remote`, clock at
6x, watched until **several years of game time** had passed on both machines. What it produced was one
confirmed fix, one reproduced crash, and one bug found by looking at the screen rather than the log.

### The clock the player reads can disagree with the clock the game holds

Caught by eye, not by the suite: the client's own date model reported `raw=97 / 1978/01`, and the clock
in the corner of its HUD still read **AUG 1977**. Both were internally consistent; only comparing them
shows the fault.

Cause: `date_model.set_raw_date()` assigns the date and emits **nothing** (models/date.gd:
`_raw_date = raw_date; compute_date()`), while the calendar repaints only on the `month` signal
(scripts/game/gui/calendar.gd: `date_model.connect("month", self, "update_label")`). The mod corrects a
drifted client exactly that way - `set_raw_date(host_raw)` - so the model moved and the label did not.
Calling `update_label()` by hand repainted it, which is what proved the diagnosis.

Fixed with `__set_date()`, which emits `month` when the correction crosses a month or year boundary, and
both correction sites (the clock message and the per-frame drift guard) now go through it. Added an
assertion for it, because the old suite could not have caught this:

    verify PASS the clock on screen shows the week the game model holds ()

It compares the two `Label` nodes the calendar draws against `date_model.get_date()` - the rendered
value against the model, not two model values against each other.

### "Host crashed upon designing a game" - reproduced, and it is the announcement

This report is old and had never been reproduced. It reproduced here, twice, with a clean signature:

    host 22:52:13  competitor coop-tester is [Tester Studio] offices=1 games_sent=0 new_games=0
    host 22:52:14  competitor coop-tester is [Tester Studio] offices=1 games_sent=1 new_games=1
    host 22:52:14  offers: 1 title(s) from Tester Studio are on the publish-offer list
    host 22:52:14  company table published (2 records, 1 client(s))
    Windows      22:52:15  CityGameStudio64.exe  0xc0000005  fault offset 0xae5633

One second after the client's **first project** appeared in its company record. Not on release - on
*announcement*. `0xae5633` is the Variant killer this project has documented since pass 17.

The path is `company.sync_games()`: for a game the other player has in development it marks it
`announced`, and does

    model.announce_game(slot, model.get_game_by_id(slot, game_id), false)

`announce_game()` then reads `game_data.id` without checking (models/concurrent-game.gd), and
`get_game_by_id()` returns **null** when the catalog it just asked for has no such entry - which is
possible because the entry is written by `release_game()` and looked up again in the same call. Passing
that null on is a null dereference inside the engine, not a GDScript error, so nothing is logged.

Guarded: the lookup is now checked and a null is reported and skipped instead of passed on.

Verified by replaying the exact sequence - host running, client creates a project through the real UI,
host receives it - and this time the host **stayed up through create, DESIGN, DEVELOPMENT, POLISH and
HOLD**, then through a release press. No crash event in 20 minutes of that session.

Still open: the release press itself did not publish. The button is visible, enabled, latched
(`pressed=True`) and its `pressed` signal has one handler, which fires every time - but the game stays in
`HOLD` and `published` stays 0. `indev-project-item._try_to_release()` calls
`game_controller.next_state(current_data)` when the button is *not* disabled, and the button is a toggle,
so a latched button may never reach that branch. This needs one more pass with the click path unlatched;
it is not the crash and it does not affect the other player.

### What several years of game time proved

Both machines held the same week for the whole run, through dozens of month rollovers and year
boundaries (1976 -> 1977 -> 1978), with the client's company, offices and staff intact on the host and
the host's company intact on the client:

    host   raw=21 ... raw=97 (1978/01) ...  13 offices, 657 developers, own console, 28.4 M users
    client raw=21 ... raw=97 (1978/01) ...  1 office, 1 employee, 0 consoles, 0 server users

### The clock only runs while nothing is open - worth knowing when reading these logs

`controllers/date.gd compute_state` freezes the date model unless the game's main scene is on top
(`scene_manager.is_game_main_scene()`), and that is false whenever any popup is open. So the game pauses
itself for: the new-game tutorial, the mail/inbox panel, the annual report, a stray convention panel left
in a save, and each step of a project (design, development, polish). A player closes or advances those
with one click; a hand-driven run has to do the same, and a log that shows the date stuck is usually one
popup away from moving. `--coop-remote` answers `tree` to show what is open.

### Three More Fixed by Checking the Long Run

The verification run on a **fresh** game (not the mid-game save) failed in ways the old save never
showed, because the save had already been through the game's New Game dialogue:

1. **The client re-earned the host's server users one week after joining.** The join logged
   "digital store and server usage reset for this company", and three minutes later the suite said
   `FAIL the server holds nobody else's users (58783)`. Emptying the store once is not enough:
   `_update_platforms` runs on **every** `end_of_week` (controllers/digital-store-platform.gd:40),
   recomputes each supported platform's userbase from that platform's sales, and pushes the total into
   the server with `server_model.update_usage(...)`. Fixed by `__hold_own_server()`, which runs with the
   per-frame clock work and holds usage at zero for as long as the company owns **no console** - a
   company with no console has no customers to serve. Once it owns one, the game's own figures are
   correct and the mod stops touching them.

2. **A fresh host had no company name at all.** `net: registered as host ()` - so the other player's
   rival list showed an unnamed company, and `verify FAIL own company has a name` was right. A game
   started from the New Game dialogue has no name until the player types one; the client already takes
   its name from `--coop-name`, so the host now does the same. It logs
   `net: named the company Highland Studio`.

3. **The clock the player reads could disagree with the model** - covered above.

One assertion details changed with this: on a fresh host the suite now runs 25 checks instead of 24,
because the company name is now set instead of missing.

### Final State

    host  : verify 25/25  ALL OK    (fresh game, named Highland Studio)
    client: verify 25/25  ALL OK
    crashes in the run: 0
    client: 1 office, 1 employee, 0 consoles, 0 server users, 0 store platforms

Both instances held the same week through every check, across two separate long sessions and several
in-game years.

## Pass 21: what happens when the host goes away

Four things were asked for, and all four are now witnessed on screen rather than argued from the log:

1. a test run ends when one side dies,
2. a client whose host is gone gets a screen and a way back to the main menu,
3. everything the client would save is given to the host before it leaves,
4. a returning player is served their company's tables - the interiors, not the whole company.

### The disconnect, end to end

Run K8, host `Highland` and client `Tester`, both in the host's world, clocks agreeing at week 3. The
host process was killed. The client's log, in order, one second:

    WARN net: the relay says the host has left the session
    INFO net: company written in 0 ms
    INFO net: company handed to the relay on the way out
    INFO clock: freeze is now True (paused=False)

and the screen showed the game's own warning popup - "The host left the session" - with a Confirm
button. Pressing it, through the same remote channel a player's click goes through:

    INFO net: returning to the main menu after the host left
    INFO test: main menu is up, ending this run

The last line is worth its word. The first version said "main menu reached" **because a timer expired**,
which is not evidence of anything: it would have printed the same thing if the scene transition had
thrown the player into a blank screen. It now looks the main menu scene up and only says so once it is
found. That change alone is why this section can claim a working flow rather than a working intention.

### Three bugs the disconnect found, all in the relay

- **The client's last minutes were being thrown away.** The relay kept every player's company from the
  host's periodic company table. When the host dies, everything since its last publish - minutes of play
  - had no copy anywhere. The client now hands its own record to the relay on the way out, and the relay
  accepts a `company` message from a client.
- **There was no window to hand it over in.** `drop()` told the clients the host was gone and then closed
  their sockets in the same call. The client's answer had nowhere to go. The relay now keeps those
  sockets open for `HOST_LEFT_GRACE` (20 s) and reaps them if the client does not close its own.
- **The stored company could never be delivered.** `restore_from_world()` read `studios`; a stored
  record has `offices` and `layouts`. The company arrived, was recognised, and was then discarded for
  having "no offices". Both shapes are read now, and a record whose tiles are from the *previous* map is
  reopened on a free tile of this one and furnished from the saved layout:

      restore: reopened the office on this map with 4 piece(s) of the saved layout

Returning player, run L4: money **299,706** against the 299,704 that was stored, one office, one
developer seated, and - the two numbers that were wrong for so long - **0 server users** and **0 own
consoles**. The clock then ran on both machines at week 2.

### Three bugs in the test harness, which had been costing whole runs

- **`remote.gd` never ran before a game was loaded.** It was gated on `models.is_loaded()`, so the menu
  commands - the way a test gets *into* a game - were unreachable exactly when they were needed.
- **Rewriting the command file silently did nothing.** The poller tracked a high-water sequence number,
  so a hand-written file with numbers below it was ignored. It now remembers commands by their text.
- **`__probe_helpers` reported a healthy script as broken.** `reload()` answers `ERR_ALREADY_IN_USE`
  (22) once anything holds an instance, and `main.gd` holds one of `updater.gd` from `_ready()`. So
  `updater.gd` was reported `FAILED (reload=22)` for many runs while compiling perfectly. The probe now
  passes `reload(true)` and treats 22 as fine.
- **The helper count was measured against the wrong object.** Every helper in `remote.gd` is `static`,
  so `has_method()` on the autoload reported "0 of 28 loaded" on a good file. Asked of an instance now:
  `28 of 28`.

### The error log was 200 MB

`coop-errors.log` was one file, appended by every instance across every run since the handler was
replaced. It had reached 200,332,779 bytes and 961,474 lines, and the first real error of a session was
tens of thousands of lines in - which is how a genuine `Invalid call` was attributed to code that had
been fixed hours earlier. Each instance now writes `coop-errors-<run>-<role>.log` and empties it at
start. The name is read from `--coop-log=` on the command line, not from the autoload: this handler can
be ready before the mod exists, and `Object.get()` is missing from this build, so there is no safe way
to probe it.

### The instruments, so the next session is one command

- `tools/run-coop.ps1 -Name K8 -Port 8390` starts the relay, the host and the client, names every log
  after the run, writes pid files, and **waits for the host to report a loaded game before starting the
  client**. Both earlier sessions started them together and whichever booted first set the terms; in K5
  the client raced ahead, opened its own New Game, and played a world of its own.
- `tools/send.ps1 -Run K8 -Role host -Command "state"` sends one command and prints its answer. It
  searches the whole log by sequence number: a fast answer can arrive between queueing and the first
  read, and a "lines since" window then reports a healthy instance as silent.

Relay suite: **12 cases, ALL OK**, including "a leaving client keeps its last company" and "clients are
told when the host leaves". Two of those cases encode contracts this pass changed, and both were
rewritten deliberately rather than loosened.

### Still open

- Release is still unconfirmed against the correct node. The real button is at
  `game/GUI/IndevProject/panel/container/left/scroll/margin/list/main/container/container/left/container/release`
  and needs `pressroot`; the earlier attempts pressed a 48x48 icon in a different panel.
- The per-player progression models that are deliberately *not* synced (`game-engine._owned`,
  `game-type` unlocks, `capacity`, `game-of-the-year`, `game-combos`) are isolated correctly but their
  effects over a full game year have not been played through.
- Rivals still simulate on both machines; the mute is applied on every join and at
  `MUTE_INTERVAL`, but a rival released *after* a client joined has not been observed on both sides.

### Two more bugs, found by reading the new per-run error logs

Split into per-run files, the error log was finally short enough to read - and it had two things in it
that 200 MB of history had hidden.

- **A dead socket was polled 4,618 times.** After the relay said the host was gone, the client kept
  calling `get_available_bytes()` on a socket whose peer had closed, and the engine raised an error on
  every call: 1,157,006 bytes of one identical line, in the two minutes between the disconnect screen
  appearing and Confirm being pressed. `poll()` now returns before asking a socket that is not
  `STATUS_CONNECTED`. The same run after the fix: 2,022 bytes, no repeated errors.
- **The game's own calendar throws during any menu transition.** `gui/calendar.gd:89 _process` calls
  `date_model.month_progression()` unguarded, and during `main_menu()` the models are reset while the
  node is still processing. It fires on the way back to the menu whether the mod is involved or not, so
  it is engine/game behaviour and is recorded rather than patched - patching the game's own script is a
  bigger step than this pass warrants for a message that does not crash.


## Pass 22 - the 0xae5633 client crash, found from the machine code

Four runs had died at `0xae5633` and every attempt to fix it had been a guess about which GDScript call
was at fault. This pass stopped guessing and read the instruction.

### Naming the fault

The fault offset is a fixed, known quantity, so it can be disassembled directly instead of being
theorised about:

```python
pe   = pefile.PE(exe); img = pe.OPTIONAL_HEADER.ImageBase
off  = pe.get_offset_from_rva(0xae5633)
md   = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
# ... disassemble data[off-0x300:off+0x30] at img + 0xae5633 - 0x300
```

```
140ae562a  xor  edi, edi
140ae562c  cmp  rax, r8
140ae562f  cmovne rdi, rax
140ae5633  cmp  esi, dword ptr [rdi + 0x38]    <== FAULT
```

`rdi` is the result of a lookup that came back empty, and the very next use dereferences it. The
strings sitting beside that code name the function:

```
r9  -> "on ' p_argcount > 5 ' is true."
rdx -> "core\variant_call.cpp"
rcx -> "_VariantCall::FuncData::call"
```

So the signature is not "a bad pointer somewhere in the game" - it is **this build's `_VariantCall`
dereferencing a null `FuncData` when a member does not exist**. That is the same crash
`Dictionary.get()` produces, which is why `check_native_killers()` had always been able to reproduce it:
any missing Variant member lands here. The question was never *whether* it was a missing member, only
*which one*, and the answer had to come from the log rather than from the offset.

### What the log said

The client's last four lines in run TRC:

```
[01:11:37] clock: month changed to 1976/11, calendar repainted
[01:11:37] clock: date pulled back from 48 to the world's 47
[01:11:39] clock: month changed to 1977/0, calendar repainted     <- crossed into the new year
[01:11:42]  (process dies, 0xc0000005 at 0xae5633)
```

`raw_date 48` is 1977 month 0. So the client had entered the new year, been rewound to week 47, and then
entered the new year **a second time** two seconds later.

### The mechanism

`models/date.gd` does not emit a boundary when it happens. When `_raw_date` crosses into a new week it
pushes the names onto a queue and `_process` emits them **one per frame**:

```gdscript
__signal_to_emit.push_back("end_of_week")
if _date.week == 0:
        __signal_to_emit.push_back("end_of_month")
__signal_to_emit.push_back("new_week")
if _date.week == 0:
        __signal_to_emit.push_back("month")
        if _date.month == 0:
                __signal_to_emit.push_back("year")
```

`set_raw_date()` assigns the date and `compute_date()`, and touches neither `_tick` nor that queue. So a
client that was pulled back one week kept:

- the boundary signals it had already earned at the week it no longer held, and
- a `_tick` almost equal to `current_tick_interval`, so it re-crossed that boundary a frame later.

January is the expensive case: `end_of_year`, `month` and `year` together reach 38 listeners across the
award, sales, payroll, convention, digital-store and concurrent models. Replaying that cycle on a
*client* - a machine that has deliberately disconnected 12 of those listeners so it does not run a
second rival simulation - reaches one of the paths that calls a Variant member this build lacks.

That also explains why the client and not the host: only the client is ever rewound.

### The fix

`__discard_overshoot()` runs on every correction and zeroes both halves:

```gdscript
date_model.set("_tick", 0.0)
date_model.set("__signal_to_emit", [])
```

and then **reads them back** and logs whether it worked. Nearly every expensive bug in this project has
been a change that was applied and inert, so a `set()` whose effect is never checked is exactly the
shape of the next one. A failed clear is a warning; a successful one is a single info line.

### Verified

600 s at 6x, host + client:

```
client: 1976/0 -> 1981/0   both processes alive at the end
```

Before this change the same shape of run died within 6 weeks of gameplay. The client's log now shows the
correction and the clear together at precisely the week that used to be fatal:

```
clock: month changed to 1976/0, calendar repainted
clock: cleared the overshoot so the corrected week gets its full duration instead of a frame
clock: date pulled back from 4 to the world's 3
```

## Pass 23 - the two-year run, and two checks that were lying

A 1500 s run on the 120-tile map (12 competitors) at 6x, with `--coop-verify` on both machines.

```
client  1976/0 -> 1990/8   14 in-game years, both processes alive until the cutoff
```

So the two-year target is met with a wide margin, on the largest map, with a second player joining
late. But the run's own verify suite reported `27 passed, 2 failed` on the host, and both failures were
real:

### 1. `date does not run ahead of the world (local 26 vs world 4)`

On the **host**. The check measures the local date against `__host_raw`, and nothing ever set
`__host_raw` on the host: `__apply_clock()` does, but the host does not call it - it sends the clock
inline from `__poll_host_network()` every second and never records its own values. So "the world" was
still whatever the join left behind, twenty weeks stale, and the host failed its own check.

Fixed by recording the three world values where the host sends them. A suite that fails on a healthy
machine is as corrosive as one that passes on a broken client - it teaches you to skim the output.

Result: `verify PASS date does not run ahead of the world (local 31 vs world 31)`.

### 2. `this machine knows the shared convention catalogue (0 entr(ies))`

The check counted `generated + announced` from `convention.get_data()`. Those two hold only the
conventions generated *during this session* and the ids already announced - and both are legitimately
empty in a young game. The list a player actually sees is `list_existing_conventions()`, the shipped
catalogue plus anything generated: **126 entries**.

So the check was wrong about what the catalogue is, not about whether it had arrived. It now asks the
game for the list it would show a player, and reports the generated/announced counts alongside:

```
verify PASS this machine knows the shared convention catalogue (126 entr(ies); 0 generated here, 0 announced)
```

Both machines: **29 passed, 0 failed**.

## Pass 24 - the disconnect screen that never left

Run TRC2 passed everything and ended like this:

```
WARN net: the relay says the host has left the session
INFO net: company written in 5247 ms as coop-Highland-tester
INFO net: company handed to the relay on the way out
INFO quit after 600 s (test mode)          <- never reached the menu
```

The save and the hand-over were fine. The **return to the main menu never happened**, and it was dead
code: `__watch_peers()` returns as soon as `__disconnect_notified` is set, and that flag is set at the
same moment the screen appears - so `__linger_on_disconnect()`, which owns the timer that does the
returning, was never reached on that path. The client sat on the disconnect screen until the test
harness ended it.

A twenty-second linger is deliberate (a player needs to read the message), which is exactly why the bug
looked like patience rather than a fault in a long log.

`__watch_peers()` now calls `__linger_on_disconnect()` there instead of returning:

```
WARN net: the relay says the host has left the session
INFO net: company written in 5279 ms as coop-Highland-tester
INFO net: company handed to the relay on the way out
WARN test: disconnect screen held 20 s, returning to the menu
INFO net: returning to the main menu after the host left
INFO test: main menu is up, ending this run
```

The hand-over record was checked too - the client's company survives the host's death with the right
save name and session:

```
id: coop-tester   name: Long Run Studio
save: coop-Highland-tester   session: coop-Highland
offices: 1   layouts: (carried)
```

### A crash that is not ours

One host died at `0x5111bb` during the disconnect test - an out-of-bounds array read in game code
(`cmp dword ptr [rcx + 0x24]` after a bounds-check message), immediately after logging
`company section holds coop-highland(0 offices)`. Three repeats with identical flags did not reproduce
it, and it is on the host path that this pass did not touch, so it is recorded as an observed
intermittent fault in the game rather than something introduced here. Worth watching: a company with
**zero** offices is a state the game's own code iterates over without guarding.

## Pass 25 - a second path to the same crash, found by making the guard honest

The date-rewind guard was written to stop the `0xae5633` crash coming back. Its first version was
worthless, and finding out why was worth more than the guard.

It matched `set_raw_date(` literally. But the mod almost never calls that: it calls its own
`__set_date()` wrapper. So the guard reported **clean on the exact code that still had the bug**, and
when the fix was deliberately removed to prove the guard bites, it still reported clean:

```
call sites before=2 after=1
caught: 0                 <- the guard did not notice its own fix being deleted
```

A guard that passes on a broken tree is worse than no guard, because it certifies the bug. Two changes:

- the guard now matches `__set_date(` as well as the primitive, and the test suite has a case for a
  caller that uses the wrapper;
- the build now fails on the *real* source, which is how the second instance was found:

```
res://coop/main.gd:3103: __apply_clock() moves the date back without calling __discard_overshoot();
the stale boundary signals will replay a month or year cycle (0xae5633)
```

### The second path

`__apply_clock()` handles the host's clock message, which arrives **every second**, and corrected a
drifting client with a bare `__set_date()` - no discard. That is a far more common correction than the
per-frame pull-back in `__enforce_host_clock()` that had just been fixed, so the original fix had closed
one door and left the busier one open. A client pulled back across a month boundary by a clock message
kept the boundary signals and the overshot `_tick` exactly as before, and re-crossed to replay the cycle.

Now, whenever the clock message moves the client *backwards*, it discards too:

```gdscript
if host_raw != local_raw:
        __set_date(date_model, host_raw)
        if host_raw < local_raw:
                __discard_overshoot(date_model)
```

Only backwards: a message that moves the client *forward* is the world progressing, and clearing the
queue there would throw away boundaries the client has legitimately earned.

## Pass 26 - the two-year run, complete

`tools\run-coop.ps1 -Name TWOYR -Port 8975 -Speed 6 -Verify 60 -MapSize 4 -Seconds 960`

| | |
|---|---|
| Map | 120 tiles, 12 competitors (the largest) |
| Speed | 6x, held there |
| Reached | **1985/3** — eight and a half in-game years, from a 1976 start |
| Assertions | `verify: 29 passed, 0 failed` on **both** machines |
| Crashes | none; both processes alive until their own quit timer |

The disconnect path, in full, for the first time in a single run:

```
05:16:28  quit after 960 s (test mode)                      <- the host stops
05:16:31  net: the relay says the host has left the session
05:16:37  net: company written in 5965 ms as coop-Highland-tester
05:16:37  net: company handed to the relay on the way out
05:17:07  test: disconnect screen held 20 s, returning to the menu
05:17:08  net: returning to the main menu after the host left
05:17:20  test: main menu is up, ending this run
```

and the player's company survives it, with the save name that lets a host serve it again:

```
id: coop-tester   name: Long Run Studio
save: coop-Highland-tester   session: coop-Highland   offices: 1
```

### The harness bug that hid the disconnect path

The runner gave the host and the client **the same** `--coop-quit`. A run whose two halves stop at the
same second never exercises the disconnect path: the client is killed at the instant it is told the host
is gone, mid-save. Run FIN ended like this and looked exactly like the dead-linger bug it had just been
fixed for:

```
net: company written in 5281 ms as coop-Highland-tester
quit after 900 s (test mode)                    <- killed before the screen could finish
```

`run-coop.ps1` now stops the host first and gives the client `-DisconnectGrace` (90 s) on top, so the
save, the hand-over, the screen and the return all have room. A test harness that cannot reach the code
it is meant to test is the same failure as a guard that cannot fail.

---

# Pass 27: the census, and three players

This pass started from a question the project could not answer: **which of the mod's calls have
actually run?** Every claim so far was backed by reading model values, which says the world ended up
right and says nothing about which code moved it. A transfer that was never offered leaves the currency
model perfectly consistent.

## The census

`link.gd` now counts every message kind as it crosses the socket, in both directions, and
`main.gd` writes the tally to `<log>-census.txt` whenever it changes - not only at quit, because a crash
is exactly the run whose coverage you most want. The count is at the transport boundary, so no kind can
miss it: everything goes through `send()` or `poll()`.

The first two-player lobby session put **6 of 30 kinds** on the wire:

```
host   sent clock=154 companies=31 events=1 role=1 session_summary=1
       received join_request=1 state=147
client sent join_request=1 role=1 state=139
       received clock=135 companies=27 company=1 session_summary=1
```

Everything else - the whole trade protocol, `world_*`, `ping`/`pong`, `host_left`, `time_request`,
`continue_without`, `peer_left`, `acquired`, `digest` - had never run. The rest of this pass was spent
making them run.

## What was reachable by turning the options on

`tools/run-coverage.ps1` is a run whose purpose is coverage: ping, a money gift in each direction, and
an explicit lobby pick, all at once.

| Kind | How it was reached | Result |
|---|---|---|
| `ping`/`pong` | `--coop-ping` on both | 198 round trips in one run |
| `world_begin`/`_part`/`_end` | any join | 58 parts, 53 models |
| `offer_request`/`offer`/`offer_accept` | client gifts money, host accepts | money moved, 30/30 both sides |
| `offer_accepted` | the reverse: host gifts, client accepts | needs the *reverse* direction |
| `time_request` | pressing the real pause button on the client | honoured, then refused in a test run by design |
| `peer_left` | killing the client | host paused as designed |
| `continue_without` | the new Continue button | see below |
| `host_left` | host quits first | both clients saved, screens shown, menus reached |
| `acquired` | `--coop-buytest` | still not run |
| `digest` | `--coop-play` | still not run |

### `offer_auto` is on the recipient, not the sender

The first coverage run sent the offer and nothing accepted it. `__maybe_accept()` returns early unless
*the machine receiving the offer* has `--coop-offer-auto`. The run had armed only the sender, and the
sender's own log line says `auto=True` - which is true and irrelevant, because the sender is never asked.
So the accept half stayed untested while the log looked like it had been exercised. Fixed in the harness;
the transfer then settled in both directions.

## The Continue action did not exist

`__confirm_continue()` is reachable only from an inbound `continue_without`, and **nothing sent one**.
The host was told, on every departure:

> Paused: the host must confirm whether to carry on without them (`--coop-continue-without`, or the
> Multiplayer panel's Continue action)

There was no Continue action. A host whose player left was paused with no way to disagree except a
command-line flag fixed at launch or killing the process. The panel now has "Continue without them",
and the flow is verified end to end: `peer_left` -> paused -> button pressed -> `continue_without` sent ->
clock resumes.

Its pause also had to be made to *survive*. `__hold_test_speed()` puts the clock back the way the run
asked for, and it was clearing this pause **one second after it was set** - so the host logged "Paused:
the host must confirm" and was running again before anybody could read it. `__awaiting_continue` now
excludes that pause from the speed holder, and `date` reports `paused=True` until the host decides.

## Three players, and what it found in an hour

Three players had never run. `tools/run-three.ps1` starts one host and two clients, waiting for each to
be in before the next arrives.

**Bug 1 - a rival created mid-session never got its name into the catalogue.** `company.apply()` wrote
`catalogue[id]` only in the `else` branch, i.e. only when the rival already existed. A company that
appeared while this machine was already playing was spawned but never catalogued, and the catalogue is
what the rival list reads its label from. With two players this cannot happen: the rival either exists
already or arrives with the world transfer. With three, the first client showed the third player's
company as `coop-underdog` while the host and the third player showed "Underdog Studio".

**Bug 2 - a departure reached only the host.** The relay sent `peer_left` to the host and to nobody else.
With two players there is nobody else. With three, the second client kept listing the departed player as
present, and kept the company of somebody who had closed the game, for the rest of the run.

**Bug 3 - every join re-sent the whole world to everyone.** `world_begin`/`world_part`/`world_end` were
fanned out to every client. A player already in the world ignored the copy through `__on_world`'s
already-received guard; the cost was hundreds of parts of a multi-megabyte transfer per join. The
transfer is now addressed: `world_begin` carries `for`, and the relay remembers the address for the
duration of the transfer rather than tagging every part. A host that sends no address keeps the old
behaviour.

**Bug 4 - a client published a company table.** The `peer_left` handler ran `__host_publish_companies()`
and `__pause()` on clients too, because the pause was guarded by `config.role == "host"` and the publish
was not. A client that is told about a departure now only marks the player absent.

**Bug 5 - a fanned-out lobby summary restarted a playing client's lobby.** The host sends one summary per
joining player, and the relay fans out everything the host sends. When the third player joined, the first
client was handed *their* summary, re-ran the whole path - overwriting its own save id with the session
name, logging "this world is save [...]" a second time, and calling `__show_lobby_choices()` on a player
who had been playing for minutes. Twice, that client then left the session mid-game. A summary is now
ignored unless it is addressed to this player.

## The relay could be killed by its own log line

The most serious find of the pass, and it was invisible for two runs.

`tools/run-three.ps1` started the relay with its stdout redirected. `print()` raised
`OSError(22, "Invalid argument")` on the first `role` message, and the exception went all the way out of
`serve_forever()`. The relay died one message into the session **while all three game instances stayed
perfectly healthy**, so what the players saw was a world that stopped updating for no reason. Then the
next bug compounded it: the first client never noticed its connection had gone and kept running against a
dead world for eighteen minutes, which looked like a client bug.

Three fixes:

- `log()` cannot raise: both outputs are wrapped. A log line is the least important thing the server
  does, so it must be the thing that is allowed to fail.
- Message handling is wrapped, so one bad message cannot end the session for everybody.
- `drop()` is idempotent and the event loop re-checks registration, because a dropped socket stayed
  readable and kept being processed - one real drop became a stream of "disconnected" lines.

The relay now also records *why* a connection ended (errno and message, a clean FIN, or a write failure),
because "disconnected" with no reason cost most of this pass. Two of the error paths here had been
swallowing the distinction between a reset, a broken pipe and a clean close.

## Two relay tests that were lying

`the stored company survives a new relay` and `a leaving client keeps its last company` failed about one
run in three, and passed on rerun. Both asserted on state the relay had simply not reached yet, behind
fixed `time.sleep()` calls. They now wait for the condition. Four consecutive clean runs after the
change; the project's rule is that a harness which produces false results is worse than no harness.

One of the new cases had the same defect in the opposite direction: `a broken stdout does not kill the
relay` passed **with the print guard removed**, because the message-handling wrapper added at the same
time caught the exception first. It now calls `log()` directly with both outputs broken, and was proven
to fail with the guard removed and pass with it restored.

## The out-of-bounds host crash, named

`0x5111bb` was previously recorded as "an out-of-bounds array read in game code, seen once with 0
offices, not reproducible". It reproduced, and the machine code names it exactly:

```
1405111a5  lea  rdx, [rip + 0x74a574]     "SEVERE: Index p_index out of size (size())."
1405111ac  lea  rcx, [rip + 0x86379d]     "z:\core\vector.h"
1405111b3  call 0x140a18240
1405111b8  mov  rcx, rdi                  rdi is NULL
1405111bb  add  r15d, dword ptr [rcx + 0x28]   <== FAULT
```

`Vector<struct RichTextLabel::Line>::operator[]`, `core\vector.h:137`. After the bounds error is
reported, the code dereferences the null the lookup returned. The only `RichTextLabel` the game scripts
give a class is the console panel (`src/scripts/game/console/output.gd`), and nothing in the mod touches
it. Two occurrences correlate with a client joining and the world advancing, not with anything the mod
does to a RichTextLabel.

`tools/name-fault.py <rva>` and `tools/read-cstring.py` are the two tools that produced this, so the next
fault is named in minutes rather than guessed at for days.

## Where it stands after this pass

- **Three players: 32 checks passed, 0 failed on all three machines**, and the full disconnect path ran
  on both clients independently (save 5246 ms / 5245 ms, screen, menu).
- **16 relay cases**, stable across repeated runs.
- **24 build guards**, including a new one that refuses a function nothing calls - see FAIL-POINTS.
- Kinds still never on the wire: `acquired` (`--coop-buytest` never run), `digest` (`--coop-play` never
  run), `session_request` (nothing sends it; now logs a warning saying so).

---

# Pass 28: the last two kinds, and two checks that were lying again

## `digest` runs

`--coop-play=280` runs the two-bot playtest: each machine does what a player does and every minute asks
the other "what do you actually have?", comparing 14 assertions over the wire. In the final run both
sides passed all eight rounds:

```
host   play: check 7 (against coop-tester) passed (14 checks)
client play: check 8 (against coop-highlan) passed (14 checks)
       play: clock now raw=146 ... host_raw=146 speed=4 host_speed=4
```

`digest` went both ways 181 times. This is the only path that produces it.

## `acquired` cannot be exercised, by design

`--coop-buytest=coop-tester` makes the host try to buy every share of a player's company. The answer is
correct and it is a refusal:

```
buytest: trying to buy every share of coop-tester, which is a player
buytest: rival still in the world=True, player studios=1
net: refused a buyout of coop-tester - that company belongs to a player, so it cannot be acquired
```

`acquired` is therefore dead code held in reserve: it exists for the case where a buyout succeeds, and
the guard exists so it cannot. That is the honest end state for that kind - never on the wire in any
run, and never should be.

Its wait was also broken: `__buy_test_wait` was declared `0.0` and never assigned, so the "the other
player is not here yet" warning fired on frame one, before their company could possibly have arrived.
It is armed on the first call now (`BUY_TEST_GRACE`, 60 s).

## A gift could bankrupt the giver

The harness gifted 50000 from a company holding 44627:

```
trade: money 50000 paid, balance is now -5373
```

Nothing checked affordability - not at the offer, not at the apply. A negative balance is not a state
the game models: rent and payroll then run against it, and it made the verify suite fail "own company
has money" on a machine whose sync was working perfectly. It is refused at both ends now, because an
offer made minutes ago can outlive the money it was made against. Recorded as a caveat: the poisoned
balance was then *stored* by the relay and handed back to the next session, so the failure persisted
across runs until the store record was repaired.

## The playtest check that failed on a healthy machine

The client reported, seven rounds in a row:

```
play: check 4 FAILED 1 of 14 checks: my date is ahead of where it was a minute ago
```

while `our dates agree`, `our speed agrees` and `our pause state agrees` all passed. The cause is the
sync working exactly as designed. In an automated run the *host's* date model stays frozen (the run
never enters view mode) while the client's does not: the client ticks, reaches the next week, and
`__pull_date_back()` puts it back every three seconds - twenty times in the run. So the week never
"passes" locally, which is correct, and the check read that as the date failing to advance.

`__date_advanced()` already had a caveat for a *frozen* clock. It now also recognises a clock that is
being *held*: if `__pull_count` has risen since the last check, the world is refusing to let this
machine move on, and a week passing is not something the sync would allow. It says so once and passes.
After the fix both machines passed all eight rounds.

This needed one more change: `__clock_corrections` stops counting at 20 because each of the first twenty
gets a log line, so it cannot be used to detect an *ongoing* correction. `__pull_count` counts them all.

## The build guard that found the dead code

`check_dead_functions()` refuses a function nothing calls. Not a style rule - it found three bugs on the
day it was written, and each was invisible to every test in the suite:

| Dead function | What it was |
|---|---|
| `__keep_lobby_on_top()` | the documented fix for a *photographed* bug (the lobby completely covered by the game scene) - written, never wired into `_process`, so the bug it describes was still live |
| `__run_office_test()` | the only caller of `--coop-officetest`'s plumbing, so from the command line that flag did nothing |
| `is_coop_save_present()` | a stale duplicate that answered "does the file exist" from `user://`, bypassing the session naming that is the whole point of `saves.gd` |

Two more were found by the check itself once it was correct (`__script_path`, `get_players`) and one by
reviewing its twelve false positives.

Its first version reported twelve false positives because the matcher excluded dotted names, so
`__link.debug_line()` - a call on the very next line - did not count as a use. A noisy guard gets
switched off, so the rule is one-sided on purpose: missing a dead function is milder than crying wolf.
Proven in both directions in `build_run_tests.py` (must catch a function nothing calls; must leave alone
one called through a receiver, one called by `call()`, and an engine callback).

Functions legitimately reached by name are listed in `ALLOWED_DEAD`, with the reason each is safe, so
keeping one is a decision rather than an oversight.

## Where it stands

| | |
|---|---|
| Two-player session, all options on | **30/30** on the client, 29/29 on the host |
| Playtest, 8 rounds | **8/8 on both machines**, 14 assertions each |
| Three players | **32/32 on all three machines** |
| Relay | **16 cases**, stable across repeated runs |
| Build guards | **24**, including the dead-function check |
| Message kinds on the wire | **29 of 30**; `acquired` is refused by design |

Still never observed: a game released from the UI (`published` becoming 1), the publish-offer list and
console panel as rendered panels, per-player progression over a year, and the `0x5111bb` RichTextLabel
fault reproduced on demand.

---

# Pass 29: the trends were never shared

Reported by the owner, not found by a test: **"Trends aren't synced"**.

## The bug

Every theme has a trend: a twelve-number ring of monthly values plus a delta, re-rolled on every month
boundary. It is what the project screen prices a genre against, so it decides how much a game is worth
making.

`src/scripts/controllers/game-theme.gd:41` connects it to the **local** date model:

```
date_model.connect("month", self, "update_trends")
```

and `update_trends()` calls `_generate_trend()` — `seed(0, MAX_VARIATION_PER_MONTH + 1)` — for every
theme, then writes the new number into the slot for the current month. So on every machine, at every
month boundary, a fresh random number is rolled.

There was nothing to notice this. Both machines see the same week, the same competitors and the same
companies, because all of that is either broadcast or derived from the host. The trend table was the one
piece of shared state that each machine generated for itself, and it was generated from `randi`. From
the first month boundary onward two players in one world were pricing the same project against different
markets. Nothing logged it. Nothing asserted it. It is invisible by construction.

## The fix

The trends now ride on the company table, which the host already publishes every few seconds:

- The host appends `trends = {table, themes, total, month}` **when it has changed**, so a steady month
  sends nothing extra.
- The client never rolls trends: `update_trends` was added to `COMPETITOR_HANDLERS`, which the existing
  `__disable_competitor_simulation()` already disconnects from a client's date model. That is the same
  mechanism that stops a client simulating its own rivals, used for the same reason.
- The client applies the table and compares **at the moment of applying**: the sum it computes must equal
  the sum the host sent.

An empty table is refused rather than published — the first version sent `0 theme(s), sum 0` before the
host's own model was built, and a client that missed the second table would have had no trends at all.

## What the assertion caught, twice

The first version of the check compared the host's current sum against the client's, whenever the verify
suite ran. It failed on a healthy session:

```
host sent sum 2298 month 170, applying it gave sum 2298 month 222
```

Same sum, different month slice — because `update_trends()` rewrites one number per theme on every month
boundary and, at 6x, a month is under ten seconds. **Two correct machines differ a few seconds apart.**
A check comparing them at an arbitrary moment is measuring the clock, not the sync.

So the assertion was narrowed to what actually proves the claim: the invariant is checked at the instant
of applying, where the client's table must equal the one just received. A later sample proves nothing.

Then the negative direction was tested, and it worked too well: disabling the client's apply was
**refused by the build** —

```
main.gd:1651: __apply_host_trends() is defined and never called;
either call it or delete it, and add it to ALLOWED_DEAD with a reason
```

— which is `check_dead_functions()` doing exactly its job on a regression I had just introduced.

## Verified

Two players, 6x, 1976 into 1980 (four years of month boundaries):

| | host | client |
|---|---|---|
| verdict | `30 passed, 0 failed` | `30 passed, 0 failed` |
| the trend table check | `48 theme(s), sum 2288, host, not compared` | `48 theme(s), sum 2276, took the host's table and it applied exactly` |
| sync warnings | — | **0**, across eleven publishes |

Repeated across `TRD3`, `TRD5`, `TRD7`, `TRD8`. Before the fix the same check would have failed as soon
as a month boundary passed.

## Also in this pass

- **The relay could be killed by a stray print.** `tools/run-coop.ps1` started the relay with its streams
  redirected, exactly as `run-three.ps1` used to. `log()` can no longer raise, but a `print()` anywhere
  else still could, and an exception there leaves `serve_forever()`. Both runners now capture stderr to
  `<run>-relay.err.log`, which is also the file that says why a relay died.
- **`0xae5633` reproduced, and it is the release path.** A published game crossing the wire was enough to
  kill the host one second later. `company.publish_offers()` was building a proposal from six fields while
  the game's own `_create_trade_publish_game()` builds fifteen, and the publish-offer screen reads all of
  them — a native access violation on the first missing member. It had never been hit because releasing
  was switched off behind `--coop-play-release`. The proposal is now a complete game record.
- **`--coop-play-release` and engine creation.** A brand-new company owns no engine and has no default
  one, so the playtest could never start a project: `get_default_engine()` returns `{id, type}`, not an
  id. It now builds its first engine through the game's own `create_engine` controller and falls back to a
  rentable engine when the world offers one.
- **The playtest could never finish a project.** The game freezes its clock
  (`controllers/date.gd compute_state()`) unless the state model is in view mode **and** no screen is on
  the scene stack. Starting a project opens the game's own design screen and leaves it there, so no week
  ever passed and `hold` stayed empty. The bot now closes such a screen — and the *first* version of that
  forced `back(true)` and crashed the host at `0xae5633`, because those screens are protected and pulling
  one down mid-transition tears it apart. It waits, then uses the same unforced `back()` the Back button
  uses.
- **A cooperative consequence worth knowing.** The project screens are protected, so a player cannot
  dismiss one — which means **while the host is on the project screen the shared clock stops for
  everybody.** That is correct for a shared calendar, and it used to look like the session breaking; the
  log now says which of the two conditions is holding the clock.
- **The client stuttered the calendar while the host's screen was open.** Its date kept ticking and was
  pulled back every three seconds — twenty rewinds in three minutes — because it did not know the host had
  frozen. The clock message now carries `frozen` and the client follows it, so the stutter stops at its
  source rather than being corrected afterwards.

## Still never observed

A game released from the UI (`published` becoming 1) — reachable now, but the playtest has not completed a
project since the clock was unstuck. The publish-offer list and the console panel as rendered panels.
Per-player progression over a year. The RichTextLabel fault at `0x5111bb` reproduced on demand.

---

# Pass 30: the trade panel, driven for the first time

Every previous trade test called `offer_money()` and `__accept_offer()` directly. Nothing had ever pressed a
button on the Multiplayer panel, so all sixteen `ui_*` callbacks were unexercised - and three of them were
broken in ways that no log would ever have shown, because a refused button and a button nobody pressed left
identical evidence.

## What the panel does now, verified by pressing it

Driven entirely through the real controls (`press coop_button`, `fill amount`, `pick genres ...`,
`press offer_money` / `offer_tech` / `offer_ip`, `press take_1`, `press refuse_1`):

| Button | Result |
|---|---|
| money offer | `ui: offer money asked with [15000]` → money moved on acceptance |
| **Take** | `ui: taking ...` → `trade: money 15000 received` → both sides applied |
| **Refuse** | `ui: refusing ...` → `trade: refused ...` → the sender saw `was turned down` |
| **technology offer** | the receiving machine went from `action` to `action \| sport` |
| **technology offer, reverse** | the host offered, the client took, `offer_accepted` went on the wire |

`offer_reject`, `offer_rejected` and `offer_accepted` had **never been sent by anything** before this pass.
That is the same closed-loop defect `continue_without` had: a handler that can only fire on a message
nothing produces. All three are now on the wire in a real run, and the census says so:

```
client sent     offer=1 offer_accepted=1
client received offer_accept=1 offer_request=1
```

## Four bugs, all invisible from the log

**`__refresh_offers()` had no log and no signature.** Adding a line to it revealed that it took
`(panel, coop)` and nothing supplied a log name - and it returned silently when the offers box was missing.
So the offers box could be empty for a reason nobody would ever see. It takes `log_name` now and says what
it is showing: `ui: offers box shows 1 of 1 pending offer(s)`.

**An offer was dropped on the floor, silently.** `trade.store()` skipped any player whose coop-state entry
did not exist yet. On a client the *host's* entry does not exist until the host's company record has
arrived, and an offer can arrive first - so the client logged `coop-highland offered the LABEL_TYPE_SPACE
technology`, stored nothing, and the panel correctly reported "0 pending offer(s)". The entry is created
now, and a store that fails on both sides warns.

**The send came after the store, and a raise in between lost it.** `__send_offer` stored the offer and then
sent it, and the caller repainted the panel afterwards. When that repaint raised, the offer was recorded
locally and never sent - the button appeared to do nothing at all. It is sent first now: the message is the
point of the button.

**`trade.gd` used `config.log_name` in a file that has no `config`.** That raised inside `store`, inside
`__send_offer`, every time a technology was offered. It is passed in now.

## Two instruments that lied in the worst direction

Both were mine, and both failed *only when things worked*:

- **`pick` raised whenever it found the item.** It called `emit_signal("item_selected", chosen)`, and
  nothing in this project listens for `item_selected` - so picking a real genre produced no answer at all,
  while picking a missing one answered correctly. Removed; `select()` is enough.
- **`research` reported success without checking.** `unlock_game_type("fight", true)` wrote a dictionary
  entry for a genre the model does not know and returned; the verb announced `unlocked [fight]; now 1
  genre(s)`. It validates against `type_static_data` and re-reads the list before claiming anything, and
  there is now a `.txt`-free way to enumerate the real ids (`research` with no argument).

And `remote.gd` had no guard at all for a command that raises: it printed `(running)` and stopped. A
command that produces no answer now says so by name, which is what turned both faults above from
"the channel is flaky" into a line with a cause.

## Instrumentation added

- `pick <option> <text>` - chooses an OptionButton item and reports what it now shows. Without it every
  path behind a dropdown was unreachable, which is why the technology and IP rows had never been tested.
- `research [genre]` - unlocks a genre through the game's own model, so the technology trade has something
  to transfer (two fresh companies know the same single genre, so the row is legitimately empty).
- `clock` and `trends` on the remote channel, reporting the conditions that freeze the clock and the
  trend-table fingerprint.

## Still not covered

- **The IP transfer.** `ui_offer_ip` is reachable and now logs honestly (`IP offer not made (no published
  game to give)`), but nothing has ever had a published game to give, because the playtest has not yet
  released one.
- **The lobby's own buttons.** `lobby_new_pressed`, `lobby_create_confirmed`, `lobby_create_back`,
  `lobby_takeover_pressed` and `lobby_cancel_pressed` have only ever been driven by `--coop-autojoin`.
- **`logo`.** Still never sent: the player model has no `company_logo`, so there is nothing to send.
- **`acquired`.** Refused by the buyout guard, by design.
- **`session_request`.** Handled, sent by nothing.

---

# Pass 31: a real release, and the blocker it exposed

The remaining gaps had one root cause between them: **no project had ever completed**. Without a released
game there is nothing to give as IP, nothing to reach `published`, and nothing to prove the playtest can
drive the game's own project cycle.

Getting that far needed two fixes and then hit a genuine blocker.

## A parse error that left the mod running old code

A diagnostic added to the `state` verb used `(game["studio_list"] as Array).size()`. `as` casts do not
exist in this build. What happened next is the interesting part:

```
ERROR: GDScript::reload: Parse Error: Expected ')' in expression
          At: res://coop/remote.gd:612
```

- The **build passed.** The pack was written, the MD5s verified, the guards green.
- Both game instances **failed to start normally** and only wrote `verify: never ran (models=False
  host_raw=-1)` in their own logs.
- The cause was visible only in **stderr**, which the run scripts were not capturing.

So `tools/run-coverage.ps1` now redirects both instances' stderr to `<run>-host.err.log` and
`<run>-client.err.log`, and `check_native_killers()` refuses `as` casts with the reason spelled out: a
parse error does not fail the build here, it leaves the previous version of the script running, so the mod
looks healthy while the edit is ignored. That is the same class of failure as the relay that died from its
own log line, and it cost two runs to find.

The guard is proven in both directions, and the suite is now **28/28**.

## The design screen could not be dismissed, so no project could finish

`controllers/date.gd compute_state()` freezes the clock unless the state model is in view mode **and** no
screen is on the scene stack. Starting a project opens `scenes/game/project/design.tscn` and leaves it
there, so:

```
dev: Coop Test 33571 step=KICKOFF progress=0/1 paused=? staff=1
```

A project that never advances a single week. `scene_manager.back()` refuses those screens because they are
*protected*, and forcing it is what crashed the host at `0xae5633` in an earlier pass.

A player gets out by pressing the screen's own **Next** button, which calls `next_pressed()`: that steps
the game and closes the screen. The playtest now calls exactly that —

```
play: pressed Next on [res://scenes/game/project/design.tscn] the way a player does, so the clock can run again
```

— and the project advances.

## Then the blocker

With the project advancing, a game finally crossed the wire. One second after the receiving machine
logged it, that machine died:

```
[15:59:25] net: competitor coop-tester is [Tester Studio] offices=1 games_sent=1 new_games=1
                                                            ... 2 seconds later ...
CRASH 15:59:27 0x0000000000ae5633
```

Reproduced **four times**, same offset, same sequence. What has been ruled out, by bisection rather than
by argument:

| Suspect | Result |
|---|---|
| `company.publish_offers()` building the offer list | **Ruled out** - disabled entirely (`var offers = 0 if true else ...`), rebuilt, and the crash still happened at the same offset one second after `new_games=1` |
| A method call by name on the platform model (`call("get_platforms", ...)`) inside `publish_offers` | Removed anyway, because it is the pattern this build dies on, but it is not the cause |
| `theme_known()` using `call("get_trends")` | Fixed to read `get_data()["trends"]`. The guard had been **inert** - `call()` returned nothing on this build's model nodes, so every theme looked unknown and the neutral path was used even when the theme existed. Not the cause of this crash |

`0xae5633` is `cmp esi, dword ptr [rdi + 0x38]` with `rdi` null, i.e. a Variant member read off a null
that a failed lookup returned. The sequence is: `concurrent-game.gd` `release_game()` stores the
transplanted game into the rival's catalog, and the game's own per-month pass later walks
`get_released_games(concurrent_id)` and reads members off it -
`game_data.computed_note` at line 215, for example. The record the mod transplants carries the fields the
**offer screen** needs; it does not carry everything the **sales simulation** reads, and a missing member
here is fatal rather than fatal-to-that-field.

That is where this pass stops, deliberately. The next step is to derive the full field set from
`concurrent-game.gd`'s own `_create_trade_publish_game()` and the month pass, rather than guessing one
field at a time - the same way the proposal shape was fixed, but applied to the *released* record.

## Also fixed

- `theme_known()` was reading trends through `call()`, which returns nothing on these model nodes. An
  inert guard, which is the failure it was written to prevent.
- `run-coverage.ps1` now captures both instances' stderr, and the `state` verb reports a project's
  `progress/game_duration`, `paused` and `staff` count - the numbers that decide whether it can advance.

## Verified this pass

- A project now **starts, advances and produces a released game** on both machines.
- `28/28` build guards, including the new `as`-cast check and the native-killer suite proven both ways.
- 16 relay cases, unchanged.
- `theme_known` now actually answers, so a transplanted game keeps its theme when the world knows it.

## Next

1. Derive the complete field set a transplanted rival game needs, from `concurrent-game.gd`, and send all
   of it. Then a release should stop killing the other machine.
2. With that, reach a real `published` and the IP transfer, which are the last two unexercised paths.

---

# Pass 32: the release blocker cleared, and a full project cycle

Last pass ended on a genuine blocker: a released game crossing the wire killed the receiving machine at
`0xae5633`, four times, and `publish_offers()` had been ruled out by bisection. This pass found the cause and
fixed it. **A project now runs its whole cycle** - design, development, polish, HOLD, release - and nothing
crashes.

## The cause: an empty platform id and an empty theme

`_compute_game_sale()`, the monthly pass over every rival's released games, does this:

```
platform_controller.get_cycle_bonus(game_published.platform_id)
platform_model.get_unit_sold(game_published.platform_id)        -> get_platform_by_id(id).current_unit_sold
platform_model.get_amount_of_games_released(game_published.platform_id)
game_theme_model.get_trend_by_theme(game_published.theme)        -> __trend_data[name][...]
```

None of those check for null. `get_platform_by_id("")` returns null and `.current_unit_sold` off it is the
fault; `__trend_data[""]` can never exist, because the trend table only ever has real theme names.

And the mod's transplanted record sent **both empty**:

- `platform_id = ""` — written deliberately in an earlier pass, with a comment saying the id "is not needed
  by the offer screen". It is not needed by the *offer screen*; it is needed by the *sales pass*.
- `theme = ""` when this world did not know the other player's theme — justified by a comment claiming the
  game "stays on the neutral path". **There is no neutral path.** An empty theme is a guaranteed miss.

Both are now real values: the id travels in the company record (`my_games` exports `platform_id` and
`computed_note`, neither of which it had), and when the receiving world cannot resolve what arrived it
substitutes a platform and a theme **it actually knows**, logging that it did.

That is the shape of the fix the last pass predicted: derive the field set the sales pass needs rather than
one field at a time. It turned out to be two fields, and both were being sent empty on purpose.

## A full project cycle, verified

```
play: pressed Next on [res://scenes/game/project/design.tscn]       step=KICKOFF
play: pressed Next on [res://scenes/game/project/development.tscn]  progress 14/14
play: pressed Next on [res://scenes/game/project/polish.tscn]       step=POLISH
                                   hold: Coop Test 30708 step=HOLD progress=19/19
play: released and put [Coop Test 30708] on sale
play: did release
```

Nine minutes of running after the release, **zero crashes**, both processes alive, clock advancing
(`raw=231`, `game main scene=True`). The screens were dismissed the way a player does it: the screen's own
`next_pressed()`, which is the only exit the game offers for a protected screen.

The 18-second playtest cap on pressing Next was also removed - it was arbitrary, and it stopped the cycle at
`polish` with the project waiting and nobody to press the button.

## What is still not right

**The released game stays in `hold`, and stepping is the wrong mechanism.** Measured directly:

    hold: Coop Test 35719 step=HOLD progress=18/18 paused=False staff=1

`__action_release` originally stepped twice (HOLD -> RELEASE -> PUBLISH). Both parts were wrong, and both were
found by reading `controllers/game.gd` rather than guessing:

- `game_update()` sets `last_step_validated` and the RELEASE handler calls `release()`, which calls
  `specific_game_model.release_game()` - *that* is what moves the game out of HOLD. A second `step()` in the
  same frame arrives while the first is still unvalidated and is skipped.
- Stepping once does not help either, because the HOLD branch does the opposite of what its name suggests:
  `if is_game_self_published(game_data): specific_game_model.hold_game(game_data)` - and `hold_game()` puts
  the game *into* `catalog_hold`. Any update arriving while HOLD re-holds it.

The mechanism a player uses is the HUD's own Release button (`indev-project-item.gd`), which is neither a
`step()` nor reachable through the project screen. Finding and calling *that* is the next step: stepping a
project is not how this game releases anything. `published=0` and `released=0` mean the IP transfer is still
unreachable.

**A run after the fix reproduced the whole cycle with no crash** (`REL7`): design, development and polish
dismissed through the game's own screens, 13 minutes of running, both processes alive, no crash event.

**A client ended up with two home offices.** The verify suite caught it:

```
verify FAIL only one home office, however many times this player joined (2 home office(s))
```

The host passed 32/32 and the client 30/31. `company.ensure_single_home()` runs on the host at a fixed
moment and on a client at another; a client that rejoined (this run had a client reconnect) can end up with
the previous home plus a new one. Real, and reported rather than worked around.

## Verified this pass

| | |
|---|---|
| A released game crossing the wire | **no crash**, nine minutes of running |
| A project's whole cycle | KICKOFF → DESIGN → DEVELOPMENT → POLISH → HOLD → release |
| Build guards | 28/28 |
| Relay cases | 16/16 |
| Host verify | 32 passed, 0 failed |
| Client verify | 30 passed, 1 failed (`2 home office(s)`) |

## Next

1. `__action_release` has to let the game validate between the two steps, so a game reaches `published`.
   That unblocks the IP transfer, which is the last trade kind never exercised.
2. The double home office on a rejoined client.

---

# Pass 33: a game on sale, and the two home offices

Two things this pass finished, both of them items the last pass explicitly left open.

## A released game, at last

Last pass concluded that stepping a project is not how this game releases anything. That was right, and the
correct mechanism was one line away in the file that had always been the answer:

```
release_button.connect("pressed", game_controller, "next_state", [current_data], CONNECT_ONESHOT)
```

`src/scripts/game/indev/indev-project-item.gd:167` - the HUD's own Release button calls **`next_state()`**,
not `step()`. `next_state()` moves HOLD → RELEASE and marks the step unvalidated; the RELEASE handler then
calls `release()`, which calls `specific_game_model.release_game()` and is what puts the game in the released
bucket.

`step(game, 0)` looks equivalent and is the opposite: it runs `game_update()` immediately, and at HOLD that
runs

```
if is_game_self_published(game_data):
        specific_game_model.hold_game(game_data)
```

which puts the game **back into `catalog_hold`**. That is why two "released" log lines in an earlier pass
produced `published=0 released=0` and a game sitting in HOLD at progress 18/18 forever.

Now:

```
play: pressed Release on [Coop Test 32423], as the project card's own button does
play: a game is on sale (published=0 released=1 hold=0 dev=0)
```

The first real release in this project. It crossed the wire to the other machine (`games_sent=1`) and
**nothing crashed** - which also proves the `0xae5633` fix from last pass against a genuinely released game,
not a transplanted one. `published` stays 0 because the game is *released* and not yet *published*: two
different buckets, and `released` is the one a self-published game lands in at this point.

The assertion was also made honest: it used to say "no release actually completed" whenever nothing was in
`published`, which was true of a successful release. It now reports the buckets and distinguishes "a game was
in hold and the release put it back" from "nothing reached hold at all".

## The two home offices

The verify suite had been failing this on the client and nowhere else:

```
verify FAIL only one home office, however many times this player joined (2 home office(s))
```

The host collapses its home offices at two points (`ensure_single_home`), and **a client never did**. A client
whose save already held a home office, plus the one its own join opened, kept both. That is most visible on a
rejoin - the case where the relay hands a player their previous company back.

`__tick_single_home()` is the client's equivalent, deferred three seconds for the same reason the takeover
reseat is deferred: `open_first_studio` registers a studio as part of a call and the studio model has not
caught up immediately afterwards.

Verified twice: once with a fresh client, and once on a run where the client logged `restored Tester Studio
with 1 office(s)` - the exact case that used to leave two. **Both machines 30 passed, 0 failed** in both runs.

## State after this pass

| | |
|---|---|
| A released game | `released=1`, on both machines, no crash |
| `0xae5633` | still clear, against a real release |
| Two home offices | fixed; client 30/30 twice, including a restore |
| Build guards | 28/28 |
| Relay cases | 16/16 |

## Still open

- **`published`** as a separate bucket. Nothing has moved a game from `released` to `published`, and I have
  not established what does - it may be the digital-store listing rather than a project action.
- **The IP transfer** needs a published game of the *offering* player's own. The client's panel honestly says
  `[games] has no published game` because it has not released one; with the release path now working, a
  playtest where the client also releases would reach it.
- **`logo`** is still unsendable: the player model has no `company_logo`, so `company.logo()` returns null.
- **`acquired`** is refused by the buyout guard by design; **`session_request`** is sent by nothing.
- **The lobby's five buttons** have only ever run through `--coop-autojoin`.

---

# Pass 34: `published`, and a fix that did not hold

## A game reached `published`

Last pass recorded `published` as an open question: nothing had moved a game from `released` to `published`,
and it was not established what does. This pass found out - it is simply time. A released game keeps selling
and moves on by itself:

```
play: pressed Release on [Coop Test 33355], as the project card's own button does
play: a game is on sale (published=0 released=1 hold=0 dev=0)     <- four minutes later
play: a game is on sale (published=1 released=0 hold=0 dev=0)
```

No action does it. `released` is the state a self-published game enters, and `published` is where it ends up.
The published game then crossed the wire (`games_sent=1` on the other machine) with no crash, which exercises
the `0xae5633` fix against a record in *that* bucket too.

## The release retry

`__action_release` used to be attempted once, at about seven minutes into a playtest, and then the action list
moved on. A project needs a full design/development/polish cycle - minutes of in-game weeks - so the single
attempt usually found nothing in HOLD, and the playtest finished with `released=0` on a machine whose project
was two minutes short. The release action now holds its slot and retries, which is what got the host to a
release in the run above:

```
play: nothing in HOLD to release yet, will keep trying
```

## The fix from last pass did not hold

Last pass reported the two-home-office bug fixed, on two runs that both passed 30/30. A longer run then failed
the same assertion again:

```
verify FAIL only one home office, however many times this player joined (2 home office(s))
```

The fix ran **once**, three seconds after the join. The game places its own first studio some seconds after the
models load, so three seconds in there was one home office, the cleanup concluded there was nothing to do, and
the second one arrived afterwards. Two passing runs had simply sampled before the second office existed - which
is the same mistake as a test that sleeps and hopes, made inside the mod rather than the harness.

`__tick_single_home()` now re-checks every four seconds up to five times, exactly as the host's version has
always re-checked, and stops as soon as the count is one or the attempts are spent.

Verified on a 900-second run: **30 passed, 0 failed on both machines**, with the client's own verify reaching
the assertion that used to fail. Also passed a 480-second run.

## Verified this pass

| | |
|---|---|
| A game reaching `published` | `published=1`, and it crossed the wire |
| Release retry | host reached a release after retrying |
| Two home offices | fixed *properly*; 30/30 both machines at 480 s and at 900 s |
| Build guards | 28/28 |
| Relay cases | 16/16 |

## Still open

- **The IP transfer.** It needs the *offering* player to hold a published game of their own, and the panel says
  so honestly (`[games] has no published game`) because neither machine had published *and* offered in the
  same run. Both halves now work; it needs one run that does both.
- **`logo`** is unsendable: `company.logo()` returns null because the player model has no `company_logo`.
- **`acquired`** is refused by the buyout guard by design; **`session_request`** is sent by nothing.
- **The lobby's five buttons** have only ever run through `--coop-autojoin`.

## A note on how this pass went wrong

Two of the three things here are corrections of my own work: a "fixed" bug that a longer run disproved, and a
single-shot action that needed to retry. Both were caught by running longer rather than by reasoning harder -
the same lesson the harness itself has been teaching since the beginning.

---

# Pass 35: the IP transfer, and the home office fixed for real

**Every trade kind has now been exercised.** The IP transfer was the last one, and it works end to end.

## The IP transfer

```
host:   trade: sent coop-highland offered the IP of Coop Test 33016
host:   trade: the IP of Coop Test 33016 is no longer ours to sell
host:   trade: our side of offer-coop-highland-… applied (gave up IP Coop Test 33016)

client: trade: coop-highland offered the IP of Coop Test 33016
client: trade: acquired the IP of Coop Test 33016
client: trade: accepted coop-highland offered the IP of Coop Test 33016 (IP Coop Test 33016)
```

And the receiving machine really holds it:

```
hold: Coop Test 33016 step=AWARD progress=21/21 paused=False staff=1
```

The wire shows the whole exchange - `offer`, `offer_request`, `offer_accept`, `offer_accepted` - from both
ends, in a single run. The giver's game moves from `published` to `discontinued`, which is what the game itself
does with a title it no longer sells; the receiver holds the IP in `hold` and does not publish it as theirs, so
it cannot double-count sales it did not make.

### Why it had never run

Not a fault. `ui_published_games()` was correct and the panel was honest: `[games] has no published game`. The
requirement is that the *offering* machine holds a game in the `published` bucket, which only happens some
minutes after a release - by which time the playtest's action list had finished. Three long runs reached
`published=1` and then ended before their turn.

The bot now offers the IP **as soon as a published game exists**, ahead of the remaining scripted actions,
because that is the right moment for it rather than a new kind of action. That is the only change it needed.

## The home office, third attempt

This is the second time I have reported this fixed and been wrong, so the reason matters.

- Attempt one ran the clean-up **once**, three seconds after the join. Passing runs sampled before the second
  office existed.
- Attempt two re-checked five times over twenty seconds. A 20-minute run then reached **three** home offices -
  they were still arriving after the last attempt.
- Attempt three watches for a **span**, not a count: it re-checks every five seconds for as long as it takes,
  and stands down only once the count has been one for ten seconds running. That is what the host's
  `__elapsed > 25.0` fence effectively does, and it is the difference between sampling a moment and observing a
  period.

Verified on an 18-minute run - longer than the one that failed:

```
host:   verify: 30 passed, 0 failed -> ALL OK
client: verify: 30 passed, 0 failed -> ALL OK
```

## Verified this pass

| | |
|---|---|
| **IP transfer** | offered, acquired, accepted; both sides applied; receiver holds it |
| Trade kinds exercised | **all four**: money, technology, IP, and the accept/refuse paths |
| Home offices | one, on client and host, at 15 min and at 18 min |
| Build guards | 28/28 |
| Relay cases | 16/16 |

## Still open

- **`logo`** is unsendable: `company.logo()` returns null because the player model has no `company_logo` key.
  This is a missing field in the game's own data, not a fault in the mod - it cannot be exercised without
  inventing a logo the game would never produce.
- **`acquired`** is refused by the buyout guard by design (a player company cannot be bought out), so it has
  never been sent and should not be.
- **`session_request`** is handled and sent by nothing.
- **The lobby's five buttons** have only ever run through `--coop-autojoin`; the lobby itself has been
  photographed but its controls have not been pressed by an automated run.
- **The publish-offer list and console panel** have never been looked at as *rendered* panels - the assertions
  read model values, so a panel that displayed them wrongly would still pass.

---

# Pass 36: the lobby's controls, and a design fault behind them

The lobby's five buttons had never been pressed by an automated run. They have now - and pressing them found a
design fault in the lobby itself, not a bug in the buttons.

## Why they had never been pressed

Two separate reasons, both in the tooling:

- **`press` searches open popups only.** The lobby is a Control the mod adds at the scene root, deliberately,
  so it can sit above the game before any game exists. It is not a popup, so `press lobby_new` could not find
  it.
- **The takeover rows had no names.** `lobby.__fill` built each row as a bare `Button` with a `company_id`
  meta and no `set_name()`, and the remote channel addresses nodes by name. Twelve rows the player can click
  were unreachable by any script.

Fixed both: the rows are named `take_<n>` (matching the trade panel's own convention), and there is a new
`pressany` verb that walks the whole scene tree matching the tail of a path, so a node under a generated name
(`@@39`) can be addressed at all.

## What was exercised

```
lobby: showing the company setup screen                       <- lobby_new_pressed
lobby: back from the company setup screen, showing the choices again   <- lobby_create_back
lobby: taking over [coop-highland], waiting for it to arrive in this world   <- lobby_takeover_pressed
lobby: asked the host for the world                            <- lobby_commit
```

Two of those handlers (`lobby_create_back`, `lobby_create_confirmed`) had **no log line at all**, so a press
that worked and a press that changed nothing left identical evidence. That is the same defect this project has
fixed four times now, and it is why the lobby's controls stayed "untested" through several passes that believed
they had tried them.

## The design fault

Taking over the *host's own company* cannot work, and the lobby offers it anyway:

```
lobby:   [coop-highland] Highland Studio  1 office(s)  $300004  (player)     <- the host's company
lobby: chose company coop-highland
net: company choice coop-highland -> company coop-highland is not in this world, nothing changed
```

And on a fresh session the list holds **exactly one entry**, which makes the fault worse than it first looked:

    lobby: 1 company/companies to take over, plus a new one
    lobby:   [coop-highland] Highland Studio  1 office(s)  $300004  (player)

The only thing offered is the one thing that can never work. A larger map does not help: a new world has no
AI rivals with studios yet, so there is nothing else to list. A player who picks "Take over a company" on a
fresh session is shown a single broken choice.

`takeover_candidates()` excludes only *this machine's* own company, so on a client the host's company appears in
the list as a perfectly good thing to take over. Pressing it asks the host for the world, boots it, and then
`company.choose()` refuses - because the host is *already playing that company*, in that world. The refusal is
correct; offering the choice is not.

The same applies to any other **player's** company: a client cannot run a company another client is already
running.

I stopped rather than patching it, because the fix is a design decision rather than a bug fix, and the options
differ in what the feature means:

1. **Offer only AI rivals and companies whose player has left.** Honest and simple: the lobby becomes "take over
   a company nobody is playing". `takeover_candidates()` already knows which entries are players and which are
   `away`, so this is a filter.
2. **Let a takeover become a hand-over.** The named player is disconnected and the taker takes the seat. That is
   a real feature with real consequences (the other player is thrown out mid-session).
3. **Let two players run one company.** Shared control, which this mod deliberately is not.

I have not chosen, because it changes what the feature is for. The write-up records the fault instead of hiding
it behind a filter I picked unilaterally.

## Verified this pass

| | |
|---|---|
| `lobby_new_pressed` | opens the game's own company setup screen |
| `lobby_create_back` | returns to the choice list |
| `lobby_takeover_pressed` | commits the choice and asks for the world |
| `pressany` | reaches nodes under generated names; the whole lobby was unreachable before |
| Build guards | 28/28 |
| Relay cases | 16/16 |

## Still open

- The lobby's takeover list, as above - needs a decision.
- `lobby_cancel_pressed` is the fifth button and is deliberately not pressed in a run: it disconnects the client,
  which ends the test.
- **`logo`** unsendable (no `company_logo` on the player model); **`acquired`** refused by design;
  **`session_request`** sent by nothing.
- **Rendered panels**: the publish-offer list and the console panel have never been looked at as pixels.

---

# Pass 37: the takeover list, decided and fixed

The last pass stopped on a design fault and asked for a decision. The instruction was to continue, so I took the
least destructive option and recorded why: **a takeover offers AI rivals and companies whose player has left**.
That is what the code's own comment already claimed the feature was for ("players who are not connected right
now, which is exactly who a new joiner most likely wants to pick up"), and it is the only one of the three options
that neither throws a player out mid-session nor turns this into shared control.

## The change

`takeover_candidates()` now excludes **every company that is being played right now**, and takes the roster from
its caller:

```
takeover_candidates(connected)   # connected = this machine's id + every client the host has been told about
```

It has to be passed in because the file is static and cannot see the host's client list.

## Why the first two attempts did nothing

Worth recording, because it took three runs to find and each step was visible only after adding a log line:

1. **Filtering on `coop-state.present` does not work.** The host never writes `present` for its own record, so on
   the machine that *builds* the list its own company reads as "away" and is offered anyway.
2. **Comparing against the player model's `id` does not work either.** The mod keys companies by `coop-<name>`
   (`make_id`); the game's own player id is a different value, so the exclusion matched nothing. Passing
   `__local_id()` fixed that.
3. **The list is built from two loops, and only one was filtered.** Even with the live-rival loop excluding
   correctly — the log said `not offered: [coop-highland]` — the same company came back through the second
   loop, which walks `coop-state` for companies the world remembers. That loop checked only the game's own id.

The lesson is the one this pass keeps relearning: `offering 1` next to `not offered: [coop-highland]` is a
contradiction no amount of reading the first loop could resolve. The count and the name had to be printed
together.

## Verified

```
host:   net: takeover list built excluding in-session player(s) 1, offering 0
client: lobby: 0 company/companies to take over, plus a new one
client: lobby: showing the company setup screen          <- New still works
client: lobby: back from the company setup screen, showing the choices again
```

And there is no takeover row to press (`no node called [take_1]`), on a fresh session where the only candidate was
the host's own company. Before this pass that row existed, was pressable, and could only fail.

The honest consequence, which the panel now shows rather than hides: **on a fresh session the takeover list is
empty**, because there is nothing in it that can legitimately be taken over. The lobby's other path — "start a new
company" — works as before.

## What this does and does not prove

It proves the list no longer offers something that cannot work, and that the filter is what removed it (before:
`offering 1`, after: `offering 0`, same world, same code path).

It does **not** prove that a departed player's company is still offered, because that needs two clients: one to
join, have a company, and leave; and another to arrive afterwards and find it. That is the test this change most
needs and it has not been run — the single-client harness cannot reach it.

## Still open

- **A departed player's company being offered** - needs a two-client run, as above.
- **`logo`** unsendable (no `company_logo` on the player model); **`acquired`** refused by design;
  **`session_request`** sent by nothing.
- **Rendered panels**: the publish-offer list and console panel have never been looked at as pixels.
- **`lobby_cancel_pressed`** is deliberately not pressed in a run: it disconnects the client and ends the test.

---

# Pass 38: the unstable build — what actually changed, and what it blocks

The Steam install was updated while this project was mid-flight. Recorded first, before touching anything,
because a write-up that does not match the installed build is worthless.

## GAME IDENTITY (new, replaces the old one)

| | |
|---|---|
| Steam `buildid` | **25961418** (was 25723493) |
| `appmanifest` LastUpdated | 2026-10-31 23:56 local |
| `CityGameStudio64.exe` | 17,027,584 bytes, SHA-256 `62B84148F31AAC20AA544D32DA62F2293888474D40A5BB28C582A4C690845EC1` |
| `data.pck` | 376,412,006 bytes |
| Engine | Godot 2.1.0, bytecode revision 2.1.3-stable (ed80f45) - unchanged |
| Layout | exe + `data.pck` + `steam_api64.dll` + `discord-rpc.dll` + **`send-presence.exe`** |

## The finding that matters: the scripts are now encrypted

```
ERROR: Condition "p_key.size() != 32" is true. Returning: ERR_INVALID_PARAMETER
   at: FileAccessEncryptedv3::open_and_parse
WARNING: Could not determine bytecode revision, not able to decompile scripts...
Decompiled scripts:                     0
Scripts not decompiled:                 932
Failed to decompile encrypted scripts! Set the correct key and try again!
```

Every `.gde` in the pack begins `GDEC` and must be opened by `FileAccessEncryptedv3` with a **32-byte key**. GDRE
Tools v2.7.4 - the version that produced `src/` for the previous build - cannot read any of them without that key.

So the previous build's `.gde` files *were* the encrypted format too, but this project already had a plain-text
`src/` tree (925 files) from an earlier decompilation, and every guard, every `check_*` and every "I read
`controllers/game.gd`" in these notes has been against **that** tree. That tree still describes the *old* build.

What this means concretely: **the source of the new build's scripts is not readable by me.** Any claim about how
its features work would be a guess, and this playbook forbids that.

## What IS readable

- `engine.cfb` (project config, `ECFG`) - the same format `build_mod.py` already parses. Autoloads, main scene,
  input mappings. This is what an autoloaded mod needs.
- `scenes/*.scn` - binary `RSRC`, but the node tree, resource paths and **script paths** are plain ASCII inside
  it. Enough to know which script backs which scene, not what it does.
- Everything else (assets, themes, fonts, translations) as before.

## The headline, tested rather than assumed

**The existing mod builds, boots and reaches a live game on the unstable build.**

```
INFO coop mod 0.1.0 booted
INFO compile: res://coop/remote.gd ok  ... (every mod script compiles)
INFO menu: multiplayer entry added to the left of the game's own entries
INFO selftest: game state is loaded
INFO selftest: ready
```

`build_mod.py` copied the new pack, injected the mod, updated the autoload list and re-verified the MD5s. The
mod's own files are plain GDScript and are unaffected by the encryption - which only covers the *game's* scripts.

Also unchanged on this build, and still absent: `TCPServer`, `NetworkedMultiplayerPeer`, `NetworkedMultiplayerENet`
and `JSON` are all MISSING, so the off-game relay is still necessary and nothing about the networking model
changes.

## A correction to my own first reading

I initially reported the mod system ("Build a mod", `scenes/mod/`, `mod-manager`) as a new feature of the unstable
build. **It is not.** `src/scenes/mod/` and `src/scenes/mod-manager.tscn` exist in the old build too. The unstable
build may well change it, but I cannot read the scripts to say how, so I am not claiming anything about it.

## Where this leaves "work with its new features"

Three honest options, and the first one is a question for the owner rather than something I should decide:

1. **Get the key.** If the unstable build's scripts are encrypted with a key the owner has or can obtain (the
   developer's own tooling, a beta branch note, or the key compiled into the exe), everything opens up. Without
   it, "its new features" cannot be read, only observed.
2. **Work behaviourally.** The mod still loads, and the game still exposes its models and controllers *at runtime*.
   The `remote` channel (`own`, `state`, `clock`, `trends`, `research`, `pick`) can enumerate what a feature does
   by inspecting the live models, without reading a line of its source. Slower and weaker than reading code, but
   real - and it is how the lobby's fault was found.
3. **Stay on the old build** for the verified work until the unstable one is readable, and treat the new build as
   "loads, not yet characterised".

I have not changed any mod logic for the new build, because I cannot see what changed. Recording that is more
useful than a plausible-looking guess.

## What is verified about the new build

| | |
|---|---|
| Mod builds against it | yes - pack copied, injected, MD5s verified |
| Mod boots | yes - `coop mod 0.1.0 booted`, all scripts compile |
| Reaches a live game | yes - `selftest: game state is loaded`, `ready` |
| Game scripts readable | **no** - 0 of 932, encrypted with a 32-byte key |
| Networking classes | unchanged - `TCPServer` etc. still absent |

## Next

Ask for the key, or characterise the new features behaviourally through the live models. Everything in these
notes up to pass 37 describes the **previous** build (`25723493`) and should be read that way until re-verified.
