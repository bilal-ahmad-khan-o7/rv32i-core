`timescale 1ns/1ps
// control.sv - main control unit (PDF Lesson 9, Table 9.2, Listings 9.1-9.2).
// Purely combinational: opcode (+ funct3, instr[30]) -> every select and
// enable in the datapath. Both decode levels (main + ALU control) live here.
//
//  group       reg_  src_a src_b alu_op  imm_ mem_   wb_  br/jmp/
//  (opcode)    write _pc   _imm          sel  rd/wr  sel  jalr
//  OP_REG        1    0     0    f3/f7    -   0/0    ALU  0/0/0
//  OP_IMM        1    0     1    f3       I   0/0    ALU  0/0/0
//  OP_LOAD       1    0     1    ADD      I   1/0    MEM  0/0/0
//  OP_STORE      0    0     1    ADD      S   0/1    -    0/0/0
//  OP_BRANCH     0    -     -    -        B   0/0    -    1/0/0
//  OP_LUI        1    -     1    PASSB    U   0/0    ALU  0/0/0
//  OP_AUIPC      1    1     1    ADD      U   0/0    ALU  0/0/0
//  OP_JAL        1    -     -    -        J   0/0    PC4  0/1/0
//  OP_JALR       1    0     1    ADD      I   0/0    PC4  0/0/1
//  OP_FENCE      0    -     -    -        -   0/0    -    0/0/0   (nop)
//  OP_SYSTEM     0    -     -    -        -   0/0    -    0/0/0   (+system: halt)
//  other         0    -     -    -        -   0/0    -    0/0/0   (+illegal)
module control
  import riscv_pkg::*;
(
  input  logic [6:0] opcode,
  input  logic [2:0] funct3,
  input  logic       funct7_5,       // instr[30]
  output logic       reg_write,
  output logic       alu_src_a_pc,   // mux A: 1 = pc,  0 = rs1
  output logic       alu_src_b_imm,  // mux B: 1 = imm, 0 = rs2
  output logic [3:0] alu_op,
  output logic [2:0] imm_sel,
  output logic       mem_read,       // unused in single-cycle; kept for the pipeline's load-use check
  output logic       mem_write,
  output logic [1:0] wb_sel,
  output logic       branch,
  output logic       jump,           // jal
  output logic       jalr,
  output logic       illegal,
  output logic       system          // ecall / ebreak
);
  // ---- ALU operation for OP-IMM and OP instructions (Listing 9.1) ---------
  logic [3:0] arith_op;
  always_comb begin
    case (funct3)
      3'b000:  arith_op = ALU_ADD;                        // add / addi (sub handled below)
      3'b001:  arith_op = ALU_SLL;
      3'b010:  arith_op = ALU_SLT;
      3'b011:  arith_op = ALU_SLTU;
      3'b100:  arith_op = ALU_XOR;
      3'b101:  arith_op = funct7_5 ? ALU_SRA : ALU_SRL;   // shifts use instr[30] in BOTH formats
      3'b110:  arith_op = ALU_OR;
      default: arith_op = ALU_AND;                        // 3'b111
    endcase
  end

  // ---- Main decode (Listing 9.2) ------------------------------------------
  always_comb begin
    // ---- safe defaults: do nothing ----
    reg_write     = 1'b0;  alu_src_a_pc = 1'b0;  alu_src_b_imm = 1'b0;
    alu_op        = ALU_ADD;  imm_sel   = IMM_I;  mem_read      = 1'b0;
    mem_write     = 1'b0;  wb_sel       = WB_ALU;  branch       = 1'b0;
    jump          = 1'b0;  jalr         = 1'b0;   illegal       = 1'b0;
    system        = 1'b0;

    case (opcode)
      OP_REG: begin
        reg_write = 1'b1;
        // instr[30] means "subtract" ONLY here; for addi it is an immediate bit.
        alu_op    = (funct3 == 3'b000 && funct7_5) ? ALU_SUB : arith_op;
      end
      OP_IMM: begin
        reg_write     = 1'b1;
        alu_src_b_imm = 1'b1;
        imm_sel       = IMM_I;
        alu_op        = arith_op;                         // note: no "subi" exists
      end
      OP_LOAD: begin
        reg_write     = 1'b1;  alu_src_b_imm = 1'b1;  imm_sel = IMM_I;
        alu_op        = ALU_ADD;                          // address = rs1 + imm
        mem_read      = 1'b1;  wb_sel        = WB_MEM;
      end
      OP_STORE: begin
        alu_src_b_imm = 1'b1;  imm_sel = IMM_S;
        alu_op        = ALU_ADD;                          // address = rs1 + imm
        mem_write     = 1'b1;
      end
      OP_BRANCH: begin
        imm_sel = IMM_B;
        branch  = 1'b1;                                   // condition from branch_unit
      end
      OP_LUI: begin
        reg_write     = 1'b1;  alu_src_b_imm = 1'b1;  imm_sel = IMM_U;
        alu_op        = ALU_PASSB;                        // rd = imm
      end
      OP_AUIPC: begin
        reg_write     = 1'b1;  alu_src_a_pc = 1'b1;  alu_src_b_imm = 1'b1;
        imm_sel       = IMM_U;  alu_op      = ALU_ADD;    // rd = pc + imm
      end
      OP_JAL: begin
        reg_write = 1'b1;  imm_sel = IMM_J;
        wb_sel    = WB_PC4;  jump  = 1'b1;
      end
      OP_JALR: begin
        reg_write     = 1'b1;  alu_src_b_imm = 1'b1;  imm_sel = IMM_I;
        alu_op        = ALU_ADD;                          // target = rs1 + imm (bit 0 cleared in ex_stage)
        wb_sel        = WB_PC4;  jalr        = 1'b1;
      end
      OP_FENCE: ;                                         // nop on a single in-order core
      OP_SYSTEM: system  = 1'b1;                          // ecall / ebreak: the testbench stops
      default:   illegal = 1'b1;
    endcase
  end
endmodule
