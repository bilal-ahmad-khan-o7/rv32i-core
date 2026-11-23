# rv32iss: instruction-set simulator

The golden model for both cores: RV32I + Zmmul + DOT4.S8 + CLIP.S8. `rv32iss.c` is a single C file with no dependencies. It runs at about 200 M instructions per second, against about 12 k cycles per second for Icarus, which is what makes KWS build (a) and the 1000-file run possible ([`../kws/`](../kws/)). Run from the repository root:

```bash
gcc -O2 -std=gnu11 -o build/rv32iss iss/rv32iss.c
```

```bash
./build/rv32iss --imem kws/gen/kws_c.imem.hex --dmem kws/gen/kws_c.dmem.hex --load kws/gen/input_syn_random.hex@0x1000F000 --layers kws/gen/layers.hex --expect kws/gen/expect_syn_random.hex
```

- **It matches the RTL,** including memory aliasing and the decode holes listed under the single-cycle core's [Known limitations](../single_cycle/README.md#known-limitations). The two share the layer table and expected-output files.
- **Cross-check.** `--trace FILE` writes one line per register write (pc, rd, value), and `tb_core_kws` writes the same format with `+TRACE=FILE`. Build (c) on one recording gives identical traces over 3,165,880 writes, on both cores; `hello`, `smoke` and `dot64` match too.
- **On the pipelined core,** register writes keep program order, so its trace must still equal the simulator's. Only the cycle counts differ.
- **`--pipeline`** also counts the cycles of the pipelined core in [`../pipelined/`](../pipelined/): each instruction is one cycle, plus one for a load-use stall and two for each taken branch or jump. It equals that core's RTL exactly; see its README.
- **Other options:** `--load-bin F@ADDR`, `--dump ADDR LEN`, `--max N`, `--trace-max N`, `--quiet`, `--imem-words N`, `--dmem-words N`. It also prints the lowest `sp` reached.
