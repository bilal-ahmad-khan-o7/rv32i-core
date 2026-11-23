`timescale 1ns/1ps
// if_stage.sv - Instruction Fetch, for a synchronous-read instruction memory.
//
// Changed from single_cycle/rtl/if_stage.sv: the instruction memory is addressed with
// next_pc, not pc. pc_reg and the memory's address register take the same value at
// the same clock edge, so during each cycle `instr` is the word at `pc`, exactly as
// with the single-cycle core's combinational memory, and there is no extra fetch
// cycle. Holding the PC means reading the same word again.
//
// next_pc, in priority order:
//   reset         RESET_ADDR    so the first word is ready when reset ends
//   pc_redirect   redirect_pc   taken branch, jal or jalr in EX (the core flushes IF/ID, ID/EX)
//   hold          pc            load-use stall, or fetch stopped after ebreak/ecall
//   otherwise     pc + 4
module if_stage #(
  parameter logic [31:0] RESET_ADDR = 32'h0000_0000,
  parameter int          IMEM_WORDS = 1024,
  parameter              INIT_FILE  = ""
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        hold,          // from hazard_unit: fetch this PC again
  input  logic        pc_redirect,   // from ex_stage: taken branch, jal or jalr
  input  logic [31:0] redirect_pc,   // from ex_stage: the target address
  output logic [31:0] pc,
  output logic [31:0] pc_plus4,
  output logic [31:0] instr
);
  logic [31:0] next_pc;

  assign pc_plus4 = pc + 32'd4;

  always_comb begin                                          // next-PC mux
    if      (rst)         next_pc = RESET_ADDR;
    else if (pc_redirect) next_pc = redirect_pc;
    else if (hold)        next_pc = pc;
    else                  next_pc = pc_plus4;
  end

  pc_reg #(.RESET_ADDR(RESET_ADDR)) u_pc (
    .clk(clk), .rst(rst), .next_pc(next_pc), .pc(pc));

  imem #(.WORDS(IMEM_WORDS), .INIT_FILE(INIT_FILE)) u_imem (
    .clk(clk), .addr(next_pc), .instr(instr));
endmodule
