`timescale 1ns/1ps
// id_stage.sv - Instruction Decode.
// Slices the fixed instruction fields, decodes control signals, reads the
// register file and builds the immediate. The register file's WRITE port is
// driven from wb_stage (rf_we / rf_waddr / rf_wdata), as in the pipeline.
module id_stage
  import riscv_pkg::*;
(
  input  logic        clk,
  input  logic [31:0] instr,
  // register-file write port (from write-back)
  input  logic        rf_we,
  input  logic [4:0]  rf_waddr,
  input  logic [31:0] rf_wdata,
  // decoded fields and operands
  output logic [4:0]  rs1_addr,
  output logic [4:0]  rs2_addr,
  output logic [4:0]  rd_addr,
  output logic [2:0]  funct3,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data,
  output logic [31:0] rs3_data,      // old value of rd (DOT4.S8 accumulator)
  output logic [31:0] imm,
  // control signals
  output logic        reg_write,
  output logic        alu_src_a_pc,
  output logic        alu_src_b_imm,
  output logic [3:0]  alu_op,
  output logic [1:0]  ex_sel,
  output logic        rs3_read,
  output logic        mem_read,
  output logic        mem_write,
  output logic [1:0]  wb_sel,
  output logic        branch,
  output logic        jump,
  output logic        jalr,
  output logic        illegal,
  output logic        system
);
  logic [6:0] opcode;
  logic [6:0] funct7;
  logic [2:0] imm_sel;

  // Fixed field positions (Lesson 6.3): plain wires, no decoding needed.
  assign opcode   = instr[6:0];
  assign rd_addr  = instr[11:7];
  assign funct3   = instr[14:12];
  assign rs1_addr = instr[19:15];
  assign rs2_addr = instr[24:20];
  assign funct7   = instr[31:25];

  control u_ctrl (
    .opcode(opcode), .funct3(funct3), .funct7(funct7), .rs2_addr(rs2_addr),
    .reg_write(reg_write), .alu_src_a_pc(alu_src_a_pc), .alu_src_b_imm(alu_src_b_imm),
    .alu_op(alu_op), .ex_sel(ex_sel), .rs3_read(rs3_read),
    .imm_sel(imm_sel), .mem_read(mem_read), .mem_write(mem_write),
    .wb_sel(wb_sel), .branch(branch), .jump(jump), .jalr(jalr),
    .illegal(illegal), .system(system));

  // The third read port is addressed by the rd field: there is no rs3 field.
  regfile u_rf (
    .clk(clk),
    .rs1_addr(rs1_addr), .rs1_data(rs1_data),
    .rs2_addr(rs2_addr), .rs2_data(rs2_data),
    .rs3_addr(rd_addr),  .rs3_data(rs3_data),
    .we(rf_we), .rd_addr(rf_waddr), .rd_data(rf_wdata));

  imm_gen u_imm (.instr(instr), .imm_sel(imm_sel), .imm(imm));
endmodule
