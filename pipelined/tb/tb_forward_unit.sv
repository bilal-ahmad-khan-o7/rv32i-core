`timescale 1ns/1ps
// tb_forward_unit.sv - forward_unit against a model written differently (a loop over
// the two producers, newest first), on hand-picked cases and 3000 random ones:
//   - EX/MEM wins over MEM/WB when both write the register;
//   - nothing is forwarded from a write to x0, or from an instruction that doesn't write;
//   - rs3 (the rd field) is forwarded exactly like rs1 and rs2.
module tb_forward_unit;
  import pipeline_pkg::*;

  logic [4:0] rs1, rs2, rd, exm_rd, mwb_rd;
  logic       exm_we, mwb_we;
  logic [1:0] fa, fb, fc;
  int         errors = 0;

  forward_unit dut (
    .id_ex_rs1_addr(rs1), .id_ex_rs2_addr(rs2), .id_ex_rd_addr(rd),
    .ex_mem_reg_write(exm_we), .ex_mem_rd_addr(exm_rd),
    .mem_wb_reg_write(mwb_we), .mem_wb_rd_addr(mwb_rd),
    .forward_a(fa), .forward_b(fb), .forward_c(fc));

  function automatic logic [1:0] model(input logic [4:0] src);
    logic       we   [2];
    logic [4:0] dst  [2];
    logic [1:0] code [2];
    we[0] = exm_we; dst[0] = exm_rd; code[0] = FWD_EX_MEM;     // newest first
    we[1] = mwb_we; dst[1] = mwb_rd; code[1] = FWD_MEM_WB;
    for (int i = 0; i < 2; i++)
      if (we[i] && dst[i] == src && src != 5'd0) return code[i];
    return FWD_ID_EX;
  endfunction

  task automatic check(input string what);
    #1;
    if (fa !== model(rs1) || fb !== model(rs2) || fc !== model(rd)) begin
      $display("FAIL %s: rs1=%0d rs2=%0d rd=%0d exm=%0d/%b mwb=%0d/%b -> a=%b b=%b c=%b, expected %b %b %b",
               what, rs1, rs2, rd, exm_rd, exm_we, mwb_rd, mwb_we, fa, fb, fc, model(rs1), model(rs2), model(rd));
      errors++;
    end
  endtask

  task automatic set(input int s1, s2, d, input logic ew, input int er, input logic mw, input int mr);
    rs1 = s1; rs2 = s2; rd = d; exm_we = ew; exm_rd = er; mwb_we = mw; mwb_rd = mr;
  endtask

  initial begin
    set(5, 6, 7, 1, 5, 0, 0);  check("EX/MEM -> rs1");
    if (fa !== FWD_EX_MEM) begin $display("FAIL: rs1 not forwarded from EX/MEM"); errors++; end
    set(5, 6, 7, 0, 0, 1, 6);  check("MEM/WB -> rs2");
    if (fb !== FWD_MEM_WB) begin $display("FAIL: rs2 not forwarded from MEM/WB"); errors++; end
    set(5, 6, 7, 1, 7, 1, 7);  check("both write rs3: EX/MEM wins");
    if (fc !== FWD_EX_MEM) begin $display("FAIL: EX/MEM must win for rs3"); errors++; end
    set(0, 0, 0, 1, 0, 1, 0);  check("x0 is never forwarded");
    if (fa !== FWD_ID_EX || fc !== FWD_ID_EX) begin $display("FAIL: forwarded a write to x0"); errors++; end
    set(9, 9, 9, 0, 9, 0, 9);  check("producers that don't write");
    if (fa !== FWD_ID_EX) begin $display("FAIL: forwarded from reg_write = 0"); errors++; end
    repeat (3000) begin
      set($urandom % 32, $urandom % 32, $urandom % 32, $urandom % 2, $urandom % 32, $urandom % 2, $urandom % 32);
      if ($urandom % 3 == 0) exm_rd = rs1;                    // make matches common
      if ($urandom % 3 == 0) mwb_rd = rd;
      check("random");
    end
    if (errors == 0) $display("PASS: tb_forward_unit");
    else             $display("FAIL: tb_forward_unit (%0d errors)", errors);
    $finish;
  end
endmodule
