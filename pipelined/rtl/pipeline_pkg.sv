`timescale 1ns/1ps
// pipeline_pkg.sv - constants used only by the pipelined core (compile after riscv_pkg).
package pipeline_pkg;
  // forward_unit select codes, as Patterson & Hennessy number ForwardA / ForwardB
  localparam logic [1:0] FWD_ID_EX  = 2'b00;    // no hazard: the value read in ID
  localparam logic [1:0] FWD_MEM_WB = 2'b01;    // from write-back: two instructions ahead
  localparam logic [1:0] FWD_EX_MEM = 2'b10;    // from the instruction just ahead

  // a bubble in IF/ID holds this instruction: addi x0, x0, 0 reads and writes nothing
  localparam logic [31:0] NOP = 32'h0000_0013;
endpackage
