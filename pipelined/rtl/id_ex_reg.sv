`timescale 1ns/1ps
// id_ex_reg.sv - the ID/EX pipeline register: everything ex_stage needs, plus what
// later stages need (rd, wb_sel, pc_plus4, ...).
//   flush = 1  become a bubble (a redirect, or the load-use stall)
// Every control signal that could change state is ANDed with `valid` on the way in,
// so a bubble writes no register, touches no memory and redirects nothing.
module id_ex_reg (
  input  logic        clk,
  input  logic        rst,
  input  logic        flush,
  // from ID
  input  logic        valid,
  input  logic [31:0] pc,
  input  logic [31:0] pc_plus4,
  input  logic [31:0] instr,
  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  input  logic [4:0]  rd_addr,        // also rs3's address (DOT4.S8 accumulator)
  input  logic [2:0]  funct3,
  input  logic [31:0] rs1_data,
  input  logic [31:0] rs2_data,
  input  logic [31:0] rs3_data,
  input  logic [31:0] imm,
  input  logic        reg_write,
  input  logic        alu_src_a_pc,
  input  logic        alu_src_b_imm,
  input  logic [3:0]  alu_op,
  input  logic [1:0]  ex_sel,
  input  logic        rs3_read,
  input  logic        mem_read,
  input  logic        mem_write,
  input  logic [1:0]  wb_sel,
  input  logic        branch,
  input  logic        jump,
  input  logic        jalr,
  input  logic        illegal,
  input  logic        system,
  // to EX
  output logic        id_ex_valid,
  output logic [31:0] id_ex_pc,
  output logic [31:0] id_ex_pc_plus4,
  output logic [31:0] id_ex_instr,
  output logic [4:0]  id_ex_rs1_addr,
  output logic [4:0]  id_ex_rs2_addr,
  output logic [4:0]  id_ex_rd_addr,
  output logic [2:0]  id_ex_funct3,
  output logic [31:0] id_ex_rs1_data,
  output logic [31:0] id_ex_rs2_data,
  output logic [31:0] id_ex_rs3_data,
  output logic [31:0] id_ex_imm,
  output logic        id_ex_reg_write,
  output logic        id_ex_alu_src_a_pc,
  output logic        id_ex_alu_src_b_imm,
  output logic [3:0]  id_ex_alu_op,
  output logic [1:0]  id_ex_ex_sel,
  output logic        id_ex_rs3_read,
  output logic        id_ex_mem_read,
  output logic        id_ex_mem_write,
  output logic [1:0]  id_ex_wb_sel,
  output logic        id_ex_branch,
  output logic        id_ex_jump,
  output logic        id_ex_jalr,
  output logic        id_ex_illegal,
  output logic        id_ex_system
);
  always_ff @(posedge clk) begin
    if (rst || flush) begin                  // bubble
      id_ex_valid     <= 1'b0;
      id_ex_instr     <= 32'h0000_0013;
      id_ex_rd_addr   <= 5'd0;
      id_ex_reg_write <= 1'b0;
      id_ex_rs3_read  <= 1'b0;
      id_ex_mem_read  <= 1'b0;
      id_ex_mem_write <= 1'b0;
      id_ex_branch    <= 1'b0;
      id_ex_jump      <= 1'b0;
      id_ex_jalr      <= 1'b0;
      id_ex_illegal   <= 1'b0;
      id_ex_system    <= 1'b0;
    end else begin
      id_ex_valid         <= valid;
      id_ex_pc            <= pc;
      id_ex_pc_plus4      <= pc_plus4;
      id_ex_instr         <= instr;
      id_ex_rs1_addr      <= rs1_addr;
      id_ex_rs2_addr      <= rs2_addr;
      id_ex_rd_addr       <= rd_addr;
      id_ex_funct3        <= funct3;
      id_ex_rs1_data      <= rs1_data;
      id_ex_rs2_data      <= rs2_data;
      id_ex_rs3_data      <= rs3_data;
      id_ex_imm           <= imm;
      id_ex_alu_src_a_pc  <= alu_src_a_pc;
      id_ex_alu_src_b_imm <= alu_src_b_imm;
      id_ex_alu_op        <= alu_op;
      id_ex_ex_sel        <= ex_sel;
      id_ex_wb_sel        <= wb_sel;
      id_ex_reg_write     <= valid & reg_write;
      id_ex_rs3_read      <= valid & rs3_read;
      id_ex_mem_read      <= valid & mem_read;
      id_ex_mem_write     <= valid & mem_write;
      id_ex_branch        <= valid & branch;
      id_ex_jump          <= valid & jump;
      id_ex_jalr          <= valid & jalr;
      id_ex_illegal       <= valid & illegal;
      id_ex_system        <= valid & system;
    end
  end
endmodule
