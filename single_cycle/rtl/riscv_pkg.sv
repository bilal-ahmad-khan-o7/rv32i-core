`timescale 1ns/1ps
// riscv_pkg.sv - shared constants for the single-cycle RV32I core.
// One definition, imported by the ALU, the control unit and the testbenches,
// so the codes cannot drift apart.
// Icarus needs this file listed FIRST on the command line.
package riscv_pkg;

  // ---- Opcodes: instr[6:0] ------------------------------------------------
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
  localparam logic [6:0] OP_CUSTOM0 = 7'b0001011; // custom-0: the INT8 instructions (R format)

  // ---- custom-0 instructions (funct7 = 0000000; others illegal) -----------
  localparam logic [2:0] F3_DOT4_S8 = 3'b001;     // rd = rd + dot(rs1, rs2), 4 x signed int8
  localparam logic [2:0] F3_CLIP_S8 = 3'b010;     // rd = clamp(rs1, -128, 127); rs2 field must be 0

  // ---- funct7 values that are defined (instr[31:25]) ----------------------
  // Every other funct7 on OP, and on the OP-IMM shifts, is illegal.
  localparam logic [6:0] F7_BASE   = 7'b0000000;  // add sll ... and, slli srli
  localparam logic [6:0] F7_ALT    = 7'b0100000;  // sub sra, srai
  localparam logic [6:0] F7_MULDIV = 7'b0000001;  // M: funct3 0xx = mul mulh mulhsu mulhu
                                                  //    funct3 1xx = div/rem (not in Zmmul: illegal)

  // ---- ALU operations -----------------------------------------------------
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

  // ---- Immediate formats --------------------------------------------------
  localparam logic [2:0] IMM_I = 3'd0;
  localparam logic [2:0] IMM_S = 3'd1;
  localparam logic [2:0] IMM_B = 3'd2;
  localparam logic [2:0] IMM_U = 3'd3;
  localparam logic [2:0] IMM_J = 3'd4;

  // ---- Write-back select --------------------------------------------------
  localparam logic [1:0] WB_ALU = 2'd0;  // ALU result
  localparam logic [1:0] WB_MEM = 2'd1;  // loaded data
  localparam logic [1:0] WB_PC4 = 2'd2;  // pc + 4 (jal, jalr)

  // ---- Execute-unit select: which unit produces ex_result -----------------
  // The choice is made inside ex_stage, so every later stage (and, in the
  // pipeline, every forwarding path) still sees one result per instruction.
  localparam logic [1:0] EX_ALU = 2'd0;  // alu.sv: all RV32I operations
  localparam logic [1:0] EX_MUL = 2'd1;  // mul_unit.sv: Zmmul
  localparam logic [1:0] EX_NN  = 2'd2;  // nn_unit.sv: custom-0 INT8 instructions

  // ---- Misc ----------------------------------------------------------------
  localparam logic [31:0] NOP = 32'h0000_0013;  // addi x0, x0, 0

endpackage
