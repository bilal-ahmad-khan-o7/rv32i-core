`timescale 1ns/1ps
// wb_stage.sv - Write Back.
// Chooses what is written to rd: the ALU result, the loaded data, or pc+4.
// The value goes back to id_stage's register-file write port and is stored
// at the next clock edge.
module wb_stage
  import riscv_pkg::*;
(
  input  logic [1:0]  wb_sel,
  input  logic [31:0] alu_y,
  input  logic [31:0] load_data,
  input  logic [31:0] pc_plus4,
  output logic [31:0] wb_data
);
  always_comb begin
    case (wb_sel)
      WB_MEM:  wb_data = load_data;
      WB_PC4:  wb_data = pc_plus4;
      default: wb_data = alu_y;                    // WB_ALU
    endcase
  end
endmodule
