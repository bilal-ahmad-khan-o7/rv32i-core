`timescale 1ns/1ps
// imm_gen.sv - immediate generator.
// Five fixed wirings of instruction bits and a 5-to-1 mux. Every line must
// total 32 bits; the sign bit is always instr[31].
module imm_gen
  import riscv_pkg::*;
(
  input  logic [31:0] instr,
  input  logic [2:0]  imm_sel,
  output logic [31:0] imm
);
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  // The five wirings (count the bits: each line totals 32).
  assign imm_i = {{20{instr[31]}}, instr[31:20]};                                // 20+12
  assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};                   // 20+7+5
  assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25],
                  instr[11:8], 1'b0};                                            // 19+1+1+6+4+1
  assign imm_u = {instr[31:12], 12'b0};                                          // 20+12, no sign-extension
  assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20],
                  instr[30:21], 1'b0};                                           // 11+1+8+1+10+1

  // The 5-to-1 mux.
  always_comb begin
    case (imm_sel)
      IMM_I:   imm = imm_i;
      IMM_S:   imm = imm_s;
      IMM_B:   imm = imm_b;
      IMM_U:   imm = imm_u;
      IMM_J:   imm = imm_j;
      default: imm = 32'b0;
    endcase
  end
endmodule
