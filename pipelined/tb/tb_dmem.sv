`timescale 1ns/1ps
// tb_dmem.sv - the synchronous data memory: byte write mask and little-endian placement,
// random masked writes against a model, the INIT_FILE preload (the checks of
// single_cycle/tb/tb_dmem.sv), plus the new timing:
//   - a read returns the word one clock edge after its address;
//   - a write and a read of the same word at the same edge return the OLD word
//     (read-first); the next edge returns the new one.
// Icarus prints a "Not enough words in the file" warning: expected and harmless.
module tb_dmem;
  logic        clk = 1'b0;
  logic [31:0] addr, rdata, wdata;
  logic        we;
  logic [3:0]  wmask;
  logic [31:0] model [0:1023];
  int          errors = 0;

  dmem #(.WORDS(1024)) dut (
    .clk(clk), .addr(addr), .rdata(rdata), .we(we), .wmask(wmask), .wdata(wdata));

  // preloaded from a 4-word hex file; never written
  logic [31:0] init_addr, init_rdata;
  dmem #(.WORDS(1024), .INIT_FILE("../single_cycle/programs/imem_demo.hex")) dut_init (
    .clk(clk), .addr(init_addr), .rdata(init_rdata), .we(1'b0), .wmask(4'b0), .wdata(32'd0));

  always #5 clk = ~clk;

  task automatic check_init(input logic [31:0] a, input logic [31:0] expect_word);
    @(negedge clk) init_addr = a;
    @(posedge clk) #1;
    if (init_rdata !== expect_word) begin
      $display("FAIL: preloaded word at %h = %h, expected %h", a, init_rdata, expect_word);
      errors++;
    end
  endtask

  task automatic write(input logic [31:0] a, input logic [3:0] m, input logic [31:0] d, input logic en);
    @(negedge clk) begin addr = a; wmask = m; wdata = d; we = en; end
    @(posedge clk) #1 we = 1'b0;
    if (en)
      for (int b = 0; b < 4; b++)
        if (m[b]) model[a[11:2]][8*b +: 8] = d[8*b +: 8];
  endtask

  task automatic check(input logic [31:0] a, input logic [31:0] expect_word);
    @(negedge clk) addr = a;
    @(posedge clk) #1;
    if (rdata !== expect_word) begin
      $display("FAIL at %0t: word at %h = %h, expected %h", $time, a, rdata, expect_word);
      errors++;
    end
  endtask

  initial begin
    $dumpfile("build/tb_dmem.vcd");
    $dumpvars(0, tb_dmem);
    for (int i = 0; i < 1024; i++) model[i] = 32'd0;
    we = 1'b0; wmask = 4'b0; wdata = 32'd0; addr = 32'd0;

    write(32'd8, 4'b1111, 32'h1234_5678, 1'b1);     // sw 0x12345678 -> address 8
    check(32'd8, 32'h1234_5678);
    if (rdata[7:0] !== 8'h78) begin                 // lowest byte lives in bits [7:0]
      $display("FAIL: little-endian: byte 0 of word 2 is %h, expected 78", rdata[7:0]);
      errors++;
    end
    write(32'd9,  4'b0010, 32'h0000_EE00, 1'b1);    // "sb 0xEE -> address 9": only byte 1
    check(32'd8, 32'h1234_EE78);
    write(32'd10, 4'b1100, 32'hABCD_0000, 1'b1);    // "sh 0xABCD -> address 10": bytes 2,3 of word 2
    check(32'd8, 32'hABCD_EE78);
    write(32'd8, 4'b1111, 32'hFFFF_FFFF, 1'b0);     // we = 0: nothing changes
    check(32'd8, 32'hABCD_EE78);
    check(32'd12, 32'd0);                           // neighbour untouched
    check(32'd4096 + 32'd8, 32'hABCD_EE78);         // 4 KiB wrap: same word

    // read-first: the edge that writes word 2 also reads it, and returns the old value
    write(32'd8, 4'b1111, 32'h0BAD_F00D, 1'b1);
    if (rdata !== 32'hABCD_EE78) begin
      $display("FAIL: read during a write returned %h, expected the old word abcdee78", rdata);
      errors++;
    end
    model[2] = 32'h0BAD_F00D;
    check(32'd8, 32'h0BAD_F00D);                    // the next edge sees the new word

    repeat (300) begin                              // random masked writes
      logic [31:0] a;
      a = $urandom & 32'h0000_0FFF;                 // any byte address in the 4 KiB
      write(a, $urandom % 16, $urandom, 1'b1);
      check(a, model[a[11:2]]);
    end
    for (int i = 0; i < 1024; i += 37) check(i * 4, model[i]);

    // INIT_FILE: the file's words, then zeros (not nop: this is data memory)
    check_init(32'd0,  32'h0050_0293);
    check_init(32'd4,  32'h0070_0313);
    check_init(32'd8,  32'h0062_83B3);
    check_init(32'd12, 32'h0000_0013);
    check_init(32'd16, 32'h0000_0000);
    check_init(32'd4092, 32'h0000_0000);

    if (errors == 0) $display("PASS: tb_dmem");
    else             $display("FAIL: tb_dmem (%0d errors)", errors);
    $finish;
  end
endmodule
