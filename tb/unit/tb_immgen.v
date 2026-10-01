// SPDX-License-Identifier: MIT
//============================================================================
// tb_immgen.v -- unit test for rv32i_immgen
//
// All five formats, sign extension boundaries, the forced zero bit of the B
// and J formats, and the zero low half of the U format.  Encodings are built
// with local helper functions so the test states the intended instruction
// rather than a magic hex constant.
//============================================================================
`timescale 1ns/1ps
`include "rv32i_defs.vh"

module tb_immgen;

    reg  [31:0] instr;
    wire [31:0] imm;
    integer     errors;

    rv32i_immgen dut (.instr(instr), .imm(imm));

    function [31:0] enc_i;
        input [11:0] i; input [4:0] rs1; input [2:0] f3; input [4:0] rd; input [6:0] op;
        begin enc_i = {{20{i[11]}}, i, rs1, f3, rd, op}; end
    endfunction

    function [31:0] enc_s;
        input [11:0] i; input [4:0] rs2; input [4:0] rs1; input [2:0] f3; input [6:0] op;
        begin enc_s = {{20{i[11]}}, i[11:5], rs2, rs1, f3, i[4:0], op}; end
    endfunction

    function [31:0] enc_b;
        input [12:0] i; input [4:0] rs2; input [4:0] rs1; input [2:0] f3; input [6:0] op;
        begin
            enc_b = {{19{i[12]}}, i[12], i[10:5], rs2, rs1, f3, i[4:1], i[11], op};
        end
    endfunction

    function [31:0] enc_u;
        input [19:0] i; input [4:0] rd; input [6:0] op;
        begin enc_u = {i, rd, op}; end
    endfunction

    function [31:0] enc_j;
        input [20:0] i; input [4:0] rd; input [6:0] op;
        begin
            enc_j = {{11{i[20]}}, i[20], i[10:1], i[11], i[19:12], rd, op};
        end
    endfunction

    task check;
        input [31:0]  insn;
        input [31:0]  exp;
        input [255:0] what;
        begin
            instr = insn; #1;
            if (imm !== exp) begin
                $display("FAIL %0s: instr=%08x imm=%08x expected %08x",
                         what, insn, imm, exp);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0; instr = 0;

        //--------------------------------------------------- I format
        check(enc_i(12'h000, 5'd1, 3'd0, 5'd2, `OP_OPIMM), 32'h00000000, "I imm 0");
        check(enc_i(12'h7FF, 5'd1, 3'd0, 5'd2, `OP_OPIMM), 32'h000007FF, "I imm +2047");
        check(enc_i(12'h800, 5'd1, 3'd0, 5'd2, `OP_OPIMM), 32'hFFFFF800, "I imm -2048");
        check(enc_i(12'hFFF, 5'd1, 3'd0, 5'd2, `OP_OPIMM), 32'hFFFFFFFF, "I imm -1");
        check(enc_i(12'h123, 5'd3, 3'd2, 5'd4, `OP_OPIMM), 32'h00000123, "I imm positive");
        check(enc_i(12'hFED, 5'd3, 3'd2, 5'd4, `OP_OPIMM), 32'hFFFFFFED, "I imm negative");
        // shifts use the same I format; SRAI sets imm[11:5] = 0100000, and
        // since bit 11 is clear the whole field sign extends to a positive
        // value.  Only imm[4:0] reaches the ALU for shifts either way.
        check(enc_i(12'h41F, 5'd1, 3'd5, 5'd2, `OP_OPIMM), 32'h0000041F, "SRAI field");
        // loads and JALR use it too
        check(enc_i(12'h004, 5'd1, 3'd2, 5'd3, `OP_LOAD), 32'h00000004, "LW offset");
        check(enc_i(12'hFFC, 5'd1, 3'd0, 5'd3, `OP_JALR), 32'hFFFFFFFC, "JALR offset -4");

        //--------------------------------------------------- S format
        check(enc_s(12'h000, 5'd2, 5'd1, 3'd2, `OP_STORE), 32'h00000000, "S imm 0");
        check(enc_s(12'h7FF, 5'd2, 5'd1, 3'd2, `OP_STORE), 32'h000007FF, "S imm +2047");
        check(enc_s(12'h800, 5'd2, 5'd1, 3'd2, `OP_STORE), 32'hFFFFF800, "S imm -2048");
        check(enc_s(12'hFFF, 5'd2, 5'd1, 3'd2, `OP_STORE), 32'hFFFFFFFF, "S imm -1");

        //--------------------------------------------------- B format
        check(enc_b(13'h0000, 5'd2, 5'd1, 3'd0, `OP_BRANCH), 32'h00000000, "B imm 0");
        check(enc_b(13'h0004, 5'd2, 5'd1, 3'd0, `OP_BRANCH), 32'h00000004, "B imm +4");
        check(enc_b(13'h0FFE, 5'd2, 5'd1, 3'd0, `OP_BRANCH), 32'h00000FFE, "B imm +4094");
        check(enc_b(13'h1000, 5'd2, 5'd1, 3'd0, `OP_BRANCH), 32'hFFFFF000, "B imm -4096");
        check(enc_b(13'h1FFE, 5'd2, 5'd1, 3'd0, `OP_BRANCH), 32'hFFFFFFFE, "B imm -2");
        // bit 0 of the immediate field must always decode to zero
        check(enc_b(13'h0005, 5'd2, 5'd1, 3'd0, `OP_BRANCH), 32'h00000004, "B bit0 forced 0");

        //--------------------------------------------------- U format
        check(enc_u(20'h00000, 5'd1, `OP_LUI),   32'h00000000, "LUI 0");
        check(enc_u(20'h12345, 5'd1, `OP_LUI),   32'h12345000, "LUI 0x12345");
        check(enc_u(20'hFFFFF, 5'd1, `OP_LUI),   32'hFFFFF000, "LUI 0xFFFFF");
        check(enc_u(20'h80000, 5'd1, `OP_LUI),   32'h80000000, "LUI 0x80000");
        check(enc_u(20'h12345, 5'd1, `OP_AUIPC), 32'h12345000, "AUIPC 0x12345");

        //--------------------------------------------------- J format
        check(enc_j(21'h000000, 5'd1, `OP_JAL), 32'h00000000, "J imm 0");
        check(enc_j(21'h000004, 5'd1, `OP_JAL), 32'h00000004, "J imm +4");
        check(enc_j(21'h0FFFFE, 5'd1, `OP_JAL), 32'h000FFFFE, "J imm +1048574");
        check(enc_j(21'h100000, 5'd1, `OP_JAL), 32'hFFF00000, "J imm -1048576");
        check(enc_j(21'h1FFFFE, 5'd1, `OP_JAL), 32'hFFFFFFFE, "J imm -2");
        check(enc_j(21'h000005, 5'd1, `OP_JAL), 32'h00000004, "J bit0 forced 0");

        //--------------------------------------------------- non immediate opcodes
        check(enc_i(12'h123, 5'd1, 3'd0, 5'd2, `OP_OP), 32'h00000000, "R type has no imm");

        if (errors == 0) begin
            $display("tb_immgen: PASS");
        end else begin
            $display("tb_immgen: FAIL (%0d errors)", errors);
            $fatal;
        end
        $finish;
    end

endmodule
