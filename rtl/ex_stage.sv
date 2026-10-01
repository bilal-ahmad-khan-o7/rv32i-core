`timescale 1ns/1ps
// ex_stage.sv - Execute.
// Operand muxes, ALU, branch condition, and the redirect decision.
// Three adders work in parallel: the ALU, pc+imm here, and pc+4 in if_stage
// (Lesson 8.4 trade-off). jalr reuses the ALU's rs1+imm for its target.
module ex_stage (
  input  logic [31:0] pc,
  input  logic [31:0] rs1_data,
  input  logic [31:0] rs2_data,
  input  logic [31:0] imm,
  input  logic        alu_src_a_pc,
  input  logic        alu_src_b_imm,
  input  logic [3:0]  alu_op,
  input  logic [2:0]  funct3,
  input  logic        branch,
  input  logic        jump,
  input  logic        jalr,
  output logic [31:0] alu_y,
  output logic        take_branch,
  output logic        pc_redirect,     // to if_stage: leave the pc+4 path
  output logic [31:0] redirect_pc      // to if_stage: where to go
);
  logic [31:0] alu_a, alu_b;
  logic [31:0] pc_target, jalr_target;

  assign alu_a = alu_src_a_pc  ? pc  : rs1_data;   // mux A
  assign alu_b = alu_src_b_imm ? imm : rs2_data;   // mux B

  alu u_alu (.a(alu_a), .b(alu_b), .alu_op(alu_op), .y(alu_y));

  branch_unit u_br (
    .rs1_data(rs1_data), .rs2_data(rs2_data), .funct3(funct3),
    .take_branch(take_branch));

  assign pc_target   = pc + imm;                   // branch and jal targets
  assign jalr_target = {alu_y[31:1], 1'b0};        // rs1 + imm, bit 0 cleared

  // jalr is checked first; take_branch only counts when branch is 1.
  assign pc_redirect = jalr | jump | (branch & take_branch);
  assign redirect_pc = jalr ? jalr_target : pc_target;
endmodule
