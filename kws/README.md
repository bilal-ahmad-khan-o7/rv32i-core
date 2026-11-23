# KWS: keyword spotting on the core

The cores run the MLPerf Tiny keyword-spotting model, a DS-CNN (49 × 10 INT8 MFCC input, 12 classes, about 2.66 M MACs), as bare-metal C with no compiler changes.

- **Bit-exact.** Every layer's output equals TFLite's reference int8 kernels byte for byte, on 19 inputs, in the RTL of both cores and in the instruction simulator ([`../iss/`](../iss/)).
- **Real words.** All 12 real recordings tested give the right word. On the 1000 test files the core's 12 scores and label equal TFLite's on every file, at 90.1% accuracy.
- **Speed.** DOT4.S8 and CLIP.S8 make the whole model 3.48× faster than `mul` alone.

## The three builds: (a), (b) and (c)

The same C program, `kws/sw/kws.c`, is compiled three times. Each build lets the compiler use more of the core's instructions, so comparing them shows what each hardware addition is worth.

| Build | ISA it targets | Compiler flags | How one multiply-accumulate (MAC) is done |
|---|---|---|---|
| **(a)** | RV32I only: no multiply instruction | `-march=rv32i` | every `*` calls `__mulsi3`, libgcc's software multiply (a shift-and-add loop of tens of instructions) |
| **(b)** | RV32I + Zmmul (hardware multiply) | `-march=rv32i_zmmul` | `lb`, `lb`, `mul`, `add`: one MAC per `mul` |
| **(c)** | RV32I + Zmmul + DOT4.S8 and CLIP.S8 | `-march=rv32i_zmmul -DHAVE_NN` | `lw`, `lw`, `dot4.s8`: four MACs in one instruction; `clip.s8` saturates each output to int8 |

(a) → (b) measures the hardware multiplier; (b) → (c) measures the two custom instructions. All three give the same output bytes. Build (c) is the one used on the FPGA. `HAVE_NN` switches the inner loops to `dot4_s8()` and `clip_s8()` from `kws/sw/nn_insn.h`, which emit the custom instructions as inline assembly, so no compiler change is needed.

**Softmax is not run on the core.** The core stops at the 12 FC outputs and takes their arg-max; those two things are what is compared with TFLite. Softmax did not change the arg-max on any of the 1,007 inputs tested.

## Results

Builds (a), (b) and (c) are described [above](#the-three-builds-a-b-and-c). Figures are for the single-cycle core, which runs one instruction per clock, so cycles = instructions; the pipelined core's are in [`../pipelined/results.md`](../pipelined/results.md). Figures are means over the 12 real recordings. `kws/results.md` is the generated copy.

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

## Memory map

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

## Building and running

The committed images in `kws/gen` need only Icarus, Python and a host `gcc`, plus the real recordings for the runs that use them (see [Inputs](#inputs)). Run from the repository root.

```bash
python3 single_cycle/sim/run_tests.py kws
```

```bash
python3 kws/run_all.py iss
```

```bash
python3 kws/run_all.py rtl
```

- `single_cycle/sim/run_tests.py kws` is the regression test, in the RTL, and takes about 10 minutes. It is a separate target, not part of the default 13. It runs `hello` on all three builds, then the whole model, build (c), on two inputs: `tst_000012_Go_1` (the recording where FC's rounding shows) and `syn_random` (which drives the upper clamp). The programs, layer table and expected files are used unchanged by the pipelined core in [`../pipelined/`](../pipelined/), whose `tb_core_kws` takes the marker store from EX and the trace from WB.
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

## How each layer runs

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

## Matching TFLite exactly

- **The reference is TFLite with its reference kernels** (`OpResolverType.BUILTIN_REF`). Its other kernels give different bytes: on 1,007 inputs the optimised kernels differ in 10.6% of output bytes and the default ones (XNNPACK) in 14.3%. Comparing against those would fail for reasons that have nothing to do with the core. The NumPy model in `kws/ref/` equals the reference kernels on all 1,007 inputs and all 11 layers.
- **Convolutions use double rounding,** TFLite's `MultiplyByQuantizedMultiplier`. `requant()` in `kws.c` is a shorter form of it that holds for every multiplier here (2³⁰ ≤ M < 2³¹) and every shift (right, by at least 1); its comment gives the derivation.
- **FC uses one rounding.** It follows desktop TFLite's reference kernel: a float scale with one rounding, reproduced exactly in integers as `(acc · M + 2³⁷) >> 38`. `check_ref.py` compares that with the float result on every accumulator any input can reach (−680,638 to 348,756) and finds no difference.
  - TFLite Micro's FC instead receives only an integer `output_multiplier` / `output_shift` and calls `reference_integer_ops::FullyConnected`. That points to the same `MultiplyByQuantizedMultiplier` rounding as the conv layers, but it was not confirmed from the source.
  - On a TFLite Micro build, about 49 of 12,000 FC scores would differ by 1, and the predicted word would not change.
- **Average pool divides by 125,** rounding to the nearest and truncating as TFLite does. The published `.tflite` has a 25 × 5 pool; the current `keras_model.py` in `mlcommons/tiny` says (24, 5), but the binary is what runs. Builds (b) and (c) need no divide routine, because GCC turns `/ 125` into an exact reciprocal multiply (`mulh` by `0x10624DD3`). Only build (a) calls `__divsi3`.
- **CLIP.S8 alone is exact.** Every CONV_2D and DEPTHWISE_CONV_2D has a fused ReLU and output zero point −128, so clamping to [−128, 127] *is* ReLU + clamp. FC has no ReLU (output zero point 14); clamping is still correct there.
- **Weights** have zero point 0 and per-channel scales (64 per layer), so signed × signed on the raw bytes is exact, with per-channel requantisation tables.
- **Model size.** The weights and biases are **24,376 bytes** in the model (the core needs 24,368 B; the other 8 are a reshape shape).

## Inputs

- **7 synthetic:** all −128, all 127, all 83 (the zero point), all 0, random, a ramp, and an impulse beside the padding.
- **12 real recordings,** one per class, in `kws/inputs/real/`. These are the MLPerf Tiny test features published with EEMBC's `energyrunner` (`datasets/kws01`), 490 INT8 values each, so feature extraction is not run here.

The EEMBC repository has no licence and says "Copyright of EEMBC", so the recordings, and the files generated from them, are **not in this repository**. The `kws` regression target, `kws/run_all.py` and the FPGA build need them; the synthetic inputs and every other test do not. To recreate them:

1. `python3 kws/ref/fetch_eembc.py` downloads all 1000 files into `kws/inputs/eembc_all/`;
2. copy the 12 named in the table above into `kws/inputs/real/`;
3. `kws/ref/gen_kws.py` writes `kws/gen/input_tst_*.hex` and `expect_tst_*.hex`;
4. `python3 fpga/make_mem.py` writes the FPGA's data image.

Replacing them with features generated from Speech Commands v2 by the MLPerf pipeline would allow committing them; a WAV-to-word demo at the FPGA step would need that anyway.

## The KWS test has been shown to fail

Each bug was planted in a scratch copy of the project, and `python3 single_cycle/sim/run_tests.py kws` was run there. All ten failed the test, each at the layer where the bug lives.

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

## Layout

| Path | Contents |
|---|---|
| `sw/` | bare-metal C: `crt0.S`, `link.ld`, `nn_insn.h` (the custom instructions as inline assembly), `hello.c` (bring-up), `kws.c` (the model) |
| `ref/` | Python reference: the model as arrays, a NumPy re-implementation, the comparison with TFLite, the table generator |
| `gen/` | generated and committed: C tables, program images, synthetic inputs and their expected outputs |
| `model/` | the `.tflite` file (MLPerf Tiny reference model, Apache-2.0) |
| `inputs/real/` | the 12 real recordings: not committed, see [Inputs](#inputs) |
| `build.py`, `run_all.py`, `results.md` | builds the C programs; runs the sweeps; the generated results |

## Limitations

- **KWS runs the model, not the whole pipeline.** The input is precomputed MFCC features, and softmax is not run. Feature extraction stays on the PC.
- **KWS cross-checks are partial for the slow builds.** The RTL ran build (b) on one recording and build (a) only to the end of the first conv. Their other figures are instruction-simulator counts.
- **Depthwise is not accelerated.** It is 42% of build (c), and DOT4.S8 does not fit the interleaved layout.
- **The stack limit is not enforced.** `0x1000_F400` is only a documented bound; the deepest use is 384 B.
