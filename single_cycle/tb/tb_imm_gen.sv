`timescale 1ns/1ps
// tb_imm_gen.sv - immediate generator against real encoded instructions.
// The expected immediates are the ones written in the
// assembly, NOT recomputed with the same bit expressions as the design.
module tb_imm_gen;
  import riscv_pkg::*;

  logic [31:0] instr, imm;
  logic [2:0]  imm_sel;
  int          errors = 0;

  imm_gen dut (.instr(instr), .imm_sel(imm_sel), .imm(imm));

  task automatic check(input logic [31:0] i, input logic [2:0] sel,
                       input logic [31:0] expect_imm, input string what);
    instr = i; imm_sel = sel; #1;
    if (imm !== expect_imm) begin
      $display("FAIL: %-24s instr=%h -> imm=%h, expected %h", what, i, imm, expect_imm);
      errors++;
    end
  endtask

  initial begin
    check(32'h0050_0093, IMM_I, 32'd5,         "addi x1, x0, 5");
    check(32'h8000_0093, IMM_I, 32'hFFFF_F800, "addi x1, x0, -2048");
    check(32'hfe20_af23, IMM_S, 32'hFFFF_FFFE, "sw x2, -2(x1)");
    check(32'hfe20_8ee3, IMM_B, 32'hFFFF_FFFC, "beq x1, x2, -4");
    check(32'hffff_f0b7, IMM_U, 32'hFFFF_F000, "lui x1, 0xFFFFF");
    check(32'hff9f_f06f, IMM_J, 32'hFFFF_FFF8, "jal x0, -8");
    // worked examples
    check(32'hFE20_8CE3, IMM_B, 32'hFFFF_FFF8, "beq x1, x2, -8");
    check(32'h7E53_84E3, IMM_B, 32'h0000_0FE8, "branch, instr[31]=0");
    // range limits of every format, positive and negative
    check(32'h7ff00093, IMM_I, 32'h000007ff, "addi x1, x0, 2047");
    check(32'hfff32283, IMM_I, 32'hffffffff, "lw x5, -1(x6)");
    check(32'h800100e7, IMM_I, 32'hfffff800, "jalr x1, -2048(x2)");
    check(32'h7e20afa3, IMM_S, 32'h000007ff, "sw x2, 2047(x1)");
    check(32'h81ff8023, IMM_S, 32'hfffff800, "sb x31, -2048(x31)");
    check(32'h007192a3, IMM_S, 32'h00000005, "sh x7, 5(x3)");
    check(32'h7e000fe3, IMM_B, 32'h00000ffe, "beq x0, x0, 4094");
    check(32'h80209063, IMM_B, 32'hfffff000, "bne x1, x2, -4096");
    check(32'h0041c0e3, IMM_B, 32'h00000800, "blt x3, x4, 2048");
    check(32'h0062f163, IMM_B, 32'h00000002, "bgeu x5, x6, 2");
    check(32'h123450b7, IMM_U, 32'h12345000, "lui x1, 0x12345");
    check(32'h80000117, IMM_U, 32'h80000000, "auipc x2, 0x80000");
    check(32'h7ffff0ef, IMM_J, 32'h000ffffe, "jal x1, 1048574");
    check(32'h8000006f, IMM_J, 32'hfff00000, "jal x0, -1048576");
    check(32'h001002ef, IMM_J, 32'h00000800, "jal x5, 2048");
    check(32'h000012ef, IMM_J, 32'h00001000, "jal x5, 4096");
    // unused select value
    check(32'hFFFF_FFFF, 3'd7,  32'd0,         "imm_sel = 7 gives 0");

    if (errors == 0) $display("PASS: tb_imm_gen");
    else             $display("FAIL: tb_imm_gen (%0d errors)", errors);
    $finish;
  end
endmodule
