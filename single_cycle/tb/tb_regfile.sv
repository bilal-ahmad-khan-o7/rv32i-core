`timescale 1ns/1ps
// tb_regfile.sv - register file against a shadow model.
// The model follows the ISA rules: writes to x0 and writes with we=0 are ignored.
// All three read ports are checked on every read (rs3 = DOT4.S8's accumulator).
module tb_regfile;
  logic        clk = 1'b0;
  logic [4:0]  rs1_addr, rs2_addr, rs3_addr, rd_addr;
  logic [31:0] rs1_data, rs2_data, rs3_data, rd_data;
  logic        we;
  logic [31:0] model [0:31];               // what the registers SHOULD hold
  int          errors = 0;

  regfile dut (
    .clk(clk),
    .rs1_addr(rs1_addr), .rs1_data(rs1_data),
    .rs2_addr(rs2_addr), .rs2_data(rs2_data),
    .rs3_addr(rs3_addr), .rs3_data(rs3_data),
    .we(we), .rd_addr(rd_addr), .rd_data(rd_data));

  always #5 clk = ~clk;

  task automatic write_reg(input logic [4:0] r, input logic [31:0] v, input logic en);
    @(negedge clk) begin we = en; rd_addr = r; rd_data = v; end
    @(posedge clk) #1 we = 1'b0;
    if (en && r != 5'd0) model[r] = v;
  endtask

  task automatic check_read(input logic [4:0] a1, input logic [4:0] a2, input logic [4:0] a3);
    rs1_addr = a1; rs2_addr = a2; rs3_addr = a3; #1;
    if (rs1_data !== model[a1] || rs2_data !== model[a2] || rs3_data !== model[a3]) begin
      $display("FAIL at %0t: x%0d=%h (exp %h)  x%0d=%h (exp %h)  x%0d=%h (exp %h)",
               $time, a1, rs1_data, model[a1], a2, rs2_data, model[a2], a3, rs3_data, model[a3]);
      errors++;
    end
  endtask

  initial begin
    $dumpfile("build/tb_regfile.vcd");
    $dumpvars(0, tb_regfile);
    for (int i = 0; i < 32; i++) model[i] = 32'd0;
    we = 1'b0; rd_addr = 5'd0; rd_data = 32'd0; rs1_addr = 5'd0; rs2_addr = 5'd0; rs3_addr = 5'd0;

    check_read(5'd1, 5'd31, 5'd17);          // all zero after power-up
    write_reg(5'd5, 32'd7, 1'b1);
    write_reg(5'd6, 32'hCAFE_F00D, 1'b1);
    check_read(5'd5, 5'd6, 5'd6);
    check_read(5'd6, 5'd0, 5'd5);            // each port sees its own address
    write_reg(5'd0, 32'hFFFF_FFFF, 1'b1);    // must be ignored
    check_read(5'd0, 5'd5, 5'd0);
    write_reg(5'd7, 32'h1234_5678, 1'b0);    // we = 0: must be ignored
    check_read(5'd7, 5'd6, 5'd7);
    check_read(5'd6, 5'd6, 5'd6);            // all three ports on one register

    // Same-cycle read and write: old value before the edge, new after.
    write_reg(5'd9, 32'h0000_0011, 1'b1);
    @(negedge clk) begin we = 1'b1; rd_addr = 5'd9; rd_data = 32'h0000_0055; rs1_addr = 5'd9; end
    #1;
    if (rs1_data !== 32'h0000_0011) begin
      $display("FAIL: same-cycle read returned %h, expected old value 00000011", rs1_data);
      errors++;
    end
    @(posedge clk) #1 we = 1'b0;
    model[9] = 32'h0000_0055;
    if (rs1_data !== 32'h0000_0055) begin
      $display("FAIL: after the edge x9=%h, expected 00000055", rs1_data);
      errors++;
    end

    // The same on the third port: DOT4.S8 x10, ... reads the OLD x10 and
    // writes the new one at the edge (rd is both a source and the destination).
    write_reg(5'd10, 32'h0000_1000, 1'b1);
    @(negedge clk) begin we = 1'b1; rd_addr = 5'd10; rd_data = 32'h0000_1234; rs3_addr = 5'd10; end
    #1;
    if (rs3_data !== 32'h0000_1000) begin
      $display("FAIL: same-cycle rs3 read returned %h, expected old value 00001000", rs3_data);
      errors++;
    end
    @(posedge clk) #1 we = 1'b0;
    model[10] = 32'h0000_1234;
    if (rs3_data !== 32'h0000_1234) begin
      $display("FAIL: after the edge rs3 (x10)=%h, expected 00001234", rs3_data);
      errors++;
    end

    repeat (300) begin                       // random traffic, x0 included
      write_reg($urandom % 32, $urandom, $urandom % 2);
      check_read($urandom % 32, $urandom % 32, $urandom % 32);
    end
    for (int i = 0; i < 32; i += 2) check_read(i[4:0], i[4:0] + 5'd1, 5'd31 - i[4:0]);

    if (errors == 0) $display("PASS: tb_regfile");
    else             $display("FAIL: tb_regfile (%0d errors)", errors);
    $finish;
  end
endmodule
