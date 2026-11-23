`timescale 1ns/1ps
// tb_hazard_unit.sv - hazard_unit's stall and flush decisions against a model, then the
// fetch stop's sequence:
//   - load-use: only a load (mem_read) writing a register ID reads, never x0; rs3 only
//     with rs3_read;
//   - a redirect flushes IF/ID and ID/EX;
//   - ebreak/ecall/illegal in ID: IF/ID takes bubbles from then on, until reset; not
//     while ID is stalled (it is still in ID), and not if a redirect flushes it.
module tb_hazard_unit;
  logic       clk = 1'b0, rst = 1'b1;
  logic       v, rs3_read, sys, ill, mem_read, redirect;
  logic [4:0] rs1, rs2, rd, ex_rd;
  logic       stall, flush, pc_hold, if_id_write, if_id_flush, id_ex_flush;
  int         errors = 0;

  hazard_unit dut (
    .clk(clk), .rst(rst),
    .if_id_valid(v), .if_id_rs1_addr(rs1), .if_id_rs2_addr(rs2), .if_id_rd_addr(rd),
    .id_rs3_read(rs3_read), .id_system(sys), .id_illegal(ill),
    .id_ex_mem_read(mem_read), .id_ex_rd_addr(ex_rd), .ex_redirect(redirect),
    .stall(stall), .flush(flush), .pc_hold(pc_hold),
    .if_id_write(if_id_write), .if_id_flush(if_id_flush), .id_ex_flush(id_ex_flush));

  always #5 clk = ~clk;

  task automatic set(input logic vv, input int s1, s2, d, input logic r3, s, il, mr, input int er, input logic re);
    v = vv; rs1 = s1; rs2 = s2; rd = d; rs3_read = r3; sys = s; ill = il; mem_read = mr; ex_rd = er; redirect = re;
  endtask

  // the combinational decisions, while the fetch stop is clear
  task automatic check_comb(input string what);
    logic m_stall, m_stop;
    #1;
    m_stall = mem_read && ex_rd != 0 && (ex_rd == rs1 || ex_rd == rs2 || (rs3_read && ex_rd == rd));
    m_stop  = v && (sys || ill);
    if (stall !== m_stall || flush !== redirect || pc_hold !== (m_stall || m_stop) ||
        if_id_write !== !m_stall || id_ex_flush !== (redirect || m_stall) ||
        if_id_flush !== (redirect || (m_stop && !m_stall))) begin
      $display("FAIL %s: stall=%b flush=%b hold=%b ifid_w=%b ifid_f=%b idex_f=%b (model stall=%b stop=%b)",
               what, stall, flush, pc_hold, if_id_write, if_id_flush, id_ex_flush, m_stall, m_stop);
      errors++;
    end
  endtask

  task automatic expect_stopped(input logic want, input string what);
    set(1, 0, 0, 0, 0, 0, 0, 0, 0, 0); #1;            // a plain nop in ID
    if (pc_hold !== want || if_id_flush !== want) begin
      $display("FAIL %s: fetch stop is %b, expected %b", what, pc_hold, want);
      errors++;
    end
  endtask

  initial begin
    set(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    repeat (2) @(posedge clk);
    @(negedge clk) rst = 1'b0;

    set(1, 5, 0, 0, 0, 0, 0, 1, 5, 0);  check_comb("load-use on rs1");
    set(1, 0, 5, 0, 0, 0, 0, 1, 5, 0);  check_comb("load-use on rs2");
    set(1, 0, 0, 5, 1, 0, 0, 1, 5, 0);  check_comb("load-use on rs3, read");
    set(1, 0, 0, 5, 0, 0, 0, 1, 5, 0);  check_comb("rs3 not read: no stall");
    if (stall) begin $display("FAIL: stalled on rs3 without rs3_read"); errors++; end
    set(1, 0, 0, 0, 0, 0, 0, 1, 0, 0);  check_comb("load to x0: no stall");
    if (stall) begin $display("FAIL: stalled on a load to x0"); errors++; end
    set(1, 5, 5, 5, 1, 0, 0, 0, 5, 0);  check_comb("not a load: no stall");
    set(1, 1, 2, 3, 0, 0, 0, 0, 0, 1);  check_comb("redirect");
    repeat (2000) begin
      set($urandom % 2, $urandom % 8, $urandom % 8, $urandom % 8, $urandom % 2, 1'b0, 1'b0,
          $urandom % 2, $urandom % 8, $urandom % 2);
      check_comb("random");
    end

    // fetch stop: ebreak in ID while stalled sets nothing; once it moves on, it sticks
    @(negedge clk) set(1, 0, 1, 0, 0, 1, 0, 1, 1, 0);        // ebreak (rs2 field = x1), load x1 in EX
    #1 if (!stall || if_id_flush) begin $display("FAIL: ebreak stalled: IF/ID must hold"); errors++; end
    @(negedge clk) expect_stopped(1'b0, "after a stalled ebreak");
    @(negedge clk) set(1, 0, 0, 0, 0, 1, 0, 0, 0, 1);        // ebreak in ID, but EX redirects
    @(negedge clk) expect_stopped(1'b0, "after a flushed ebreak");
    @(negedge clk) set(1, 0, 0, 0, 0, 0, 1, 0, 0, 0);        // illegal word in ID: stops fetch
    @(negedge clk) expect_stopped(1'b1, "one cycle after an illegal word");
    repeat (3) @(negedge clk);
    expect_stopped(1'b1, "still, three cycles later");
    rst = 1'b1; @(negedge clk) rst = 1'b0;
    expect_stopped(1'b0, "after reset");

    if (errors == 0) $display("PASS: tb_hazard_unit");
    else             $display("FAIL: tb_hazard_unit (%0d errors)", errors);
    $finish;
  end
endmodule
