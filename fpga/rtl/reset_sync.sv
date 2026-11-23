`timescale 1ns/1ps
// reset_sync.sv - turns an asynchronous reset request (a button, or the MMCM not locked)
// into a reset that is synchronous to `clk`: it starts at once and ends on a clock edge,
// two flip-flops after the request goes away, so every flip-flop leaves reset in the
// same cycle. The core's own reset is synchronous, so it needs exactly this.
// Kept as its own module so step 3 (the bitstream) can reuse it.
module reset_sync (
  input  logic clk,
  input  logic async_rst,   // 1: reset (any time)
  output logic rst          // 1: reset, synchronous to clk
);
  (* ASYNC_REG = "TRUE" *) logic [1:0] sync = 2'b11;

  always_ff @(posedge clk or posedge async_rst) begin
    if (async_rst) sync <= 2'b11;
    else           sync <= {sync[0], 1'b0};
  end

  assign rst = sync[1];
endmodule
