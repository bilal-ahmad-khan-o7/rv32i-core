`timescale 1ns/1ps
// if_stage.sv - Instruction Fetch.
// Holds the PC, reads the instruction, computes pc+4 and picks the next PC.
// ex_stage decides WHETHER to redirect and WHERE (pc_redirect, redirect_pc);
// this stage only chooses between that target and pc+4. In the pipeline the
// same pc_redirect becomes the flush signal.
module if_stage #(
  parameter logic [31:0] RESET_ADDR = 32'h0000_0000,
  parameter int          IMEM_WORDS = 1024,
  parameter              INIT_FILE  = ""
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        pc_redirect,   // from ex_stage: taken branch, jal or jalr
  input  logic [31:0] redirect_pc,   // from ex_stage: the target address
  output logic [31:0] pc,
  output logic [31:0] pc_plus4,
  output logic [31:0] instr
);
  logic [31:0] next_pc;

  assign pc_plus4 = pc + 32'd4;
  assign next_pc  = pc_redirect ? redirect_pc : pc_plus4;   // next-PC mux

  pc_reg #(.RESET_ADDR(RESET_ADDR)) u_pc (
    .clk(clk), .rst(rst), .next_pc(next_pc), .pc(pc));

  imem #(.WORDS(IMEM_WORDS), .INIT_FILE(INIT_FILE)) u_imem (
    .addr(pc), .instr(instr));
endmodule
