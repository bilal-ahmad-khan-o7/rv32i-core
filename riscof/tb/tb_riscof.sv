`timescale 1ns/1ps
// tb_riscof.sv - runs ONE riscv-arch-test program on riscv_core and writes
// its signature for RISCOF. A new file: the core RTL is used unchanged.
//
//   vvp -n tb_riscof.vvp +PROG=my.hex +SIG=DUT-rv32i_core.signature \
//       +BEGIN_SIG=80003110 +END_SIG=80003280 [+MAX_CYCLES=n] [+TRACE]
//
// tools/run_test.py works out every argument and runs this for you.
// The register being written back, for +TRACE only (signatures do not use it).
// In the pipeline, rd_addr is the ID-stage field, so the WB copy is used instead;
// the plugin passes -DPIPELINED when config.ini says core=pipelined.
`ifdef PIPELINED
  `define TRACE_RD dut.mem_wb_rd_addr
`else
  `define TRACE_RD dut.rd_addr
`endif

module tb_riscof;
  // ---- memory map (must agree with rv32i_core/env/link.ld) -------------
  localparam logic [31:0] BASE  = 32'h8000_0000;   // tests are linked here
  localparam int          WORDS = 1 << 20;         // 4 MiB per memory

  // ---- DUT ports ---------------------------------------------------------
  logic        clk = 1'b0;
  logic        rst;
  logic [31:0] dbg_pc, dbg_instr;
  logic        dbg_illegal, dbg_system;

  // ---- run-time arguments (plusargs) ------------------------------------
  string       prog, sig_file;
  logic [31:0] begin_sig, end_sig;
  int          max_cycles;
  bit          trace;

  int          cycles = 0;

  riscv_core #(
    .RESET_ADDR(BASE),          // first fetch at 0x8000_0000
    .IMEM_WORDS(WORDS),
    .DMEM_WORDS(WORDS)
  ) dut (
    .clk(clk), .rst(rst),
    .dbg_pc(dbg_pc), .dbg_instr(dbg_instr),
    .dbg_illegal(dbg_illegal), .dbg_system(dbg_system));

  always #5 clk = ~clk;

  // Byte address -> word index inside one memory. The core itself keeps
  // only addr[21:2]; subtracting BASE gives the same index and reads clearly.
  function automatic int unsigned word_index(input logic [31:0] addr);
    return (addr - BASE) >> 2;
  endfunction

  // ---- write the signature: one 32-bit word per line, 8 hex digits ------
  task automatic dump_signature();
    int fd;
    fd = $fopen(sig_file, "w");
    if (fd == 0) begin
      $display("tb_riscof: cannot open %s", sig_file);
      $finish;
    end
    for (logic [31:0] a = begin_sig; a < end_sig; a += 4)
      $fwrite(fd, "%08h\n", dut.u_mem.u_dmem.mem[word_index(a)]);
    $fclose(fd);
  endtask

  task automatic finish_run(input string why);
    $display("tb_riscof: stopped (%s) at pc=%h instr=%h after %0d cycles",
             why, dbg_pc, dbg_instr, cycles);
    dump_signature();
    $finish;
  endtask

  initial begin
    // ---- 1. read the arguments ----
    if (!$value$plusargs("PROG=%s", prog))          $fatal(1, "missing +PROG=");
    if (!$value$plusargs("SIG=%s", sig_file))       $fatal(1, "missing +SIG=");
    if (!$value$plusargs("BEGIN_SIG=%h", begin_sig)) $fatal(1, "missing +BEGIN_SIG=");
    if (!$value$plusargs("END_SIG=%h", end_sig))     $fatal(1, "missing +END_SIG=");
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 2_000_000;
    trace = $test$plusargs("TRACE");

    // ---- 2. hold reset, load the program into BOTH memories ----
    rst = 1'b1;
    #1;  // after the memories' own initial blocks (nop / zero fill) at time 0
    $readmemh(prog, dut.u_if.u_imem.mem);   // instructions for fetch
    $readmemh(prog, dut.u_mem.u_dmem.mem);  // same image: data, signature area
    repeat (3) @(posedge clk);
    @(negedge clk) rst = 1'b0;
    #1;  // let rf_we = reg_write & ~rst settle before the first trace line

    // ---- 3. run until ebreak, an illegal instruction or the cycle limit ----
    forever begin
      if (trace) begin
        if (dut.rf_we && `TRACE_RD != 5'd0)            // same format as tb_core
          $display("%7d  pc=%h  instr=%h  x%0d <- %h", cycles, dbg_pc, dbg_instr,
                   `TRACE_RD, dut.wb_data);
        else
          $display("%7d  pc=%h  instr=%h", cycles, dbg_pc, dbg_instr);
      end
      if (dbg_system)            finish_run("ebreak");
      if (dbg_illegal)           finish_run("illegal instruction");
      if (cycles >= max_cycles)  finish_run("cycle limit");
      @(negedge clk);
      cycles++;
    end
  end
endmodule
