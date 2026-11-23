`timescale 1ns/1ps
// tb_mul_unit.sv - Zmmul multiplier (RISC-V unprivileged spec, "M" chapter).
// Part 1: hand-worked results for the classic edge cases.
// Part 2: every op x {0, 1, -1, INT_MAX, INT_MIN} in both operands.
// Part 3: random operands. Parts 2-3 compare against a model that is built
//         differently from the RTL: plain 64-bit unsigned multiplication of
//         explicitly sign- or zero-extended operands.
// (div/divu/rem/remu never reach this unit; tb_control checks they are illegal.)
module tb_mul_unit;
  logic [31:0] a, b, y;
  logic [2:0]  funct3;
  int          errors = 0;

  localparam logic [2:0] MUL = 3'b000, MULH = 3'b001, MULHSU = 3'b010, MULHU = 3'b011;

  mul_unit dut (.a(a), .b(b), .funct3(funct3), .y(y));

  function automatic logic [31:0] model(input logic [31:0] ma, mb, input logic [2:0] f);
    logic [63:0] xa, xb, p;
    xa = (f == MULHU)               ? {32'b0, ma} : {{32{ma[31]}}, ma};   // rs1 signed except mulhu
    xb = (f == MULH || f == MUL)    ? {{32{mb[31]}}, mb} : {32'b0, mb};   // rs2 signed only for mulh
    p  = xa * xb;                                                       // exact modulo 2^64
    return (f == MUL) ? p[31:0] : p[63:32];
  endfunction

  function automatic string name(input logic [2:0] f);
    case (f)
      MUL:     return "mul";
      MULH:    return "mulh";
      MULHSU:  return "mulhsu";
      default: return "mulhu";
    endcase
  endfunction

  task automatic check_exp(input logic [2:0] f, input logic [31:0] ta, tb,
                           input logic [31:0] expect_y, input string what);
    funct3 = f; a = ta; b = tb; #1;
    if (y !== expect_y) begin
      $display("FAIL: %-6s %h x %h -> %h, expected %h  (%s)", name(f), ta, tb, y, expect_y, what);
      errors++;
    end
  endtask

  task automatic check(input logic [2:0] f, input logic [31:0] ta, tb);
    check_exp(f, ta, tb, model(ta, tb, f), "model");
  endtask

  logic [31:0] edge_v [0:4];

  initial begin
    // ---- hand-worked: exact 64-bit products written out in the comments ----
    check_exp(MUL,    32'h8000_0000, 32'hFFFF_FFFF, 32'h8000_0000, "-2^31 * -1 = 2^31: low half");
    check_exp(MUL,    32'h7FFF_FFFF, 32'h7FFF_FFFF, 32'h0000_0001, "(2^31-1)^2 = 3FFFFFFF_00000001");
    check_exp(MUL,    32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0001, "-1 * -1");
    check_exp(MUL,    32'h0001_0000, 32'h0001_0000, 32'h0000_0000, "2^16 * 2^16: low half is 0");
    check_exp(MULH,   32'h8000_0000, 32'h8000_0000, 32'h4000_0000, "-2^31 * -2^31 = 2^62");
    check_exp(MULH,   32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0000, "-1 * -1 = 1");
    check_exp(MULH,   32'h8000_0000, 32'h0000_0001, 32'hFFFF_FFFF, "-2^31 * 1: high is all sign");
    check_exp(MULH,   32'h7FFF_FFFF, 32'h7FFF_FFFF, 32'h3FFF_FFFF, "(2^31-1)^2");
    check_exp(MULH,   32'h7FFF_FFFF, 32'h8000_0000, 32'hC000_0000, "(2^31-1) * -2^31 = C0000000_80000000");
    check_exp(MULH,   32'hFFFF_FFFF, 32'h0000_0001, 32'hFFFF_FFFF, "-1 * 1 = -1");
    check_exp(MULHSU, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF, "-1 * (2^32-1) = FFFFFFFF_00000001");
    check_exp(MULHSU, 32'h8000_0000, 32'h8000_0000, 32'hC000_0000, "-2^31 * 2^31 = -2^62");
    check_exp(MULHSU, 32'h0000_0001, 32'hFFFF_FFFF, 32'h0000_0000, "1 * (2^32-1): rs2 is unsigned");
    check_exp(MULHSU, 32'h7FFF_FFFF, 32'hFFFF_FFFF, 32'h7FFF_FFFE, "(2^31-1)(2^32-1) = 7FFFFFFE_80000001");
    check_exp(MULHSU, 32'hFFFF_FFFF, 32'h0000_0001, 32'hFFFF_FFFF, "-1 * 1: rs1 is signed");
    check_exp(MULHU,  32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFE, "(2^32-1)^2 = FFFFFFFE_00000001");
    check_exp(MULHU,  32'h8000_0000, 32'h8000_0000, 32'h4000_0000, "2^31 * 2^31 = 2^62");
    check_exp(MULHU,  32'h8000_0000, 32'hFFFF_FFFF, 32'h7FFF_FFFF, "2^31 (2^32-1) = 7FFFFFFF_80000000");
    check_exp(MULHU,  32'hFFFF_FFFF, 32'h0000_0001, 32'h0000_0000, "unsigned: (2^32-1) * 1");
    check_exp(MULHU,  32'h0000_0000, 32'hFFFF_FFFF, 32'h0000_0000, "0 * anything");

    // ---- every op on the classic edge values, both operands ----
    edge_v[0] = 32'h0000_0000; edge_v[1] = 32'h0000_0001; edge_v[2] = 32'hFFFF_FFFF;
    edge_v[3] = 32'h7FFF_FFFF; edge_v[4] = 32'h8000_0000;
    for (int f = 0; f < 4; f++)
      for (int i = 0; i < 5; i++)
        for (int j = 0; j < 5; j++)
          check(f[2:0], edge_v[i], edge_v[j]);

    // ---- random operands: full range, then small/near-zero (sign changes) ----
    for (int f = 0; f < 4; f++) begin
      repeat (500) check(f[2:0], $urandom, $urandom);
      repeat (100) check(f[2:0], $urandom % 64 - 32, $urandom % 64 - 32);
    end

    if (errors == 0) $display("PASS: tb_mul_unit");
    else             $display("FAIL: tb_mul_unit (%0d errors)", errors);
    $finish;
  end
endmodule
