// SPDX-License-Identifier: MIT
//============================================================================
// tb_reset.v -- reset determinism and the reset-to-first-instruction timing
//
// Checks the properties claimed in docs/04-datapath-control.md section 3:
//   * during reset the PC sits at RESET_PC, no memory access and no retire
//     pulse is issued, no trap is raised, and the register file is cleared;
//   * after reset the first instruction is fetched in cycle 1, retires in
//     cycle 3 (the EX->MEM commit point) and writes its register in cycle 5.
//
// A non-zero RESET_PC is used so that "PC == 0 by accident" cannot pass.
//============================================================================
`timescale 1ns/1ps
`include "rv32i_defs.vh"

module tb_reset;

    localparam RESET_PC = 32'h0000_0040;      // word 16
    localparam P0       = RESET_PC >> 2;

    reg  clk, reset;

    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we, dmem_re;
    wire        trap_o;
    wire [3:0]  trap_cause_o;
    wire [31:0] trap_pc_o, trap_tval_o;
    wire        retire_valid_o;
    wire [31:0] retire_pc_o, retire_instr_o;
    wire        halt_i = 1'b0;

    reg [31:0] imem [0:63];
    reg [31:0] dmem [0:63];
    integer    errors;
    integer    cyc;
    integer    i;

    assign imem_rdata = imem[imem_addr[7:2]];
    assign dmem_rdata = dmem[dmem_addr[7:2]];

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (dmem_we) begin
            if (dmem_wstrb[0]) dmem[dmem_addr[7:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) dmem[dmem_addr[7:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) dmem[dmem_addr[7:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) dmem[dmem_addr[7:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    rv32i_cpu #(.RESET_PC(RESET_PC)) dut (
        .clk(clk), .reset(reset),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb),
        .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_rdata(dmem_rdata),
        .halt_i(halt_i),
        .trap_o(trap_o), .trap_cause_o(trap_cause_o), .trap_pc_o(trap_pc_o),
        .trap_tval_o(trap_tval_o),
        .retire_valid_o(retire_valid_o), .retire_pc_o(retire_pc_o),
        .retire_instr_o(retire_instr_o));

    task chk;
        input        cond;
        input [511:0] what;
        begin
            if (!cond) begin
                $display("FAIL cycle %0d: %0s", cyc, what);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        clk = 0; reset = 1; cyc = 0;

        //--------------------------------------------------- program image
        for (i = 0; i < 64; i = i + 1) begin
            imem[i] = 32'h00000013;             // nop (addi x0,x0,0)
            dmem[i] = 32'h00000000;
        end
        imem[P0 + 0] = 32'h00500093;            // addi x1, x0, 5
        imem[P0 + 1] = 32'h00708113;            // addi x2, x1, 7   (forwarding)
        imem[P0 + 2] = 32'h00202823;            // sw   x2, 16(x0)
        imem[P0 + 3] = 32'h00000013;            // nop

        //--------------------------------------------------- during reset
        repeat (3) @(posedge clk);
        #1;
        chk(imem_addr === RESET_PC, "PC must be RESET_PC during reset");
        chk(dmem_we === 1'b0,       "no data write during reset");
        chk(dmem_re === 1'b0,       "no data read during reset");
        chk(retire_valid_o === 1'b0, "no retire during reset");
        chk(trap_o === 1'b0,        "no trap during reset");
        for (i = 0; i < 32; i = i + 1) begin
            chk(dut.u_regfile.rf[i] === 32'd0, "register file must be cleared by reset");
        end

        //--------------------------------------------------- release reset
        // Cycle numbering: cycle 1 is the first cycle with reset low.  The
        // checks are placed right after each rising edge, so the sampled
        // values are those of the following cycle.
        @(negedge clk);
        reset = 1'b0;
        #1; cyc = 1;
        chk(imem_addr === RESET_PC, "cycle 1 must fetch RESET_PC");
        chk(retire_valid_o === 1'b0, "nothing retires in cycle 1");
        chk(dmem_we === 1'b0, "no store in cycle 1");

        // end of cycle 1: PC advanced, I0 captured into IF/ID
        @(posedge clk); #1; cyc = 2;
        chk(imem_addr === RESET_PC + 4, "cycle 2 must fetch RESET_PC+4");
        chk(retire_valid_o === 1'b0, "nothing retires in cycle 2");

        // cycle 3: I0 in EX -> retire pulse at the commit point
        @(posedge clk); #1; cyc = 3;
        chk(retire_valid_o === 1'b1, "first instruction must retire in cycle 3");
        chk(retire_pc_o === RESET_PC, "retire PC of the first instruction");
        chk(retire_instr_o === 32'h00500093, "retire instruction word");

        // cycle 4: I1 in EX (depends on I0 through forwarding)
        @(posedge clk); #1; cyc = 4;
        chk(retire_valid_o === 1'b1, "second instruction must retire in cycle 4");
        chk(retire_pc_o === RESET_PC + 4, "retire PC of the second instruction");

        // cycle 5: I0 in WB
        @(posedge clk); #1; cyc = 5;
        chk(retire_pc_o === RESET_PC + 8, "third instruction must retire in cycle 5");

        // cycle 6: I0 has written back, I2 (the store) is in MEM
        @(posedge clk); #1; cyc = 6;
        chk(dut.u_regfile.rf[1] === 32'd5, "x1 must be 5 after cycle 5");
        chk(dut.u_regfile.rf[0] === 32'd0, "x0 must stay 0");
        chk(dmem_we === 1'b1, "store must drive dmem_we in its MEM cycle");
        chk(dmem_addr === 32'd16, "store address");
        chk(dmem_wstrb === 4'b1111, "word store byte enables");

        // cycle 7: the store has been applied
        @(posedge clk); #1; cyc = 7;
        chk(dut.u_regfile.rf[2] === 32'd12, "x2 must be 12 (forwarded)");
        chk(dmem[4] === 32'd12, "memory must hold the stored value");
        chk(trap_o === 1'b0, "no trap in this program");

        if (errors == 0) begin
            $display("tb_reset: PASS (reset state + 5 stage fill timing)");
        end else begin
            $display("tb_reset: FAIL (%0d errors)", errors);
            $fatal;
        end
        $finish;
    end

endmodule
