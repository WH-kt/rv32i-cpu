//============================================================================
// tb_hazard.v -- unit test for rv32i_hazard
//
// The forwarding selects and the load-use interlock are the whole of the data
// hazard logic, and their input space is small enough to pin down.  Directed
// cases cover every condition in the decision (valid, write enable, load
// guard, x0 guard, register match, uses flags, priority); a randomised sweep
// cross-checks against a reference model written independently in this file.
//============================================================================
`timescale 1ns/1ps
`include "rv32i_defs.vh"

module tb_hazard;

    reg        id_ex_valid, id_ex_mem_re;
    reg  [4:0] id_ex_rd_addr, id_ex_rs1_addr, id_ex_rs2_addr;
    reg        ex_mem_valid, ex_mem_rf_we, ex_mem_mem_re;
    reg  [4:0] ex_mem_rd_addr;
    reg        mem_wb_valid, mem_wb_rf_we;
    reg  [4:0] mem_wb_rd_addr;
    reg        if_id_valid, if_id_uses_rs1, if_id_uses_rs2;
    reg  [4:0] if_id_rs1_addr, if_id_rs2_addr;
    wire [1:0] fwd_a_sel, fwd_b_sel;
    wire       stall;

    integer errors;
    integer i;
    reg [31:0] rnd;

    rv32i_hazard dut (
        .id_ex_valid(id_ex_valid), .id_ex_mem_re(id_ex_mem_re),
        .id_ex_rd_addr(id_ex_rd_addr), .id_ex_rs1_addr(id_ex_rs1_addr),
        .id_ex_rs2_addr(id_ex_rs2_addr),
        .ex_mem_valid(ex_mem_valid), .ex_mem_rf_we(ex_mem_rf_we),
        .ex_mem_mem_re(ex_mem_mem_re), .ex_mem_rd_addr(ex_mem_rd_addr),
        .mem_wb_valid(mem_wb_valid), .mem_wb_rf_we(mem_wb_rf_we),
        .mem_wb_rd_addr(mem_wb_rd_addr),
        .if_id_valid(if_id_valid), .if_id_uses_rs1(if_id_uses_rs1),
        .if_id_uses_rs2(if_id_uses_rs2), .if_id_rs1_addr(if_id_rs1_addr),
        .if_id_rs2_addr(if_id_rs2_addr),
        .fwd_a_sel(fwd_a_sel), .fwd_b_sel(fwd_b_sel), .stall(stall));

    // ---- reference model, written from the specification -------------------
    function [1:0] ref_fwd;
        input        p_valid, p_we, p_load;
        input [4:0]  p_rd, c_rs;
        begin
            if (p_valid && p_we && !p_load && (p_rd != 5'd0) && (p_rd == c_rs))
                ref_fwd = `FWD_MEM;
            else
                ref_fwd = 2'bxx;      // caller decides on the MEM/WB term
        end
    endfunction

    task clear_all;
        begin
            id_ex_valid = 0; id_ex_mem_re = 0; id_ex_rd_addr = 0;
            id_ex_rs1_addr = 0; id_ex_rs2_addr = 0;
            ex_mem_valid = 0; ex_mem_rf_we = 0; ex_mem_mem_re = 0; ex_mem_rd_addr = 0;
            mem_wb_valid = 0; mem_wb_rf_we = 0; mem_wb_rd_addr = 0;
            if_id_valid = 0; if_id_uses_rs1 = 0; if_id_uses_rs2 = 0;
            if_id_rs1_addr = 0; if_id_rs2_addr = 0;
            #1;
        end
    endtask

    task chk;
        input [1:0]  e_a, e_b;
        input        e_stall;
        input [255:0] what;
        begin
            #1;
            if ((fwd_a_sel !== e_a) || (fwd_b_sel !== e_b) || (stall !== e_stall)) begin
                $display("FAIL %0s: fwd_a=%b/%b fwd_b=%b/%b stall=%b/%b",
                         what, fwd_a_sel, e_a, fwd_b_sel, e_b, stall, e_stall);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        clear_all;

        //--------------------------------------------------- H1 from EX/MEM
        ex_mem_valid = 1; ex_mem_rf_we = 1; ex_mem_mem_re = 0; ex_mem_rd_addr = 5'd7;
        id_ex_rs1_addr = 5'd7; id_ex_rs2_addr = 5'd8;
        chk(`FWD_MEM, `FWD_REG, 1'b0, "H1 on rs1");
        id_ex_rs1_addr = 5'd8; id_ex_rs2_addr = 5'd7;
        chk(`FWD_REG, `FWD_MEM, 1'b0, "H1 on rs2");
        id_ex_rs1_addr = 5'd7; id_ex_rs2_addr = 5'd7;
        chk(`FWD_MEM, `FWD_MEM, 1'b0, "H1 on both");

        // a load in EX/MEM must not forward (its data does not exist yet)
        ex_mem_mem_re = 1;
        chk(`FWD_REG, `FWD_REG, 1'b0, "load in EX/MEM must not forward");
        ex_mem_mem_re = 0;

        // x0 and disabled writes never forward
        ex_mem_rd_addr = 5'd0;
        id_ex_rs1_addr = 5'd0;
        chk(`FWD_REG, `FWD_REG, 1'b0, "rd=x0 must not forward");
        ex_mem_rd_addr = 5'd7; ex_mem_rf_we = 0;
        id_ex_rs1_addr = 5'd7;
        chk(`FWD_REG, `FWD_REG, 1'b0, "rf_we=0 must not forward");
        ex_mem_rf_we = 1; ex_mem_valid = 0;
        chk(`FWD_REG, `FWD_REG, 1'b0, "invalid EX/MEM must not forward");
        clear_all;

        //--------------------------------------------------- H2 from MEM/WB
        mem_wb_valid = 1; mem_wb_rf_we = 1; mem_wb_rd_addr = 5'd9;
        id_ex_rs1_addr = 5'd9; id_ex_rs2_addr = 5'd3;
        chk(`FWD_WB, `FWD_REG, 1'b0, "H2 on rs1");
        id_ex_rs1_addr = 5'd4; id_ex_rs2_addr = 5'd9;
        chk(`FWD_REG, `FWD_WB, 1'b0, "H2 on rs2");
        mem_wb_rd_addr = 5'd0; id_ex_rs1_addr = 5'd0;
        chk(`FWD_REG, `FWD_REG, 1'b0, "MEM/WB rd=x0 must not forward");
        mem_wb_rd_addr = 5'd9; mem_wb_rf_we = 0; id_ex_rs1_addr = 5'd9;
        chk(`FWD_REG, `FWD_REG, 1'b0, "MEM/WB we=0 must not forward");
        clear_all;

        //--------------------------------------------------- H1 beats H2
        ex_mem_valid = 1; ex_mem_rf_we = 1; ex_mem_rd_addr = 5'd5;
        mem_wb_valid = 1; mem_wb_rf_we = 1; mem_wb_rd_addr = 5'd5;
        id_ex_rs1_addr = 5'd5; id_ex_rs2_addr = 5'd6;
        chk(`FWD_MEM, `FWD_REG, 1'b0, "EX/MEM has priority over MEM/WB");
        clear_all;

        //--------------------------------------------------- H4 interlock
        id_ex_valid = 1; id_ex_mem_re = 1; id_ex_rd_addr = 5'd10;
        if_id_valid = 1; if_id_uses_rs1 = 1; if_id_rs1_addr = 5'd10;
        chk(`FWD_REG, `FWD_REG, 1'b1, "load-use on rs1");
        if_id_uses_rs1 = 0; if_id_uses_rs2 = 1; if_id_rs2_addr = 5'd10;
        chk(`FWD_REG, `FWD_REG, 1'b1, "load-use on rs2 (store data)");
        if_id_uses_rs2 = 0;
        chk(`FWD_REG, `FWD_REG, 1'b0, "no use -> no stall");
        if_id_uses_rs1 = 1; if_id_rs1_addr = 5'd11;      // different register
        chk(`FWD_REG, `FWD_REG, 1'b0, "different register -> no stall");
        id_ex_mem_re = 0; if_id_rs1_addr = 5'd10;
        chk(`FWD_REG, `FWD_REG, 1'b0, "not a load -> no stall");
        id_ex_mem_re = 1; id_ex_rd_addr = 5'd0; if_id_rs1_addr = 5'd0;
        chk(`FWD_REG, `FWD_REG, 1'b0, "load into x0 -> no stall");
        id_ex_rd_addr = 5'd10; id_ex_valid = 0; if_id_rs1_addr = 5'd10;
        chk(`FWD_REG, `FWD_REG, 1'b0, "invalid ID/EX -> no stall");
        id_ex_valid = 1; if_id_valid = 0;
        chk(`FWD_REG, `FWD_REG, 1'b0, "invalid IF/ID -> no stall");
        clear_all;

        //--------------------------------------------------- randomised sweep
        for (i = 0; i < 20000; i = i + 1) begin
            rnd = {$random};
            id_ex_valid     = rnd[0];
            id_ex_mem_re    = rnd[1];
            id_ex_rd_addr   = rnd[6:2]  % 5'd12;
            id_ex_rs1_addr  = rnd[11:7] % 5'd12;
            id_ex_rs2_addr  = rnd[16:12] % 5'd12;
            ex_mem_valid    = rnd[17];
            ex_mem_rf_we    = rnd[18];
            ex_mem_mem_re   = rnd[19];
            ex_mem_rd_addr  = rnd[24:20] % 5'd12;
            mem_wb_valid    = rnd[25];
            mem_wb_rf_we    = rnd[26];
            mem_wb_rd_addr  = rnd[31:27] % 5'd12;
            if_id_valid     = rnd[3];
            if_id_uses_rs1  = rnd[4];
            if_id_uses_rs2  = rnd[8];
            if_id_rs1_addr  = rnd[13:9]  % 5'd12;
            if_id_rs2_addr  = rnd[21:17] % 5'd12;
            #1;

            // expected forwarding, computed here from the spec
            if (ex_mem_valid && ex_mem_rf_we && !ex_mem_mem_re &&
                (ex_mem_rd_addr != 5'd0) && (ex_mem_rd_addr == id_ex_rs1_addr)) begin
                if (fwd_a_sel !== `FWD_MEM) begin
                    $display("FAIL sweep H1a i=%0d", i); errors = errors + 1;
                end
            end else if (mem_wb_valid && mem_wb_rf_we && (mem_wb_rd_addr != 5'd0) &&
                         (mem_wb_rd_addr == id_ex_rs1_addr)) begin
                if (fwd_a_sel !== `FWD_WB) begin
                    $display("FAIL sweep H2a i=%0d", i); errors = errors + 1;
                end
            end else if (fwd_a_sel !== `FWD_REG) begin
                $display("FAIL sweep REGa i=%0d", i); errors = errors + 1;
            end

            if (ex_mem_valid && ex_mem_rf_we && !ex_mem_mem_re &&
                (ex_mem_rd_addr != 5'd0) && (ex_mem_rd_addr == id_ex_rs2_addr)) begin
                if (fwd_b_sel !== `FWD_MEM) begin
                    $display("FAIL sweep H1b i=%0d", i); errors = errors + 1;
                end
            end else if (mem_wb_valid && mem_wb_rf_we && (mem_wb_rd_addr != 5'd0) &&
                         (mem_wb_rd_addr == id_ex_rs2_addr)) begin
                if (fwd_b_sel !== `FWD_WB) begin
                    $display("FAIL sweep H2b i=%0d", i); errors = errors + 1;
                end
            end else if (fwd_b_sel !== `FWD_REG) begin
                $display("FAIL sweep REGb i=%0d", i); errors = errors + 1;
            end

            if (id_ex_valid && if_id_valid && id_ex_mem_re && (id_ex_rd_addr != 5'd0) &&
                ((if_id_uses_rs1 && (if_id_rs1_addr == id_ex_rd_addr)) ||
                 (if_id_uses_rs2 && (if_id_rs2_addr == id_ex_rd_addr)))) begin
                if (stall !== 1'b1) begin
                    $display("FAIL sweep stall i=%0d", i); errors = errors + 1;
                end
            end else if (stall !== 1'b0) begin
                $display("FAIL sweep nostall i=%0d", i); errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("tb_hazard: PASS (directed + 20000 randomised checks)");
        end else begin
            $display("tb_hazard: FAIL (%0d errors)", errors);
            $fatal;
        end
        $finish;
    end

endmodule
