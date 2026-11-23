`timescale 1ns/1ps
// pc_reg.sv - the program counter register (PDF Lesson 4.5, Listing 4.2).
// Only stores. The next-PC choice lives outside (if_stage), so the pipeline can
// later add an enable here without touching anything else.
module pc_reg #(
  parameter logic [31:0] RESET_ADDR = 32'h0000_0000
) (
  input  logic        clk,
  input  logic        rst,      // synchronous, active high
  input  logic [31:0] next_pc,
  output logic [31:0] pc
);
  always_ff @(posedge clk) begin
    if (rst) pc <= RESET_ADDR;
    else     pc <= next_pc;
  end
endmodule
