# Architecture

## The shape

```
   host machine                          relay (python)                      client machine
  ┌────────────────┐                   ┌────────────────┐                  ┌────────────────┐
  │  CityGameStudio│  StreamPeerTCP    │  coop_server   │   StreamPeerTCP  │  CityGameStudio│
  │  + coop autoload ├─────────────────►│  :port         │◄─────────────────┤  + coop autoload│
  │                 │                   │                │                  │                │
  │  owns: the world│  fan-out          │  routes        │  fan-out         │  owns: its own │
  │  date, map,     │  host → clients   │  host → clients │  host → clients  │  company       │
  │  rivals, company│  client → host    │  client → host  │  client → host   │                │
  │  table          │                   │  keeps stores   │                  │                │
  └────────────────┘                   └────────────────┘                  └────────────────┘
```

Three processes, always. There is no peer-to-peer path because **this engine build has no
`TCPServer`** — proven by probing the exe at boot and logged as `class: TCPServer MISSING`. The game
can dial out and nothing else. So the relay is not a design choice, it is the only option, and both
players run it on one machine or one of them hosts it.

## Roles

The role is decided at boot by a flag, not by connection order:

```
--coop-host                 this instance is the authority
--coop-join=<address>       this instance joins
```

`main.gd` is the autoload (`autoload/coop` in `engine.cfb`). It registers with the relay as its first
act (`{"t":"role", ...}`), and a client then sends `join_request`.

## The world, and the company — the split everything rests on

This is the single idea the whole mod is built around:

| | belongs to | how it moves |
|---|---|---|
| map, date, rivals, convention **catalogue** | **the host** | sent once on join, in pieces |
| identity, money, fanbase, staff, offices, interiors, games, sales, consoles, stores, conventions **plans** | **each player** | each machine keeps its own; the host is told about it so it can show them as a rival |

A client that used the host's company models would be a second copy of the host with different money.
A client that used the host's `digital-store` looked like it owned a console and 3 million users -
that was a real bug, and the fix is `state_sync.isolate_store()`.

## Message types

Every message is one JSON object with a `t` field. The relay does not interpret most of them.

**Host → clients (relayed verbatim)**

| `t` | Meaning |
|---|---|
| `world_begin`, `world_part` | the world transfer, one model per message |
| `clock` | the authoritative date, speed, paused |
| `companies` | the whole company table, every few seconds |
| `company` | one player's company record |
| `offer`, `offer_accept`, `offer_reject` | a trade |
| `joined`, `peer_left`, `state`, `digest` | presence and liveness |

**Client → host**

| `t` | Meaning |
|---|---|
| `join_request` | send me the world |
| `company` | here is my company (also kept by the relay) |
| `offer_request` | offer something to another player |
| `time_request` | may I pause / resume |

**Relay → client, relay's own**

| `t` | Meaning |
|---|---|
| `host_left` | the authority is gone; save and leave |
| `error` | no host is running, etc |

## The relay is not dumb

`server/coop_server.py` does four things beyond routing:

1. **Caches the host's world** so a joiner gets it without waiting for the host to re-encode it
   (`world` message, stored on the host's connection).
2. **Keeps every player's company on disk** (`--stores <dir>`), so a returning player is handed their
   company back — and survives a relay restart. Only the company travels; the map and the date belong
   to whoever hosts.
3. **Tells clients when the host dies**, and keeps their sockets open for 20 s so they can hand their
   own company over first. Closing in the same call was a real bug: the client's answer had nowhere to
   go, and everything since the host's last publish was lost.
4. **Frames messages** as `8 ASCII digits of byte length` + JSON. This matters more than it looks: the
   game reads frames as a `String` and uses the byte length as a character offset, which is only
   correct while the wire is pure ASCII. The relay forces `ensure_ascii=True` for that reason.

## Why one message is not one world

A single 8 MB message kills this build. `send_world()` therefore encodes per model and splits each into
`WORLD_PART_SIZE` pieces; `world_begin` says how many models to expect. The relay's write path is
non-blocking and **must** queue rather than drop: a game reads a frame a tick, and a `sendall()` on a
non-blocking socket used to raise `BlockingIOError`, which was treated as a dead peer and killed the
transfer halfway.

## Boot order

Godot 2 adds autoloads as children of the root *before* the main scene, so `coop`'s `_ready()` runs
while `models`, `scene_manager` and the rest already exist. The mod:

1. probes the engine for missing classes (`class: X MISSING`) - this is how the absence of `TCPServer`
   was found rather than assumed;
2. compiles every mod script and logs `compile: <path> ok|FAILED`, because a `.gd` that fails to parse
   silently keeps its previous version;
3. patches the main menu with a **Multiplayer** entry;
4. starts the network only when it can (`__can_join()`), which for a client means waiting for a world.

## What the mod replaces in the game

Two files, both in `mod/scripts/`:

| File | Why |
|---|---|
| `errorhandler.gd` | The retail one posts every error to the developer's server with the scene, the exe path and `OS.get_cmdline_args()` — i.e. it would leak the mod. This one logs locally and sends nothing |
| `models/coop-state.gd` | A new model holding per-player company sections inside the world save |

Everything else is added under `res://coop/` and does not touch game scripts.
