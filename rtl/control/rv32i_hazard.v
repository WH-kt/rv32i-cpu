// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
//============================================================================
// rv32i_hazard.v -- forwarding selects and the load-use interlock
//
// Purely combinational.  This module is the whole of the pipeline's data
// hazard logic; the cases are closed and finite (docs/03 section 6):
//
//   H1  producer in EX/MEM  -> EX operands   (fwd_*_sel = FWD_MEM, priority)
//   H2  producer in MEM/WB  -> EX operands   (fwd_*_sel = FWD_WB)
//   H3  producer in WB      -> ID read port  (handled inside rv32i_regfile)
//   H4  producer is a load  -> stall one cycle, inject a bubble into ID/EX
//   H6  store data          -> resolved in EX by H1/H2, no second network
//
// Every compare is gated by "destination is not x0" and by the producer
// actually writing a register.
//============================================================================
`include "rv32i_defs.vh"

module rv32i_hazard (
    // ---- producer in EX (load-use check) --------------------------------
    input  wire        id_ex_valid,
    input  wire        id_ex_mem_re,
    input  wire [4:0]  id_ex_rd_addr,
    // ---- consumer in EX (forwarding targets) ----------------------------
    input  wire [4:0]  id_ex_rs1_addr,
    input  wire [4:0]  id_ex_rs2_addr,
    // ---- producer in MEM (EX/MEM stage register) ------------------------
    input  wire        ex_mem_valid,
    input  wire        ex_mem_rf_we,
    input  wire        ex_mem_mem_re,
    input  wire [4:0]  ex_mem_rd_addr,
    // ---- producer in WB (MEM/WB stage register) -------------------------
    input  wire        mem_wb_valid,
    input  wire        mem_wb_rf_we,
    input  wire [4:0]  mem_wb_rd_addr,
    // ---- consumer in ID (IF/ID stage register) --------------------------
    input  wire        if_id_valid,
    input  wire        if_id_uses_rs1,
    input  wire        if_id_uses_rs2,
    input  wire [4:0]  if_id_rs1_addr,
    input  wire [4:0]  if_id_rs2_addr,
    // ---- outputs ---------------------------------------------------------
    output reg  [1:0]  fwd_a_sel,
    output reg  [1:0]  fwd_b_sel,
    output reg         stall
);

    // ---- H1: EX/MEM -> EX ------------------------------------------------
    // A load in EX/MEM cannot forward: its data only exists after the MEM
    // stage.  The load-use interlock (H4) makes that case unreachable; the
    // ~mem_re term keeps the property true even if the interlock changes.
    wire h1_a = ex_mem_valid & ex_mem_rf_we & ~ex_mem_mem_re &
                (ex_mem_rd_addr != 5'd0) & (ex_mem_rd_addr == id_ex_rs1_addr);
    wire h1_b = ex_mem_valid & ex_mem_rf_we & ~ex_mem_mem_re &
                (ex_mem_rd_addr != 5'd0) & (ex_mem_rd_addr == id_ex_rs2_addr);

    // ---- H2: MEM/WB -> EX ------------------------------------------------
    wire h2_a = mem_wb_valid & mem_wb_rf_we &
                (mem_wb_rd_addr != 5'd0) & (mem_wb_rd_addr == id_ex_rs1_addr);
    wire h2_b = mem_wb_valid & mem_wb_rf_we &
                (mem_wb_rd_addr != 5'd0) & (mem_wb_rd_addr == id_ex_rs2_addr);

    // ---- H4: load-use interlock -----------------------------------------
    wire use_rs1_hit = if_id_uses_rs1 & (if_id_rs1_addr == id_ex_rd_addr);
    wire use_rs2_hit = if_id_uses_rs2 & (if_id_rs2_addr == id_ex_rd_addr);

    always @(*) begin
        fwd_a_sel = h1_a ? `FWD_MEM : (h2_a ? `FWD_WB : `FWD_REG);
        fwd_b_sel = h1_b ? `FWD_MEM : (h2_b ? `FWD_WB : `FWD_REG);

        stall = id_ex_valid & if_id_valid & id_ex_mem_re &
                (id_ex_rd_addr != 5'd0) & (use_rs1_hit | use_rs2_hit);
    end

endmodule
