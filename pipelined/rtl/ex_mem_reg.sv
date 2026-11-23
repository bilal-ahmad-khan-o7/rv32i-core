`timescale 1ns/1ps
// ex_mem_reg.sv - the EX/MEM pipeline register. It never stalls or flushes: whatever
// is in EX moves on. Its address half is inside the data memory (see mem_stage.sv);
// alu_y is kept here too, for the load's byte select (alu_y[1:0]) and the debug port.
module ex_mem_reg (
  input  logic        clk,
  input  logic        rst,
  // from EX
  input  logic        valid,
  input  logic [31:0] pc,
  input  logic [31:0] pc_plus4,
  input  logic [31:0] instr,
  input  logic [4:0]  rd_addr,
  input  logic [2:0]  funct3,
  input  logic [31:0] alu_y,          // the load/store address
  input  logic [31:0] ex_result,
  input  logic [31:0] store_data,     // rs2 after forwarding: for the debug port only
  input  logic        reg_write,
  input  logic        mem_write,
  input  logic [1:0]  wb_sel,
  input  logic        illegal,
  input  logic        system,
  // to MEM
  output logic        ex_mem_valid,
  output logic [31:0] ex_mem_pc,
  output logic [31:0] ex_mem_pc_plus4,
  output logic [31:0] ex_mem_instr,
  output logic [4:0]  ex_mem_rd_addr,
  output logic [2:0]  ex_mem_funct3,
  output logic [31:0] ex_mem_alu_y,
  output logic [31:0] ex_mem_ex_result,
  output logic [31:0] ex_mem_store_data,
  output logic        ex_mem_reg_write,
  output logic        ex_mem_mem_write,
  output logic [1:0]  ex_mem_wb_sel,
  output logic        ex_mem_illegal,
  output logic        ex_mem_system
);
  always_ff @(posedge clk) begin
    if (rst) begin
      ex_mem_valid     <= 1'b0;
      ex_mem_instr     <= 32'h0000_0013;
      ex_mem_rd_addr   <= 5'd0;
      ex_mem_reg_write <= 1'b0;
      ex_mem_mem_write <= 1'b0;
      ex_mem_illegal   <= 1'b0;
      ex_mem_system    <= 1'b0;
    end else begin
      ex_mem_valid      <= valid;
      ex_mem_pc         <= pc;
      ex_mem_pc_plus4   <= pc_plus4;
      ex_mem_instr      <= instr;
      ex_mem_rd_addr    <= rd_addr;
      ex_mem_funct3     <= funct3;
      ex_mem_alu_y      <= alu_y;
      ex_mem_ex_result  <= ex_result;
      ex_mem_store_data <= store_data;
      ex_mem_reg_write  <= reg_write;
      ex_mem_mem_write  <= mem_write;
      ex_mem_wb_sel     <= wb_sel;
      ex_mem_illegal    <= illegal;
      ex_mem_system     <= system;
    end
  end
endmodule
