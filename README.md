# RV32I RISC-V Core

A single-cycle (and soon 5-stage pipelined) RV32I processor written in SystemVerilog.

## Status
- [ ] All RV32I instructions implemented
- [ ] Passes the official RISC-V architectural tests (RISCOF)
- [ ] 5-stage pipeline with hazard detection and forwarding

## How to run
iverilog -g2012 -o build/sim tb/tb_core.sv rtl/*.sv
vvp build/sim

## Tools
Icarus Verilog, GTKWave, Verilator, RISC-V GCC (riscv64-unknown-elf)
