`timescale 1ns/1ps
// tb_core_kws.sv - runs a bare-metal C program from kws/ on the whole core.
// The same compiled simulation runs any build and any input; files come from
// plusargs (paths are relative to the project folder):
//
//   +PROG=f     instruction-memory image (word hex)              required
//   +DATA=f     data-memory image (word hex)
//   +INPUT=f    the 490 input bytes (word hex), loaded at kws_input
//   +LAYERS=f   layer table, +EXPECT=f  expected bytes (see below)
//   +TRACE=f    write pc, rd, value for each register write (same format as rv32iss)
//   +TRACE_MAX=n  stop writing the trace after n lines
//   +STOP=n     stop at marker n (to run only the first layers of a slow build)
//   +MAX=n      cycle limit
//
// Measuring without touching the core: the program stores the layer number to
// 0xFFFFFFF0; this testbench sees the store, prints the cycles since the
// previous marker, and compares that layer's output with the expected bytes.
// The program spends no cycles on any of this beyond the store itself.
//
// The layer table has 5 hex words per row: marker, base, len, stride, count. At
// that marker, `count` spans of `len` bytes, `stride` bytes apart, are compared
// with the next bytes of the expected file (little-endian words). A row's bytes
// start right after the previous row's. rv32iss reads the same two files.
//
// The memories are large enough for code, weights, buffers and stack; the sizes
// are the core's own parameters, so the RTL is unchanged.
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
  logic [31:0] dbg_pc, dbg_instr;
  logic        dbg_illegal, dbg_system;

  riscv_core #(.IMEM_WORDS(IMEM_WORDS), .DMEM_WORDS(DMEM_WORDS)) dut (
    .clk(clk), .rst(rst),
    .dbg_pc(dbg_pc), .dbg_instr(dbg_instr),
    .dbg_illegal(dbg_illegal), .dbg_system(dbg_system));

  always #5 clk = ~clk;

  logic [31:0] table_w [0:5*MAX_ROWS-1];                 // +LAYERS
  logic [31:0] expect_w [0:EXP_WORDS-1];                 // +EXPECT
  string       prog, data, input_file, layers_file, expect_file, trace_file;
  int          trace_fd = 0, trace_lines = 0, trace_max = -1;
  int          stop_marker = -1;
  longint      max_cycles = 64'd100_000_000;
  longint      cycles = 0, last_mark = 0;
  int          errors = 0, layers_checked = 0, table_rows = 0;

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
    $write("output:");
    for (int i = 0; i < 12; i++) $write(" %h", dmem_byte(OUTPUT_ADDR + i));
    $write("  label: %h%h%h%h\n", dmem_byte(LABEL_ADDR + 3), dmem_byte(LABEL_ADDR + 2),
           dmem_byte(LABEL_ADDR + 1), dmem_byte(LABEL_ADDR));
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
    if (!$value$plusargs("DATA=%s", data))     data = "";
    if (!$value$plusargs("INPUT=%s", input_file))   input_file = "";
    if (!$value$plusargs("LAYERS=%s", layers_file)) layers_file = "";
    if (!$value$plusargs("EXPECT=%s", expect_file)) expect_file = "";
    if (!$value$plusargs("TRACE=%s", trace_file))   trace_file = "";
    if (!$value$plusargs("TRACE_MAX=%d", trace_max)) trace_max = -1;
    if (!$value$plusargs("STOP=%d", stop_marker))    stop_marker = -1;
    if (!$value$plusargs("MAX=%d", max_cycles))      max_cycles = 64'd100_000_000;

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
    #1;                                      // let rst = 0 reach rf_we

    // Each iteration looks at the instruction in the middle of its cycle
    // (all combinational logic settled), then lets the clock edge commit it.
    forever begin
      if (trace_fd != 0 && dut.rf_we && dut.rd_addr != 5'd0 &&
          (trace_max < 0 || trace_lines < trace_max)) begin
        $fdisplay(trace_fd, "%h x%-2d %h", dbg_pc, dut.rd_addr, dut.wb_data);
        trace_lines++;
      end
      if (dut.dmem_we && dut.alu_y == MARKER) begin
        $display("marker %2d: %10d cycles  (total %0d)", dut.rs2_data, cycles - last_mark, cycles);
        last_mark = cycles;
        check_marker(dut.rs2_data);
        if (dut.rs2_data == stop_marker) finish_run("stop marker");
      end
      if (dbg_illegal)           finish_run("illegal instruction");
      if (dbg_system)            finish_run("ebreak");
      if (cycles >= max_cycles)  finish_run("cycle limit");
      @(negedge clk);
      cycles++;
    end
  end
endmodule
