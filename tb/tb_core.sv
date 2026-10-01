`timescale 1ns/1ps
// tb_core.sv - whole-core smoke test (PDF Lesson 11.3.1 style).
// Runs programs/smoke.hex until ebreak (normal stop), an illegal instruction,
// or a cycle limit, then checks every register and the data-memory results
// against values worked out by hand (see programs/smoke.s).
//
//   vvp build/tb_core.vvp            normal run
//   vvp build/tb_core.vvp +TRACE     also print pc / instr / rd write every cycle
//
// The testbench only READS the design's state (registers, data memory);
// it never writes into it.
module tb_core;
  parameter     PROG       = "programs/smoke.hex";
  parameter int MAX_CYCLES = 1000;

  logic        clk = 1'b0;
  logic        rst;
  logic [31:0] dbg_pc, dbg_instr;
  logic        dbg_illegal, dbg_system;
  int          cycles = 0;
  int          errors = 0;
  bit          trace;

  riscv_core #(.INIT_FILE(PROG)) dut (
    .clk(clk), .rst(rst),
    .dbg_pc(dbg_pc), .dbg_instr(dbg_instr),
    .dbg_illegal(dbg_illegal), .dbg_system(dbg_system));

  always #5 clk = ~clk;

  // ---- checking helpers (read-only views into the design) ----
  function automatic logic [31:0] reg_val(input int r);
    return (r == 0) ? 32'd0 : dut.u_id.u_rf.regs[r];
  endfunction

  function automatic logic [31:0] mem_val(input logic [31:0] addr);
    return dut.u_mem.u_dmem.mem[addr[11:2]];
  endfunction

  task automatic expect_reg(input int r, input logic [31:0] v);
    if (reg_val(r) !== v) begin
      $display("  x%-2d : hardware %h   expected %h   <-- differs", r, reg_val(r), v);
      errors++;
    end
  endtask

  task automatic expect_mem(input logic [31:0] addr, input logic [31:0] v, input string what);
    if (mem_val(addr) !== v) begin
      $display("  M[%h] %-10s: hardware %h   expected %h   <-- differs", addr, what, mem_val(addr), v);
      errors++;
    end
  endtask

  // Expected signature: arithmetic results stored at 0x200 + 4k.
  function automatic logic [31:0] sig(input int k);
    case (k)
       0: return 32'h0000_0002;   1: return 32'h0000_0008;   // add    sub
       2: return 32'h0000_00A0;   3: return 32'h0000_0001;   // sll    slt
       4: return 32'h0000_0000;   5: return 32'hFFFF_FFF8;   // sltu   xor
       6: return 32'h07FF_FFFF;   7: return 32'hFFFF_FFFF;   // srl    sra
       8: return 32'hFFFF_FFFD;   9: return 32'h0000_0005;   // or     and
      10: return 32'h0000_0001;  11: return 32'h0000_0001;   // slti   sltiu
      12: return 32'hFFFF_FFFA;  13: return 32'h0000_07F5;   // xori   ori
      14: return 32'h0000_00F0;  15: return 32'h8000_0000;   // andi   slli
      16: return 32'h0000_000F;  17: return 32'hFFFF_FFFE;   // srli   srai
      18: return 32'h1234_5678;  19: return 32'hFFFF_F000;   // lui+addi, lui
      20: return 32'h0000_10B0;  21: return 32'h7FFF_FFFF;   // auipc (at 0xB0), lui+addi -1
      22: return 32'h8000_0004;  23: return 32'h0000_0005;   // overflow wrap, x0 reads 0
      default: return 32'hxxxx_xxxx;
    endcase
  endfunction

  task automatic check_results();
    // ---- registers (smoke.s comments) ----
    expect_reg( 0, 32'h0000_0000);  expect_reg( 1, 32'h0000_0005);
    expect_reg( 2, 32'hFFFF_FFFD);  expect_reg( 3, 32'h0000_0005);
    expect_reg( 4, 32'h0000_0100);  expect_reg( 5, 32'h1234_5678);
    expect_reg( 6, 32'h0000_0080);  expect_reg( 7, 32'hFFFF_FFFF);
    expect_reg( 8, 32'h0000_8000);  expect_reg( 9, 32'hFF34_8078);
    expect_reg(10, 32'hFFFF_FF80);  expect_reg(11, 32'h0000_0080);
    expect_reg(12, 32'h0000_0034);  expect_reg(13, 32'h0000_00FF);
    expect_reg(14, 32'hFFFF_8000);  expect_reg(15, 32'h0000_8000);
    expect_reg(16, 32'hFFFF_8078);  expect_reg(17, 32'h0000_FFFF);
    expect_reg(18, 32'h8000_FFFF);  expect_reg(19, 32'h1234_5678);
    expect_reg(20, 32'h0000_003F);  expect_reg(21, 32'h0000_0000);
    expect_reg(22, 32'h0000_000A);  expect_reg(23, 32'h0000_000A);
    expect_reg(24, 32'h0000_0037);  expect_reg(25, 32'h0000_01B4);
    expect_reg(26, 32'h0000_006B);  expect_reg(27, 32'h0000_01D0);
    expect_reg(28, 32'h0000_01D0);  expect_reg(29, 32'h0000_0001);
    expect_reg(30, 32'h0000_0000);  expect_reg(31, 32'h0000_0200);

    // ---- load/store area ----
    expect_mem(32'h0FC, 32'h1234_5678, "sw -4");
    expect_mem(32'h100, 32'hFF34_8078, "sw+sb+sb");
    expect_mem(32'h104, 32'h8000_FFFF, "sh+sh");

    // ---- signature ----
    for (int k = 0; k < 24; k++)
      expect_mem(32'h200 + 4 * k, sig(k), $sformatf("sig[%0d]", k));
  endtask

  task automatic finish_run(input string why);
    $display("=== smoke ===");
    $display("  stopped (%s) at pc=%h instr=%h after %0d cycles", why, dbg_pc, dbg_instr, cycles);
    if (why != "ebreak" || dbg_pc !== 32'h0000_01F4) begin
      $display("  expected to stop at the ebreak at pc=000001f4");
      errors++;
    end
    check_results();
    $writememh("build/tb_core_regs.txt", dut.u_id.u_rf.regs);
    if (errors == 0) $display("PASS: tb_core");
    else             $display("FAIL: tb_core (%0d errors)", errors);
    $finish;
  endtask

  initial begin
    $dumpfile("build/tb_core.vcd");
    $dumpvars(0, tb_core);
    trace = $test$plusargs("TRACE");

    rst = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk) rst = 1'b0;

    // Each iteration looks at the instruction in the middle of its cycle
    // (all combinational logic settled), then lets the clock edge commit it.
    forever begin
      if (trace) begin
        if (dut.rf_we && dut.rd_addr != 5'd0)
          $display("%4d  pc=%h  instr=%h  x%0d <- %h", cycles, dbg_pc, dbg_instr, dut.rd_addr, dut.wb_data);
        else if (dut.dmem_we)
          $display("%4d  pc=%h  instr=%h  M[%h] <- %h (mask %b)", cycles, dbg_pc, dbg_instr,
                   dut.alu_y, dut.u_mem.mem_wdata, dut.u_mem.mem_wmask);
        else
          $display("%4d  pc=%h  instr=%h", cycles, dbg_pc, dbg_instr);
      end
      if (dbg_illegal)          finish_run("illegal instruction");
      if (dbg_system)           finish_run("ebreak");
      if (cycles >= MAX_CYCLES) finish_run("cycle limit");
      @(negedge clk);
      cycles++;
    end
  end
endmodule
