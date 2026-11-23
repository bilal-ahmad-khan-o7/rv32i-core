`timescale 1ns/1ps
// tb_imem.sv - the synchronous instruction memory: hex loading, byte address -> word,
// nop fill, 4 KiB wrap (the checks of single_cycle/tb/tb_imem.sv), plus the new timing:
//   - the word appears only after the clock edge that took its address;
//   - between edges the output holds, whatever the address does.
// Icarus prints a "Not enough words in the file" warning: expected and harmless.
module tb_imem;
  logic        clk = 1'b0;
  logic [31:0] addr = 32'd0, instr;
  int          errors = 0;

  imem #(.WORDS(1024), .INIT_FILE("../single_cycle/programs/imem_demo.hex")) dut (
    .clk(clk), .addr(addr), .instr(instr));

  always #5 clk = ~clk;

  // present the address before an edge, then look just after it
  task automatic check(input logic [31:0] a, input logic [31:0] expect_instr, input string what);
    @(negedge clk) addr = a;
    @(posedge clk) #1;
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

    // synchronous: a new address changes nothing until the next edge
    check(32'd8, 32'h0062_83B3, "word 2");
    addr = 32'd4; #2;
    if (instr !== 32'h0062_83B3) begin
      $display("FAIL: the output changed before the clock edge (%h)", instr);
      errors++;
    end
    @(posedge clk) #1;
    if (instr !== 32'h0070_0313) begin
      $display("FAIL: after the edge, addr 4 gave %h, expected 00700313", instr);
      errors++;
    end

    if (errors == 0) $display("PASS: tb_imem");
    else             $display("FAIL: tb_imem (%0d errors)", errors);
    $finish;
  end
endmodule
