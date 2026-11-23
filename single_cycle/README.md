# Single-cycle RV32I core + Zmmul + custom INT8 instructions

A single-cycle RV32I core, written from scratch in SystemVerilog and extended step by step. The 5-stage pipelined version of this core is in [`../pipelined/`](../pipelined/).

The core executes one instruction per clock cycle. Beyond RV32I it implements:
- **Zmmul**: the multiply half of the RISC-V M extension (`mul`, `mulh`, `mulhsu`, `mulhu`; no divide).
- **DOT4.S8** and **CLIP.S8**: two custom-0 instructions for quantised (INT8) neural-network inference. They target the MLPerf Tiny keyword-spotting model, which the core now runs bit-exact with TFLite; see [Running the KWS model](#running-the-kws-model).

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
| `sim/iss/rv32iss.c` | instruction simulator, the golden model for the RTL |
| `kws/sw/` | bare-metal C: `crt0.S`, `link.ld`, `nn_insn.h`, `hello.c` (bring-up), `kws.c` (the model) |
| `kws/ref/` | Python reference: the model as arrays, a NumPy re-implementation, the comparison with TFLite, the table generator |
| `kws/gen/` | generated and committed: C tables, program images, synthetic inputs and their expected outputs |
| `kws/model/` | the `.tflite` file (the 12 real recordings go in `kws/inputs/real/`, not committed; see [Inputs](#inputs)) |
| `kws/build.py`, `kws/run_all.py`, `kws/results.md` | builds the C programs; runs the sweeps; the generated results |
| `docs/diagrams/` | TikZ architecture diagrams (`diagrams.pdf` = all of them) |

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
| `tb_core_kws` | slow target, not in the default run: C programs on the whole core, with every layer compared with TFLite at its marker (see [Running the KWS model](#running-the-kws-model)) |

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

## Running the KWS model

The core runs the MLPerf Tiny keyword-spotting model, a DS-CNN (49 × 10 INT8 MFCC input, 12 classes, about 2.66 M MACs), as bare-metal C with no compiler changes.

- **Bit-exact.** Every layer's output equals TFLite's reference int8 kernels byte for byte, on 19 inputs, in the RTL and in the instruction simulator.
- **Real words.** All 12 real recordings tested give the right word. On the 1000 test files the core's 12 scores and label equal TFLite's on every file, at 90.1% accuracy.
- **Speed.** DOT4.S8 and CLIP.S8 make the whole model 3.48× faster than `mul` alone.

### The three builds: (a), (b) and (c)

The same C program, `kws/sw/kws.c`, is compiled three times. Each build lets the compiler use more of the core's instructions, so comparing them shows what each hardware addition is worth.

| Build | ISA it targets | Compiler flags | How one multiply-accumulate (MAC) is done |
|---|---|---|---|
| **(a)** | RV32I only: no multiply instruction | `-march=rv32i` | every `*` calls `__mulsi3`, libgcc's software multiply (a shift-and-add loop of tens of instructions) |
| **(b)** | RV32I + Zmmul (hardware multiply) | `-march=rv32i_zmmul` | `lb`, `lb`, `mul`, `add`: one MAC per `mul` |
| **(c)** | RV32I + Zmmul + DOT4.S8 and CLIP.S8 | `-march=rv32i_zmmul -DHAVE_NN` | `lw`, `lw`, `dot4.s8`: four MACs in one instruction; `clip.s8` saturates each output to int8 |

(a) → (b) measures the hardware multiplier; (b) → (c) measures the two custom instructions. All three give the same output bytes. Build (c) is the one used on the FPGA. `HAVE_NN` switches the inner loops to `dot4_s8()` and `clip_s8()` from `kws/sw/nn_insn.h`, which emit the custom instructions as inline assembly, so no compiler change is needed.

**Softmax is not run on the core.** The core stops at the 12 FC outputs and takes their arg-max; those two things are what is compared with TFLite. Softmax did not change the arg-max on any of the 1,007 inputs tested.

### Results

Builds (a), (b) and (c) are described [above](#the-three-builds-a-b-and-c). The core runs one instruction per clock, so cycles = instructions. Figures are means over the 12 real recordings. `kws/results.md` is the generated copy.

**Build (a) is an instruction-simulator count, cross-checked with the RTL on the first conv layer** (a full Icarus run would take about 8 hours). Builds (b) and (c) are also simulator counts, and the RTL matched them at every marker: (c) on all 19 inputs, (b) on one recording.

| # | Layer | MACs | (a) cycles | (b) cycles | (c) cycles | (b)/(c) | (a)/(c) | (a) instr/MAC | (b) instr/MAC | (c) instr/MAC |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
|  | setup (fill padding) | 0 | 38.4 k | 38.4 k | 38.4 k | 1.00× | 1.0× | - | - | - |
| 1 | conv 10×4 | 320,000 | 19.48 M | 1.34 M | 329.4 k | 4.06× | 59.1× | 60.9 | 4.2 | 1.0 |
| 2 | depthwise 1 | 72,000 | 13.59 M | 395.5 k | 352.5 k | 1.12× | 38.5× | 188.7 | 5.5 | 4.9 |
| 3 | pointwise 1 | 512,000 | 65.31 M | 2.18 M | 388.0 k | 5.62× | 168.3× | 127.6 | 4.3 | 0.8 |
| 4 | depthwise 2 | 72,000 | 13.11 M | 396.7 k | 352.5 k | 1.13× | 37.2× | 182.1 | 5.5 | 4.9 |
| 5 | pointwise 2 | 512,000 | 64.35 M | 2.18 M | 388.0 k | 5.62× | 165.8× | 125.7 | 4.3 | 0.8 |
| 6 | depthwise 3 | 72,000 | 12.38 M | 397.1 k | 352.5 k | 1.13× | 35.1× | 171.9 | 5.5 | 4.9 |
| 7 | pointwise 3 | 512,000 | 65.55 M | 2.18 M | 388.0 k | 5.62× | 169.0× | 128.0 | 4.3 | 0.8 |
| 8 | depthwise 4 | 72,000 | 13.58 M | 396.7 k | 352.5 k | 1.13× | 38.5× | 188.6 | 5.5 | 4.9 |
| 9 | pointwise 4 | 512,000 | 65.70 M | 2.18 M | 388.0 k | 5.62× | 169.3× | 128.3 | 4.3 | 0.8 |
| 10 | average pool | 0 | 43.1 k | 37.7 k | 37.7 k | 1.00× | 1.1× | - | - | - |
| 12 | fully connected | 768 | 156.6 k | 3.2 k | 1.3 k | 2.44× | 117.9× | 204.0 | 4.2 | 1.7 |
| 13 | arg-max (no softmax) | 0 | 0.1 k | 0.1 k | 0.1 k | 1.00× | 1.0× | - | - | - |
| | **Total** | **2,656,768** | **333.30 M** | **11.72 M** | **3.37 M** | **3.48×** | **98.9×** | **125.5** | **4.4** | **1.3** |

| Build | Whole program to `ebreak`, mean | Range over the 12 recordings |
|---|---:|---|
| (a) | 333,300,720 | 332,707,205 to 334,407,592 |
| (b) | 11,724,916 | 11,723,604 to 11,726,091 |
| (c) | 3,368,932 | 3,368,930 to 3,368,934 |

Reading the table:

- **Pointwise is where DOT4.S8 pays:** 5.62× on 77% of the MACs.
- **Depthwise barely changes,** because a word holds four different channels, so DOT4.S8 does not apply. It is now 42% of build (c): 1.41 M of 3.37 M cycles.
- **Build (a) depends on operand order.** `__mulsi3` loops over the bits of its second argument. Activations are nearly all negative, so they sign-extend to 32 bits and take every pass; weights are about half positive. The first conv and depthwise compile with the weight second, and the pointwise loop is written the same way. With the activation second instead, build (a) takes 486 M cycles and produces the same bytes, so the 144× it would show has nothing to do with DOT4.S8. FC is left as GCC compiled it (157 k cycles, 0.05% of build (a)).

| Recording | Correct word | Core: (a), (b), (c) | TFLite |
|---|---|---|---|
| 000000 | Stop | Stop | Stop |
| 000001 | Left | Left | Left |
| 000002 | Right | Right | Right |
| 000003 | Up | Up | Up |
| 000004 | On | On | On |
| 000005 | Down | Down | Down |
| 000007 | Yes | Yes | Yes |
| 000008 | Off | Off | Off |
| 000009 | No | No | No |
| 000010 | Unknown | Unknown | Unknown |
| 000012 | Go | Go | Go |
| 000014 | Silence | Silence | Silence |

**All 1000 test files**, build (c) on the instruction simulator: accuracy 90.1%, TFLite reference kernels 90.1%, and no file where the 12 scores or the label differ.

### Memory map

Instruction and data memory are separate, and each uses the low bits of the address with no decoder. `tb_core_kws` makes them 32 KiB and 64 KiB through the core's own parameters; no RTL changes. The fixed addresses are in `kws/sw/link.ld`.

| Region | Address | Size | Contents |
|---|---|---|---|
| Code | `0x0000_0000` | 32 KiB (instruction memory) | `crt0`, the program, libgcc |
| Read-only tables | `0x1000_0000` | 36 KiB | weights, folded biases, requantisation tables (preloaded) |
| `buf_a` | `0x1000_9000` | 12,096 B | conv and pointwise output: 27 × 7 × 64, the 25 × 5 × 64 result inside a −128 border |
| `buf_b` | `0x1000_BF40` | 8,000 B | depthwise output: 25 × 5 × 64 |
| `input_pad` | `0x1000_DE80` | 696 B | the input inside its padding of 83: 58 × 12 |
| `pool_out` | `0x1000_E140` | 64 B | average-pool output |
| `.data`, `.bss` | `0x1000_E200` | 3.5 KiB | unused by KWS |
| `kws_input` | `0x1000_F000` | 490 B | input features, 49 × 10 INT8 |
| `kws_output` | `0x1000_F200` | 12 B | the 12 FC scores |
| `kws_label` | `0x1000_F20C` | 4 B | index of the largest score |
| Stack | `0x1000_FFE0` down to `0x1000_F400` | 3,040 B | not enforced; `rv32iss` reports the lowest `sp` |
| Marker | `0xFFFF_FFF0` | | a store here reaches data memory at offset `0xFFF0`, above the stack, so it never overwrites anything |

`kws_input`, `kws_output` and `kws_label` sit together in their own 1 KiB region, so the ARM side of the PYNQ-Z2 can reach them through a second block-RAM port later.

| Memory used | (a) | (b) | (c) |
|---|---:|---:|---:|
| Code | 7,000 B | 5,412 B | 2,408 B |
| Read-only tables | 31,292 B | 31,292 B | 31,292 B |
| Activation buffers | 20,856 B | 20,856 B | 20,856 B |
| Input and output | 506 B | 506 B | 506 B |
| Deepest stack | 384 B | 304 B | 128 B |

The read-only tables are 24,368 B of weights and biases plus 6,924 B of requantisation tables.

### Building and running

The committed images in `kws/gen` need only Icarus, Python and a host `gcc`, plus the real recordings for the runs that use them (see [Inputs](#inputs)). Run from this folder.

```bash
python3 sim/run_tests.py kws
```

```bash
python3 kws/run_all.py iss
```

```bash
python3 kws/run_all.py rtl
```

- `sim/run_tests.py kws` is the regression test, in the RTL, and takes about 10 minutes. It is a separate target, not part of the default 13. It runs `hello` on all three builds, then the whole model, build (c), on two inputs: `tst_000012_Go_1` (the recording where FC's rounding shows) and `syn_random` (which drives the upper clamp). The programs, layer table and expected files are used unchanged by the pipelined core in [`../pipelined/`](../pipelined/), whose `tb_core_kws` takes the marker store from EX and the trace from WB.
- `kws/run_all.py iss` runs all 19 inputs on all three builds on the simulator, checks every layer, and rewrites `kws/results.md`. It takes about 20 seconds.
- `kws/run_all.py rtl` repeats the checks in the RTL, comparing bytes and counts: (c) on all 19 inputs, (b) on one recording, (a) up to the end of the first conv. It takes up to an hour.

Changing the C code needs a RISC-V GCC with rv32i/ilp32 libraries: `riscv-none-elf-gcc` ([xPack](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack)) or `riscv64-unknown-elf-gcc`, found on `PATH` (or set `RISCV_PREFIX`). The committed images were built with xPack GCC 15.2; another version gives equally correct images with slightly different cycle counts (GCC 14.2: build (c) takes 3,368,957 instructions instead of 3,368,932). `kws/build.py` passes `-Werror`, because a generated table that only warned once produced wrong results.

```bash
python3 kws/build.py kws
```

Changing the reference or the tables needs TFLite in a virtual environment (`numpy` and `ai-edge-litert`):

```bash
.venv/bin/python kws/ref/check_ref.py --all
```

```bash
.venv/bin/python kws/ref/gen_kws.py
```

```bash
.venv/bin/python kws/run_all.py accuracy
```

`check_ref.py` compares the NumPy model with TFLite on every layer. `--all` and `accuracy` need the 1000 files, fetched by `kws/ref/fetch_eembc.py`.

### How each layer runs

| Layer (share of MACs) | Build (c) instructions | Instructions per output, (c) | (b) |
|---|---|---:|---:|
| pointwise (77.1%) | 16 × (`lw`, `dot4.s8`), with one filter's 16 words held in registers | 48.5 | 273 |
| first conv (12.0%) | 10 × (`lw`, `dot4.s8`) | 41 | 167 |
| depthwise (10.8%) | 9 × (`lb`, `mul`, `add`) | 44 | 50 |
| fully connected (0.03%) | 16 × (`lw`, `lw`, `dot4.s8`) | 111 | 271 |
| every output | `mul`, `mulhsu`, 6 more for rounding, `addi`, `clip.s8`, `sb` | included | |

- **One filter at a time.** Pointwise and depthwise keep one filter in registers and sweep the pixels, so the weights are loaded once per filter, not once per pixel. GCC's output keeps all 16 weight words in registers with no spills, so no loop is hand-written.
- **The first conv needs no second copy of the input.** Every 4-tap row starts on an even byte of `input_pad`. The 10-word window is loaded once per pixel, with `lw` at even x and pairs of `lhu` at odd x, and stays in registers for all 64 filters.
- **Loads one word ahead.** In the DOT4.S8 loops (pointwise, first conv) each word is loaded one `dot4.s8` before it is used, into two variables in turn, with an empty compiler barrier (`LOAD_AHEAD` in `kws.c`) so GCC keeps that order. The pipelined core needs it: a load's value comes one cycle too late for the next instruction, and this removes about 550 k stall cycles there. It costs this core 0.2% (6,378 instructions); the figures here include it.
- **Padding is real memory.** `input_pad` is filled with 83 and `buf_a`'s border with −128, once, before the first layer. Depthwise reads `buf_a` and writes `buf_b`; pointwise does the reverse.
- **Zero points are folded.** `bias' = bias − zp · Σw` is computed offline, so the loops use raw bytes, and padded values must equal the zero point for `x − zp` to be 0 there.

### Matching TFLite exactly

- **The reference is TFLite with its reference kernels** (`OpResolverType.BUILTIN_REF`). Its other kernels give different bytes: on 1,007 inputs the optimised kernels differ in 10.6% of output bytes and the default ones (XNNPACK) in 14.3%. Comparing against those would fail for reasons that have nothing to do with the core. The NumPy model in `kws/ref/` equals the reference kernels on all 1,007 inputs and all 11 layers.
- **Convolutions use double rounding,** TFLite's `MultiplyByQuantizedMultiplier`. `requant()` in `kws.c` is a shorter form of it that holds for every multiplier here (2³⁰ ≤ M < 2³¹) and every shift (right, by at least 1); its comment gives the derivation.
- **FC uses one rounding.** It follows desktop TFLite's reference kernel: a float scale with one rounding, reproduced exactly in integers as `(acc · M + 2³⁷) >> 38`. `check_ref.py` compares that with the float result on every accumulator any input can reach (−680,638 to 348,756) and finds no difference.
  - TFLite Micro's FC instead receives only an integer `output_multiplier` / `output_shift` and calls `reference_integer_ops::FullyConnected`. That points to the same `MultiplyByQuantizedMultiplier` rounding as the conv layers, but it was not confirmed from the source.
  - On a TFLite Micro build, about 49 of 12,000 FC scores would differ by 1, and the predicted word would not change.
- **Average pool divides by 125,** rounding to the nearest and truncating as TFLite does. The published `.tflite` has a 25 × 5 pool; the current `keras_model.py` in `mlcommons/tiny` says (24, 5), but the binary is what runs. Builds (b) and (c) need no divide routine, because GCC turns `/ 125` into an exact reciprocal multiply (`mulh` by `0x10624DD3`). Only build (a) calls `__divsi3`.
- **CLIP.S8 alone is exact.** Every CONV_2D and DEPTHWISE_CONV_2D has a fused ReLU and output zero point −128, so clamping to [−128, 127] *is* ReLU + clamp. FC has no ReLU (output zero point 14); clamping is still correct there.
- **Weights** have zero point 0 and per-channel scales (64 per layer), so signed × signed on the raw bytes is exact, with per-channel requantisation tables.
- **Model size.** The weights and biases are **24,376 bytes** in the model (the core needs 24,368 B; the other 8 are a reshape shape).

### Inputs

- **7 synthetic:** all −128, all 127, all 83 (the zero point), all 0, random, a ramp, and an impulse beside the padding.
- **12 real recordings,** one per class, in `kws/inputs/real/`. These are the MLPerf Tiny test features published with EEMBC's `energyrunner` (`datasets/kws01`), 490 INT8 values each, so feature extraction is not run here.

The EEMBC repository has no licence and says "Copyright of EEMBC", so the recordings, and the files generated from them, are **not in this repository**. The `kws` regression target, `kws/run_all.py` and the FPGA build need them; the synthetic inputs and every other test do not. To recreate them:

1. `python3 kws/ref/fetch_eembc.py` downloads all 1000 files into `kws/inputs/eembc_all/`;
2. copy the 12 named in the table above into `kws/inputs/real/`;
3. `kws/ref/gen_kws.py` writes `kws/gen/input_tst_*.hex` and `expect_tst_*.hex`;
4. `python3 ../fpga/make_mem.py` writes the FPGA's data image.

Replacing them with features generated from Speech Commands v2 by the MLPerf pipeline would allow committing them; a WAV-to-word demo at the FPGA step would need that anyway.

### The KWS test has been shown to fail

Each bug was planted in a scratch copy of the project, and `python3 sim/run_tests.py kws` was run there. All ten failed the test, each at the layer where the bug lives.

| Planted bug | Caught at | By |
|---|---|---|
| DOT4.S8 lanes treated as unsigned | layer 1 | both KWS runs |
| requantisation without rounding | layer 1 | both KWS runs |
| input padded with 0, not 83 | layer 1 | both KWS runs |
| CLIP.S8 upper bound 128, not 127 | layer 1 | `syn_random`, and `hello` (c) |
| depthwise padded with 0, not −128 | layer 2 | both KWS runs |
| pointwise bias not folded | layer 3 | both KWS runs |
| average pool truncates | layer 10 | both KWS runs |
| FC uses double rounding | layer 12 | `tst_000012_Go_1` only |
| arg-max picks the smallest score | marker 13 | both KWS runs |
| program returns after layer 5 | "only 5 of 12 layer rows were reached" | both KWS runs |

The last two would have passed before the label became a checked row and before a run had to reach every row of the layer table. The CLIP and FC rows are why the test uses those two inputs.

### The instruction simulator

`sim/iss/rv32iss.c` is a single C file with no dependencies. It runs at about 200 M instructions per second, against about 12 k cycles per second for Icarus, which is what makes build (a) and the 1000-file run possible. It stays as the golden model for the pipelined core.

```bash
gcc -O2 -std=gnu11 -o build/rv32iss sim/iss/rv32iss.c
```

```bash
./build/rv32iss --imem kws/gen/kws_c.imem.hex --dmem kws/gen/kws_c.dmem.hex --load kws/gen/input_tst_000007_Yes_9.hex@0x1000F000 --layers kws/gen/layers.hex --expect kws/gen/expect_tst_000007_Yes_9.hex
```

- **It matches the RTL,** including memory aliasing and the decode holes listed under Known limitations. The two share the layer table and expected-output files.
- **Cross-check.** `--trace FILE` writes one line per register write (pc, rd, value), and `tb_core_kws` writes the same format with `+TRACE=FILE`. Build (c) on one recording gives identical traces over 3,165,880 writes, on this core and on the pipelined one; `hello`, `smoke` and `dot64` match too.
- **On the pipelined core,** register writes keep program order, so its trace must still equal this one. Only the cycle counts will differ.
- **`--pipeline`** also counts the cycles of the pipelined core in `../pipelined/`: each instruction is one cycle, plus one for a load-use stall and two for each taken branch or jump. It equals that core's RTL exactly; see its README.
- **Other options:** `--load-bin F@ADDR`, `--dump ADDR LEN`, `--max N`, `--trace-max N`, `--quiet`, `--imem-words N`, `--dmem-words N`. It also prints the lowest `sp` reached.

## On the FPGA

Vivado 2026.1 built this core for the PYNQ-Z2 (xc7z020clg400-1), inside the wrapper in [`../fpga/`](../fpga/) with KWS build (c) preloaded. The run was constrained to 100 MHz. The worst setup slack is −14.700 ns, so the maximum clock is 1 / (10 ns + 14.7 ns) = 40.49 MHz. That is an estimate from that run, not a measured clock, and so are the times below (cycles × 24.7 ns).

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
- **KWS runs the model, not the whole pipeline.** The input is precomputed MFCC features, and softmax is not run. Feature extraction stays on the PC.
- **KWS cross-checks are partial for the slow builds.** The RTL ran build (b) on one recording and build (a) only to the end of the first conv. Their other figures are instruction-simulator counts.
- **Depthwise is not accelerated.** It is 42% of build (c), and DOT4.S8 does not fit the interleaved layout.
- **The stack limit is not enforced.** `0x1000_F400` is only a documented bound; the deepest use is 384 B.
- **Clock period.** The core runs at most 40.49 MHz (see [On the FPGA](#on-the-fpga)), with the 33 × 33 multiplier and DOT4.S8's multipliers and adder tree in its one cycle. No plain-RV32I build was run, so the KWS speed-ups above are in cycles. A comparison against plain RV32I should report time as well.
