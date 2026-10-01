//============================================================================
// tb_decoder.v -- unit test for rv32i_decoder
//
// Every instruction class is checked against a hand written expected control
// word, plus the register usage flags (which decide whether the load-use
// interlock and the forwarding compares apply at all) and a set of illegal
// encodings that must clear the whole control word.
//============================================================================
`timescale 1ns/1ps
`include "rv32i_defs.vh"

module tb_decoder;

    reg  [31:0] instr;
    wire [`CTRL_W-1:0] ctrl;
    wire [4:0]  rs1_addr, rs2_addr, rd_addr;
    wire        uses_rs1, uses_rs2;
    integer     errors;

    rv32i_decoder dut (
        .instr(instr), .ctrl(ctrl), .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
        .rd_addr(rd_addr), .uses_rs1(uses_rs1), .uses_rs2(uses_rs2));

    // ---- encoders (the decoder under test must not be used to build them) --
    function [31:0] enc_r;
        input [6:0] f7; input [4:0] rs2; input [4:0] rs1;
        input [2:0] f3; input [4:0] rd;  input [6:0] op;
        begin enc_r = {f7, rs2, rs1, f3, rd, op}; end
    endfunction

    function [31:0] enc_i;
        input [11:0] i; input [4:0] rs1; input [2:0] f3;
        input [4:0] rd; input [6:0] op;
        begin enc_i = {{20{i[11]}}, i, rs1, f3, rd, op}; end
    endfunction

    function [31:0] enc_s;
        input [11:0] i; input [4:0] rs2; input [4:0] rs1;
        input [2:0] f3; input [6:0] op;
        begin enc_s = {{20{i[11]}}, i[11:5], rs2, rs1, f3, i[4:0], op}; end
    endfunction

    function [31:0] enc_b;
        input [12:0] i; input [4:0] rs2; input [4:0] rs1;
        input [2:0] f3; input [6:0] op;
        begin enc_b = {{19{i[12]}}, i[12], i[10:5], rs2, rs1, f3, i[4:1], i[11], op}; end
    endfunction

    function [31:0] enc_u;
        input [19:0] i; input [4:0] rd; input [6:0] op;
        begin enc_u = {i, rd, op}; end
    endfunction

    function [31:0] enc_j;
        input [20:0] i; input [4:0] rd; input [6:0] op;
        begin enc_j = {{11{i[20]}}, i[20], i[10:1], i[11], i[19:12], rd, op}; end
    endfunction

    // ---- expected control word builder ------------------------------------
    function [`CTRL_W-1:0] mk;
        input [3:0]  aluop; input alua; input alub;
        input [1:0]  wb;    input rfwe; input memre; input memwe;
        input [1:0]  msize; input muns; input br;    input [2:0] brop;
        input        jump;  input jalr; input ecall; input ebreak; input ill;
        reg [`CTRL_W-1:0] c;
        begin
            c = {`CTRL_W{1'b0}};
            c[`CTRL_ALU_OP]   = aluop;
            c[`CTRL_ALU_A]    = alua;
            c[`CTRL_ALU_B]    = alub;
            c[`CTRL_WB_SEL]   = wb;
            c[`CTRL_RF_WE]    = rfwe;
            c[`CTRL_MEM_RE]   = memre;
            c[`CTRL_MEM_WE]   = memwe;
            c[`CTRL_MEM_SIZE] = msize;
            c[`CTRL_MEM_UNS]  = muns;
            c[`CTRL_BRANCH]   = br;
            c[`CTRL_BR_OP]    = brop;
            c[`CTRL_JUMP]     = jump;
            c[`CTRL_JALR]     = jalr;
            c[`CTRL_ECALL]    = ecall;
            c[`CTRL_EBREAK]   = ebreak;
            c[`CTRL_ILLEGAL]  = ill;
            mk = c;
        end
    endfunction

    // The decoder contract is raw field extraction (docs/05 section 2.4):
    // rs1_addr/rs2_addr/rd_addr are always instr[19:15], instr[24:20] and
    // instr[11:7], even for instructions where those bits are immediate bits
    // and the field is not a register number at all.  What makes them
    // meaningful is uses_rs1/uses_rs2 and the register write enable, which is
    // exactly why the test checks the extracted fields against the instruction
    // word and checks the usage flags explicitly.
    task chk;
        input [31:0] insn;
        input [`CTRL_W-1:0] exp;
        input        e_u1, e_u2;
        input [255:0] what;
        begin
            instr = insn; #1;
            if ((ctrl !== exp) || (uses_rs1 !== e_u1) || (uses_rs2 !== e_u2) ||
                (rs1_addr !== insn[19:15]) || (rs2_addr !== insn[24:20]) ||
                (rd_addr !== insn[11:7])) begin
                $display("FAIL %0s: instr=%08x", what, insn);
                $display("      ctrl got=%b exp=%b rs1=%0d/%0d rs2=%0d/%0d rd=%0d/%0d use=%b%b/%b%b",
                         ctrl, exp, rs1_addr, insn[19:15], rs2_addr, insn[24:20],
                         rd_addr, insn[11:7], uses_rs1, uses_rs2, e_u1, e_u2);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0; instr = 0;

        //--------------------------------------------------- R type
        chk(enc_r(7'h00, 5'd2, 5'd1, 3'd0, 5'd3, `OP_OP),
            mk(`ALU_ADD, 0,0, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "add");
        chk(enc_r(7'h20, 5'd2, 5'd1, 3'd0, 5'd3, `OP_OP),
            mk(`ALU_SUB, 0,0, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "sub");
        chk(enc_r(7'h00, 5'd2, 5'd1, 3'd1, 5'd3, `OP_OP),
            mk(`ALU_SLL, 0,0, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "sll");
        chk(enc_r(7'h00, 5'd2, 5'd1, 3'd2, 5'd3, `OP_OP),
            mk(`ALU_SLT, 0,0, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "slt");
        chk(enc_r(7'h00, 5'd2, 5'd1, 3'd3, 5'd3, `OP_OP),
            mk(`ALU_SLTU, 0,0, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "sltu");
        chk(enc_r(7'h00, 5'd2, 5'd1, 3'd4, 5'd3, `OP_OP),
            mk(`ALU_XOR, 0,0, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "xor");
        chk(enc_r(7'h00, 5'd2, 5'd1, 3'd5, 5'd3, `OP_OP),
            mk(`ALU_SRL, 0,0, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "srl");
        chk(enc_r(7'h20, 5'd2, 5'd1, 3'd5, 5'd3, `OP_OP),
            mk(`ALU_SRA, 0,0, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "sra");
        chk(enc_r(7'h00, 5'd2, 5'd1, 3'd6, 5'd3, `OP_OP),
            mk(`ALU_OR, 0,0, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "or");
        chk(enc_r(7'h00, 5'd2, 5'd1, 3'd7, 5'd3, `OP_OP),
            mk(`ALU_AND, 0,0, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "and");

        //--------------------------------------------------- I type ALU / shifts
        chk(enc_i(12'h123, 5'd1, 3'd0, 5'd3, `OP_OPIMM),
            mk(`ALU_ADD, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "addi");
        chk(enc_i(12'h123, 5'd1, 3'd2, 5'd3, `OP_OPIMM),
            mk(`ALU_SLT, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "slti");
        chk(enc_i(12'h123, 5'd1, 3'd3, 5'd3, `OP_OPIMM),
            mk(`ALU_SLTU, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "sltiu");
        chk(enc_i(12'h123, 5'd1, 3'd4, 5'd3, `OP_OPIMM),
            mk(`ALU_XOR, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "xori");
        chk(enc_i(12'h123, 5'd1, 3'd6, 5'd3, `OP_OPIMM),
            mk(`ALU_OR, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "ori");
        chk(enc_i(12'h123, 5'd1, 3'd7, 5'd3, `OP_OPIMM),
            mk(`ALU_AND, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "andi");
        chk(enc_i(12'h005, 5'd1, 3'd1, 5'd3, `OP_OPIMM),
            mk(`ALU_SLL, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "slli");
        chk(enc_i(12'h005, 5'd1, 3'd5, 5'd3, `OP_OPIMM),
            mk(`ALU_SRL, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "srli");
        chk(enc_i(12'h405, 5'd1, 3'd5, 5'd3, `OP_OPIMM),
            mk(`ALU_SRA, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "srai");

        //--------------------------------------------------- loads
        chk(enc_i(12'h004, 5'd1, 3'd0, 5'd3, `OP_LOAD),
            mk(`ALU_ADD, 0,1, `WB_MEM,1,1,0, `MSZ_B,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "lb");
        chk(enc_i(12'h004, 5'd1, 3'd1, 5'd3, `OP_LOAD),
            mk(`ALU_ADD, 0,1, `WB_MEM,1,1,0, `MSZ_H,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "lh");
        chk(enc_i(12'h004, 5'd1, 3'd2, 5'd3, `OP_LOAD),
            mk(`ALU_ADD, 0,1, `WB_MEM,1,1,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "lw");
        chk(enc_i(12'h004, 5'd1, 3'd4, 5'd3, `OP_LOAD),
            mk(`ALU_ADD, 0,1, `WB_MEM,1,1,0, `MSZ_B,1, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "lbu");
        chk(enc_i(12'h004, 5'd1, 3'd5, 5'd3, `OP_LOAD),
            mk(`ALU_ADD, 0,1, `WB_MEM,1,1,0, `MSZ_H,1, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "lhu");

        //--------------------------------------------------- stores
        chk(enc_s(12'h004, 5'd2, 5'd1, 3'd0, `OP_STORE),
            mk(`ALU_ADD, 0,1, `WB_ALU,0,0,1, `MSZ_B,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "sb");
        chk(enc_s(12'h004, 5'd2, 5'd1, 3'd1, `OP_STORE),
            mk(`ALU_ADD, 0,1, `WB_ALU,0,0,1, `MSZ_H,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "sh");
        chk(enc_s(12'h004, 5'd2, 5'd1, 3'd2, `OP_STORE),
            mk(`ALU_ADD, 0,1, `WB_ALU,0,0,1, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b1, "sw");

        //--------------------------------------------------- branches
        chk(enc_b(13'h8, 5'd2, 5'd1, 3'd0, `OP_BRANCH),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 1,3'd0, 0,0, 0,0,0),
            1'b1, 1'b1, "beq");
        chk(enc_b(13'h8, 5'd2, 5'd1, 3'd1, `OP_BRANCH),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 1,3'd1, 0,0, 0,0,0),
            1'b1, 1'b1, "bne");
        chk(enc_b(13'h8, 5'd2, 5'd1, 3'd4, `OP_BRANCH),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 1,3'd4, 0,0, 0,0,0),
            1'b1, 1'b1, "blt");
        chk(enc_b(13'h8, 5'd2, 5'd1, 3'd5, `OP_BRANCH),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 1,3'd5, 0,0, 0,0,0),
            1'b1, 1'b1, "bge");
        chk(enc_b(13'h8, 5'd2, 5'd1, 3'd6, `OP_BRANCH),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 1,3'd6, 0,0, 0,0,0),
            1'b1, 1'b1, "bltu");
        chk(enc_b(13'h8, 5'd2, 5'd1, 3'd7, `OP_BRANCH),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 1,3'd7, 0,0, 0,0,0),
            1'b1, 1'b1, "bgeu");

        //--------------------------------------------------- upper immediate
        chk(enc_u(20'h12345, 5'd3, `OP_LUI),
            mk(`ALU_PASSB, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b0, 1'b0, "lui");
        chk(enc_u(20'h12345, 5'd3, `OP_AUIPC),
            mk(`ALU_ADD, 1,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b0, 1'b0, "auipc");

        //--------------------------------------------------- jumps
        chk(enc_j(21'h8, 5'd3, `OP_JAL),
            mk(`ALU_ADD, 0,0, `WB_PC4,1,0,0, `MSZ_W,0, 0,0, 1,0, 0,0,0),
            1'b0, 1'b0, "jal");
        chk(enc_i(12'h0, 5'd1, 3'd0, 5'd3, `OP_JALR),
            mk(`ALU_ADD, 0,1, `WB_PC4,1,0,0, `MSZ_W,0, 0,0, 1,1, 0,0,0),
            1'b1, 1'b0, "jalr");

        //--------------------------------------------------- system
        chk(32'h00000073,
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 1,0,0),
            1'b0, 1'b0, "ecall");
        chk(32'h00100073,
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,1,0),
            1'b0, 1'b0, "ebreak");
        chk(32'h0000000F,
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b0, 1'b0, "fence -> no-op");
        chk(32'h0000100F,
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b0, 1'b0, "fence.i -> no-op");

        //--------------------------------------------------- illegal encodings
        chk(32'h00000000,
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "all zero");
        chk(enc_i(12'hC00, 5'd0, 3'd2, 5'd1, `OP_SYSTEM),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "csrrs (Zicsr not implemented)");
        chk(enc_i(12'h004, 5'd1, 3'd3, 5'd3, `OP_LOAD),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "load funct3=3");
        chk(enc_s(12'h004, 5'd2, 5'd1, 3'd3, `OP_STORE),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "store funct3=3");
        chk(enc_b(13'h8, 5'd2, 5'd1, 3'd2, `OP_BRANCH),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "branch funct3=2");
        chk(enc_i(12'h0, 5'd1, 3'd1, 5'd3, `OP_JALR),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "jalr funct3=1");
        chk(enc_r(7'h40, 5'd2, 5'd1, 3'd0, 5'd3, `OP_OP),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "op funct7=0x40");
        chk(enc_r(7'h20, 5'd2, 5'd1, 3'd2, 5'd3, `OP_OP),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "op funct7=0x20 with f3=2");
        // ANDI/XORI/ORI/ADDI take the whole 12 bit field as an immediate, so
        // bit 11 set is legal there (only the shifts have a funct7 split)
        chk(enc_i(12'h405, 5'd1, 3'd7, 5'd3, `OP_OPIMM),
            mk(`ALU_AND, 0,1, `WB_ALU,1,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,0),
            1'b1, 1'b0, "andi with bit 11 set");
        chk(enc_i(12'h405, 5'd1, 3'd1, 5'd3, `OP_OPIMM),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "slli with funct7 != 0");
        chk(enc_i(12'h205, 5'd1, 3'd5, 5'd3, `OP_OPIMM),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "srli with imm[11:5]=0010000");
        chk(enc_i(12'h605, 5'd1, 3'd5, 5'd3, `OP_OPIMM),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "srli with imm[11:5]=0110000");
        chk(enc_i(12'h205, 5'd1, 3'd1, 5'd3, `OP_OPIMM),
            mk(`ALU_ADD, 0,0, `WB_ALU,0,0,0, `MSZ_W,0, 0,0, 0,0, 0,0,1),
            1'b0, 1'b0, "slli with imm[11:5]=0010000");

        if (errors == 0) begin
            $display("tb_decoder: PASS");
        end else begin
            $display("tb_decoder: FAIL (%0d errors)", errors);
            $fatal;
        end
        $finish;
    end

endmodule
