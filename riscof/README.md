# RISCOF: the official RISC-V architectural tests

[RISCOF](https://riscof.readthedocs.io) runs the [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) suite on two models:

1. this core in Icarus (the DUT, *device under test*);
2. [Spike](https://github.com/riscv-software-src/riscv-isa-sim), the reference simulator.

Each test writes its results into a memory region called the *signature*. RISCOF passes a test only if the two signatures match word for word. The core RTL is not changed for this: a separate testbench sets `RESET_ADDR` and the memory sizes through parameters.

## How a test flows

```
test.S ──gcc──► my.elf ──► Spike ─────────────────────────────► Reference-spike.signature ─┐
                   └─────► objcopy → my.hex ──► tb_riscof (Icarus) ► DUT-rv32i_core.signature ┴─► compare
```

| File | Role |
|---|---|
| `config.ini` | names the DUT plugin (`rv32i_core`) and the reference (`spike`); `core=` picks which core |
| `rv32i_core/riscof_rv32i_core.py` | DUT plugin: compiles the testbench once, then compiles and runs every test |
| `rv32i_core/*_isa.yaml` | what the core implements; RISCOF uses it to choose which tests apply |
| `rv32i_core/env/` | `link.ld` (memory layout at `0x8000_0000`), `model_test.h` (how a test halts: `ebreak`) |
| `spike/` | reference plugin, same compile command |
| `rtl_single_cycle.f`, `rtl_pipelined.f` | the RTL file lists, relative to the repository root |
| `tb/tb_riscof.sv` | loads the program into both memories, runs to `ebreak`, dumps the signature |
| `tools/run_test.py` | ELF → hex, finds `begin_signature`/`end_signature` with `nm`, runs the testbench |
| `tools/compare_trace.py` | the first instruction where the core and Spike disagree |
| `run_riscof.sh` | one command for a run; exit code 0 only if every test passed |

## 1. Install the tools (once)

`iverilog` and `riscv64-unknown-elf-gcc` are already needed by the rest of the repository.

**RISCOF**, in a virtual environment (Ubuntu refuses a system-wide `pip install`):

```bash
python3 -m venv ~/venvs/riscof
```

```bash
source ~/venvs/riscof/bin/activate
```

```bash
pip install riscof
```

**The tests**, pinned to the release used for the results below. Run this from `riscof/`. Do not use `riscof arch-test --clone`: the arch-test repository's default branch has moved to a new framework (ACT4) that RISCOF cannot run.

```bash
git clone --depth 1 -b ctp-release-e9514aa-2025-12-28 https://github.com/riscv-non-isa/riscv-arch-test
```

**Spike**, built from source into `~/tools/spike` (where `config.ini` looks for it). Older prebuilt Spikes may lack the `+signature` option.

```bash
sudo apt install build-essential device-tree-compiler
```

```bash
mkdir -p ~/tools/src && cd ~/tools/src && git clone --recursive https://github.com/riscv-software-src/riscv-isa-sim.git
```

```bash
cd ~/tools/src/riscv-isa-sim && mkdir -p build && cd build && ../configure --prefix=$HOME/tools/spike && make -j$(nproc) && make install
```

`--recursive` matters: Spike keeps its floating-point library (`berkeley-softfloat-3`) in a git submodule. Without it, `make` stops with *No rule to make target `.../softfloat.h`*. On an existing clone, run `git submodule update --init` in `riscv-isa-sim/` and build again.

## 2. Run

From `riscof/`, with the venv active:

```bash
./run_riscof.sh
```

```bash
./run_riscof.sh sll
```

The first runs all 38 RV32I tests; the second only the tests whose path contains `sll`. Both end with `RISCOF summary: N passed, M failed`. The report is `riscof_work/report.html`, and each test's files are in `riscof_work/src/<test>.S/{dut,ref}/`.

**The other core:** set `core=pipelined` in `config.ini`.

**The multiply tests (Zmmul):** copy `config.ini` to `config_mul.ini`, set `ispec=rv32i_core/rv32im_isa.yaml` in the copy, then run only the `mul` tests. The core has no divide, so `div`/`rem` would fail by design.

```bash
CONFIG=config_mul.ini SUITE=riscv-arch-test/riscv-test-suite/rv32i_m/M ./run_riscof.sh mul
```

## 3. When a test fails

Rerun the one test by hand with a trace, give Spike the same ELF with a commit log, and find the first instruction where they differ:

```bash
cd riscof_work/src/add-01.S/dut
```

```bash
python3 ../../../../tools/run_test.py --elf my.elf --vvp ../../../tb_riscof.vvp --sig out.sig --trace > trace.txt
```

```bash
~/tools/spike/bin/spike --isa=rv32i -l --log-commits my.elf 2> spike.log
```

```bash
python3 ../../../../tools/compare_trace.py --dut trace.txt --ref spike.log
```

## Results

Last full run: 2026-11-23. Every test ended at `ebreak`, none at the cycle limit.

| Core | RV32I (`rv32i_m/I`) | Multiply (`rv32i_m/M`: mul, mulh, mulhsu, mulhu) |
|---|---|---|
| `single_cycle` | 38 / 38 | 4 / 4 |
| `pipelined` | 38 / 38 | 4 / 4 |

Tools: RISCOF 1.25.3, arch-test `ctp-release-e9514aa-2025-12-28`, Spike 1.1.1-dev, `riscv64-unknown-elf-gcc` 14.2, Icarus Verilog 12.0.

**Not covered:**
- the privileged tests (the cores have no CSRs or traps);
- `Zifencei` (separate instruction and data memories);
- DOT4.S8 and CLIP.S8, which the official suite does not know. The repository's own tests and the KWS bit-exact check cover them.

The suite checks each instruction's result, but rarely puts dependent instructions close enough to stress the pipeline's forwarding. With MEM/WB → EX forwarding of rs2 removed, only `auipc-01` failed. The pipeline's own hazard tests and random programs are what cover that.
