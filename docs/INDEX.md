# Documentation index

One page per topic. Claims are labelled, and the labels are the point:

- **proven** — a command that ran, with its output
- **derived** — reasoned from proven facts, not itself observed
- **unknown** — nobody has checked
- **wrong** — tried, did not work; kept so it is not tried again

Several conclusions in this project have been retracted once. The retractions stay visible rather
than being quietly edited out, because the next person will otherwise repeat them.

## Start here

| Page | What it answers |
|---|---|
| [README.md](../README.md) | What works, what does not, and what it would take |
| [PLAY.md](PLAY.md) | **For a player.** Exactly what to type, and what will go wrong |
| [STATE.md](STATE.md) | The full honest state of co-op: every subsystem, one line each |
| [REVERSE-ENGINEERING.md](REVERSE-ENGINEERING.md) | How the pack was opened and what the engine turned out to be |

## How the co-op works

| Page | What it covers |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Host/client roles, the relay, the world-vs-company split, message types |
| [SYNC.md](SYNC.md) | What is synced, model by model, and why the split is where it is |
| [DISCONNECT.md](DISCONNECT.md) | What happens when the host dies: the screen, the save, the store, the returning player |
| [FAIL-POINTS.md](FAIL-POINTS.md) | Every subsystem that could still break, with evidence labels |

## The tooling

| Page | What it covers |
|---|---|
| [QA.md](QA.md) | The three test layers, what each proves, and what none of them prove |
| [REMOTE.md](REMOTE.md) | The remote-control channel: commands, how to drive the UI, and its traps |
| [BUILD.md](BUILD.md) | The build pipeline, and the four kinds of failure it refuses to ship |

## The rules, condensed

Full list with incidents in [NOTES.md](NOTES.md). The ones that cost the most:

- **A `.gd` that fails to compile is silent.** The engine keeps the last version it loaded. Every fix
  in that file is inert while the log says nothing useful. `build_mod.py` compiles every script before
  packing, and the mod compiles every script again at boot.
- **Naming a class this build lacks is a compile error.** `TCPServer`, `JSON`,
  `NetworkedMultiplayerPeer`, `NetworkedMultiplayerENet`, `ColorRect`, `InputEvent*` — none exist.
- **Half of Godot's Variant API is missing.** `Dictionary.get()`, `Object.get()`, `Array.to_json()`,
  `Array.extend()` — and calling one is a native crash, not an exception.
- **A missing Variant member is `0xc0000005` at `0xae5633`.** That offset is the member call, not your
  code. `--coop-trace-steps` names the last stage that survived.
- **The clock only runs when nothing is open.** `controllers/date.gd` freezes unless the game's main
  scene is on top. Any popup stops game time.
- **`set_raw_date()` emits nothing.** The HUD calendar repaints only on `month`, so a correction must
  emit it or the visible clock keeps lying.
- **A node found by name is not necessarily the node you meant.** Three are called `release`.
- **A test that runs to its full duration buries a crash.** End the run when a peer dies.

## Reading order for someone picking this up

1. [STATE.md](STATE.md) — what is done, one line each.
2. [ARCHITECTURE.md](ARCHITECTURE.md) — the shape, so the code reads as intended.
3. [FAIL-POINTS.md](FAIL-POINTS.md) — what will break next, and what to try.
4. [NOTES.md](NOTES.md) — the incidents, so they are not repeated.
