"""Simulate the FPGA wrapper with Icarus, for one core or both, before running Vivado.

    python3 fpga/sim/run_sim.py                 # both cores
    python3 fpga/sim/run_sim.py pipelined       # or: single_cycle

Uses the same source lists as build.tcl, plus xilinx_stubs.sv for the MMCM and the clock
buffer. Each run takes a few minutes (about 3.5 million core cycles).
"""
import shutil
import subprocess
import sys
from pathlib import Path

FPGA = Path(__file__).resolve().parent.parent
SOURCES = {
    "pipelined": ["../single_cycle/rtl/riscv_pkg.sv", "../pipelined/rtl/pipeline_pkg.sv"]
    + [f"../single_cycle/rtl/{m}.sv" for m in ("pc_reg", "regfile", "imm_gen", "alu", "control", "branch_unit",
                                                "lsu", "mul_unit", "nn_unit", "id_stage", "ex_stage", "wb_stage")]
    + [f"../pipelined/rtl/{m}.sv" for m in ("imem", "dmem", "if_stage", "mem_stage", "if_id_reg", "id_ex_reg",
                                             "ex_mem_reg", "mem_wb_reg", "hazard_unit", "forward_unit", "rf_bypass",
                                             "riscv_core")],
    "single_cycle": ["../single_cycle/rtl/riscv_pkg.sv"]
    + [f"../single_cycle/rtl/{m}.sv" for m in ("pc_reg", "imem", "regfile", "dmem", "imm_gen", "alu", "control",
                                                "branch_unit", "lsu", "mul_unit", "nn_unit", "if_stage", "id_stage",
                                                "ex_stage", "mem_stage", "wb_stage", "riscv_core")],
}
WRAPPER = ["rtl/clock_gen.sv", "rtl/reset_sync.sv", "rtl/top_kws.sv", "sim/xilinx_stubs.sv", "sim/tb_top_kws.sv"]


def tool(name):
    return shutil.which(name) or sys.exit(f"error: {name} not found on PATH (install Icarus Verilog 12+)")


def main():
    cores = sys.argv[1:] or list(SOURCES)
    (FPGA / "out").mkdir(exist_ok=True)
    ok = True
    for core in cores:
        vvp = f"out/tb_top_kws_{core}.vvp"
        subprocess.run([tool("iverilog"), "-g2012", "-Wno-timescale", "-s", "tb_top_kws", "-o", vvp,
                        *SOURCES[core], *WRAPPER], cwd=FPGA, check=True)
        r = subprocess.run([tool("vvp"), "-n", vvp], cwd=FPGA, capture_output=True, text=True)
        result = [l for l in r.stdout.splitlines() if l.startswith(("after", "PASS", "FAIL"))]
        print(f"{core}: " + "  ".join(result))
        ok = ok and any(l.startswith("PASS") for l in result)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
