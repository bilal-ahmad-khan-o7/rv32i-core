# FPGA: Vivado scripts for the PYNQ-Z2

These scripts synthesise, place and route either core for the PYNQ-Z2 (Zynq-7020, part `xc7z020clg400-1`) and report its maximum clock and resource use. A bitstream, the board bring-up and the ARM side are step 3; the wrapper, the clock and reset modules and the constraints are written so that step 3 can reuse them.

| File | Contents |
|---|---|
| `build.tcl` | non-project batch flow: synthesis, `opt_design`, place, route, reports |
| `pynq_z2.xdc` | the pins used, copied from the official PYNQ-Z2 master XDC (source in the file) |
| `rtl/top_kws.sv` | the wrapper: one core, the clock, the reset button, the LEDs |
| `rtl/clock_gen.sv` | MMCM: 125 MHz board clock to the core clock (100 MHz; `CLK_DIVIDE` changes it) |
| `rtl/reset_sync.sv` | button and MMCM lock to a reset synchronous to the core clock |
| `make_mem.py`, `mem/` | the data-memory preload: KWS build (c) with recording `tst_000007_Yes_9` ("Yes") merged in. Not committed (the recording has no open licence): run `python3 fpga/make_mem.py` after recreating the recordings (see `single_cycle/README.md`, "Inputs") |
| `sim/` | an Icarus test of the wrapper (`run_sim.py`), with stand-ins for the two Xilinx primitives |

## What the wrapper does

Both cores are preloaded with KWS build (c) (the program compiled for RV32I + Zmmul + the custom DOT4.S8 / CLIP.S8 instructions; see [`../single_cycle/README.md`](../single_cycle/README.md#the-three-builds-a-b-and-c)) and one recording, so the logic depends on real data and Vivado cannot optimise it away. After reset the core runs the model once:

| Output | Pin | Meaning |
|---|---|---|
| `led[3:0]` (LD0–LD3) | R14, P14, N16, M14 | the label the program stores to `kws_label`, 0–11 in binary ("Yes" = 9 = `1001`) |
| `led4_g` (RGB LD4, green) | G17 | done: the core reached `ebreak` |
| `led5_r` (RGB LD5, red) | M15 | error: the core reached an illegal instruction |
| `btn0` (BTN0) | D19 | reset; press it to run again |

Four LEDs can show 0–11 but not "done" as well, so done uses an RGB LED. The wrapper sees the label through the core's `dbg_mem_*` outputs, which describe each store. Once the core is done, the wrapper holds it in reset, so it runs exactly once per button press.

## Running Vivado

Copy the repository to a folder whose path has no spaces (e.g. `D:\minor\`). In that folder, create the output folder first, because git does not carry it and Vivado may not create the log's folder (`mkdir fpga\out` in cmd or PowerShell). Then run:

```bash
vivado -mode batch -source fpga/build.tcl -log fpga/out/pipelined.log -nojournal -tclargs pipelined
```

```bash
vivado -mode batch -source fpga/build.tcl -log fpga/out/single_cycle.log -nojournal -tclargs single_cycle
```

The two paths in each command (`fpga/build.tcl` and the log) are relative to the repository's top folder; `build.tcl` itself finds every other file from its own location. It needs Vivado 2019.1 or later. On a 4-core laptop with 8 GB of memory, the pipelined core takes about 7 minutes. The single-cycle core takes about 25, because its 64 KiB data memory becomes distributed RAM (8,192 LUTs). Vivado's scratch files (`.Xil/`, `clockInfo.txt`, …) go to `fpga/out/<core>/` with the reports.

**Licence.** Before 2026.1, the xc7z020 needs no licence. From 2026.1, Vivado does not start without a licence file, even for free use ("a valid license was not found").
- **Which licence:** the free one is **Vivado Basic Tier License, Node Locked License** (Certificate – No Charge), from AMD's Product Licensing site. It covers every Zynq-7000 device and lasts one year.
- **Host ID:** the licence is locked to the PC's host ID. `lmutil lmhostid`, in `Vivado\bin\unwrapped\win64.o\`, prints the ID Vivado checks.
- **Pointing Vivado at it:** Vivado does not look in `%USERPROFILE%\.Xilinx\` on its own. Either set the environment variable `XILINXD_LICENSE_FILE` to the `.lic` file, or add the file in the Vivado License Manager under Manage License Search Paths.

**Send back, for each core**, from `fpga/out/<core>/`:

| File | Contents |
|---|---|
| `summary.txt` | the maximum clock (1 / (period − WNS)), the slowest path (start, end, logic levels, logic and routing delay), the 10 slowest paths, the main resource counts |
| `timing_summary.rpt` | `report_timing_summary` |
| `utilization.rpt`, `utilization_hier.rpt` | `report_utilization`, flat and per module |
| `critical_paths.rpt` | the 10 slowest paths in full |

If a run fails, send `fpga/out/<core>.log` as well. `routed.dcp` (the routed design) stays on your PC for step 3.

### DOT4.S8's products in DSP blocks (experiment)

A second argument, `dsp`, defines `NN_USE_DSP` for synthesis. That puts a `use_dsp` attribute on DOT4.S8's four lane products in `nn_unit.sv`, so Vivado builds them in DSP blocks instead of LUTs. The logic is the same, the attribute means nothing to a simulator, and without `dsp` the flow is unchanged. Results go to `fpga/out/<core>_dsp/`:

```bash
vivado -mode batch -source fpga/build.tcl -log fpga/out/pipelined_dsp.log -nojournal -tclargs pipelined dsp
```

```bash
vivado -mode batch -source fpga/build.tcl -log fpga/out/single_cycle_dsp.log -nojournal -tclargs single_cycle dsp
```

The attribute works (8 DSP slices instead of 4), but neither clock improves, so the default flow keeps the products in LUTs:

| | Pipelined | Pipelined, `dsp` | Single-cycle | Single-cycle, `dsp` |
|---|---:|---:|---:|---:|
| Worst setup slack (WNS) at 10 ns | −6.873 ns | −6.960 ns | −14.700 ns | −15.551 ns |
| Maximum clock | 59.27 MHz | 58.96 MHz | 40.49 MHz | 39.14 MHz |
| Slice LUTs | 1,784 | 1,477 | 11,061 | 10,767 |
| Flip-flops | 621 | 590 | 42 | 43 |
| DSP slices | 4 | 8 | 4 | 8 |

Vivado builds the four products and their sum as a cascade of four DSP blocks, each adding the result of the one before.
- **Each block is unregistered,** so the first block's multiply takes 4.0 ns and each later block 1.5–1.7 ns: about 9 ns, roughly what the LUTs took.
- **On the pipelined core's slowest path,** routing falls from 9.3 to 5.1 ns, and logic rises from 7.4 to 11.8 ns.
- **DSP blocks are fast when their internal registers are used.** That means splitting DOT4.S8 across two stages, the next speed step in [`../pipelined/README.md`](../pipelined/README.md).

## Results

Vivado 2026.1, both cores built with the commands above, without `dsp`, on 2026-11-06. Both placed and routed with no errors and no critical warnings, and hold timing is met (WHS +0.064 ns pipelined, +0.122 ns single-cycle). The runs were constrained to 100 MHz, which neither core meets, so the maximum clock is an estimate from them. The same builds on a second PC gave identical timing: the same slack and the same slowest paths, to the picosecond.

| | Single-cycle | Pipelined |
|---|---:|---:|
| Worst setup slack (WNS) at 10 ns | −14.700 ns | −6.873 ns |
| Maximum clock, 1 / (10 ns − WNS) | 40.49 MHz | 59.27 MHz |
| Slowest path | `pc_reg` → register file write data | `ex_mem_rd_addr` → `ex_mem_ex_result` |
| Its logic levels; delay (logic + routing) | 21; 24.1 ns (4.7 + 19.4) | 23; 16.8 ns (7.4 + 9.3) |
| Slice LUTs (of 53,200) | 11,061 | 1,784 |
| of which LUT RAM (of 17,400) | 8,256 | 66 |
| Flip-flops (of 106,400) | 42 | 621 |
| Block RAM tiles (of 140) | 0 | 24 |
| DSP slices (of 220) | 4 | 4 |
| KWS build (c), time per inference | 83.2 ms | 60.0 ms |

The pipelined core's slowest path goes through the forwarding mux and DOT4.S8; [`../pipelined/README.md`](../pipelined/README.md) describes it and compares the two cores in full.

## The clock

The board supplies 125 MHz on H16. `clock_gen` multiplies it by 8 (VCO 1000 MHz) and divides by `CLK_DIVIDE`: 10 for 100 MHz, the constraint for now. Vivado derives the core clock's constraint from the board clock. The maximum clock is reported as 1 / (10 ns − WNS), which is still meaningful when the design misses 100 MHz (WNS < 0).

For the bitstream in step 3, `CLK_DIVIDE` leaves a margin below the measured maxima:

| Core | `CLK_DIVIDE` | Core clock | Measured maximum |
|---|---:|---:|---:|
| pipelined | 18 | 55.6 MHz | 59.27 MHz |
| single-cycle | 30 | 33.3 MHz | 40.49 MHz |

Not set yet: `build.tcl` still builds at 100 MHz.

## Testing the wrapper without Vivado

```bash
python3 fpga/sim/run_sim.py
```

This runs `top_kws` in Icarus for each core, exactly as on the board: preloaded memories, reset from the button, answer on the LEDs. `xilinx_stubs.sv` stands in for `MMCME2_BASE` and `BUFG` in simulation only; `build.tcl` never reads it. Both cores finish with label 9 and no error. To preload another recording, run `python3 fpga/make_mem.py <recording>` and change `DMEM_FILE` in `build.tcl` and `sim/tb_top_kws.sv`.
