"""Run one compiled riscv-arch-test ELF on the RV32I core and write its signature.

    python3 run_test.py --elf my.elf --vvp tb_riscof.vvp --sig DUT-rv32i_core.signature
    python3 run_test.py --elf my.elf --vvp tb_riscof.vvp --sig out.sig --trace > trace.txt

Steps: ELF -> raw binary (objcopy) -> one 32-bit word per line (my.hex)
       -> find begin_signature / end_signature (nm) -> run the simulation.
The RISCOF plugin calls this once per test; you can also call it by hand
to debug a single failing test.
"""
import argparse
import subprocess
import sys
from pathlib import Path


def elf_to_hex(elf, prefix):
    """Turn the ELF into a hex file that $readmemh can load at word 0."""
    binfile = elf.with_suffix(".bin")
    hexfile = elf.with_suffix(".hex")
    # -O binary: only the bytes that are loaded into memory, starting at the
    # lowest section address (0x80000000), with gaps filled by zeros.
    subprocess.run([prefix + "objcopy", "-O", "binary", str(elf), str(binfile)],
                   check=True)
    data = binfile.read_bytes()
    data += bytes((-len(data)) % 4)               # pad to a whole number of words
    with hexfile.open("w") as f:
        for i in range(0, len(data), 4):
            word = int.from_bytes(data[i:i + 4], "little")   # RISC-V is little-endian
            f.write(f"{word:08x}\n")
    return hexfile


def symbol_address(elf, prefix, name):
    """Address of a global symbol, read from the ELF symbol table with nm."""
    out = subprocess.run([prefix + "nm", str(elf)], check=True,
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()                       # "80003110 D begin_signature"
        if len(parts) == 3 and parts[2] == name:
            return parts[0]
    sys.exit(f"run_test.py: symbol {name} not found in {elf}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--elf", required=True, type=Path)
    ap.add_argument("--vvp", required=True, help="compiled testbench (tb_riscof.vvp)")
    ap.add_argument("--sig", required=True, help="signature file to write")
    ap.add_argument("--prefix", default="riscv64-unknown-elf-", help="toolchain prefix")
    ap.add_argument("--max-cycles", type=int, default=2_000_000)
    ap.add_argument("--trace", action="store_true", help="print pc/instr every cycle")
    args = ap.parse_args()

    hexfile = elf_to_hex(args.elf, args.prefix)
    begin = symbol_address(args.elf, args.prefix, "begin_signature")
    end = symbol_address(args.elf, args.prefix, "end_signature")

    cmd = ["vvp", "-n", args.vvp,
           f"+PROG={hexfile}", f"+SIG={args.sig}",
           f"+BEGIN_SIG={begin}", f"+END_SIG={end}",
           f"+MAX_CYCLES={args.max_cycles}"]
    if args.trace:
        cmd.append("+TRACE")
    sys.exit(subprocess.run(cmd).returncode)


if __name__ == "__main__":
    main()
