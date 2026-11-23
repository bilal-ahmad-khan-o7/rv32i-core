`timescale 1ns/1ps
// hazard_unit.sv - the pipeline's stall and flush decisions.
//
// stall (load-use): the instruction in ID reads a register that the load in EX will
//   write. The loaded value is ready only at the end of MEM, one cycle too late for
//   forwarding, so ID waits one cycle: the PC and IF/ID hold, and a bubble goes into
//   ID/EX. Then MEM/WB forwards the value. rs3 counts only when the instruction reads
//   it (rs3_read: DOT4.S8). rs1 and rs2 are compared by field, whether or not the
//   instruction reads them; rv32iss's cycle model uses the same rule.
//
// flush (redirect): a taken branch, jal or jalr in EX. The two instructions behind it,
//   in IF and ID, are on the wrong path: both become bubbles, and IF fetches the target.
//
// fetch stop: once ebreak, ecall or an illegal word is in ID, nothing behind it may run,
//   so that when it reaches WB (and the run stops) no younger instruction has written
//   anything. IF/ID takes bubbles and the PC holds, until reset. A redirect in the same
//   cycle wins: the instruction in ID is then on the wrong path.
module hazard_unit (
  input  logic       clk,
  input  logic       rst,
  // ID: the instruction in IF/ID
  input  logic       if_id_valid,
  input  logic [4:0] if_id_rs1_addr,
  input  logic [4:0] if_id_rs2_addr,
  input  logic [4:0] if_id_rd_addr,        // rs3's address
  input  logic       id_rs3_read,
  input  logic       id_system,
  input  logic       id_illegal,
  // EX: the instruction in ID/EX
  input  logic       id_ex_mem_read,
  input  logic [4:0] id_ex_rd_addr,
  input  logic       ex_redirect,          // pc_redirect of a valid instruction
  // decisions
  output logic       stall,                // load-use: ID waits one cycle
  output logic       flush,                // redirect: drop the instructions in IF and ID
  output logic       pc_hold,              // to if_stage: fetch the same PC again
  output logic       if_id_write,          // 0: IF/ID holds
  output logic       if_id_flush,          // 1: IF/ID becomes a bubble
  output logic       id_ex_flush           // 1: ID/EX becomes a bubble
);
  logic id_stop, fetch_stopped;

  assign stall = id_ex_mem_read && id_ex_rd_addr != 5'd0 &&
                 (id_ex_rd_addr == if_id_rs1_addr ||
                  id_ex_rd_addr == if_id_rs2_addr ||
                  (id_rs3_read && id_ex_rd_addr == if_id_rd_addr));

  assign flush = ex_redirect;

  assign id_stop = if_id_valid && (id_system || id_illegal);

  always_ff @(posedge clk) begin
    if (rst)                               fetch_stopped <= 1'b0;
    else if (id_stop && !stall && !flush)  fetch_stopped <= 1'b1;   // it moves on to EX
  end

  assign pc_hold     = stall || id_stop || fetch_stopped;           // (a redirect overrides it)
  assign if_id_write = !stall;
  assign if_id_flush = flush || ((id_stop || fetch_stopped) && !stall);
  assign id_ex_flush = flush || stall;
endmodule
