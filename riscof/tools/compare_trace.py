"""Find the first instruction where the core and Spike disagree.

    python3 compare_trace.py --dut trace.txt --ref spike.log

trace.txt : output of  run_test.py ... --trace       (tb_riscof +TRACE lines)
spike.log : stderr of  spike --isa=rv32i -l --log-commits ref.elf

Both programs are compiled from the same test with the same memory layout,
so the n-th instruction executed should have the same pc, the same encoding
and write the same value to the same register. The first line where that is
not true is where the bug shows itself.
"""
import argparse
import re
import sys

# tb_riscof:  "    108  pc=800001b0  instr=01291933  x18 <- 00000000"
DUT_RE = re.compile(r"^\s*\d+\s+pc=([0-9a-f]{8})\s+instr=([0-9a-f]{8})"
                    r"(?:\s+x(\d+) <- ([0-9a-f]{8}))?")
# spike:      "core   0: 3 0x800001b0 (0x01291933) x18 0x80000000"
REF_RE = re.compile(r"^core\s+\d+: 3 0x([0-9a-f]+) \(0x([0-9a-f]+)\)"
                    r"(?:\s+x(\d+)\s+0x([0-9a-f]+))?")
FENCE, EBREAK = 0x0FF0000F, 0x00100073     # the first two words of the DUT's halt


def parse(path, regex, first_pc=0x80000000):
    steps = []
    with open(path) as f:
        for line in f:
            m = regex.match(line)
            if not m:
                continue
            pc = int(m.group(1), 16)
            if pc < first_pc:                 # skip Spike's boot ROM at 0x1000
                continue
            rd = int(m.group(3)) if m.group(3) else None
            val = int(m.group(4), 16) if m.group(4) else None
            if rd == 0:                        # writes to x0 are not real writes
                rd, val = None, None
            steps.append((pc, int(m.group(2), 16), rd, val, line.rstrip()))
    return steps


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dut", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--context", type=int, default=4, help="lines shown before the mismatch")
    args = ap.parse_args()

    dut = parse(args.dut, DUT_RE)
    ref = parse(args.ref, REF_RE)
    for i, (d, r) in enumerate(zip(dut, ref)):
        if d[1] == FENCE and any(s[1] == EBREAK for s in dut[i:i + 2]):
            # the DUT's RVMODEL_HALT (fence; ebreak) - Spike's halt is different code
            print(f"no difference in {i} instructions; both reached the halt")
            return
        if d[:4] != r[:4]:
            print(f"first difference at instruction {i}:")
            for k in range(max(0, i - args.context), i):
                print("   same:", dut[k][4].strip())
            print("    DUT:", d[4].strip())
            print("    REF:", r[4].strip())
            sys.exit(1)
    print(f"no difference in the first {min(len(dut), len(ref))} instructions "
          f"(DUT ran {len(dut)}, Spike {len(ref)})")


if __name__ == "__main__":
    main()
