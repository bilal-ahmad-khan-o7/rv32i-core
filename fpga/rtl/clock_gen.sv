`timescale 1ns/1ps
// clock_gen.sv - the core clock, from the PYNQ-Z2's 125 MHz board clock.
// One MMCM (the MMCME2_BASE primitive, so no IP is needed and it works the same in every
// Vivado version) and a global clock buffer:
//   f_out = 125 MHz * MULT / DIVIDE      MULT = 8 keeps the VCO at 1000 MHz (600-1200 allowed)
//   DIVIDE = 10 -> 100 MHz,  12.5 -> 80 MHz,  20 -> 50 MHz
// `locked` is 1 once the output is stable; hold the design in reset until then.
// Kept as its own module so step 3 (the bitstream) can reuse it.
module clock_gen #(
  parameter real DIVIDE = 10.0
) (
  input  logic clk_in,      // 125 MHz, from the board
  output logic clk_out,
  output logic locked
);
  logic clkfb, clk_mmcm;

  MMCME2_BASE #(
    .CLKIN1_PERIOD(8.0),            // 125 MHz
    .DIVCLK_DIVIDE(1),
    .CLKFBOUT_MULT_F(8.0),          // VCO = 1000 MHz
    .CLKOUT0_DIVIDE_F(DIVIDE)
  ) u_mmcm (
    .CLKIN1(clk_in), .CLKFBIN(clkfb), .CLKFBOUT(clkfb),   // feedback straight back in
    .CLKOUT0(clk_mmcm), .LOCKED(locked),
    .PWRDWN(1'b0), .RST(1'b0));

  BUFG u_bufg (.I(clk_mmcm), .O(clk_out));
endmodule
