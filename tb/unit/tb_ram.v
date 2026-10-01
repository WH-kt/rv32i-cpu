//============================================================================
// tb_ram.v -- unit test for rv32i_ram
//
// Byte enables are the interface between the core's store width/alignment
// logic and the memory, so they are exercised lane by lane, together with the
// address range behaviour (reads outside the array return zero, writes outside
// are ignored) and the fact that writes only take effect on the clock edge.
//============================================================================
`timescale 1ns/1ps
`include "rv32i_defs.vh"

module tb_ram;

    localparam WORDS = 64;                 // 256 bytes

    reg         clk, we;
    reg  [31:0] addr;
    reg  [3:0]  wstrb;
    reg  [31:0] wdata;
    wire [31:0] rdata;

    integer errors;
    integer i;

    rv32i_ram #(.MEM_WORDS(WORDS), .INIT_FILE(""), .FILL(32'h00000000)) dut (
        .clk(clk), .addr(addr), .we(we), .wstrb(wstrb), .wdata(wdata),
        .rdata(rdata));

    always #5 clk = ~clk;

    task write_word;
        input [31:0] a;
        input [3:0]  s;
        input [31:0] d;
        begin
            @(negedge clk);
            addr = a; we = 1'b1; wstrb = s; wdata = d;
            @(posedge clk);
            #1;
            @(negedge clk);
            we = 1'b0; wstrb = 4'b0000;
        end
    endtask

    task expect_read;
        input [31:0]  a;
        input [31:0]  exp;
        input [255:0] what;
        begin
            addr = a; #1;
            if (rdata !== exp) begin
                $display("FAIL %0s: addr=%08x rdata=%08x expected %08x",
                         what, a, rdata, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        clk = 0; we = 0; addr = 0; wstrb = 0; wdata = 0;

        //--------------------------------------------------- whole word
        write_word(32'h0000_0010, 4'b1111, 32'hDEADBEEF);
        expect_read(32'h0000_0010, 32'hDEADBEEF, "word write/read");

        //--------------------------------------------------- every single lane
        // start from a known word, then overwrite exactly one byte
        write_word(32'h0000_0020, 4'b1111, 32'h00000000);
        write_word(32'h0000_0020, 4'b0001, 32'h000000AA);
        expect_read(32'h0000_0020, 32'h000000AA, "byte lane 0");
        write_word(32'h0000_0020, 4'b0010, 32'h0000BB00);
        expect_read(32'h0000_0020, 32'h0000BBAA, "byte lane 1");
        write_word(32'h0000_0020, 4'b0100, 32'h00CC0000);
        expect_read(32'h0000_0020, 32'h00CCBBAA, "byte lane 2");
        write_word(32'h0000_0020, 4'b1000, 32'hDD000000);
        expect_read(32'h0000_0020, 32'hDDCCBBAA, "byte lane 3");

        //--------------------------------------------------- halfword lanes
        write_word(32'h0000_0030, 4'b1111, 32'h00000000);
        write_word(32'h0000_0030, 4'b0011, 32'h0000BEEF);
        expect_read(32'h0000_0030, 32'h0000BEEF, "half lane 0");
        write_word(32'h0000_0030, 4'b1100, 32'hCAFE0000);
        expect_read(32'h0000_0030, 32'hCAFEBEEF, "half lane 1");

        //--------------------------------------------------- neighbouring words untouched
        write_word(32'h0000_0040, 4'b1111, 32'h11111111);
        write_word(32'h0000_0044, 4'b1111, 32'h22222222);
        write_word(32'h0000_0040, 4'b0001, 32'h00000033);
        expect_read(32'h0000_0040, 32'h11111133, "word 0x40 partial");
        expect_read(32'h0000_0044, 32'h22222222, "word 0x44 untouched");

        //--------------------------------------------------- addr[1:0] is ignored by the RAM
        expect_read(32'h0000_0041, 32'h11111133, "unaligned addr selects the word");
        expect_read(32'h0000_0043, 32'h11111133, "unaligned addr selects the word");

        //--------------------------------------------------- write only on the clock edge
        @(negedge clk);
        addr = 32'h0000_0050; we = 1'b1; wstrb = 4'b1111; wdata = 32'h55555555;
        #1;
        if (rdata === 32'h55555555) begin
            $display("FAIL write became visible before the clock edge");
            errors = errors + 1;
        end
        @(posedge clk); #1;
        we = 1'b0;
        expect_read(32'h0000_0050, 32'h55555555, "write visible after the edge");

        //--------------------------------------------------- out of range
        expect_read(32'h0000_0100, 32'h00000000, "read past the end returns 0");
        expect_read(32'hFFFF_0000, 32'h00000000, "far unmapped read returns 0");
        write_word(32'h0000_0100, 4'b1111, 32'hFFFFFFFF);
        expect_read(32'h0000_0000, 32'h00000000, "write past the end ignored (word 0)");
        write_word(32'hFFFF_0000, 4'b1111, 32'hFFFFFFFF);
        expect_read(32'h0000_0000, 32'h00000000, "write to unmapped ignored (word 0)");

        //--------------------------------------------------- every location readable
        for (i = 0; i < WORDS; i = i + 1) begin
            write_word(i * 4, 4'b1111, i + 32'h1000);
        end
        for (i = 0; i < WORDS; i = i + 1) begin
            expect_read(i * 4, i + 32'h1000, "fill/readback sweep");
        end

        if (errors == 0) begin
            $display("tb_ram: PASS");
        end else begin
            $display("tb_ram: FAIL (%0d errors)", errors);
            $fatal;
        end
        $finish;
    end

endmodule
