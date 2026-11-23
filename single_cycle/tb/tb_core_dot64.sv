`timescale 1ns/1ps
// tb_core_dot64.sv - whole-core test of Zmmul, DOT4.S8 and CLIP.S8.
// Runs programs/dot64.hex with programs/dot64_data.hex preloaded in data
// memory (see programs/dot64.s):
//   A/B  one KWS-style pointwise output: bias + a 64-element INT8 dot product,
//        once with 16 x (lw, lw, dot4.s8) and once with 64 x (lb, lb, mul, add)
//   C    requantisation: mulh, srai, addi (zero point), clip.s8
//   D-F  DOT4.S8 register cases (rd = x0, rd == rs1 / rs2), CLIP.S8 and Zmmul
//        edge values
// Expected values are generated with the program (programs/gen_dot64.py ->
// programs/dot64_expect.svh). Prints the cycle count of both dot products.
//
//   vvp build/tb_core_dot64.vvp            normal run
//   vvp build/tb_core_dot64.vvp +TRACE     also print pc / instr / rd write every cycle
module tb_core_dot64;
  parameter     PROG       = "programs/dot64.hex";
  parameter     DATA       = "programs/dot64_data.hex";
  parameter int MAX_CYCLES = 2000;
  localparam int DMEM_WORDS = 1024;
  localparam int AW         = $clog2(DMEM_WORDS);

  `include "dot64_expect.svh"

  logic        clk = 1'b0;
  logic        rst;
  logic [31:0] dbg_pc, dbg_instr;
  logic        dbg_illegal, dbg_system;
  int          cycles = 0;
  int          errors = 0;
  int          c_dot4_start = -1, c_dot4_end = -1, c_mul_start = -1, c_mul_end = -1;
  bit          trace;

  riscv_core #(.INIT_FILE(PROG), .DMEM_WORDS(DMEM_WORDS), .DMEM_INIT_FILE(DATA)) dut (
    .clk(clk), .rst(rst),
    .dbg_pc(dbg_pc), .dbg_instr(dbg_instr),
    .dbg_illegal(dbg_illegal), .dbg_system(dbg_system));

  always #5 clk = ~clk;

  // ---- checking helpers (read-only views into the design) ----
  function automatic logic [31:0] reg_val(input int r);
    return (r == 0) ? 32'd0 : dut.u_id.u_rf.regs[r];
  endfunction

  function automatic logic [31:0] mem_val(input logic [31:0] addr);
    return dut.u_mem.u_dmem.mem[addr[AW+1:2]];
  endfunction

  task automatic expect_reg(input int r, input logic [31:0] v);
    if (reg_val(r) !== v) begin
      $display("  x%-2d : hardware %h   expected %h   <-- differs", r, reg_val(r), v);
      errors++;
    end
  endtask

  task automatic check_results();
    // the known answer, computed both ways
    if (reg_val(10) !== DOT_ANSWER) begin
      $display("  DOT4.S8 dot product: x10 = %h, expected %h", reg_val(10), DOT_ANSWER); errors++;
    end
    if (reg_val(11) !== DOT_ANSWER) begin
      $display("  mul dot product:     x11 = %h, expected %h", reg_val(11), DOT_ANSWER); errors++;
    end
    // reads of x0 are forced to 0, so a write to x0 is only visible inside the array
    if (dut.u_id.u_rf.regs[0] !== 32'd0) begin
      $display("  x0 storage was written: %h", dut.u_id.u_rf.regs[0]); errors++;
    end
    for (int r = 0; r < 32; r++) expect_reg(r, exp_reg(r));
    for (int k = 0; k < N_MEM; k++)
      if (mem_val(exp_mem_addr(k)) !== exp_mem_val(k)) begin
        $display("  M[%h] : hardware %h   expected %h   <-- differs (see dot64.s)",
                 exp_mem_addr(k), mem_val(exp_mem_addr(k)), exp_mem_val(k));
        errors++;
      end
  endtask

  task automatic finish_run(input string why);
    int d4, dm;
    d4 = c_dot4_end - c_dot4_start;
    dm = c_mul_end - c_mul_start;
    $display("=== dot64 ===");
    $display("  stopped (%s) at pc=%h instr=%h after %0d cycles", why, dbg_pc, dbg_instr, cycles);
    if (why != "ebreak" || dbg_pc !== PC_EBREAK) begin
      $display("  expected to stop at the ebreak at pc=%h", PC_EBREAK);
      errors++;
    end
    if (c_dot4_end < 0 || c_mul_end < 0) begin
      $display("  a dot-product kernel never finished"); errors++;
    end else begin
      $display("  64-element dot product, 16 x (lw, lw, dot4.s8)   : %0d cycles", d4);
      $display("  64-element dot product, 64 x (lb, lb, mul, add)  : %0d cycles", dm);
      $display("  ratio                                            : %0d.%02d x", dm / d4, (dm * 100 / d4) % 100);
    end
    check_results();
    if (errors == 0) $display("PASS: tb_core_dot64");
    else             $display("FAIL: tb_core_dot64 (%0d errors)", errors);
    $finish;
  endtask

  initial begin
    $dumpfile("build/tb_core_dot64.vcd");
    $dumpvars(0, tb_core_dot64);
    trace = $test$plusargs("TRACE");

    rst = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk) rst = 1'b0;
    #1;                                      // let rst = 0 reach rf_we before the first trace line

    // Each iteration looks at the instruction in the middle of its cycle
    // (all combinational logic settled), then lets the clock edge commit it.
    forever begin
      if (dbg_pc == PC_DOT4_START && c_dot4_start < 0) c_dot4_start = cycles;
      if (dbg_pc == PC_DOT4_END   && c_dot4_end   < 0) c_dot4_end   = cycles;
      if (dbg_pc == PC_MUL_START  && c_mul_start  < 0) c_mul_start  = cycles;
      if (dbg_pc == PC_MUL_END    && c_mul_end    < 0) c_mul_end    = cycles;
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
