// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
//============================================================================
// rv32i_immgen.v -- immediate generator (I / S / B / U / J formats)
//
// The format is selected by the opcode, so the unit is self contained and can
// be verified on its own.  All outputs are sign extended to 32 bit except the
// U format, whose low 12 bits are zero by definition.  B and J immediates have
// bit 0 hardwired to zero.
//============================================================================
`include "rv32i_defs.vh"

module rv32i_immgen (
    input  wire [31:0] instr,
    output reg  [31:0] imm
);

    wire [6:0] opcode = instr[6:0];

    always @(*) begin
        case (opcode)
            // I type: ALU immediate, shifts, loads, JALR
            `OP_OPIMM,
            `OP_LOAD,
            `OP_JALR:   imm = {{20{instr[31]}}, instr[31:20]};

            // S type: stores
            `OP_STORE:  imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};

            // B type: conditional branches
            `OP_BRANCH: imm = {{19{instr[31]}}, instr[31], instr[7],
                               instr[30:25], instr[11:8], 1'b0};

            // U type: LUI / AUIPC
            `OP_LUI,
            `OP_AUIPC:  imm = {instr[31:12], 12'b0};

            // J type: JAL
            `OP_JAL:    imm = {{11{instr[31]}}, instr[31], instr[19:12],
                               instr[20], instr[30:21], 1'b0};

            default:    imm = 32'd0;
        endcase
    end

endmodule
