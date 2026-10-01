//============================================================================
// rv32i_defs.vh -- shared constants for the rv32i-cpu core
//
// Verilog-2001/2005.  Header guard keeps a single definition when several
// files include it in one compilation unit.
//
// Naming:  `OP_*   instruction opcode (instr[6:0])
//          `ALU_*  ALU operation (rv32i_alu)
//          `CTRL_* control bus field position inside ctrl[23:0]
//          `FWD_*  operand forward select (rv32i_hazard)
//          `WB_*   writeback source select
//          `MSZ_*  memory access size
//          `TRAP_* architectural trap cause (RISC-V standard codes)
//============================================================================
`ifndef RV32I_DEFS_VH
`define RV32I_DEFS_VH

//----------------------------------------------------------------------------
// Instruction opcodes (instr[6:0])
//----------------------------------------------------------------------------
`define OP_LOAD    7'b0000011
`define OP_STORE   7'b0100011
`define OP_BRANCH  7'b1100011
`define OP_JALR    7'b1100111
`define OP_JAL     7'b1101111
`define OP_OPIMM   7'b0010011
`define OP_OP      7'b0110011
`define OP_LUI     7'b0110111
`define OP_AUIPC   7'b0010111
`define OP_FENCE   7'b0001111
`define OP_SYSTEM  7'b1110011

// Full encodings of the two environment instructions (funct3 = 000, rs1 = x0,
// rd = x0, imm12 = 000/001).  Any other SYSTEM encoding is illegal because
// CSR instructions belong to Zicsr, which this core deliberately omits.
`define INSN_ECALL   32'h0000_0073
`define INSN_EBREAK  32'h0010_0073

//----------------------------------------------------------------------------
// ALU operations (4 bit)
//----------------------------------------------------------------------------
`define ALU_ADD    4'd0
`define ALU_SUB    4'd1
`define ALU_SLL    4'd2
`define ALU_SLT    4'd3
`define ALU_SLTU   4'd4
`define ALU_XOR    4'd5
`define ALU_SRL    4'd6
`define ALU_SRA    4'd7
`define ALU_OR     4'd8
`define ALU_AND    4'd9
`define ALU_PASSB  4'd10   // y = b   (LUI)

//----------------------------------------------------------------------------
// Control bus (24 bit, see docs/03-microarchitecture.md section 3)
// A bubble is ctrl == 24'h000000.
//----------------------------------------------------------------------------
`define CTRL_W        23
`define CTRL_ALU_OP   3:0
`define CTRL_ALU_A    4     // 0: rs1, 1: pc          (AUIPC)
`define CTRL_ALU_B    5     // 0: rs2, 1: imm
`define CTRL_WB_SEL   7:6
`define CTRL_RF_WE    8
`define CTRL_MEM_RE   9
`define CTRL_MEM_WE   10
`define CTRL_MEM_SIZE 12:11
`define CTRL_MEM_UNS  13
`define CTRL_BRANCH   14
`define CTRL_BR_OP    17:15
`define CTRL_JUMP     18
`define CTRL_JALR     19
`define CTRL_ECALL    20
`define CTRL_EBREAK   21
`define CTRL_ILLEGAL  22

// Writeback source
`define WB_ALU   2'd0
`define WB_MEM   2'd1      // load data
`define WB_PC4   2'd2      // pc + 4  (JAL/JALR link)

// Memory access size
`define MSZ_B    2'd0
`define MSZ_H    2'd1
`define MSZ_W    2'd2

//----------------------------------------------------------------------------
// Forward select (rv32i_hazard)
//----------------------------------------------------------------------------
`define FWD_REG  2'b00      // register file value captured in ID/EX
`define FWD_WB   2'b01      // MEM/WB -> EX   (hazard H2)
`define FWD_MEM  2'b10      // EX/MEM -> EX   (hazard H1)

//----------------------------------------------------------------------------
// Trap causes (RISC-V standard codes)
//----------------------------------------------------------------------------
`define TRAP_IADDR_MISALIGN  4'd0    // instruction address misaligned
`define TRAP_ILLEGAL         4'd2    // illegal instruction
`define TRAP_BREAK           4'd3    // breakpoint (EBREAK)
`define TRAP_LOAD_MISALIGN   4'd4    // load address misaligned
`define TRAP_STORE_MISALIGN  4'd6    // store address misaligned
`define TRAP_ECALL           4'd11   // environment call from M-mode

//----------------------------------------------------------------------------
// Simulation control MMIO map (implemented in rv32i_soc, not in the core)
//----------------------------------------------------------------------------
`define SIM_BASE     32'h1000_0000
`define SIM_PUTCHAR  32'h1000_0000
`define SIM_HALT     32'h1000_0004
`define SIM_MARKER   32'h1000_0008
`define SIM_CYCLES   32'h1000_000C

//----------------------------------------------------------------------------
// Misc
//----------------------------------------------------------------------------
`define XLEN         32
`define RF_INIT_NOP  32'h0000_0013   // addi x0,x0,0  (pre-fill for instruction memory)

`endif // RV32I_DEFS_VH
