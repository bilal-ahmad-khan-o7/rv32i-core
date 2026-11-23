`timescale 1ns/1ps
// tb_nn_unit.sv - custom-0 INT8 unit: DOT4.S8 and CLIP.S8.
// DOT4.S8, part 1: hand-worked edge cases (lane signs, extremes, lane
//         pairing, wrap-around of the accumulator, acc aliasing rs1/rs2).
// DOT4.S8, part 2: random operands against a model that loops over the
//         lanes with SystemVerilog `byte` (signed 8-bit) and `int` arithmetic.
// CLIP.S8: the boundary values by hand, then random values (many near the
//         -128/127 boundaries) against a compare-based model; b and acc are
//         random and must be ignored.
// At this level "rd = x0" means the accumulator input is 0 and "rd == rs1"
// means acc == a; the real register cases run in tb_core_dot64.
module tb_nn_unit;
  import riscv_pkg::*;

  logic [31:0] a, b, acc, y;
  logic [2:0]  funct3;
  int          errors = 0;

  nn_unit dut (.a(a), .b(b), .acc(acc), .funct3(funct3), .y(y));

  function automatic logic [31:0] dot4_model(input logic [31:0] ma, mb, macc);
    byte sa, sb;
    int  sum;
    sum = 0;
    for (int i = 0; i < 4; i++) begin
      sa = ma[8*i +: 8];
      sb = mb[8*i +: 8];
      sum += int'(sa) * int'(sb);
    end
    return macc + sum;                       // 32-bit wrap, like the hardware
  endfunction

  function automatic logic [31:0] clip_model(input logic [31:0] ma);
    int v;
    v = $signed(ma);
    if (v > 127)  return 32'd127;
    if (v < -128) return -32'sd128;
    return ma;
  endfunction

  task automatic check_clip(input logic [31:0] ta, input logic [31:0] expect_y, input string what);
    funct3 = F3_CLIP_S8; a = ta; b = $urandom; acc = $urandom; #1;   // b, acc: must not matter
    if (y !== expect_y) begin
      $display("FAIL: clip.s8 %h -> %h, expected %h  (%s)", ta, y, expect_y, what);
      errors++;
    end
  endtask

  task automatic check_dot(input logic [31:0] ta, tb, tacc, input logic [31:0] expect_y,
                           input string what);
    funct3 = F3_DOT4_S8; a = ta; b = tb; acc = tacc; #1;
    if (y !== expect_y) begin
      $display("FAIL: dot4.s8 a=%h b=%h acc=%h -> %h, expected %h  (%s)", ta, tb, tacc, y, expect_y, what);
      errors++;
    end
  endtask

  // a random byte that is often an extreme value
  function automatic logic [7:0] edgy_byte();
    case ($urandom % 8)
      0: return 8'h80;  1: return 8'h81;  2: return 8'hFF;  3: return 8'h00;
      4: return 8'h01;  5: return 8'h7F;  6: return 8'h7E;
      default: return $urandom;
    endcase
  endfunction

  logic [31:0] ra, rb, racc;

  initial begin
    // ---- DOT4.S8: hand-worked ----
    check_dot(32'h8080_8080, 32'h8080_8080, 32'h0000_0000, 32'h0001_0000, "4 x (-128 * -128) = 65536 (needs 18 bits)");
    check_dot(32'h7F7F_7F7F, 32'h8080_8080, 32'h0000_0000, 32'hFFFF_0200, "4 x (127 * -128) = -65024");
    check_dot(32'h8080_8080, 32'h7F7F_7F7F, 32'h0000_0000, 32'hFFFF_0200, "4 x (-128 * 127), operands swapped");
    check_dot(32'h7F7F_7F7F, 32'h7F7F_7F7F, 32'h0000_0000, 32'h0000_FC04, "4 x (127 * 127) = 64516");
    check_dot(32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0000, 32'h0000_0004, "4 x (-1 * -1): bytes are signed");
    check_dot(32'h7F80_FF01, 32'h02FF_7F80, 32'h0000_03E8, 32'h0000_0467,
              "mixed signs: 1*-128 + -1*127 + -128*-1 + 127*2 = 127, + 1000");
    // lane pairing: byte i of rs1 must meet byte i of rs2, nothing else
    check_dot(32'h0403_0201, 32'h0000_0001, 32'h0000_0000, 32'h0000_0001, "lane 0 only");
    check_dot(32'h0403_0201, 32'h0000_0100, 32'h0000_0000, 32'h0000_0002, "lane 1 only");
    check_dot(32'h0403_0201, 32'h0001_0000, 32'h0000_0000, 32'h0000_0003, "lane 2 only");
    check_dot(32'h0403_0201, 32'h0100_0000, 32'h0000_0000, 32'h0000_0004, "lane 3 only");
    check_dot(32'h0403_0201, 32'h0101_0101, 32'h0000_0000, 32'h0000_000A, "all lanes: 1+2+3+4");
    check_dot(32'h0000_0080, 32'h0000_0001, 32'h0000_0000, 32'hFFFF_FF80, "one lane -128 * 1: sign reaches bit 31");
    // the accumulate wraps modulo 2^32, no saturation
    check_dot(32'h0000_0001, 32'h0000_0001, 32'h7FFF_FFFF, 32'h8000_0000, "0x7FFFFFFF + 1 wraps to 0x80000000");
    check_dot(32'h8080_8080, 32'h8080_8080, 32'h7FFF_FF00, 32'h8000_FF00, "0x7FFFFF00 + 65536 wraps");
    check_dot(32'h0000_00FF, 32'h0000_0001, 32'h8000_0000, 32'h7FFF_FFFF, "0x80000000 + (-1) wraps to 0x7FFFFFFF");
    check_dot(32'h0000_0001, 32'h0000_0001, 32'hFFFF_FFFF, 32'h0000_0000, "-1 + 1 = 0");
    check_dot(32'h7F7F_7F7F, 32'h8080_8080, 32'h0001_0000, 32'h0000_0200, "positive acc + negative dot: 65536 - 65024");
    check_dot(32'h7F7F_7F7F, 32'h8080_8080, 32'h0000_FE00, 32'h0000_0000, "65024 - 65024 = 0");
    // accumulator inputs
    check_dot(32'h1234_5678, 32'h0000_0000, 32'hDEAD_BEEF, 32'hDEAD_BEEF, "rs2 = 0: rd unchanged");
    check_dot(32'h0102_0304, 32'h0101_0101, 32'h0000_0000, 32'h0000_000A, "rd = x0: accumulator reads 0");
    check_dot(32'h0102_0304, 32'h0101_0101, 32'h0102_0304, 32'h0102_030E, "rd == rs1: acc == a");
    check_dot(32'h80FF_7F01, 32'hFF01_FF01, 32'h80FF_7F01, 32'h80FF_7F02, "rd == rs1, signed lanes: 1-127-1+128 = 1");
    check_dot(32'h0101_0101, 32'hFE03_FD02, 32'hFE03_FD02, 32'hFE03_FD02, "rd == rs2: 2-3+3-2 = 0");

    // ---- DOT4.S8: random, full range and extreme-heavy ----
    repeat (500) begin
      ra = $urandom; rb = $urandom; racc = $urandom;
      check_dot(ra, rb, racc, dot4_model(ra, rb, racc), "random");
    end
    repeat (300) begin
      ra = {edgy_byte(), edgy_byte(), edgy_byte(), edgy_byte()};
      rb = {edgy_byte(), edgy_byte(), edgy_byte(), edgy_byte()};
      racc = ($urandom % 2) ? (32'h7FFF_0000 + ($urandom % 32'h2_0000)) : $urandom;  // often near the wrap
      check_dot(ra, rb, racc, dot4_model(ra, rb, racc), "random extreme lanes");
    end

    // ---- CLIP.S8: hand-worked ----
    check_clip(32'h0000_007F, 32'h0000_007F, "127 stays");
    check_clip(32'h0000_0080, 32'h0000_007F, "128 -> 127");
    check_clip(32'hFFFF_FF80, 32'hFFFF_FF80, "-128 stays");
    check_clip(32'hFFFF_FF7F, 32'hFFFF_FF80, "-129 -> -128");
    check_clip(32'h0000_0000, 32'h0000_0000, "0 stays");
    check_clip(32'h7FFF_FFFF, 32'h0000_007F, "INT_MAX -> 127");
    check_clip(32'h8000_0000, 32'hFFFF_FF80, "INT_MIN -> -128");
    check_clip(32'hFFFF_FFFF, 32'hFFFF_FFFF, "-1 stays (sign-extended)");
    check_clip(32'h0000_00FF, 32'h0000_007F, "255 -> 127 (not a byte reinterpretation)");
    check_clip(32'h0000_0100, 32'h0000_007F, "256 -> 127");
    check_clip(32'hFFFF_FF00, 32'hFFFF_FF80, "-256 -> -128");
    check_clip(32'h0001_0000, 32'h0000_007F, "65536 -> 127 (DOT4 maximum)");
    check_clip(32'hFFFF_0200, 32'hFFFF_FF80, "-65024 -> -128 (DOT4 minimum)");
    check_clip(32'h0000_0001, 32'h0000_0001, "1 stays");
    check_clip(32'h4000_0000, 32'h0000_007F, "large positive, bit 31 clear");

    // ---- CLIP.S8: random, full range and near the boundaries ----
    repeat (300) begin
      ra = $urandom;
      check_clip(ra, clip_model(ra), "random");
    end
    repeat (400) begin
      ra = $urandom % 600 - 300;                  // -300 .. 299
      check_clip(ra, clip_model(ra), "random near the boundary");
    end

    if (errors == 0) $display("PASS: tb_nn_unit");
    else             $display("FAIL: tb_nn_unit (%0d errors)", errors);
    $finish;
  end
endmodule
