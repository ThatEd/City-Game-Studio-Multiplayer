# The lobby

The screen a player sees after choosing **Join a game**, before they enter anyone's world.

## Why it exists

The two buttons alone left a hole. "Host a game" and "Join a game" said how to connect and nothing about
*who you would be* once connected, so a joining player was silently given a brand-new company - and the
takeover path, which already worked, was reachable only from a command-line flag. A player could not
choose.

The lobby asks one question: **which company do you want to run in this world?**

- **Start a new company** opens the game's own company setup - name, randomise, logo, the logo drawer,
  genre specialisation - and creates that company when you confirm.
- **Take over a company** lists the companies in the host's world and hands you the one you pick,
  through the game's own acquisition path.

## The order that matters most: the lobby comes *before* the game

This is the part that was wrong first, and everything else follows from it.

The obvious implementation - send the world, then ask - cannot work. The world is what *creates* the
game, so by the time the client could be shown a list it had already loaded into someone else's studio
and there was nothing left to ask. That is exactly what happened: the first version's lobby was built,
populated, positioned and visible, and the screenshot showed the client standing in a game with the panel
nowhere in sight.

So the join is two round trips instead of one:

```
client                              host
  |  join_request  (auto: false)  ->  |
  |  <-  session_summary              |   the date, and every company in it
  |                                   |
  |  (the lobby is on screen here)    |
  |                                   |
  |  lobby_pick (choice) ->           |
  |  <-  world_begin / world_part...  |   only now does the world move
```

The summary is a few hundred bytes; the world is ~9 MB. The host builds the summary from its own live
models (`company.takeover_candidates()`), so it can never disagree with the world it describes.

`session_summary` also carries the **name of the save the world is** - see [SAVES.md](SAVES.md) for why
that matters.

### Automated runs

A script cannot press the lobby, so it says so and the host sends the world immediately:

| flag | effect |
|---|---|
| `--coop-company=<id>` | already decided; no lobby |
| `--coop-pilot=N` | a script is driving; no lobby |
| `--coop-lobby=off` | explicit |

`tools/run-coop.ps1 -Lobby` starts a client *without* deciding, which is how the lobby is tested.

## The pages

One panel, two pages, so nothing is torn down between them.

**Choose** - the player's first look:

```
Join a game
The host's world is here. Choose the company you want to run.
[ Start a new company ]
Or take over an existing company
[ Fresh Studio  -  player  -  1 office(s)  -  $300,004 ]
[ Back ]
```

Rows rank by: has offices first, then another player's company over an AI rival's, then someone who is
away. At most eight are shown - a world can hold 21 rivals.

**Create** - the game's own `res://scenes/new-game/company-item.tscn`, instanced inside the panel. Not a
reimplementation: the same fields, the same validation, the same logo drawer, so a player cannot get a
different company here than from New Game.

## Where it lives, and why that was a bug

The panel is attached to the **scene root**, not to the main menu. The world transfer pushes the game's
loading scene, which replaces the menu - a lobby parented to the menu would be freed at exactly the moment
it became useful.

Two consequences had to be handled:

- **It must be sized.** An anchorless Control added to the root keeps a zero-sized rect and draws nothing
  however visible it claims to be. `set_pos`/`set_size` is the pair the in-game panel already proved works
  in this build; the Godot 3 margin and anchor-preset calls are not available.
- **It must be raised.** The game adds its own scene to the root *after* the mod, so the lobby was
  completely covered: visible, correctly sized at `(202, 40, 722, 460)`, and invisible on screen. It is
  raised on show and again every frame while a choice is pending.

## Nodes cannot be found by name

In this engine build, a Control added at runtime is **not addressable by the name set on it**. The whole
lobby subtree reports as `@@38`, so `find_node("status")` finds nothing. Every lookup in `lobby.gd` walks
the tree comparing `get_name()` instead.

The same applies to the game's form: its name field is found by *what it can do* - `get_text`, `set_text`,
`get_cursor_pos` - not by its path.

## Driving it

`--coop-remote`, command `lobby`:

```
lobby                    what is on screen, and every row
lobby new                press "Start a new company"
lobby name <text>        type into the game's company form
lobby create             press "Create and join"
lobby take <index>       press row <index>
```

A verified session, end to end:

```
lobby: 1 company/companies to take over, plus a new one
lobby:   [coop-fresh] Fresh Studio  1 office(s)  $300004  (player)
lobby: showing the company setup screen
remote:     name set to [Neon Workshop]
lobby: new company called [Neon Workshop] (3 field(s))
lobby: chose a new company called Neon Workshop
lobby: asked the host for the world
company choice new -> named the company Neon Workshop Studio (...)
company: [Neon Workshop] studios=1 staff=1 published=0 currency=300006 ...
```

## What is not built

- No chat, no ready-check, no lobby for more than the players already in the session.
- A host cannot see the lobby; it is a client-side screen only.
- The list does not live-update: it is a snapshot taken when the summary arrived.
