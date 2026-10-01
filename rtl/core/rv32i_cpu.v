// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
//============================================================================
// rv32i_cpu.v -- RV32I five stage in-order single-issue pipeline core
//
//   IF -> ID -> EX -> MEM -> WB
//
// Structure (see docs/03-microarchitecture.md and docs/04-datapath-control.md):
//   * Harvard interface, zero latency (combinational) read memories.
//   * Static not-taken prediction: IF always fetches pc+4; every branch, JAL
//     and JALR is resolved in EX and redirects with a two cycle flush.
//   * Data hazards: EX/MEM->EX and MEM/WB->EX forwarding, register file
//     write-through, one cycle load-use interlock.  All of it lives in
//     rv32i_hazard / rv32i_regfile.
//   * Commit point is the EX->MEM boundary.  EX is the only stage that can
//     raise a trap, so an instruction that enters EX/MEM is guaranteed to
//     complete: retire counting and traps can never disagree.
//   * Traps are precise and fail-stop: older instructions complete and
//     commit, younger ones are squashed, fetching stops and trap_o stays
//     asserted until reset (no privileged ISA in this core).
//   * halt_i squashes every instruction younger than the MEM stage and then
//     freezes the core, so a system halt has no side effects from
//     wrong-path work.
//
// Verilog-2001/2005, synchronous active high reset, single clock.
//============================================================================
`include "rv32i_defs.vh"

module rv32i_cpu #(
    parameter RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        reset,

    // ---- instruction port (combinational read) ----
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,

    // ---- data port ----
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    output wire        dmem_we,
    output wire        dmem_re,
    input  wire [31:0] dmem_rdata,

    // ---- system halt request ----
    input  wire        halt_i,

    // ---- trap observability (sticky until reset) ----
    output wire        trap_o,
    output wire [3:0]  trap_cause_o,
    output wire [31:0] trap_pc_o,
    output wire [31:0] trap_tval_o,

    // ---- retire observability (commit point: EX -> MEM) ----
    output wire        retire_valid_o,
    output wire [31:0] retire_pc_o,
    output wire [31:0] retire_instr_o
);

    //========================================================================
    // Pipeline registers
    //========================================================================
    reg [31:0] pc;

    // IF/ID
    reg        if_id_valid;
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;
    reg        if_id_pred_taken;
    reg [31:0] if_id_pred_target;

    // ID/EX
    reg        id_ex_valid;
    reg [`CTRL_W-1:0] id_ex_ctrl;
    reg [31:0] id_ex_pc;
    reg [31:0] id_ex_instr;
    reg [31:0] id_ex_rs1_val;
    reg [31:0] id_ex_rs2_val;
    reg [31:0] id_ex_imm;
    reg [4:0]  id_ex_rs1_addr;
    reg [4:0]  id_ex_rs2_addr;
    reg [4:0]  id_ex_rd_addr;
    reg        id_ex_pred_taken;
    reg [31:0] id_ex_pred_target;

    // EX/MEM
    // Control fields are kept as named registers: exactly the subset the MEM
    // and WB stages consume, so no field map is needed downstream and no
    // flops are spent on bits nobody reads.
    reg        ex_mem_valid;
    reg        ex_mem_rf_we;
    reg        ex_mem_mem_re;
    reg        ex_mem_mem_we;
    reg [1:0]  ex_mem_mem_size;
    reg        ex_mem_mem_uns;
    reg [1:0]  ex_mem_wb_sel;
    reg [31:0] ex_mem_pc;
    reg [31:0] ex_mem_alu;
    reg [31:0] ex_mem_store_data;
    reg [4:0]  ex_mem_rd_addr;

    // MEM/WB
    reg        mem_wb_valid;
    reg        mem_wb_rf_we;
    reg [31:0] mem_wb_wdata;
    reg [4:0]  mem_wb_rd_addr;

    //========================================================================
    // IF stage
    //========================================================================
    assign imem_addr = pc;

    // Static predict-not-taken: the prediction fields are carried through the
    // pipeline so the EX stage can check them.  With pred_taken tied to 0 the
    // check degenerates to "taken => mispredict", and the fields become the
    // hook for a future predictor without touching any other stage.
    wire        if_pred_taken  = 1'b0;
    wire [31:0] if_pred_target = 32'd0;

    //========================================================================
    // ID stage
    //========================================================================
    wire [`CTRL_W-1:0] id_ctrl;
    wire [4:0]  id_rs1_addr, id_rs2_addr, id_rd_addr;
    wire        id_uses_rs1, id_uses_rs2;
    wire [31:0] id_imm;
    wire [31:0] id_rs1_val, id_rs2_val;

    rv32i_decoder u_decoder (
        .instr    (if_id_instr),
        .ctrl     (id_ctrl),
        .rs1_addr (id_rs1_addr),
        .rs2_addr (id_rs2_addr),
        .rd_addr  (id_rd_addr),
        .uses_rs1 (id_uses_rs1),
        .uses_rs2 (id_uses_rs2)
    );

    rv32i_immgen u_immgen (
        .instr (if_id_instr),
        .imm   (id_imm)
    );

    rv32i_regfile u_regfile (
        .clk    (clk),
        .reset  (reset),
        .we     (mem_wb_rf_we & mem_wb_valid),
        .waddr  (mem_wb_rd_addr),
        .wdata  (mem_wb_wdata),
        .raddr1 (id_rs1_addr),
        .raddr2 (id_rs2_addr),
        .rdata1 (id_rs1_val),
        .rdata2 (id_rs2_val)
    );

    //========================================================================
    // Hazard unit (forwarding selects + load-use interlock)
    //========================================================================
    wire [1:0] fwd_a_sel, fwd_b_sel;
    wire       stall;

    rv32i_hazard u_hazard (
        .id_ex_valid     (id_ex_valid),
        .id_ex_mem_re    (id_ex_ctrl[`CTRL_MEM_RE]),
        .id_ex_rd_addr   (id_ex_rd_addr),
        .id_ex_rs1_addr  (id_ex_rs1_addr),
        .id_ex_rs2_addr  (id_ex_rs2_addr),
        .ex_mem_valid    (ex_mem_valid),
        .ex_mem_rf_we    (ex_mem_rf_we),
        .ex_mem_mem_re   (ex_mem_mem_re),
        .ex_mem_rd_addr  (ex_mem_rd_addr),
        .mem_wb_valid    (mem_wb_valid),
        .mem_wb_rf_we    (mem_wb_rf_we),
        .mem_wb_rd_addr  (mem_wb_rd_addr),
        .if_id_valid     (if_id_valid),
        .if_id_uses_rs1  (id_uses_rs1),
        .if_id_uses_rs2  (id_uses_rs2),
        .if_id_rs1_addr  (id_rs1_addr),
        .if_id_rs2_addr  (id_rs2_addr),
        .fwd_a_sel       (fwd_a_sel),
        .fwd_b_sel       (fwd_b_sel),
        .stall           (stall)
    );

    //========================================================================
    // EX stage
    //========================================================================
    wire [31:0] ex_rs1_fwd = (fwd_a_sel == `FWD_MEM) ? ex_mem_alu   :
                             (fwd_a_sel == `FWD_WB ) ? mem_wb_wdata : id_ex_rs1_val;
    wire [31:0] ex_rs2_fwd = (fwd_b_sel == `FWD_MEM) ? ex_mem_alu   :
                             (fwd_b_sel == `FWD_WB ) ? mem_wb_wdata : id_ex_rs2_val;

    wire [31:0] ex_alu_a = id_ex_ctrl[`CTRL_ALU_A] ? id_ex_pc : ex_rs1_fwd;
    wire [31:0] ex_alu_b = id_ex_ctrl[`CTRL_ALU_B] ? id_ex_imm : ex_rs2_fwd;
    wire [31:0] ex_alu_y;

    rv32i_alu u_alu (
        .alu_op (id_ex_ctrl[`CTRL_ALU_OP]),
        .a      (ex_alu_a),
        .b      (ex_alu_b),
        .y      (ex_alu_y)
    );

    wire ex_br_taken;
    rv32i_brcmp u_brcmp (
        .br_op (id_ex_ctrl[`CTRL_BR_OP]),
        .a     (ex_rs1_fwd),
        .b     (ex_rs2_fwd),
        .taken (ex_br_taken)
    );

    // ---- control transfer resolution --------------------------------------
    // JAL/JALR/JALR target: JALR reuses the ALU adder (rs1 + imm), JAL and
    // branches need pc + imm.
    wire [31:0] ex_pc_imm = id_ex_pc + id_ex_imm;
    wire [31:0] ex_target = id_ex_ctrl[`CTRL_JALR] ? (ex_alu_y & 32'hFFFF_FFFE)
                                                   : ex_pc_imm;
    wire        ex_actual_taken = (id_ex_ctrl[`CTRL_BRANCH] & ex_br_taken) |
                                  id_ex_ctrl[`CTRL_JUMP];

    wire        ex_mispredict = (ex_actual_taken != id_ex_pred_taken) |
                                (ex_actual_taken & (ex_target != id_ex_pred_target));

    // ---- trap detection (EX is the only trap source) ----------------------
    wire [1:0]  ex_msize   = id_ex_ctrl[`CTRL_MEM_SIZE];
    wire [31:0] ex_addr    = ex_alu_y;
    wire        ex_addr_odd = (ex_msize == `MSZ_W) ? (ex_addr[1:0] != 2'b00) :
                              (ex_msize == `MSZ_H) ? (ex_addr[0]    != 1'b0) : 1'b0;
    wire        ex_load_mis  = id_ex_ctrl[`CTRL_MEM_RE] & ex_addr_odd;
    wire        ex_store_mis = id_ex_ctrl[`CTRL_MEM_WE] & ex_addr_odd;
    wire        ex_target_mis = ex_actual_taken & (ex_target[1:0] != 2'b00);

    wire        ex_trap = id_ex_valid & (id_ex_ctrl[`CTRL_ILLEGAL] |
                                         id_ex_ctrl[`CTRL_ECALL]   |
                                         id_ex_ctrl[`CTRL_EBREAK]  |
                                         ex_load_mis | ex_store_mis | ex_target_mis);

    reg [3:0] ex_cause;
    always @(*) begin
        if      (id_ex_ctrl[`CTRL_ILLEGAL]) ex_cause = `TRAP_ILLEGAL;
        else if (id_ex_ctrl[`CTRL_ECALL])   ex_cause = `TRAP_ECALL;
        else if (id_ex_ctrl[`CTRL_EBREAK])  ex_cause = `TRAP_BREAK;
        else if (ex_load_mis)               ex_cause = `TRAP_LOAD_MISALIGN;
        else if (ex_store_mis)              ex_cause = `TRAP_STORE_MISALIGN;
        else if (ex_target_mis)             ex_cause = `TRAP_IADDR_MISALIGN;
        else                                ex_cause = 4'd0;
    end

    // trap value follows the mtval convention: encoding for illegal
    // instruction, faulting address for misaligned accesses, else zero.
    reg [31:0] ex_tval;
    always @(*) begin
        if      (id_ex_ctrl[`CTRL_ILLEGAL])  ex_tval = id_ex_instr;
        else if (ex_load_mis | ex_store_mis) ex_tval = ex_addr;
        else if (ex_target_mis)              ex_tval = ex_target;
        else                                 ex_tval = 32'd0;
    end

    // ---- trap register (sticky until reset) --------------------------------
    reg        trap_flag;
    reg [3:0]  trap_cause_r;
    reg [31:0] trap_pc_r;
    reg [31:0] trap_tval_r;

    always @(posedge clk) begin
        if (reset) begin
            trap_flag   <= 1'b0;
            trap_cause_r <= 4'd0;
            trap_pc_r    <= 32'd0;
            trap_tval_r  <= 32'd0;
        end else if (ex_trap && !trap_flag) begin
            trap_flag   <= 1'b1;
            trap_cause_r <= ex_cause;
            trap_pc_r    <= id_ex_pc;
            trap_tval_r  <= ex_tval;
        end
    end

    assign trap_o       = trap_flag;
    assign trap_cause_o = trap_cause_r;
    assign trap_pc_o    = trap_pc_r;
    assign trap_tval_o  = trap_tval_r;

    // ---- halt request (sticky) --------------------------------------------
    reg halt_flag;
    always @(posedge clk) begin
        if (reset)        halt_flag <= 1'b0;
        else if (halt_i)  halt_flag <= 1'b1;
    end

    //========================================================================
    // Pipeline control (flush / stall / redirect)
    //
    //   reset                 > halt/trap > redirect > stall
    //
    // core_stop  : fetching stops and the front end is squashed (trap/halt)
    // flush_front: squash IF/ID and ID/EX
    // kill_ex    : squash the EX stage instruction as well -- needed for
    //              halt_i, whose source (a store in MEM) is older than the
    //              instruction sitting in EX; without it that younger
    //              instruction would write memory on the next cycle.
    //========================================================================
    wire ex_redirect = id_ex_valid & ex_mispredict & ~ex_trap;
    wire core_stop   = trap_flag | ex_trap | halt_flag | halt_i;
    wire flush_front = reset | core_stop | ex_redirect;
    wire kill_ex     = reset | halt_i;

    //========================================================================
    // PC
    //========================================================================
    always @(posedge clk) begin
        if (reset)            pc <= RESET_PC;
        else if (core_stop)   pc <= pc;
        else if (ex_redirect) pc <= ex_target;
        else if (stall)       pc <= pc;
        else                  pc <= pc + 32'd4;
    end

    //========================================================================
    // IF/ID
    //========================================================================
    always @(posedge clk) begin
        if (reset || flush_front) begin
            if_id_valid       <= 1'b0;
            if_id_pc          <= 32'd0;
            if_id_instr       <= 32'd0;
            if_id_pred_taken  <= 1'b0;
            if_id_pred_target <= 32'd0;
        end else if (!stall) begin
            if_id_valid       <= 1'b1;
            if_id_pc          <= pc;
            if_id_instr       <= imem_rdata;
            if_id_pred_taken  <= if_pred_taken;
            if_id_pred_target <= if_pred_target;
        end
    end

    //========================================================================
    // ID/EX
    //========================================================================
    always @(posedge clk) begin
        if (reset || flush_front || stall) begin
            id_ex_valid       <= 1'b0;
            id_ex_ctrl        <= {`CTRL_W{1'b0}};
            id_ex_pc          <= 32'd0;
            id_ex_instr       <= 32'd0;
            id_ex_rs1_val     <= 32'd0;
            id_ex_rs2_val     <= 32'd0;
            id_ex_imm         <= 32'd0;
            id_ex_rs1_addr    <= 5'd0;
            id_ex_rs2_addr    <= 5'd0;
            id_ex_rd_addr     <= 5'd0;
            id_ex_pred_taken  <= 1'b0;
            id_ex_pred_target <= 32'd0;
        end else begin
            id_ex_valid       <= if_id_valid;
            id_ex_ctrl        <= id_ctrl;
            id_ex_pc          <= if_id_pc;
            id_ex_instr       <= if_id_instr;
            id_ex_rs1_val     <= id_rs1_val;
            id_ex_rs2_val     <= id_rs2_val;
            id_ex_imm         <= id_imm;
            id_ex_rs1_addr    <= id_rs1_addr;
            id_ex_rs2_addr    <= id_rs2_addr;
            id_ex_rd_addr     <= id_rd_addr;
            id_ex_pred_taken  <= if_id_pred_taken;
            id_ex_pred_target <= if_id_pred_target;
        end
    end

    //========================================================================
    // EX/MEM
    //========================================================================
    always @(posedge clk) begin
        if (kill_ex || (id_ex_valid && ex_trap)) begin
            // trap: the trapping instruction must not commit or touch memory
            ex_mem_valid      <= 1'b0;
            ex_mem_rf_we      <= 1'b0;
            ex_mem_mem_re     <= 1'b0;
            ex_mem_mem_we     <= 1'b0;
            ex_mem_mem_size   <= `MSZ_W;
            ex_mem_mem_uns    <= 1'b0;
            ex_mem_wb_sel     <= `WB_ALU;
            ex_mem_pc         <= 32'd0;
            ex_mem_alu        <= 32'd0;
            ex_mem_store_data <= 32'd0;
            ex_mem_rd_addr    <= 5'd0;
        end else begin
            ex_mem_valid      <= id_ex_valid;
            ex_mem_rf_we      <= id_ex_ctrl[`CTRL_RF_WE];
            ex_mem_mem_re     <= id_ex_ctrl[`CTRL_MEM_RE];
            ex_mem_mem_we     <= id_ex_ctrl[`CTRL_MEM_WE];
            ex_mem_mem_size   <= id_ex_ctrl[`CTRL_MEM_SIZE];
            ex_mem_mem_uns    <= id_ex_ctrl[`CTRL_MEM_UNS];
            ex_mem_wb_sel     <= id_ex_ctrl[`CTRL_WB_SEL];
            ex_mem_pc         <= id_ex_pc;
            ex_mem_alu        <= ex_alu_y;
            ex_mem_store_data <= ex_rs2_fwd;
            ex_mem_rd_addr    <= id_ex_rd_addr;
        end
    end

    //========================================================================
    // MEM stage
    //========================================================================
    wire [1:0] mem_size = ex_mem_mem_size;
    wire       mem_uns  = ex_mem_mem_uns;

    assign dmem_addr = ex_mem_alu;
    assign dmem_we   = ex_mem_valid & ex_mem_mem_we;
    assign dmem_re   = ex_mem_valid & ex_mem_mem_re;

    // Byte enables: position comes from the address, width from the opcode.
    reg [3:0] mem_wstrb;
    always @(*) begin
        case (mem_size)
            `MSZ_B:  mem_wstrb = 4'b0001 << ex_mem_alu[1:0];
            `MSZ_H:  mem_wstrb = ex_mem_alu[1] ? 4'b1100 : 4'b0011;
            default: mem_wstrb = 4'b1111;
        endcase
    end
    assign dmem_wstrb = ex_mem_valid ? mem_wstrb : 4'b0000;

    // Store data replicated into every lane; dmem_wstrb picks the real one.
    reg [31:0] mem_wdata;
    always @(*) begin
        case (mem_size)
            `MSZ_B:  mem_wdata = {4{ex_mem_store_data[7:0]}};
            `MSZ_H:  mem_wdata = {2{ex_mem_store_data[15:0]}};
            default: mem_wdata = ex_mem_store_data;
        endcase
    end
    assign dmem_wdata = mem_wdata;

    // ---- load data extraction --------------------------------------------
    reg [7:0]  mem_byte;
    reg [15:0] mem_half;
    always @(*) begin
        case (ex_mem_alu[1:0])
            2'd0:    mem_byte = dmem_rdata[7:0];
            2'd1:    mem_byte = dmem_rdata[15:8];
            2'd2:    mem_byte = dmem_rdata[23:16];
            default: mem_byte = dmem_rdata[31:24];
        endcase
        mem_half = ex_mem_alu[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];
    end

    reg [31:0] mem_load_data;
    always @(*) begin
        case (mem_size)
            `MSZ_B:  mem_load_data = mem_uns ? {24'd0, mem_byte}
                                             : {{24{mem_byte[7]}}, mem_byte};
            `MSZ_H:  mem_load_data = mem_uns ? {16'd0, mem_half}
                                             : {{16{mem_half[15]}}, mem_half};
            default: mem_load_data = dmem_rdata;
        endcase
    end

    // ---- writeback value --------------------------------------------------
    // The JAL/JALR link value (pc+4) is produced here from the PC carried in
    // EX/MEM, which is why that field is functional and not debug-only.
    reg [31:0] mem_wb_value;
    always @(*) begin
        case (ex_mem_wb_sel)
            `WB_MEM: mem_wb_value = mem_load_data;
            `WB_PC4: mem_wb_value = ex_mem_pc + 32'd4;
            default: mem_wb_value = ex_mem_alu;
        endcase
    end

    //========================================================================
    // MEM/WB
    //========================================================================
    always @(posedge clk) begin
        if (reset) begin
            mem_wb_valid   <= 1'b0;
            mem_wb_rf_we   <= 1'b0;
            mem_wb_wdata   <= 32'd0;
            mem_wb_rd_addr <= 5'd0;
        end else begin
            mem_wb_valid   <= ex_mem_valid;
            mem_wb_rf_we   <= ex_mem_rf_we;
            mem_wb_wdata   <= mem_wb_value;
            mem_wb_rd_addr <= ex_mem_rd_addr;
        end
    end

    //========================================================================
    // Retire / commit observation (EX -> MEM boundary)
    //========================================================================
    assign retire_valid_o = id_ex_valid & ~ex_trap & ~halt_i & ~halt_flag & ~trap_flag;
    assign retire_pc_o    = id_ex_pc;
    assign retire_instr_o = id_ex_instr;

endmodule
