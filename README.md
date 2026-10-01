# RV32I RISC-V Core

A single-cycle RV32I processor written in SystemVerilog, with a self-checking test suite.
A 5-stage pipelined version is in progress.

## Status

- [x] Single-cycle RV32I datapath (fetch, decode, execute, memory, writeback)
- [x] 10/10 self-checking testbenches pass (unit tests + full-core smoke test)
- [x] All RV32I instructions exercised by the smoke test except ECALL (39/40)
- [ ] Verified against the official RISC-V architectural tests (RISCOF)
- [ ] 5-stage pipeline with hazard detection and forwarding

## Repository layout

| Folder / file | Contents |
|---|---|
| `rtl/` | Design (SystemVerilog) |
| `tb/` | Testbenches, one per block plus `tb_core` for the whole core |
| `programs/` | Test programs: `smoke.s` (assembly) and `smoke.hex` (machine code) |
| `sim/run_tests.py` | Regression script: compiles and runs every testbench |
| `rtl.f` | File list for compiling the design (package first) |
| `docs/diagrams/` | Block diagrams |

### Design modules (`rtl/`)

| Module | Role |
|---|---|
| `riscv_pkg` | Shared constants (opcodes, ALU operation codes) |
| `pc_reg` | Program counter |
| `imem` / `dmem` | Instruction memory / data memory |
| `regfile` | 32 x 32-bit register file (x0 hard-wired to 0) |
| `imm_gen` | Builds immediates for the I/S/B/U/J formats |
| `control` | Main decoder: turns an instruction into control signals |
| `alu` | Arithmetic, logic, shift and compare operations |
| `branch_unit` | Decides whether a branch is taken |
| `lsu` | Load/store unit: byte/half/word access and sign extension |
| `if_stage` ... `wb_stage` | Datapath grouped into the five classic steps |
| `riscv_core` | Top level: connects everything |

## Quick start

Requirements (Ubuntu / WSL2): `iverilog` (Icarus Verilog 12+), `python3`, `gtkwave` (optional).

Run the full test suite:

```bash
python3 sim/run_tests.py            # all testbenches
python3 sim/run_tests.py alu core   # only some
python3 sim/run_tests.py -v core    # with full simulator output
```

Compile and run the full core by hand:

```bash
mkdir -p build
iverilog -g2012 -o build/core.vvp -c rtl.f tb/tb_core.sv
vvp build/core.vvp
gtkwave build/tb_core.vcd           # view waveforms
```

## How the core is tested

`tb_core` loads `programs/smoke.hex` into instruction memory, runs the core until it reaches
`ebreak`, then checks every register (x1–x31) and a block of result words in data memory
against values worked out by hand from `programs/smoke.s`.

## Roadmap

1. Run the official RISC-V architectural tests with RISCOF, using Spike as the reference model
2. 5-stage pipeline with hazard detection and forwarding
3. Custom SIMD instructions for quantized neural-network inference
4. FPGA implementation

## Tools

Icarus Verilog, GTKWave, Verilator, RISC-V GCC (`riscv64-unknown-elf`), Python 3
