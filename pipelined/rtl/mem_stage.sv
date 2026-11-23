`timescale 1ns/1ps
// mem_stage.sv - Memory access, for a synchronous-read data memory.
//
// Changed from single_cycle/rtl/mem_stage.sv: the access now spans the EX/MEM boundary.
//   end of EX  the address, byte mask and lane-shifted store data go into dmem; a store
//              writes at this clock edge, and the RAM registers the address for a load
//   MEM        the whole word comes out of dmem; the LSU picks the lane and extends it,
//              using addr_lo and funct3 from EX/MEM, and the result goes to MEM/WB
// So a load's value is ready at the end of MEM: one cycle of load-use penalty.
//
// lsu.sv is reused unchanged, twice: u_lsu_store uses only its store side, with EX's
// funct3 and address; u_lsu_load only its load side, with MEM's.
module mem_stage #(
  parameter int DMEM_WORDS     = 1024,
  parameter     DMEM_INIT_FILE = ""          // optional data-memory preload
) (
  input  logic        clk,
  // EX side: the instruction now in EX
  input  logic [31:0] ex_addr,       // alu_y: rs1 + imm
  input  logic [31:0] ex_store_data, // rs2, after forwarding
  input  logic [2:0]  ex_funct3,     // access size
  input  logic        ex_mem_write,  // a store (already gated by valid and reset)
  // MEM side: the instruction now in MEM, from EX/MEM
  input  logic [1:0]  mem_addr_lo,   // which byte of the word
  input  logic [2:0]  mem_funct3,    // access size and signedness
  output logic [31:0] load_data
);
  logic [31:0] mem_wdata, mem_rdata;
  logic [3:0]  mem_wmask;

  lsu u_lsu_store (
    .funct3(ex_funct3), .addr_lo(ex_addr[1:0]),
    .store_data(ex_store_data), .mem_wdata(mem_wdata), .mem_wmask(mem_wmask),
    .mem_rdata(32'd0), .load_data());

  dmem #(.WORDS(DMEM_WORDS), .INIT_FILE(DMEM_INIT_FILE)) u_dmem (
    .clk(clk), .addr(ex_addr), .we(ex_mem_write), .wmask(mem_wmask), .wdata(mem_wdata),
    .rdata(mem_rdata));

  lsu u_lsu_load (
    .funct3(mem_funct3), .addr_lo(mem_addr_lo),
    .store_data(32'd0), .mem_wdata(), .mem_wmask(),
    .mem_rdata(mem_rdata), .load_data(load_data));
endmodule
