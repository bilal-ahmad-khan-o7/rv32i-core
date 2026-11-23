`timescale 1ns/1ps
// riscv_core.sv - single-cycle RV32I core (+ Zmmul and the custom INT8 instructions).
// Only wiring: the five stage modules connected in one cycle. When this core
// is pipelined, the IF/ID, ID/EX, EX/MEM and MEM/WB registers go on exactly
// these wires; the stage modules themselves do not change.
//
//   IF  -> instr, pc, pc_plus4
//   ID  -> operands, imm, control           (register file read)
//   EX  -> alu_y (address), ex_result, pc_redirect/redirect_pc (back to IF)
//   MEM -> load_data
//   WB  -> wb_data                          (back to ID: register file write)
module riscv_core #(
  parameter logic [31:0] RESET_ADDR = 32'h0000_0000,
  parameter int          IMEM_WORDS = 1024,
  parameter int          DMEM_WORDS = 1024,
  parameter              INIT_FILE  = "",        // program (imem)
  parameter              DMEM_INIT_FILE = ""     // data preload (dmem); "" = all zero
) (
  input  logic        clk,
  input  logic        rst,
  // debug / testbench observation
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_instr,
  output logic        dbg_illegal,   // undefined encoding
  output logic        dbg_system,    // ecall / ebreak: the testbench stops
  // the store this instruction makes, for a board wrapper (e.g. the KWS label on LEDs)
  output logic        dbg_mem_we,    // 1: a store to data memory
  output logic [31:0] dbg_mem_addr,  // its byte address
  output logic [31:0] dbg_mem_wdata  // the rs2 value stored (sb/sh store its low 8/16 bits)
);
  // ---- IF ----
  logic [31:0] pc, pc_plus4, instr;
  // ---- ID ----
  logic [4:0]  rs1_addr, rs2_addr, rd_addr;
  logic [2:0]  funct3;
  logic [31:0] rs1_data, rs2_data, rs3_data, imm;
  logic        reg_write, alu_src_a_pc, alu_src_b_imm, mem_read, mem_write;
  logic        branch, jump, jalr, illegal, system;
  logic        rs3_read;                       // for the pipeline's hazard check; unused here
  logic [3:0]  alu_op;
  logic [1:0]  wb_sel, ex_sel;
  // ---- EX ----
  logic [31:0] alu_y, ex_result, redirect_pc;
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
    .rs1_data(rs1_data), .rs2_data(rs2_data), .rs3_data(rs3_data), .imm(imm),
    .reg_write(reg_write), .alu_src_a_pc(alu_src_a_pc), .alu_src_b_imm(alu_src_b_imm),
    .alu_op(alu_op), .ex_sel(ex_sel), .rs3_read(rs3_read),
    .mem_read(mem_read), .mem_write(mem_write), .wb_sel(wb_sel),
    .branch(branch), .jump(jump), .jalr(jalr), .illegal(illegal), .system(system));

  ex_stage u_ex (
    .pc(pc), .rs1_data(rs1_data), .rs2_data(rs2_data), .rs3_data(rs3_data), .imm(imm),
    .alu_src_a_pc(alu_src_a_pc), .alu_src_b_imm(alu_src_b_imm), .alu_op(alu_op), .ex_sel(ex_sel),
    .funct3(funct3), .branch(branch), .jump(jump), .jalr(jalr),
    .alu_y(alu_y), .ex_result(ex_result), .take_branch(take_branch),
    .pc_redirect(pc_redirect), .redirect_pc(redirect_pc));

  mem_stage #(.DMEM_WORDS(DMEM_WORDS), .DMEM_INIT_FILE(DMEM_INIT_FILE)) u_mem (
    .clk(clk), .addr(alu_y), .store_data(rs2_data), .funct3(funct3),
    .mem_write(dmem_we), .load_data(load_data));

  wb_stage u_wb (
    .wb_sel(wb_sel), .ex_result(ex_result), .load_data(load_data), .pc_plus4(pc_plus4),
    .wb_data(wb_data));

  assign dbg_pc      = pc;
  assign dbg_instr   = instr;
  assign dbg_illegal = illegal;
  assign dbg_system  = system;
  assign dbg_mem_we    = dmem_we;
  assign dbg_mem_addr  = alu_y;
  assign dbg_mem_wdata = rs2_data;
endmodule
