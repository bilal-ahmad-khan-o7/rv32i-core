"""Build the bare-metal programs in kws/sw and write their memory images to kws/gen.

    python3 kws/build.py              # every program, builds a, b and c
    python3 kws/build.py kws c        # one program, one build

Needs a RISC-V GNU toolchain with rv32i/ilp32 libraries: riscv-none-elf-gcc (xPack),
riscv64-unknown-elf-gcc or riscv32-unknown-elf-gcc, the first one found on PATH.
RISCV_PREFIX picks one (e.g. RISCV_PREFIX=/opt/riscv/bin/riscv64-unknown-elf-).
Only rebuilding needs it: the images are committed, so running the tests does not.
A different GCC version may produce different (equally valid) images and cycle counts.

Builds (one C source, three instruction sets):
    a   RV32I; multiply and divide in software (libgcc)
    b   RV32I + Zmmul (mul, mulh, ...)
    c   RV32I + Zmmul + DOT4.S8 and CLIP.S8
"""
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SW = ROOT / "kws" / "sw"
GEN = ROOT / "kws" / "gen"
OBJ = ROOT / "build" / "kws"


def toolchain_prefix():
    """RISCV_PREFIX if set, else the first RISC-V GCC found on PATH."""
    if "RISCV_PREFIX" in os.environ:
        return os.environ["RISCV_PREFIX"]
    for prefix in ("riscv-none-elf-", "riscv64-unknown-elf-", "riscv32-unknown-elf-"):
        if shutil.which(prefix + "gcc"):
            return prefix
    sys.exit("no RISC-V GCC on PATH (riscv-none-elf-gcc, riscv64-unknown-elf-gcc, ...); "
             "install one or set RISCV_PREFIX")


PREFIX = toolchain_prefix()
CC = shutil.which(PREFIX + "gcc") or sys.exit(f"toolchain not found: {PREFIX}gcc (set RISCV_PREFIX)")
OBJDUMP = shutil.which(PREFIX + "objdump") or sys.exit(f"toolchain not found: {PREFIX}objdump")

BUILDS = {
    "a": ["-march=rv32i"],
    "b": ["-march=rv32i_zmmul", "-DHAVE_ZMMUL"],
    "c": ["-march=rv32i_zmmul", "-DHAVE_ZMMUL", "-DHAVE_NN"],
}
PROGRAMS = {
    "hello": [SW / "crt0.S", SW / "hello.c"],
    "kws":   [SW / "crt0.S", SW / "kws.c", GEN / "kws_tables.c"],
}
CFLAGS = ["-mabi=ilp32", "-mstrict-align", "-msmall-data-limit=0", "-O2", "-g", "-ffreestanding",
          "-fno-strict-aliasing", "-Wall", "-Wextra", "-Werror", f"-I{SW}", f"-I{GEN}"]
DATA_BASE = 0x1000_0000

SHT_PROGBITS, SHT_NOBITS, SHF_ALLOC = 1, 8, 2


def run(cmd):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0:
        sys.exit(f"failed: {' '.join(str(c) for c in cmd)}\n{r.stdout}{r.stderr}")
    return r.stdout + r.stderr


def sections(path):
    """(name, type, flags, address, size, bytes) of each section of an ELF32 little-endian file."""
    b = Path(path).read_bytes()
    shoff = struct.unpack_from("<I", b, 32)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", b, 46)
    hdrs = [struct.unpack_from("<10I", b, shoff + i * shentsize) for i in range(shnum)]
    strs = hdrs[shstrndx]
    names = b[strs[4]:strs[4] + strs[5]]
    out = []
    for name, typ, flags, addr, off, size, *_ in hdrs:
        n = names[name:names.index(b"\0", name)].decode()
        out.append((n, typ, flags, addr, size, b[off:off + size] if typ == SHT_PROGBITS else b""))
    return out


def write_hex(path, data):
    data = bytes(data) + bytes(-len(data) % 4)
    words = struct.unpack(f"<{len(data) // 4}I", data)
    path.write_text("".join(f"{w:08x}\n" for w in words), newline="\n")


def check_encodings():
    """The .insn lines of nn_insn.h must give the README's encodings."""
    src = OBJ / "insn_check.S"
    src.write_text(".insn r 0x0B, 1, 0, x10, x11, x12\n.insn r 0x0B, 2, 0, x13, x10, x0\n")
    obj = OBJ / "insn_check.o"
    run([CC, "-march=rv32i_zmmul", "-mabi=ilp32", "-c", src, "-o", obj])
    text = next(s[5] for s in sections(obj) if s[0] == ".text")
    got = struct.unpack("<2I", text[:8])
    if got != (0x00C5950B, 0x0005268B):
        sys.exit(f"custom encodings differ from the README: {got[0]:08x} {got[1]:08x}")
    print("encodings ok: dot4.s8 x10,x11,x12 = 00c5950b, clip.s8 x13,x10 = 0005268b")


def build(prog, b):
    tag = f"{prog}_{b}"
    elf = OBJ / f"{tag}.elf"
    run([CC, *BUILDS[b], *CFLAGS, *PROGRAMS[prog], "-nostartfiles", "-nostdlib",
         f"-T{SW / 'link.ld'}", "-Wl,--no-relax", f"-Wl,-Map={OBJ / (tag + '.map')}", "-lgcc", "-o", elf])
    (OBJ / f"{tag}.lst").write_text(run([OBJDUMP, "-d", "-S", elf]))

    imem, dmem = bytearray(), bytearray()
    code = rodata = data = bss = 0
    for name, typ, flags, addr, size, content in sections(elf):
        if not flags & SHF_ALLOC:
            continue
        if typ == SHT_NOBITS:
            bss += size
        elif addr < DATA_BASE:
            end = addr + len(content)
            imem.extend(bytes(max(0, end - len(imem))))
            imem[addr:end] = content
            code += len(content)
        else:
            off = addr - DATA_BASE
            dmem.extend(bytes(max(0, off + len(content) - len(dmem))))
            dmem[off:off + len(content)] = content
            if name.startswith(".rodata"):
                rodata += len(content)
            else:
                data += len(content)
    write_hex(GEN / f"{tag}.imem.hex", imem)
    write_hex(GEN / f"{tag}.dmem.hex", dmem)
    print(f"{tag}: code {code} B, rodata {rodata} B, data {data} B, bss {bss} B")


def main():
    OBJ.mkdir(parents=True, exist_ok=True)
    GEN.mkdir(parents=True, exist_ok=True)
    args = sys.argv[1:]
    progs = [a for a in args if a in PROGRAMS] or list(PROGRAMS)
    builds = [a for a in args if a in BUILDS] or list(BUILDS)
    check_encodings()
    for m in (["-march=rv32i"], ["-march=rv32i_zmmul"]):
        lib = run([CC, *m, "-mabi=ilp32", "-print-multi-directory"]).strip()
        print(f"{m[0]}: libgcc from {lib}")
    for p in progs:
        for b in builds:
            build(p, b)


if __name__ == "__main__":
    main()
