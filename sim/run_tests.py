"""Compile and run every testbench of the single-cycle core with Icarus Verilog.

    python sim/run_tests.py              # all testbenches
    python sim/run_tests.py alu core     # only tb_alu and tb_core
    python sim/run_tests.py -v core      # also print the full simulator output

Runs from the single_cycle/ folder (whatever the current directory is), so the
$readmemh / $dumpfile paths inside the testbenches ("programs/...", "build/...")
resolve. Needs iverilog and vvp (Icarus 12+) on PATH, or in C:\\iverilog\\bin.
Exit code is 0 only if every testbench prints "PASS:".
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # single_cycle/
RTL = ROOT / "rtl"
TB = ROOT / "tb"
BUILD = ROOT / "build"

PKG = [RTL / "riscv_pkg.sv"]                           # must be first on the command line
BLOCKS = [RTL / f"{m}.sv" for m in (
    "pc_reg", "imem", "regfile", "dmem", "imm_gen", "alu",
    "control", "branch_unit", "lsu")]
STAGES = [RTL / f"{m}.sv" for m in (
    "if_stage", "id_stage", "ex_stage", "mem_stage", "wb_stage", "riscv_core")]

# testbench name -> design files it needs (the package is always added first)
TESTS = {
    "pc_reg":      [RTL / "pc_reg.sv"],
    "regfile":     [RTL / "regfile.sv"],
    "imem":        [RTL / "imem.sv"],
    "dmem":        [RTL / "dmem.sv"],
    "alu":         [RTL / "alu.sv"],
    "imm_gen":     [RTL / "imm_gen.sv"],
    "control":     [RTL / "control.sv"],
    "branch_unit": [RTL / "branch_unit.sv"],
    "lsu":         [RTL / "lsu.sv"],
    "core":        BLOCKS + STAGES,
}


def find_tool(name):
    path = shutil.which(name)
    if path:
        return path
    fallback = Path(r"C:\iverilog\bin") / (name + ".exe")
    if fallback.exists():
        return str(fallback)
    sys.exit(f"error: {name} not found on PATH (install Icarus Verilog 12+)")


def run(name, iverilog, vvp, verbose):
    tb = f"tb_{name}"
    vvp_file = BUILD / f"{tb}.vvp"
    files = [str(p.relative_to(ROOT)) for p in PKG + TESTS[name] + [TB / f"{tb}.sv"]]
    comp = subprocess.run([iverilog, "-g2012", "-Wall", "-Wno-timescale", "-s", tb,
                           "-o", str(vvp_file.relative_to(ROOT))] + files,
                          cwd=ROOT, capture_output=True, text=True)
    if comp.returncode != 0:
        print(f"[COMPILE ERROR] {tb}\n{comp.stdout}{comp.stderr}")
        return False
    if comp.stderr.strip() and verbose:
        print(comp.stderr)
    sim = subprocess.run([vvp, "-n", str(vvp_file.relative_to(ROOT))],
                         cwd=ROOT, capture_output=True, text=True)
    out = sim.stdout + sim.stderr
    passed = f"PASS: {tb}" in out and "FAIL" not in out
    if verbose or not passed:
        print(out.rstrip())
    print(f"[{'PASS' if passed else 'FAIL'}] {tb}")
    return passed


def main():
    args = [a for a in sys.argv[1:] if a != "-v"]
    verbose = "-v" in sys.argv[1:]
    names = [a.removeprefix("tb_") for a in args] or list(TESTS)
    unknown = [n for n in names if n not in TESTS]
    if unknown:
        sys.exit(f"unknown testbench(es): {', '.join(unknown)}; choose from {', '.join(TESTS)}")
    BUILD.mkdir(exist_ok=True)
    iverilog, vvp = find_tool("iverilog"), find_tool("vvp")
    results = {n: run(n, iverilog, vvp, verbose) for n in names}
    passed = sum(results.values())
    print(f"\n{passed}/{len(results)} testbenches passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
