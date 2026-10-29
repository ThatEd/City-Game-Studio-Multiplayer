# How the game was opened

For someone who needs to redo this, or who is wondering why the build has to patch a pack at all.

## The game

| | |
|---|---|
| Title | City Game Studio |
| Steam app id | `726840` |
| Version tested | **v1.28.1**, Steam build `25723493` |
| Executable | `CityGameStudio64.exe`, 17,027,584 bytes, PE32+ x64 |
| Engine | **Godot 2.1.7-stable**, custom build |
| Content | `data.pck`, 376,378,687 bytes, 6,869 entries |

The engine identifies itself as Godot 2.1.7, which matters for everything below: the script format is
`.gde` (compiled bytecode), the settings live in `res://engine.cfb`, and the API is Godot **2**'s.

**Version correction, kept visible on purpose.** An earlier pass recorded `1.29.0-rc3`, taken from the
store page. The build actually installed and tested reports **v1.28.1** in its own menu, and its own fresh
company data says `"version":"v1.28.1"`. Steam build `25723493` is the identity to match on; a version
string read off a store page is not the version of the thing that ran.

## The pack was encrypted, and the key is in the exe

`data.pck` is a Godot 2 pack whose entries are encrypted with `FileAccessEncrypted`. The key is not
shipped as data; it is derived inside the executable. `local/CGS/re/crack_key.py` finds it by brute force
over 32-byte windows, and it sits at exe offset `0xF47010`.

`decrypt_all.py` decrypts entries; `patch_cfb.py` edits `engine.cfb`. Together they produce a readable
copy of the game's scripts. **None of that is in this repository** — the extracted scripts are game
data. What is here is the *result*: the mod, and the facts the mod relies on.

## How the mod gets in without re-encrypting anything

The important discovery: **`remap/all` in `engine.cfb` maps `res://x.gd` → `res://x.gde`**, and Godot
resolves that *before* deciding what to load. Dropping the pair for a script, and adding a plaintext
`res://scripts/x.gd` to the pack, makes the engine load the plaintext file. No encryption key is needed
to ship a mod — only to read one.

So the build:

- adds `res://coop/` (the mod) as plaintext `.gd`;
- replaces `res://scripts/errorhandler.gd` and **deletes its `.gde` remap**;
- adds `autoload/coop` pointing at `res://coop/main.gd`.

The retail exe runs the modded pack unchanged. There is no patched executable.

## What the engine turned out to be missing

The first hours were spent assuming Godot 2 API and being wrong. The mod probes the engine at boot and
logs what it finds:

```
class: TCPServer MISSING
class: NetworkedMultiplayerPeer MISSING
class: NetworkedMultiplayerENet MISSING
class: JSON MISSING
class: StreamPeerTCP present
class: PacketPeerUDP present
class: StreamPeerSSL present
class: Thread present
```

`TCPServer` is gone. That single fact dictates the whole architecture: the game cannot listen, so a
relay exists, so the session has three processes. It was not a design preference.

Separately, and much more dangerous, **half the Variant API is missing**:

`Dictionary.get()`, `Object.get()`, `Array.to_json()`, `Array.extend()`, `CanvasItem.get_viewport_rect()`,
and `Node.get_class()` on a plain Object.

Calling one is **not** an error you can catch. It is `0xc0000005` at `0xae5633` — inside
`_VariantCall::FuncData::call` — and the process ends with no GDScript error anywhere. That offset is
where every one of this project's unexplained crashes landed.

Also absent: `ColorRect`, `InputEventMouseButton`, `InputEventKey`, `InputEventAction`, `InputEvent`.
`InputEvent.new()` does not exist either, which is why a test cannot synthesise a click and has to emit
the signal a node's own `_input()` would have emitted.

## The script format

`.gde` is Godot 2 compiled bytecode. Decompiling it gave a working source tree — enough to read the
game's own logic (`controllers/date.gd`, `models/game-theme.gd`, `popup-manager.gd`) and to find the
places a mod has to be careful. Three of those findings decided real bugs:

- `controllers/date.gd compute_state` freezes the clock unless the game's main scene is on top — so any
  popup stops game time.
- `models/date.gd set_raw_date()` assigns and emits **nothing**; the HUD repaints only on `month`.
- `models/game-theme.gd get_trend_by_theme()` indexes a **per-save** table without checking, and that
  is the crash that looked like "the host crashes when a player creates a game".

## Tools used

| | |
|---|---|
| `local/CGS/tools/gdre` | GDRE Tools, to decompile `.gde` |
| `local/CGS/tools/Sandboxie-Plus` | isolating a test copy |
| `local/CGS/re/` | the key crack, the decryptor, the `.cfb` editor |
| `local/CGS/refs/` | Godot 2.1.6 engine sources, used to know exactly what the API does |
| `tools/godotpck` | the pack reader/writer, vendored in this repo |
| Ghidra | for the crash offsets |

## The one thing worth taking from this page

**Probe the engine; do not assume Godot 2.1 means Godot 2.1.** A custom build can remove classes, and
the failure mode is not a helpful error — it is either a compile error that silently disables a whole
file, or a native crash at `0xae5633`. The mod's own boot log is the cheapest defence: it lists which
classes are present and compiles every script, both in the first second of every run.
