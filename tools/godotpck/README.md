# godotpck: read, extract and patch Godot `.pck` archives

Every exported Godot game ships its gameplay code, scenes and assets inside a `.pck`
(`data.pck` by default). The gameplay is compiled GDScript (`.gde` on Godot 2.x, `.gdc` on
Godot 3.x and 4.x). Co-op work on a Godot game needs two things constantly: get a file out to
read it, and put files back in — replaced scripts, or new scripts your mod adds. This tool does
both, without the Godot editor and without touching the player's install. `ecfg.py`, in the
same folder, edits the Godot 2 settings blob that decides whether a script is loaded as
compiled bytecode or as plaintext source.

It handles all three pack formats:

| Pack format | Engine | Header | Entry record |
|---|---|---|---|
| 0 | Godot 2.x | magic, format, engine version, 64 bytes reserved, count | path, u64 offset, u64 size, 16-byte MD5 |
| 1 | Godot 3.x | same | same |
| 2 | Godot 4.x | adds u32 pack flags and u64 file base | adds u32 flags per entry |

Path strings padded to 4 bytes (Godot 4.x exports) are detected automatically. The engine
verifies the MD5 of every file it loads, so a patched pack must recompute the MD5 of anything
it writes; the writer does that, and `verify` checks a pack against its own index.

## Usage

```
python -I tools/godotpck/pck.py info    <game.pck>
python -I tools/godotpck/pck.py list    <game.pck> [--include GLOB] [--grep TEXT]
python -I tools/godotpck/pck.py extract <game.pck> <outdir> [--include GLOB] [--grep TEXT] [--no-verify]
python -I tools/godotpck/pck.py patch   <game.pck> <new.pck> [--from DIR] [--include GLOB] [--delete PATH]...
python -I tools/godotpck/pck.py verify  <game.pck>
```

A typical first look at a new Godot game:

```
python -I tools/godotpck/pck.py info  <game dir>/data.pck
python -I tools/godotpck/pck.py list  <game dir>/data.pck --include '*.gde'
python -I tools/godotpck/pck.py extract <game dir>/data.pck local/<game>/scripts --include 'scripts/*'
```

Injecting files: lay them out as they should appear under `res://`, then patch a copy.

```
mkdir -p local/<game>/inject/scripts
# ... put your .gd files there ...
python -I tools/godotpck/pck.py patch "<game dir>/data.pck" local/<game>/coop.pck --from local/<game>/inject
```

`--delete res://scripts/foo.gde` drops entries (useful when the engine prefers a compiled file
over the plaintext one you added).

Never write into the game's install directory: patch a copy, and keep the shipped pack
untouched so a failed experiment costs nothing.

## Godot 2.x: making the engine load plaintext scripts (`ecfg.py`)

Godot 2 keeps the project settings in `res://engine.cfb` (magic `ECFG`): a list of
`key -> encoded Variant` pairs. Two keys matter:

- `remap/all`, a PackedStringArray of alternating `res://x.gd` -> `res://x.gde`. Godot resolves
  every load through it, and the GDScript loader picks its mode from the *remapped* path's
  extension. That is why a pack with only `.gde` scripts still has scenes that say
  `path="res://scripts/main.gd"`. Drop the pair and the same scene loads a plaintext `.gd`.
- `autoload/*`, the global singletons — where a mod wants a permanent hook.

```
python -I tools/godotpck/ecfg.py list   <engine.cfb>
python -I tools/godotpck/ecfg.py remaps <engine.cfb> [--grep scripts/]
python -I tools/godotpck/ecfg.py drop   <engine.cfb> <out.cfb> res://scripts/main.gd
```

A working pattern, run against City Game Studio's retail pack and verified in the running game
(see [games/city-game-studio](../../games/city-game-studio/NOTES.md)):

1. extract `res://engine.cfb` and the script you want, decompile the script with Godot RE Tools,
2. `pck.py patch game.pck new.pck --from inject/ --delete res://scripts/main.gde`, with the
   decompiled `inject/scripts/main.gd` and the `ecfg.py drop`-ed `inject/engine.cfb`,
3. run the game from a copy and look for your change (stdout may be disabled by the game's own
   `application/disable_stdout`, so change the window title instead of printing).

Things that bite:

- Keep `engine.cfb` byte-identical apart from the pairs you drop. `ecfg.py` treats every other
  value as an opaque blob for that reason; the tests assert that a parse/build round-trip
  reproduces the file exactly.
- Variant strings are `u32(len + 1)`, the bytes, a NUL, then padding to a 4-byte boundary.
  Godot will not read a config written without that padding.
- The engine tries `res://engine.cfg` (text) before `res://engine.cfb`. A pack that carries
  both uses the text one — useful if you would rather edit text, but only if you have the full,
  faithful config.

## What this tool does not do

It does not decrypt anything. Godot 2.x compiled scripts *are* encrypted by default:
`.gde` is `GDEC`, a mode word, 16 bytes of MD5 over the plaintext, a u64 length, then
AES-256-ECB ciphertext padded to 16 bytes, with a 32-byte key compiled into the exe. Those
files come out as ciphertext. Whether to recover that key is your owner's decision, not a
container-format problem; [games/city-game-studio](../../games/city-game-studio/NOTES.md)
records how that went there.

It also does not convert resources: `.scn` stays binary, `.tex` stays a compiled texture. Godot
RE Tools (`gdsdecomp`) does that side, and it can decompile Godot 2.x/3.x/4.x bytecode.

## Tests

```
python -I tools/godotpck/run_tests.py
```

Builds packs in all three formats, round-trips them, extracts with globs, patches (replace,
add, delete, patch-from-directory), tampers with a byte to check the MD5 guard, feeds it junk
headers, and runs the CLI. For `ecfg.py` it round-trips a settings file, decodes and re-encodes
the remap array, drops pairs, rejects junk. Five mutation twins prove the checks test something:
a writer that stamps zero MD5s, a delete that is ignored, data offsets that overwrite the
header, Variant strings written without padding, and a drop that leaves the pair in place must
all be caught.

Real-pack checks run when a pack is available:

```
python -I tools/godotpck/run_tests.py                                     # verifies every entry MD5
GODOTPCK_FULL=1 python -I tools/godotpck/run_tests.py                      # also rebuilds the whole pack
CGS_PCK=/path/to/other/data.pck python -I tools/godotpck/run_tests.py      # against another game
```

Default real pack: `B:\SteamLibrary\steamapps\common\City Game Studio\data.pck`. The suite
skips those checks when it is missing and still prints `ALL OK`. Against the retail City Game
Studio pack (6,869 files, 376 MB) all entry MD5s verify, a full rebuild reproduces every entry
hash, and its `engine.cfb` parses to 116 settings with 1,477 remap pairs (925 of them scripts).
