# Single-cycle RV32I core + Zmmul + custom INT8 instructions

A single-cycle RV32I core, written from scratch in SystemVerilog and extended step by step. The 5-stage pipelined version of this core is in [`../pipelined/`](../pipelined/).

The core executes one instruction per clock cycle. Beyond RV32I it implements:
- **Zmmul**: the multiply half of the RISC-V M extension (`mul`, `mulh`, `mulhsu`, `mulhu`; no divide).
- **DOT4.S8** and **CLIP.S8**: two custom-0 instructions for quantised (INT8) neural-network inference. They target the MLPerf Tiny keyword-spotting model, which the core runs bit-exact with TFLite; see [`../kws/`](../kws/).

It is split into five **stage modules** (`if_stage`, `id_stage`, `ex_stage`, `mem_stage`, `wb_stage`); `riscv_core` only wires them together. When the core is pipelined, the IF/ID, ID/EX, EX/MEM and MEM/WB registers go on exactly the wires between the stages, and the stage modules stay as they are.

## Layout

| Path | Contents |
|---|---|
| `rtl/riscv_pkg.sv` | opcodes, funct7/funct3 codes, `ALU_*`, `IMM_*`, `WB_*`, `EX_*` constants (compile first) |
| `rtl/pc_reg.sv`, `imem.sv`, `regfile.sv`, `dmem.sv` | state: PC, instruction ROM, register file (3 read ports), data RAM (optional preload) |
| `rtl/imm_gen.sv`, `alu.sv`, `control.sv`, `branch_unit.sv`, `lsu.sv` | combinational blocks |
| `rtl/mul_unit.sv` | Zmmul multiplier |
| `rtl/nn_unit.sv` | DOT4.S8 and CLIP.S8 |
| `rtl/if_stage.sv` … `wb_stage.sv` | the five stage modules |
| `rtl/riscv_core.sv` | top level: stage wiring, writes blocked during reset |
| `tb/tb_*.sv` | one testbench per block, plus `tb_core.sv`, `tb_core_dot64.sv` and `tb_core_kws.sv` (whole core) |
| `programs/smoke.s`, `smoke.hex` | RV32I smoke program (hand-encoded, annotated listing) |
| `programs/gen_dot64.py` | generates the dot64 test: `dot64.s`, `dot64.hex`, `dot64_data.hex`, `dot64_expect.svh` |
| `programs/imem_demo.hex` | a 4-word program, used by `tb_imem` and `tb_dmem` |
| `sim/run_tests.py` | compiles and runs every testbench with Icarus |
| `docs/diagrams/` | TikZ architecture diagrams (`diagrams.pdf` = all of them) |

The KWS software is in [`../kws/`](../kws/) and the instruction simulator, the golden model for the RTL, in [`../iss/`](../iss/).

## Running the tests

Requires Icarus Verilog 12+ (`iverilog`, `vvp`) on `PATH`, and Python 3. Run from this folder:

```bash
python3 sim/run_tests.py
```

```bash
python3 sim/run_tests.py -v core_dot64
```

The first runs all 13 default testbenches; `-v` prints the full simulator output. Every testbench prints `PASS: tb_<name>` or `FAIL: …`, and the script exits non-zero if any fails. It switches to the project folder itself, so it can be started from anywhere.

Trace a whole-core program cycle by cycle (pc, instruction, register or memory write), then open the waveform:

```bash
vvp -n build/tb_core_dot64.vvp +TRACE
```

```bash
gtkwave build/tb_core_dot64.vcd
```

`dot64.s`, `dot64.hex`, `dot64_data.hex` and `dot64_expect.svh` are generated and committed. After changing the generator, rebuild them:

```bash
python3 programs/gen_dot64.py
```

## The new instructions

### Zmmul (RISC-V unprivileged spec, "M" chapter)

All use opcode OP (`0110011`) and funct7 `0000001`.

| Instruction | funct3 | Result in rd |
|---|---|---|
| `mul` | 000 | low 32 bits of rs1 × rs2 |
| `mulh` | 001 | high 32 bits, signed × signed |
| `mulhsu` | 010 | high 32 bits, signed rs1 × unsigned rs2 |
| `mulhu` | 011 | high 32 bits, unsigned × unsigned |
| `div` `divu` `rem` `remu` | 100–111 | **illegal**: Zmmul has no divide |

`mul_unit` uses one 33 × 33 signed multiplier for all four. Each operand gets a 33rd bit: its sign bit if the instruction treats it as signed, 0 if unsigned.

### custom-0 instructions (opcode `0001011`, R format)

| Instruction | funct7 [31:25] | rs2 [24:20] | rs1 [19:15] | funct3 [14:12] | rd [11:7] | opcode [6:0] |
|---|---|---|---|---|---|---|
| `DOT4.S8 rd, rs1, rs2` | `0000000` | rs2 | rs1 | `001` | rd (read **and** written) | `0001011` |
| `CLIP.S8 rd, rs1` | `0000000` | `00000` | rs1 | `010` | rd | `0001011` |

Worked examples:

| Assembly | Fields (funct7 · rs2 · rs1 · funct3 · rd · opcode) | Hex |
|---|---|---|
| `dot4.s8 x10, x11, x12` | `0000000 01100 01011 001 01010 0001011` | `0x00C5950B` |
| `clip.s8 x13, x10` | `0000000 00000 01010 010 01101 0001011` | `0x0005268B` |

**DOT4.S8 rd, rs1, rs2**

```
rd ← rd + sext(rs1[7:0])  ·sext(rs2[7:0])   + sext(rs1[15:8]) ·sext(rs2[15:8])
        + sext(rs1[23:16])·sext(rs2[23:16]) + sext(rs1[31:24])·sext(rs2[31:24])
```

- All four lanes are signed 8-bit, and each product is signed 16-bit.
- The sum of four products always fits: its largest magnitude is 4 · (−128 · −128) = 65536, which needs 18 bits.
- The add into rd wraps modulo 2³², with no saturation.
- rd is read through register-file port 3 (`rs3_data`), which is addressed by the rd field. The read returns the old value, like rs1/rs2.
- If rd = x0, the accumulator reads 0 and the result is discarded. rd may equal rs1 and/or rs2.

**CLIP.S8 rd, rs1**: `rd ← max(−128, min(127, signed(rs1)))`, sign-extended to 32 bits.
- Examples: 0x7FFFFFFF → 0x7F; 0x80000000 → 0xFFFFFF80; 128 → 127; −129 → −128.
- The rs2 field must be `00000`; any other value is illegal, which keeps the field free for later use.

**Every other custom-0 combination is illegal.** That includes funct3 `000`, which is left free for a later instruction.


### How the datapath changed

- **Full funct7 decode.**
  - **Why:** `control` used to look only at `instr[30]`, so `mul` ran silently as `add`, `div` as `xor`, and so on.
  - **Now:** it decodes all of `instr[31:25]`. Every undefined OP / OP-IMM-shift / custom-0 encoding raises `illegal` and writes nothing.
- **Third register-file read port** (`rs3_data`, address = rd field), for DOT4.S8's accumulator.
- **Two units beside the ALU in `ex_stage`:** `mul_unit` and `nn_unit`. Both take `rs1_data`/`rs2_data` (and `rs3_data`) directly and decode `funct3` themselves, as `branch_unit` and `lsu` do.
- **New control output `ex_sel`** (`EX_ALU` / `EX_MUL` / `EX_NN`). It picks which unit's result becomes `ex_result`, the value written back.
  - The result is chosen *inside* EX, so every later stage still sees one result per instruction. In the pipeline, EX/MEM and MEM/WB carry one result and forwarding needs no new paths for it.
  - `alu_op` (4 bits) and `wb_sel` (2 bits) keep their widths and codes.
- **The data-memory address is `alu_y`, not `ex_result`.** Loads and stores always use the ALU, so the result mux stays off the load path. In the pipeline, EX/MEM can hold `ex_result` alone and use it as the address, since the two are equal for every load and store.
- **New control output `rs3_read`** (1 only for DOT4.S8). Like `mem_read`, the single-cycle core does not use it; the pipeline's hazard unit does.
- **Optional data-memory preload:** `dmem` / `mem_stage` / `riscv_core` take `INIT_FILE` / `DMEM_INIT_FILE` (default `""`: all zero).
- **Debug store outputs** (added with the pipelined core, for the FPGA wrapper): `dbg_mem_we` (1 for a store), `dbg_mem_addr` (its address) and `dbg_mem_wdata` (the `rs2` value stored). They only bring existing signals out of `riscv_core`, beside `dbg_pc`, `dbg_instr`, `dbg_illegal` and `dbg_system`, so the core behaves as before: after adding them, all 13 testbenches and the `kws` target pass unchanged. The pipelined core has the same outputs, taken from WB.

### Carrying this over to the pipeline

- **Reading rs3.** rs3 is read in ID, together with rs1/rs2. ID/EX gains `rs3_data`, `rs3_read` and `ex_sel`. rs3's address is just `rd_addr`, which ID/EX already carries.
- **Forwarding.** rs3 needs a third forwarding mux, like rs1/rs2. It compares ID/EX.rd with EX/MEM.rd and MEM/WB.rd and is enabled by `rs3_read` (and rd ≠ 0).
  - The KWS inner loop chains DOT4.S8 into one accumulator. EX/MEM → EX forwarding of rs3 therefore fires on every DOT4 and must not stall.
- **Load-use stall.** It must also cover rs3: stall when `rs3_read` is set and the load in EX writes that rd. Without `rs3_read`, every "load x, then write x" pair would stall for nothing.
- **Same-cycle write-back bypass.** If the pipeline's register file needs a WB → ID bypass, it must cover all three read ports.
- **Clock period.** Vivado shows that the pipelined core's longest path goes through DOT4.S8 in EX, not through the 33 × 33 multiplier, which is built from DSP blocks. See [`../pipelined/`](../pipelined/).

## What the tests cover

| Testbench | Checks |
|---|---|
| `tb_pc_reg` | reset beats `next_pc`; loads every edge |
| `tb_regfile` | shadow model on **all three read ports**; x0 and `we=0` writes ignored; same-cycle read returns the old value (also on rs3, as DOT4.S8 needs); 300 random ops |
| `tb_imem` | hex loading, byte address → word, NOP fill, 4 KiB wrap |
| `tb_dmem` | byte write mask, little-endian placement, random masked writes, `INIT_FILE` preload |
| `tb_alu` | hand-worked edge cases (sign, shifts ≥ 32, overflow) + random data for all 11 ops |
| `tb_imm_gen` | encoded instructions with known immediates, including the range limits of every format |
| `tb_control` | see below |
| `tb_branch_unit` | all six conditions, signed/unsigned edges, random operands |
| `tb_lsu` | store lanes and masks; load lane select and sign/zero extension |
| `tb_mul_unit` | see below |
| `tb_nn_unit` | see below |
| `tb_core` | `smoke.hex` (127 words) runs to `ebreak` at pc 0x1F4 in 144 cycles; all 32 registers and 27 memory words are checked |
| `tb_core_dot64` | the dot64 program (below): every register, x0's storage, 20 result words, and the cycle count of both dot products |
| `tb_core_kws` | slow target, not in the default run: C programs on the whole core, with every layer compared with TFLite at its marker (see [`../kws/`](../kws/)) |

**`tb_control`:**
- Every Table 9.2 row, with the original expectations unchanged.
- Zmmul rows, with div/divu/rem/remu illegal.
- funct7 near-misses, all illegal: `sll` with `0100000`, `add` with `0000010`, odd shift funct7s, and so on. Plus OP-IMM rows where funct7 is just immediate bits, which stay legal.
- DOT4.S8, and CLIP.S8 with rs2 = 0 (legal) and rs2 = 1…31 (illegal).
- A sweep of 194,560 inputs: every opcode × funct3 × all 128 funct7, and all 32 rs2 fields for OP and custom-0. `illegal` is compared against an independent table of legal encodings.
- Sweep invariants:
  - an illegal word changes no state;
  - `EX_MUL` / `EX_NN` appear exactly for the new instructions, which always write rd and never touch memory;
  - `rs3_read` is set only for DOT4.S8;
  - `sub` and `sra` appear only where they belong.

**`tb_mul_unit`:**
- 20 hand-worked cases, e.g. `mulh(−2³¹, −2³¹)` = `0x40000000`, `mulhsu(−1, 0xFFFFFFFF)` = `0xFFFFFFFF`, `mulhu(0xFFFFFFFF, 0xFFFFFFFF)` = `0xFFFFFFFE`.
- All four ops on {0, 1, −1, 0x7FFFFFFF, 0x80000000} in both operands.
- 600 random cases per op, checked against a 64-bit model built differently from the RTL.

**`tb_nn_unit`:**
- **DOT4.S8, 23 hand-worked cases:**
  - all lanes −128 × −128 (= 65536), 127 × −128, mixed signs;
  - one lane at a time, which catches swapped lanes;
  - an accumulate across 0x7FFFFFFF → 0x80000000 and back;
  - accumulator 0 (rd = x0), and accumulator = rs1 or = rs2.
- **DOT4.S8, random:** 800 cases checked against a lane-by-lane `byte` model, 300 of them with extreme bytes and an accumulator near the wrap.
- **CLIP.S8:** 127, 128, −128, −129, 0, INT_MAX, INT_MIN, −1, 255, ±256 and the DOT4 extremes. Then 700 random values, 400 of them within ±300, with random rs2/acc inputs that must be ignored.

### The dot64 whole-core program

`programs/gen_dot64.py` writes the program and its expected results.
- **Encoder:** only the instructions this test uses. It checks itself against known words (from `smoke.s` and GNU as) before writing anything.
- **Expected values:** every instruction is executed on a small Python model as it is emitted, which yields every expected register and memory word. The dot product and the requantisation are also checked against plain formulas.

The program, with `dot64_data.hex` preloaded into data memory (64 int8 weights at 0x400, 64 int8 inputs at 0x440):

| Section | What it does |
|---|---|
| A | one KWS-style pointwise output: `bias + Σ w[i]·x[i]` over 64 elements, as 16 × (`lw`, `lw`, `dot4.s8`) |
| B | the same dot product as 64 × (`lb`, `lb`, `mul`, `add`); both must give the known answer (−100776) |
| C | requantisation: `mulh` (Q31 multiplier), `srai`, `addi` (zero point), `clip.s8`; once in range, once saturating up, once saturating down |
| D | DOT4.S8 with rd = x0, rd == rs1, rd == rs2, rd == rs1 == rs2, and the wrap-around both ways |
| E | CLIP.S8 on 127, 128, −128, −129, 0, 0x7FFFFFFF, 0x80000000 |
| F | `mul`, `mulh`, `mulhsu`, `mulhu` on INT_MIN, −1, INT_MAX |

Both kernels are fully unrolled, because every KWS pointwise reduction is exactly 64 long. Cycle counts (one instruction per cycle):

| 64-element INT8 dot product | Cycles |
|---|---|
| 16 × (`lw`, `lw`, `dot4.s8`) | **48** |
| 64 × (`lb`, `lb`, `mul`, `add`) | **256** |
| ratio | **5.33×** |

The whole program runs to `ebreak` in 390 cycles.

### The tests have been shown to fail

Each bug below was planted, the whole suite was run, and the bug was removed.

| Planted bug | Testbenches that failed |
|---|---|
| OP_IMM uses `funct7_5` for `sub` (`addi` with bit 30 set becomes a subtract) | `tb_control`, `tb_core` (x2 = `00000003` instead of `fffffffd`), `tb_core_dot64` (`addi x2, x0, 0x440` has bit 30 set) |
| `lbu` sign-extends | `tb_lsu`, `tb_core` |
| div/rem decode as `mul` (funct3[2] ignored) | `tb_control` |
| register-file port 3 reads with rs2's address | `tb_regfile`, `tb_core_dot64` |
| `mulhsu` treats rs1 as unsigned | `tb_mul_unit`, `tb_core_dot64` |
| DOT4.S8 lanes treated as unsigned | `tb_nn_unit`, `tb_core_dot64` |
| CLIP.S8 upper bound 128 instead of 127 | `tb_nn_unit`, `tb_core_dot64` |

**Not covered yet:**
- misaligned accesses (unsupported by design)
- `ecall`/`fence` semantics beyond "no state change"
- long random programs (the pipelined core's suite runs 300 of them against `rv32iss`)

The official RISC-V architectural tests pass on this core (38/38 RV32I, 4/4 multiply); see [`../riscof/`](../riscof/).

## On the FPGA

Vivado 2026.1 built this core for the PYNQ-Z2 (xc7z020clg400-1), inside the wrapper in [`../fpga/`](../fpga/) with KWS build (c) ([what the builds are](../kws/README.md#the-three-builds-a-b-and-c)) preloaded. The run was constrained to 100 MHz. The worst setup slack is −14.700 ns, so the maximum clock is 1 / (10 ns + 14.7 ns) = 40.49 MHz. That is an estimate from that run, not a measured clock, and so are the times below (cycles × 24.7 ns).

| Build | Cycles | Time per inference | Pipelined core, 59.27 MHz |
|---|---:|---:|---:|
| (a) | 333,300,720 | 8.23 s | 7.72 s |
| (b) | 11,724,916 | 289.6 ms | 210.9 ms |
| (c) | 3,368,932 | 83.2 ms | 60.0 ms |

- **Slowest path:** from the PC to the register file's write data, the whole instruction in one cycle: 21 logic levels and 24.1 ns, of which 19.4 ns is routing.
- **LUTs:** 11,061, of which 8,256 are distributed RAM: the 64 KiB data memory (8,192 LUTs at 64 bits each) and the register file (64).
  - The instruction memory is read-only, so Vivado turns it into logic for the program loaded.
  - Block RAM cannot hold either memory, because it reads synchronously and this core reads its memories combinationally.
- **Other resources:** 42 flip-flops, no block RAM, and 4 DSP slices (the 33 × 33 multiplier). DOT4.S8's products are built from LUTs. `nn_unit.sv`'s `NN_USE_DSP` macro asks for them in DSP blocks instead; it is synthesis only, and off unless `fpga/build.tcl` is run with `dsp`. With it this core is slightly slower (39.14 MHz), so it stays off.

The pipelined core's README compares the two cores in full.

## Diagrams

`docs/diagrams/diagrams.pdf` (7 pages) holds all figures, in this order:
1. the full datapath, including `mul_unit`, `nn_unit`, the `ex_sel` result mux and register-file port 3
2. the control table (with `ex_sel` and `rs3_read`), the illegal-encoding rules, and the ALU / immediate / write-back / execute-unit codes and custom-0 encodings
3. one figure per stage module, each with its port table

Every label is the exact SystemVerilog name; a script check confirms that all 63 stage-module ports appear in their figure. To rebuild, run from `docs/diagrams/` (MiKTeX or TeX Live with TikZ and `standalone`):

```bash
pdflatex diagrams.tex
```

Each figure also compiles on its own, e.g. `pdflatex fig_ex_stage.tex`. The files are `fig_datapath`, `fig_if_stage`, `fig_id_stage`, `fig_ex_stage`, `fig_mem_stage`, `fig_wb_stage`; the shared styles are in `rv32i_style.tex`. For PNGs (e.g. for a Word report): `pdftoppm -png -r 300 fig_datapath.pdf fig_datapath`.

## Design choices

- **Stage modules** instead of one flat `riscv_core.sv`, so pipelining only adds registers.
- **Next-PC split:**
  - `ex_stage` decides `pc_redirect = jalr | jump | (branch & take_branch)` and computes `redirect_pc`.
  - `if_stage` only picks `redirect_pc` or `pc_plus4`.
  - `pc_redirect` then becomes the pipeline's flush signal unchanged.
- **Writes blocked during reset** (`rf_we = reg_write & ~rst`, same for data memory). Without this, the instruction at `RESET_ADDR` would write once per reset cycle.
- **Full funct7 decode:** `control` checks all of `instr[31:25]` (and the rs2 field for CLIP.S8), not only `instr[30]`.
- **Extension results are picked in EX** (`ex_sel`), not by widening `wb_sel`. The memory address comes straight from `alu_y`.
- **Bit-slicing in `assign`s:** `imm_gen`, `lsu`, `control` and `nn_unit` slice bits in `assign`s, not inside `always_comb`, which avoids Icarus's "constant selects" notes.
- **`system` output:** `control` has an extra `system` output (ecall/ebreak); the testbenches stop on it.

## Known limitations

- **No division.** The core implements Zmmul only, so `div`, `divu`, `rem` and `remu` are illegal. Software must divide with a library routine (GCC's `-march=rv32i_zmmul` does this), or by a reciprocal multiply, as GCC does for KWS's divide by 125.
- **Memory size.** Instruction and data memories default to 4 KiB each, with combinational (LUTRAM) reads. `tb_core_kws` sets 32 KiB and 64 KiB through the parameters. The pipelined core uses synchronous-read block RAM instead.
- **Remaining decode holes.** These encodings are *not* flagged illegal and execute as shown:
  - loads with funct3 `011`/`110`/`111` run as `lw`;
  - stores with funct3 ≥ `011` run as `sw`;
  - branches with funct3 `010`/`011` are never taken;
  - `jalr` ignores funct3;
  - `fence` accepts any funct3 (e.g. `fence.i`);
  - **every** SYSTEM word (e.g. a CSR instruction) sets `system`, so the testbench stops as if it were `ebreak`.

  Only OP, the OP-IMM shifts and custom-0 are fully decoded.
- **Traps and CSRs.** There are none: illegal instructions are only flagged (`dbg_illegal`), and `fence`/`ecall` are NOPs.
- **Misaligned loads and stores** silently use the containing word.
- **Requantisation in dot64** (`mulh` + `srai`) rounds down; it is not bit-exact with TFLite. `kws.c` is the exact version.
- **Clock period.** The core runs at most 40.49 MHz (see [On the FPGA](#on-the-fpga)), with the 33 × 33 multiplier and DOT4.S8's multipliers and adder tree in its one cycle. No plain-RV32I build was run, so the KWS speed-ups in [`../kws/`](../kws/) are in cycles. A comparison against plain RV32I should report time as well.
