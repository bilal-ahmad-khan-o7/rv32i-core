`timescale 1ns/1ps
// riscv_core.sv - 5-stage pipelined RV32I core (+ Zmmul and the custom INT8 instructions).
// The stage modules of the single-cycle core, with the IF/ID, ID/EX, EX/MEM and MEM/WB
// registers on the wires between them. Same parameters and ports as the single-cycle
// riscv_core; the debug outputs describe the instruction finishing in WB.
//
// Hazards (hazard_unit, forward_unit, rf_bypass):
//   forwarding   EX/MEM -> EX and MEM/WB -> EX, for rs1, rs2 and rs3
//   bypass       a register written in WB is read correctly in ID the same cycle
//   load-use     one stall cycle when ID needs the value a load in EX is fetching
//   redirect     a taken branch, jal or jalr is decided in EX; the two instructions
//                behind it are flushed (2 cycles lost), with no prediction
//   fetch stop   nothing behind ebreak / ecall / an illegal word runs
module riscv_core
  import riscv_pkg::*;
  import pipeline_pkg::*;
#(
  parameter logic [31:0] RESET_ADDR = 32'h0000_0000,
  parameter int          IMEM_WORDS = 1024,
  parameter int          DMEM_WORDS = 1024,
  parameter              INIT_FILE  = "",        // program (imem)
  parameter              DMEM_INIT_FILE = ""     // data preload (dmem); "" = all zero
) (
  input  logic        clk,
  input  logic        rst,
  // debug / testbench observation: the instruction in WB
  output logic [31:0] dbg_pc,
  output logic [31:0] dbg_instr,
  output logic        dbg_illegal,   // undefined encoding
  output logic        dbg_system,    // ecall / ebreak: the testbench stops
  // the store this instruction made, for a board wrapper (e.g. the KWS label on LEDs)
  output logic        dbg_mem_we,    // 1: a store to data memory
  output logic [31:0] dbg_mem_addr,  // its byte address
  output logic [31:0] dbg_mem_wdata  // the rs2 value stored (sb/sh store its low 8/16 bits)
);
  // ======================= IF ===========================================
  logic [31:0] pc, pc_plus4, instr;
  logic        hold;                             // keep fetching the same PC

  // ======================= IF/ID ========================================
  logic        if_id_valid;
  logic [31:0] if_id_pc, if_id_pc_plus4, if_id_instr;
  logic        if_id_write, if_id_flush;

  // ======================= ID ===========================================
  logic [4:0]  rs1_addr, rs2_addr, rd_addr;
  logic [2:0]  funct3;
  logic [31:0] rf_rs1_data, rf_rs2_data, rf_rs3_data;  // as the register file returns them
  logic [31:0] rs1_data, rs2_data, rs3_data, imm;      // after the write-back bypass
  logic        reg_write, alu_src_a_pc, alu_src_b_imm, mem_read, mem_write;
  logic        branch, jump, jalr, illegal, system, rs3_read;
  logic [3:0]  alu_op;
  logic [1:0]  wb_sel, ex_sel;

  // ======================= ID/EX ========================================
  logic        id_ex_valid, id_ex_flush;
  logic [31:0] id_ex_pc, id_ex_pc_plus4, id_ex_instr;
  logic [4:0]  id_ex_rs1_addr, id_ex_rs2_addr, id_ex_rd_addr;
  logic [2:0]  id_ex_funct3;
  logic [31:0] id_ex_rs1_data, id_ex_rs2_data, id_ex_rs3_data, id_ex_imm;
  logic        id_ex_reg_write, id_ex_alu_src_a_pc, id_ex_alu_src_b_imm, id_ex_rs3_read;
  logic        id_ex_mem_read, id_ex_mem_write, id_ex_branch, id_ex_jump, id_ex_jalr;
  logic        id_ex_illegal, id_ex_system;
  logic [3:0]  id_ex_alu_op;
  logic [1:0]  id_ex_ex_sel, id_ex_wb_sel;

  // ======================= EX ===========================================
  logic [31:0] ex_rs1, ex_rs2, ex_rs3;            // the operands ex_stage uses, after forwarding
  logic [31:0] ex_mem_value;                      // what the instruction in EX/MEM will write
  logic [1:0]  forward_a, forward_b, forward_c;
  logic [31:0] alu_y, ex_result, redirect_pc;
  logic        take_branch, pc_redirect, ex_mem_write;

  // ======================= EX/MEM =======================================
  logic        ex_mem_valid;
  logic [31:0] ex_mem_pc, ex_mem_pc_plus4, ex_mem_instr, ex_mem_alu_y, ex_mem_ex_result;
  logic [31:0] ex_mem_store_data;
  logic [4:0]  ex_mem_rd_addr;
  logic [2:0]  ex_mem_funct3;
  logic        ex_mem_reg_write, ex_mem_mem_write, ex_mem_illegal, ex_mem_system;
  logic [1:0]  ex_mem_wb_sel;

  // ======================= MEM ==========================================
  logic [31:0] load_data;

  // ======================= MEM/WB =======================================
  logic        mem_wb_valid;
  logic [31:0] mem_wb_pc, mem_wb_pc_plus4, mem_wb_instr, mem_wb_alu_y, mem_wb_ex_result;
  logic [31:0] mem_wb_load_data, mem_wb_store_data;
  logic [4:0]  mem_wb_rd_addr;
  logic        mem_wb_reg_write, mem_wb_mem_write, mem_wb_illegal, mem_wb_system;
  logic [1:0]  mem_wb_wb_sel;

  // ======================= WB ===========================================
  logic [31:0] wb_data;
  logic        rf_we;

  // ---- hazard control -----------------------------------------------------
  logic stall, flush;                            // load-use stall; redirect (the testbench counts both)

  hazard_unit u_hazard (
    .clk(clk), .rst(rst),
    .if_id_valid(if_id_valid), .if_id_rs1_addr(rs1_addr), .if_id_rs2_addr(rs2_addr),
    .if_id_rd_addr(rd_addr), .id_rs3_read(rs3_read), .id_system(system), .id_illegal(illegal),
    .id_ex_mem_read(id_ex_mem_read), .id_ex_rd_addr(id_ex_rd_addr),
    .ex_redirect(id_ex_valid & pc_redirect),
    .stall(stall), .flush(flush), .pc_hold(hold),
    .if_id_write(if_id_write), .if_id_flush(if_id_flush), .id_ex_flush(id_ex_flush));

  // ---- IF ----------------------------------------------------------------
  if_stage #(.RESET_ADDR(RESET_ADDR), .IMEM_WORDS(IMEM_WORDS), .INIT_FILE(INIT_FILE)) u_if (
    .clk(clk), .rst(rst), .hold(hold),
    .pc_redirect(flush), .redirect_pc(redirect_pc),
    .pc(pc), .pc_plus4(pc_plus4), .instr(instr));

  if_id_reg u_if_id (
    .clk(clk), .rst(rst), .write(if_id_write), .flush(if_id_flush),
    .pc(pc), .pc_plus4(pc_plus4), .instr(instr),
    .if_id_valid(if_id_valid), .if_id_pc(if_id_pc), .if_id_pc_plus4(if_id_pc_plus4),
    .if_id_instr(if_id_instr));

  // ---- ID: the register file is written from WB ---------------------------
  id_stage u_id (
    .clk(clk), .instr(if_id_instr),
    .rf_we(rf_we), .rf_waddr(mem_wb_rd_addr), .rf_wdata(wb_data),
    .rs1_addr(rs1_addr), .rs2_addr(rs2_addr), .rd_addr(rd_addr), .funct3(funct3),
    .rs1_data(rf_rs1_data), .rs2_data(rf_rs2_data), .rs3_data(rf_rs3_data), .imm(imm),
    .reg_write(reg_write), .alu_src_a_pc(alu_src_a_pc), .alu_src_b_imm(alu_src_b_imm),
    .alu_op(alu_op), .ex_sel(ex_sel), .rs3_read(rs3_read),
    .mem_read(mem_read), .mem_write(mem_write), .wb_sel(wb_sel),
    .branch(branch), .jump(jump), .jalr(jalr), .illegal(illegal), .system(system));

  rf_bypass u_bypass (
    .rs1_addr(rs1_addr), .rs2_addr(rs2_addr), .rs3_addr(rd_addr),
    .rf_rs1_data(rf_rs1_data), .rf_rs2_data(rf_rs2_data), .rf_rs3_data(rf_rs3_data),
    .wb_we(rf_we), .wb_rd_addr(mem_wb_rd_addr), .wb_data(wb_data),
    .rs1_data(rs1_data), .rs2_data(rs2_data), .rs3_data(rs3_data));

  id_ex_reg u_id_ex (
    .clk(clk), .rst(rst), .flush(id_ex_flush),
    .valid(if_id_valid), .pc(if_id_pc), .pc_plus4(if_id_pc_plus4), .instr(if_id_instr),
    .rs1_addr(rs1_addr), .rs2_addr(rs2_addr), .rd_addr(rd_addr), .funct3(funct3),
    .rs1_data(rs1_data), .rs2_data(rs2_data), .rs3_data(rs3_data), .imm(imm),
    .reg_write(reg_write), .alu_src_a_pc(alu_src_a_pc), .alu_src_b_imm(alu_src_b_imm),
    .alu_op(alu_op), .ex_sel(ex_sel), .rs3_read(rs3_read),
    .mem_read(mem_read), .mem_write(mem_write), .wb_sel(wb_sel),
    .branch(branch), .jump(jump), .jalr(jalr), .illegal(illegal), .system(system),
    .id_ex_valid(id_ex_valid), .id_ex_pc(id_ex_pc), .id_ex_pc_plus4(id_ex_pc_plus4),
    .id_ex_instr(id_ex_instr), .id_ex_rs1_addr(id_ex_rs1_addr), .id_ex_rs2_addr(id_ex_rs2_addr),
    .id_ex_rd_addr(id_ex_rd_addr), .id_ex_funct3(id_ex_funct3),
    .id_ex_rs1_data(id_ex_rs1_data), .id_ex_rs2_data(id_ex_rs2_data),
    .id_ex_rs3_data(id_ex_rs3_data), .id_ex_imm(id_ex_imm),
    .id_ex_reg_write(id_ex_reg_write), .id_ex_alu_src_a_pc(id_ex_alu_src_a_pc),
    .id_ex_alu_src_b_imm(id_ex_alu_src_b_imm), .id_ex_alu_op(id_ex_alu_op),
    .id_ex_ex_sel(id_ex_ex_sel), .id_ex_rs3_read(id_ex_rs3_read),
    .id_ex_mem_read(id_ex_mem_read), .id_ex_mem_write(id_ex_mem_write),
    .id_ex_wb_sel(id_ex_wb_sel), .id_ex_branch(id_ex_branch), .id_ex_jump(id_ex_jump),
    .id_ex_jalr(id_ex_jalr), .id_ex_illegal(id_ex_illegal), .id_ex_system(id_ex_system));

  // ---- EX ------------------------------------------------------------------
  forward_unit u_forward (
    .id_ex_rs1_addr(id_ex_rs1_addr), .id_ex_rs2_addr(id_ex_rs2_addr), .id_ex_rd_addr(id_ex_rd_addr),
    .ex_mem_reg_write(ex_mem_reg_write), .ex_mem_rd_addr(ex_mem_rd_addr),
    .mem_wb_reg_write(mem_wb_reg_write), .mem_wb_rd_addr(mem_wb_rd_addr),
    .forward_a(forward_a), .forward_b(forward_b), .forward_c(forward_c));

  // jal / jalr write pc+4, everything else that EX/MEM can forward writes ex_result
  // (a load's value is not ready yet: the load-use stall keeps anyone from needing it)
  assign ex_mem_value = (ex_mem_wb_sel == WB_PC4) ? ex_mem_pc_plus4 : ex_mem_ex_result;

  always_comb begin                               // forwarding muxes
    case (forward_a)
      FWD_EX_MEM: ex_rs1 = ex_mem_value;
      FWD_MEM_WB: ex_rs1 = wb_data;
      default:    ex_rs1 = id_ex_rs1_data;
    endcase
    case (forward_b)
      FWD_EX_MEM: ex_rs2 = ex_mem_value;
      FWD_MEM_WB: ex_rs2 = wb_data;
      default:    ex_rs2 = id_ex_rs2_data;
    endcase
    case (forward_c)
      FWD_EX_MEM: ex_rs3 = ex_mem_value;
      FWD_MEM_WB: ex_rs3 = wb_data;
      default:    ex_rs3 = id_ex_rs3_data;
    endcase
  end

  ex_stage u_ex (
    .pc(id_ex_pc), .rs1_data(ex_rs1), .rs2_data(ex_rs2), .rs3_data(ex_rs3), .imm(id_ex_imm),
    .alu_src_a_pc(id_ex_alu_src_a_pc), .alu_src_b_imm(id_ex_alu_src_b_imm),
    .alu_op(id_ex_alu_op), .ex_sel(id_ex_ex_sel), .funct3(id_ex_funct3),
    .branch(id_ex_branch), .jump(id_ex_jump), .jalr(id_ex_jalr),
    .alu_y(alu_y), .ex_result(ex_result), .take_branch(take_branch),
    .pc_redirect(pc_redirect), .redirect_pc(redirect_pc));

  // The store is made at the end of EX; reset blocks it, as in the single-cycle core.
  assign ex_mem_write = id_ex_mem_write & ~rst;

  ex_mem_reg u_ex_mem (
    .clk(clk), .rst(rst),
    .valid(id_ex_valid), .pc(id_ex_pc), .pc_plus4(id_ex_pc_plus4), .instr(id_ex_instr),
    .rd_addr(id_ex_rd_addr), .funct3(id_ex_funct3), .alu_y(alu_y), .ex_result(ex_result),
    .store_data(ex_rs2), .reg_write(id_ex_reg_write), .mem_write(id_ex_mem_write),
    .wb_sel(id_ex_wb_sel), .illegal(id_ex_illegal), .system(id_ex_system),
    .ex_mem_valid(ex_mem_valid), .ex_mem_pc(ex_mem_pc), .ex_mem_pc_plus4(ex_mem_pc_plus4),
    .ex_mem_instr(ex_mem_instr), .ex_mem_rd_addr(ex_mem_rd_addr), .ex_mem_funct3(ex_mem_funct3),
    .ex_mem_alu_y(ex_mem_alu_y), .ex_mem_ex_result(ex_mem_ex_result),
    .ex_mem_store_data(ex_mem_store_data), .ex_mem_reg_write(ex_mem_reg_write),
    .ex_mem_mem_write(ex_mem_mem_write), .ex_mem_wb_sel(ex_mem_wb_sel),
    .ex_mem_illegal(ex_mem_illegal), .ex_mem_system(ex_mem_system));

  // ---- MEM: issued from EX, completed here -------------------------------
  mem_stage #(.DMEM_WORDS(DMEM_WORDS), .DMEM_INIT_FILE(DMEM_INIT_FILE)) u_mem (
    .clk(clk),
    .ex_addr(alu_y), .ex_store_data(ex_rs2), .ex_funct3(id_ex_funct3), .ex_mem_write(ex_mem_write),
    .mem_addr_lo(ex_mem_alu_y[1:0]), .mem_funct3(ex_mem_funct3), .load_data(load_data));

  mem_wb_reg u_mem_wb (
    .clk(clk), .rst(rst),
    .valid(ex_mem_valid), .pc(ex_mem_pc), .pc_plus4(ex_mem_pc_plus4), .instr(ex_mem_instr),
    .rd_addr(ex_mem_rd_addr), .alu_y(ex_mem_alu_y), .ex_result(ex_mem_ex_result),
    .load_data(load_data), .store_data(ex_mem_store_data), .reg_write(ex_mem_reg_write),
    .mem_write(ex_mem_mem_write), .wb_sel(ex_mem_wb_sel), .illegal(ex_mem_illegal),
    .system(ex_mem_system),
    .mem_wb_valid(mem_wb_valid), .mem_wb_pc(mem_wb_pc), .mem_wb_pc_plus4(mem_wb_pc_plus4),
    .mem_wb_instr(mem_wb_instr), .mem_wb_rd_addr(mem_wb_rd_addr), .mem_wb_alu_y(mem_wb_alu_y),
    .mem_wb_ex_result(mem_wb_ex_result), .mem_wb_load_data(mem_wb_load_data),
    .mem_wb_store_data(mem_wb_store_data), .mem_wb_reg_write(mem_wb_reg_write),
    .mem_wb_mem_write(mem_wb_mem_write), .mem_wb_wb_sel(mem_wb_wb_sel),
    .mem_wb_illegal(mem_wb_illegal), .mem_wb_system(mem_wb_system));

  // ---- WB --------------------------------------------------------------------
  wb_stage u_wb (
    .wb_sel(mem_wb_wb_sel), .ex_result(mem_wb_ex_result), .load_data(mem_wb_load_data),
    .pc_plus4(mem_wb_pc_plus4), .wb_data(wb_data));

  assign rf_we = mem_wb_reg_write & ~rst;

  // ---- debug: the instruction finishing in WB ---------------------------------
  assign dbg_pc        = mem_wb_pc;
  assign dbg_instr     = mem_wb_instr;
  assign dbg_illegal   = mem_wb_valid & mem_wb_illegal;
  assign dbg_system    = mem_wb_valid & mem_wb_system;
  assign dbg_mem_we    = mem_wb_valid & mem_wb_mem_write;
  assign dbg_mem_addr  = mem_wb_alu_y;
  assign dbg_mem_wdata = mem_wb_store_data;
endmodule
