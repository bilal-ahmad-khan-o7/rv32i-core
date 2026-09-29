`timescale 1ns/1ps
// riscv_core.sv - single-cycle RV32I core (iteration 1).
// Only wiring: the five stage modules connected in one cycle. When this core
// is pipelined, the IF/ID, ID/EX, EX/MEM and MEM/WB registers go on exactly
// these wires; the stage modules themselves do not change.
//
//   IF  -> instr, pc, pc_plus4
//   ID  -> operands, imm, control           (register file read)
//   EX  -> alu_y, pc_redirect/redirect_pc   (back to IF)
//   MEM -> load_data
//   WB  -> wb_data                          (back to ID: register file write)
module riscv_core #(
  parameter logic [31:0] RESET_ADDR = 32'h0000_0000,
  parameter int          IMEM_WORDS = 1024,
  parameter int          DMEM_WORDS = 1024,
  parameter              INIT_FILE  = ""
) (
  input  logic        clk,
  input  logic        rst,
  // debug / testbench observation
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_instr,
  output logic        dbg_illegal,   // unknown opcode
  output logic        dbg_system     // ecall / ebreak: the testbench stops
);
  // ---- IF ----
  logic [31:0] pc, pc_plus4, instr;
  // ---- ID ----
  logic [4:0]  rs1_addr, rs2_addr, rd_addr;
  logic [2:0]  funct3;
  logic [31:0] rs1_data, rs2_data, imm;
  logic        reg_write, alu_src_a_pc, alu_src_b_imm, mem_read, mem_write;
  logic        branch, jump, jalr, illegal, system;
  logic [3:0]  alu_op;
  logic [1:0]  wb_sel;
  // ---- EX ----
  logic [31:0] alu_y, redirect_pc;
  logic        take_branch, pc_redirect;
  // ---- MEM ----
  logic [31:0] load_data;
  // ---- WB ----
  logic [31:0] wb_data;
  // ---- state writes, blocked during reset ----
  logic        rf_we, dmem_we;

  // While rst is high the PC sits at RESET_ADDR and that instruction's
  // combinational result is ready every cycle; without this gate it would
  // write rd / memory once per reset cycle.
  assign rf_we   = reg_write & ~rst;
  assign dmem_we = mem_write & ~rst;

  if_stage #(.RESET_ADDR(RESET_ADDR), .IMEM_WORDS(IMEM_WORDS), .INIT_FILE(INIT_FILE)) u_if (
    .clk(clk), .rst(rst),
    .pc_redirect(pc_redirect), .redirect_pc(redirect_pc),
    .pc(pc), .pc_plus4(pc_plus4), .instr(instr));

  id_stage u_id (
    .clk(clk), .instr(instr),
    .rf_we(rf_we), .rf_waddr(rd_addr), .rf_wdata(wb_data),
    .rs1_addr(rs1_addr), .rs2_addr(rs2_addr), .rd_addr(rd_addr), .funct3(funct3),
    .rs1_data(rs1_data), .rs2_data(rs2_data), .imm(imm),
    .reg_write(reg_write), .alu_src_a_pc(alu_src_a_pc), .alu_src_b_imm(alu_src_b_imm),
    .alu_op(alu_op), .mem_read(mem_read), .mem_write(mem_write), .wb_sel(wb_sel),
    .branch(branch), .jump(jump), .jalr(jalr), .illegal(illegal), .system(system));

  ex_stage u_ex (
    .pc(pc), .rs1_data(rs1_data), .rs2_data(rs2_data), .imm(imm),
    .alu_src_a_pc(alu_src_a_pc), .alu_src_b_imm(alu_src_b_imm), .alu_op(alu_op),
    .funct3(funct3), .branch(branch), .jump(jump), .jalr(jalr),
    .alu_y(alu_y), .take_branch(take_branch),
    .pc_redirect(pc_redirect), .redirect_pc(redirect_pc));

  mem_stage #(.DMEM_WORDS(DMEM_WORDS)) u_mem (
    .clk(clk), .addr(alu_y), .store_data(rs2_data), .funct3(funct3),
    .mem_write(dmem_we), .load_data(load_data));

  wb_stage u_wb (
    .wb_sel(wb_sel), .alu_y(alu_y), .load_data(load_data), .pc_plus4(pc_plus4),
    .wb_data(wb_data));

  assign dbg_pc      = pc;
  assign dbg_instr   = instr;
  assign dbg_illegal = illegal;
  assign dbg_system  = system;
endmodule
