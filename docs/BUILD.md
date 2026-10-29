# The build pipeline

`build/build_mod.py` turns a retail install into a runnable modded copy. It writes nothing into the
install.

```powershell
python build\build_mod.py --install "<game dir>" --out <dir> [--no-verify]
```

It writes a **complete copy** of the game with the mod injected, then verifies what it wrote.

## What it does

1. **Collects the mod source** (`mod/coop/*`, `mod/scripts/*`) plus a generated icon.
2. **Static-checks it** — three checks, described below. A failure here stops the build.
3. **Patches `data.pck`** — adds the mod files under `res://coop/`, replaces
   `res://scripts/errorhandler.gd` (dropping its `.gde` remap), recomputes every MD5.
4. **Patches `engine.cfb`** — adds `autoload/coop = *res://coop/main.gd` so the mod boots, and drops
   the remaps of any script it replaced.
5. **Verifies** — pack MD5s, the autoload entry, and every mod file being present. Last line:
   `verified: pack MD5s, autoload and mod files present`.

The install is opened read-only. The evidence for that is simply that the owner's `data.pck` still has
its original timestamp and SHA-256 after dozens of builds.

## The three static checks, and why each exists

Each one was added after a specific failure that wasted a session.

### `check_gdscript` — would the engine compile this?

A `.gd` that fails to compile is **not** a loud failure. The engine keeps running the last version it
managed to load, so every fix in that file is inert while the log fills with `Compile Error` somewhere
you are not looking. Two "verified" runs were spent on exactly that.

It catches the three mistakes that actually produced it:

- an identifier used outside the block that defines it
- two statements joined onto one line (this is easy to do when editing, and it bit twice)
- unbalanced brackets

It also cross-checks module-qualified calls (`company.something(...)`) against the functions that
module actually defines — a renamed helper that one call site still uses raises
`Nonexistent function` at **runtime**, inside whatever was running, which is how an entire verification
suite died silently for three runs while looking like it passed.

### `check_missing_classes` — does this engine actually have that class?

Naming a class this build lacks is a **compile error**, so the whole file is inert. The list is
`TCPServer`, `NetworkedMultiplayerPeer`, `NetworkedMultiplayerENet`, `JSON`, `ColorRect`,
`InputEventMouseButton`, `InputEventKey`, `InputEventAction`, `InputEvent`. All verified absent by
probing the exe.

The mod does the same check again at **boot**, logging `class: X MISSING`, which is how the absence was
discovered rather than assumed.

### `check_native_killers` — a Variant member this build lacks

Worse than a compile error: calling one is a native crash, `0xc0000005` at `0xae5633`, with no
GDScript error at all. `Dictionary.get()`, `Object.get()`, `Array.to_json()`, `Array.extend()` are the
known ones; the check rejects the AST shapes that produce them.

## What the build cannot check

- **Whether the code works.** It proves the engine would accept it, not that it does anything useful.
- **Whether a runtime API exists.** A method that is missing on an object is `Invalid call` at the
  moment it runs. `--coop-trace-steps` is the tool: the last `trace: <stage> ok` before death names the
  call.
- **Whether the pack format is what it thinks.** `tools/godotpck` has its own verified tests; if a
  future patch changes the container, those fail first.

## Building without the hub

This repository vendors `tools/godotpck`, so the build works from a fresh clone. The resolver searches
upward for `pck.py` and `ecfg.py` and does not assume a particular depth — the earlier version used a
fixed `parents[1] / "tools"` guess, which stopped working the moment the working folders were
reorganised, with an `ImportError` at the top of the file that had nothing to do with packing.

## Cost

A build writes ~400 MB and takes a couple of minutes. That is why the static checks run **before** the
pack is written, and why `run_all_tests.py` calls them directly without building anything.

## The icon

`make_multiplayer_icon()` generates a two-people PNG into the pack rather than committing a binary. It
is drawn in code: a body-torso-head pair with rounded rectangles and sampled coverage, deterministic,
no asset to keep in sync.
