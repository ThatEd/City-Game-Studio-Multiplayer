"""Read and edit Godot 2.x `engine.cfb`, the binary project settings file.

Godot 2 exports a game's settings as `res://engine.cfb` (magic `ECFG`). The engine reads it with
`Globals::_load_settings_binary` (text `engine.cfg` is tried first, then the binary one):

    "ECFG" | u32 key count | count x { u32 key length, key bytes,
                                       u32 value length, value bytes (encoded Variant) }

Two parts of it matter for co-op work on an exported game:

- `remap/all`, a PackedStringArray (Variant type 25) of alternating paths
  `res://x.gd` -> `res://x.gde`. Godot 2 resolves every resource load through it, and it picks
  the GDScript loader by the *remapped* path's extension, so a `.gd` remapped to `.gde` is read
  as encrypted bytecode. Dropping a pair makes the engine load the plaintext script instead.
- `autoload/*`, the global singletons, which is where a mod wants to hook in.

Everything else is kept byte for byte: values are treated as opaque blobs, so the file stays
exactly as the developer shipped it apart from the pairs you drop or add.

    python -I tools/godotpck/ecfg.py list    <engine.cfb> [--grep TEXT]
    python -I tools/godotpck/ecfg.py remaps  <engine.cfb> [--grep TEXT]
    python -I tools/godotpck/ecfg.py drop    <engine.cfb> <out.cfb> res://scripts/main.gd [...]
    python -I tools/godotpck/ecfg.py add     <engine.cfb> <out.cfb> res://from.gd res://to.gde
"""
import argparse
import struct
import sys
from pathlib import Path

MAGIC = b"ECFG"
STRING_ARRAY = 25
REMAP_KEY = "remap/all"


class EcfgError(Exception):
    pass


def _read_key(data, at):
    if at + 4 > len(data):
        raise EcfgError("truncated key header")
    length = struct.unpack_from("<I", data, at)[0]
    at += 4
    if at + length > len(data):
        raise EcfgError(f"bad key length {length} at {at}")
    return data[at:at + length].decode("utf-8"), at + length


def _read_array_string(data, at):
    # Variant strings: u32 (length + 1), the bytes, a NUL, then padding to a 4 byte boundary
    if at + 4 > len(data):
        raise EcfgError("truncated string header")
    length = struct.unpack_from("<I", data, at)[0]
    at += 4
    if length == 0 or at + length > len(data):
        raise EcfgError(f"bad string length {length} at {at}")
    if data[at + length - 1] != 0:
        raise EcfgError("string is not NUL terminated")
    value = data[at:at + length - 1].decode("utf-8")
    at += length
    at += (-at) % 4
    return value, at


def parse(data):
    """[(key, encoded variant bytes)] in file order."""
    if data[:4] != MAGIC:
        raise EcfgError(f"not an engine.cfb (magic {data[:4]!r})")
    if len(data) < 8:
        raise EcfgError("truncated header")
    count = struct.unpack_from("<I", data, 4)[0]
    at = 8
    entries = []
    for _ in range(count):
        key, at = _read_key(data, at)
        if at + 4 > len(data):
            raise EcfgError("truncated value header")
        length = struct.unpack_from("<I", data, at)[0]
        at += 4
        if at + length > len(data):
            raise EcfgError(f"value of {key} runs past the end")
        entries.append((key, data[at:at + length]))
        at += length
    if at != len(data):
        raise EcfgError(f"{len(data) - at} trailing bytes after the last entry")
    return entries


def build(entries):
    out = bytearray(MAGIC)
    out += struct.pack("<I", len(entries))
    for key, blob in entries:
        raw = key.encode("utf-8")
        out += struct.pack("<I", len(raw)) + raw
        out += struct.pack("<I", len(blob)) + blob
    return bytes(out)


def decode_string_array(blob):
    if len(blob) < 8:
        raise EcfgError("string array value is too short")
    kind, count = struct.unpack_from("<II", blob, 0)
    if kind != STRING_ARRAY:
        raise EcfgError(f"not a PackedStringArray (variant type {kind})")
    at = 8
    values = []
    for _ in range(count):
        value, at = _read_array_string(blob, at)
        values.append(value)
    if at != len(blob):
        raise EcfgError(f"{len(blob) - at} trailing bytes in the string array")
    return values


def encode_string_array(values):
    out = bytearray(struct.pack("<II", STRING_ARRAY, len(values)))
    for value in values:
        raw = value.encode("utf-8")
        out += struct.pack("<I", len(raw) + 1) + raw + b"\x00"
        out += bytes((-len(out)) % 4)
    return bytes(out)


def remap_pairs(entries):
    for key, blob in entries:
        if key == REMAP_KEY:
            values = decode_string_array(blob)
            if len(values) % 2:
                raise EcfgError("remap/all has an odd number of strings")
            return [(values[i], values[i + 1]) for i in range(0, len(values), 2)]
    return []


def set_remaps(entries, pairs):
    values = []
    for source, target in pairs:
        values.append(source)
        values.append(target)
    blob = encode_string_array(values)
    out = []
    for key, existing in entries:
        out.append((key, blob if key == REMAP_KEY else existing))
    if not any(key == REMAP_KEY for key, _ in entries):
        out.append((REMAP_KEY, blob))
    return out


def drop_remaps(entries, paths):
    """Remove the remap pair that sources each path, so the plaintext file loads instead.

    Returns (entries, dropped pairs). A path that is already unmapped is not an error: patches
    are applied on top of each other and re-running them must not fail.
    """
    wanted = set(paths)
    pairs = remap_pairs(entries)
    kept, dropped = [], []
    for source, target in pairs:
        if source in wanted:
            dropped.append((source, target))
        else:
            kept.append((source, target))
    if not dropped:
        return entries, []
    return set_remaps(entries, kept), dropped


def main(argv=None):
    parser = argparse.ArgumentParser(description="Read and edit Godot 2.x engine.cfb files.")
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list", help="list setting keys")
    p_list.add_argument("cfb")
    p_list.add_argument("--grep", default=None)

    p_remaps = sub.add_parser("remaps", help="list remap pairs")
    p_remaps.add_argument("cfb")
    p_remaps.add_argument("--grep", default=None)

    p_drop = sub.add_parser("drop", help="drop the remap of a script path")
    p_drop.add_argument("cfb")
    p_drop.add_argument("out")
    p_drop.add_argument("paths", nargs="+")

    p_add = sub.add_parser("add", help="add or replace one remap pair")
    p_add.add_argument("cfb")
    p_add.add_argument("out")
    p_add.add_argument("source")
    p_add.add_argument("target")

    args = parser.parse_args(argv)
    try:
        entries = parse(Path(args.cfb).read_bytes())
        if args.command == "list":
            for key, blob in entries:
                if args.grep and args.grep.lower() not in key.lower():
                    continue
                print(f"{len(blob):>8}  {key}")
            return 0
        if args.command == "remaps":
            pairs = remap_pairs(entries)
            print(f"{len(pairs)} remap pairs")
            for source, target in pairs:
                if args.grep and args.grep.lower() not in source.lower() and \
                        args.grep.lower() not in target.lower():
                    continue
                print(f"  {source} -> {target}")
            return 0
        if args.command == "drop":
            new, dropped = drop_remaps(entries, args.paths)
            if not dropped:
                print("no matching remap entries; nothing to do")
                return 0
            Path(args.out).write_bytes(build(new))
            for source, target in dropped:
                print(f"dropped {source} -> {target}")
            print(f"wrote {args.out}")
            return 0
        if args.command == "add":
            pairs = [(s, t) for s, t in remap_pairs(entries) if s != args.source]
            pairs.append((args.source, args.target))
            Path(args.out).write_bytes(build(set_remaps(entries, pairs)))
            print(f"mapped {args.source} -> {args.target}")
            print(f"wrote {args.out}")
            return 0
    except EcfgError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
