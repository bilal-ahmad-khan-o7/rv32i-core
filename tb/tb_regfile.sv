`timescale 1ns/1ps
// tb_regfile.sv - register file against a shadow model (PDF Lesson 5.5).
// The model follows the ISA rules: writes to x0 and writes with we=0 are ignored.
module tb_regfile;
  logic        clk = 1'b0;
  logic [4:0]  rs1_addr, rs2_addr, rd_addr;
  logic [31:0] rs1_data, rs2_data, rd_data;
  logic        we;
  logic [31:0] model [0:31];               // what the registers SHOULD hold
  int          errors = 0;

  regfile dut (
    .clk(clk),
    .rs1_addr(rs1_addr), .rs1_data(rs1_data),
    .rs2_addr(rs2_addr), .rs2_data(rs2_data),
    .we(we), .rd_addr(rd_addr), .rd_data(rd_data));

  always #5 clk = ~clk;

  task automatic write_reg(input logic [4:0] r, input logic [31:0] v, input logic en);
    @(negedge clk) begin we = en; rd_addr = r; rd_data = v; end
    @(posedge clk) #1 we = 1'b0;
    if (en && r != 5'd0) model[r] = v;
  endtask

  task automatic check_read(input logic [4:0] a1, input logic [4:0] a2);
    rs1_addr = a1; rs2_addr = a2; #1;
    if (rs1_data !== model[a1] || rs2_data !== model[a2]) begin
      $display("FAIL at %0t: x%0d=%h (exp %h)  x%0d=%h (exp %h)",
               $time, a1, rs1_data, model[a1], a2, rs2_data, model[a2]);
      errors++;
    end
  endtask

  initial begin
    $dumpfile("build/tb_regfile.vcd");
    $dumpvars(0, tb_regfile);
    for (int i = 0; i < 32; i++) model[i] = 32'd0;
    we = 1'b0; rd_addr = 5'd0; rd_data = 32'd0; rs1_addr = 5'd0; rs2_addr = 5'd0;

    check_read(5'd1, 5'd31);                 // all zero after power-up
    write_reg(5'd5, 32'd7, 1'b1);
    write_reg(5'd6, 32'hCAFE_F00D, 1'b1);
    check_read(5'd5, 5'd6);
    write_reg(5'd0, 32'hFFFF_FFFF, 1'b1);    // must be ignored
    check_read(5'd0, 5'd5);
    write_reg(5'd7, 32'h1234_5678, 1'b0);    // we = 0: must be ignored
    check_read(5'd7, 5'd6);

    // Same-cycle read and write (Lesson 5.4.6): old value before the edge, new after.
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

    repeat (200) begin                       // random traffic, x0 included
      write_reg($urandom % 32, $urandom, $urandom % 2);
      check_read($urandom % 32, $urandom % 32);
    end
    for (int i = 0; i < 32; i += 2) check_read(i[4:0], i[4:0] + 5'd1);

    if (errors == 0) $display("PASS: tb_regfile");
    else             $display("FAIL: tb_regfile (%0d errors)", errors);
    $finish;
  end
endmodule
