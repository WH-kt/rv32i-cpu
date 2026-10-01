//============================================================================
// tb_regfile.v -- unit test for rv32i_regfile
//
// Covers: x0 read/write, write enable, both read ports, reset initialisation
// and the write-through bypass (hazard H3) including its enabling conditions.
//============================================================================
`timescale 1ns/1ps
`include "rv32i_defs.vh"

module tb_regfile;

    reg         clk, reset, we;
    reg  [4:0]  waddr, raddr1, raddr2;
    reg  [31:0] wdata;
    wire [31:0] rdata1, rdata2;

    integer errors;
    integer i;

    rv32i_regfile #(.RF_INIT_EN(1)) dut (
        .clk(clk), .reset(reset), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr1(raddr1), .raddr2(raddr2), .rdata1(rdata1), .rdata2(rdata2));

    always #5 clk = ~clk;

    task expect_read;
        input [4:0]  r1, r2;
        input [31:0] e1, e2;
        input [127:0] what;
        begin
            raddr1 = r1; raddr2 = r2;
            #6;
            if (rdata1 !== e1 || rdata2 !== e2) begin
                $display("FAIL %0s: r[%0d]=%08x (exp %08x) r[%0d]=%08x (exp %08x)",
                         what, r1, rdata1, e1, r2, rdata2, e2);
                errors = errors + 1;
            end
        end
    endtask

    task write_reg;
        input [4:0]  a;
        input [31:0] d;
        begin
            @(negedge clk);
            we = 1'b1; waddr = a; wdata = d;
            @(posedge clk);
            #1;
            @(negedge clk);
            we = 1'b0; waddr = 5'd0; wdata = 32'd0;
        end
    endtask

    initial begin
        errors = 0;
        clk = 0; reset = 1; we = 0;
        waddr = 0; wdata = 0; raddr1 = 0; raddr2 = 0;

        //--------------------------------------------------- reset clears state
        repeat (3) @(posedge clk);
        @(negedge clk); reset = 0;

        for (i = 0; i < 32; i = i + 1) begin
            raddr1 = i[4:0]; raddr2 = 5'd0;
            #6;
            if (rdata1 !== 32'd0) begin
                $display("FAIL reset: r[%0d]=%08x, expected 0", i, rdata1);
                errors = errors + 1;
            end
        end

        //--------------------------------------------------- write / read back
        write_reg(5'd1,  32'hDEADBEEF);
        write_reg(5'd31, 32'h12345678);
        expect_read(5'd1, 5'd31, 32'hDEADBEEF, 32'h12345678, "readback");

        //--------------------------------------------------- x0 is hardwired
        write_reg(5'd0, 32'hFFFFFFFF);
        expect_read(5'd0, 5'd1, 32'd0, 32'hDEADBEEF, "x0 write ignored");

        //--------------------------------------------------- write enable low
        @(negedge clk); we = 1'b0; waddr = 5'd2; wdata = 32'hA5A5A5A5;
        @(posedge clk); #1; @(negedge clk);
        expect_read(5'd2, 5'd0, 32'd0, 32'd0, "we=0 must not write");

        //--------------------------------------------------- write-through (H3)
        // read port 1 targets the register being written in this very cycle
        @(negedge clk);
        we = 1'b1; waddr = 5'd3; wdata = 32'hCAFEBABE;
        raddr1 = 5'd3; raddr2 = 5'd1;
        #1;
        if (rdata1 !== 32'hCAFEBABE) begin
            $display("FAIL write-through: same-cycle read got %08x, expected CAFEBABE",
                     rdata1);
            errors = errors + 1;
        end
        if (rdata2 !== 32'hDEADBEEF) begin
            $display("FAIL write-through: other port disturbed (%08x)", rdata2);
            errors = errors + 1;
        end
        @(posedge clk); #1; @(negedge clk); we = 1'b0;

        // write-through must not fire for x0 ...
        we = 1'b1; waddr = 5'd0; wdata = 32'h99999999; raddr1 = 5'd0;
        #1;
        if (rdata1 !== 32'd0) begin
            $display("FAIL write-through to x0 leaked (%08x)", rdata1);
            errors = errors + 1;
        end

        // ... nor when the write is disabled
        we = 1'b0; waddr = 5'd4; wdata = 32'h77777777; raddr1 = 5'd4;
        #1;
        if (rdata1 !== 32'd0) begin
            $display("FAIL write-through fired with we=0 (%08x)", rdata1);
            errors = errors + 1;
        end

        //--------------------------------------------------- result
        if (errors == 0) begin
            $display("tb_regfile: PASS");
        end else begin
            $display("tb_regfile: FAIL (%0d errors)", errors);
            $fatal;
        end
        $finish;
    end

endmodule
