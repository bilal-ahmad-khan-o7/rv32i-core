`timescale 1ns/1ps
// tb_control.sv - control unit, directed (PDF Lesson 9.5 and exercise 9.9.3).
// Part 1: one check per row of Table 9.2. An expected value of x means
//         "does not matter" (the table's dash) and is not compared.
//         reg_write and mem_write are NEVER don't-cares.
// Part 2: sweep all 128 opcodes x 8 funct3 x 2 funct7_5 and check invariants.
module tb_control;
  import riscv_pkg::*;

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic       funct7_5;
  logic       reg_write, alu_src_a_pc, alu_src_b_imm, mem_read, mem_write;
  logic       branch, jump, jalr, illegal, system;
  logic [3:0] alu_op;
  logic [2:0] imm_sel;
  logic [1:0] wb_sel;
  logic [21:0] all_outs;                     // every output, for the X/Z check in the sweep
  int         errors = 0;

  localparam logic X = 1'bx;

  control dut (
    .opcode(opcode), .funct3(funct3), .funct7_5(funct7_5),
    .reg_write(reg_write), .alu_src_a_pc(alu_src_a_pc), .alu_src_b_imm(alu_src_b_imm),
    .alu_op(alu_op), .imm_sel(imm_sel), .mem_read(mem_read), .mem_write(mem_write),
    .wb_sel(wb_sel), .branch(branch), .jump(jump), .jalr(jalr),
    .illegal(illegal), .system(system));

  // Compare the low `w` bits; an x in the expected value is a don't-care.
  function automatic bit ok(input logic [3:0] e, input logic [3:0] g, input int w);
    for (int i = 0; i < w; i++)
      if (e[i] !== 1'bx && e[i] !== g[i]) return 1'b0;
    return 1'b1;
  endfunction

  task automatic check(input string what,
                       input logic [6:0] op, input logic [2:0] f3, input logic f7,
                       input logic e_rw, input logic e_a, input logic e_b,
                       input logic [3:0] e_alu, input logic [2:0] e_imm,
                       input logic e_mr, input logic e_mw, input logic [1:0] e_wb,
                       input logic e_br, input logic e_j, input logic e_jr,
                       input logic e_ill, input logic e_sys);
    opcode = op; funct3 = f3; funct7_5 = f7; #1;
    if (!(ok(e_rw, reg_write, 1) && ok(e_a, alu_src_a_pc, 1) && ok(e_b, alu_src_b_imm, 1) &&
          ok(e_alu, alu_op, 4) && ok(e_imm, imm_sel, 3) && ok(e_mr, mem_read, 1) &&
          ok(e_mw, mem_write, 1) && ok(e_wb, wb_sel, 2) && ok(e_br, branch, 1) &&
          ok(e_j, jump, 1) && ok(e_jr, jalr, 1) && ok(e_ill, illegal, 1) &&
          ok(e_sys, system, 1))) begin
      $display("FAIL: %-26s rw=%b a_pc=%b b_imm=%b alu=%0d imm=%0d mr=%b mw=%b wb=%0d br=%b j=%b jr=%b ill=%b sys=%b",
               what, reg_write, alu_src_a_pc, alu_src_b_imm, alu_op, imm_sel, mem_read,
               mem_write, wb_sel, branch, jump, jalr, illegal, system);
      errors++;
    end
  endtask

  function automatic bit known_opcode(input logic [6:0] op);   // (Icarus has no `inside` yet)
    case (op)
      OP_REG, OP_IMM, OP_LOAD, OP_STORE, OP_BRANCH, OP_LUI,
      OP_AUIPC, OP_JAL, OP_JALR, OP_FENCE, OP_SYSTEM: return 1'b1;
      default:                                         return 1'b0;
    endcase
  endfunction

  initial begin
    //                                  op        f3      f7   rw a  b  alu        imm    mr mw wb      br j  jr ill sys
    // ---- R format: operation from funct3 / funct7 ----
    check("add",                         OP_REG,   3'b000, 0,   1, 0, 0, ALU_ADD,  'x,    0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("sub",                         OP_REG,   3'b000, 1,   1, 0, 0, ALU_SUB,  'x,    0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("sll",                         OP_REG,   3'b001, 0,   1, 0, 0, ALU_SLL,  'x,    0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("slt",                         OP_REG,   3'b010, 0,   1, 0, 0, ALU_SLT,  'x,    0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("sltu",                        OP_REG,   3'b011, 0,   1, 0, 0, ALU_SLTU, 'x,    0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("xor",                         OP_REG,   3'b100, 0,   1, 0, 0, ALU_XOR,  'x,    0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("srl",                         OP_REG,   3'b101, 0,   1, 0, 0, ALU_SRL,  'x,    0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("sra",                         OP_REG,   3'b101, 1,   1, 0, 0, ALU_SRA,  'x,    0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("or",                          OP_REG,   3'b110, 0,   1, 0, 0, ALU_OR,   'x,    0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("and",                         OP_REG,   3'b111, 0,   1, 0, 0, ALU_AND,  'x,    0, 0, WB_ALU, 0, 0, 0, 0,  0);
    // ---- I format arithmetic: instr[30] is an IMMEDIATE bit, except for srai ----
    check("addi (imm bit 30 = 0)",       OP_IMM,   3'b000, 0,   1, 0, 1, ALU_ADD,  IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("addi x1,x1,-1 (bit 30 = 1)",  OP_IMM,   3'b000, 1,   1, 0, 1, ALU_ADD,  IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("slti",                        OP_IMM,   3'b010, 1,   1, 0, 1, ALU_SLT,  IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("sltiu",                       OP_IMM,   3'b011, 0,   1, 0, 1, ALU_SLTU, IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("xori",                        OP_IMM,   3'b100, 1,   1, 0, 1, ALU_XOR,  IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("ori",                         OP_IMM,   3'b110, 0,   1, 0, 1, ALU_OR,   IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("andi",                        OP_IMM,   3'b111, 1,   1, 0, 1, ALU_AND,  IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("slli",                        OP_IMM,   3'b001, 0,   1, 0, 1, ALU_SLL,  IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("srli",                        OP_IMM,   3'b101, 0,   1, 0, 1, ALU_SRL,  IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("srai",                        OP_IMM,   3'b101, 1,   1, 0, 1, ALU_SRA,  IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0,  0);
    // ---- loads and stores (every size) ----
    for (int f = 0; f < 8; f++) begin
      check("load",                      OP_LOAD,  f[2:0], X,   1, 0, 1, ALU_ADD,  IMM_I, 1, 0, WB_MEM, 0, 0, 0, 0,  0);
      check("store",                     OP_STORE, f[2:0], X,   0, 0, 1, ALU_ADD,  IMM_S, X, 1, 'x,     0, 0, 0, 0,  0);
      check("branch",                    OP_BRANCH,f[2:0], X,   0, X, X, 'x,       IMM_B, X, 0, 'x,     1, 0, 0, 0,  0);
    end
    // ---- upper immediates and jumps ----
    check("lui",                         OP_LUI,   3'b000, 0,   1, X, 1, ALU_PASSB,IMM_U, X, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("auipc",                       OP_AUIPC, 3'b000, 0,   1, 1, 1, ALU_ADD,  IMM_U, X, 0, WB_ALU, 0, 0, 0, 0,  0);
    check("jal",                         OP_JAL,   3'b000, 0,   1, X, X, 'x,       IMM_J, X, 0, WB_PC4, 0, 1, 0, 0,  0);
    check("jalr",                        OP_JALR,  3'b000, 0,   1, 0, 1, ALU_ADD,  IMM_I, X, 0, WB_PC4, 0, 0, 1, 0,  0);
    // ---- system ----
    check("fence (nop)",                 OP_FENCE, 3'b000, 0,   0, X, X, 'x,       'x,    X, 0, 'x,     0, 0, 0, 0,  0);
    check("ecall / ebreak",              OP_SYSTEM,3'b000, 0,   0, X, X, 'x,       'x,    X, 0, 'x,     0, 0, 0, 0,  1);
    // ---- illegal ----
    check("all-zero word",               7'b0000000, 3'b000, 0, 0, X, X, 'x,       'x,    X, 0, 'x,     0, 0, 0, 1,  0);
    check("all-ones word",               7'b1111111, 3'b111, 1, 0, X, X, 'x,       'x,    X, 0, 'x,     0, 0, 0, 1,  0);
    check("custom-0 (reserved: SIMD)",   7'b0001011, 3'b000, 0, 0, X, X, 'x,       'x,    X, 0, 'x,     0, 0, 0, 1,  0);

    // ---- sweep every input: invariants that must always hold ----
    for (int op = 0; op < 128; op++)
      for (int f = 0; f < 8; f++)
        for (int s = 0; s < 2; s++) begin
          opcode = op[6:0]; funct3 = f[2:0]; funct7_5 = s[0]; #1;
          all_outs = {reg_write, alu_src_a_pc, alu_src_b_imm, alu_op, imm_sel, mem_read,
                      mem_write, wb_sel, branch, jump, jalr, illegal, system};
          if (^all_outs === 1'bx) begin              // reduction XOR is x if any bit is x/z
            $display("FAIL: sweep op=%b f3=%b f7_5=%b: an output is X/Z: rw=%b a=%b b=%b alu=%b imm=%b mr=%b mw=%b wb=%b br=%b j=%b jr=%b ill=%b sys=%b",
                     opcode, funct3, funct7_5, reg_write, alu_src_a_pc, alu_src_b_imm, alu_op, imm_sel,
                     mem_read, mem_write, wb_sel, branch, jump, jalr, illegal, system);
            errors++;
          end
          if (illegal !== !known_opcode(opcode)) begin
            $display("FAIL: sweep op=%b: illegal=%b", opcode, illegal); errors++;
          end
          if (illegal && (reg_write || mem_write || branch || jump || jalr || system)) begin
            $display("FAIL: sweep op=%b: illegal instruction changes state", opcode); errors++;
          end
          if ((opcode == OP_STORE || opcode == OP_BRANCH) && reg_write) begin
            $display("FAIL: sweep op=%b: reg_write set, instr[11:7] is an immediate here", opcode); errors++;
          end
          if (mem_write && opcode != OP_STORE) begin
            $display("FAIL: sweep op=%b: mem_write outside stores", opcode); errors++;
          end
          if (int'(branch) + int'(jump) + int'(jalr) > 1) begin
            $display("FAIL: sweep op=%b: more than one of branch/jump/jalr", opcode); errors++;
          end
        end

    if (errors == 0) $display("PASS: tb_control");
    else             $display("FAIL: tb_control (%0d errors)", errors);
    $finish;
  end
endmodule
