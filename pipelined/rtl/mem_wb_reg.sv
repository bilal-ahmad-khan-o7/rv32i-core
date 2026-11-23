`timescale 1ns/1ps
// mem_wb_reg.sv - the MEM/WB pipeline register: the instruction that is finishing.
// It never stalls or flushes. The core's debug outputs come from here.
module mem_wb_reg (
  input  logic        clk,
  input  logic        rst,
  // from MEM
  input  logic        valid,
  input  logic [31:0] pc,
  input  logic [31:0] pc_plus4,
  input  logic [31:0] instr,
  input  logic [4:0]  rd_addr,
  input  logic [31:0] alu_y,
  input  logic [31:0] ex_result,
  input  logic [31:0] load_data,
  input  logic [31:0] store_data,
  input  logic        reg_write,
  input  logic        mem_write,
  input  logic [1:0]  wb_sel,
  input  logic        illegal,
  input  logic        system,
  // to WB
  output logic        mem_wb_valid,
  output logic [31:0] mem_wb_pc,
  output logic [31:0] mem_wb_pc_plus4,
  output logic [31:0] mem_wb_instr,
  output logic [4:0]  mem_wb_rd_addr,
  output logic [31:0] mem_wb_alu_y,
  output logic [31:0] mem_wb_ex_result,
  output logic [31:0] mem_wb_load_data,
  output logic [31:0] mem_wb_store_data,
  output logic        mem_wb_reg_write,
  output logic        mem_wb_mem_write,
  output logic [1:0]  mem_wb_wb_sel,
  output logic        mem_wb_illegal,
  output logic        mem_wb_system
);
  always_ff @(posedge clk) begin
    if (rst) begin
      mem_wb_valid     <= 1'b0;
      mem_wb_instr     <= 32'h0000_0013;
      mem_wb_rd_addr   <= 5'd0;
      mem_wb_reg_write <= 1'b0;
      mem_wb_mem_write <= 1'b0;
      mem_wb_illegal   <= 1'b0;
      mem_wb_system    <= 1'b0;
    end else begin
      mem_wb_valid      <= valid;
      mem_wb_pc         <= pc;
      mem_wb_pc_plus4   <= pc_plus4;
      mem_wb_instr      <= instr;
      mem_wb_rd_addr    <= rd_addr;
      mem_wb_alu_y      <= alu_y;
      mem_wb_ex_result  <= ex_result;
      mem_wb_load_data  <= load_data;
      mem_wb_store_data <= store_data;
      mem_wb_reg_write  <= reg_write;
      mem_wb_mem_write  <= mem_write;
      mem_wb_wb_sel     <= wb_sel;
      mem_wb_illegal    <= illegal;
      mem_wb_system     <= system;
    end
  end
endmodule
