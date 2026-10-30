"""Print the C strings at one or more RVAs in the shipped exe."""
import sys
from pathlib import Path

import pefile

EXE = Path(__file__).parent.parent / "build" / "out" / "CityGameStudio64.exe"


def read_cstring(data, offset):
    end = data.index(b"\x00", offset)
    return data[offset:end].decode("utf-8", "replace")


def main(argv):
    pe = pefile.PE(str(EXE), fast_load=True)
    base = pe.OPTIONAL_HEADER.ImageBase
    data = EXE.read_bytes()
    for text in argv[1:]:
        rva = int(text, 0)
        offset = pe.get_offset_from_rva(rva)
        if offset < 0:
            print(f"0x{rva:x} -> not in file")
            continue
        # ASCII-safe output: some of these strings carry bytes that are not valid UTF-8, and a
        # console encoding error must not hide the one string that names the faulting file.
        value = read_cstring(data, offset)
        safe = value.encode("ascii", "backslashreplace").decode("ascii")
        print(f"0x{rva:x}: {safe!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
