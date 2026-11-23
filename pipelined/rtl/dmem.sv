`timescale 1ns/1ps
// dmem.sv - data memory: word array with a SYNCHRONOUS read and a clocked write with
// a 4-bit byte write mask, written as the block-RAM template Vivado recognises.
// Zero-filled, then optionally preloaded from INIT_FILE (one 32-bit hex word per line).
//
// Changed from single_cycle/rtl/dmem.sv: rdata is the word at the address of the
// last clock edge. The address register inside the RAM is therefore the address half
// of the EX/MEM pipeline register (see mem_stage.sv). A read in the same cycle as a
// write to the same word returns the old word (read-first); the core never does that,
// since each instruction makes at most one access.
//
// Port A is the core's. A second port, for the PYNQ-Z2's ARM side, would be one more
// always_ff block on the same `mem` array with its own clock, address, mask and data:
// true dual-port block RAM. It is not built yet; the memory map does not change.
module dmem #(
  parameter int WORDS     = 1024,           // 1024 words = 4 KiB
  parameter     INIT_FILE = ""              // hex file; "" leaves all zero
) (
  input  logic        clk,
  // port A: the core
  input  logic [31:0] addr,                 // byte address, from EX
  input  logic        we,
  input  logic [3:0]  wmask,                // wmask[i] = 1: write byte i of the word
  input  logic [31:0] wdata,                // bytes already in their lane positions
  output logic [31:0] rdata                 // the whole word, one clock later
);
  localparam int AW = $clog2(WORDS);        // index bits: 10 for 1024 words

  logic [31:0]   mem [0:WORDS-1];
  logic [AW-1:0] index;

  assign index = addr[AW+1:2];              // drop the 2 byte-offset bits

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'd0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge clk) begin            // port A
    if (we) begin
      if (wmask[0]) mem[index][ 7: 0] <= wdata[ 7: 0];
      if (wmask[1]) mem[index][15: 8] <= wdata[15: 8];
      if (wmask[2]) mem[index][23:16] <= wdata[23:16];
      if (wmask[3]) mem[index][31:24] <= wdata[31:24];
    end
    rdata <= mem[index];                    // read-first: the word before this edge's write
  end
endmodule
