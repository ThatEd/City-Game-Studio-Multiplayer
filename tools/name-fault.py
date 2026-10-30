"""Name a fault address from the game's own machine code.

    python -I tools/name-fault.py 0x5111bb

Pass an RVA or a VA; both are accepted. Prints the surrounding instructions, the enclosing
function's prologue, and every nearby string in the module, which is how the 0xae5633 crash was
identified as "a Variant member this build lacks" rather than guessed at.
"""
import re
import sys
from pathlib import Path

import capstone
import pefile

EXE = Path(__file__).parent.parent / "build" / "out" / "CityGameStudio64.exe"


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    wanted = int(argv[1], 0)
    pe = pefile.PE(str(EXE), fast_load=True)
    base = pe.OPTIONAL_HEADER.ImageBase
    rva = wanted - base if wanted > base else wanted
    offset = pe.get_offset_from_rva(rva)
    if offset < 0:
        print(f"0x{rva:x} is not inside the file")
        return 1

    data = EXE.read_bytes()
    start = offset - 0x80
    blob = data[start:offset + 0x40]
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    print(f"RVA 0x{rva:x}  file offset 0x{offset:x}  VA 0x{base + rva:x}")
    print("--- instructions around the fault ---")
    for ins in md.disasm(blob, base + rva - 0x80):
        marker = "  <<<< FAULT" if ins.address == base + rva else ""
        print(f"  {ins.address:012x}  {ins.mnemonic:<8} {ins.op_str}{marker}")

    # Find a plausible function prologue above the fault.
    print("--- nearest prologue above ---")
    window = data[max(0, offset - 0x600):offset]
    best = None
    for match in re.finditer(rb"\x48\x83\xec|\x48\x81\xec|\x55\x48\x8b\xec", window):
        best = match
    if best:
        prologue = max(0, offset - 0x600) + best.start()
        pro_rva = pe.get_rva_from_offset(prologue)
        print(f"  RVA 0x{pro_rva:x}")
        for ins in md.disasm(data[prologue:prologue + 0x30], base + pro_rva):
            print(f"  {ins.address:012x}  {ins.mnemonic:<8} {ins.op_str}")

    # Strings near the code name the subsystem, which is what makes the offset interpretable.
    print("--- strings within 4 KB of the code ---")
    nearby = data[max(0, offset - 4096):offset + 4096]
    for match in re.finditer(rb"[ -~]{12,}", nearby):
        print(f"  {match.group().decode('ascii', 'replace')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
