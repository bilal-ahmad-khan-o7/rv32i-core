`timescale 1ns/1ps
// tb_lsu.sv - load/store byte lanes (PDF Lesson 10.2).
// Stores: data shifted into the right lane + the right write mask.
// Loads:  lane selected by addr[1:0], then sign- or zero-extended.
module tb_lsu;
  logic [2:0]  funct3;
  logic [1:0]  addr_lo;
  logic [31:0] store_data, mem_wdata, mem_rdata, load_data;
  logic [3:0]  mem_wmask;
  int          errors = 0;

  localparam logic [2:0] F_B = 3'b000, F_H = 3'b001, F_W = 3'b010, F_BU = 3'b100, F_HU = 3'b101;

  lsu dut (
    .funct3(funct3), .addr_lo(addr_lo),
    .store_data(store_data), .mem_wdata(mem_wdata), .mem_wmask(mem_wmask),
    .mem_rdata(mem_rdata), .load_data(load_data));

  // Only the lanes enabled by the mask matter for a store.
  task automatic check_store(input logic [2:0] f, input logic [1:0] lo, input logic [31:0] d,
                             input logic [3:0] expect_mask, input logic [31:0] expect_lanes,
                             input string what);
    funct3 = f; addr_lo = lo; store_data = d; #1;
    if (mem_wmask !== expect_mask) begin
      $display("FAIL: %-12s wmask=%b, expected %b", what, mem_wmask, expect_mask);
      errors++;
    end
    for (int b = 0; b < 4; b++)
      if (expect_mask[b] && mem_wdata[8*b +: 8] !== expect_lanes[8*b +: 8]) begin
        $display("FAIL: %-12s lane %0d = %h, expected %h", what, b, mem_wdata[8*b +: 8], expect_lanes[8*b +: 8]);
        errors++;
      end
  endtask

  task automatic check_load(input logic [2:0] f, input logic [1:0] lo, input logic [31:0] word,
                            input logic [31:0] expect_data, input string what);
    funct3 = f; addr_lo = lo; mem_rdata = word; #1;
    if (load_data !== expect_data) begin
      $display("FAIL: %-12s word=%h -> %h, expected %h", what, word, load_data, expect_data);
      errors++;
    end
  endtask

  initial begin
    mem_rdata = 32'd0;
    // ---- stores of 0xAABBCCDD ----
    check_store(F_B, 2'd0, 32'hAABB_CCDD, 4'b0001, 32'h0000_00DD, "sb +0");
    check_store(F_B, 2'd1, 32'hAABB_CCDD, 4'b0010, 32'h0000_DD00, "sb +1");
    check_store(F_B, 2'd2, 32'hAABB_CCDD, 4'b0100, 32'h00DD_0000, "sb +2");
    check_store(F_B, 2'd3, 32'hAABB_CCDD, 4'b1000, 32'hDD00_0000, "sb +3");
    check_store(F_H, 2'd0, 32'hAABB_CCDD, 4'b0011, 32'h0000_CCDD, "sh +0");
    check_store(F_H, 2'd2, 32'hAABB_CCDD, 4'b1100, 32'hCCDD_0000, "sh +2");
    check_store(F_W, 2'd0, 32'hAABB_CCDD, 4'b1111, 32'hAABB_CCDD, "sw");

    // ---- loads from the word 0x80017F80: bytes (3..0) = 80 01 7F 80 ----
    check_load(F_B,  2'd0, 32'h8001_7F80, 32'hFFFF_FF80, "lb +0");
    check_load(F_BU, 2'd0, 32'h8001_7F80, 32'h0000_0080, "lbu +0");
    check_load(F_B,  2'd1, 32'h8001_7F80, 32'h0000_007F, "lb +1");
    check_load(F_BU, 2'd1, 32'h8001_7F80, 32'h0000_007F, "lbu +1");
    check_load(F_B,  2'd2, 32'h8001_7F80, 32'h0000_0001, "lb +2");
    check_load(F_B,  2'd3, 32'h8001_7F80, 32'hFFFF_FF80, "lb +3");
    check_load(F_BU, 2'd3, 32'h8001_7F80, 32'h0000_0080, "lbu +3");
    check_load(F_H,  2'd0, 32'h8001_7F80, 32'h0000_7F80, "lh +0");
    check_load(F_HU, 2'd0, 32'h8001_7F80, 32'h0000_7F80, "lhu +0");
    check_load(F_H,  2'd2, 32'h8001_7F80, 32'hFFFF_8001, "lh +2");
    check_load(F_HU, 2'd2, 32'h8001_7F80, 32'h0000_8001, "lhu +2");
    check_load(F_W,  2'd0, 32'h8001_7F80, 32'h8001_7F80, "lw");

    // ---- random: every lane, both extensions ----
    repeat (300) begin
      logic [31:0] w;
      logic [1:0]  lo;
      logic [7:0]  by;
      logic [15:0] hw;
      w = $urandom; lo = $urandom % 4;
      by = w >> (8 * lo);
      hw = lo[1] ? w[31:16] : w[15:0];
      check_load(F_B,  lo, w, {{24{by[7]}}, by},  "lb random");
      check_load(F_BU, lo, w, {24'd0, by},        "lbu random");
      check_load(F_H,  {lo[1], 1'b0}, w, {{16{hw[15]}}, hw}, "lh random");
      check_load(F_HU, {lo[1], 1'b0}, w, {16'd0, hw},        "lhu random");
      check_store(F_B, lo, w, 4'b0001 << lo, w << (8 * lo), "sb random");
    end

    if (errors == 0) $display("PASS: tb_lsu");
    else             $display("FAIL: tb_lsu (%0d errors)", errors);
    $finish;
  end
endmodule
