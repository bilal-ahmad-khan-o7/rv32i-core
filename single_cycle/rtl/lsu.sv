`timescale 1ns/1ps
// lsu.sv - load/store unit: byte-lane logic between the 32-bit datapath and
// the word-organised data memory.
// Store side: shift the data into its lane and build the byte write mask.
// Load side:  read word -> select lane -> extend (signed or unsigned).
// Misaligned accesses are NOT handled (known limitation).
module lsu (
  input  logic [2:0]  funct3,
  input  logic [1:0]  addr_lo,      // addr[1:0]: which byte inside the word
  // store side
  input  logic [31:0] store_data,   // rs2
  output logic [31:0] mem_wdata,
  output logic [3:0]  mem_wmask,
  // load side
  input  logic [31:0] mem_rdata,    // whole word from dmem
  output logic [31:0] load_data
);
  // ---- store side --------------------------------------------------------
  always_comb begin
    case (funct3)
      3'b000: begin                                   // sb
        mem_wdata = store_data << (8 * addr_lo);
        mem_wmask = 4'b0001 << addr_lo;
      end
      3'b001: begin                                   // sh
        mem_wdata = store_data << (8 * addr_lo);
        mem_wmask = 4'b0011 << addr_lo;
      end
      default: begin                                  // sw
        mem_wdata = store_data;
        mem_wmask = 4'b1111;
      end
    endcase
  end

  // ---- load side ---------------------------------------------------------
  logic [7:0]  sel_byte;
  logic [15:0] sel_half;
  logic [31:0] lb_data, lh_data, lbu_data, lhu_data;

  // 1. select the lane
  assign sel_byte = mem_rdata[8*addr_lo +: 8];                        // byte at addr_lo
  assign sel_half = addr_lo[1] ? mem_rdata[31:16] : mem_rdata[15:0];

  // 2. extend it
  assign lb_data  = {{24{sel_byte[7]}},  sel_byte};                   // copies of bit 7
  assign lh_data  = {{16{sel_half[15]}}, sel_half};                   // copies of bit 15
  assign lbu_data = {24'b0, sel_byte};                                // zeros above
  assign lhu_data = {16'b0, sel_half};

  // 3. pick by access size
  always_comb begin
    case (funct3)
      3'b000:  load_data = lb_data;                         // lb  (signed)
      3'b001:  load_data = lh_data;                         // lh  (signed)
      3'b100:  load_data = lbu_data;                        // lbu (unsigned)
      3'b101:  load_data = lhu_data;                        // lhu (unsigned)
      default: load_data = mem_rdata;                       // lw
    endcase
  end
endmodule
