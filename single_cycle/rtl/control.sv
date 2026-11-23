`timescale 1ns/1ps
// control.sv - main control unit.
// Purely combinational: opcode (+ funct3, funct7) -> every select and
// enable in the datapath. Both decode levels (main + ALU control) live here.
//
//  group       reg_  src_a src_b alu_op  imm_ mem_   wb_  br/jmp/
//  (opcode)    write _pc   _imm          sel  rd/wr  sel  jalr
//  OP_REG        1    0     0    f3/f7    -   0/0    ALU  0/0/0   (Zmmul: ex_sel = EX_MUL)
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
//  OP_CUSTOM0    1    -     -    -        -   0/0    ALU  0/0/0   (ex_sel = EX_NN; see below)
//  other         0    -     -    -        -   0/0    -    0/0/0   (+illegal)
//
// funct7 is decoded in full (all 7 bits), so an undefined encoding can never
// run silently as a defined one:
//  OP_REG  funct7 0000000  all eight funct3
//          funct7 0100000  funct3 000 (sub) and 101 (sra) only
//          funct7 0000001  funct3 0xx: mul mulh mulhsu mulhu (Zmmul, ex_sel = EX_MUL)
//                          funct3 1xx: div divu rem remu -> illegal (no divider)
//          any other       illegal
//  OP_IMM  funct3 001 (slli)        funct7 must be 0000000
//          funct3 101 (srli/srai)   funct7 must be 0000000 / 0100000
//          other funct3             funct7 is part of the immediate
//  custom-0 funct7 0000000, funct3 001: DOT4.S8 (rs3_read: rd is also a source)
//          funct7 0000000, funct3 010, rs2 field 00000: CLIP.S8 (one source)
//          any other                illegal (CLIP.S8 with rs2 != 0 included)
module control
  import riscv_pkg::*;
(
  input  logic [6:0] opcode,
  input  logic [2:0] funct3,
  input  logic [6:0] funct7,         // instr[31:25]
  input  logic [4:0] rs2_addr,       // instr[24:20]: must be 0 for CLIP.S8
  output logic       reg_write,
  output logic       alu_src_a_pc,   // mux A: 1 = pc,  0 = rs1
  output logic       alu_src_b_imm,  // mux B: 1 = imm, 0 = rs2
  output logic [3:0] alu_op,
  output logic [1:0] ex_sel,         // which execute unit produces the result (EX_*)
  output logic       rs3_read,       // rd is read as a third source (DOT4.S8); unused in
                                     // single-cycle, kept for the pipeline's hazard check
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
  // ---- funct7 checks (slices and compares in assigns, not in always_comb) --
  logic funct7_5;                                        // instr[30]
  logic f7_base, f7_alt, f7_muldiv;
  logic op_reg_ok, op_mul_ok, shift_imm_ok;
  logic dot4_ok, clip_ok;

  assign funct7_5  = funct7[5];
  assign f7_base   = (funct7 == F7_BASE);
  assign f7_alt    = (funct7 == F7_ALT);
  assign f7_muldiv = (funct7 == F7_MULDIV);

  // OP: 0000000 for every funct3; 0100000 only for sub (000) and sra (101).
  assign op_reg_ok    = f7_base | (f7_alt & (funct3 == 3'b000 || funct3 == 3'b101));
  // Zmmul: the multiplies (funct3 0xx) only; div/rem (1xx) stay illegal.
  assign op_mul_ok    = f7_muldiv & ~funct3[2];
  // OP-IMM: funct7 is a real field only for the shifts (it is shamt[11:5]).
  assign shift_imm_ok = (funct3 == 3'b001) ? f7_base :
                        (funct3 == 3'b101) ? (f7_base | f7_alt) : 1'b1;
  // custom-0: each instruction is one exact funct3/funct7 pair.
  assign dot4_ok      = f7_base & (funct3 == F3_DOT4_S8);
  assign clip_ok      = f7_base & (funct3 == F3_CLIP_S8) & (rs2_addr == 5'd0);

  // ---- ALU operation for OP-IMM and OP instructions ---------
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

  // ---- Main decode ------------------------------------------
  always_comb begin
    // ---- safe defaults: do nothing --------------------------
    reg_write     = 1'b0;  alu_src_a_pc = 1'b0;  alu_src_b_imm = 1'b0;
    alu_op        = ALU_ADD;  ex_sel    = EX_ALU;  imm_sel      = IMM_I;
    mem_read      = 1'b0;  rs3_read     = 1'b0;
    mem_write     = 1'b0;  wb_sel       = WB_ALU;  branch       = 1'b0;
    jump          = 1'b0;  jalr         = 1'b0;   illegal       = 1'b0;
    system        = 1'b0;

    case (opcode)
      OP_REG: begin
        if (op_reg_ok) begin
          reg_write = 1'b1;
          // instr[30] means "subtract" ONLY here; for addi it is an immediate bit.
          alu_op    = (funct3 == 3'b000 && funct7_5) ? ALU_SUB : arith_op;
        end else if (op_mul_ok) begin
          reg_write = 1'b1;
          ex_sel    = EX_MUL;                             // mul_unit decodes funct3 itself
        end else
          illegal   = 1'b1;
      end
      OP_IMM: begin
        if (shift_imm_ok) begin
          reg_write     = 1'b1;
          alu_src_b_imm = 1'b1;
          imm_sel       = IMM_I;
          alu_op        = arith_op;                       // note: no "subi" exists
        end else
          illegal       = 1'b1;
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
      OP_CUSTOM0: begin
        if (dot4_ok) begin
          reg_write = 1'b1;
          ex_sel    = EX_NN;                              // nn_unit decodes funct3 itself
          rs3_read  = 1'b1;                               // accumulator = old rd
        end else if (clip_ok) begin
          reg_write = 1'b1;
          ex_sel    = EX_NN;
        end else
          illegal   = 1'b1;
      end
      OP_FENCE: ;                                         // nop on a single in-order core
      OP_SYSTEM: system  = 1'b1;                          // ecall / ebreak: the testbench stops
      default:   illegal = 1'b1;
    endcase
  end
endmodule
