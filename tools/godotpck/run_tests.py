"""Tests for pck.py, then one mutation twin per guard. Prints ALL OK only when every check
passes and every twin is caught.

    python -I tools/godotpck/run_tests.py

No game and no Godot editor is needed: the packs are built by the module itself in a temp
directory. If a real City Game Studio pack is found (env `CGS_PCK`, or the default Steam path
below), two extra checks read it: every entry MD5 is verified, and with `GODOTPCK_FULL=1` the
whole pack is rebuilt and compared entry by entry.

How twins work: each twin is the real module with one line broken on purpose (for example
"write a zero MD5"). A twin counts as caught only when the check that is supposed to notice
fails against it, which proves the check tests something.
"""
import importlib.util
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "pck.py"
ECFG_SRC = HERE / "ecfg.py"
REAL_PACK = os.environ.get(
    "CGS_PCK", r"B:\SteamLibrary\steamapps\common\City Game Studio\data.pck")
TMPS = []

FILES = {
    "res://project.godot": b"config_version=4\n",
    "res://scripts/main.gde": bytes(range(256)) * 4,
    "res://assets/a/b/icon.png": b"\x89PNG\r\n\x1a\n" + bytes(40),
    "res://empty.txt": b"",
}


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tmpdir():
    directory = Path(tempfile.mkdtemp(prefix="godotpck-"))
    TMPS.append(directory)
    return directory


def build(m, fmt=0, engine=(2, 1, 0), align=0, files=None):
    pack = m.new_pack(fmt, engine, align)
    target = tmpdir() / f"built-{fmt}.pck"
    pack.save(target, dict(files or FILES))
    return target


# --- checks ---------------------------------------------------------------

def check_roundtrip(m):
    for fmt, engine in ((0, (2, 1, 0)), (1, (3, 5, 3)), (2, (4, 3, 0))):
        path = build(m, fmt, engine)
        pack = m.Pck.open(path)
        assert pack.format == fmt, (pack.format, fmt)
        assert pack.engine == engine, (pack.engine, engine)
        assert len(pack) == len(FILES), (len(pack), len(FILES))
        for name, data in FILES.items():
            assert pack.read(name) == data, f"{name} came back changed in format {fmt}"
        first = min(entry.offset for entry in pack.entries)
        assert first == pack.index_end, f"data does not start after the index: {first} vs {pack.index_end}"
        assert sum(e.size for e in pack.entries) == path.stat().st_size - pack.index_end, \
            "file sizes do not add up to the pack size"


def check_v2_path_padding(m):
    path = build(m, 2, (4, 4, 0), align=4)
    pack = m.Pck.open(path)
    assert pack.path_align == 4, f"padded paths not detected: {pack.path_align}"
    for name, data in FILES.items():
        assert pack.read(name) == data


def check_extract_and_select(m):
    path = build(m)
    pack = m.Pck.open(path)
    out = tmpdir() / "extracted"
    written = pack.extract(out, include=["*.gde"])
    assert written == ["res://scripts/main.gde"], written
    assert (out / "scripts" / "main.gde").read_bytes() == FILES["res://scripts/main.gde"]
    assert [e.path for e in pack.select(grep="ICON")] == ["res://assets/a/b/icon.png"]
    assert len(pack.select()) == len(FILES)


def check_patch_replace_add_delete(m):
    source = build(m)
    pack = m.Pck.open(source)
    out = tmpdir() / "patched.pck"
    pack.save(out, {"res://scripts/main.gde": b"var coop = true\n"},
              delete=["res://empty.txt"])
    patched = m.Pck.open(out)
    names = [entry.path for entry in patched.entries]
    assert "res://empty.txt" not in names, "delete did not apply"
    assert patched.read("res://scripts/main.gde") == b"var coop = true\n"
    assert patched.read("res://assets/a/b/icon.png") == FILES["res://assets/a/b/icon.png"], \
        "an untouched entry changed"
    assert patched.verify() == [], "patched pack does not verify"

    added = tmpdir() / "added.pck"
    patched.save(added, {"res://scripts/coop/net.gd": b"extends Node\n"})
    last = m.Pck.open(added)
    assert last.read("res://scripts/coop/net.gd") == b"extends Node\n"
    assert last.verify() == []


def check_patch_from_dir(m):
    source = build(m)
    pack = m.Pck.open(source)
    injection = tmpdir() / "inject"
    (injection / "scripts").mkdir(parents=True)
    (injection / "scripts" / "coop.gd").write_bytes(b"# added by the mod\n")
    (injection / "scripts" / "main.gde").write_bytes(b"replaced\n")
    out = tmpdir() / "injected.pck"
    pack.patch_from_dir(injection, out)
    patched = m.Pck.open(out)
    assert patched.read("res://scripts/coop.gd") == b"# added by the mod\n"
    assert patched.read("res://scripts/main.gde") == b"replaced\n"
    assert len(patched) == len(FILES) + 1


def check_md5_guard(m):
    path = build(m)
    pack = m.Pck.open(path)
    entry = pack.find("res://scripts/main.gde")
    raw = bytearray(path.read_bytes())
    raw[entry.offset] ^= 0xFF
    path.write_bytes(bytes(raw))

    again = m.Pck.open(path)
    try:
        again.read("res://scripts/main.gde")
    except m.PckError:
        pass
    else:
        raise AssertionError("a corrupted entry was read without complaint")
    assert again.read("res://scripts/main.gde", verify=False)[0] != FILES["res://scripts/main.gde"][0]
    assert again.verify() == ["res://scripts/main.gde"], again.verify()


def check_rejects_bad_input(m):
    good = build(m)
    bad_magic = tmpdir() / "magic.pck"
    raw = bytearray(good.read_bytes())
    raw[0:4] = b"PCKG"
    bad_magic.write_bytes(bytes(raw))
    for path, why in ((bad_magic, "bad magic"),):
        try:
            m.Pck.open(path)
        except m.PckError:
            pass
        else:
            raise AssertionError(f"{why} was accepted")

    unknown = tmpdir() / "format.pck"
    raw = bytearray(good.read_bytes())
    struct.pack_into("<I", raw, 4, 7)
    unknown.write_bytes(bytes(raw))
    try:
        m.Pck.open(unknown)
    except m.PckError:
        pass
    else:
        raise AssertionError("an unknown pack format was accepted")

    truncated = tmpdir() / "short.pck"
    truncated.write_bytes(good.read_bytes()[:60])
    try:
        m.Pck.open(truncated)
    except m.PckError:
        pass
    else:
        raise AssertionError("a truncated pack was accepted")

    pack = m.Pck.open(good)
    try:
        pack.save(tmpdir() / "x.pck", None, ["res://not/there.gd"])
    except m.PckError:
        pass
    else:
        raise AssertionError("deleting an absent path was accepted")


def check_cli(m):
    good = build(m)
    script = HERE / "pck.py"
    info = subprocess.run([sys.executable, "-I", str(script), "info", str(good)],
                          capture_output=True, text=True)
    assert info.returncode == 0, info.stderr
    assert "Godot 2.x" in info.stdout, info.stdout
    listing = subprocess.run([sys.executable, "-I", str(script), "list", str(good)],
                             capture_output=True, text=True)
    assert listing.returncode == 0 and "res://scripts/main.gde" in listing.stdout, listing.stdout
    verify = subprocess.run([sys.executable, "-I", str(script), "verify", str(good)],
                            capture_output=True, text=True)
    assert verify.returncode == 0, verify.stderr


def check_real_game_pack(m):
    path = Path(REAL_PACK)
    if not path.is_file():
        print(f"  SKIP real pack not found at {path} (set CGS_PCK to point at one)")
        return
    pack = m.Pck.open(path)
    print(f"  real pack: {len(pack)} files, format {pack.format}, engine "
          f"{'.'.join(map(str, pack.engine))}")
    assert len(pack) > 1000, f"only {len(pack)} files, is this the right pack?"
    bad = pack.verify()
    assert bad == [], f"{len(bad)} entries failed their MD5, first {bad[0]}"
    scripts = [e for e in pack.entries if e.path.endswith((".gde", ".gdc"))]
    assert scripts, "no compiled scripts in the pack"
    print(f"  {len(scripts)} compiled scripts, all MD5s verified")
    if os.environ.get("GODOTPCK_FULL") != "1":
        print("  (set GODOTPCK_FULL=1 to rebuild the whole pack and compare it)")
        return
    out = tmpdir() / "repacked.pck"
    pack.save(out)
    again = m.Pck.open(out)
    assert [e.path for e in again.entries] == [e.path for e in pack.entries]
    assert [e.md5 for e in again.entries] == [e.md5 for e in pack.entries], "rebuild changed an entry"
    assert again.verify() == [], "rebuilt pack does not verify"


def check_ecfg_roundtrip(e):
    entries = [
        ("application/name", struct.pack("<I", 4) + b"name"),
        ("remap/all", e.encode_string_array(["res://a.gd", "res://a.gde"])),
        ("gamma/empty", b""),
    ]
    raw = e.build(entries)
    assert e.parse(raw) == entries, "parse/build round-trip changed an entry"
    assert e.build(e.parse(raw)) == raw, "rebuilding identical entries changed the bytes"


def check_ecfg_remaps(e):
    strings = ["res://scripts/main.gd", "res://scripts/main.gde",
               "res://scripts/utils/date.gd", "res://scripts/utils/date.gde",
               "res://assets/a.png", "res://.import/a.stex"]
    blob = e.encode_string_array(strings)
    assert e.decode_string_array(blob) == strings
    assert e.encode_string_array(e.decode_string_array(blob)) == blob, \
        "re-encoding a decoded string array changed the bytes (padding?)"
    other = struct.pack("<I", 4) + b"log\x00"
    entries = [("remap/all", blob), ("autoload/logger", other)]
    assert e.remap_pairs(entries) == [(strings[0], strings[1]),
                                      (strings[2], strings[3]),
                                      (strings[4], strings[5])]
    new, dropped = e.drop_remaps(entries, {"res://scripts/main.gd"})
    assert dropped == [(strings[0], strings[1])], dropped
    remaining = e.remap_pairs(new)
    assert len(remaining) == 2, remaining
    assert (strings[0], strings[1]) not in remaining
    assert dict(new)["autoload/logger"] == other, "an unrelated setting changed"
    assert e.parse(e.build(new)) == new, "the edited config does not parse back"

    unchanged, none = e.drop_remaps(new, {"res://not/mapped.gd"})
    assert none == [], "dropping an unmapped path reported a change"
    assert len(e.remap_pairs(unchanged)) == 2


def check_ecfg_rejects_bad_input(e):
    cases = {
        "bad magic": b"XCFG" + bytes(8),
        "truncated": b"ECFG\x01\x00\x00\x00",
        "trailing bytes": e.build([("a", b"")]) + b"junk",
    }
    for label, raw in cases.items():
        try:
            e.parse(raw)
        except e.EcfgError:
            pass
        else:
            raise AssertionError(f"{label} was accepted")
    bad_array = struct.pack("<II", 25, 3) + struct.pack("<I", 3) + b"ab\x00"
    try:
        e.decode_string_array(bad_array)
    except e.EcfgError:
        pass
    else:
        raise AssertionError("an odd length string array was accepted")


def check_ecfg_real(e):
    path = Path(REAL_PACK)
    if not path.is_file():
        print(f"  SKIP real pack not found at {path} (set CGS_PCK to point at one)")
        return
    pck = load(SRC, "pck_for_ecfg")
    pack = pck.Pck.open(path)
    try:
        raw = pack.read("res://engine.cfb")
    except KeyError:
        print("  SKIP this pack has no res://engine.cfb")
        return
    entries = e.parse(raw)
    pairs = e.remap_pairs(entries)
    scripts = [source for source, _ in pairs if source.endswith(".gd")]
    print(f"  real engine.cfb: {len(entries)} settings, {len(pairs)} remap pairs "
          f"({len(scripts)} scripts remapped to compiled files)")
    assert len(scripts) > 100, f"only {len(scripts)} script remaps, is this the right game?"
    assert e.build(entries) == raw, "the file did not round-trip byte for byte"
    new, dropped = e.drop_remaps(entries, scripts[:1])
    assert len(dropped) == 1 and len(e.remap_pairs(new)) == len(pairs) - 1
    assert e.parse(e.build(new)) == new, "the edited real config does not parse back"


CHECKS = [
    ("pck", "roundtrip", check_roundtrip),
    ("pck", "v2-path-padding", check_v2_path_padding),
    ("pck", "extract-and-select", check_extract_and_select),
    ("pck", "patch-replace-add-delete", check_patch_replace_add_delete),
    ("pck", "patch-from-dir", check_patch_from_dir),
    ("pck", "md5-guard", check_md5_guard),
    ("pck", "rejects-bad-input", check_rejects_bad_input),
    ("pck", "cli", check_cli),
    ("pck", "real-game-pack", check_real_game_pack),
    ("ecfg", "roundtrip", check_ecfg_roundtrip),
    ("ecfg", "remaps", check_ecfg_remaps),
    ("ecfg", "rejects-bad-input", check_ecfg_rejects_bad_input),
    ("ecfg", "real-engine-cfb", check_ecfg_real),
]

# (label, module, check name, original text, broken text, what the twin should break)
TWINS = [
    ("stale-md5", "pck", "md5-guard",
     "header += hashlib.md5(data).digest()",
     "header += bytes(16)",
     "the writer stamps a zero MD5"),
    ("delete-ignored", "pck", "patch-replace-add-delete",
     "            if entry.path in doomed:\n                continue",
     "            if False:\n                continue",
     "deleted entries stay in the pack"),
    ("bad-data-start", "pck", "roundtrip",
     "        data_start = self.header_size + index_size",
     "        data_start = index_size",
     "file data overwrites the header"),
    ("no-string-padding", "ecfg", "remaps",
     "        out += bytes((-len(out)) % 4)",
     "        out += bytes(0)",
     "Variant strings are written without the 4 byte padding"),
    ("drop-keeps-pair", "ecfg", "remaps",
     "        if source in wanted:",
     "        if False:",
     "dropping a remap leaves the pair in place"),
]


def run_check(module, name, fn):
    try:
        fn(module)
        return None
    except Exception:
        return traceback.format_exc(limit=4)


def main():
    failures = 0
    modules = {"pck": load(SRC, "pck_real"), "ecfg": load(ECFG_SRC, "ecfg_real")}
    print("checks")
    for module_name, name, fn in CHECKS:
        error = run_check(modules[module_name], name, fn)
        if error:
            failures += 1
            print(f"  FAIL {name}\n{error}")
        else:
            print(f"  ok   {name}  [{module_name}]")

    print("twin checks (each broken module must make its check fail)")
    sources = {"pck": SRC.read_text(encoding="utf-8"), "ecfg": ECFG_SRC.read_text(encoding="utf-8")}
    for label, module_name, check_name, old, new, description in TWINS:
        source = sources[module_name]
        if source.count(old) != 1:
            failures += 1
            print(f"  FAIL {label}: target text is not unique in {module_name}.py "
                  f"({source.count(old)} matches)")
            continue
        broken_path = tmpdir() / f"{module_name}_{label.replace('-', '_')}.py"
        broken_path.write_text(source.replace(old, new), encoding="utf-8")
        broken = load(broken_path, f"{module_name}_{label}")
        fn = {(m, n): f for m, n, f in CHECKS}[(module_name, check_name)]
        if run_check(broken, check_name, fn) is None:
            failures += 1
            print(f"  FAIL {label}: not caught, though {description}")
        else:
            print(f"  ok   {label} (caught: {description})")

    for directory in TMPS:
        shutil.rmtree(directory, ignore_errors=True)
    if failures:
        print(f"FAILED: {failures} problem(s)")
        return 1
    print("ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
