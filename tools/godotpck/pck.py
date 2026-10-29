#!/usr/bin/env python3
"""Read, extract and patch Godot `.pck` archives (the container every exported Godot game uses).

Why this exists: a Godot game's gameplay code ships inside `*.pck` as compiled GDScript
(`.gde` on Godot 2.x, `.gdc` on Godot 3.x/4.x) next to the scenes and assets. Co-op work on
such a game means two things over and over: (a) get a copy of a file out of the pack to
study it, and (b) put files back in, either replaced game scripts or new ones your mod adds.
This module does both without the Godot editor and without touching the player's install.

Formats handled (all little-endian):

    magic "GDPC"
    u32   pack format     0 = Godot 2.x, 1 = Godot 3.x, 2 = Godot 4.x
    u32 x3 engine version major/minor/patch
    [format 2 only] u32 pack flags, u64 file base
    64 bytes reserved (zeros)
    u32   file count
    per file: u32 path length, path bytes (UTF-8, `res://...`),
              u64 offset, u64 size, 16 byte MD5,
              [format 2 only] u32 flags

Godot 4 packs written by newer editors pad the path string to a 4 byte boundary; the reader
detects that on its own. File offsets are absolute in the pack, and the engine verifies every
MD5 when it reads a file, so a patched pack must recompute the MD5 of everything it touches.

Usage:

    python -I tools/godotpck/pck.py info    <game.pck>
    python -I tools/godotpck/pck.py list    <game.pck> [--include GLOB] [--grep TEXT]
    python -I tools/godotpck/pck.py extract <game.pck> <outdir> [--include GLOB] [--no-verify]
    python -I tools/godotpck/pck.py patch   <game.pck> <new.pck> [--from DIR] [--delete PATH]...
    python -I tools/godotpck/pck.py verify  <game.pck>

`patch --from DIR` maps every file under DIR to `res://<relative/path>` (forward slashes), so
you can lay out the files you want to inject exactly as they appear in the pack.

Always patch a copy: never write into a game's install directory, and keep the shipped pack
untouched so a failed experiment costs nothing.
"""
import argparse
import fnmatch
import hashlib
import struct
import sys
from pathlib import Path

MAGIC = b"GDPC"
FORMAT_NAMES = {0: "Godot 2.x", 1: "Godot 3.x", 2: "Godot 4.x"}
RESERVED = 64
MAX_FILES = 2_000_000
MD5_LEN = 16


class PckError(Exception):
    """The pack is not a pack we understand, or an entry does not match its MD5."""


class Entry:
    __slots__ = ("path", "offset", "size", "md5", "flags")

    def __init__(self, path, offset, size, md5, flags=0):
        self.path = path
        self.offset = offset
        self.size = size
        self.md5 = md5
        self.flags = flags

    def __repr__(self):
        return f"Entry({self.path!r}, offset={self.offset}, size={self.size})"


def _u32(data, at):
    if at + 4 > len(data):
        raise PckError("truncated pack header")
    return struct.unpack_from("<I", data, at)[0]


def _read_at(handle, offset, size):
    handle.seek(offset)
    data = handle.read(size)
    if len(data) != size:
        raise PckError(f"pack is truncated at offset {offset} (wanted {size} bytes, got {len(data)})")
    return data


class Pck:
    """A parsed pack. `open()` reads the index only; file data stays in the source pack."""

    def __init__(self, source=None):
        self.source = Path(source) if source else None
        self.format = 0
        self.engine = (2, 1, 0)
        self.pack_flags = 0
        self.file_base = 0
        self.entries = []
        self.path_align = 0
        self.header_size = 0
        self.index_end = 0

    # --- reading -----------------------------------------------------------

    @classmethod
    def open(cls, path):
        pack = cls(path)
        raw = Path(path).read_bytes()
        if raw[:4] != MAGIC:
            raise PckError(f"{path}: not a Godot pack (magic is {raw[:4]!r}, expected {MAGIC!r})")
        pack.format = _u32(raw, 4)
        if pack.format not in FORMAT_NAMES:
            raise PckError(f"{path}: unknown pack format {pack.format} (known: 0, 1, 2)")
        major, minor, patch = struct.unpack_from("<III", raw, 8)
        pack.engine = (major, minor, patch)
        at = 20
        if pack.format == 2:
            pack.pack_flags = _u32(raw, at)
            pack.file_base = struct.unpack_from("<Q", raw, at + 4)[0]
            at += 12
        at += RESERVED
        count = _u32(raw, at)
        at += 4
        if count > MAX_FILES:
            raise PckError(f"{path}: implausible file count {count}")
        pack.header_size = at
        pack.index_end = at

        last_error = None
        for align in ((0, 4) if pack.format == 2 else (0,)):
            try:
                pack._read_index(raw, at, count, align)
                pack.path_align = align
                return pack
            except PckError as exc:
                last_error = exc
        raise last_error

    def _read_index(self, raw, at, count, align):
        entries = []
        limit = len(raw) - 4
        for _ in range(count):
            if at + 4 > limit:
                raise PckError("pack index is truncated")
            plen = _u32(raw, at)
            at += 4
            if plen == 0 or plen > 4096 or at + plen > limit:
                raise PckError(f"bad path length {plen} at index offset {at - 4}")
            raw_path = raw[at:at + plen]
            at += plen
            if align:
                at += (-plen) % align
            try:
                path = raw_path.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise PckError(f"path at index offset {at} is not UTF-8") from exc
            if "\x00" in path or not path.startswith("res://"):
                raise PckError(f"path at index offset {at} does not look like a pack path: {path[:40]!r}")
            extra = 4 if self.format == 2 else 0
            if at + 16 + extra > limit:
                raise PckError("pack index is truncated")
            offset, size = struct.unpack_from("<QQ", raw, at)
            md5 = raw[at + 16:at + 16 + MD5_LEN]
            at += 16 + MD5_LEN
            flags = _u32(raw, at) if self.format == 2 else 0
            at += extra
            if offset + size > len(raw):
                raise PckError(f"entry {path} points past the end of the pack")
            entries.append(Entry(path, offset, size, md5, flags))
        self.entries = entries
        self.index_end = at

    def __len__(self):
        return len(self.entries)

    def find(self, path):
        for entry in self.entries:
            if entry.path == path:
                return entry
        raise KeyError(path)

    def read(self, path, verify=True):
        if self.source is None:
            raise PckError(f"{path}: this pack has no source file to read from")
        entry = self.find(path)
        with open(self.source, "rb") as handle:
            data = _read_at(handle, entry.offset, entry.size)
        if verify and hashlib.md5(data).digest() != entry.md5:
            raise PckError(f"{path}: MD5 mismatch, pack is corrupt or this is not the entry you think")
        return data

    def select(self, include=None, grep=None):
        out = []
        for entry in self.entries:
            if include and not _match(entry.path, include):
                continue
            if grep and grep.lower() not in entry.path.lower():
                continue
            out.append(entry)
        return out

    def extract(self, out_dir, include=None, grep=None, verify=True):
        out_dir = Path(out_dir)
        written = []
        for entry in self.select(include, grep):
            data = self.read(entry.path, verify=verify)
            target = out_dir / entry.path[len("res://"):]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            written.append(entry.path)
        return written

    def verify(self):
        bad = []
        with open(self.source, "rb") as handle:
            for entry in self.entries:
                if hashlib.md5(_read_at(handle, entry.offset, entry.size)).digest() != entry.md5:
                    bad.append(entry.path)
        return bad

    # --- writing -----------------------------------------------------------

    def save(self, target, overrides=None, delete=()):
        """Write a new pack: source entries minus `delete`, with `overrides` replacing or adding.

        `overrides` maps a `res://` path to bytes. New paths are appended, in sorted order.
        Every written entry gets a fresh MD5, which the engine needs.
        """
        overrides = dict(overrides or {})
        doomed = set(delete)
        missing = doomed - {e.path for e in self.entries}
        if missing:
            raise PckError(f"cannot delete paths that are not in the pack: {sorted(missing)[:5]}")

        plan = []
        for entry in self.entries:
            if entry.path in doomed:
                continue
            data = overrides.pop(entry.path, None)
            if data is None:
                if self.source is None:
                    raise PckError(f"{entry.path}: no data for this entry")
                data = self.read(entry.path, verify=False)
            plan.append((entry.path, data, entry.flags))
        for path in sorted(overrides):
            plan.append((path, overrides[path], 0))

        # twin-target: index-size (a wrong index size shifts every data offset)
        index_size = self._index_size(plan)
        # twin-target: data-start (start file data at 0 and the pack becomes unreadable)
        data_start = self.header_size + index_size
        file_base = 0
        if self.format == 2 and self.file_base:
            file_base = self.file_base + (data_start - self.index_end)

        header = bytearray()
        header += MAGIC
        header += struct.pack("<I", self.format)
        header += struct.pack("<III", *self.engine)
        if self.format == 2:
            header += struct.pack("<I", self.pack_flags)
            header += struct.pack("<Q", file_base)
        header += bytes(RESERVED)
        header += struct.pack("<I", len(plan))

        body = bytearray()
        offset = data_start
        for path, data, flags in plan:
            raw_path = path.encode("utf-8")
            header += struct.pack("<I", len(raw_path))
            header += raw_path
            if self.path_align:
                header += bytes((-len(raw_path)) % self.path_align)
            header += struct.pack("<QQ", offset, len(data))
            # twin-target: md5 (a stale MD5 makes the engine drop the file)
            header += hashlib.md5(data).digest()
            if self.format == 2:
                header += struct.pack("<I", flags)
            body += data
            offset += len(data)

        if len(header) != data_start:
            raise PckError(f"internal: header is {len(header)} bytes but data starts at {data_start}")

        target = Path(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "wb") as handle:
            handle.write(header)
            handle.write(body)
        return target

    def _index_size(self, plan):
        total = 0
        for path, _data, _flags in plan:
            raw_path = path.encode("utf-8")
            total += 4 + len(raw_path)
            if self.path_align:
                total += (-len(raw_path)) % self.path_align
            total += 16 + MD5_LEN + (4 if self.format == 2 else 0)
        return total

    def patch_from_dir(self, source_dir, target, include=None, delete=()):
        """Replace or add every file under `source_dir`; its layout becomes `res://` paths."""
        source_dir = Path(source_dir)
        if not source_dir.is_dir():
            raise PckError(f"{source_dir} is not a directory")
        overrides = {}
        for file in sorted(source_dir.rglob("*")):
            if not file.is_file():
                continue
            rel = file.relative_to(source_dir).as_posix()
            if include and not _match(rel, include):
                continue
            overrides["res://" + rel] = file.read_bytes()
        return self.save(target, overrides, delete)


def _match(path, patterns):
    rel = path[len("res://"):] if path.startswith("res://") else path
    for pattern in patterns:
        if fnmatch.fnmatch(path, pattern) or fnmatch.fnmatch(rel, pattern):
            return True
    return False


def new_pack(format=0, engine=(2, 1, 0), path_align=0):
    """An empty pack, for building one from scratch (and for the tests)."""
    pack = Pck()
    pack.format = format
    pack.engine = tuple(engine)
    pack.path_align = path_align
    pack.header_size = 4 + 4 + 12 + (12 if format == 2 else 0) + RESERVED + 4
    pack.index_end = pack.header_size
    return pack


def _human(size):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if size < 1024 or unit == "GiB":
            return f"{size} B" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024.0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Read, extract and patch Godot .pck archives.")
    sub = parser.add_subparsers(dest="command", required=True)

    p_info = sub.add_parser("info", help="show format, engine version and counts")
    p_info.add_argument("pck")

    p_list = sub.add_parser("list", help="list entries")
    p_list.add_argument("pck")
    p_list.add_argument("--include", action="append", default=None, help="glob, repeatable")
    p_list.add_argument("--grep", default=None, help="path substring, case-insensitive")

    p_extract = sub.add_parser("extract", help="extract entries to a directory")
    p_extract.add_argument("pck")
    p_extract.add_argument("outdir")
    p_extract.add_argument("--include", action="append", default=None)
    p_extract.add_argument("--grep", default=None)
    p_extract.add_argument("--no-verify", action="store_true", help="skip MD5 checks")

    p_patch = sub.add_parser("patch", help="write a patched copy of a pack")
    p_patch.add_argument("pck")
    p_patch.add_argument("out")
    p_patch.add_argument("--from", dest="from_dir", default=None,
                         help="directory whose layout becomes res:// paths")
    p_patch.add_argument("--delete", action="append", default=[], help="res:// path, repeatable")
    p_patch.add_argument("--include", action="append", default=None)

    p_verify = sub.add_parser("verify", help="check every entry MD5")
    p_verify.add_argument("pck")

    args = parser.parse_args(argv)
    try:
        if args.command == "info":
            pack = Pck.open(args.pck)
            print(f"pack      {args.pck}")
            print(f"format    {pack.format} ({FORMAT_NAMES[pack.format]})")
            print(f"engine    {pack.engine[0]}.{pack.engine[1]}.{pack.engine[2]}")
            print(f"files     {len(pack)}")
            print(f"index     {_human(pack.index_end)}, "
                  f"data {_human(Path(args.pck).stat().st_size - pack.index_end)}")
            if pack.path_align:
                print(f"paths     padded to {pack.path_align} bytes")
            return 0
        if args.command == "list":
            pack = Pck.open(args.pck)
            for entry in pack.select(args.include, args.grep):
                print(f"{entry.size:>10}  {entry.path}")
            return 0
        if args.command == "extract":
            pack = Pck.open(args.pck)
            written = pack.extract(args.outdir, args.include, args.grep, verify=not args.no_verify)
            print(f"extracted {len(written)} files to {args.outdir}")
            return 0
        if args.command == "verify":
            pack = Pck.open(args.pck)
            bad = pack.verify()
            if bad:
                print(f"{len(bad)} entries failed their MD5, first: {bad[0]}")
                return 1
            print(f"all {len(pack)} entries OK")
            return 0
        if args.command == "patch":
            pack = Pck.open(args.pck)
            if not args.from_dir and not args.delete:
                print("nothing to do: pass --from DIR and/or --delete PATH", file=sys.stderr)
                return 2
            if args.from_dir:
                out = pack.patch_from_dir(args.from_dir, args.out, args.include, args.delete)
            else:
                out = pack.save(args.out, None, args.delete)
            print(f"wrote {out} ({_human(out.stat().st_size)}, {len(Pck.open(out))} files)")
            return 0
    except PckError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
