`timescale 1ns/1ps
// mul_unit.sv - Zmmul: the multiply half of the RISC-V M extension.
// One 33 x 33 signed multiplier serves all four instructions. Each operand
// gets a 33rd bit: a copy of its sign bit if the instruction treats it as
// signed, 0 if unsigned. The 66-bit signed product then holds the exact
// 64-bit result of every combination.
//
//   funct3  instr    rs1       rs2       result
//   000     mul      either    either    product[31:0]
//   001     mulh     signed    signed    product[63:32]
//   010     mulhsu   signed    unsigned  product[63:32]
//   011     mulhu    unsigned  unsigned  product[63:32]
//
// funct3 1xx (div/rem) never reaches here: control flags them illegal.
module mul_unit (
  input  logic [31:0] a,          // rs1
  input  logic [31:0] b,          // rs2
  input  logic [2:0]  funct3,
  output logic [31:0] y
);
  logic        a_signed, b_signed;
  logic [32:0] a_ext, b_ext;
  logic [65:0] product;

  assign a_signed = (funct3[1:0] != 2'b11);            // mulh, mulhsu (and mul: low bits are the same)
  assign b_signed = (funct3[1:0] == 2'b01);            // mulh only
  assign a_ext    = {a_signed & a[31], a};
  assign b_ext    = {b_signed & b[31], b};

  assign product  = $signed(a_ext) * $signed(b_ext);   // 33 x 33 -> 66 bits, exact

  assign y = (funct3[1:0] == 2'b00) ? product[31:0]    // mul: low half
                                    : product[63:32];  // mulh*: high half
endmodule
