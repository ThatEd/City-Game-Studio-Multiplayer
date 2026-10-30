#!/usr/bin/env python3
"""Build a runnable, modded copy of City Game Studio from the retail install.

The retail game keeps everything in `data.pck` and the project settings in
`res://engine.cfb`. This script produces a *separate* folder holding the untouched
executable plus a patched pack, so the player's install is never modified.

What it injects:

- every file under `mod/`, laid out as `res://...` paths (`mod/coop/main.gd` ->
  `res://coop/main.gd`),
- replacement game scripts, listed in `REPLACED` (currently the error reporter, which
  otherwise posts every GDScript error to the developer's server),
- `autoload/coop` in `engine.cfb`, pointing at `res://coop/main.gd`, so the mod boots
  as a normal Godot singleton without touching a single game script,
- and it drops the `remap/all` pairs of the scripts it replaces, because Godot 2 loads
  `res://x.gd` through that table and would otherwise read the compiled `.gde`.

    python local/city-game-studio/build/build_mod.py --install "<game dir>" --out local/city-game-studio/build/out
    python local/city-game-studio/build/build_mod.py --install "<game dir>" --out <dir> --verify-run

`--key` is only needed to decompile, not to build: the build ships plaintext source.
"""
import argparse
import os
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


def _find_hub_tools():
    """The pack tool this build depends on, searched upward.

    This used to be a fixed `ROOT.parents[1] / "tools"` guess, which broke as soon as the working
    folders moved. It also assumed the hub layout. A published copy of this project carries its own
    `tools/godotpck`, so that is looked for first, and the hub layout second - the same script then
    works in the working area and in a fresh clone with no hub at all.
    """
    for candidate in [ROOT] + list(ROOT.parents):
        for relative in ("tools/godotpck", "tools", "tools/../tools/godotpck"):
            tools = candidate / relative
            if (tools / "pck.py").is_file() and (tools / "ecfg.py").is_file():
                return tools
    raise SystemExit(
        "could not find pck.py and ecfg.py by searching upward from %s; "
        "this project needs tools/godotpck next to it" % ROOT
    )


sys.path.insert(0, str(_find_hub_tools()))

import ecfg  # noqa: E402
import pck  # noqa: E402

MOD_DIR = ROOT / "mod"
AUTOLOAD_NAME = "coop"
BOOT_SCRIPT = "res://coop/main.gd"

# Game scripts replaced wholesale. Add a line here when the mod needs to own a game file;
# the build then drops that script's remap so the plaintext version is used.
REPLACED = {
    # The retail error handler posts every GDScript error to bugreport.binogure-studio.com.
    # The replacement logs locally instead, which also gives the mod an error channel.
    "scripts/errorhandler.gd": "scripts/errorhandler.gd",
}

COPY_AS_IS = ("CityGameStudio64.exe", "discord-rpc.dll", "steam_api64.dll", "send-presence.exe")


class BuildError(Exception):
    pass


def collect_mod_files():
    """{res:// path: bytes} for everything under mod/."""
    if not MOD_DIR.is_dir():
        raise BuildError(f"no mod directory at {MOD_DIR}")
    files = {}
    for path in sorted(MOD_DIR.rglob("*")):
        if path.is_file():
            files["res://" + path.relative_to(MOD_DIR).as_posix()] = path.read_bytes()
    if not files:
        raise BuildError(f"{MOD_DIR} is empty")
    missing = [name for name in [BOOT_SCRIPT] if name not in files]
    if missing:
        raise BuildError(f"mod is missing {missing}; the autoload would fail to load")
    return files


# --- the multiplayer icon ------------------------------------------------
#
# The menu entry needs a two-people icon in the same white-silhouette style as the game's own icons.
# The engine cannot load an SVG at runtime (Godot 2.1 has no SVG support) and the build has no
# rasteriser, so the drawing is done here from the same geometry as mod/coop/icon/multiplayer.svg and
# wrapped in one of the game's own .tex containers - a PNG byte-for-byte the length of the one it
# replaces, so every offset and length in the container stays valid.

TWO_PEOPLE_SVG = ROOT / "mod" / "coop" / "icon" / "multiplayer.svg"
ICON_TARGET = "res://coop/icon/multiplayer.tex"
ICON_TEMPLATE = "res://theme/icon/white/staff-128x128.tex"
ICON_SIZE = 128

# (cx, cy, head_r, x0, y0, w, h, corner) in the 128x128 space, matching the SVG.
PERSON_BACK = (84.0, 40.0, 13.0, 68.0, 54.0, 32.0, 34.0, 10.0)
PERSON_FRONT = (46.0, 52.0, 15.0, 26.0, 68.0, 40.0, 34.0, 10.0)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _inside_round_rect(x, y, x0, y0, w, h, r):
    x1, y1 = x0 + w, y0 + h
    if not (x0 <= x <= x1 and y0 <= y <= y1):
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def _coverage(person, x, y, samples=4):
    """How much of a pixel is inside the person, 0..samples*samples."""
    cx, cy, head_r, x0, y0, w, h, corner = person
    hits = 0
    for sx in range(samples):
        for sy in range(samples):
            px = x + (sx + 0.5) / samples
            py = y + (sy + 0.5) / samples
            if (px - cx) ** 2 + (py - cy) ** 2 <= head_r * head_r:
                hits += 1
            elif _inside_round_rect(px, py, x0, y0, w, h, corner):
                hits += 1
    return hits


def two_people_rows(size=ICON_SIZE, samples=4):
    """RGBA scanlines: white, alpha from 4x4 supersampled coverage."""
    full = samples * samples
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            hits = _coverage(PERSON_BACK, x, y, samples) + _coverage(PERSON_FRONT, x, y, samples)
            row += bytes((255, 255, 255, min(255, (hits * 255) // full)))
        rows.append(bytes(row))
    return rows


def _png_chunk(kind, payload):
    import struct
    import zlib

    body = kind + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def encode_png(rows, size=ICON_SIZE, pad_to=0):
    """A PNG of the given scanlines, padded with an ancillary chunk to exactly `pad_to` bytes."""
    import struct
    import zlib

    raw = b"".join(b"\x00" + row for row in rows)
    out = bytearray(PNG_SIGNATURE)
    out += _png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    out += _png_chunk(b"IDAT", zlib.compress(raw, 9))
    if pad_to:
        # A private ancillary chunk is a legal PNG, so the file can be grown to an exact size with it.
        room = pad_to - (len(out) + len(_png_chunk(b"IEND", b"")))
        if room < 12:
            raise BuildError(
                f"the two-people icon needs {len(out) + 12} bytes and the container has {pad_to}; "
                "the drawing has to be simpler"
            )
        out += _png_chunk(b"coOp", b"icon" + b"\x00" * (room - 4 - 12))
    out += _png_chunk(b"IEND", b"")
    if pad_to and len(out) != pad_to:
        raise BuildError(f"icon padding went wrong: {len(out)} bytes, wanted {pad_to}")
    return bytes(out)


def make_multiplayer_icon(pack):
    """The game's own .tex container with our two-people PNG inside it."""
    if ICON_TEMPLATE not in {entry.path for entry in pack.entries}:
        raise BuildError(f"the pack has no {ICON_TEMPLATE} to use as an icon container")
    template = pack.read(ICON_TEMPLATE)
    start = template.find(PNG_SIGNATURE)
    if start < 0:
        raise BuildError(f"{ICON_TEMPLATE} does not hold a PNG, so it cannot be used as a container")
    end = template.find(b"IEND", start)
    if end < 0:
        raise BuildError(f"{ICON_TEMPLATE} has no PNG end marker")
    end += len(b"IEND") + 4
    png = encode_png(two_people_rows(), ICON_SIZE, pad_to=end - start)
    return template[:start] + png + template[end:]


def patch_settings(cfb_bytes, mod_files):
    """Add the mod autoload and drop the remaps of replaced scripts."""
    entries = ecfg.parse(cfb_bytes)
    existing = {key for key, _ in entries}
    if f"autoload/{AUTOLOAD_NAME}" in existing:
        raise BuildError(f"engine.cfb already has autoload/{AUTOLOAD_NAME}; is this an already-modded build?")

    # `*` marks a singleton, matching how every other autoload is stored
    entries = entries + [(f"autoload/{AUTOLOAD_NAME}", _variant_string("*" + BOOT_SCRIPT))]

    replaced = ["res://" + name for name in REPLACED if "res://" + name in mod_files]
    entries, dropped = ecfg.drop_remaps(entries, replaced)
    return ecfg.build(entries), dropped


def _variant_string(text):
    import struct
    raw = text.encode("utf-8")
    return struct.pack("<I", 4) + struct.pack("<I", len(raw) + 1) + raw + b"\x00"


def build(install, out, verify=True):
    install = Path(install)
    out = Path(out)
    for name in COPY_AS_IS:
        if not (install / name).is_file():
            raise BuildError(f"{install} does not look like a City Game Studio install (no {name})")
    source_pck = install / "data.pck"
    if not source_pck.is_file():
        raise BuildError(f"no data.pck in {install}")

    mod_files = collect_mod_files()
    pack = pck.Pck.open(source_pck)
    cfb_name = "res://engine.cfb"
    if cfb_name not in {entry.path for entry in pack.entries}:
        raise BuildError("the pack has no res://engine.cfb; this build expects a Godot 2 export")
    original_cfb = pack.read(cfb_name)
    mod_files[ICON_TARGET] = make_multiplayer_icon(pack)

    new_cfb, dropped = patch_settings(original_cfb, mod_files)
    overrides = dict(mod_files)
    overrides[cfb_name] = new_cfb

    out.mkdir(parents=True, exist_ok=True)
    for name in COPY_AS_IS:
        target = out / name
        if not target.exists():
            try:
                os.link(install / name, target)
            except OSError:
                shutil.copy2(install / name, target)

    target_pck = out / "data.pck"
    pack.save(target_pck, overrides)

    result = {
        "out": out,
        "mod_files": sorted(mod_files),
        "dropped_remaps": dropped,
        "files": len(pck.Pck.open(target_pck)),
    }
    if verify:
        check = pck.Pck.open(target_pck)
        bad = check.verify()
        if bad:
            raise BuildError(f"built pack fails its own MD5 check: {bad[:3]}")
        settings = {key for key, _ in ecfg.parse(check.read(cfb_name))}
        if f"autoload/{AUTOLOAD_NAME}" not in settings:
            raise BuildError("built engine.cfb lost the mod autoload")
        for name in mod_files:
            if name not in {entry.path for entry in check.entries}:
                raise BuildError(f"{name} did not make it into the built pack")
        script_problems = check_gdscript(mod_files)
        script_problems += check_native_killers(mod_files)
        script_problems += check_missing_classes(mod_files)
        if script_problems:
            raise BuildError(
                "the mod has scripts the engine will refuse to compile, and a script that fails to "
                "compile keeps running as its previous version, so every change in it would be "
                "silently ignored:\n  " + "\n  ".join(script_problems)
            )
        result["verified"] = True
    return result


MOD_HELPERS = {    "catalogue", "catalogue_name", "log_studios", "my_home_office", "my_consoles", "my_genres",
    "my_games", "apply_consoles", "apply", "spawn", "prune", "snapshot", "save_into_world",
    "load_from_world", "restore_from_world", "restore_studio", "restore_competitor",
    "is_player_company", "make_id", "record", "change", "sync_studios", "sync_games",
    "publish_offers", "owned_studios", "studio_layouts", "count_player_studios",
    "first_player_studio", "find_empty_office", "furnish_first_office", "open_first_studio",
    "open_new_office", "adopt_existing_office", "ensure_single_home", "home_office_count",
    "has_workstation", "foreign_consoles_supported", "foreign_server_users", "choose",
    "name_self", "release_studios", "restore_studio", "join", "is_home_building",
    "encode_models", "decode_models", "merge_company", "merge_company_for_takeover",
    "empty_studios", "saved_company", "load_company_backup", "first_studio", "capture_models",
    "isolate_store", "make", "describe", "apply", "pending_for", "store", "set_status",
    "is_settled", "field", "text", "number", "flag", "make_id", "__local_id",
}


def check_missing_classes(files):
    """Refuse to ship a mod that names an engine class this build does not provide.

    A missing class is a *compile* error, and a mod script that fails to compile keeps running whatever
    the loader already registered - silently losing the rest of the file. The symptom is not an error at
    the point of the mistake but "Nonexistent function" the first time the missing half is used, which is
    how a remote-control command answered nothing at all for an hour. Only classes already probed against
    this build belong in this list; the list is what --coop-* discovery has confirmed is absent.
    """
    missing = {
        "TCPServer", "NetworkedMultiplayerPeer", "NetworkedMultiplayerENet", "JSON",
        "ColorRect", "InputEventMouseButton", "InputEventKey", "InputEventAction", "InputEvent",
    }
    problems = []
    pattern = re.compile(r"(?<![\w.])(" + "|".join(sorted(missing)) + r")\.new\(")
    for name, data in sorted(files.items()):
        if not name.endswith(".gd"):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split("#", 1)[0]
            if not code.strip():
                continue
            for match in pattern.finditer(code):
                problems.append(
                    f"{name}:{number}: {match.group(1)} does not exist in this build, so naming it is a "
                    "compile error that disables the rest of the file"
                )
    problems.extend(_check_missing_operators(files))
    problems.extend(_check_missing_methods(files))
    problems.extend(_check_structure(files))
    problems.extend(check_date_rewind(files))
    return problems


def _check_structure(files):
    """Functions with no body, and functions defined twice.

    Both are parse errors the engine rejects at load, and both were produced by editing: a partial
    replace left `func __lobby_panel():` twice - once complete, once truncated to its signature - and
    the whole of main.gd stopped loading. The mod booted as nothing at all: no log, the retail menu with
    no Multiplayer button, and no error anywhere except one line from the error handler. Two instance
    launches and a rebuild were spent finding it.
    """
    problems = []
    for name, data in sorted(files.items()):
        if not name.endswith(".gd"):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        lines = text.splitlines()
        seen = {}
        for index, line in enumerate(lines):
            match = re.match(r"^func (\w+)\s*\(", line)
            if not match:
                continue
            func = match.group(1)
            if func in seen:
                problems.append(
                    f"{name}:{index + 1}: {func}() is already defined at line {seen[func]}; a "
                    "duplicate definition is a parse error that stops the whole file loading"
                )
            else:
                seen[func] = index + 1
            # A signature with no indented line after it (allowing comments) has no body.
            has_body = False
            for follower in lines[index + 1:]:
                if not follower.strip() or follower.strip().startswith("#"):
                    continue
                has_body = follower.startswith(("\t", " "))
                break
            if not has_body:
                problems.append(
                    f"{name}:{index + 1}: {func}() has no body; a bare signature is a parse error "
                    "and stops the whole file loading"
                )
    return problems


# Language constructs that parse in modern GDScript and are *parse errors* here.
#
# Found the hard way: `if child is Button:` took out all of lobby.gd with
# "Parse Error: ':' expected at end of line", and the only reason it was visible at all is that the
# mod compiles every script at boot. The game's own scripts never use `is`, which was the clue.
_BAD_CONSTRUCTS = (
    (re.compile(r"(?<![\w.])if\s+[^:#]*\bis\s+[A-Z]"), "`is` is not an operator in this engine build",
     "Recognise a node by has_method() instead."),
    (re.compile(r"\bawait\b"), "`await` does not exist in Godot 2",
     "Use yield() or a signal callback."),
    (re.compile(r"\bclass_name\b"), "`class_name` does not exist in Godot 2",
     "preload() the script and call its statics."),
    (re.compile(r"\bfunc\s+\w+\([^)]*\)\s*->"), "return-type annotations do not exist in Godot 2",
     "Leave the type off."),
    (re.compile(r"\bvar\s+\w+\s*:[^=]*="), "typed variable declarations do not exist in Godot 2",
     "Leave the type off."),
    (re.compile(r"\bexport\s*\("), "`export(...)` syntax does not exist in Godot 2",
     "This mod builds its nodes in code."),
    (re.compile(r"\bsignal\s+\w+\("), "signal declarations with parentheses do not exist in Godot 2",
     "This mod connects to the game's own signals."),
    (re.compile(r"^\s*match\s+\S"), "`match` does not exist in Godot 2.1",
     "Use if/elif on typeof()."),
    (re.compile(r"\bfunc\s+\w+\([^)]*\)\s*->"), "return-type annotations do not exist in Godot 2",
     "Leave the type off."),
)


def _check_missing_operators(files):
    problems = []
    for name, data in sorted(files.items()):
        if not name.endswith(".gd"):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split("#", 1)[0]
            if not code.strip():
                continue
            for pattern, what, fix in _BAD_CONSTRUCTS:
                if pattern.search(code):
                    problems.append(f"{name}:{number}: {what}; this build fails to parse it. {fix}")
    return problems


# Engine methods this build does not have. Calling one is either `Invalid call` at runtime or, for the
# Variant half, a native crash - so neither is catchable where it happens.
_MISSING_METHODS = (
    # The leading dot is optional: get_node_or_null() is usually called bare on self, and
    # can_instance() is called on a script.
    (re.compile(r"(?<![\w])get_node_or_null\s*\("), "get_node_or_null"),
    (re.compile(r"\.?can_instance\s*\("), "can_instance"),
    (re.compile(r"\.sort_custom\s*\("), "sort_custom"),
    (re.compile(r"\"\.join\s*\("), "String.join"),
)


def _check_missing_methods(files):
    problems = []
    for name, data in sorted(files.items()):
        if not name.endswith(".gd"):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split("#", 1)[0]
            if not code.strip():
                continue
            for pattern, method in _MISSING_METHODS:
                if method is None:
                    continue
                if pattern.search(code):
                    problems.append(
                        f"{name}:{number}: {method}() does not exist in this build; calling it is a "
                        "runtime error or a crash, not something that can be caught"
                    )
            # Emitting a *model's* signal runs every listener the game registered on it. `month` alone has
            # 23 - sales, awards, trades, conventions, digital stores - so emitting it out of band ran a
            # whole month's business cycle inside a clock correction and crashed on a Variant this build
            # lacks. A model signal is the game's to emit; the mod calls the one handler it wants instead.
            if _is_game_signal_emit(code):
                problems.append(
                    f"{name}:{number}: this emits a signal on a game model, which runs every listener the "
                    "game registered on it; call the single handler you need instead"
                )
    return problems


# Signals a game model owns, that the mod must never emit.
_GAME_SIGNALS = (
    "month", "year", "end_of_week", "end_of_month", "end_of_year", "new_week",
    "before_end_of_month", "first_week_of_the_month", "monthly_report_reset",
    "start_game", "speed_changed", "freeze", "unfreeze", "update_season",
)


def _is_game_signal_emit(code):
    if "emit_signal" not in code:
        return False
    for signal_name in _GAME_SIGNALS:
        if f'emit_signal("{signal_name}")' in code:
            return True
    return False


def check_date_rewind(files):
    """Refuse a date correction that does not also discard the week the machine overshot.

    This is the guard for the `0xae5633` client crash, the longest-lived bug in this project. The game's
    date model queues week/month/year signals as the date crosses them and emits one per frame; it also
    keeps `_tick`, the progress through the current week. `set_raw_date()` touches neither.

    So a client pulled back a week kept the boundary signals it had already earned *and* a nearly-full
    `_tick`, crossed the same boundary again a frame later, and replayed a month or year cycle - on a
    machine that had deliberately muted part of the rival simulation. One of those listeners calls a
    Variant member this engine build lacks, which is a native access violation with no traceback.

    Any call that moves the date backwards must be paired with a discard. The pairing is checked by
    requiring `set_raw_date(` and the discard to appear in the same file, and by requiring the discard
    to be called from every function that rewinds. A guard that cannot fail is worse than none, so
    build_run_tests.py proves this one catches a rewind with no discard.
    """
    discard = "__discard_overshoot"
    problems = []
    for name, data in sorted(files.items()):
        if not name.endswith(".gd"):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if "set_raw_date(" not in text:
            continue
        if discard not in text:
            problems.append(
                f"{name}: calls set_raw_date() but never calls {discard}(); a rewound date keeps the "
                "stale boundary signals and the overshot _tick, which re-plays a month or year cycle "
                "and crashes at 0xae5633"
            )
            continue
        # Every function that rewinds has to discard, not just the file as a whole: the discard being
        # defined somewhere is exactly the shape of the change that looked applied and did nothing.
        lines = text.splitlines()
        current = ""
        rewinds = []
        discards = set()
        for index, line in enumerate(lines):
            code = line.split("#", 1)[0]
            header = re.match(r"^func (\w+)\s*\(", code)
            if header:
                current = header.group(1)
                continue
            if "set_raw_date(" in code and _moves_date_back(code):
                rewinds.append((current, index + 1))
            if discard + "(" in code:
                discards.add(current)
        for func, number in rewinds:
            if func in (discard, "__set_date"):
                # __set_date is the primitive; the guarantee lives in its callers.
                continue
            if func not in discards:
                problems.append(
                    f"{name}:{number}: {func}() rewinds the date without calling {discard}(); the "
                    "stale boundary signals will replay a month or year cycle (0xae5633)"
                )
    return problems


def _moves_date_back(code):
    """Whether this statement sets the date to something that can be *older* than it is now.

    Only a backwards move is dangerous: crossing a boundary on the way back and then crossing it again
    re-plays the cycle. A test that deliberately pushes the date forward (`+ 10`) is doing the opposite
    harm and needs no discard, and flagging it would be a false positive - which is how a guard gets
    switched off.

    Anything that is not obviously an increment is treated as a rewind, because the dangerous form is
    `set_raw_date(<some value>)` where the value is the world's, and that is the one that must be paired.
    """
    inner = code.split("set_raw_date(", 1)[1]
    # `get_raw_date() + N` / `get_raw_date() + delta` only ever moves forward.
    if re.search(r"get_raw_date\(\)\s*\+\s*[A-Za-z0-9_]", inner):
        return False
    return True


def check_native_killers(files):
    """Refuse the calls that crash this engine build instead of raising an error.

    This build is a custom Godot 2.1.7 whose Variant method table is incomplete. Calling a member that is
    missing does not throw: it dereferences a null and the process dies with 0xc0000005 at 0xae5633,
    inside _VariantCall::FuncData::call. That has now cost this project a host mid-playtest three times.
    `Dictionary.get()` is the famous one; `Object.get(...)` (used on model nodes) and
    `Array.to_json()` are the others seen so far, and `Array.extend()` - which is Godot 3, not 2.1 -
    killed a client the first time a diagnostic used it.
    """
    problems = []
    # `something.get("key")` / `something.get("key", default)` where `something` is not a known-safe
    # configuration object. globals_manager.get() and config.get() do exist; a model does not.
    safe_receivers = ("globals_manager", "ConfigFile", "config", "OS", "Input", "ProjectSettings")
    pattern = re.compile(r"\b([A-Za-z_][A-Za-z0-9_\.]*)\.get\(\s*[\"']")
    for name, data in sorted(files.items()):
        if not name.endswith(".gd"):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split("#", 1)[0]
            if not code.strip():
                continue
            for match in pattern.finditer(code):
                receiver = match.group(1)
                if receiver.split(".")[-1] in safe_receivers or receiver == "self":
                    continue
                # dict_lib.field()/text()/number() are the sanctioned replacements.
                problems.append(
                    f"{name}:{number}: {receiver}.get() kills this engine build "
                    "(0xc0000005); use dict_lib.field/text/number instead"
                )
            if ".to_json()" in code and _looks_like_array_call(code):
                problems.append(f"{name}:{number}: Array.to_json() is missing in this build")
            # Array.extend() arrived in Godot 3; this is 2.1, where the same statement dies the same way
            # as Dictionary.get(). It cost a client mid-playtest, in code that only ran on request.
            if re.search(r"\.extend\(", code):
                problems.append(
                    f"{name}:{number}: Array.extend() does not exist in this build "
                    "(0xc0000005); push_back in a loop instead"
                )
    return problems


def _looks_like_array_call(line):
    """Array.to_json() is missing; Dictionary.to_json() exists. Only flag an array-shaped receiver."""
    return bool(re.search(r"(\.keys\(\)|\.values\(\)|\.push_back|_list|\[\]|Array\()", line))


def check_gdscript(files):
    """Refuse to ship a mod whose scripts the engine will not compile.

    A GDScript file that fails to *compile* is not a loud failure: the autoload keeps running on the
    last version it managed to load, so every fix in that file is silently inert while the log fills
    with "Compile Error". Two "verified" runs were wasted on exactly that. The checks here are the two
    mistakes that produced it - an identifier used outside the block that defines it, and a statement
    joined onto the end of a previous line - plus bracket balance.
    """
    problems = []
    for name, data in sorted(files.items()):
        if not name.endswith(".gd"):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as exc:
            problems.append(f"{name}: not utf-8 ({exc})")
            continue
        problems.extend(_check_one_script(name, text))
    # Calls to functions this mod defines elsewhere in itself. A renamed helper that one call site still
    # uses raises "Nonexistent function" at *runtime*, inside whatever was running - which is how the
    # whole verification suite died silently for three runs while looking like it passed.
    defined = {}
    for name, data in files.items():
        if not name.endswith(".gd"):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for line in text.splitlines():
            stripped = line.strip()
            for prefix in ("func ", "static func "):
                if stripped.startswith(prefix):
                    signature = stripped[len(prefix):]
                    defined.setdefault(signature.split("(")[0].strip(), []).append(name)
    for name, data in sorted(files.items()):
        if not name.endswith(".gd"):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            body = line.split("#", 1)[0]
            # Only the module-qualified form, e.g. company.something(...), which is where a rename is
            # caught without guessing at GDScript's resolution rules.
            for module in ("company", "state_sync", "trade", "play_lib", "pilot_lib", "ui_lib", "menu_lib",
                           "dict_lib", "coop_log", "link_lib", "automation", "dict_probe"):
                marker = module + "."
                index = body.find(marker)
                while index >= 0:
                    tail = body[index + len(marker):]
                    if tail and (tail[0].isalpha() or tail[0] == "_"):
                        call = ""
                        for char in tail:
                            if char.isalnum() or char == "_":
                                call += char
                            else:
                                break
                        if call and (call + "(") in body[index + len(marker):] \
                                and call not in defined and call not in ("new", "has", "size", "get",
                                                                          "set", "keys", "values"):
                            # A parameter can legitimately be called `company`, so only report a name
                            # that looks like this mod's own naming (leading underscore or a word the
                            # mod actually uses as a helper).
                            if call.startswith("_") or call in MOD_HELPERS:
                                problems.append(
                                    f"{name}:{number}: calls {module}.{call}(), which nothing defines"
                                )
                    index = body.find(marker, index + len(marker))
    return problems


def _check_one_script(name, text):
    problems = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        # The mistake that started this: a statement joined onto the end of the previous one, because a
        # newline was lost. `func f():` is legal with the body indented on the next line; what is not
        # legal is the body appearing on the same line as the colon.
        body = line.split("#", 1)[0].rstrip()
        if not body:
            continue
        # A tab in the middle of a line is never valid GDScript: indentation only appears at the start of
        # a line. This is what catches two statements joined into one by a lost newline, which is the
        # mistake that has now silently broken the mod three times.
        stripped_leading = body.lstrip("\t")
        if "\t" in stripped_leading:
            problems.append(f"{name}:{number}: a tab appears mid-line, so two statements are joined")
            continue
        if ":" not in body:
            continue
        after_colon = body.split(":", 1)[1]
        if not after_colon.strip():
            continue
        if "\t" in after_colon and not after_colon.strip().startswith('"'):
            problems.append(f"{name}:{number}: a statement follows ':' on the same line")
    # Bracket balance, ignoring strings and comments.
    depth = {"(": 0, "[": 0, "{": 0}
    pairs = {")": "(", "]": "[", "}": "{"}
    in_string = None
    for number, line in enumerate(text.splitlines(), 1):
        index = 0
        while index < len(line):
            char = line[index]
            if in_string:
                if char == "\\":
                    index += 2
                    continue
                if char == in_string:
                    in_string = None
            elif char in "\"'":
                in_string = char
            elif char == "#":
                break
            elif char in depth:
                depth[char] += 1
            elif char in pairs:
                depth[pairs[char]] -= 1
                if depth[pairs[char]] < 0:
                    problems.append(f"{name}:{number}: unmatched '{char}'")
                    depth[pairs[char]] = 0
            index += 1
    for char, count in depth.items():
        if count:
            problems.append(f"{name}: {count} unclosed '{char}'")
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--install", required=True, help="retail install folder (read only)")
    parser.add_argument("--out", required=True, help="folder to build the runnable copy into")
    parser.add_argument("--no-verify", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = build(args.install, args.out, verify=not args.no_verify)
    except (BuildError, pck.PckError, ecfg.EcfgError) as exc:
        print(f"build failed: {exc}", file=sys.stderr)
        return 1
    print(f"built {result['out']} ({result['files']} files in the pack)")
    print(f"  mod files: {len(result['mod_files'])}")
    for name in result["mod_files"]:
        print(f"    {name}")
    for source, target in result["dropped_remaps"]:
        print(f"  replaced: {source} (was remapped to {target})")
    if result.get("verified"):
        print("  verified: pack MD5s, autoload and mod files present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
