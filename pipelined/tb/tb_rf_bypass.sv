`timescale 1ns/1ps
// tb_rf_bypass.sv - the write-back bypass: a read of the register being written in WB
// returns the new value, on all three ports; x0 and writes with wb_we = 0 are never
// passed. Hand-picked cases, then 2000 random ones against a model.
module tb_rf_bypass;
  logic [4:0]  a1, a2, a3, wa;
  logic [31:0] r1, r2, r3, wd, o1, o2, o3;
  logic        we;
  int          errors = 0;

  rf_bypass dut (
    .rs1_addr(a1), .rs2_addr(a2), .rs3_addr(a3),
    .rf_rs1_data(r1), .rf_rs2_data(r2), .rf_rs3_data(r3),
    .wb_we(we), .wb_rd_addr(wa), .wb_data(wd),
    .rs1_data(o1), .rs2_data(o2), .rs3_data(o3));

  function automatic logic [31:0] model(input logic [4:0] a, input logic [31:0] from_rf);
    return (we && a == wa && a != 5'd0) ? wd : from_rf;
  endfunction

  task automatic check(input string what);
    #1;
    if (o1 !== model(a1, r1) || o2 !== model(a2, r2) || o3 !== model(a3, r3)) begin
      $display("FAIL %s: addr %0d %0d %0d, write x%0d=%h we=%b -> %h %h %h", what, a1, a2, a3, wa, wd, we, o1, o2, o3);
      errors++;
    end
  endtask

  initial begin
    r1 = 32'h1111_1111; r2 = 32'h2222_2222; r3 = 32'h3333_3333; wd = 32'hAAAA_5555;
    a1 = 5; a2 = 6; a3 = 7;  we = 1; wa = 5;  check("rs1 bypassed");
    if (o1 !== wd) begin $display("FAIL: rs1 not bypassed"); errors++; end
    wa = 7;                                    check("rs3 bypassed");
    if (o3 !== wd || o1 !== r1) begin $display("FAIL: rs3 bypass"); errors++; end
    we = 0;                                    check("wb_we = 0: no bypass");
    a1 = 0; we = 1; wa = 0;                    check("x0 never bypassed");
    if (o1 !== r1) begin $display("FAIL: bypassed a write to x0"); errors++; end
    repeat (2000) begin
      a1 = $urandom % 8; a2 = $urandom % 8; a3 = $urandom % 8; wa = $urandom % 8; we = $urandom % 2;
      r1 = $urandom; r2 = $urandom; r3 = $urandom; wd = $urandom;
      check("random");
    end
    if (errors == 0) $display("PASS: tb_rf_bypass");
    else             $display("FAIL: tb_rf_bypass (%0d errors)", errors);
    $finish;
  end
endmodule
