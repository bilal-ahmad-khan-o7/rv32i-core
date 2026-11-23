`timescale 1ns/1ps
// mem_stage.sv - Memory access.
// The LSU shifts store data into its byte lane and builds the write mask;
// data memory reads the whole word every cycle; the LSU then selects and
// extends the loaded lane.
module mem_stage #(
  parameter int DMEM_WORDS     = 1024,
  parameter     DMEM_INIT_FILE = ""          // optional data-memory preload
) (
  input  logic        clk,
  input  logic [31:0] addr,          // alu_y: rs1 + imm
  input  logic [31:0] store_data,    // rs2
  input  logic [2:0]  funct3,        // access size and signedness
  input  logic        mem_write,
  output logic [31:0] load_data
);
  logic [31:0] mem_wdata, mem_rdata;
  logic [3:0]  mem_wmask;

  lsu u_lsu (
    .funct3(funct3), .addr_lo(addr[1:0]),
    .store_data(store_data), .mem_wdata(mem_wdata), .mem_wmask(mem_wmask),
    .mem_rdata(mem_rdata), .load_data(load_data));

  dmem #(.WORDS(DMEM_WORDS), .INIT_FILE(DMEM_INIT_FILE)) u_dmem (
    .clk(clk), .addr(addr), .rdata(mem_rdata),
    .we(mem_write), .wmask(mem_wmask), .wdata(mem_wdata));
endmodule
