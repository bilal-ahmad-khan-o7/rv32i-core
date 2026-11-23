`timescale 1ns/1ps
// imem.sv - instruction memory: read-only, with a SYNCHRONOUS read, as FPGA block
// RAM has. Filled with nop, then loaded from INIT_FILE (one 32-bit hex word per line).
//
// Changed from single_cycle/rtl/imem.sv: the word comes out one clock edge after its
// address goes in. if_stage gives it next_pc, the value the PC register takes at
// that same edge, so the word and its PC still arrive together.
module imem #(
  parameter int WORDS     = 1024,           // 1024 words = 4 KiB
  parameter     INIT_FILE = ""              // hex file; "" leaves all nop
) (
  input  logic        clk,
  input  logic [31:0] addr,                 // byte address: next_pc
  output logic [31:0] instr                 // the word at the address of the last edge
);
  localparam int AW = $clog2(WORDS);        // index bits: 10 for 1024 words

  logic [31:0] mem [0:WORDS-1];

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0000_0013;  // addi x0,x0,0
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge clk)
    instr <= mem[addr[AW+1:2]];             // drop the 2 byte-offset bits
endmodule
