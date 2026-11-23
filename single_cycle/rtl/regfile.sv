`timescale 1ns/1ps
// regfile.sv - 32 x 32-bit register file: three combinational read ports,
// one clocked write port (PDF Lesson 5.4.5, Listing 5.3, plus a third read
// port for DOT4.S8, which reads its accumulator rd as a source).
// x0 is protected twice: never written, and forced to 0 on read.
// Initialised with `initial` (not reset) so the FPGA tool can use LUTRAM.
module regfile (
  input  logic        clk,
  input  logic [4:0]  rs1_addr,
  output logic [31:0] rs1_data,
  input  logic [4:0]  rs2_addr,
  output logic [31:0] rs2_data,
  input  logic [4:0]  rs3_addr,      // third source: the rd field (instr[11:7])
  output logic [31:0] rs3_data,
  input  logic        we,
  input  logic [4:0]  rd_addr,
  input  logic [31:0] rd_data
);
  logic [31:0] regs [0:31];

  initial begin
    for (int i = 0; i < 32; i++) regs[i] = 32'd0;
  end

  always_ff @(posedge clk) begin
    if (we && rd_addr != 5'd0)
      regs[rd_addr] <= rd_data;
  end

  // Same-cycle read of a register being written returns the OLD value:
  // the read is combinational during the cycle, the write lands at the edge.
  assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
  assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];
  assign rs3_data = (rs3_addr == 5'd0) ? 32'd0 : regs[rs3_addr];
endmodule
