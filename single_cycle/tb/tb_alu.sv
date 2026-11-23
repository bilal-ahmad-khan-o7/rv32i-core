`timescale 1ns/1ps
// tb_alu.sv - ALU.
// Part 1: edge cases with HAND-WORKED expected values (checks RISC-V semantics).
// Part 2: random data for every operation against a behavioural model
//         (checks the multiplexing and the alu_op codes).
module tb_alu;
  import riscv_pkg::*;

  logic [31:0] a, b, y;
  logic [3:0]  alu_op;
  int          errors = 0;

  alu dut (.a(a), .b(b), .alu_op(alu_op), .y(y));

  function automatic logic [31:0] model(input logic [31:0] ma, mb, input logic [3:0] op);
    case (op)
      ALU_ADD:   return ma + mb;
      ALU_SUB:   return ma - mb;
      ALU_SLL:   return ma << mb[4:0];
      ALU_SLT:   return ($signed(ma) < $signed(mb)) ? 32'd1 : 32'd0;
      ALU_SLTU:  return (ma < mb) ? 32'd1 : 32'd0;
      ALU_XOR:   return ma ^ mb;
      ALU_SRL:   return ma >> mb[4:0];
      ALU_SRA:   return $unsigned($signed(ma) >>> mb[4:0]);
      ALU_OR:    return ma | mb;
      ALU_AND:   return ma & mb;
      ALU_PASSB: return mb;
      default:   return 32'd0;
    endcase
  endfunction

  task automatic check_exp(input logic [31:0] ta, tb, input logic [3:0] op,
                           input logic [31:0] expect_y, input string what);
    a = ta; b = tb; alu_op = op; #1;
    if (y !== expect_y) begin
      $display("FAIL: %s: a=%h b=%h op=%0d -> y=%h, expected %h", what, ta, tb, op, y, expect_y);
      errors++;
    end
  endtask

  task automatic check(input logic [31:0] ta, tb, input logic [3:0] op);
    check_exp(ta, tb, op, model(ta, tb, op), "random");
  endtask

  initial begin
    // ---- edge cases, expected values worked out by hand ----
    check_exp(32'h8000_0000, 32'd1,  ALU_SRA,  32'hC000_0000, "arithmetic shift keeps the sign");
    check_exp(32'h8000_0000, 32'd1,  ALU_SRL,  32'h4000_0000, "logical shift does not");
    check_exp(32'hFFFF_FFFF, 32'd1,  ALU_SLT,  32'd1,         "-1 < 1 signed");
    check_exp(32'hFFFF_FFFF, 32'd1,  ALU_SLTU, 32'd0,         "huge > 1 unsigned");
    check_exp(32'd1,         32'd33, ALU_SLL,  32'd2,         "only the low 5 bits shift");
    check_exp(32'hFFFF_FFFF, 32'd1,  ALU_ADD,  32'd0,         "add wraps to 0");
    check_exp(32'd0,         32'd1,  ALU_SUB,  32'hFFFF_FFFF, "0 - 1 = FFFFFFFF");
    check_exp(32'h7FFF_FFFF, 32'd1,  ALU_ADD,  32'h8000_0000, "signed overflow wraps");
    check_exp(32'h8000_0000, 32'h7FFF_FFFF, ALU_SLT, 32'd1,   "INT_MIN < INT_MAX signed");
    check_exp(32'h8000_0000, 32'h7FFF_FFFF, ALU_SLTU, 32'd0,  "0x80000000 > 0x7FFFFFFF unsigned");
    check_exp(32'hFFFF_FFFD, 32'd31, ALU_SRA,  32'hFFFF_FFFF, "sra by 31 of a negative");
    check_exp(32'hF0F0_F0F0, 32'h0FF0_0FF0, ALU_XOR, 32'hFF00_FF00, "xor");
    check_exp(32'hF0F0_F0F0, 32'h0FF0_0FF0, ALU_OR,  32'hFFF0_FFF0, "or");
    check_exp(32'hF0F0_F0F0, 32'h0FF0_0FF0, ALU_AND, 32'h00F0_00F0, "and");
    check_exp(32'h1234_5678, 32'hABCD_E000, ALU_PASSB, 32'hABCD_E000, "passb ignores a (lui)");
    check_exp(32'hDEAD_BEEF, 32'd0,  4'd15,    32'd0,         "unused op code gives 0");

    // ---- every operation, random data ----
    for (int op = 0; op <= 10; op++)
      repeat (200) check($urandom, $urandom, op[3:0]);
    // small shift amounts and values near zero are where bugs hide
    for (int op = 0; op <= 10; op++)
      repeat (100) check($urandom % 8 - 4, $urandom % 40, op[3:0]);

    if (errors == 0) $display("PASS: tb_alu");
    else             $display("FAIL: tb_alu (%0d errors)", errors);
    $finish;
  end
endmodule
