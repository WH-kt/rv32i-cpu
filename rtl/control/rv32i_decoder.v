`timescale 1ns/1ps
//============================================================================
// rv32i_decoder.v -- main control decoder
//
// Purely combinational.  Produces the 24 bit packed control word (see
// docs/03-microarchitecture.md section 3) plus the register indices and the
// "really reads this register" flags used by the hazard unit.
//
// Illegal encodings set CTRL_ILLEGAL and clear every other control bit, so an
// illegal instruction can never write a register or memory and can never
// trigger a second (misalignment) trap.  The trap itself is raised in EX.
//
// RV32I only: CSR instructions (SYSTEM with funct3 != 0) are illegal here
// because Zicsr is not part of the base ISA.
//============================================================================
`include "rv32i_defs.vh"

module rv32i_decoder (
    input  wire [31:0] instr,
    output reg  [`CTRL_W-1:0] ctrl,
    output wire [4:0]  rs1_addr,
    output wire [4:0]  rs2_addr,
    output wire [4:0]  rd_addr,
    output wire        uses_rs1,    // instruction really consumes rs1
    output wire        uses_rs2
);

    wire [6:0] opcode = instr[6:0];
    wire [2:0] f3     = instr[14:12];
    wire [6:0] f7     = instr[31:25];
    wire       f7_bit5 = instr[30];        // SUB / SRA selector

    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign rd_addr  = instr[11:7];

    // ---- decoded control fields -----------------------------------------
    reg [3:0] alu_op;
    reg       alu_a_pc;      // CTRL_ALU_A
    reg       alu_b_imm;     // CTRL_ALU_B
    reg [1:0] wb_sel;
    reg       rf_we;
    reg       mem_re;
    reg       mem_we;
    reg [1:0] mem_size;
    reg       mem_uns;
    reg       is_branch;
    reg [2:0] br_op;
    reg       is_jump;
    reg       is_jalr;
    reg       is_ecall;
    reg       is_ebreak;
    reg       illegal;
    reg       u_rs1;
    reg       u_rs2;

    always @(*) begin
        // ---- defaults: a bubble -----------------------------------------
        alu_op    = `ALU_ADD;
        alu_a_pc  = 1'b0;
        alu_b_imm = 1'b0;
        wb_sel    = `WB_ALU;
        rf_we     = 1'b0;
        mem_re    = 1'b0;
        mem_we    = 1'b0;
        mem_size  = `MSZ_W;
        mem_uns   = 1'b0;
        is_branch = 1'b0;
        br_op     = 3'd0;
        is_jump   = 1'b0;
        is_jalr   = 1'b0;
        is_ecall  = 1'b0;
        is_ebreak = 1'b0;
        illegal   = 1'b0;
        u_rs1     = 1'b0;
        u_rs2     = 1'b0;

        case (opcode)
            // ---- R type ------------------------------------------------
            `OP_OP: begin
                rf_we     = 1'b1;
                wb_sel    = `WB_ALU;
                u_rs1     = 1'b1;
                u_rs2     = 1'b1;
                case (f3)
                    3'd0:    alu_op = f7_bit5 ? `ALU_SUB  : `ALU_ADD;
                    3'd1:    alu_op = `ALU_SLL;
                    3'd2:    alu_op = `ALU_SLT;
                    3'd3:    alu_op = `ALU_SLTU;
                    3'd4:    alu_op = `ALU_XOR;
                    3'd5:    alu_op = f7_bit5 ? `ALU_SRA  : `ALU_SRL;
                    3'd6:    alu_op = `ALU_OR;
                    3'd7:    alu_op = `ALU_AND;
                    default: alu_op = `ALU_ADD;
                endcase
                // funct7 must be 0000000 or 0100000, and the 0100000 form
                // exists only for SUB (f3=0) and SRA (f3=5).
                if ((f7 != 7'b0000000) && (f7 != 7'b0100000)) illegal = 1'b1;
                if (f7_bit5 && (f3 != 3'd0) && (f3 != 3'd5))   illegal = 1'b1;
            end

            // ---- I type ALU / shifts ------------------------------------
            `OP_OPIMM: begin
                rf_we     = 1'b1;
                wb_sel    = `WB_ALU;
                alu_b_imm = 1'b1;
                u_rs1     = 1'b1;
                case (f3)
                    3'd0:    alu_op = `ALU_ADD;
                    3'd1:    begin alu_op = `ALU_SLL;
                                   if (f7 != 7'b0000000) illegal = 1'b1; end
                    3'd2:    alu_op = `ALU_SLT;
                    3'd3:    alu_op = `ALU_SLTU;
                    3'd4:    alu_op = `ALU_XOR;
                    3'd5:    begin alu_op = f7_bit5 ? `ALU_SRA : `ALU_SRL;
                                   if ((f7 != 7'b0000000) && (f7 != 7'b0100000))
                                       illegal = 1'b1; end
                    3'd6:    alu_op = `ALU_OR;
                    3'd7:    alu_op = `ALU_AND;
                    default: alu_op = `ALU_ADD;
                endcase
            end

            // ---- loads ---------------------------------------------------
            `OP_LOAD: begin
                rf_we     = 1'b1;
                wb_sel    = `WB_MEM;
                mem_re    = 1'b1;
                alu_b_imm = 1'b1;
                u_rs1     = 1'b1;
                case (f3)
                    3'd0:    begin mem_size = `MSZ_B; mem_uns = 1'b0; end
                    3'd1:    begin mem_size = `MSZ_H; mem_uns = 1'b0; end
                    3'd2:    begin mem_size = `MSZ_W; mem_uns = 1'b0; end
                    3'd4:    begin mem_size = `MSZ_B; mem_uns = 1'b1; end
                    3'd5:    begin mem_size = `MSZ_H; mem_uns = 1'b1; end
                    default: illegal = 1'b1;
                endcase
            end

            // ---- stores --------------------------------------------------
            `OP_STORE: begin
                mem_we    = 1'b1;
                alu_b_imm = 1'b1;
                u_rs1     = 1'b1;
                u_rs2     = 1'b1;       // store data: needed for load->store stalls
                case (f3)
                    3'd0:    mem_size = `MSZ_B;
                    3'd1:    mem_size = `MSZ_H;
                    3'd2:    mem_size = `MSZ_W;
                    default: illegal = 1'b1;
                endcase
            end

            // ---- branches ------------------------------------------------
            `OP_BRANCH: begin
                is_branch = 1'b1;
                br_op     = f3;
                u_rs1     = 1'b1;
                u_rs2     = 1'b1;
                if ((f3 == 3'd2) || (f3 == 3'd3)) illegal = 1'b1;
            end

            // ---- jumps ---------------------------------------------------
            `OP_JAL: begin
                is_jump = 1'b1;
                rf_we   = 1'b1;
                wb_sel  = `WB_PC4;
                // no register operands: rs1/rs2 fields are immediate bits
            end

            `OP_JALR: begin
                is_jump   = 1'b1;
                is_jalr   = 1'b1;
                rf_we     = 1'b1;
                wb_sel    = `WB_PC4;
                alu_b_imm = 1'b1;
                u_rs1     = 1'b1;
                if (f3 != 3'd0) illegal = 1'b1;
            end

            // ---- upper immediate ----------------------------------------
            `OP_LUI: begin
                rf_we     = 1'b1;
                wb_sel    = `WB_ALU;
                alu_op    = `ALU_PASSB;
                alu_b_imm = 1'b1;
            end

            `OP_AUIPC: begin
                rf_we     = 1'b1;
                wb_sel    = `WB_ALU;
                alu_op    = `ALU_ADD;
                alu_a_pc  = 1'b1;
                alu_b_imm = 1'b1;
            end

            // ---- memory ordering ----------------------------------------
            // Single core, no cache, strictly in-order: FENCE has no
            // observable effect, so it decodes to an all-zero control word
            // (a no-op) while still occupying and retiring from the pipeline.
            // FENCE.I belongs to Zifencei and is accepted here for the same
            // reason: there is no instruction cache to synchronise.
            `OP_FENCE: ;

            // ---- system --------------------------------------------------
            `OP_SYSTEM: begin
                if (instr == `INSN_ECALL)       is_ecall  = 1'b1;
                else if (instr == `INSN_EBREAK) is_ebreak = 1'b1;
                else                            illegal   = 1'b1;   // incl. CSR
            end

            default: illegal = 1'b1;
        endcase

        // ---- illegal overrides everything -------------------------------
        if (illegal) begin
            alu_op    = `ALU_ADD;
            alu_a_pc  = 1'b0;
            alu_b_imm = 1'b0;
            wb_sel    = `WB_ALU;
            rf_we     = 1'b0;
            mem_re    = 1'b0;
            mem_we    = 1'b0;
            mem_size  = `MSZ_W;
            mem_uns   = 1'b0;
            is_branch = 1'b0;
            br_op     = 3'd0;
            is_jump   = 1'b0;
            is_jalr   = 1'b0;
            is_ecall  = 1'b0;
            is_ebreak = 1'b0;
            u_rs1     = 1'b0;
            u_rs2     = 1'b0;
        end
    end

    // ---- packed control word --------------------------------------------
    always @(*) begin
        ctrl = {`CTRL_W{1'b0}};
        ctrl[`CTRL_ALU_OP]   = alu_op;
        ctrl[`CTRL_ALU_A]    = alu_a_pc;
        ctrl[`CTRL_ALU_B]    = alu_b_imm;
        ctrl[`CTRL_WB_SEL]   = wb_sel;
        ctrl[`CTRL_RF_WE]    = rf_we;
        ctrl[`CTRL_MEM_RE]   = mem_re;
        ctrl[`CTRL_MEM_WE]   = mem_we;
        ctrl[`CTRL_MEM_SIZE] = mem_size;
        ctrl[`CTRL_MEM_UNS]  = mem_uns;
        ctrl[`CTRL_BRANCH]   = is_branch;
        ctrl[`CTRL_BR_OP]    = br_op;
        ctrl[`CTRL_JUMP]     = is_jump;
        ctrl[`CTRL_JALR]     = is_jalr;
        ctrl[`CTRL_ECALL]    = is_ecall;
        ctrl[`CTRL_EBREAK]   = is_ebreak;
        ctrl[`CTRL_ILLEGAL]  = illegal;
    end

    assign uses_rs1 = u_rs1;
    assign uses_rs2 = u_rs2;

endmodule
