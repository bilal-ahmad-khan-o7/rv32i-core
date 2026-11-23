`timescale 1ns/1ps
// branch_unit.sv - branch condition (PDF Lesson 10.3, Listing 10.3).
// Compares rs1/rs2 on every instruction; take_branch only means something
// when the control unit's `branch` is 1.
module branch_unit (
  input  logic [31:0] rs1_data,
  input  logic [31:0] rs2_data,
  input  logic [2:0]  funct3,
  output logic        take_branch
);
  logic eq, lt_s, lt_u;

  assign eq   = (rs1_data == rs2_data);
  assign lt_s = ($signed(rs1_data) < $signed(rs2_data));
  assign lt_u = (rs1_data < rs2_data);

  always_comb begin
    case (funct3)
      3'b000:  take_branch =  eq;     // beq
      3'b001:  take_branch = !eq;     // bne
      3'b100:  take_branch =  lt_s;   // blt
      3'b101:  take_branch = !lt_s;   // bge
      3'b110:  take_branch =  lt_u;   // bltu
      3'b111:  take_branch = !lt_u;   // bgeu
      default: take_branch = 1'b0;    // 010, 011 do not exist
    endcase
  end
endmodule
