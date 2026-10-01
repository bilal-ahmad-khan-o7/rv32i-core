`timescale 1ns/1ps
// riscv_pkg.sv - shared constants for the single-cycle RV32I core.
// One definition, imported by the ALU, the control unit and the testbenches,
// so the codes cannot drift apart (PDF Lesson 7.2.1).
// Icarus needs this file listed FIRST on the command line.
package riscv_pkg;

  // ---- Opcodes: instr[6:0] (Lesson 6, Table 9.2) --------------------------
  localparam logic [6:0] OP_LOAD   = 7'b0000011;  // lb lh lw lbu lhu
  localparam logic [6:0] OP_FENCE  = 7'b0001111;  // fence (treated as nop)
  localparam logic [6:0] OP_IMM    = 7'b0010011;  // addi slti ... srai
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_STORE  = 7'b0100011;  // sb sh sw
  localparam logic [6:0] OP_REG    = 7'b0110011;  // add sub ... and
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;  // beq bne blt bge bltu bgeu
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;  // ecall ebreak (halt in sim)
  // custom-0 (7'b0001011) is reserved for the SIMD extension (Lesson 12).

  // ---- ALU operations (Lesson 7.2.1) --------------------------------------
  localparam logic [3:0] ALU_ADD   = 4'd0;   // add addi, loads, stores, jalr, auipc
  localparam logic [3:0] ALU_SUB   = 4'd1;   // sub
  localparam logic [3:0] ALU_SLL   = 4'd2;   // sll slli
  localparam logic [3:0] ALU_SLT   = 4'd3;   // slt slti
  localparam logic [3:0] ALU_SLTU  = 4'd4;   // sltu sltiu
  localparam logic [3:0] ALU_XOR   = 4'd5;   // xor xori
  localparam logic [3:0] ALU_SRL   = 4'd6;   // srl srli
  localparam logic [3:0] ALU_SRA   = 4'd7;   // sra srai
  localparam logic [3:0] ALU_OR    = 4'd8;   // or ori
  localparam logic [3:0] ALU_AND   = 4'd9;   // and andi
  localparam logic [3:0] ALU_PASSB = 4'd10;  // lui (y = b)

  // ---- Immediate formats (Lesson 7.3) -------------------------------------
  localparam logic [2:0] IMM_I = 3'd0;
  localparam logic [2:0] IMM_S = 3'd1;
  localparam logic [2:0] IMM_B = 3'd2;
  localparam logic [2:0] IMM_U = 3'd3;
  localparam logic [2:0] IMM_J = 3'd4;

  // ---- Write-back select (Lesson 8.4) -------------------------------------
  localparam logic [1:0] WB_ALU = 2'd0;  // ALU result
  localparam logic [1:0] WB_MEM = 2'd1;  // loaded data
  localparam logic [1:0] WB_PC4 = 2'd2;  // pc + 4 (jal, jalr)

  // ---- Misc ----------------------------------------------------------------
  localparam logic [31:0] NOP = 32'h0000_0013;  // addi x0, x0, 0

endpackage
