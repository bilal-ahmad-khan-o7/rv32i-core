`timescale 1ns/1ps
// nn_unit.sv - custom-0 INT8 instructions for quantised NN inference.
//
// DOT4.S8 rd, rs1, rs2   (funct3 001)
//   rd = rd + a0*b0 + a1*b1 + a2*b2 + a3*b3
//   a_i = signed byte i of rs1 (bits 8i+7:8i), b_i = the same byte of rs2.
//   Each product is 16-bit signed; the sum of four fits in 18 bits
//   (largest magnitude 4 * (-128 * -128) = 65536). The add into rd wraps
//   modulo 2^32: no saturation. `acc` is the OLD rd (register-file port 3).
//
// CLIP.S8 rd, rs1        (funct3 010, rs2 field must be 0)
//   rd = max(-128, min(127, signed(rs1))), sign-extended to 32 bits.
//   rs1 is already in range when bits 31..7 are all copies of the sign.
module nn_unit
  import riscv_pkg::*;
(
  input  logic [31:0] a,          // rs1
  input  logic [31:0] b,          // rs2
  input  logic [31:0] acc,        // rs3 = old value of rd (DOT4.S8 accumulator)
  input  logic [2:0]  funct3,
  output logic [31:0] y
);
  // ---- DOT4.S8 ----------------------------------------------------------
  // NN_USE_DSP (fpga/build.tcl ... dsp) asks Vivado to build the four products in DSP
  // blocks instead of LUTs. It is a synthesis attribute only: the logic is the same.
`ifdef NN_USE_DSP
  (* use_dsp = "yes" *)
`endif
  logic signed [15:0] p0, p1, p2, p3;      // the four lane products
  logic signed [17:0] dot;                 // their sum
  logic        [31:0] dot4_y;

  assign p0 = $signed(a[ 7: 0]) * $signed(b[ 7: 0]);
  assign p1 = $signed(a[15: 8]) * $signed(b[15: 8]);
  assign p2 = $signed(a[23:16]) * $signed(b[23:16]);
  assign p3 = $signed(a[31:24]) * $signed(b[31:24]);

  assign dot    = p0 + p1 + p2 + p3;                  // operands sign-extended to 18 bits
  assign dot4_y = acc + {{14{dot[17]}}, dot};         // sign-extend to 32, wrap mod 2^32

  // ---- CLIP.S8 ----------------------------------------------------------
  logic        fits;                       // -128 <= rs1 <= 127
  logic [31:0] clip_y;

  assign fits   = (a[31:7] == {25{a[31]}});
  assign clip_y = fits  ? a            :
                  a[31] ? 32'hFFFF_FF80 :  // below -128 -> -128
                          32'h0000_007F;   // above  127 ->  127

  // ---- which instruction -------------------------------------------------
  always_comb begin
    case (funct3)
      F3_CLIP_S8: y = clip_y;
      default:    y = dot4_y;              // F3_DOT4_S8
    endcase
  end
endmodule
