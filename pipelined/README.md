# Pipelined RV32I core + Zmmul + custom INT8 instructions

The 5-stage pipelined version of the core in [`../single_cycle/`](../single_cycle/): the same instructions (RV32I, Zmmul, DOT4.S8, CLIP.S8), the same encodings, the same decode holes, the same parameters and ports. It runs the same programs with the same results: every program writes the same sequence of registers as `rv32iss`, and the KWS model is bit-exact at every layer.

- **Stages:** IF, ID, EX, MEM, WB. The single-cycle core's stage modules are reused, with the IF/ID, ID/EX, EX/MEM and MEM/WB registers on the wires between them.
- **Branches and jumps** are decided in EX, predicting not taken; a taken one flushes the two instructions behind it (2 cycles).
- **Forwarding** EX/MEM → EX and MEM/WB → EX for rs1, rs2 and rs3 (DOT4.S8's accumulator): a chain of DOT4.S8 into one accumulator never stalls.
- **One load-use stall cycle** when an instruction needs the value a load just ahead is fetching.
- **Block-RAM memories:** both memories read synchronously, as FPGA block RAM does, with no extra fetch cycle.

## Layout

| Path | Contents |
|---|---|
| `rtl/` | the modules that are new or changed for the pipeline (table below); the rest come from `../single_cycle/rtl/` |
| `tb/` | testbenches for the new and changed modules, and the whole-core ones |
| `programs/gen_random.py`, `programs/random/` | random-program generator; 8 programs with rv32iss's expected trace and final data window |
| `programs/gen_hazards.py`, `programs/hazards/` | directed hazard tests: 27 cases, 4 programs about stopping |
| `sim/run_tests.py` | compiles and runs every testbench with Icarus |
| `results.md` | KWS cycles per layer for builds (a), (b), (c), generated |
| `docs/diagrams/` | TikZ diagrams (`diagrams.pdf` = all of them) |

The KWS software, its images and expected outputs, and `rv32iss` stay in `../single_cycle/` and are used from there.

## Running the tests

Requires Icarus Verilog 12+ and Python 3. Run from this folder:

```bash
python3 sim/run_tests.py
```

```bash
python3 sim/run_tests.py kws
```

```bash
python3 sim/run_tests.py random_slow
```

- **The fast suite** (18 testbenches, a few seconds) runs the unit testbenches of the reused blocks from `../single_cycle/tb/`, the adapted memory testbenches, the new units' testbenches, `tb_core` (smoke), `tb_core_dot64`, the hazard programs and the 8 committed random programs.
- **`kws`** (slow, about 20 minutes) runs `hello` on all three builds, then the whole model, build (c), on `tst_000012_Go_1` and `syn_random`, checking every layer.
- **`random_slow`** generates 300 new random programs (half padded, half hazard-dense), runs each on `rv32iss` and on the RTL, and compares the register traces and final data windows. It needs a host `gcc` to build `rv32iss`.

`python3 sim/run_tests.py -v core` prints the full simulator output.

## Where each RTL file comes from

| File | From | Why |
|---|---|---|
| `riscv_pkg.sv` | unchanged, `single_cycle/rtl` | |
| `pc_reg.sv` | unchanged, `single_cycle/rtl` | holding the PC needs no enable: `if_stage` feeds it its own value |
| `regfile.sv` | unchanged, `single_cycle/rtl` | the write-back bypass sits outside it (`rf_bypass.sv`) |
| `imm_gen.sv`, `alu.sv`, `control.sv`, `branch_unit.sv`, `mul_unit.sv` | unchanged, `single_cycle/rtl` | |
| `nn_unit.sv` | unchanged, `single_cycle/rtl` | shared by both cores; its `NN_USE_DSP` macro (synthesis only, off unless `build.tcl ... dsp`) asks for the products in DSP blocks |
| `lsu.sv` | unchanged, `single_cycle/rtl` | `mem_stage` uses it twice: store side in EX, load side in MEM |
| `id_stage.sv`, `ex_stage.sv`, `wb_stage.sv` | unchanged, `single_cycle/rtl` | stage modules reused as they are |
| `imem.sv` | changed copy | synchronous read (block RAM); the word comes out one edge after its address |
| `dmem.sv` | changed copy | synchronous read, read-first, byte write enables; written so a second port can be added |
| `if_stage.sv` | changed copy | addresses `imem` with `next_pc`, so the word arrives with its pc; `hold` repeats a fetch |
| `mem_stage.sv` | changed copy | the access spans EX/MEM: issued at the end of EX, completed in MEM |
| `riscv_core.sv` | changed copy | the pipeline: registers, forwarding muxes, hazard units, debug outputs from WB |
| `pipeline_pkg.sv` | new | forwarding select codes, the nop |
| `if_id_reg.sv`, `id_ex_reg.sv`, `ex_mem_reg.sv`, `mem_wb_reg.sv` | new | the four pipeline registers |
| `forward_unit.sv` | new | where each EX operand comes from |
| `hazard_unit.sv` | new | load-use stall, redirect flush, fetch stop |
| `rf_bypass.sv` | new | a register written in WB reads correctly in ID in the same cycle |

`riscv_core` keeps the single-cycle core's parameters (`RESET_ADDR`, `IMEM_WORDS`, `DMEM_WORDS`, `INIT_FILE`, `DMEM_INIT_FILE`), its ports, and the instance paths testbenches look into (`u_id.u_rf.regs`, `u_mem.u_dmem.mem`, `u_if.u_imem.mem`).

## The pipeline

### Pipeline registers

A bubble has `valid = 0`, and every control signal that changes state is ANDed with `valid` as it enters ID/EX, so a bubble writes nothing and redirects nothing.

| Register | Contents | Control |
|---|---|---|
| IF/ID | `valid`, `pc`, `pc_plus4`, `instr` | `write = 0` holds (stall); `flush` makes a bubble (nop) |
| ID/EX | `valid`, `pc`, `pc_plus4`, `instr`, `rs1/rs2/rd_addr`, `funct3`, `rs1/rs2/rs3_data`, `imm`, every control signal from `control.sv` | `flush` makes a bubble (redirect or stall) |
| EX/MEM | `valid`, `pc`, `pc_plus4`, `instr`, `rd_addr`, `funct3`, `alu_y`, `ex_result`, `store_data`, `reg_write`, `mem_write`, `wb_sel`, `illegal`, `system` | never stalls; its address half is inside `dmem` |
| MEM/WB | as EX/MEM, plus `load_data` | never stalls; the debug outputs come from here |

`pc_plus4` is carried so that `wb_stage` is reused unchanged; `instr` is carried for `dbg_instr`, and Vivado removes it when nothing reads it.

### Memories

- **Instruction memory.** `imem`'s address is `next_pc`, the value `pc_reg` takes at the same edge, so during each cycle `instr` is the word at `pc`, exactly as with a combinational memory. A stall makes `next_pc = pc` (the same word is read again); a redirect makes it the target; reset makes it `RESET_ADDR`.
- **Data memory.** A load or store is issued at the end of EX: `dmem`'s address is EX's `alu_y`, and the store side of `lsu` shifts the forwarded rs2 into its lane and builds the byte mask in EX, so a store writes at the EX→MEM edge. In MEM the whole word comes out, the load side of `lsu` picks the byte (`alu_y[1:0]` from EX/MEM) and extends it (`funct3` from EX/MEM), and the value goes into MEM/WB. Reads and writes share one port; the block RAM's second port stays free for the ARM side.

A load followed by an instruction that uses it:

| Cycle | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| `lw x5, 0(x6)` | IF | ID | EX: address to `dmem` | MEM: word out, byte select, sign extend | WB | | |
| `add x7, x5, x8` | | IF | ID: load-use, stall | ID again (a bubble is in EX) | EX: x5 from MEM/WB | MEM | WB |
| next | | | IF | IF again | ID | EX | MEM |

A store's data is needed in EX too, so `lw x5` followed by `sw x5` also stalls once.

### Hazards

```text
forward_a = EX/MEM writes rs1 (rd != 0)  -> FWD_EX_MEM   ex_mem_value: pc_plus4 for jal/jalr, else ex_result
          | MEM/WB writes rs1 (rd != 0)  -> FWD_MEM_WB   wb_data
          | otherwise                    -> FWD_ID_EX    the value read in ID
forward_b, forward_c: the same for rs2 and rs3 (rs3 = the rd field)

rf_bypass: rsN_data = (WB writes rsN_addr, rd != 0) ? wb_data : register file   (all three ports)

stall    = id_ex_mem_read & id_ex_rd != 0 & (id_ex_rd == rs1 | id_ex_rd == rs2 | (rs3_read & id_ex_rd == rd))
flush    = taken branch, jal or jalr in EX
id_stop  = if_id_valid & (system | illegal);  fetch_stopped sticks once it moves on to EX

next_pc  = rst ? RESET_ADDR : flush ? redirect_pc : (stall | id_stop | fetch_stopped) ? pc : pc + 4
IF/ID    = bubble on flush, or on id_stop / fetch_stopped (unless stalled); holds on stall
ID/EX    = bubble on flush or stall;   EX/MEM and MEM/WB never stall
```

rs1 and rs2 are compared by field, whether or not the instruction reads them; see [False load-use stalls](#false-load-use-stalls).

### Stopping

The debug outputs come from MEM/WB, so a testbench stops only when `ebreak`, `ecall` or an illegal word reaches WB, after every older instruction has finished. Fetch stops as soon as such an instruction is in ID: everything behind it becomes a bubble, so when the run stops no younger instruction has written a register or memory, exactly as on `rv32iss` and the single-cycle core. A wrong-path `ebreak` or illegal word is flushed by the redirect in the same cycle and stops nothing.

### Debug outputs

`dbg_pc`, `dbg_instr`, `dbg_illegal` and `dbg_system` describe the instruction in WB (bubbles have `dbg_system = dbg_illegal = 0`). `dbg_mem_we`, `dbg_mem_addr` and `dbg_mem_wdata` describe its store, if it made one; the FPGA wrapper uses them to show the KWS label.

## Verification

| Test | Checks |
|---|---|
| unit testbenches of the reused blocks | run again from `../single_cycle/tb/`, unchanged |
| `tb_imem`, `tb_dmem` | the single-cycle checks, adapted to a synchronous read (a read presents the address and waits one edge), plus: the output holds between edges; a read and a write of one word at one edge return the old word |
| `tb_forward_unit`, `tb_hazard_unit`, `tb_rf_bypass` | each against an independent model, on hand-picked and 2000–3000 random cases; the fetch stop's sequence (not set while stalled or flushed, sticks until reset) |
| `tb_core` | smoke: every register, the memory results, the stop pc; 188 cycles (single-cycle: 144) |
| `tb_core_dot64` | dot64: every register and memory word; kernels 64 and 322 cycles (single-cycle: 48 and 256), 476 in all |
| `hazards` | 27 directed cases, each with values (through the trace) and timing (exactly its load-use and flush cycles): forwarding from EX/MEM and MEM/WB for rs1, rs2, rs3; the bypass; load-use on rs1, rs2, rs3; load then store of the loaded register; loads to x0; branches taken and not, `jal`, `jalr` with forwarded and loaded bases; 8 DOT4.S8 into one accumulator with no stall; CLIP.S8 after DOT4.S8; writes to x0 not forwarded. Plus 4 programs: `ebreak` after a store, stores after `ebreak` (must not write), `ebreak` and an illegal word on a wrong path (must not stop) |
| `random` | 8 random programs (3 padded, 5 hazard-dense): register trace and final data window equal `rv32iss`'s |
| `kws` | `hello` on builds (a), (b), (c); the whole model, build (c), on two inputs, every layer |

Beyond the suites, for this step:

- **Full traces.** KWS builds (b) and (c) on `tst_000007_Yes_9` write exactly `rv32iss`'s register trace: 11,375,874 and 3,165,880 register writes.
- **300 more random programs.** `random_slow` (seeds 1000–1299, half padded, half hazard-dense): every register trace and final data window equals `rv32iss`'s.
- **All 19 inputs.** Build (c) is bit-exact at every layer on all 19 inputs in the RTL, and its cycles, instructions, load-use and flush cycles equal the cycle model at every marker (`python3 kws/run_all.py rtl --core pipelined`, in `../single_cycle/`). So do build (b) on one recording and build (a) up to the end of its first conv.

### The tests have been shown to fail

Each bug below was planted in a scratch copy of the repository and the fast suite (18 testbenches) was run there. Every one is caught by the hazard and the random programs, and most also by a unit testbench or a core test.

| Planted bug | Passed | Failing | First difference reported |
|---|---:|---|---|
| no EX/MEM forwarding of rs3 | 14/18 | `tb_forward_unit`, `tb_core_dot64`, `hazards`, `random` | hazards, trace line 14: x7 = 0x7a, `rv32iss` 0xde |
| no load-use stall on rs3 | 15/18 | `tb_hazard_unit`, `hazards`, `random` | case 12 (load-use, rs3): 0 load-use cycles, expected 1 |
| no flush on a taken branch (the PC still moves) | 14/18 | `tb_hazard_unit`, `tb_core`, `hazards`, `random` | case 18 (branch taken): 0 flush cycles, expected 2 |
| forwarding from x0 | 13/18 | `tb_forward_unit`, `tb_core`, `tb_core_dot64`, `hazards`, `random` | hazards, trace line 49: x6 = 0x2001e000, `rv32iss` 0 |
| no register-file bypass | 13/18 | `tb_rf_bypass`, `tb_core`, `tb_core_dot64`, `hazards`, `random` | hazards, trace line 29: x6 = 0x1a, `rv32iss` 0x22 |
| the run stops when `ebreak` reaches ID, not WB | 14/18 | `tb_core`, `tb_core_dot64`, `hazards`, `random` | `ebreak_after_store`: 1 register write, `rv32iss` 2 |
| MEM/WB wins over EX/MEM (priority reversed) | 13/18 | `tb_forward_unit`, `tb_core`, `tb_core_dot64`, `hazards`, `random` | hazards, trace line 35: x6 = 1, `rv32iss` 2 |
| store data not forwarded (the store writes ID/EX's rs2) | 14/18 | `tb_core`, `tb_core_dot64`, `hazards`, `random` | `ebreak_after_store`: final data window differs |

The hazard and random programs stop after 100,000 cycles (they need a few thousand), and a stop there is a failure. Without that limit the last bug made the hazards program loop until the default limit of 100 M cycles.

## Measurements

### The cycle model

`rv32iss --pipeline` counts cycles for this core, without changing what it executes: each instruction is in EX one cycle after the one before, plus one cycle for a load-use stall and two after each taken branch, `jal` or `jalr`. The first instruction is in EX in cycle 2, and the run ends when `ebreak` reaches WB, so cycles = instructions + load-use + 2 × redirects + 3. It splits the cycles at each marker exactly as `tb_core_kws` does, by what is in EX: an instruction, a load-use bubble, a flush bubble, or other (the fill). On every program tried (smoke, dot64, the hazard and random programs, KWS (b) and (c) in full, (a)'s first conv) it equals the RTL exactly, marker by marker. Build (a) as a whole is therefore given as simulator-measured.

### KWS, per layer

The same three builds of the KWS program as on the single-cycle core ([details](../single_cycle/README.md#the-three-builds-a-b-and-c)):

- **(a)** RV32I only: every multiply is a call to libgcc's software `__mulsi3`;
- **(b)** RV32I + Zmmul: hardware `mul`, one multiply-accumulate per instruction;
- **(c)** RV32I + Zmmul + DOT4.S8 and CLIP.S8: four multiply-accumulates per instruction.

Means over the 12 real recordings; `results.md` holds the generated version. Build (c):

| # | Layer | Cycles | Instructions | CPI | Load-use cycles | Flush cycles |
|---|---|---:|---:|---:|---:|---:|
|  | setup (fill padding) | 64.0 k | 38.4 k | 1.666 | 0 | 25.6 k |
| 1 | conv 10×4 | 346.4 k | 329.4 k | 1.052 | 0 | 17.0 k |
| 2, 4, 6, 8 | depthwise (each) | 368.5 k | 352.5 k | 1.045 | 0 | 16.0 k |
| 3, 5, 7, 9 | pointwise (each) | 404.0 k | 388.0 k | 1.041 | 0 | 16.0 k |
| 10 | average pool | 53.9 k | 37.7 k | 1.432 | 0 | 16.3 k |
| 12 | fully connected | 1.7 k | 1.3 k | 1.290 | 0 | 0.4 k |
| 13 | arg-max | 0.1 k | 0.1 k | 1.604 | 0 | 0.0 k |
| | **Total** | **3.56 M** | **3.37 M** | **1.056** | **21** | **187.3 k** |

| Build | Cycles (mean) | Range over the 12 | Instructions | CPI | Load-use cycles | Flush cycles |
|---|---:|---|---:|---:|---:|---:|
| (a) | 457,245,383 | 456,516,009 to 458,711,548 | 333.30 M | 1.372 | 7.4 k | 123.94 M |
| (b) | 12,500,447 | 12,499,272 to 12,501,759 | 11.72 M | 1.066 | 370.5 k | 405.0 k |
| (c) | 3,556,226 | 3,556,225 to 3,556,229 | 3.37 M | 1.056 | 21 | 187.3 k |

Build (a) is simulator-measured (the cycle model, which equals the RTL on its first conv layer). Its flushes come from `__mulsi3`, whose bit loop takes a branch every iteration. Where the stalls come from:

- **load-use:** in (b), mostly the first conv's `lb`/`mul` pairs (178 k) and the `lb` pairs of depthwise and pointwise; in (c), none left after the scheduling fix below;
- **flush:** every loop iteration ends in a taken branch (2 cycles each); there is no other kind of stall.

### The scheduling fix

Before the fix, build (c) spent 552 k cycles (13% of 4.10 M) in load-use stalls: in the pointwise and first-conv loops every `lw` came right before the `dot4.s8` that used it. All 16 weights of a pointwise filter sit in registers, which leaves one temporary for the input words. Measured with the cycle model, all bit-exact:

| Change | (b) pipelined cycles | (c) pipelined cycles | (c) single-cycle cycles |
|---|---:|---:|---:|
| none | 12,500,447 | 4,101,848 | 3,362,554 |
| compiler flag `-mtune=sifive-7-series` | 12,236,418 (−2.1%) | 4,022,326 (−1.9%) | 3,362,660 |
| compiler flag `-mtune=sifive-p400-series` | 12,093,064 (−3.3%) | 4,072,462 (−0.7%) | 3,362,684 |
| compiler flag `-mtune=xiangshan-nanhu` | 12,227,451 (−2.2%) | 3,971,498 (−3.2%) | 3,646,930 (+8.5%) |
| `-fschedule-insns` | no change | no change | no change |
| **source: load one word ahead (kept)** | 12,500,447 | **3,556,226 (−13.3%)** | 3,368,932 (+0.19%) |
| source + `-mtune=sifive-7-series` | 12,236,418 | 3,564,248 | 3,368,838 |

The source change loads each word one `dot4.s8` ahead, into two variables in turn; without the empty compiler barrier `LOAD_AHEAD` (in `kws.c`), GCC moves the loads straight back and nothing changes. It is kept; the build flags are not changed, since they help little and favour a different target for each build. Builds (a) and (b) do not use these loops, so their programs are unchanged. The single-cycle core runs the same code, and its figures are re-measured with it.

### False load-use stalls

The hazard unit compares the rs1 and rs2 fields whether or not the instruction reads them. A stall caused only by an unread field (for example, an `lb` whose offset bits happen to equal the previous load's rd):

| Build | False stalls | Share of all cycles |
|---|---:|---:|
| (a) | 6 | 0.00% |
| (b) | 128,136 of 370,499 | **1.03%** |
| (c) | 10 of 21 | 0.00% |

Build (b) is just over 1%. Avoiding it needs `rs1_read`/`rs2_read` outputs from `control.sv`, which is shared with the single-cycle core, so it has not been changed.

### Single-cycle vs pipelined

Both cores were built by Vivado 2026.1 for the PYNQ-Z2's xc7z020clg400-1, inside the FPGA wrapper with KWS build (c) preloaded (see [`../fpga/`](../fpga/)). The runs were constrained to 100 MHz, which neither core meets. The maximum clock is 1 / (period − WNS) and the time per inference is cycles × (period − WNS); both are estimates from those runs, not measured clocks.

| | Single-cycle | Pipelined |
|---|---:|---:|
| Worst setup slack (WNS) at 10 ns | −14.700 ns | −6.873 ns |
| Maximum clock | 40.49 MHz | 59.27 MHz |

| Build | Single-cycle cycles | Pipelined cycles | Pipelined CPI | Single-cycle time | Pipelined time | Pipelined faster by |
|---|---:|---:|---:|---:|---:|---:|
| (a) | 333,300,720 | 457,245,383 | 1.372 | 8.23 s | 7.72 s | 1.07× |
| (b) | 11,724,916 | 12,500,447 | 1.066 | 289.6 ms | 210.9 ms | 1.37× |
| (c) | 3,368,932 | 3,556,226 | 1.056 | 83.2 ms | 60.0 ms | 1.39× |

The pipeline raises the clock 1.46×, and on build (c) its CPI of 1.056 gives back 5% of that. Build (a) gains only 1.07×, because `__mulsi3`'s branches take its CPI to 1.372.

| Resource (available) | Single-cycle | Pipelined |
|---|---:|---:|
| Slice LUTs (53,200) | 11,061 | 1,784 |
| of which LUT RAM (17,400) | 8,256 | 66 |
| Flip-flops (106,400) | 42 | 621 |
| Block RAM tiles (140) | 0 | 24 |
| DSP slices (220) | 4 | 4 |

- **Memories.** Block RAM reads synchronously, so the single-cycle core's memories cannot use it. Its 64 KiB data memory becomes 8,192 LUTs of distributed RAM (64 bits each), and its read-only instruction memory becomes logic for the program loaded. Here both memories are block RAM: 24 tiles hold 32 KiB + 64 KiB at 4 KiB a tile.
- **Register file.** Both cores' register files are distributed RAM: 64 LUTs for its three read ports.
- **DSP slices.** In both cores the 4 DSP slices are `mul_unit`'s 33 × 33 multiplier. DOT4.S8's four 8 × 8 products are built from LUTs and carry chains.
- **Flip-flops.** The pipelined core's 621 are mostly its four pipeline registers.

## Known limitations

- **Decode holes** behave as in the single-cycle core (see its README), on purpose: `rv32iss` stays the golden model for both.
- **False load-use stalls** on unread fields, 1.03% of build (b) (above).
- **No branch prediction:** every taken branch or jump costs 2 cycles; that is 5% of build (c) and 27% of build (a).
- **DOT4.S8 sets the clock.** The slowest path has 23 logic levels and takes 16.8 ns (7.4 ns logic, 9.3 ns routing). All 10 slowest paths go through `nn_unit`. The slowest one runs:
  1. from `ex_mem_rd_addr` through the forwarding compare and the rs1 forwarding mux (fan-out 32);
  2. into DOT4.S8's four lane multipliers, built from LUTs and carry chains rather than DSP blocks;
  3. through its adder tree, the accumulate and the `ex_sel` result mux;
  4. into `ex_mem_ex_result`.
- **The next speed step.** Split DOT4.S8 (and the multiply) across EX and MEM, with the accumulator forwarded inside the second stage so that a chain of DOT4.S8 into one accumulator still does not stall. It is not done, because it restructures the pipeline.
  - **Tried first, without effect: DSP blocks with no registers.** `build.tcl ... dsp` (see [`../fpga/`](../fpga/)) builds the four products in DSP blocks without changing the logic. The clock stays where it was: 58.96 MHz instead of 59.27 MHz. Without registers, the four cascaded DSP blocks take about 9 ns, as the LUTs did, so DSP blocks only pay off with the split, which can use their internal registers.
- **The fetch path** (a redirect from EX through the next-PC mux to the instruction memory's address) is not among the 10 slowest paths.
