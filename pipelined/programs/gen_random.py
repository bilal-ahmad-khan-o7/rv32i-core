"""Random but valid programs, for comparing the pipelined core with rv32iss.

    python3 programs/gen_random.py SEED OUT [--padded] [-n N] [--expect]

writes OUT.imem.hex (the program) and OUT.data.hex (a 256-byte data window, loaded at
0x1000_F000 with +INPUT / --load); --expect also runs rv32iss and writes OUT.trace and
OUT.dump, the expected register-write trace and final window. The program:
  - sets x31 to the window's address (x31 is never written again) and fills x1..x30
    with random values;
  - runs N random instructions: ALU and immediate ops, the Zmmul multiplies, DOT4.S8,
    CLIP.S8, aligned loads and stores inside the window (base x31), forward branches,
    jal, and jalr through a base register computed by the instruction just before;
  - ends with ebreak.
Writes to x0 are included. Every branch and jump goes forward, so every program ends.

Hazard-dense mode (the default) picks source registers mostly from the last few
destinations, to provoke forwarding and load-use stalls. --padded puts 3 nops before
every instruction instead: that is the step 1 test, for a pipeline with no hazard logic.

The encoder below covers only what these programs use. It checks itself against
words from GNU as when it is imported.
"""
import argparse
import os
import random
import shutil
import subprocess
import sys
from pathlib import Path

# ---- encoder ---------------------------------------------------------------------
OP, OP_IMM, LOAD, STORE, BRANCH = 0x33, 0x13, 0x03, 0x23, 0x63
LUI, AUIPC, JAL, JALR, CUSTOM0, SYSTEM = 0x37, 0x17, 0x6F, 0x67, 0x0B, 0x73

R_OPS = {  # name: (funct7, funct3)
    "add": (0x00, 0), "sub": (0x20, 0), "sll": (0x00, 1), "slt": (0x00, 2), "sltu": (0x00, 3),
    "xor": (0x00, 4), "srl": (0x00, 5), "sra": (0x20, 5), "or": (0x00, 6), "and": (0x00, 7),
    "mul": (0x01, 0), "mulh": (0x01, 1), "mulhsu": (0x01, 2), "mulhu": (0x01, 3),
}
I_OPS = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SHIFT_OPS = {"slli": (0x00, 1), "srli": (0x00, 5), "srai": (0x20, 5)}
LOADS = {"lb": (0, 1), "lh": (1, 2), "lw": (2, 4), "lbu": (4, 1), "lhu": (5, 2)}   # funct3, size
STORES = {"sb": (0, 1), "sh": (1, 2), "sw": (2, 4)}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}


def r_type(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def s_type(imm, rs2, rs1, f3):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 31) << 7) | STORE


def b_type(off, rs2, rs1, f3):
    o = off & 0x1FFF
    return (((o >> 12) & 1) << 31) | (((o >> 5) & 63) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
        | (((o >> 1) & 15) << 8) | (((o >> 11) & 1) << 7) | BRANCH


def u_type(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def j_type(off, rd):
    o = off & 0x1FFFFF
    return (((o >> 20) & 1) << 31) | (((o >> 1) & 0x3FF) << 21) | (((o >> 11) & 1) << 20) \
        | (((o >> 12) & 0xFF) << 12) | (rd << 7) | JAL


NOP = i_type(0, 0, 0, 0, OP_IMM)
EBREAK = 0x0010_0073


def dot4(rd, rs1, rs2):
    return r_type(0, rs2, rs1, 1, rd, CUSTOM0)


def clip(rd, rs1):
    return r_type(0, 0, rs1, 2, rd, CUSTOM0)


# Known words from GNU as (riscv-none-elf-as 15.2, -march=rv32i_zmmul) and the README.
_CHECK = [
    (NOP, 0x00000013), (dot4(10, 11, 12), 0x00C5950B), (clip(13, 10), 0x0005268B),
    (u_type(0x1000F, 31, LUI), 0x1000FFB7), (s_type(8, 5, 31, 2), 0x005FA423),
    (i_type(-4, 31, 4, 9, LOAD), 0xFFCFC483), (b_type(16, 2, 1, 0), 0x00208863),
    (b_type(2048, 7, 6, 7), 0x007370E3), (j_type(8, 1), 0x008000EF), (j_type(4096, 0), 0x0000106F),
    (i_type(7 | 0x400, 4, 5, 3, OP_IMM), 0x40725193), (r_type(1, 9, 8, 2, 7, OP), 0x029423B3),
    (i_type(-1, 5, 0, 6, JALR), 0xFFF28367), (u_type(0, 5, AUIPC), 0x00000297),
    (s_type(-2, 11, 31, 1), 0xFEBF9F23), (b_type(0, 4, 3, 1), 0x00419063),
]
for got, want in _CHECK:
    assert got == want, f"encoder: {got:08x} != {want:08x}"

# ---- generator -------------------------------------------------------------------
WINDOW = 0x1000_F000
WINDOW_BYTES = 256
BASE = 31                      # holds WINDOW for the whole program


class Program:
    """A list of items; each is a word, or a function of the address table (for jumps)."""

    def __init__(self, padded):
        self.items, self.padded = [], padded

    def emit(self, word_or_fn):
        """Append one instruction. Returns (start, index): where a jump to it lands, and its
        own item index. Padded, 3 nops come BEFORE each instruction and a jump lands on the
        first of them, so even an instruction at a jump target is 4 slots after anything
        it reads (a jal's link register included)."""
        start = len(self.items)
        if self.padded:
            self.items += [NOP, NOP, NOP]
        self.items.append(word_or_fn)
        return start, len(self.items) - 1

    def words(self):
        return [w(self, i) if callable(w) else w for i, w in enumerate(self.items)]


def generate(seed, n=300, padded=False):
    rng = random.Random(seed)
    p = Program(padded)
    recent = []                                     # the latest destinations, newest last

    def dest():
        rd = 0 if rng.random() < 0.04 else rng.randrange(1, 31)
        recent.append(rd)
        del recent[:-4]
        return rd

    def src():
        if not padded and recent and rng.random() < 0.7:
            return rng.choice(recent[-3:])          # usually something just written
        return rng.randrange(0, 32)

    p.emit(u_type(WINDOW >> 12, BASE, LUI))
    for r in range(1, 31):
        p.emit(u_type(rng.getrandbits(20), r, LUI))
        p.emit(i_type(rng.randrange(-2048, 2048), r, 0, r, OP_IMM))

    # Forward jumps land on random instruction k + 1..6 (or on the ebreak). Their offsets
    # are known only once the program is laid out, so they are functions of
    # (program, own item index), resolved by Program.words().
    starts = []                                     # item index where random instruction k starts
    for k in range(n):
        kind = rng.choices(["r", "i", "shift", "lui", "load", "store", "branch", "jal", "jalr",
                            "dot4", "clip"], [14, 10, 4, 2, 14, 8, 8, 2, 2, 10, 4])[0]
        target = min(k + rng.randint(1, 6), n)      # a random-instruction number; n = the ebreak
        if kind == "r":
            f7, f3 = R_OPS[rng.choice(list(R_OPS))]
            start, _ = p.emit(r_type(f7, src(), src(), f3, dest(), OP))
        elif kind == "i":
            start, _ = p.emit(i_type(rng.randrange(-2048, 2048), src(), I_OPS[rng.choice(list(I_OPS))], dest(), OP_IMM))
        elif kind == "shift":
            f7, f3 = SHIFT_OPS[rng.choice(list(SHIFT_OPS))]
            start, _ = p.emit(i_type((f7 << 5) | rng.randrange(32), src(), f3, dest(), OP_IMM))
        elif kind == "lui":
            start, _ = p.emit(u_type(rng.getrandbits(20), dest(), rng.choice([LUI, AUIPC])))
        elif kind == "load":
            f3, size = LOADS[rng.choice(list(LOADS))]
            start, _ = p.emit(i_type(size * rng.randrange(WINDOW_BYTES // size), BASE, f3, dest(), LOAD))
        elif kind == "store":
            f3, size = STORES[rng.choice(list(STORES))]
            start, _ = p.emit(s_type(size * rng.randrange(WINDOW_BYTES // size), src(), BASE, f3))
        elif kind == "branch":
            f3 = BRANCHES[rng.choice(list(BRANCHES))]
            rs1, rs2 = src(), src()
            start, _ = p.emit(lambda prog, i, f3=f3, rs1=rs1, rs2=rs2, target=target:
                         b_type(4 * (prog.start[target] - i), rs2, rs1, f3))
        elif kind == "jal":
            rd = dest()
            start, _ = p.emit(lambda prog, i, rd=rd, target=target: j_type(4 * (prog.start[target] - i), rd))
        elif kind == "jalr":                        # auipc t, 0 ; jalr rd, off(t): one random instruction
            t = rng.randrange(1, 31)
            start, auipc = p.emit(u_type(0, t, AUIPC))
            recent.append(t)
            rd = dest()
            p.emit(lambda prog, i, rd=rd, t=t, auipc=auipc, target=target:
                   i_type(4 * (prog.start[target] - auipc), t, 0, rd, JALR))
        elif kind == "dot4":
            start, _ = p.emit(dot4(dest(), src(), src()))
        else:
            start, _ = p.emit(clip(dest(), src()))
        starts.append(start)
    starts.append(p.emit(EBREAK)[0])                # target n: the ebreak
    p.items += [NOP] * 4
    p.start = starts
    data = bytes(rng.getrandbits(8) for _ in range(WINDOW_BYTES))
    return p.words(), data


def write_hex(path, words):
    with open(path, "w", newline="\n") as f:
        f.write("".join(f"{w & 0xFFFFFFFF:08x}\n" for w in words))


# ---- expected results, from rv32iss --------------------------------------------------
HERE = Path(__file__).resolve().parent
ISS_SRC = HERE.parents[1] / "single_cycle" / "sim" / "iss" / "rv32iss.c"
ISS = HERE.parent / "build" / ("rv32iss.exe" if os.name == "nt" else "rv32iss")


def build_iss():
    """Compile rv32iss (host gcc) into pipelined/build if it is missing or out of date."""
    if not ISS.exists() or ISS.stat().st_mtime < ISS_SRC.stat().st_mtime:
        ISS.parent.mkdir(exist_ok=True)
        gcc = shutil.which("gcc") or sys.exit("gcc not found: it builds rv32iss")
        subprocess.run([gcc, "-O2", "-std=gnu11", "-o", str(ISS), str(ISS_SRC)], check=True)
    return ISS


def expect(prefix):
    """Run the program on rv32iss; write PREFIX.trace and PREFIX.dump (the final window)."""
    r = subprocess.run([str(build_iss()), "--imem", f"{prefix}.imem.hex",
                        "--load", f"{prefix}.data.hex@{WINDOW:#x}", "--trace", f"{prefix}.trace",
                        "--dump", hex(WINDOW), str(WINDOW_BYTES), "--quiet"],
                       capture_output=True, text=True)
    dump = [l for l in r.stdout.splitlines() if l.startswith("dump ")]
    if r.returncode != 0 or len(dump) != 1:
        sys.exit(f"rv32iss failed on {prefix}:\n{r.stdout}{r.stderr}")
    Path(f"{prefix}.dump").write_text(dump[0] + "\n", newline="\n")


def write_program(seed, prefix, n=300, padded=False, with_expect=False):
    words, data = generate(seed, n, padded)
    write_hex(f"{prefix}.imem.hex", words)
    write_hex(f"{prefix}.data.hex", [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)])
    if with_expect:
        expect(prefix)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("seed", type=int)
    ap.add_argument("out")
    ap.add_argument("-n", type=int, default=300)
    ap.add_argument("--padded", action="store_true")
    ap.add_argument("--expect", action="store_true", help="also write OUT.trace and OUT.dump from rv32iss")
    a = ap.parse_args()
    write_program(a.seed, a.out, a.n, a.padded, a.expect)


if __name__ == "__main__":
    main()
