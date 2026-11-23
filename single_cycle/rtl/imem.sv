`timescale 1ns/1ps
// imem.sv - instruction memory, read-only ROM with combinational read.
// Filled with nop, then loaded from INIT_FILE (one 32-bit hex word per line).
// The $readmemh path is relative to the directory vvp runs in.
module imem #(
  parameter int WORDS     = 1024,           // 1024 words = 4 KiB
  parameter     INIT_FILE = ""              // hex file; "" leaves all nop
) (
  input  logic [31:0] addr,                 // byte address (the PC)
  output logic [31:0] instr
);
  localparam int AW = $clog2(WORDS);        // index bits: 10 for 1024 words

  logic [31:0] mem [0:WORDS-1];

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0000_0013;  // addi x0,x0,0
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  assign instr = mem[addr[AW+1:2]];         // drop the 2 byte-offset bits
endmodule
