"""Compile and run every testbench of the pipelined core with Icarus Verilog.

    python3 sim/run_tests.py              # the fast suite
    python3 sim/run_tests.py alu random   # only those
    python3 sim/run_tests.py -v core      # also print the full simulator output
    python3 sim/run_tests.py kws          # slow: hello and the KWS model, never run by default
    python3 sim/run_tests.py random_slow  # slow: 300 new random programs against rv32iss

Runs from this folder (pipelined/), whatever the current directory is. The blocks the
pipelined core reuses unchanged, and their unit testbenches, come from ../single_cycle/;
so do the KWS images and rv32iss. Needs iverilog and vvp (Icarus 12+) on PATH. random_slow also needs a host gcc, to build rv32iss.
Exit code is 0 only if every testbench passes.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # pipelined/
SC = ROOT.parent / "single_cycle"
RTL, TB = ROOT / "rtl", ROOT / "tb"
SC_RTL, SC_TB = SC / "rtl", SC / "tb"
BUILD = ROOT / "build"
RANDOM = ROOT / "programs" / "random"                  # committed random programs + expected results
sys.path.insert(0, str(ROOT / "programs"))

PKG = [SC_RTL / "riscv_pkg.sv", RTL / "pipeline_pkg.sv"]      # first on the command line
# reused unchanged from single_cycle/rtl
SHARED = [SC_RTL / f"{m}.sv" for m in (
    "pc_reg", "regfile", "imm_gen", "alu", "control", "branch_unit", "lsu", "mul_unit", "nn_unit",
    "id_stage", "ex_stage", "wb_stage")]
# changed copies and new modules, in pipelined/rtl
OWN = [RTL / f"{m}.sv" for m in (
    "imem", "dmem", "if_stage", "mem_stage",
    "if_id_reg", "id_ex_reg", "ex_mem_reg", "mem_wb_reg",
    "hazard_unit", "forward_unit", "rf_bypass", "riscv_core")]
CORE = SHARED + OWN

# testbench name -> (testbench file, design files); the packages are always added first
TESTS = {
    # blocks reused unchanged: the single-cycle testbenches, run again here
    "pc_reg":      (SC_TB / "tb_pc_reg.sv",      [SC_RTL / "pc_reg.sv"]),
    "regfile":     (SC_TB / "tb_regfile.sv",     [SC_RTL / "regfile.sv"]),
    "alu":         (SC_TB / "tb_alu.sv",         [SC_RTL / "alu.sv"]),
    "imm_gen":     (SC_TB / "tb_imm_gen.sv",     [SC_RTL / "imm_gen.sv"]),
    "control":     (SC_TB / "tb_control.sv",     [SC_RTL / "control.sv"]),
    "branch_unit": (SC_TB / "tb_branch_unit.sv", [SC_RTL / "branch_unit.sv"]),
    "lsu":         (SC_TB / "tb_lsu.sv",         [SC_RTL / "lsu.sv"]),
    "mul_unit":    (SC_TB / "tb_mul_unit.sv",    [SC_RTL / "mul_unit.sv"]),
    "nn_unit":     (SC_TB / "tb_nn_unit.sv",     [SC_RTL / "nn_unit.sv"]),
    # changed blocks: adapted testbenches
    "imem":        (TB / "tb_imem.sv",           [RTL / "imem.sv"]),
    "dmem":        (TB / "tb_dmem.sv",           [RTL / "dmem.sv"]),
    # new blocks
    "forward_unit": (TB / "tb_forward_unit.sv",  [RTL / "forward_unit.sv"]),
    "hazard_unit":  (TB / "tb_hazard_unit.sv",   [RTL / "hazard_unit.sv"]),
    "rf_bypass":    (TB / "tb_rf_bypass.sv",     [RTL / "rf_bypass.sv"]),
    # whole core
    "core":        (TB / "tb_core.sv",           CORE),
    "core_dot64":  (TB / "tb_core_dot64.sv",     CORE),
    "hazards":     (TB / "tb_core_kws.sv",       CORE),
    "random":      (TB / "tb_core_kws.sv",       CORE),
}

# Slow targets: left out of the default run, so name them to run them.
SLOW = {
    "kws":         (TB / "tb_core_kws.sv",       CORE),
    "random_slow": (TB / "tb_core_kws.sv",       CORE),
}

KWS = "../single_cycle/kws"


def hello_args(build):
    return [f"+PROG={KWS}/gen/hello_{build}.imem.hex", f"+DATA={KWS}/gen/hello_{build}.dmem.hex",
            f"+LAYERS={KWS}/sw/hello_layers.hex", f"+EXPECT={KWS}/sw/hello_expect.hex"]


def kws_args(name):
    return [f"+PROG={KWS}/gen/kws_c.imem.hex", f"+DATA={KWS}/gen/kws_c.dmem.hex",
            f"+INPUT={KWS}/gen/input_{name}.hex", f"+LAYERS={KWS}/gen/layers.hex",
            f"+EXPECT={KWS}/gen/expect_{name}.hex", "+MAX=500000000"]


def random_run(prefix):
    """A run of one random program, and the check that its trace and final data window
    equal rv32iss's (PREFIX.trace, PREFIX.dump)."""
    name = Path(prefix).name
    trace = BUILD / "random" / f"{name}.trace"
    args = [f"+PROG={Path(prefix).relative_to(ROOT).as_posix()}.imem.hex",
            f"+INPUT={Path(prefix).relative_to(ROOT).as_posix()}.data.hex",
            f"+TRACE={trace.relative_to(ROOT).as_posix()}", "+DUMP=1000f000", "+DUMP_LEN=256",
            "+MAX=100000"]          # these run a few thousand cycles; a bug that loops stops here

    def check(out):
        want_trace = Path(f"{prefix}.trace").read_text().splitlines()    # CRLF after a checkout
        got_trace = trace.read_text().splitlines() if trace.exists() else []
        for i, (w, g) in enumerate(zip(want_trace, got_trace)):
            if w != g:
                return f"{name}: trace line {i + 1}: rv32iss '{w}', RTL '{g}'"
        if len(want_trace) != len(got_trace):
            return f"{name}: trace has {len(got_trace)} lines, rv32iss {len(want_trace)}"
        want_dump = Path(f"{prefix}.dump").read_text().strip().lower()
        got_dump = next((l.strip().lower() for l in out.splitlines() if l.startswith("dump ")), "")
        if want_dump != got_dump:
            return f"{name}: final data window differs from rv32iss"
        return None
    return args, check


HAZARDS = ROOT / "programs" / "hazards"               # written by programs/gen_hazards.py


def hazard_runs():
    """The directed hazard programs. Each must match rv32iss like a random program; the
    case program must also spend exactly the stall and flush cycles in hazards.cases."""
    runs = []
    for p in sorted(HAZARDS.glob("*.imem.hex")):
        prefix = str(p)[:-len(".imem.hex")]
        args, same_as_iss = random_run(prefix)
        if Path(prefix).name != "hazards":
            runs.append((args, same_as_iss))
            continue
        want = {}
        for line in (HAZARDS / "hazards.cases").read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                k, lu, rd, name = line.split(maxsplit=3)
                want[int(k)] = (int(lu), 2 * int(rd), name)

        def check(out, same_as_iss=same_as_iss, want=want):
            got = {}
            for line in out.splitlines():
                f = line.split()
                if f and f[0] == "marker":
                    got[int(f[1].rstrip(":"))] = (int(f[f.index("load-use") + 1]), int(f[f.index("flush") + 1]))
            for k, (lu, fl, name) in want.items():
                if got.get(k) != (lu, fl):
                    return f"case {k} ({name}): load-use/flush cycles {got.get(k)}, expected {(lu, fl)}"
            return same_as_iss(out)
        runs.append((args, check))
    return runs


def committed_random():
    return [random_run(str(p)[:-len(".imem.hex")]) for p in sorted(RANDOM.glob("*.imem.hex"))]


def new_random(count=300, first_seed=1000):
    """Generate fresh programs (half padded, half hazard-dense) with rv32iss's results."""
    import gen_random
    out = BUILD / "random_slow"
    out.mkdir(parents=True, exist_ok=True)
    runs = []
    for seed in range(first_seed, first_seed + count):
        prefix = out / f"seed{seed}"
        gen_random.write_program(seed, str(prefix), padded=(seed % 2 == 0), with_expect=True)
        runs.append(random_run(str(prefix)))
    return runs


# target -> its runs: one (plusargs, check) per simulation; check(output) returns an
# error message or None
def runs_of(name):
    if name == "kws":
        # tst_000012_Go_1 is the one committed recording where FC's rounding shows;
        # syn_random is the one that drives the upper clamp
        return [(a, None) for a in (hello_args("a"), hello_args("b"), hello_args("c"),
                                    kws_args("tst_000012_Go_1"), kws_args("syn_random"))]
    if name == "random":
        return committed_random()
    if name == "hazards":
        return hazard_runs()
    if name == "random_slow":
        return new_random()
    return [([], None)]


def find_tool(name):
    return shutil.which(name) or sys.exit(f"error: {name} not found on PATH (install Icarus Verilog 12+)")


def rel(p):
    """A path as the compiler sees it from pipelined/: rtl/x.sv or ../single_cycle/rtl/x.sv."""
    return Path(os.path.relpath(p, ROOT)).as_posix()


def run(name, iverilog, vvp, verbose):
    tb_file, design = TESTS[name] if name in TESTS else SLOW[name]
    tb = tb_file.stem
    vvp_file = f"build/{tb}_{name}.vvp"
    files = [rel(p) for p in PKG + design + [tb_file]]
    incs = ["-I../single_cycle/programs"]                 # dot64_expect.svh
    comp = subprocess.run([iverilog, "-g2012", "-Wall", "-Wno-timescale", "-s", tb, "-o", vvp_file]
                          + incs + files, cwd=ROOT, capture_output=True, text=True)
    if comp.returncode != 0:
        print(f"[COMPILE ERROR] {tb}\n{comp.stdout}{comp.stderr}")
        return False
    if comp.stderr.strip() and verbose:
        print(comp.stderr)
    (BUILD / "random").mkdir(exist_ok=True)
    passed, runs = True, runs_of(name)
    for plusargs, check in runs:
        sim = subprocess.run([vvp, "-n", vvp_file] + plusargs, cwd=ROOT, capture_output=True, text=True)
        out = sim.stdout + sim.stderr
        ok = f"PASS: {tb}" in out and "FAIL" not in out
        problem = check(out) if (check and ok) else None
        if verbose or not ok or problem:
            print(out.rstrip())
        if problem:
            print(f"  DIFFERENT: {problem}")
        passed = passed and ok and not problem
    label = f"{tb} ({name}, {len(runs)} programs)" if name in ("random", "random_slow", "hazards") else tb
    print(f"[{'PASS' if passed else 'FAIL'}] {label}")
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
