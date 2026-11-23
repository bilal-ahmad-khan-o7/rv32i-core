"""Compile and run every testbench of the single-cycle core with Icarus Verilog.

    python sim/run_tests.py              # all testbenches
    python sim/run_tests.py alu core     # only tb_alu and tb_core
    python sim/run_tests.py -v core      # also print the full simulator output
    python sim/run_tests.py kws          # the slow KWS test (about 10 minutes), never run by default

Runs from the project folder (whatever the current directory is), so the
$readmemh / $dumpfile paths inside the testbenches ("programs/...", "build/...")
resolve. Needs iverilog and vvp (Icarus 12+) on PATH, or in C:\\iverilog\\bin.
Exit code is 0 only if every testbench prints "PASS:".
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # the project folder (rtl/, tb/, ...)
RTL = ROOT / "rtl"
TB = ROOT / "tb"
BUILD = ROOT / "build"

PKG = [RTL / "riscv_pkg.sv"]                           # must be first on the command line
BLOCKS = [RTL / f"{m}.sv" for m in (
    "pc_reg", "imem", "regfile", "dmem", "imm_gen", "alu",
    "control", "branch_unit", "lsu", "mul_unit", "nn_unit")]
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
    "mul_unit":    [RTL / "mul_unit.sv"],
    "nn_unit":     [RTL / "nn_unit.sv"],
    "core":        BLOCKS + STAGES,
    "core_dot64":  BLOCKS + STAGES,
}

# extra include directories (for `include files), relative to ROOT
INCLUDES = {
    "core_dot64":  ["programs"],              # dot64_expect.svh, written by programs/gen_dot64.py
}


def hello_args(build):
    """Plusargs of one tb_core_kws run of the tiny bring-up program."""
    return [f"+PROG=kws/gen/hello_{build}.imem.hex", f"+DATA=kws/gen/hello_{build}.dmem.hex",
            "+LAYERS=kws/sw/hello_layers.hex", "+EXPECT=kws/sw/hello_expect.hex"]


def kws_args(name):
    """Plusargs of one tb_core_kws run of the full model, build (c)."""
    return ["+PROG=kws/gen/kws_c.imem.hex", "+DATA=kws/gen/kws_c.dmem.hex", f"+INPUT=kws/gen/input_{name}.hex",
            "+LAYERS=kws/gen/layers.hex", f"+EXPECT=kws/gen/expect_{name}.hex"]


# Slow targets: left out of the default run, so name them to run them. They use the
# committed images in kws/gen, so they need no RISC-V toolchain.
SLOW = {
    "kws":         BLOCKS + STAGES,
}
TESTBENCH = {"kws": "tb_core_kws"}            # when the target name differs from tb_<name>
# target -> one list of plusargs per simulation
RUNS = {
    # tst_000012_Go_1 is the one committed recording where FC's rounding shows: with
    # MultiplyByQuantizedMultiplier there, one score would differ from TFLite's
    "kws":         [hello_args("a"), hello_args("b"), hello_args("c"),
                    kws_args("tst_000012_Go_1"), kws_args("syn_random")],
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
    tb = TESTBENCH.get(name, f"tb_{name}")
    vvp_file = BUILD / f"{tb}.vvp"
    design = TESTS[name] if name in TESTS else SLOW[name]
    files = [str(p.relative_to(ROOT)) for p in PKG + design + [TB / f"{tb}.sv"]]
    incs = [f"-I{d}" for d in INCLUDES.get(name, [])]
    comp = subprocess.run([iverilog, "-g2012", "-Wall", "-Wno-timescale", "-s", tb,
                           "-o", str(vvp_file.relative_to(ROOT))] + incs + files,
                          cwd=ROOT, capture_output=True, text=True)
    if comp.returncode != 0:
        print(f"[COMPILE ERROR] {tb}\n{comp.stdout}{comp.stderr}")
        return False
    if comp.stderr.strip() and verbose:
        print(comp.stderr)
    passed = True
    for plusargs in RUNS.get(name, [[]]):
        sim = subprocess.run([vvp, "-n", str(vvp_file.relative_to(ROOT))] + plusargs,
                             cwd=ROOT, capture_output=True, text=True)
        out = sim.stdout + sim.stderr
        ok = f"PASS: {tb}" in out and "FAIL" not in out
        if verbose or not ok:
            print(out.rstrip())
        passed = passed and ok
    print(f"[{'PASS' if passed else 'FAIL'}] {tb}")
    return passed


def main():
    args = [a for a in sys.argv[1:] if a != "-v"]
    verbose = "-v" in sys.argv[1:]
    names = [a.removeprefix("tb_") for a in args] or list(TESTS)
    unknown = [n for n in names if n not in TESTS and n not in SLOW]
    if unknown:
        sys.exit(f"unknown testbench(es): {', '.join(unknown)}; choose from {', '.join([*TESTS, *SLOW])}")
    BUILD.mkdir(exist_ok=True)
    iverilog, vvp = find_tool("iverilog"), find_tool("vvp")
    results = {n: run(n, iverilog, vvp, verbose) for n in names}
    passed = sum(results.values())
    print(f"\n{passed}/{len(results)} testbenches passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
