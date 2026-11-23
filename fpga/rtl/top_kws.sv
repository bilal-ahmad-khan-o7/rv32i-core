`timescale 1ns/1ps
// top_kws.sv - the PYNQ-Z2 wrapper: one core, preloaded with KWS build (c) and one
// recording, run once after reset; the 4 LEDs show the predicted word.
//
//   sysclk  125 MHz board clock -> clock_gen -> the core clock (100 MHz by default)
//   btn0    reset; the core also waits until the MMCM has locked
//   led     the label the program stores to kws_label (0..11, binary)
//   led4_g  done: the core reached ebreak
//   led5_r  error: the core reached an illegal instruction
//
// The same wrapper serves both cores: build.tcl reads either pipelined/ or single_cycle/,
// whose top modules are both riscv_core, with the same parameters and ports. When the
// core finishes, the wrapper holds it in reset, so it runs exactly once per button press;
// the memories keep their contents, and a new run recomputes everything from kws_input.
module top_kws #(
  parameter      IMEM_FILE = "",       // program image (set by build.tcl)
  parameter      DMEM_FILE = "",       // data image with the input merged in (fpga/make_mem.py)
  parameter real CLK_DIVIDE = 10.0     // core clock = 1000 MHz / CLK_DIVIDE
) (
  input  logic       sysclk,
  input  logic       btn0,
  output logic [3:0] led,
  output logic       led4_g,
  output logic       led5_r
);
  localparam logic [31:0] LABEL_ADDR = 32'h1000_F20C;      // kws_label (single_cycle/kws/sw/link.ld)

  logic        clk, locked, rst, core_rst;
  logic [31:0] dbg_pc, dbg_instr, dbg_mem_addr, dbg_mem_wdata;
  logic        dbg_illegal, dbg_system, dbg_mem_we;
  logic        done, error;
  logic [3:0]  label;

  clock_gen #(.DIVIDE(CLK_DIVIDE)) u_clk (.clk_in(sysclk), .clk_out(clk), .locked(locked));

  reset_sync u_rst (.clk(clk), .async_rst(btn0 | ~locked), .rst(rst));

  assign core_rst = rst | done | error;                    // finished: hold it there

  riscv_core #(
    .IMEM_WORDS(8192), .DMEM_WORDS(16384),                 // 32 KiB and 64 KiB, as for KWS
    .INIT_FILE(IMEM_FILE), .DMEM_INIT_FILE(DMEM_FILE)
  ) u_core (
    .clk(clk), .rst(core_rst),
    .dbg_pc(dbg_pc), .dbg_instr(dbg_instr), .dbg_illegal(dbg_illegal), .dbg_system(dbg_system),
    .dbg_mem_we(dbg_mem_we), .dbg_mem_addr(dbg_mem_addr), .dbg_mem_wdata(dbg_mem_wdata));

  always_ff @(posedge clk) begin
    if (rst) begin
      done  <= 1'b0;
      error <= 1'b0;
      label <= 4'd0;
    end else begin
      if (dbg_mem_we && dbg_mem_addr == LABEL_ADDR) label <= dbg_mem_wdata[3:0];
      if (dbg_system)  done  <= 1'b1;
      if (dbg_illegal) error <= 1'b1;
    end
  end

  assign led    = label;
  assign led4_g = done;
  assign led5_r = error;
endmodule
