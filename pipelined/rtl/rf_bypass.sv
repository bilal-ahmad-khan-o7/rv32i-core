`timescale 1ns/1ps
// rf_bypass.sv - the register file's write-back bypass, in front of its three read ports.
// The instruction in WB writes rd at the end of this cycle, but the instruction in ID
// reads its registers during this cycle: from the register file it would get the OLD
// value. If they are the same register, pass the value being written instead.
// (Forwarding covers the two instructions ahead of EX; this covers the third.)
//
// It sits outside regfile.sv, so the register file and its testbench stay as in the
// single-cycle core, where a same-cycle read must return the old value (DOT4.S8 reads
// and writes rd in one cycle there).
module rf_bypass (
  // the registers ID reads
  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  input  logic [4:0]  rs3_addr,            // the rd field
  input  logic [31:0] rf_rs1_data,         // as the register file returns them
  input  logic [31:0] rf_rs2_data,
  input  logic [31:0] rf_rs3_data,
  // the write in WB
  input  logic        wb_we,
  input  logic [4:0]  wb_rd_addr,
  input  logic [31:0] wb_data,
  // the values ID passes on
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data,
  output logic [31:0] rs3_data
);
  assign rs1_data = (wb_we && wb_rd_addr != 5'd0 && wb_rd_addr == rs1_addr) ? wb_data : rf_rs1_data;
  assign rs2_data = (wb_we && wb_rd_addr != 5'd0 && wb_rd_addr == rs2_addr) ? wb_data : rf_rs2_data;
  assign rs3_data = (wb_we && wb_rd_addr != 5'd0 && wb_rd_addr == rs3_addr) ? wb_data : rf_rs3_data;
endmodule
