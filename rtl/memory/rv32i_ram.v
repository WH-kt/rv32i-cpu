`timescale 1ns/1ps
//============================================================================
// rv32i_ram.v -- word addressed RAM with byte write enables
//
//   * combinational read (zero latency), synchronous byte enabled write
//   * index is addr[AW+1:2]; the byte address is used unmodified
//   * every location is pre-filled (FILL) before the optional $readmemh, so
//     simulation never starts from unknown values.  Instruction memory is
//     filled with NOPs, data memory with zeros (which is also what the
//     reference model starts from).
//
// The single initial block is the standard FPGA BRAM initialisation pattern;
// it is the only initial block in the RTL.
//============================================================================
`include "rv32i_defs.vh"

module rv32i_ram #(
    parameter MEM_WORDS = 16384,
    parameter INIT_FILE = "",
    parameter [31:0] FILL = 32'h0000_0000
)(
    input  wire        clk,
    // Byte address.  Only addr[AW+1:2] indexes the array: the upper bits are
    // consumed by the range check below and addr[1:0] is the intra-word byte
    // offset that the core has already turned into wstrb.  Both are therefore
    // intentionally unread here; the lint pragma records that decision.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [31:0] addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        we,
    input  wire [3:0]  wstrb,
    input  wire [31:0] wdata,
    output wire [31:0] rdata
);

    localparam AW = $clog2(MEM_WORDS);

    reg [31:0] mem [0:MEM_WORDS-1];

    wire [AW-1:0] widx = addr[AW+1:2];
    wire          hit  = (addr < (MEM_WORDS * 4));

    assign rdata = hit ? mem[widx] : 32'd0;

    integer i;

    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1) begin
            mem[i] = FILL;
        end
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk) begin
        if (we && hit) begin
            if (wstrb[0]) mem[widx][7:0]   <= wdata[7:0];
            if (wstrb[1]) mem[widx][15:8]  <= wdata[15:8];
            if (wstrb[2]) mem[widx][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[widx][31:24] <= wdata[31:24];
        end
    end

endmodule
