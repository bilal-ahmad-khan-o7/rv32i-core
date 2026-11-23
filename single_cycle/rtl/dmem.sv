`timescale 1ns/1ps
// dmem.sv - data memory: word array, combinational read, clocked write with a
// 4-bit byte write mask.
// Lane shifting and mask generation happen outside, in lsu.sv.
// Zero-filled, then optionally preloaded from INIT_FILE (one 32-bit hex word
// per line, like imem) - e.g. NN weights and inputs. The path is relative to
// the directory vvp runs in.
module dmem #(
  parameter int WORDS     = 1024,           // 1024 words = 4 KiB
  parameter     INIT_FILE = ""              // hex file; "" leaves all zero
) (
  input  logic        clk,
  input  logic [31:0] addr,                 // byte address
  output logic [31:0] rdata,                // the whole word containing addr
  input  logic        we,
  input  logic [3:0]  wmask,                // wmask[i] = 1: write byte i of the word
  input  logic [31:0] wdata                 // bytes already in their lane positions
);
  localparam int AW = $clog2(WORDS);        // index bits: 10 for 1024 words

  logic [31:0]   mem [0:WORDS-1];
  logic [AW-1:0] index;

  assign index = addr[AW+1:2];              // drop the 2 byte-offset bits

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'd0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge clk) begin
    if (we) begin
      if (wmask[0]) mem[index][ 7: 0] <= wdata[ 7: 0];
      if (wmask[1]) mem[index][15: 8] <= wdata[15: 8];
      if (wmask[2]) mem[index][23:16] <= wdata[23:16];
      if (wmask[3]) mem[index][31:24] <= wdata[31:24];
    end
  end

  assign rdata = mem[index];
endmodule
