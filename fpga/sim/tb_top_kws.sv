`timescale 1ns/1ps
// tb_top_kws.sv - runs the FPGA wrapper as the board will: preloaded memories only (no
// testbench loading), reset from the button, the answer on the LEDs. Checks that the
// core finishes (led4_g), without error (led5_r), with the expected label, and that it
// stays finished (the wrapper then holds the core in reset).
//   +EXPECT=n  the expected label (default 9: tst_000007_Yes_9 is "Yes")
module tb_top_kws;
  parameter IMEM_FILE = "../single_cycle/kws/gen/kws_c.imem.hex";
  parameter DMEM_FILE = "mem/kws_c_dmem_tst_000007_Yes_9.hex";

  logic       sysclk = 1'b0, btn0 = 1'b1;
  logic [3:0] led;
  logic       led4_g, led5_r;
  int         expect_label = 9;
  longint     cycles = 0;

  top_kws #(.IMEM_FILE(IMEM_FILE), .DMEM_FILE(DMEM_FILE)) dut (
    .sysclk(sysclk), .btn0(btn0), .led(led), .led4_g(led4_g), .led5_r(led5_r));

  always #4 sysclk = ~sysclk;                      // 125 MHz (the stub MMCM passes it through)

  initial begin
    if (!$value$plusargs("EXPECT=%d", expect_label)) expect_label = 9;
    repeat (20) @(posedge sysclk);
    btn0 = 1'b0;                                   // release the button
    while (!led4_g && !led5_r && cycles < 20_000_000) begin
      @(posedge sysclk);
      cycles++;
    end
    repeat (100) @(posedge sysclk);                // it must stay done
    $display("after %0d cycles: done=%b error=%b label=%0d", cycles, led4_g, led5_r, led);
    if (led4_g && !led5_r && led == expect_label) $display("PASS: tb_top_kws");
    else $display("FAIL: tb_top_kws (expected done, no error, label %0d)", expect_label);
    $finish;
  end
endmodule
