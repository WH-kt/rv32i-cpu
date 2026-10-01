// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
//============================================================================
// rv32i_alu.v -- 32 bit combinational ALU
//
// Pure combinational, no state.  All operations are defined on 32 bit values;
// SLL/SRL/SRA use b[4:0] as the shift amount (RV32I shift semantics).
//============================================================================
`include "rv32i_defs.vh"

module rv32i_alu (
    input  wire [3:0]  alu_op,   // `ALU_*
    input  wire [31:0] a,        // operand A (already forwarded)
    input  wire [31:0] b,        // operand B (already forwarded)
    output reg  [31:0] y
);

    wire [4:0] shamt = b[4:0];

    always @(*) begin
        case (alu_op)
            `ALU_ADD:   y = a + b;
            `ALU_SUB:   y = a - b;
            `ALU_SLL:   y = a << shamt;
            `ALU_SLT:   y = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            `ALU_SLTU:  y = (a < b) ? 32'd1 : 32'd0;
            `ALU_XOR:   y = a ^ b;
            `ALU_SRL:   y = a >> shamt;
            `ALU_SRA:   y = $signed(a) >>> shamt;
            `ALU_OR:    y = a | b;
            `ALU_AND:   y = a & b;
            `ALU_PASSB: y = b;
            default:    y = 32'd0;
        endcase
    end

endmodule
