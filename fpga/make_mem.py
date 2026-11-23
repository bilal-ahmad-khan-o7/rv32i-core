"""Write the data-memory image for the FPGA build: KWS build (c)'s data image with one
recording's 490 input bytes merged in at kws_input (0x1000_F000).

    python3 fpga/make_mem.py [recording]      # default tst_000007_Yes_9 ("Yes")

writes fpga/mem/kws_c_dmem_<recording>.hex: 16384 words (64 KiB), one per line. In
simulation the input is loaded separately (+INPUT); the FPGA has only its preload.
"""
import sys
from pathlib import Path

FPGA = Path(__file__).resolve().parent
GEN = FPGA.parent / "kws" / "gen"
WORDS = 16384                                   # DMEM_WORDS of top_kws
INPUT_WORD = (0x1000_F000 >> 2) & (WORDS - 1)   # the memory has no decoder: low address bits


def words(path):
    return [int(l, 16) for l in path.read_text().split() if l.strip()]


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "tst_000007_Yes_9"
    mem = [0] * WORDS
    image = words(GEN / "kws_c.dmem.hex")
    mem[:len(image)] = image
    data = words(GEN / f"input_{name}.hex")
    assert INPUT_WORD + len(data) <= WORDS and not any(mem[INPUT_WORD:INPUT_WORD + len(data)])
    mem[INPUT_WORD:INPUT_WORD + len(data)] = data
    out = FPGA / "mem" / f"kws_c_dmem_{name}.hex"
    out.parent.mkdir(exist_ok=True)
    out.write_text("".join(f"{w:08x}\n" for w in mem), newline="\n")
    print(f"wrote {out}: {len(image)} image words, {len(data)} input words at word {INPUT_WORD:#x}")


if __name__ == "__main__":
    main()
