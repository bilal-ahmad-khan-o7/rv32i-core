`timescale 1ns/1ps
// tb_branch_unit.sv - the six branch conditions, signed vs unsigned edges
// (PDF Lesson 10.3), plus random operands against a model.
module tb_branch_unit;
  logic [31:0] rs1_data, rs2_data;
  logic [2:0]  funct3;
  logic        take_branch;
  int          errors = 0;

  localparam logic [2:0] BEQ = 3'b000, BNE = 3'b001, BLT = 3'b100,
                         BGE = 3'b101, BLTU = 3'b110, BGEU = 3'b111;

  branch_unit dut (.rs1_data(rs1_data), .rs2_data(rs2_data), .funct3(funct3),
                   .take_branch(take_branch));

  function automatic logic model(input logic [31:0] a, b, input logic [2:0] f);
    case (f)
      BEQ:     return a == b;
      BNE:     return a != b;
      BLT:     return $signed(a) <  $signed(b);
      BGE:     return $signed(a) >= $signed(b);
      BLTU:    return a <  b;
      BGEU:    return a >= b;
      default: return 1'b0;
    endcase
  endfunction

  task automatic check(input logic [31:0] a, b, input logic [2:0] f,
                       input logic expect_take, input string what);
    rs1_data = a; rs2_data = b; funct3 = f; #1;
    if (take_branch !== expect_take) begin
      $display("FAIL: %-28s a=%h b=%h f3=%b -> %b, expected %b", what, a, b, f, take_branch, expect_take);
      errors++;
    end
  endtask

  initial begin
    // hand-worked expected values
    check(32'd5, 32'd5,               BEQ,  1, "beq equal");
    check(32'd5, 32'd6,               BEQ,  0, "beq different");
    check(32'd5, 32'd6,               BNE,  1, "bne different");
    check(32'd5, 32'd5,               BNE,  0, "bne equal");
    check(32'hFFFF_FFFF, 32'd1,       BLT,  1, "blt -1 < 1 signed");
    check(32'hFFFF_FFFF, 32'd1,       BLTU, 0, "bltu 0xFFFFFFFF > 1 unsigned");
    check(32'd1, 32'hFFFF_FFFF,       BGE,  1, "bge 1 >= -1 signed");
    check(32'd1, 32'hFFFF_FFFF,       BGEU, 0, "bgeu 1 < 0xFFFFFFFF unsigned");
    check(32'h8000_0000, 32'h7FFF_FFFF, BLT,  1, "blt INT_MIN < INT_MAX");
    check(32'h8000_0000, 32'h7FFF_FFFF, BLTU, 0, "bltu 0x80000000 > 0x7FFFFFFF");
    check(32'd7, 32'd7,               BGE,  1, "bge equal is taken");
    check(32'd7, 32'd7,               BGEU, 1, "bgeu equal is taken");
    check(32'd7, 32'd7,               BLT,  0, "blt equal not taken");
    check(32'd7, 32'd7,               BLTU, 0, "bltu equal not taken");
    check(32'd0, 32'd0,               3'b010, 0, "funct3 010 does not exist");
    check(32'd0, 32'd1,               3'b011, 0, "funct3 011 does not exist");

    for (int f = 0; f < 8; f++)
      repeat (300) begin
        logic [31:0] a, b;
        a = $urandom; b = ($urandom % 4 == 0) ? a : $urandom;   // equal operands 1 time in 4
        check(a, b, f[2:0], model(a, b, f[2:0]), "random");
      end

    if (errors == 0) $display("PASS: tb_branch_unit");
    else             $display("FAIL: tb_branch_unit (%0d errors)", errors);
    $finish;
  end
endmodule
