`timescale 1ns/1ps
// alu.sv - arithmetic and logic unit.
// Every unit computes every cycle; alu_op selects the answer.
module alu
  import riscv_pkg::*;
(
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [3:0]  alu_op,
  output logic [31:0] y
);
  logic [4:0] shamt;
  assign shamt = b[4:0];                    // RV32I shifts use only the low 5 bits

  always_comb begin
    case (alu_op)
      ALU_ADD:   y = a + b;
      ALU_SUB:   y = a - b;
      ALU_SLL:   y = a << shamt;
      ALU_SLT:   y = {31'b0, ($signed(a) < $signed(b))};
      ALU_SLTU:  y = {31'b0, (a < b)};
      ALU_XOR:   y = a ^ b;
      ALU_SRL:   y = a >> shamt;
      ALU_SRA:   y = $signed(a) >>> shamt;
      ALU_OR:    y = a | b;
      ALU_AND:   y = a & b;
      ALU_PASSB: y = b;
      default:   y = 32'b0;
    endcase
  end
endmodule
