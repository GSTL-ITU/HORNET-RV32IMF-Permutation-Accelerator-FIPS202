#!/usr/bin/env python3
"""Write a padded $readmemh image (one 32-bit little-endian word per line) from an ELF file.

  elf2hex.py prog.elf imem.hex 0x00000000 0x10000
  elf2hex.py prog.elf dmem.hex 0x10000000 0x10000

Same output as HORNET-RV32IMF/scripts/elf2hex.py --pad, without the pyelftools dependency:
the loadable bytes (PT_LOAD, file contents) inside [base, base + size) are written, the rest is 0.
"""
import struct
import sys


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    elf, out = sys.argv[1], sys.argv[2]
    base, size = int(sys.argv[3], 0), int(sys.argv[4], 0)

    with open(elf, "rb") as f:
        d = f.read()
    if d[:4] != b"\x7fELF" or d[4] != 1 or d[5] != 1:
        sys.exit("%s: not a 32-bit little-endian ELF" % elf)

    phoff, = struct.unpack_from("<I", d, 28)
    phentsize, phnum = struct.unpack_from("<HH", d, 42)
    img = bytearray(size)
    for i in range(phnum):
        p_type, p_offset, _vaddr, p_paddr, p_filesz = struct.unpack_from("<5I", d, phoff + i * phentsize)
        if p_type != 1 or p_filesz == 0:
            continue
        lo, hi = max(p_paddr, base), min(p_paddr + p_filesz, base + size)
        if lo < hi:
            img[lo - base:hi - base] = d[p_offset + lo - p_paddr:p_offset + hi - p_paddr]
        if p_paddr < base + size and p_paddr + p_filesz > base + size:
            sys.exit("%s: segment at 0x%x does not fit in [0x%x, 0x%x)" % (elf, p_paddr, base, base + size))

    with open(out, "w") as f:
        for w in range(size // 4):
            f.write("%08x\n" % struct.unpack_from("<I", img, 4 * w)[0])


if __name__ == "__main__":
    main()
