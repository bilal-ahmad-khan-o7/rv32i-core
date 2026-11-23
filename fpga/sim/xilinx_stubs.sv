`timescale 1ns/1ps
// xilinx_stubs.sv - stand-ins for the two Xilinx primitives clock_gen.sv uses, so that
// Icarus can simulate top_kws. ONLY for simulation: build.tcl never reads this file,
// and Vivado uses the real primitives.
//   MMCME2_BASE  passes the input clock through (in simulation only the cycle count
//                matters, not the frequency) and raises LOCKED after 8 input cycles
//   BUFG         a wire
module MMCME2_BASE #(
  parameter real CLKIN1_PERIOD    = 10.0,
  parameter int  DIVCLK_DIVIDE    = 1,
  parameter real CLKFBOUT_MULT_F  = 5.0,
  parameter real CLKOUT0_DIVIDE_F = 1.0
) (
  input  logic CLKIN1,
  input  logic CLKFBIN,
  input  logic PWRDWN,
  input  logic RST,
  output logic CLKFBOUT,
  output logic CLKOUT0,
  output logic LOCKED
);
  logic [3:0] count = 4'd0;
  assign CLKOUT0  = CLKIN1;
  assign CLKFBOUT = CLKIN1;
  assign LOCKED   = count[3];
  always @(posedge CLKIN1) if (!count[3]) count <= count + 4'd1;
endmodule

module BUFG (
  input  logic I,
  output logic O
);
  assign O = I;
endmodule
