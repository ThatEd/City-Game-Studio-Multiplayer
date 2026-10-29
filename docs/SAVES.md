# Saves

How a co-op save is stored, named, and served back to the right player.

## The problem with the game's own names

The game names a save after the player's id and keeps it in `user://`:

```
user://<player id>.cgs             the save
user://<player id>.cgs.autosave    the file being written
```

For single player that is right. For co-op it is wrong in three ways, all of which were observed:

1. **A client overwrites with the host's id.** A client boots the *host's* world, which carries the
   host's player id. The game derives the filename from that id at write time, so the client's save
   landed under the host's name - and on one machine, over the host's own file.
2. **The same person in two worlds.** A player who joins host A then host B has one id per session but
   one `lastsavegame`, so Continue loads whichever was written last - potentially the wrong world.
3. **A host adopts a client's identity.** `lastsavegame` is shared by every instance on a machine. A host
   started after a client session read the client's save name as its own, and published itself under the
   client's company name. Seen, then fixed.

## What a co-op save is called

```
user://coop-<session>-<player>.cgs
```

- **session** is the name of the save the host's world *is*. A world with no file yet (started from New
  Game) gets `coop-<host name>` instead, so two worlds played with the same host name do not collide.
- **player** is that player's own co-op id.

Both parts are reduced to a safe identifier: decoration (`user://`, `.cgs`, `.autosave`) and the shared
`coop-` prefix are stripped, then anything not `[A-Za-z0-9_-]` is dropped. The result is capped at 56
characters so the final name fits comfortably inside a filename limit.

A real example, from a verified run:

```
save: this world is [coop-Fresh]
lobby: my id [coop-tester], my save [coop-Fresh-tester]
net: company written as coop-Fresh-tester
```

`coop-tester.cgs` from an earlier run was left untouched - that is the isolation proof, not the log.

## How the name is applied

Through the game's own **Save As** path.

`save_game()` derives its filename from `data.player.id` inside a worker thread, and `player.get_data()`
hands back a fresh dictionary on each call - so writing to it changed nothing and the save still landed
under the host's id. `_save_game_as(name)` is the path the in-game *Save As* button uses: it takes the
name as an argument and passes it to the same worker. That is the one that works, and it means the mod is
using the game's own mechanism rather than fighting it.

The write is on a thread, so the caller waits for `is_saving()` to clear before reporting success - a
report of "written" before the file exists is not a verified save.

## What the relay keeps

The save **file never leaves the machine that wrote it**. What travels is the name, on the company record
that the client hands over:

```json
{ "id": "coop-tester", "name": "Saved Studio", ...,
  "save": "coop-Fresh-tester", "session": "coop-Fresh" }
```

`CompanyStore.KEPT` includes both fields, so:

- a returning player's company is replayed on join, as before;
- the lobby can tell the player which save is theirs **before** they land in a world:

```
lobby: this world is save [coop-Fresh], my id [coop-tester], my save [coop-Fresh-tester] (not written yet)
```

That is the "server feeds all the players the correct save" part: the identity of the save is
authoritative from the relay, and per-player, rather than being inferred from a machine-wide
`lastsavegame`.

## Why the file is not shipped

A save is the whole game state plus every player's company section. Sending it would be tens of megabytes
per join, it would put one player's world on another player's disk, and the host already has the only copy
that matters - it is the world everyone boots from. The per-player save exists so a player can carry on
alone or return later; the shared state comes from the host.

## Carrying on alone

`saves.export_to_single(session, player, plain_name)` copies a co-op save to a plain single-player name, so
a player who wants to continue without a host can. The reverse - importing a single-player save into a
session - is not built.

## What is not built

- No in-game save browser for co-op saves. They are files on disk like any other, and the game's own list
  does not filter them out, so they will appear there too.
- No automatic cleanup of a session's saves when the session ends.
- No merge: if two players' saves disagree with the host's world, the host's world wins.
