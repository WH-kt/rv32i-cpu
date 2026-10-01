// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
//============================================================================
// rv32i_regfile.v -- 32 x 32 register file, 2 read ports, 1 write port
//
//  * x0 reads as zero and writes to x0 are discarded.
//  * The read ports contain a write-through bypass: when the write port of the
//    same cycle targets the register being read, the write data is returned
//    instead of the stored value.  This is hazard H3 of the pipeline: an
//    instruction in ID reading a register written by an instruction in WB in
//    the same cycle would otherwise capture a stale value, and by the time it
//    reaches EX the producer has already left the pipeline, so no forwarding
//    path could repair it.
//  * RF_INIT_EN=1 clears every register on reset.  This costs 1024 flops but
//    makes architectural state deterministic after reset, which outranks area
//    in this project's priority list.  Set to 0 to save the reset network.
//============================================================================
`include "rv32i_defs.vh"

module rv32i_regfile #(
    parameter RF_INIT_EN = 1
)(
    input  wire        clk,
    input  wire        reset,
    input  wire        we,        // write enable (from MEM/WB stage)
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata,
    input  wire [4:0]  raddr1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2
);

    reg [31:0] rf [0:31];
    integer    i;

    always @(posedge clk) begin
        if (reset) begin
            if (RF_INIT_EN != 0) begin
                for (i = 0; i < 32; i = i + 1) begin
                    rf[i] <= 32'd0;
                end
            end
        end else if (we && (waddr != 5'd0)) begin
            rf[waddr] <= wdata;
        end
    end

    // ---- write-through bypass (hazard H3) --------------------------------
    wire wt1 = we && (waddr != 5'd0) && (waddr == raddr1);
    wire wt2 = we && (waddr != 5'd0) && (waddr == raddr2);

    assign rdata1 = (raddr1 == 5'd0) ? 32'd0 : (wt1 ? wdata : rf[raddr1]);
    assign rdata2 = (raddr2 == 5'd0) ? 32'd0 : (wt2 ? wdata : rf[raddr2]);

endmodule
