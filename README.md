# RV32I core with INT8 instructions for keyword spotting

A RISC-V core in SystemVerilog, built step by step from a single-cycle design to a 5-stage pipeline, that runs the MLPerf Tiny keyword-spotting (KWS) model on a PYNQ-Z2 FPGA.

- **ISA:** RV32I + Zmmul (`mul`, `mulh`, `mulhsu`, `mulhu`) + two custom INT8 instructions, `DOT4.S8` and `CLIP.S8`.
- **Two cores:** single-cycle, and 5-stage pipelined with forwarding and a one-cycle load-use stall.
- **Verified:** both pass the official RISC-V architectural tests (RISCOF, compared with Spike), plus unit testbenches, directed hazard tests and random programs checked against an instruction simulator.
- **Bit-exact KWS:** every layer matches TFLite's reference kernels byte for byte. The custom instructions make the model 3.48× faster than with `mul` alone.

## Results

| | Single-cycle | Pipelined |
|---|---:|---:|
| RISCOF: RV32I / multiply tests | 38/38, 4/4 | 38/38, 4/4 |
| Max clock on the PYNQ-Z2 (Vivado estimate) | 40.5 MHz | 59.3 MHz |
| KWS inference, cycles | 3.37 M | 3.56 M (CPI 1.056) |
| KWS inference, time | 83.2 ms | 60.0 ms |
| Slice LUTs / flip-flops / BRAM tiles / DSPs | 11,061 / 42 / 0 / 4 | 1,784 / 621 / 24 / 4 |

KWS with the custom instructions: 3.37 M cycles. With Zmmul only: 11.7 M. With software multiply: 333 M. Accuracy on the 1000 test files is 90.1%, the same as TFLite.

## Custom instructions

Both use the custom-0 opcode (`0001011`), R format, funct7 = `0000000`.

| Instruction | funct3 | Operation |
|---|---|---|
| `DOT4.S8 rd, rs1, rs2` | `001` | `rd += Σ sext(rs1.byte[i]) · sext(rs2.byte[i])` over the 4 bytes |
| `CLIP.S8 rd, rs1` | `010` | `rd = clamp(signed(rs1), −128, 127)` |

## Repository layout

| Folder | Contents |
|---|---|
| [`single_cycle/`](single_cycle/) | the single-cycle core and its testbenches, the KWS C code and Python reference, the instruction simulator `rv32iss` |
| [`pipelined/`](pipelined/) | the 5-stage pipeline; reuses the unchanged modules and KWS files from `single_cycle/` |
| [`riscof/`](riscof/) | the RISCOF setup: DUT and Spike plugins, testbench, run script |
| [`fpga/`](fpga/) | Vivado scripts and the PYNQ-Z2 wrapper for both cores |

Each folder's README covers its design, tests and results in detail.

## Quick start

Requires Icarus Verilog 12+ and Python 3 (Ubuntu / WSL2). RISCOF also needs `riscv64-unknown-elf-gcc` and Spike; see [`riscof/README.md`](riscof/README.md).

```bash
python3 single_cycle/sim/run_tests.py
```

```bash
python3 pipelined/sim/run_tests.py
```

```bash
cd riscof && ./run_riscof.sh
```

The first two run the fast regression suites: 13 and 18 testbenches, a few seconds each. The third runs the 38 RV32I architectural tests.

## Tools

Icarus Verilog, GTKWave, RISC-V GCC, Spike, RISCOF, Vivado, Python (NumPy, TFLite).
