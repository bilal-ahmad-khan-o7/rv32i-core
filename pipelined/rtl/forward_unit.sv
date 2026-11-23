`timescale 1ns/1ps
// forward_unit.sv - picks where each EX operand comes from (Patterson & Hennessy 4.7).
// An instruction ahead may not have written its result to the register file yet; if
// it is going to write the register this operand reads, take its value instead:
//   EX/MEM  the instruction just ahead (its result is ready at the end of EX)
//   MEM/WB  the one before that (its result, or its loaded value, is in WB)
// EX/MEM wins when both match: it is the newer value. A write to x0 is never forwarded.
//
// Three operands: rs1, rs2, and rs3, DOT4.S8's accumulator, which is addressed by the
// rd field. A chain of DOT4.S8 into one accumulator takes rs3 from EX/MEM every time,
// so it never stalls.
//
// A load in EX/MEM has no value yet; hazard_unit's load-use stall makes sure no
// instruction needs one from there.
module forward_unit
  import pipeline_pkg::*;
(
  // the instruction in EX: which registers it reads
  input  logic [4:0] id_ex_rs1_addr,
  input  logic [4:0] id_ex_rs2_addr,
  input  logic [4:0] id_ex_rd_addr,        // rs3's address
  // the instructions ahead: which register they write
  input  logic       ex_mem_reg_write,
  input  logic [4:0] ex_mem_rd_addr,
  input  logic       mem_wb_reg_write,
  input  logic [4:0] mem_wb_rd_addr,
  // mux selects for the three operands (FWD_ID_EX / FWD_EX_MEM / FWD_MEM_WB)
  output logic [1:0] forward_a,            // rs1
  output logic [1:0] forward_b,            // rs2
  output logic [1:0] forward_c             // rs3
);
  assign forward_a = (ex_mem_reg_write && ex_mem_rd_addr != 5'd0 && ex_mem_rd_addr == id_ex_rs1_addr) ? FWD_EX_MEM
                   : (mem_wb_reg_write && mem_wb_rd_addr != 5'd0 && mem_wb_rd_addr == id_ex_rs1_addr) ? FWD_MEM_WB
                   : FWD_ID_EX;

  assign forward_b = (ex_mem_reg_write && ex_mem_rd_addr != 5'd0 && ex_mem_rd_addr == id_ex_rs2_addr) ? FWD_EX_MEM
                   : (mem_wb_reg_write && mem_wb_rd_addr != 5'd0 && mem_wb_rd_addr == id_ex_rs2_addr) ? FWD_MEM_WB
                   : FWD_ID_EX;

  assign forward_c = (ex_mem_reg_write && ex_mem_rd_addr != 5'd0 && ex_mem_rd_addr == id_ex_rd_addr)  ? FWD_EX_MEM
                   : (mem_wb_reg_write && mem_wb_rd_addr != 5'd0 && mem_wb_rd_addr == id_ex_rd_addr)  ? FWD_MEM_WB
                   : FWD_ID_EX;
endmodule
