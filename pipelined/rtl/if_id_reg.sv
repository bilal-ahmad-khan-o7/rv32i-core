`timescale 1ns/1ps
// if_id_reg.sv - the IF/ID pipeline register: the fetched instruction and its PC.
//   write = 0  hold (load-use stall: the instruction in ID decodes again)
//   flush = 1  become a bubble: valid = 0 and the instruction is a nop
//              (a redirect, or fetch stopped after ebreak/ecall)
// Reset also makes a bubble.
module if_id_reg
  import pipeline_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        write,
  input  logic        flush,
  input  logic [31:0] pc,
  input  logic [31:0] pc_plus4,
  input  logic [31:0] instr,
  output logic        if_id_valid,
  output logic [31:0] if_id_pc,
  output logic [31:0] if_id_pc_plus4,
  output logic [31:0] if_id_instr
);
  always_ff @(posedge clk) begin
    if (rst || flush) begin
      if_id_valid <= 1'b0;
      if_id_instr <= NOP;
    end else if (write) begin
      if_id_valid    <= 1'b1;
      if_id_pc       <= pc;
      if_id_pc_plus4 <= pc_plus4;
      if_id_instr    <= instr;
    end
  end
endmodule
