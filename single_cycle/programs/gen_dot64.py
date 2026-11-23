"""Generate the dot64 whole-core test for tb_core_dot64.

    python programs/gen_dot64.py

Writes, next to this script:
  dot64.s           annotated listing: [address] machine word, instruction, effect
  dot64.hex         the program (instruction memory), one word per line
  dot64_data.hex    data-memory preload: 64 int8 weights at 0x400, 64 int8 inputs at 0x440
  dot64_expect.svh  expected registers, memory words and section addresses (tb include)

What the program does (one KWS-style pointwise output, then edge cases):
  A  acc = bias + sum(w[i] * x[i]), i = 0..63, with 16 x (lw, lw, dot4.s8)
  B  the same dot product with 64 x (lb, lb, mul, add)
  C  requantisation of the result: mulh, srai, addi (zero point), clip.s8
  D  DOT4.S8 with rd = x0, rd == rs1, rd == rs2, rd == rs1 == rs2, wrap-around
  E  CLIP.S8 on 127, 128, -128, -129, 0, INT_MAX, INT_MIN
  F  mul / mulh / mulhsu / mulhu on the extreme operands
Both dot-product kernels are fully unrolled: every KWS pointwise reduction is
exactly 64 long, so that is how the real kernel will be written.

This is a test generator, not an assembler: it encodes only the instructions
used here. Each instruction is also executed by a small Python model as it is
emitted (straight-line code, no branches), which gives the expected value of
every register and memory word. The key results are cross-checked against
plain-integer formulas (bias + sum(w*x), the requantisation equation).
"""
import random
from pathlib import Path

HERE = Path(__file__).resolve().parent
MASK = 0xFFFF_FFFF

W_BASE, X_BASE, SIG_BASE = 0x400, 0x440, 0x500   # data-memory layout (bytes)
DMEM_BYTES = 4096
BIAS = 0x1234                                     # int32 bias of this output channel
M = 0x5555_5555                                   # Q31 requantisation multiplier (~2/3)
ZP_FC = 14                                        # output zero point of the final FC layer
ZP_RELU = -128                                    # output zero point of the ReLU layers


def s32(v):
    v &= MASK
    return v - (1 << 32) if v & 0x8000_0000 else v


def s8(v):
    v &= 0xFF
    return v - 256 if v & 0x80 else v


# ---- encoders (field layout: RISC-V unprivileged spec, chapter 2) ------------
def r_type(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def i_type(imm, rs1, f3, rd, op):
    assert -2048 <= imm < 2048, imm
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def s_type(imm, rs2, rs1, f3, op):
    assert -2048 <= imm < 2048, imm
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op


def u_type(imm20, rd, op):
    return ((imm20 & 0xF_FFFF) << 12) | (rd << 7) | op


OP_LOAD, OP_IMM, OP_STORE, OP_REG, OP_LUI, OP_SYSTEM, OP_CUSTOM0 = 0x03, 0x13, 0x23, 0x33, 0x37, 0x73, 0x0B
MUL_F3 = {"mul": 0, "mulh": 1, "mulhsu": 2, "mulhu": 3}


class Program:
    """Encodes instructions and executes them on a register/memory model."""

    def __init__(self, data):
        self.words, self.listing = [], []
        self.x = [0] * 32
        self.mem = bytearray(data)
        self.marks = {}
        self.sig = []                                     # (address, what) of result words

    @property
    def pc(self):
        return 4 * len(self.words)

    # ---- bookkeeping ----
    def section(self, text):
        self.listing.append(f"# ---- {text}")

    def mark(self, name):
        self.marks[name] = self.pc
        self.listing.append(f"{name}:")

    def _emit(self, word, asm, rd=None, value=None, note=""):
        if rd:                                            # x0 is never written
            self.x[rd] = value & MASK
        effect = f"x{rd} = {value & MASK:08x}" if rd else ""
        text = "  ".join(t for t in (effect, note) if t)
        self.listing.append(f"        {asm:<28}# [{self.pc:03x}] {word:08x}  {text}".rstrip())
        self.words.append(word)

    def load(self, addr, size):
        return int.from_bytes(self.mem[addr:addr + size], "little")

    # ---- instructions ----
    def addi(self, rd, rs1, imm, note=""):
        self._emit(i_type(imm, rs1, 0, rd, OP_IMM), f"addi  x{rd}, x{rs1}, {imm}", rd, self.x[rs1] + imm, note)

    def srai(self, rd, rs1, sh, note=""):
        self._emit(i_type(0x400 | sh, rs1, 5, rd, OP_IMM), f"srai  x{rd}, x{rs1}, {sh}",
                   rd, s32(self.x[rs1]) >> sh, note)

    def lui(self, rd, imm20, note=""):
        self._emit(u_type(imm20, rd, OP_LUI), f"lui   x{rd}, 0x{imm20:05x}", rd, imm20 << 12, note)

    def li(self, rd, value, note=""):
        value &= MASK
        if -2048 <= s32(value) < 2048:
            self.addi(rd, 0, s32(value), note)
            return
        lo = ((value & 0xFFF) ^ 0x800) - 0x800            # sign-extended low 12 bits
        hi = ((value - lo) >> 12) & 0xF_FFFF
        self.lui(rd, hi, "" if lo else note)
        if lo:
            self.addi(rd, rd, lo, note)

    def add(self, rd, rs1, rs2, note=""):
        self._emit(r_type(0, rs2, rs1, 0, rd, OP_REG), f"add   x{rd}, x{rs1}, x{rs2}",
                   rd, self.x[rs1] + self.x[rs2], note)

    def sub(self, rd, rs1, rs2, note=""):
        self._emit(r_type(0x20, rs2, rs1, 0, rd, OP_REG), f"sub   x{rd}, x{rs1}, x{rs2}",
                   rd, self.x[rs1] - self.x[rs2], note)

    def lw(self, rd, off, rs1, note=""):
        a = (self.x[rs1] + off) & MASK
        self._emit(i_type(off, rs1, 2, rd, OP_LOAD), f"lw    x{rd}, {off}(x{rs1})", rd, self.load(a, 4), note)

    def lb(self, rd, off, rs1, note=""):
        a = (self.x[rs1] + off) & MASK
        self._emit(i_type(off, rs1, 0, rd, OP_LOAD), f"lb    x{rd}, {off}(x{rs1})", rd, s8(self.load(a, 1)), note)

    def sw(self, rs2, off, rs1, what):
        a = (self.x[rs1] + off) & MASK
        self.mem[a:a + 4] = (self.x[rs2] & MASK).to_bytes(4, "little")
        self.sig.append((a, what))
        self._emit(s_type(off, rs2, rs1, 2, OP_STORE), f"sw    x{rs2}, {off}(x{rs1})", None, None,
                   f"M[{a:03x}] = {self.x[rs2]:08x}  {what}")

    def mulop(self, name, rd, rs1, rs2, note=""):
        a, b = self.x[rs1], self.x[rs2]
        p = {"mul": s32(a) * s32(b), "mulh": s32(a) * s32(b),
             "mulhsu": s32(a) * b, "mulhu": a * b}[name]
        value = p if name == "mul" else p >> 32           # Python >> floors, as the ISA does
        self._emit(r_type(1, rs2, rs1, MUL_F3[name], rd, OP_REG), f"{name:<6}x{rd}, x{rs1}, x{rs2}", rd, value, note)

    def dot4(self, rd, rs1, rs2, note=""):
        a, b, acc = self.x[rs1], self.x[rs2], self.x[rd]  # all three read before rd is written
        dot = sum(s8(a >> 8 * i) * s8(b >> 8 * i) for i in range(4))
        self._emit(r_type(0, rs2, rs1, 1, rd, OP_CUSTOM0), f"dot4.s8 x{rd}, x{rs1}, x{rs2}", rd, acc + dot, note)

    def clip(self, rd, rs1, note=""):
        v = max(-128, min(127, s32(self.x[rs1])))
        self._emit(r_type(0, 0, rs1, 2, rd, OP_CUSTOM0), f"clip.s8 x{rd}, x{rs1}", rd, v, note)

    def ebreak(self):
        self._emit(0x0010_0073, "ebreak", None, None, "stop")


def self_check_encoder():
    """The encoder must reproduce words whose encodings are known."""
    known = [
        (i_type(0x200, 0, 0, 31, OP_IMM), 0x20000F93),     # addi x31, x0, 0x200   (smoke.s)
        (s_type(0, 3, 31, 2, OP_STORE), 0x003FA023),        # sw   x3, 0(x31)       (smoke.s)
        (s_type(-4, 5, 4, 2, OP_STORE), 0xFE522E23),        # sw   x5, -4(x4)       (smoke.s)
        (i_type(0, 4, 2, 9, OP_LOAD), 0x00022483),          # lw   x9, 0(x4)        (smoke.s)
        (i_type(1, 4, 0, 10, OP_LOAD), 0x00120503),         # lb   x10, 1(x4)       (smoke.s)
        (u_type(0x12345, 5, OP_LUI), 0x123452B7),           # lui  x5, 0x12345      (smoke.s)
        (r_type(0x20, 2, 1, 0, 3, OP_REG), 0x402081B3),     # sub  x3, x1, x2       (smoke.s)
        (i_type(0x401, 2, 5, 3, OP_IMM), 0x40115193),       # srai x3, x2, 1        (smoke.s)
        (r_type(1, 7, 6, 0, 5, OP_REG), 0x027302B3),        # mul  x5, x6, x7       (GNU as)
        (r_type(0, 12, 11, 1, 10, OP_CUSTOM0), 0x00C5950B), # dot4.s8 x10, x11, x12 (README)
        (r_type(0, 0, 10, 2, 13, OP_CUSTOM0), 0x0005268B),  # clip.s8 x13, x10      (README)
    ]
    for got, want in known:
        assert got == want, f"encoder: {got:08x} != {want:08x}"


def requant(acc, m, shift, zp):
    """The test's requantisation formula, written directly (not via the model)."""
    t = (s32(acc) * s32(m)) >> 32          # mulh: high half, rounded down
    t = (t >> shift) + zp                  # srai, addi
    return max(-128, min(127, t))          # clip.s8


def build():
    self_check_encoder()

    # ---- data: 64 int8 weights and 64 int8 inputs, extremes in the first word ----
    rng = random.Random(2026)
    w = [rng.randint(-128, 127) for _ in range(64)]
    x = [rng.randint(-128, 127) for _ in range(64)]
    w[0:4] = [-128, 127, -128, 127]
    x[0:4] = [-128, -128, 127, 127]
    w[63], x[63] = -1, -1
    data = bytearray(DMEM_BYTES)
    data[W_BASE:W_BASE + 64] = bytes(v & 0xFF for v in w)
    data[X_BASE:X_BASE + 64] = bytes(v & 0xFF for v in x)

    answer = (BIAS + sum(a * b for a, b in zip(w, x))) & MASK

    p = Program(data)
    p.section("setup: bases and the bias")
    p.addi(1, 0, W_BASE, "x1 = weights")
    p.addi(2, 0, X_BASE, "x2 = inputs")
    p.addi(31, 0, SIG_BASE, "x31 = result area")
    p.li(10, BIAS, "x10 = bias (DOT4.S8 accumulator)")
    p.li(11, BIAS, "x11 = bias (mul accumulator)")

    p.section("A: 64-element dot product, 16 x (lw, lw, dot4.s8)")
    p.mark("dot4_start")
    for k in range(16):
        p.lw(3, 4 * k, 1, f"w[{4*k}..{4*k+3}]")
        p.lw(4, 4 * k, 2, f"x[{4*k}..{4*k+3}]")
        p.dot4(10, 3, 4, f"acc after {4*k+4} MACs")
    p.mark("dot4_end")

    p.section("B: the same dot product, 64 x (lb, lb, mul, add)")
    p.mark("mul_start")
    for i in range(64):
        p.lb(5, i, 1)
        p.lb(6, i, 2)
        p.mulop("mul", 7, 5, 6, f"w[{i}] * x[{i}]")
        p.add(11, 11, 7, f"acc after {i+1} MACs")
    p.mark("mul_end")
    assert p.x[10] == answer and p.x[11] == answer

    p.section("store both accumulators")
    p.sw(10, 0, 31, "acc, DOT4.S8 version")
    p.sw(11, 4, 31, "acc, mul version")

    # ---- C: requantisation ----
    t = (s32(answer) * s32(M)) >> 32
    shift = next(s for s in range(32) if -100 < (t >> s) + ZP_FC < 100)   # an in-range result
    assert abs(t) > 300, "the saturating cases below need a large mulh result"
    p.section(f"C: requantise: clip.s8((mulh(acc, M) >> shift) + zero point), M = 0x{M:08x}")
    p.li(20, M, "x20 = M (Q31 multiplier)")
    p.mulop("mulh", 12, 10, 20, "acc * M, high half")
    p.srai(12, 12, shift)
    p.addi(12, 12, ZP_FC, "+ zero point")
    p.clip(12, 12, "in range: clip leaves it")
    p.sw(12, 8, 31, f"requant, shift {shift}, zp {ZP_FC}: in range")
    p.mulop("mulh", 12, 10, 20)
    p.addi(12, 12, ZP_RELU, "shift 0: far out of range")
    p.clip(12, 12, "saturates")
    p.sw(12, 12, 31, f"requant, shift 0, zp {ZP_RELU}: saturates")
    p.sub(13, 0, 10, "x13 = -acc")
    p.mulop("mulh", 12, 13, 20)
    p.addi(12, 12, ZP_RELU)
    p.clip(12, 12, "saturates the other way")
    p.sw(12, 16, 31, f"requant of -acc, shift 0, zp {ZP_RELU}: saturates")
    req = [requant(answer, M, shift, ZP_FC), requant(answer, M, 0, ZP_RELU), requant(-s32(answer), M, 0, ZP_RELU)]
    got = [s32(p.load(SIG_BASE + 8 + 4 * i, 4)) for i in range(3)]
    assert got == req, (got, req)
    assert -128 < req[0] < 127 and sorted(req[1:]) == [-128, 127], req

    # ---- D: DOT4.S8 register cases ----
    p.section("D: DOT4.S8 register cases")
    p.dot4(0, 3, 4, "rd = x0: result discarded, x0 stays 0")
    p.add(29, 0, 0, "x29 = x0 + x0 = 0")
    p.li(15, 0x80FF_7F01)
    p.li(16, 0xFF01_FF01)
    p.dot4(15, 15, 16, "rd == rs1: old x15 + (1 - 127 - 1 + 128)")
    p.dot4(16, 15, 16, "rd == rs2: uses the new x15 and the old x16")
    p.li(17, 0x7F80_FF01)
    p.dot4(17, 17, 17, "rd == rs1 == rs2")
    p.li(18, 0x7FFF_FFFF)
    p.li(19, 0x0101_0101)
    p.dot4(18, 19, 19, "0x7FFFFFFF + 4 wraps to 0x80000003")
    p.li(21, 0x8000_0000)
    p.addi(22, 0, 0xFF, "x22: byte 0 = -1, others 0")
    p.dot4(21, 22, 19, "0x80000000 + (-1) wraps to 0x7FFFFFFF")
    assert p.x[18] == 0x8000_0003 and p.x[21] == 0x7FFF_FFFF and p.x[15] == 0x80FF_7F02

    # ---- E: CLIP.S8 edges ----
    p.section("E: CLIP.S8 edge values")
    off = 20
    for v in (127, 128, -128, -129, 0, 0x7FFF_FFFF, 0x8000_0000):
        p.li(23, v)
        p.clip(24, 23)
        p.sw(24, off, 31, f"clip.s8({s32(v)})")
        off += 4

    # ---- F: Zmmul on extreme operands ----
    p.section("F: Zmmul on extreme operands")
    p.li(25, 0x8000_0000, "x25 = INT_MIN")
    p.li(26, 0xFFFF_FFFF, "x26 = -1 / 0xFFFFFFFF")
    p.li(27, 0x7FFF_FFFF, "x27 = INT_MAX")
    for name, a, b in (("mul", 25, 26), ("mulh", 25, 25), ("mulh", 27, 25), ("mulhsu", 26, 26),
                       ("mulhsu", 25, 25), ("mulhu", 26, 26), ("mulhu", 25, 26), ("mul", 27, 27)):
        p.mulop(name, 28, a, b)
        p.sw(28, off, 31, f"{name} x{a}, x{b}")
        off += 4

    p.section("stop")
    p.mark("stop")
    p.ebreak()
    return p, w, x, answer, shift


def write_outputs(p, w, x, answer, shift):
    n = len(p.words)
    assert n <= 1024, "program does not fit in the 4 KiB instruction memory"

    (HERE / "dot64.hex").write_text("".join(f"{v:08x}\n" for v in p.words))

    data_words = [int.from_bytes(bytes(v & 0xFF for v in w[i:i + 4]), "little") for i in range(0, 64, 4)]
    data_words += [int.from_bytes(bytes(v & 0xFF for v in x[i:i + 4]), "little") for i in range(0, 64, 4)]
    (HERE / "dot64_data.hex").write_text(
        "// dot64_data.hex - generated by gen_dot64.py: w[0..63] at 0x400, x[0..63] at 0x440\n"
        f"@{W_BASE // 4:x}\n" + "".join(f"{v:08x}\n" for v in data_words))

    head = [
        "# dot64.s - whole-core test of Zmmul, DOT4.S8 and CLIP.S8 (tb_core_dot64.sv).",
        "# GENERATED by gen_dot64.py - edit the generator, not this file.",
        "#",
        "# Every line shows [byte address] machine word, then the effect.",
        f"# Data memory is preloaded from dot64_data.hex: w[0..63] (int8) at 0x{W_BASE:x},",
        f"# x[0..63] (int8) at 0x{X_BASE:x}. Results are stored from 0x{SIG_BASE:x}.",
        f"#   w = {w}",
        f"#   x = {x}",
        f"#   bias + sum(w[i] * x[i]) = {BIAS} + {s32(answer) - BIAS} = {s32(answer)} = 0x{answer:08x}",
        "",
    ]
    (HERE / "dot64.s").write_text("\n".join(head + p.listing) + "\n")

    regs = "\n".join(f"      {r:2d}: return 32'h{v:08x};" for r, v in enumerate(p.x))
    sig = sorted(dict(p.sig).items())
    addr_cases = "\n".join(f"      {k:2d}: return 32'h{a:08x};" for k, (a, _) in enumerate(sig))
    val_cases = "\n".join(f"      {k:2d}: return 32'h{p.load(a, 4):08x};   // {what}"
                          for k, (a, what) in enumerate(sig))
    svh = f"""// dot64_expect.svh - GENERATED by programs/gen_dot64.py; do not edit.
// Expected results of programs/dot64.hex with programs/dot64_data.hex in data memory.

localparam logic [31:0] PC_DOT4_START = 32'h{p.marks['dot4_start']:08x};  // first lw of the DOT4.S8 kernel
localparam logic [31:0] PC_DOT4_END   = 32'h{p.marks['dot4_end']:08x};  // first instruction after it
localparam logic [31:0] PC_MUL_START  = 32'h{p.marks['mul_start']:08x};  // first lb of the mul kernel
localparam logic [31:0] PC_MUL_END    = 32'h{p.marks['mul_end']:08x};  // first instruction after it
localparam logic [31:0] PC_EBREAK     = 32'h{p.marks['stop']:08x};
localparam logic [31:0] DOT_ANSWER    = 32'h{answer:08x};  // {BIAS} + sum(w[i] * x[i]) = {s32(answer)}
localparam int          REQ_SHIFT     = {shift};
localparam int          N_MEM         = {len(sig)};

// final register values (x0 included)
function automatic logic [31:0] exp_reg(input int r);
  case (r)
{regs}
    default: return 32'hxxxx_xxxx;
  endcase
endfunction

// result words: address and value of each
function automatic logic [31:0] exp_mem_addr(input int k);
  case (k)
{addr_cases}
    default: return 32'hxxxx_xxxx;
  endcase
endfunction

function automatic logic [31:0] exp_mem_val(input int k);
  case (k)
{val_cases}
    default: return 32'hxxxx_xxxx;
  endcase
endfunction
"""
    (HERE / "dot64_expect.svh").write_text(svh)
    print(f"dot64: {n} instructions, answer {s32(answer)} (0x{answer:08x}), "
          f"{len(sig)} result words, requant shift {shift}")


if __name__ == "__main__":
    write_outputs(*build())
