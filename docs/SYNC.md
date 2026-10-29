# What is synced, model by model

The game's state is a dictionary of models (`models.get_data()`). This page says, for each one, who
owns it and how it gets to the other machine.

Three categories:

- **world** — the host's. Transferred once on join.
- **company** — each player's own. Replaced from the local copy; the other side receives a summary so
  it can be shown as a rival.
- **isolated** — not synced by design. Each player has their own and they are emptied or kept locally.

---

## The 28 company models

`COMPANY_MODELS` in [`../mod/coop/main.gd`](../mod/coop/main.gd). A client boots the host's world and
then **replaces all of these with its own**, so it is not a copy of the host.

| Model | Holds |
|---|---|
| `player` | identity: company name, player name, logo, colours, difficulty |
| `staff` | every employee, their desk, their simulation |
| `currency` | money, reports, mortgage |
| `fanbase` | how many people follow you |
| `game` | the catalogue: dev, hold, published, released, canceled |
| `game-sell` | per-game sales, bonuses |
| `game-purchase` | games bought from other companies |
| `game-port` | porting work |
| `remake` | remakes |
| `game-update` | DLC and updates |
| `game-interview` | interviews |
| `post-mortem` | what was learned from a finished game |
| `review` | reviews received |
| `marketing` | campaigns, target audience |
| `market-research` | research |
| `recruitment` | the hiring pool and your candidates |
| `training` | training in progress |
| `notification` | inbox |
| `contract` | contract work |
| `building` | buildings owned |
| `server` | server usage, cloud, monthly cost |
| `achievements` | progress |
| `item` | awards and rewards placed |
| `studio-director` | the magazine / director state |
| `twitch-employee` | streaming staff |
| `product-sale` | what you are selling |
| `custom-platform` | **your own console** |
| `digital-store` | platform support and per-platform userbase |

`custom-platform` and `digital-store` are the two that caused the longest bug: taken from the host, a
brand-new company "owned" the host's console and inherited its users. `state_sync.isolate_store()`
empties the store for a client, and `__hold_own_server()` keeps server usage at zero while the company
owns no console — because `_update_platforms` runs on every `end_of_week` and would otherwise refill it
one tick after the join.

## The world

| Model | Why it is the host's |
|---|---|
| `map` | tile ids are global. A studio id **is** a map tile id, so a client's office must be opened on the host's map |
| `date` | one clock. A client that drifts is corrected; the correction emits `month` so the HUD repaints |
| `concurrent` | the AI rivals |
| `convention` | half of it: see below |
| everything else the host sends | the client boots it and then overwrites the 28 above |

## Conventions are split down the middle

`convention` is the clearest example of the world/company rule, and the experiment that proved it:

| field | belongs to |
|---|---|
| `generated`, `announced` | **the world.** Which events exist is a fact about the save |
| `planned`, `running`, `archived`, `autoattend` | **each player.** What you did with them is yours |

`state_sync.convention_catalogue()` carries the first pair in every company record;
`isolate_conventions()` empties the second on join. Proven: a client with 0 planned, 0 running, 0
archived and auto-attend off, while still knowing the shared catalogue.

## Per-player progression that is not shared

| Model | What it holds | State |
|---|---|---|
| `game-engine` | `_owned` engines | **isolated.** Each player researches their own |
| `game-type` | unlocked genres | **isolated** |
| `capacity` | unlocked project capacities | **isolated** |
| `game-of-the-year` | awards | **isolated** |
| `game-combos` | combo bonuses | **isolated** |

There is no design for sharing these. The consequence is that two players on the same date can have
different engine and genre reach — measured equal once, on a fresh game, but not over a played year.

## The rival game transplant, and the crash it caused

When the host receives a client's company, it shows those games as *that company's* games so they
appear in the publish-offer feed. `company.sync_games()` therefore copies a rival game's `theme` — but
only **if this machine's trend table knows that theme**, and it carries the `types` too.

That guard is not defensive coding. `scripts/models/game-theme.gd get_trend_by_theme(name)` indexes
`__trend_data[name]` without checking, and `__trend_data` is **per-save** (`data.trends`) while
`game_themes` is the static catalogue. A theme the save has no trend entry for throws,
`_compute_game_sale` returns null, `compute_sales` dereferences it — and the process dies with
`0xc0000005`. That was "the host crashes when a player creates a game", for several sessions.

## Company record shape

`company.record()` writes:

```json
{ "v": 1, "id": "...", "name": "...", "note": 0.0,
  "fanbase": 0, "currency": 300004, "studios": 1,
  "offices": [{"t": "<tile id>", "n": "Home"}],
  "layouts": [{"t": "<tile id>", "items": {...}, "area": 497, "buildMod": {...}}],
  "consoles": [...], "games": [...], "genres": [...],
  "conventions": {"generated": {...}, "announced": {...}} }
```

`studios` is a **count**; `offices` is the list. `layouts` holds the furniture, keyed by the same tile
id. A returning player's tiles do not exist on the new host's map, so `restore_from_world()` reopens
an office on a free tile and furnishes it from the matching layout — that is what "your interiors come
back" means mechanically.

Reading `studios` as a list crashed the client outright the first time the relay replayed a record.
Both shapes are read now, with a `typeof` check.
