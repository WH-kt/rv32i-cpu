//============================================================================
// tb_rv32i.v -- self-checking SoC level testbench
//
// Runs one program image (sim/image.hex, copied there by the Makefile), then
//
//   1. writes an EVENT LOG that is byte-for-byte the format the reference
//      model (tools/iss) produces, so correctness of the run is decided by a
//      plain `diff`:
//          PUTC hh / MARK hhhhhhhh / HALT hh / TRAP <text> /
//          CHECKSUM hhhhhhhh / STEPS d
//   2. writes an architectural STATE dump (32 registers + the whole data
//      memory) that tools/check_equiv.py compares word-for-word against the
//      reference model.
//
// Plusargs:  +log=<file>  +state=<file>  +max_cycles=<n>
//
// Retire counting: the core pulses retire_valid_o when an instruction passes
// the EX->MEM commit point.  The store that halts the system commits *before*
// the halt is seen, so it must be subtracted; a trapping instruction never
// commits at all.  That makes STEPS directly comparable with the model's
// instruction count, which does not count the terminating instruction either.
//============================================================================
`timescale 1ns/1ps
`include "rv32i_defs.vh"

module tb_rv32i;

    parameter MEM_WORDS = 16384;
    localparam IMAGE = "build/image.hex";

    //------------------------------------------------------------------
    // clock / reset
    //------------------------------------------------------------------
    reg clk;
    reg reset;

    initial begin
        clk   = 1'b0;
        reset = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
    end

    always #5 clk = ~clk;          // 100 MHz nominal

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    wire        halt_o;
    wire [7:0]  halt_code_o;
    wire        trap_o;
    wire [3:0]  trap_cause_o;
    wire [31:0] trap_pc_o;
    wire [31:0] trap_tval_o;
    wire        retire_valid_o;
    wire [31:0] retire_pc_o;
    wire [31:0] retire_instr_o;
    wire [31:0] cycle_o;
    wire        putc_valid_o;
    wire [7:0]  putc_data_o;
    wire        mark_valid_o;
    wire [31:0] mark_data_o;

    rv32i_soc #(
        .MEM_WORDS (MEM_WORDS),
        .INIT_FILE (IMAGE),
        .RESET_PC  (32'h0000_0000)
    ) dut (
        .clk            (clk),
        .reset          (reset),
        .halt_o         (halt_o),
        .halt_code_o    (halt_code_o),
        .trap_o         (trap_o),
        .trap_cause_o   (trap_cause_o),
        .trap_pc_o      (trap_pc_o),
        .trap_tval_o    (trap_tval_o),
        .retire_valid_o (retire_valid_o),
        .retire_pc_o    (retire_pc_o),
        .retire_instr_o (retire_instr_o),
        .cycle_o        (cycle_o),
        .putc_valid_o   (putc_valid_o),
        .putc_data_o    (putc_data_o),
        .mark_valid_o   (mark_valid_o),
        .mark_data_o    (mark_data_o)
    );

    //------------------------------------------------------------------
    // files and plusargs
    //------------------------------------------------------------------
    integer       log_fd;
    integer       state_fd;
    integer       trace_fd;
    reg [1023:0]  log_path;
    reg [1023:0]  state_path;
    reg [1023:0]  trace_path;
    integer       max_cycles;

    initial begin
        if (!$value$plusargs("log=%s", log_path))        log_path   = "sim/rtl.log";
        if (!$value$plusargs("state=%s", state_path))    state_path = "sim/rtl.state";
        if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 2000000;
        trace_fd = 0;
        if ($value$plusargs("trace=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");
        end
        log_fd = $fopen(log_path, "w");
        if (log_fd == 0) begin
            $display("TB FAIL: cannot open log file %0s", log_path);
            $finish;
        end
    end

    //------------------------------------------------------------------
    // run state
    //------------------------------------------------------------------
    integer  retire_count;
    reg      retire_frozen;
    reg      halt_seen;            // MMIO halt store observed (retire - 1)
    reg      end_seen;             // any terminal event (log/message only)
    reg      trap_seen;            // trap_o rose
    reg      trap_o_q;
    reg      stopping;
    reg [1:0] drain;
    integer  cyc;
    reg      timed_out;

    wire trap_rise = trap_o & ~trap_o_q;
    wire stop_pulse = halt_o | trap_rise;

    wire [31:0] steps_report = halt_seen ? (retire_count - 1) : retire_count;

    integer k;
    reg [31:0] cksum;
    reg [31:0] word;

    //------------------------------------------------------------------
    // main sequencer
    //------------------------------------------------------------------
    initial begin
        retire_count  = 0;
        retire_frozen = 1'b0;
        halt_seen     = 1'b0;
        end_seen      = 1'b0;
        trap_seen     = 1'b0;
        trap_o_q      = 1'b0;
        stopping      = 1'b0;
        drain         = 2'd0;
        cyc           = 0;
        timed_out     = 1'b0;
    end

    // event + retire bookkeeping, one clock at a time
    always @(posedge clk) begin
        if (reset) begin
            retire_count  <= 0;
            retire_frozen <= 1'b0;
            halt_seen     <= 1'b0;
            end_seen      <= 1'b0;
            trap_seen     <= 1'b0;
            trap_o_q      <= 1'b0;
            stopping      <= 1'b0;
            drain         <= 2'd0;
            cyc           <= 0;
            timed_out     <= 1'b0;
        end else begin
            cyc      <= cyc + 1;
            trap_o_q <= trap_o;

            // ---- event log (order is program order) ------------------
            if (!stopping) begin
                if (putc_valid_o) $fwrite(log_fd, "PUTC %02x\n", putc_data_o);
                if (mark_valid_o) $fwrite(log_fd, "MARK %08x\n", mark_data_o);
            end

            // ---- retire count + optional execution trace --------------
            if (retire_valid_o && !retire_frozen) begin
                retire_count <= retire_count + 1;
                if (trace_fd != 0) begin
                    $fwrite(trace_fd, "%08x %08x\n", retire_pc_o, retire_instr_o);
                end
            end
            if (trace_fd != 0 && trap_rise) begin
                $fwrite(trace_fd, "trap %0d %08x\n", trap_cause_o, trap_tval_o);
            end

            // ---- halt / trap -----------------------------------------
            if (!stopping) begin
                if (halt_o) begin
                    $fwrite(log_fd, "HALT %02x\n", halt_code_o);
                    halt_seen  <= 1'b1;
                    end_seen   <= 1'b1;
                    stopping   <= 1'b1;
                    drain      <= 2'd1;
                    retire_frozen <= 1'b1;
                end else if (trap_rise) begin
                    if (trap_cause_o == `TRAP_BREAK) begin
                        // EBREAK halts the system, but it is a trap: the
                        // instruction does not retire, so STEPS needs no
                        // adjustment here (unlike the MMIO halt store).
                        $fwrite(log_fd, "HALT 00\n");
                        end_seen <= 1'b1;
                    end else begin
                        case (trap_cause_o)
                            `TRAP_ILLEGAL:
                                $fwrite(log_fd, "TRAP opcode %02x (insn %08x)\n",
                                        trap_tval_o[6:0], trap_tval_o);
                            `TRAP_ECALL:
                                $fwrite(log_fd, "TRAP ecall\n");
                            `TRAP_LOAD_MISALIGN:
                                $fwrite(log_fd, "TRAP load misaligned addr=%08x\n", trap_tval_o);
                            `TRAP_STORE_MISALIGN:
                                $fwrite(log_fd, "TRAP store misaligned addr=%08x\n", trap_tval_o);
                            `TRAP_IADDR_MISALIGN:
                                $fwrite(log_fd, "TRAP instr misaligned addr=%08x\n", trap_tval_o);
                            default:
                                $fwrite(log_fd, "TRAP cause=%0d pc=%08x\n", trap_cause_o, trap_pc_o);
                        endcase
                    end
                    trap_seen     <= 1'b1;
                    end_seen      <= 1'b1;
                    stopping      <= 1'b1;
                    drain         <= 2'd1;
                    retire_frozen <= 1'b1;
                end
            end else if (drain != 2'd0) begin
                drain <= drain - 2'd1;
            end

            // ---- drain finished: dump and stop -----------------------
            if (stopping && (drain == 2'd0)) begin
                dump_and_finish;
            end

            // ---- timeout ---------------------------------------------
            if (!stopping && (cyc >= max_cycles)) begin
                $fwrite(log_fd, "TIMEOUT\n");
                timed_out <= 1'b1;
                stopping  <= 1'b1;
                drain     <= 2'd1;
                retire_frozen <= 1'b1;
            end
        end
    end

    //------------------------------------------------------------------
    // state dump + memory checksum + report
    //------------------------------------------------------------------
    task dump_and_finish;
        begin
            state_fd = $fopen(state_path, "w");
            $fwrite(state_fd, "REGS\n");
            for (k = 0; k < 32; k = k + 1) begin
                $fwrite(state_fd, "%08x\n", dut.u_cpu.u_regfile.rf[k]);
            end
            $fwrite(state_fd, "MEM\n");
            for (k = 0; k < MEM_WORDS; k = k + 1) begin
                $fwrite(state_fd, "%08x\n", dut.u_dmem.mem[k]);
            end
            $fclose(state_fd);
            if (trace_fd != 0) $fclose(trace_fd);

            // FNV-1a over the whole data memory, identical to the model
            cksum = 32'd2166136261;
            for (k = 0; k < MEM_WORDS; k = k + 1) begin
                word  = dut.u_dmem.mem[k];
                cksum = (cksum ^ (word & 32'hFF))         * 32'd16777619;
                cksum = (cksum ^ ((word >> 8)  & 32'hFF)) * 32'd16777619;
                cksum = (cksum ^ ((word >> 16) & 32'hFF)) * 32'd16777619;
                cksum = (cksum ^ ((word >> 24) & 32'hFF)) * 32'd16777619;
            end

            $fwrite(log_fd, "CHECKSUM %08x\n", cksum);
            $fwrite(log_fd, "STEPS %0d\n", steps_report);
            $fclose(log_fd);

            if (timed_out) begin
                $display("TB FAIL: timeout after %0d cycles", cyc);
            end else if (trap_seen || end_seen) begin
                $display("TB DONE: cycles=%0d retired=%0d traps=%0d",
                         cyc, retire_count, trap_seen);
            end
            $finish;
        end
    endtask

endmodule
