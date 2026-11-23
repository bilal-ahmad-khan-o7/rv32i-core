`timescale 1ns/1ps
// tb_control.sv - control unit, directed (PDF Lesson 9.5 and exercise 9.9.3).
// Part 1: one check per row of Table 9.2. An expected value of x means
//         "does not matter" (the table's dash) and is not compared.
//         reg_write and mem_write are NEVER don't-cares.
// Part 2: full-funct7 rows: Zmmul, and encodings that differ from a defined
//         one only in funct7 must be illegal (or, for OP-IMM non-shifts, an
//         immediate). div/divu/rem/remu are illegal: Zmmul has no divide.
//         custom-0: DOT4.S8 (funct7 0, funct3 001) and CLIP.S8 (funct7 0,
//         funct3 010, rs2 field 0) are defined; nothing else.
// Part 3: sweep all 128 opcodes x 8 funct3 x 128 funct7 (x all 32 rs2 fields
//         for OP and custom-0, a random rs2 elsewhere) and check invariants,
//         with `illegal` compared against an independent table (legal_ref).
module tb_control;
  import riscv_pkg::*;

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [4:0] rs2_addr = 5'd0;               // only CLIP.S8 looks at it (must be 0)
  logic       reg_write, alu_src_a_pc, alu_src_b_imm, mem_read, mem_write;
  logic       branch, jump, jalr, illegal, system, rs3_read;
  logic [3:0] alu_op;
  logic [2:0] imm_sel;
  logic [1:0] wb_sel, ex_sel;
  logic [24:0] all_outs;                     // every output, for the X/Z check in the sweep
  int         errors = 0;

  localparam logic X = 1'bx;

  control dut (
    .opcode(opcode), .funct3(funct3), .funct7(funct7), .rs2_addr(rs2_addr),
    .reg_write(reg_write), .alu_src_a_pc(alu_src_a_pc), .alu_src_b_imm(alu_src_b_imm),
    .alu_op(alu_op), .ex_sel(ex_sel), .rs3_read(rs3_read),
    .imm_sel(imm_sel), .mem_read(mem_read), .mem_write(mem_write),
    .wb_sel(wb_sel), .branch(branch), .jump(jump), .jalr(jalr),
    .illegal(illegal), .system(system));

  // Compare the low `w` bits; an x in the expected value is a don't-care.
  function automatic bit ok(input logic [3:0] e, input logic [3:0] g, input int w);
    for (int i = 0; i < w; i++)
      if (e[i] !== 1'bx && e[i] !== g[i]) return 1'b0;
    return 1'b1;
  endfunction

  // One directed check with the full 7-bit funct7.
  task automatic check7(input string what,
                        input logic [6:0] op, input logic [2:0] f3, input logic [6:0] f7,
                        input logic e_rw, input logic e_a, input logic e_b,
                        input logic [3:0] e_alu, input logic [2:0] e_imm,
                        input logic e_mr, input logic e_mw, input logic [1:0] e_wb,
                        input logic e_br, input logic e_j, input logic e_jr,
                        input logic e_ill, input logic e_sys, input logic [1:0] e_ex,
                        input logic e_r3);
    opcode = op; funct3 = f3; funct7 = f7; #1;
    if (!(ok(e_rw, reg_write, 1) && ok(e_a, alu_src_a_pc, 1) && ok(e_b, alu_src_b_imm, 1) &&
          ok(e_alu, alu_op, 4) && ok(e_imm, imm_sel, 3) && ok(e_mr, mem_read, 1) &&
          ok(e_mw, mem_write, 1) && ok(e_wb, wb_sel, 2) && ok(e_br, branch, 1) &&
          ok(e_j, jump, 1) && ok(e_jr, jalr, 1) && ok(e_ill, illegal, 1) &&
          ok(e_sys, system, 1) && ok(e_ex, ex_sel, 2) && ok(e_r3, rs3_read, 1))) begin
      $display("FAIL: %-34s rw=%b a_pc=%b b_imm=%b alu=%0d imm=%0d mr=%b mw=%b wb=%0d br=%b j=%b jr=%b ill=%b sys=%b ex=%0d r3=%b",
               what, reg_write, alu_src_a_pc, alu_src_b_imm, alu_op, imm_sel, mem_read,
               mem_write, wb_sel, branch, jump, jalr, illegal, system, ex_sel, rs3_read);
      errors++;
    end
  endtask

  // The original Table 9.2 rows give only instr[30] (funct7_5); the rest of
  // funct7 is 0, so f7 = 0 means funct7 0000000 and f7 = 1 means 0100000.
  // They are all base RV32I instructions: ex_sel = EX_ALU, rd is not read.
  task automatic check(input string what,
                       input logic [6:0] op, input logic [2:0] f3, input logic f7,
                       input logic e_rw, input logic e_a, input logic e_b,
                       input logic [3:0] e_alu, input logic [2:0] e_imm,
                       input logic e_mr, input logic e_mw, input logic [1:0] e_wb,
                       input logic e_br, input logic e_j, input logic e_jr,
                       input logic e_ill, input logic e_sys);
    check7(what, op, f3, {1'b0, f7, 5'b00000}, e_rw, e_a, e_b, e_alu, e_imm,
           e_mr, e_mw, e_wb, e_br, e_j, e_jr, e_ill, e_sys, e_ill ? 2'bxx : EX_ALU,
           e_ill ? 1'bx : 1'b0);
  endtask

  // An illegal encoding: no state may change; everything else is a don't-care.
  task automatic check_illegal(input string what,
                               input logic [6:0] op, input logic [2:0] f3, input logic [6:0] f7);
    check7(what, op, f3, f7, 0, X, X, 'x, 'x, X, 0, 'x, 0, 0, 0, 1, 0, 'x, X);
  endtask

  // A register-to-register instruction executed by an extension unit:
  // writes rd through WB_ALU, touches no memory, never redirects the PC.
  task automatic check_unit(input string what,
                            input logic [6:0] op, input logic [2:0] f3, input logic [6:0] f7,
                            input logic [1:0] e_ex, input logic e_r3);
    check7(what, op, f3, f7, 1, X, X, 'x, 'x, 0, 0, WB_ALU, 0, 0, 0, 0, 0, e_ex, e_r3);
  endtask

  // Reference: which encodings are defined. Written from the ISA tables with
  // literal bit patterns, independently of control.sv and riscv_pkg.
  // (Holes in funct3 of loads/stores/branches/jalr and SYSTEM are known
  // limitations: those opcodes are accepted for every funct3/funct7.)
  function automatic bit legal_ref(input logic [6:0] op, input logic [2:0] f3, input logic [6:0] f7,
                                   input logic [4:0] r2);
    case (op)
      7'b0110011:                                             // OP
        return (f7 == 7'b0000000) ||
               (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101)) ||
               (f7 == 7'b0000001 && f3 <= 3'b011);            // Zmmul: mul mulh mulhsu mulhu
      7'b0001011:                                             // custom-0
        return f7 == 7'b0000000 &&
               (f3 == 3'b001 ||                               // DOT4.S8
                (f3 == 3'b010 && r2 == 5'd0));                // CLIP.S8 (one source)
      7'b0010011:                                             // OP-IMM
        case (f3)
          3'b001:  return f7 == 7'b0000000;                   // slli
          3'b101:  return f7 == 7'b0000000 || f7 == 7'b0100000; // srli, srai
          default: return 1'b1;                               // funct7 is immediate bits
        endcase
      7'b0000011, 7'b0100011, 7'b1100011, 7'b0110111,         // LOAD STORE BRANCH LUI
      7'b0010111, 7'b1101111, 7'b1100111,                     // AUIPC JAL JALR
      7'b0001111, 7'b1110011:                                 // FENCE SYSTEM
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  // How many rs2 fields the sweep tries: all 32 where rs2 could matter.
  function automatic int rs2_count(input logic [6:0] op);
    return (op == 7'b0110011 || op == 7'b0001011) ? 32 : 1;
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
    check("custom-0 funct3=000 (unused)",7'b0001011, 3'b000, 0, 0, X, X, 'x,       'x,    X, 0, 'x,     0, 0, 0, 1,  0);

    // ---- full funct7: near-misses of defined encodings must be illegal ----
    check_illegal("sll with funct7 0100000",     OP_REG, 3'b001, 7'b0100000);
    check_illegal("xor with funct7 0100000",     OP_REG, 3'b100, 7'b0100000);
    check_illegal("and with funct7 0100000",     OP_REG, 3'b111, 7'b0100000);
    check_illegal("add with funct7 0000010",     OP_REG, 3'b000, 7'b0000010);
    check_illegal("sub with funct7 0100001",     OP_REG, 3'b000, 7'b0100001);
    check_illegal("sra with funct7 1100000",     OP_REG, 3'b101, 7'b1100000);
    check_illegal("div (Zmmul: no divide)",      OP_REG, 3'b100, 7'b0000001);
    check_illegal("divu (Zmmul: no divide)",     OP_REG, 3'b101, 7'b0000001);
    check_illegal("rem (Zmmul: no divide)",      OP_REG, 3'b110, 7'b0000001);
    check_illegal("remu (Zmmul: no divide)",     OP_REG, 3'b111, 7'b0000001);
    check_illegal("mul with funct7 0000011",     OP_REG, 3'b000, 7'b0000011);
    check_illegal("mulh with funct7 0100001",    OP_REG, 3'b001, 7'b0100001);
    // Zmmul: funct7 0000001, funct3 0xx -> mul_unit
    check_unit("mul",                            OP_REG, 3'b000, 7'b0000001, EX_MUL, 0);
    check_unit("mulh",                           OP_REG, 3'b001, 7'b0000001, EX_MUL, 0);
    check_unit("mulhsu",                         OP_REG, 3'b010, 7'b0000001, EX_MUL, 0);
    check_unit("mulhu",                          OP_REG, 3'b011, 7'b0000001, EX_MUL, 0);
    // custom-0: DOT4.S8 reads rd as a third source; nothing else is defined yet
    check_unit("dot4.s8",                        OP_CUSTOM0, 3'b001, 7'b0000000, EX_NN, 1);
    check_illegal("dot4.s8 with funct7 0000001", OP_CUSTOM0, 3'b001, 7'b0000001);
    check_illegal("dot4.s8 with funct7 0100000", OP_CUSTOM0, 3'b001, 7'b0100000);
    check_unit("clip.s8 (rs2 field 0)",          OP_CUSTOM0, 3'b010, 7'b0000000, EX_NN, 0);
    check_illegal("clip.s8 with funct7 0000001", OP_CUSTOM0, 3'b010, 7'b0000001);
    for (int r = 1; r < 32; r++) begin
      rs2_addr = r[4:0];
      check_illegal("clip.s8 with rs2 field != 0", OP_CUSTOM0, 3'b010, 7'b0000000);
    end
    rs2_addr = 5'd31;                            // rs2 is a real operand for these two
    check_unit("dot4.s8 with rs2 = x31",         OP_CUSTOM0, 3'b001, 7'b0000000, EX_NN, 1);
    check_unit("mul with rs2 = x31",             OP_REG,     3'b000, 7'b0000001, EX_MUL, 0);
    rs2_addr = 5'd0;
    for (int f = 3; f < 8; f++)
      check_illegal("custom-0 funct3=011..111",  OP_CUSTOM0, f[2:0], 7'b0000000);
    check_illegal("slli with funct7 0100000",    OP_IMM, 3'b001, 7'b0100000);
    check_illegal("slli with funct7 0000001",    OP_IMM, 3'b001, 7'b0000001);
    check_illegal("srli with funct7 0000001",    OP_IMM, 3'b101, 7'b0000001);
    check_illegal("srai with funct7 0100001",    OP_IMM, 3'b101, 7'b0100001);
    // funct7 is immediate bits for the other OP-IMM instructions: still legal
    //                                  op        f3      f7          rw a  b  alu       imm    mr mw wb      br j  jr ill sys
    //                                         op      f3      f7          rw a  b  alu      imm    mr mw wb      br j  jr il sy ex
    check7("addi x1,x1,-1 (funct7 1111111)",   OP_IMM, 3'b000, 7'b1111111, 1, 0, 1, ALU_ADD, IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0, 0, EX_ALU, 0);
    check7("andi with funct7 1000001",         OP_IMM, 3'b111, 7'b1000001, 1, 0, 1, ALU_AND, IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0, 0, EX_ALU, 0);
    check7("sltiu with funct7 0000001",        OP_IMM, 3'b011, 7'b0000001, 1, 0, 1, ALU_SLTU,IMM_I, 0, 0, WB_ALU, 0, 0, 0, 0, 0, EX_ALU, 0);

    // ---- sweep every input: invariants that must always hold ----
    for (int op = 0; op < 128; op++)
      for (int f = 0; f < 8; f++)
        for (int s = 0; s < 128; s++)
        for (int r = 0; r < rs2_count(op[6:0]); r++) begin
          opcode = op[6:0]; funct3 = f[2:0]; funct7 = s[6:0];
          rs2_addr = (rs2_count(op[6:0]) == 32) ? r[4:0] : 5'($urandom % 32);
          #1;
          all_outs = {reg_write, alu_src_a_pc, alu_src_b_imm, alu_op, imm_sel, mem_read,
                      mem_write, wb_sel, branch, jump, jalr, illegal, system, ex_sel, rs3_read};
          if (^all_outs === 1'bx) begin              // reduction XOR is x if any bit is x/z
            $display("FAIL: sweep op=%b f3=%b f7=%b: an output is X/Z: rw=%b a=%b b=%b alu=%b imm=%b mr=%b mw=%b wb=%b br=%b j=%b jr=%b ill=%b sys=%b ex=%b r3=%b",
                     opcode, funct3, funct7, reg_write, alu_src_a_pc, alu_src_b_imm, alu_op, imm_sel,
                     mem_read, mem_write, wb_sel, branch, jump, jalr, illegal, system, ex_sel, rs3_read);
            errors++;
          end
          if (illegal !== !legal_ref(opcode, funct3, funct7, rs2_addr)) begin
            $display("FAIL: sweep op=%b f3=%b f7=%b rs2=%0d: illegal=%b", opcode, funct3, funct7, rs2_addr, illegal); errors++;
          end
          if (illegal && (reg_write || mem_write || branch || jump || jalr || system)) begin
            $display("FAIL: sweep op=%b f3=%b f7=%b: illegal instruction changes state", opcode, funct3, funct7); errors++;
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
          // sub only for OP 000/0100000; sra only for 101/0100000 (OP and OP-IMM)
          if (!illegal && (alu_op == ALU_SUB) !==
              (opcode == OP_REG && f == 3'b000 && s == 7'b0100000)) begin
            $display("FAIL: sweep op=%b f3=%b f7=%b: alu_op=SUB is wrong here", opcode, funct3, funct7); errors++;
          end
          if (!illegal && (opcode == OP_REG || opcode == OP_IMM) && (alu_op == ALU_SRA) !==
              (f == 3'b101 && s == 7'b0100000)) begin
            $display("FAIL: sweep op=%b f3=%b f7=%b: alu_op=SRA is wrong here", opcode, funct3, funct7); errors++;
          end
          // mul_unit exactly for the four Zmmul multiplies
          if ((ex_sel == EX_MUL) !== (opcode == 7'b0110011 && s == 7'b0000001 && f <= 3)) begin
            $display("FAIL: sweep op=%b f3=%b f7=%b: ex_sel=%0d", opcode, funct3, funct7, ex_sel); errors++;
          end
          // nn_unit exactly for the defined custom-0 instructions
          if ((ex_sel == EX_NN) !== (opcode == 7'b0001011 && legal_ref(opcode, funct3, funct7, rs2_addr))) begin
            $display("FAIL: sweep op=%b f3=%b f7=%b rs2=%0d: ex_sel=%0d (EX_NN)", opcode, funct3, funct7, rs2_addr, ex_sel); errors++;
          end
          // rd is a source only for DOT4.S8 (otherwise the pipeline would stall for nothing)
          if (rs3_read !== (opcode == 7'b0001011 && f == 3'b001 && s == 7'b0000000)) begin
            $display("FAIL: sweep op=%b f3=%b f7=%b: rs3_read=%b", opcode, funct3, funct7, rs3_read); errors++;
          end
          // an extension-unit result goes to rd and nowhere else
          if (ex_sel != EX_ALU && !(reg_write && wb_sel == WB_ALU && !mem_read && !mem_write &&
                                     !branch && !jump && !jalr && !system && !illegal)) begin
            $display("FAIL: sweep op=%b f3=%b f7=%b: ex_sel=%0d with wrong side signals", opcode, funct3, funct7, ex_sel); errors++;
          end
        end

    if (errors == 0) $display("PASS: tb_control");
    else             $display("FAIL: tb_control (%0d errors)", errors);
    $finish;
  end
endmodule
