// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
//============================================================================
// rv32i_brcmp.v -- branch condition comparator
//
// Shares the forwarded operands with the ALU.  br_op is the raw funct3 of the
// branch instruction; funct3 values 2 and 3 are not branches and yield 0.
//   br_op 0: a == b      1: a != b
//   br_op 4: a <  b (signed)      5: a >= b (signed)
//   br_op 6: a <  b (unsigned)    7: a >= b (unsigned)
//============================================================================
`include "rv32i_defs.vh"

module rv32i_brcmp (
    input  wire [2:0]  br_op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg         taken
);

    always @(*) begin
        case (br_op)
            3'd0:    taken = (a == b);
            3'd1:    taken = (a != b);
            3'd4:    taken = ($signed(a) <  $signed(b));
            3'd5:    taken = ($signed(a) >= $signed(b));
            3'd6:    taken = (a <  b);
            3'd7:    taken = (a >= b);
            default: taken = 1'b0;
        endcase
    end

endmodule
