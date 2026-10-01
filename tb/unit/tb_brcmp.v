// SPDX-License-Identifier: MIT
//============================================================================
// tb_brcmp.v -- unit test for rv32i_brcmp
//
// Every branch condition is checked at the points where signed and unsigned
// interpretations differ, plus the equal-value case and both operand orders.
//============================================================================
`timescale 1ns/1ps
`include "rv32i_defs.vh"

module tb_brcmp;

    reg  [2:0]  br_op;
    reg  [31:0] a, b;
    wire        taken;

    integer errors;
    integer i;
    reg [31:0] ra, rb;

    rv32i_brcmp dut (.br_op(br_op), .a(a), .b(b), .taken(taken));

    task check;
        input [2:0]  o;
        input [31:0] x, z;
        input        exp;
        begin
            br_op = o; a = x; b = z;
            #1;
            if (taken !== exp) begin
                $display("FAIL brcmp op=%0d a=%08x b=%08x got=%b exp=%b",
                         o, x, z, taken, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0; br_op = 0; a = 0; b = 0;

        //--------------------------------------------------- BEQ / BNE
        check(3'd0, 32'd0,          32'd0,          1'b1);
        check(3'd0, 32'hFFFFFFFF,   32'hFFFFFFFF,   1'b1);
        check(3'd0, 32'hFFFFFFFF,   32'd1,          1'b0);
        check(3'd1, 32'hFFFFFFFF,   32'd1,          1'b1);
        check(3'd1, 32'd5,          32'd5,          1'b0);

        //--------------------------------------------------- BLT / BGE (signed)
        check(3'd4, 32'hFFFFFFFF,   32'd0,          1'b1);    // -1 < 0
        check(3'd4, 32'd0,          32'hFFFFFFFF,   1'b0);
        check(3'd4, 32'h80000000,   32'h7FFFFFFF,   1'b1);    // INT_MIN < INT_MAX
        check(3'd4, 32'h7FFFFFFF,   32'h80000000,   1'b0);
        check(3'd4, 32'd7,          32'd7,          1'b0);
        check(3'd5, 32'd0,          32'hFFFFFFFF,   1'b1);    // 0 >= -1
        check(3'd5, 32'h80000000,   32'h7FFFFFFF,   1'b0);
        check(3'd5, 32'd7,          32'd7,          1'b1);

        //--------------------------------------------------- BLTU / BGEU
        check(3'd6, 32'h7FFFFFFF,   32'h80000000,   1'b1);    // unsigned
        check(3'd6, 32'h80000000,   32'h7FFFFFFF,   1'b0);
        check(3'd6, 32'd1,          32'hFFFFFFFF,   1'b1);
        check(3'd6, 32'd7,          32'd7,          1'b0);
        check(3'd7, 32'h80000000,   32'h7FFFFFFF,   1'b1);
        check(3'd7, 32'hFFFFFFFF,   32'd1,          1'b1);
        check(3'd7, 32'd7,          32'd7,          1'b1);

        //--------------------------------------------------- undefined encodings
        check(3'd2, 32'd0,          32'd0,          1'b0);
        check(3'd3, 32'd0,          32'd0,          1'b0);

        //--------------------------------------------------- randomised cross-check
        for (i = 0; i < 20000; i = i + 1) begin
            ra = {$random};
            rb = {$random};
            br_op = 3'd0; a = ra; b = rb; #1;
            if (taken !== (ra == rb)) begin
                $display("FAIL random beq a=%08x b=%08x", ra, rb); errors = errors + 1;
            end
            br_op = 3'd1; #1;
            if (taken !== (ra != rb)) begin
                $display("FAIL random bne a=%08x b=%08x", ra, rb); errors = errors + 1;
            end
            br_op = 3'd4; #1;
            if (taken !== ($signed(ra) < $signed(rb))) begin
                $display("FAIL random blt a=%08x b=%08x", ra, rb); errors = errors + 1;
            end
            br_op = 3'd5; #1;
            if (taken !== ($signed(ra) >= $signed(rb))) begin
                $display("FAIL random bge a=%08x b=%08x", ra, rb); errors = errors + 1;
            end
            br_op = 3'd6; #1;
            if (taken !== (ra < rb)) begin
                $display("FAIL random bltu a=%08x b=%08x", ra, rb); errors = errors + 1;
            end
            br_op = 3'd7; #1;
            if (taken !== (ra >= rb)) begin
                $display("FAIL random bgeu a=%08x b=%08x", ra, rb); errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("tb_brcmp: PASS (directed + 20000 randomised checks)");
        end else begin
            $display("tb_brcmp: FAIL (%0d errors)", errors);
            $fatal;
        end
        $finish;
    end

endmodule
