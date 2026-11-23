`timescale 1ns/1ps
// tb_imem.sv - instruction memory loads a hex file and maps byte addresses to
// words (PDF Lesson 5.4.4). imem_demo.hex holds four words; the rest must be nop.
// Icarus prints a "Not enough words in the file" warning: expected and harmless.
module tb_imem;
  logic [31:0] addr, instr;
  int          errors = 0;

  imem #(.WORDS(1024), .INIT_FILE("programs/imem_demo.hex")) dut (
    .addr(addr), .instr(instr));

  task automatic check(input logic [31:0] a, input logic [31:0] expect_instr, input string what);
    addr = a; #1;
    $display("  addr %h -> %h   %s", a, instr, what);
    if (instr !== expect_instr) begin
      $display("FAIL: addr %h gave %h, expected %h", a, instr, expect_instr);
      errors++;
    end
  endtask

  initial begin
    check(32'd0,    32'h0050_0293, "addi x5, x0, 5");
    check(32'd4,    32'h0070_0313, "addi x6, x0, 7");
    check(32'd8,    32'h0062_83B3, "add  x7, x5, x6");
    check(32'd12,   32'h0000_0013, "nop");
    check(32'd16,   32'h0000_0013, "nop (fill)");
    check(32'd4092, 32'h0000_0013, "last word, nop (fill)");
    check(32'd5,    32'h0070_0313, "byte offset ignored: addr[1:0] dropped");
    check(32'd4096, 32'h0050_0293, "4 KiB wraps to word 0");
    if (errors == 0) $display("PASS: tb_imem");
    else             $display("FAIL: tb_imem (%0d errors)", errors);
    $finish;
  end
endmodule
