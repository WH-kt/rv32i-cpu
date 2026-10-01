// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
//============================================================================
// rv32i_soc.v -- core + memories + simulation control MMIO
//
// The CPU core itself only has the plain address/data/enable interface.  This
// wrapper adds the two memories and a tiny MMIO block so that real programs
// can print, mark progress and terminate.  The MMIO map is identical to the
// reference model used for differential verification (../rvai/sw/iss.py), so
// the event logs of RTL and model can be compared with a plain line diff.
//
//   0x1000_0000  W  putchar   -> putc_valid_o, putc_data_o = wdata[7:0]
//   0x1000_0004  W  halt      -> halt_o, halt_code_o, and halt_i to the core
//   0x1000_0008  W  marker    -> mark_valid_o, mark_data_o
//   0x1000_000C  R  cycles    -> free running cycle counter
//
// Unmapped addresses read as zero and ignore writes.  The event outputs are
// combinational pulses valid during the MEM cycle of the store; a testbench
// samples them on the rising clock edge.
//============================================================================
`include "rv32i_defs.vh"

module rv32i_soc #(
    parameter MEM_WORDS = 16384,
    parameter INIT_FILE = "",
    parameter RESET_PC  = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        reset,

    // ---- testbench observability ----
    output wire        halt_o,
    output wire [7:0]  halt_code_o,
    output wire        trap_o,
    output wire [3:0]  trap_cause_o,
    output wire [31:0] trap_pc_o,
    output wire [31:0] trap_tval_o,
    output wire        retire_valid_o,
    output wire [31:0] retire_pc_o,
    output wire [31:0] retire_instr_o,
    output wire [31:0] cycle_o,

    // ---- MMIO event pulses ----
    output wire        putc_valid_o,
    output wire [7:0]  putc_data_o,
    output wire        mark_valid_o,
    output wire [31:0] mark_data_o
);

    localparam MEM_BYTES = MEM_WORDS * 4;

    wire [31:0] imem_addr;
    wire [31:0] imem_rdata;
    wire [31:0] dmem_addr;
    wire [31:0] dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we;
    wire        dmem_re;
    wire [31:0] dmem_rdata_ram;
    wire [31:0] dmem_rdata_core;

    // ---- MMIO decode (full word address, no masking) ----------------------
    wire mmio_putc_w = dmem_we & (dmem_addr == `SIM_PUTCHAR);
    wire mmio_halt_w = dmem_we & (dmem_addr == `SIM_HALT);
    wire mmio_mark_w = dmem_we & (dmem_addr == `SIM_MARKER);
    wire mmio_cyc_r  = dmem_re & (dmem_addr == `SIM_CYCLES);

    // ---- cycle counter ----------------------------------------------------
    reg [31:0] cycle_cnt;
    always @(posedge clk) begin
        if (reset) cycle_cnt <= 32'd0;
        else       cycle_cnt <= cycle_cnt + 32'd1;
    end
    assign cycle_o = cycle_cnt;

    // ---- core -------------------------------------------------------------
    rv32i_cpu #(
        .RESET_PC (RESET_PC)
    ) u_cpu (
        .clk           (clk),
        .reset         (reset),
        .imem_addr     (imem_addr),
        .imem_rdata    (imem_rdata),
        .dmem_addr     (dmem_addr),
        .dmem_wdata    (dmem_wdata),
        .dmem_wstrb    (dmem_wstrb),
        .dmem_we       (dmem_we),
        .dmem_re       (dmem_re),
        .dmem_rdata    (dmem_rdata_core),
        .halt_i        (mmio_halt_w),
        .trap_o        (trap_o),
        .trap_cause_o  (trap_cause_o),
        .trap_pc_o     (trap_pc_o),
        .trap_tval_o   (trap_tval_o),
        .retire_valid_o(retire_valid_o),
        .retire_pc_o   (retire_pc_o),
        .retire_instr_o(retire_instr_o)
    );

    // ---- instruction memory (filled with NOPs, then the image) ------------
    rv32i_ram #(
        .MEM_WORDS (MEM_WORDS),
        .INIT_FILE (INIT_FILE),
        .FILL      (`RF_INIT_NOP)
    ) u_imem (
        .clk   (clk),
        .addr  (imem_addr),
        .we    (1'b0),
        .wstrb (4'd0),
        .wdata (32'd0),
        .rdata (imem_rdata)
    );

    // ---- data memory ------------------------------------------------------
    wire ram_hit = (dmem_addr < MEM_BYTES);
    wire ram_we  = dmem_we & ram_hit;

    rv32i_ram #(
        .MEM_WORDS (MEM_WORDS),
        .INIT_FILE (INIT_FILE),
        .FILL      (32'h0000_0000)
    ) u_dmem (
        .clk   (clk),
        .addr  (dmem_addr),
        .we    (ram_we),
        .wstrb (dmem_wstrb),
        .wdata (dmem_wdata),
        .rdata (dmem_rdata_ram)
    );

    // ---- data read mux ----------------------------------------------------
    assign dmem_rdata_core = ram_hit ? dmem_rdata_ram :
                             (mmio_cyc_r ? cycle_o : 32'd0);

    // ---- MMIO event outputs ----------------------------------------------
    assign putc_valid_o = mmio_putc_w;
    assign putc_data_o  = dmem_wdata[7:0];
    assign mark_valid_o = mmio_mark_w;
    assign mark_data_o  = dmem_wdata;
    assign halt_o       = mmio_halt_w;
    assign halt_code_o  = dmem_wdata[7:0];

endmodule
