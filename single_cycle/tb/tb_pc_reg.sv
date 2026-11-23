`timescale 1ns/1ps
// tb_pc_reg.sv - PC register: reset wins over next_pc, otherwise load every edge.
// Drive on the falling edge, check just after the rising edge.
module tb_pc_reg;
  logic        clk = 1'b0;
  logic        rst;
  logic [31:0] next_pc, pc;
  int          errors = 0;

  pc_reg #(.RESET_ADDR(32'h0000_1000)) dut (
    .clk(clk), .rst(rst), .next_pc(next_pc), .pc(pc));

  always #5 clk = ~clk;                    // 10 ns period

  task automatic step(input logic r, input logic [31:0] n, input logic [31:0] expect_pc);
    @(negedge clk) begin rst = r; next_pc = n; end
    @(posedge clk) #1;
    if (pc !== expect_pc) begin
      $display("FAIL at %0t: pc=%h expected %h", $time, pc, expect_pc);
      errors++;
    end
  endtask

  initial begin
    $dumpfile("build/tb_pc_reg.vcd");
    $dumpvars(0, tb_pc_reg);
    step(1, 32'hDEAD_BEEF, 32'h0000_1000);   // reset wins over next_pc
    step(0, 32'h0000_1004, 32'h0000_1004);
    step(0, 32'h0000_1008, 32'h0000_1008);
    step(0, 32'h0000_2000, 32'h0000_2000);   // a "jump"
    step(1, 32'h0000_3000, 32'h0000_1000);   // reset again
    step(0, 32'h0000_1004, 32'h0000_1004);
    repeat (50) begin                        // random loads
      logic [31:0] n;
      n = $urandom;
      step(0, n, n);
    end
    if (errors == 0) $display("PASS: tb_pc_reg");
    else             $display("FAIL: tb_pc_reg (%0d errors)", errors);
    $finish;
  end
endmodule
