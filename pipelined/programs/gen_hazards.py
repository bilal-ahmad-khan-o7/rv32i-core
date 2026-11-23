"""Directed hazard tests for the pipelined core.

    python programs/gen_hazards.py        # writes programs/hazards/*

hazards.*   one program, one small case per marker. For each case, hazards.cases holds
            the load-use stall cycles and redirects the pipeline must spend on it; the
            trace and final data window must equal rv32iss's, as for random programs.
The others test how a run stops: each must give rv32iss's trace and final window.
    ebreak_after_store          the store before ebreak has written
    store_after_ebreak          the stores after ebreak have not
    ebreak_after_taken_branch   an ebreak on the wrong path does not stop the run
    illegal_on_wrong_path       nor does an illegal word there
Needs rv32iss (built with the host gcc) for the expected results.
"""
from pathlib import Path

from gen_random import (BASE, EBREAK, JALR, LOAD, LUI, AUIPC, NOP, OP, OP_IMM, WINDOW, b_type, clip, dot4,
                        expect, i_type, j_type, r_type, s_type, u_type, write_hex)

OUT = Path(__file__).resolve().parent / "hazards"


class Asm:
    """Words plus labels; branch/jump offsets are filled in when the words are taken."""

    def __init__(self):
        self.items, self.labels = [], {}

    def __call__(self, *words):
        self.items += words

    def label(self, name):
        self.labels[name] = len(self.items)

    def branch(self, f3, rs1, rs2, name):
        self.items.append(lambda i: b_type(4 * (self.labels[name] - i), rs2, rs1, f3))

    def jal(self, rd, name):
        self.items.append(lambda i: j_type(4 * (self.labels[name] - i), rd))

    def words(self):
        return [w(i) if callable(w) else w for i, w in enumerate(self.items)]


def addi(rd, rs1, imm): return i_type(imm, rs1, 0, rd, OP_IMM)
def add(rd, a, b):      return r_type(0x00, b, a, 0, rd, OP)
def sub(rd, a, b):      return r_type(0x20, b, a, 0, rd, OP)
def mul(rd, a, b):      return r_type(0x01, b, a, 0, rd, OP)
def mulh(rd, a, b):     return r_type(0x01, b, a, 1, rd, OP)
def lw(rd, off):        return i_type(off, BASE, 2, rd, LOAD)
def sw(rs2, off, base=BASE): return s_type(off, rs2, base, 2)
def jalr(rd, rs1, off): return i_type(off, rs1, 0, rd, JALR)
def lui(rd, imm20):     return u_type(imm20, rd, LUI)
def auipc(rd):          return u_type(0, rd, AUIPC)
BEQ, BNE = 0, 1

DATA = [0x0000_0011, 0xFFFF_FF00, 0x0102_0304, 0x7F80_7F80, 0, 0, 0, 0] + [0] * 56   # 64 words


def marker(a, k):                                  # store k to the marker address
    a(addi(30, 0, k), sw(30, -16, base=0))


def hazards():
    """The case program. Returns (words, [(marker, name, load-use cycles, redirects)])."""
    a = Asm()
    cases = []

    def case(name, load_use, redirects):
        cases.append((len(cases) + 1, name, load_use, redirects))
        marker(a, len(cases))

    a(lui(BASE, WINDOW >> 12), lui(8, 0x01020), addi(8, 8, 0x304), lui(9, 0xFF7F8), addi(9, 9, -0x80))
    case("setup", 0, 0)
    a(addi(5, 0, 7), add(6, 5, 0));                       case("EX/MEM -> EX, rs1", 0, 0)
    a(addi(5, 0, 9), sub(6, 0, 5));                       case("EX/MEM -> EX, rs2", 0, 0)
    a(addi(7, 0, 100), dot4(7, 8, 9));                    case("EX/MEM -> EX, rs3 (DOT4.S8 accumulator)", 0, 0)
    a(addi(5, 0, 11), addi(10, 0, 1), add(6, 5, 0));      case("MEM/WB -> EX, rs1", 0, 0)
    a(addi(5, 0, 13), addi(10, 0, 2), sub(6, 0, 5));      case("MEM/WB -> EX, rs2", 0, 0)
    a(addi(7, 0, -5), addi(10, 0, 3), dot4(7, 8, 9));     case("MEM/WB -> EX, rs3", 0, 0)
    a(addi(5, 0, 17), NOP, NOP, add(6, 5, 5),
      addi(7, 0, 1), NOP, NOP, dot4(7, 8, 9));            case("register-file bypass, rs1/rs2 and rs3", 0, 0)
    a(addi(5, 0, 1), addi(5, 0, 2), add(6, 5, 0));        case("EX/MEM wins over MEM/WB", 0, 0)
    a(lw(5, 0), add(6, 5, 0));                            case("load-use, rs1", 1, 0)
    a(lw(5, 4), sub(6, 0, 5));                            case("load-use, rs2", 1, 0)
    a(lw(7, 8), dot4(7, 8, 9));                           case("load-use, rs3", 1, 0)
    a(lw(5, 12), sw(5, 16), lw(6, 16));                   case("load, then store of the loaded register", 1, 0)
    a(lw(0, 0), add(6, 0, 0));                            case("load to x0: no stall", 0, 0)
    a(lw(7, 0), addi(7, 8, 1));                           case("rs3 only counts when read: addi into the loaded register", 0, 0)
    a(lw(5, 0), addi(10, 0, 0), add(6, 5, 0));            case("load, then a use two later: MEM/WB, no stall", 0, 0)
    a.branch(BNE, 0, 0, "n1"); a(addi(6, 0, 1)); a.label("n1")
    case("branch not taken", 0, 0)
    a.branch(BEQ, 0, 0, "t1"); a(addi(6, 0, 111), addi(6, 0, 222)); a.label("t1"); a(addi(10, 0, 17))
    case("branch taken: the two behind it are flushed", 0, 1)
    a(addi(5, 0, 3), addi(6, 0, 3)); a.branch(BEQ, 5, 6, "t2"); a(addi(10, 0, 99)); a.label("t2")
    case("branch on forwarded operands", 0, 1)
    a.jal(1, "j1"); a(addi(6, 0, 1)); a.label("j1"); a(add(6, 1, 0))
    case("jal, and a use of its link register", 0, 1)
    a(auipc(5), jalr(1, 5, 12), addi(6, 0, 1), add(6, 1, 0))
    case("jalr with a forwarded base", 0, 1)
    a(auipc(5), addi(5, 5, 24), sw(5, 20), lw(6, 20), jalr(0, 6, 0), addi(10, 0, 1), addi(10, 0, 2))
    case("jalr with its base from a load", 1, 1)
    a(addi(7, 0, 0), *[dot4(7, 8, 9)] * 8)
    case("8 x DOT4.S8 into one accumulator: no stall", 0, 0)
    a(dot4(7, 8, 9), clip(10, 7));                        case("CLIP.S8 right after DOT4.S8", 0, 0)
    a(addi(0, 0, 55), add(6, 0, 0), addi(0, 0, 66), NOP, add(10, 0, 0))
    case("writes to x0 are not forwarded", 0, 0)
    a(mul(5, 8, 9), mulh(6, 5, 5));                       case("multiply result forwarded", 0, 0)
    a(addi(5, 0, 0x55), sw(5, 24), lw(6, 24), add(10, 6, 0))
    case("store data forwarded, then load and use", 1, 0)
    a(EBREAK, NOP, NOP, NOP)
    return a.words(), cases


def stopping():
    """{name: words} for the programs that test how a run ends."""
    progs = {}
    a = Asm()
    a(lui(BASE, WINDOW >> 12), addi(5, 0, 0x77), sw(5, 0), EBREAK, NOP, NOP)
    progs["ebreak_after_store"] = a.words()
    a = Asm()
    a(lui(BASE, WINDOW >> 12), addi(5, 0, 0x66), EBREAK, sw(5, 4), sw(5, 8), addi(6, 0, 1), NOP, NOP)
    progs["store_after_ebreak"] = a.words()
    a = Asm()
    a(lui(BASE, WINDOW >> 12)); a.branch(BEQ, 0, 0, "L"); a(EBREAK, EBREAK); a.label("L")
    a(addi(6, 0, 5), EBREAK, NOP, NOP)
    progs["ebreak_after_taken_branch"] = a.words()
    a = Asm()
    a(lui(BASE, WINDOW >> 12)); a.jal(0, "L"); a(0xFFFF_FFFF, 0x0000_0000); a.label("L")
    a(addi(6, 0, 9), EBREAK, NOP, NOP)
    progs["illegal_on_wrong_path"] = a.words()
    return progs


def main():
    OUT.mkdir(exist_ok=True)
    words, cases = hazards()
    programs = {"hazards": words, **stopping()}
    for name, w in programs.items():
        write_hex(OUT / f"{name}.imem.hex", w)
        write_hex(OUT / f"{name}.data.hex", DATA)
        expect(str(OUT / name))
    (OUT / "hazards.cases").write_text(
        "# marker  load-use  redirects  case\n"
        + "".join(f"{k} {lu} {rd} {name}\n" for k, name, lu, rd in cases), newline="\n")
    print(f"wrote {len(programs)} programs, {len(cases)} cases, to {OUT}")


if __name__ == "__main__":
    main()
