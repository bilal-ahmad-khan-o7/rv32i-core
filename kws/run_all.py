"""Run the KWS programs and produce the results.

    python3 kws/run_all.py iss        # all 19 inputs on builds a, b, c on rv32iss, every layer
                                     # checked; writes kws/results.md
    python3 kws/run_all.py rtl        # RTL against rv32iss: same bytes, same counts on every layer
    python3 kws/run_all.py accuracy   # the 1000 EEMBC files on build (c), against TFLite

    python3 kws/run_all.py iss --core pipelined   # the same, with rv32iss's pipeline cycle model;
                                                 # writes pipelined/results.md
    python3 kws/run_all.py rtl --core pipelined   # the pipelined RTL against that model

Run from anywhere; paths are relative to the repository root.
`iss` and `rtl` need only the committed images in kws/gen. `accuracy` needs TFLite,
so run it with the virtual environment's Python, after kws/ref/fetch_eembc.py.

RTL cross-check, per the plan: builds (b) and (c) in full, and build (a) up to the
end of the first conv (a full run of (a) would take about 8 hours in Icarus).
"""
import concurrent.futures
import os
import re
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent           # the repository root
SC = ROOT / "single_cycle"                              # the single-cycle core
GEN = ROOT / "kws" / "gen"
BUILD = ROOT / "build"
ISS = BUILD / ("rv32iss.exe" if os.name == "nt" else "rv32iss")
RESULTS = ROOT / "kws" / "results.md"
PIPE = ROOT / "pipelined"                               # the pipelined core
PIPE_RESULTS = PIPE / "results.md"
INPUT_ADDR, OUTPUT_ADDR = 0x1000F000, 0x1000F200
BUILDS = "abc"
WORDS = ["Down", "Go", "Left", "No", "Off", "On", "Right", "Stop", "Up", "Yes", "Silence", "Unknown"]

LAYER_NAMES = {0: "setup (fill padding)", 1: "conv 10x4", 2: "depthwise 1", 3: "pointwise 1", 4: "depthwise 2",
               5: "pointwise 2", 6: "depthwise 3", 7: "pointwise 3", 8: "depthwise 4", 9: "pointwise 4",
               10: "average pool", 12: "fully connected", 13: "arg-max (no softmax)"}
MACS = {0: 0, 1: 320000, 2: 72000, 3: 512000, 4: 72000, 5: 512000, 6: 72000, 7: 512000, 8: 72000, 9: 512000,
        10: 0, 12: 768, 13: 0}

MARK = re.compile(r"marker\s+(\d+):\s+(\d+) (?:instructions|cycles)")
STOPPED = re.compile(r"after (\d+) instructions")
# the pipelined core: cycles, instructions, load-use, flush, other (tb_core_kws.sv and rv32iss --pipeline)
PMARK = re.compile(r"marker\s+(\d+):\s+(\d+) cycles\s+\(total \d+\)\s+instructions (\d+)\s+load-use (\d+)"
                   r"\s+flush (\d+)\s+other (\d+)")
PWHOLE = re.compile(r"pipeline: (\d+) cycles = (\d+) instructions \+ (\d+) load-use \+ (\d+) flush \+ (\d+) other"
                    r"(?:.*?does not read: (\d+))?")
DUMP = re.compile(r"dump \w+:((?: \w\w)+)")


def input_names():
    return sorted(p.name[len("expect_"):-len(".hex")] for p in GEN.glob("expect_*.hex"))


def build_iss():
    gcc = shutil.which("gcc") or sys.exit("gcc not found: it builds iss/rv32iss.c")
    BUILD.mkdir(exist_ok=True)
    subprocess.run([gcc, "-O2", "-std=gnu11", "-o", str(ISS), str(ROOT / "iss" / "rv32iss.c")], check=True)


def run_iss(build, name, pipeline=False):
    cmd = [str(ISS), "--imem", f"kws/gen/kws_{build}.imem.hex", "--dmem", f"kws/gen/kws_{build}.dmem.hex",
           "--load", f"kws/gen/input_{name}.hex@{INPUT_ADDR:#x}", "--layers", "kws/gen/layers.hex",
           "--expect", f"kws/gen/expect_{name}.hex", "--dump", hex(OUTPUT_ADDR), "16"]
    if pipeline:
        cmd.append("--pipeline")
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return r.returncode == 0, r.stdout


def parse(out):
    return {int(m[0]): int(m[1]) for m in MARK.findall(out)}


def pparse(out):
    """Pipelined runs: {marker: (cycles, instructions, load-use, flush, other)}."""
    return {int(m[0]): tuple(int(v) for v in m[1:]) for m in PMARK.findall(out)}


def fmt(n):
    return f"{n / 1e6:.2f} M" if n >= 1e6 else f"{n / 1e3:.1f} k"


def cmd_iss():
    build_iss()
    names = input_names()
    jobs = [(b, n) for b in BUILDS for n in names]
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        outs = list(pool.map(lambda j: run_iss(*j), jobs))
    bad = [j for j, (ok, _) in zip(jobs, outs) if not ok]
    counts = {b: {} for b in BUILDS}
    whole = {b: {} for b in BUILDS}
    labels = {}
    stack = {}
    for (b, n), (ok, out) in zip(jobs, outs):
        counts[b][n] = parse(out)
        whole[b][n] = int(STOPPED.search(out)[1])
        stack[b] = max(stack.get(b, 0), 0x1000FFE0 - int(re.search(r"lowest sp: (\w+)", out)[1], 16))
        labels[b, n] = bytes.fromhex(DUMP.search(out)[1])[12]
    print(f"{len(jobs)} runs ({len(names)} inputs x 3 builds), every layer compared: {len(bad)} failed")
    for j in bad:
        print("  FAILED", j)
    report = (table(counts, whole) + "\n\n" + labels_table(labels)
              + "\n\nDeepest stack, any input: " + ", ".join(f"({b}) {stack[b]} B" for b in BUILDS) + "\n")
    print(report)
    RESULTS.write_text(HEADER + report, newline="\n")
    return 0 if not bad else 1


def cmd_iss_pipelined():
    build_iss()
    names = input_names()
    jobs = [(b, n) for b in BUILDS for n in names]
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        outs = list(pool.map(lambda j: run_iss(*j, pipeline=True), jobs))
    bad = [j for j, (ok, _) in zip(jobs, outs) if not ok]
    stats = {b: {} for b in BUILDS}
    whole = {b: {} for b in BUILDS}
    single = {b: {} for b in BUILDS}
    for (b, n), (ok, out) in zip(jobs, outs):
        stats[b][n] = pparse(out)
        whole[b][n] = tuple(int(v or 0) for v in PWHOLE.search(out).groups())
        single[b][n] = int(STOPPED.search(out)[1])          # instructions = single-cycle cycles
    print(f"{len(jobs)} runs ({len(names)} inputs x 3 builds), every layer compared: {len(bad)} failed")
    for j in bad:
        print("  FAILED", j)
    report = pipe_tables(stats, whole, single)
    print(report)
    PIPE_RESULTS.write_text(PIPE_HEADER + report, newline="\n")
    return 0 if not bad else 1


PIPE_HEADER = """# KWS on the pipelined core

Generated by `python3 kws/run_all.py iss --core pipelined`, with rv32iss's
pipeline cycle model. Figures are means over the 12 real recordings. Build (a) is a cycle-model
count, cross-checked with the RTL on the first conv layer; for builds (b) and (c) the model equals
the RTL exactly on every layer (`python3 kws/run_all.py rtl --core pipelined`).

Builds: (a) RV32I only, multiply in software (libgcc `__mulsi3`); (b) RV32I + Zmmul, hardware `mul`;
(c) RV32I + Zmmul + the custom DOT4.S8 and CLIP.S8. Same C program, same output bytes.

Every cycle the EX stage holds an instruction or a bubble, so per layer
cycles = instructions + load-use stall cycles + flush cycles (2 per taken branch or jump) + other,
where "other" is the 2-cycle pipeline fill before the first instruction (and, for the whole
program, 1 cycle of drain after ebreak).

"""


def pipe_tables(stats, whole, single):
    real = sorted(n for n in stats["a"] if n.startswith("tst_"))

    def mean(b, l, i):
        return statistics.mean(stats[b][n][l][i] for n in real)
    out = []
    for b in BUILDS:
        rows = [f"**Build ({b})**", "",
                "| # | Layer | Cycles | Instructions | CPI | Load-use cycles | Flush cycles | Other |",
                "|---|---|---:|---:|---:|---:|---:|---:|"]
        tot = [0.0] * 5
        for l, name in LAYER_NAMES.items():
            v = [mean(b, l, i) for i in range(5)]
            tot = [x + y for x, y in zip(tot, v)]
            rows.append(f"| {l or ''} | {name} | {fmt(v[0])} | {fmt(v[1])} | {v[0] / v[1]:.3f} | {fmt(v[2])} "
                        f"| {fmt(v[3])} | {v[4]:.0f} |")
        rows.append(f"| | **Total** | **{fmt(tot[0])}** | **{fmt(tot[1])}** | **{tot[0] / tot[1]:.3f}** "
                    f"| **{fmt(tot[2])}** | **{fmt(tot[3])}** | **{tot[4]:.0f}** |")
        w = [whole[b][n] for n in real]
        cyc = [x[0] for x in w]
        lu, false = statistics.mean(x[2] for x in w), statistics.mean(x[5] for x in w)
        rows += ["", f"Whole program to `ebreak`: mean {statistics.mean(cyc):,.0f} cycles, range {min(cyc):,} "
                 f"to {max(cyc):,}; CPI {statistics.mean(cyc) / statistics.mean(x[1] for x in w):.3f}.  ",
                 f"Load-use stalls on a register field the instruction does not read: {false:,.0f} of {lu:,.0f} "
                 f"({100 * false / max(lu, 1):.1f}% of the stalls, {100 * false / statistics.mean(cyc):.2f}% "
                 f"of all cycles).", ""]
        out.append("\n".join(rows))
    rows = ["**Single-cycle vs pipelined, in cycles**", "",
            "| Build | Single-cycle cycles | Pipelined cycles | Pipelined CPI | Pipelined / single-cycle |",
            "|---|---:|---:|---:|---:|"]
    times = []
    for b in BUILDS:
        s = statistics.mean(single[b][n] for n in real)
        p = statistics.mean(whole[b][n][0] for n in real)
        rows.append(f"| ({b}) | {s:,.0f} | {p:,.0f} | {p / statistics.mean(whole[b][n][1] for n in real):.3f} "
                    f"| {p / s:.3f} |")
        ts, tp = s / FMAX_MHZ["single"] / 1000, p / FMAX_MHZ["pipelined"] / 1000     # ms
        times.append(f"| ({b}) | {ms(ts)} | {ms(tp)} | {ts / tp:.2f}x |")
    out.append("\n".join(rows) + "\n")
    out.append("\n".join([
        f"**Single-cycle vs pipelined, in time** (maximum clock: single-cycle {FMAX_MHZ['single']:.2f} MHz, "
        f"pipelined {FMAX_MHZ['pipelined']:.2f} MHz; see `fpga/README.md`)", "",
        "Time per inference = cycles x (period - WNS), from Vivado runs constrained to 100 MHz: an",
        "estimate of what each core can run at, not a measured clock.", "",
        "| Build | Single-cycle | Pipelined | Pipelined faster by |",
        "|---|---:|---:|---:|"] + times) + "\n")
    return "\n".join(out)


# Maximum clock of each core, 1 / (period - WNS), from the Vivado 2026.1 runs of fpga/build.tcl on
# 2026-11-06 (xc7z020clg400-1, constrained to 100 MHz; fpga/README.md has the reports).
FMAX_MHZ = {"single": 1000 / (10 + 14.700), "pipelined": 1000 / (10 + 6.873)}


def ms(t):
    return f"{t / 1000:,.2f} s" if t >= 1000 else f"{t:,.1f} ms"


HEADER = """# KWS results

Generated by `python3 kws/run_all.py iss`. One instruction per clock, so cycles = instructions.
Cycle figures are means over the 12 real recordings. Build (a) is an instruction-simulator
count, cross-checked with the RTL on the first conv layer. Builds (b) and (c) were cross-checked
with the RTL on every layer (`python3 kws/run_all.py rtl`).

Builds: (a) RV32I only, multiply in software (libgcc `__mulsi3`); (b) RV32I + Zmmul, hardware `mul`;
(c) RV32I + Zmmul + the custom DOT4.S8 and CLIP.S8. Same C program, same output bytes.

"""


def labels_table(labels):
    """The predicted word for each real recording, from the core and from TFLite."""
    rows = ["| Recording | Word | Core (a) | Core (b) | Core (c) | TFLite |", "|---|---|---|---|---|---|"]
    for name in input_names():
        if name.startswith("tst_"):
            _, number, word, truth = name.split("_")
            want = int((GEN / f"expect_{name}.hex").read_text().split()[-1], 16)   # the file ends with the label
            rows.append(f"| {number} | {word} | " + " | ".join(WORDS[labels[b, name]] for b in BUILDS)
                        + f" | {WORDS[want]} |")
    return "\n".join(rows)


def table(counts, whole):
    """Markdown: cycles and instructions per MAC per layer, over the 12 real words."""
    real = [n for n in counts["a"] if n.startswith("tst_")]
    def mean(b, l):
        return statistics.mean(counts[b][n][l] for n in real)
    rows = ["| # | Layer | MACs | (a) cycles | (b) cycles | (c) cycles | (b)/(c) | (a)/(c) "
            "| (a) instr/MAC | (b) instr/MAC | (c) instr/MAC |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    total = {b: 0 for b in BUILDS}
    for l, name in LAYER_NAMES.items():
        a, b, c = (mean(x, l) for x in BUILDS)
        for x, v in zip(BUILDS, (a, b, c)):
            total[x] += v
        mac = MACS[l]
        per = [f"{v / mac:.1f}" if mac else "-" for v in (a, b, c)]
        rows.append(f"| {l or ''} | {name} | {mac:,} | {fmt(a)} | {fmt(b)} | {fmt(c)} | {b / c:.2f}x | {a / c:.1f}x "
                    f"| {per[0]} | {per[1]} | {per[2]} |")
    a, b, c = total["a"], total["b"], total["c"]
    m = sum(MACS.values())
    rows.append(f"| | **Total** | **{m:,}** | **{fmt(a)}** | **{fmt(b)}** | **{fmt(c)}** | **{b / c:.2f}x** "
                f"| **{a / c:.1f}x** | **{a / m:.1f}** | **{b / m:.1f}** | **{c / m:.1f}** |")
    rows.append("")
    for x in BUILDS:
        t = [whole[x][n] for n in real]
        rows.append(f"Build ({x}), whole program to `ebreak`: mean {statistics.mean(t):,.0f}, "
                    f"range {min(t):,} to {max(t):,}  ")
    return "\n".join(rows)


def run_rtl(build, name, stop=None, pipelined=False):
    vvp = shutil.which("vvp") or sys.exit("vvp not found on PATH (install Icarus Verilog 12+)")
    gen = "../kws/gen"                                  # from single_cycle/ or pipelined/
    args = [vvp, "-n", "build/tb_core_kws_runall.vvp" if pipelined else "build/tb_core_kws.vvp",
            f"+PROG={gen}/kws_{build}.imem.hex", f"+DATA={gen}/kws_{build}.dmem.hex",
            f"+INPUT={gen}/input_{name}.hex", f"+LAYERS={gen}/layers.hex", f"+EXPECT={gen}/expect_{name}.hex",
            "+MAX=500000000"]
    if stop is not None:
        args.append(f"+STOP={stop}")
    r = subprocess.run(args, cwd=PIPE if pipelined else SC, capture_output=True, text=True)
    return "PASS: tb_core_kws" in r.stdout and "FAIL" not in r.stdout, r.stdout


def compile_tb():
    iverilog = shutil.which("iverilog") or sys.exit("iverilog not found on PATH (install Icarus Verilog 12+)")
    rtl = [f"rtl/{m}.sv" for m in ("riscv_pkg", "pc_reg", "imem", "regfile", "dmem", "imm_gen", "alu", "control",
                                   "branch_unit", "lsu", "mul_unit", "nn_unit", "if_stage", "id_stage",
                                   "ex_stage", "mem_stage", "wb_stage", "riscv_core")]
    (SC / "build").mkdir(exist_ok=True)
    subprocess.run([iverilog, "-g2012", "-Wno-timescale", "-s", "tb_core_kws", "-o", "build/tb_core_kws.vvp",
                    *rtl, "tb/tb_core_kws.sv"], cwd=SC, check=True)


def compile_pipelined_tb():
    """The pipelined core's file list comes from its own run_tests.py."""
    sys.path.insert(0, str(PIPE / "sim"))
    import run_tests as prt
    iverilog = shutil.which("iverilog") or sys.exit("iverilog not found on PATH (install Icarus Verilog 12+)")
    files = [prt.rel(p) for p in prt.PKG + prt.CORE + [prt.TB / "tb_core_kws.sv"]]
    (PIPE / "build").mkdir(exist_ok=True)
    subprocess.run([iverilog, "-g2012", "-Wno-timescale", "-s", "tb_core_kws", "-o", "build/tb_core_kws_runall.vvp",
                    *files], cwd=PIPE, check=True)


def cmd_rtl_pipelined():
    """The pipelined RTL against rv32iss --pipeline: the same bytes at every layer, and at every
    marker the same cycles, instructions, load-use, flush and other."""
    build_iss()
    compile_pipelined_tb()
    names = input_names()
    jobs = [("c", n, None) for n in names] + [("b", "tst_000007_Yes_9", None), ("a", "tst_000007_Yes_9", 1)]
    print(f"{len(jobs)} pipelined RTL runs, 6 at a time", flush=True)
    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        outs = list(pool.map(lambda j: run_rtl(*j, pipelined=True), jobs))
    failures = 0
    for (b, n, stop), (ok, out) in zip(jobs, outs):
        rtl = pparse(out)
        _, iss_out = run_iss(b, n, pipeline=True)
        iss = pparse(iss_out)
        same = bool(rtl) and all(iss.get(k) == v for k, v in rtl.items())
        if stop is None:                                      # full runs: the whole-program split too
            w_rtl, w_iss = PWHOLE.search(out), PWHOLE.search(iss_out)
            same = same and w_rtl is not None and w_iss is not None and w_rtl.groups()[:5] == w_iss.groups()[:5]
        failures += not (ok and same)
        print(f"build ({b}) {n:26} {len(rtl) - 1:2} layers: RTL bytes {'ok' if ok else 'WRONG'}, "
              f"RTL cycles and stall split == cycle model: {same}"
              + (f" (up to marker {stop})" if stop is not None else ""), flush=True)
        if not (ok and same):
            print(out[-1500:])
            print(iss_out[-1500:])
    print(f"{len(jobs)} pipelined RTL runs: {failures} failed")
    return 1 if failures else 0


def cmd_rtl():
    build_iss()
    compile_tb()
    names = input_names()
    jobs = [("c", n, None) for n in names] + [("b", "tst_000007_Yes_9", None), ("a", "tst_000007_Yes_9", 1)]
    print(f"{len(jobs)} RTL runs, 6 at a time", flush=True)
    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        outs = list(pool.map(lambda j: run_rtl(*j), jobs))
    failures = 0
    for (b, n, stop), (ok, out) in zip(jobs, outs):
        rtl = parse(out)
        _, iss_out = run_iss(b, n)
        iss = parse(iss_out)
        same = all(iss.get(k) == v for k, v in rtl.items()) and rtl
        layers = len(rtl) - 1
        verdict = "ok" if ok and same else "DIFFERENT"
        failures += verdict != "ok"
        print(f"build ({b}) {n:26} {layers:2} layers: RTL bytes {'ok' if ok else 'WRONG'}, "
              f"RTL cycles == simulator instructions: {bool(same)}"
              + (f" (up to marker {stop})" if stop is not None else ""), flush=True)
        if not (ok and same):
            print(out[-1500:])
    print(f"{len(jobs)} RTL runs: {failures} failed")
    return 1 if failures else 0


def iss_output(path):
    """Run build (c) on one raw .bin; returns the 12 scores and the label."""
    cmd = [str(ISS), "--imem", "kws/gen/kws_c.imem.hex", "--dmem", "kws/gen/kws_c.dmem.hex",
           "--load-bin", f"{path}@{INPUT_ADDR:#x}", "--dump", hex(OUTPUT_ADDR), "16", "--quiet"]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    m = DUMP.search(r.stdout)
    if r.returncode != 0 or not m:
        raise SystemExit(f"rv32iss failed on {path}:\n{r.stdout}{r.stderr}")
    b = bytes.fromhex(m[1])
    return [v - 256 if v > 127 else v for v in b[:12]], int.from_bytes(b[12:16], "little")


def cmd_accuracy():
    import numpy as np
    sys.path.insert(0, str(ROOT / "kws" / "ref"))
    import check_ref
    import inputs
    import model

    build_iss()
    files = sorted(inputs.ALL_DIR.glob("*.bin"))
    if len(files) != 1000:
        sys.exit(f"expected 1000 files in {inputs.ALL_DIR}, found {len(files)}: run kws/ref/fetch_eembc.py")
    it = model.open_interpreter()
    layers = model.load_layers(it)
    fc = next(l.id for l in layers.values() if l.kind == "fc")
    tfl = {}
    for p in files:
        out = check_ref.tflite_layers(it, layers, np.fromfile(p, dtype=np.int8))[fc].ravel()
        tfl[p.name] = [int(v) for v in out]
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        core = dict(zip((p.name for p in files), pool.map(iss_output, files)))
    differ = core_ok = tfl_ok = 0
    for p in files:
        scores, label = core[p.name]
        want = tfl[p.name]
        truth = inputs.label_of(p)
        core_ok += label == truth
        tfl_ok += int(np.argmax(want)) == truth
        if scores != want or label != int(np.argmax(want)):
            differ += 1
            print(f"DIFFERENT {p.name}: core {scores} label {label}, TFLite {want}")
    print(f"1000 EEMBC files, build (c) on rv32iss against TFLite reference kernels")
    print(f"accuracy: core {core_ok / 10:.1f}%, TFLite {tfl_ok / 10:.1f}%")
    print(f"files where the 12 FC scores or the label differ: {differ}")
    return 1 if differ else 0


def main():
    cmds = {"iss": cmd_iss, "rtl": cmd_rtl, "accuracy": cmd_accuracy,
            "iss --core single": cmd_iss, "rtl --core single": cmd_rtl,
            "iss --core pipelined": cmd_iss_pipelined, "rtl --core pipelined": cmd_rtl_pipelined}
    key = " ".join(sys.argv[1:])
    if key not in cmds:
        sys.exit(__doc__)
    sys.exit(cmds[key]())


if __name__ == "__main__":
    main()
