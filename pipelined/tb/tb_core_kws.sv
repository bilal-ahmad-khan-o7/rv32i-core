`timescale 1ns/1ps
// tb_core_kws.sv - runs a program on the PIPELINED core: the KWS programs from
// kws/, and any other program (random, hazard tests). It is
// single_cycle/tb/tb_core_kws.sv with its probes moved to where things now happen:
//   marker      the marker store is seen in EX, the cycle it writes data memory: every
//               older store has written by then and no younger one has
//   trace       register writes are seen in WB (pc, rd, value), the same format as rv32iss
//   stopping    ebreak/ecall/illegal, from the debug outputs, i.e. when they reach WB
//
// Plusargs (paths relative to the folder vvp runs in):
//   +PROG=f +DATA=f +INPUT=f    instruction image, data image, 490 input bytes at kws_input
//   +LAYERS=f +EXPECT=f         layer table and expected bytes (see single_cycle/tb/tb_core_kws.sv)
//   +TRACE=f +TRACE_MAX=n       register-write trace
//   +DUMP=addr +DUMP_LEN=n      print n bytes of data memory from addr (hex) at the end
//   +STOP=n                     stop at marker n
//   +MAX=n                      cycle limit
//
// Cycle accounting: every cycle, the EX slot holds an instruction, or a bubble caused by
// a load-use stall (1 cycle each), by a redirect (2 cycles each), or by something else:
// the 2 cycles before the first instruction reaches EX, and the drain after ebreak.
// At each marker it prints the cycles since the previous one, split that way.
module tb_core_kws;
  localparam int IMEM_WORDS = 8192;                      // 32 KiB
  localparam int DMEM_WORDS = 16384;                     // 64 KiB
  localparam int AW         = $clog2(DMEM_WORDS);
  localparam int MAX_ROWS   = 64;
  localparam int EXP_WORDS  = 32768;

  localparam logic [31:0] MARKER      = 32'hFFFF_FFF0;
  localparam logic [31:0] INPUT_ADDR  = 32'h1000_F000;   // kws_input  (link.ld)
  localparam logic [31:0] OUTPUT_ADDR = 32'h1000_F200;   // kws_output (link.ld)
  localparam logic [31:0] LABEL_ADDR  = 32'h1000_F20C;   // kws_label  (link.ld)

  logic        clk = 1'b0;
  logic        rst = 1'b1;
  logic [31:0] dbg_pc, dbg_instr, dbg_mem_addr, dbg_mem_wdata;
  logic        dbg_illegal, dbg_system, dbg_mem_we;

  riscv_core #(.IMEM_WORDS(IMEM_WORDS), .DMEM_WORDS(DMEM_WORDS)) dut (
    .clk(clk), .rst(rst),
    .dbg_pc(dbg_pc), .dbg_instr(dbg_instr),
    .dbg_illegal(dbg_illegal), .dbg_system(dbg_system),
    .dbg_mem_we(dbg_mem_we), .dbg_mem_addr(dbg_mem_addr), .dbg_mem_wdata(dbg_mem_wdata));

  always #5 clk = ~clk;

  logic [31:0] table_w [0:5*MAX_ROWS-1];                 // +LAYERS
  logic [31:0] expect_w [0:EXP_WORDS-1];                 // +EXPECT
  string       prog, data, input_file, layers_file, expect_file, trace_file;
  int          trace_fd = 0, trace_lines = 0, trace_max = -1;
  int          stop_marker = -1, dump_len = 0;
  logic [31:0] dump_addr = 32'd0;
  longint      max_cycles = 64'd100_000_000;
  longint      cycles = 0, last_mark = 0;
  int          errors = 0, layers_checked = 0, table_rows = 0;
  // cycle accounting (see above): totals, and the values at the previous marker
  longint      n_instr = 0, n_load_use = 0, n_flush = 0, n_other = 0;
  longint      m_instr = 0, m_load_use = 0, m_flush = 0, m_other = 0;
  logic        stall_d1 = 1'b0, flush_d1 = 1'b0, flush_d2 = 1'b0;

  function automatic logic [7:0] dmem_byte(input logic [31:0] addr);
    logic [31:0] w;
    w = dut.u_mem.u_dmem.mem[addr[AW+1:2]];
    return w[8*addr[1:0] +: 8];
  endfunction

  // Compare the regions listed for this marker with the expected bytes.
  task automatic check_marker(input logic [31:0] marker);
    int off = 0;
    for (int r = 0; r < MAX_ROWS && table_w[5*r] !== 32'hxxxx_xxxx; r++) begin
      logic [31:0] base   = table_w[5*r + 1];
      int          len    = table_w[5*r + 2];
      int          stride = table_w[5*r + 3];
      int          count  = table_w[5*r + 4];
      if (table_w[5*r] == marker) begin
        int bad = 0;
        int o   = off;
        for (int s = 0; s < count; s++)
          for (int j = 0; j < len; j++) begin
            logic [31:0] addr = base + s * stride + j;
            logic [31:0] w    = expect_w[o >> 2];
            logic [7:0]  want = w[8*(o & 3) +: 8];
            logic [7:0]  got  = dmem_byte(addr);
            if (got !== want) begin
              if (bad == 0)
                $display("  layer %0d: first difference at %h (span %0d, byte %0d): got %h, expected %h",
                         marker, addr, s, j, got, want);
              bad++;
            end
            o++;
          end
        if (bad != 0) begin
          $display("  layer %0d: %0d bytes differ", marker, bad);
          errors += bad;
        end
        layers_checked++;
      end
      off += len * count;
    end
  endtask

  task automatic finish_run(input string why);
    $display("stopped (%s) at pc=%h instr=%h after %0d cycles", why, dbg_pc, dbg_instr, cycles);
    $display("pipeline: %0d cycles = %0d instructions + %0d load-use + %0d flush + %0d other",
             cycles, n_instr, n_load_use, n_flush, n_other);
    $write("output:");
    for (int i = 0; i < 12; i++) $write(" %h", dmem_byte(OUTPUT_ADDR + i));
    $write("  label: %h%h%h%h\n", dmem_byte(LABEL_ADDR + 3), dmem_byte(LABEL_ADDR + 2),
           dmem_byte(LABEL_ADDR + 1), dmem_byte(LABEL_ADDR));
    if (dump_len > 0) begin
      $write("dump %h:", dump_addr);
      for (int i = 0; i < dump_len; i++) $write(" %h", dmem_byte(dump_addr + i));
      $write("\n");
    end
    if (trace_fd != 0) $fclose(trace_fd);
    if (why != "ebreak" && why != "stop marker") errors++;
    if (expect_file != "" && layers_checked == 0) begin
      $display("  no layer was checked");
      errors++;
    end
    if (why == "ebreak" && layers_checked != table_rows) begin  // a program that stops early must not pass
      $display("  only %0d of %0d layer rows were reached", layers_checked, table_rows);
      errors++;
    end
    if (errors == 0) $display("PASS: tb_core_kws (%0d layers checked)", layers_checked);
    else             $display("FAIL: tb_core_kws (%0d errors)", errors);
    $finish;
  endtask

  initial begin
    if (!$value$plusargs("PROG=%s", prog)) begin
      $display("FAIL: tb_core_kws: +PROG=file is required");
      $finish;
    end
    if (!$value$plusargs("DATA=%s", data))          data = "";
    if (!$value$plusargs("INPUT=%s", input_file))   input_file = "";
    if (!$value$plusargs("LAYERS=%s", layers_file)) layers_file = "";
    if (!$value$plusargs("EXPECT=%s", expect_file)) expect_file = "";
    if (!$value$plusargs("TRACE=%s", trace_file))   trace_file = "";
    if (!$value$plusargs("TRACE_MAX=%d", trace_max)) trace_max = -1;
    if (!$value$plusargs("STOP=%d", stop_marker))    stop_marker = -1;
    if (!$value$plusargs("MAX=%d", max_cycles))      max_cycles = 64'd100_000_000;
    if (!$value$plusargs("DUMP=%h", dump_addr))      dump_addr = 32'd0;
    if (!$value$plusargs("DUMP_LEN=%d", dump_len))   dump_len = 0;

    #1;                                      // after the memories' own initial blocks
    $readmemh(prog, dut.u_if.u_imem.mem);
    if (data != "")       $readmemh(data, dut.u_mem.u_dmem.mem);
    if (input_file != "") $readmemh(input_file, dut.u_mem.u_dmem.mem, INPUT_ADDR[AW+1:2]);
    if (layers_file != "") $readmemh(layers_file, table_w);
    if (expect_file != "") $readmemh(expect_file, expect_w);
    while (table_rows < MAX_ROWS && table_w[5*table_rows] !== 32'hxxxx_xxxx) table_rows++;
    if (trace_file != "") trace_fd = $fopen(trace_file, "w");

    repeat (3) @(posedge clk);
    @(negedge clk) rst = 1'b0;
    #1;                                      // let rst = 0 reach the write enables

    // Each iteration looks at the pipeline in the middle of a cycle (all combinational
    // logic settled), then lets the clock edge move it on. Cycle 0 is the first cycle
    // after reset: the first instruction is in IF.
    forever begin
      if (trace_fd != 0 && dut.rf_we && dut.mem_wb_rd_addr != 5'd0 &&
          (trace_max < 0 || trace_lines < trace_max)) begin
        $fdisplay(trace_fd, "%h x%-2d %h", dut.mem_wb_pc, dut.mem_wb_rd_addr, dut.wb_data);
        trace_lines++;
      end
      // A run's length is the cycles BEFORE ebreak reaches WB (as single_cycle/tb counts
      // the cycles before ebreak executes), so the stop cycle itself is not counted.
      if (dbg_illegal)           finish_run("illegal instruction");
      if (dbg_system)            finish_run("ebreak");
      if (cycles >= max_cycles)  finish_run("cycle limit");
      // what is in EX this cycle (a stall leaves a bubble one cycle later, a redirect two)
      if (dut.id_ex_valid)             n_instr++;
      else if (stall_d1)               n_load_use++;
      else if (flush_d1 || flush_d2)   n_flush++;
      else                             n_other++;
      if (dut.ex_mem_write && dut.alu_y == MARKER) begin
        // the marker store itself is in EX, so this interval ends with it
        $display("marker %2d: %10d cycles  (total %0d)  instructions %0d  load-use %0d  flush %0d  other %0d",
                 dut.ex_rs2, cycles + 1 - last_mark, cycles + 1, n_instr - m_instr,
                 n_load_use - m_load_use, n_flush - m_flush, n_other - m_other);
        last_mark = cycles + 1;
        m_instr = n_instr; m_load_use = n_load_use; m_flush = n_flush; m_other = n_other;
        check_marker(dut.ex_rs2);
        if (dut.ex_rs2 == stop_marker) begin
          cycles++;                          // the marker's own cycle is counted
          finish_run("stop marker");
        end
      end
      stall_d1 = dut.stall;
      flush_d2 = flush_d1;
      flush_d1 = dut.flush;
      @(negedge clk);
      cycles++;
    end
  end
endmodule
