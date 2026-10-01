// SPDX-License-Identifier: MIT
//============================================================================
// tb_alu.v -- unit test for rv32i_alu
//
// Two independent checks:
//   1. directed vectors with hand computed expected values, including the
//      signed/unsigned boundary patterns;
//   2. randomised property checks that use a *different* formulation than the
//      ALU itself (e.g. SUB is checked through y + b == a), so a copy of the
//      implementation is not being compared with itself.
//
// Prints PASS/FAIL and calls $fatal on failure, so `vvp` exits non-zero.
//============================================================================
`timescale 1ns/1ps
`include "rv32i_defs.vh"

module tb_alu;

    reg  [3:0]  op;
    reg  [31:0] a, b;
    wire [31:0] y;

    integer errors;
    integer i;
    reg [31:0] ra, rb;

    rv32i_alu dut (.alu_op(op), .a(a), .b(b), .y(y));

    task check;
        input [3:0]  o;
        input [31:0] x;
        input [31:0] z;
        input [31:0] exp;
        begin
            op = o; a = x; b = z;
            #1;
            if (y !== exp) begin
                $display("FAIL alu op=%0d a=%08x b=%08x got=%08x exp=%08x",
                         o, x, z, y, exp);
                errors = errors + 1;
            end
        end
    endtask

    task prop_fail;
        input [255:0] what;
        input [3:0]   o;
        input [31:0]  x;
        input [31:0]  z;
        begin
            $display("FAIL property %0s op=%0d a=%08x b=%08x y=%08x",
                     what, o, x, z, y);
            errors = errors + 1;
        end
    endtask

    initial begin
        errors = 0;
        op = 0; a = 0; b = 0;

        //--------------------------------------------------- ADD
        check(`ALU_ADD, 32'd0,          32'd0,          32'd0);
        check(`ALU_ADD, 32'd1,          32'd1,          32'd2);
        check(`ALU_ADD, 32'hFFFFFFFF,   32'd1,          32'd0);            // wrap
        check(`ALU_ADD, 32'h7FFFFFFF,   32'd1,          32'h80000000);     // overflow
        check(`ALU_ADD, 32'h80000000,   32'h80000000,   32'd0);
        check(`ALU_ADD, 32'h12345678,   32'h87654321,   32'h99999999);

        //--------------------------------------------------- SUB
        check(`ALU_SUB, 32'd5,          32'd7,          32'hFFFFFFFE);     // -2
        check(`ALU_SUB, 32'd0,          32'd1,          32'hFFFFFFFF);
        check(`ALU_SUB, 32'h80000000,   32'd1,          32'h7FFFFFFF);
        check(`ALU_SUB, 32'h7FFFFFFF,   32'hFFFFFFFF,   32'h80000000);     // +1 overflow
        check(`ALU_SUB, 32'hAAAAAAAA,   32'hAAAAAAAA,   32'd0);

        //--------------------------------------------------- SLL / SRL / SRA
        check(`ALU_SLL, 32'd1,          32'd0,          32'd1);
        check(`ALU_SLL, 32'd1,          32'd31,         32'h80000000);
        check(`ALU_SLL, 32'h12345678,   32'd4,          32'h23456780);
        check(`ALU_SLL, 32'h12345678,   32'd32,         32'h12345678);     // b[4:0] == 0
        check(`ALU_SLL, 32'h12345678,   32'd33,         32'h2468ACF0);     // b[4:0] == 1
        check(`ALU_SLL, 32'hFFFFFFFF,   32'd63,         32'h80000000);     // b[4:0] == 31

        check(`ALU_SRL, 32'h80000000,   32'd31,         32'd1);
        check(`ALU_SRL, 32'hFFFFFFFF,   32'd4,          32'h0FFFFFFF);
        check(`ALU_SRL, 32'h80000000,   32'd0,          32'h80000000);

        check(`ALU_SRA, 32'h80000000,   32'd31,         32'hFFFFFFFF);
        check(`ALU_SRA, 32'h80000000,   32'd4,          32'hF8000000);
        check(`ALU_SRA, 32'h7FFFFFFF,   32'd4,          32'h07FFFFFF);
        check(`ALU_SRA, 32'hFFFFFFFF,   32'd31,         32'hFFFFFFFF);
        check(`ALU_SRA, 32'h00000080,   32'd0,          32'h00000080);

        //--------------------------------------------------- SLT / SLTU
        check(`ALU_SLT,  32'hFFFFFFFF,  32'd1,          32'd1);            // -1 < 1
        check(`ALU_SLT,  32'd1,         32'hFFFFFFFF,   32'd0);
        check(`ALU_SLT,  32'h80000000,  32'h7FFFFFFF,   32'd1);            // INT_MIN < INT_MAX
        check(`ALU_SLT,  32'h7FFFFFFF,  32'h80000000,   32'd0);
        check(`ALU_SLT,  32'd7,         32'd7,          32'd0);
        check(`ALU_SLTU, 32'hFFFFFFFF,  32'd1,          32'd0);            // unsigned
        check(`ALU_SLTU, 32'd1,         32'hFFFFFFFF,   32'd1);
        check(`ALU_SLTU, 32'h80000000,  32'h7FFFFFFF,   32'd0);
        check(`ALU_SLTU, 32'h7FFFFFFF,  32'h80000000,   32'd1);
        check(`ALU_SLTU, 32'd0,         32'd0,          32'd0);

        //--------------------------------------------------- XOR / OR / AND
        check(`ALU_XOR, 32'hF0F0F0F0, 32'h0FF00FF0, 32'hFF00FF00);
        check(`ALU_XOR, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'd0);
        check(`ALU_OR,  32'hF0F0F0F0, 32'h0FF00FF0, 32'hFFF0FFF0);
        check(`ALU_OR,  32'd0,        32'd0,        32'd0);
        check(`ALU_AND, 32'hF0F0F0F0, 32'h0FF00FF0, 32'h00F000F0);
        check(`ALU_AND, 32'hFFFFFFFF, 32'h12345678, 32'h12345678);
        check(`ALU_AND, 32'd0,        32'hFFFFFFFF, 32'd0);

        //--------------------------------------------------- PASS_B (LUI)
        check(`ALU_PASSB, 32'hDEADBEEF, 32'h12345000, 32'h12345000);
        check(`ALU_PASSB, 32'h0,        32'hFFFFF000, 32'hFFFFF000);

        //--------------------------------------------------- randomised properties
        for (i = 0; i < 20000; i = i + 1) begin
            ra = {$random};
            rb = {$random};

            op = `ALU_ADD; a = ra; b = rb; #1;
            if (y !== (ra + rb)) prop_fail("add", op, ra, rb);

            op = `ALU_SUB; a = ra; b = rb; #1;
            if ((y + rb) !== ra) prop_fail("sub(y+b==a)", op, ra, rb);

            op = `ALU_AND; a = ra; b = rb; #1;
            if (((y | ra) !== ra) || ((y | rb) !== rb)) prop_fail("and", op, ra, rb);

            op = `ALU_OR; a = ra; b = rb; #1;
            if (((y & ra) !== ra) || ((y & rb) !== rb)) prop_fail("or", op, ra, rb);

            op = `ALU_XOR; a = ra; b = rb; #1;
            if (y !== ((ra | rb) & ~(ra & rb))) prop_fail("xor", op, ra, rb);

            op = `ALU_SLL; a = ra; b = rb; #1;
            // shifting by n is multiplying by 2^n for the low bits that survive
            if ((rb[4:0] == 5'd0) && (y !== ra)) prop_fail("sll0", op, ra, rb);
            if ((rb[4:0] == 5'd1) && (y !== ((ra << 1)))) prop_fail("sll1", op, ra, rb);

            op = `ALU_SRL; a = ra; b = rb; #1;
            if ((rb[4:0] == 5'd0) && (y !== ra)) prop_fail("srl0", op, ra, rb);

            op = `ALU_SRA; a = ra; b = rb; #1;
            // arithmetic shift never flips the sign, and shifting a non negative
            // value must equal the logical shift
            if ((ra[31] == 1'b0) && (y !== (ra >> rb[4:0]))) prop_fail("sra==srl", op, ra, rb);
            if ((rb[4:0] == 5'd0) && (y !== ra)) prop_fail("sra0", op, ra, rb);

            op = `ALU_SLT; a = ra; b = rb; #1;
            if ((ra == rb) && (y !== 32'd0)) prop_fail("slt_eq", op, ra, rb);
            if ((ra[31] == 1'b0) && (rb[31] == 1'b0) && (ra < rb) && (y !== 32'd1))
                prop_fail("slt_pos", op, ra, rb);

            op = `ALU_SLTU; a = ra; b = rb; #1;
            if ((ra == rb) && (y !== 32'd0)) prop_fail("sltu_eq", op, ra, rb);
            if ((ra < rb) && (y !== 32'd1)) prop_fail("sltu", op, ra, rb);
        end

        if (errors == 0) begin
            $display("tb_alu: PASS (directed + 20000 randomised property checks)");
        end else begin
            $display("tb_alu: FAIL (%0d errors)", errors);
            $fatal;
        end
        $finish;
    end

endmodule
