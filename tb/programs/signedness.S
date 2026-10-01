# signedness.S -- the cases where signed and unsigned interpretations of the
# same 32 bit pattern must disagree: SLT/SLTU, BLT/BGE vs BLTU/BGEU,
# LB/LBU, LH/LHU, SRAI/SRLI.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- SLT vs SLTU
        li    x1, 0xFFFFFFFF            # -1 / 4294967295
        li    x2, 0x00000001
        slt   x3, x1, x2                # -1 < 1        -> 1
        li    x31, 1
        bne   x3, x31, fail
        sltu  x4, x1, x2                # 4294967295 < 1 -> 0
        bne   x4, x0, fail
        slt   x5, x2, x1                # 1 < -1        -> 0
        bne   x5, x0, fail
        sltu  x6, x2, x1                # 1 < 4294967295 -> 1
        li    x31, 1
        bne   x6, x31, fail

#--------------------------------------------------------------- BLT vs BLTU
        li    x1, 0xFFFFFFFF
        li    x2, 0
        blt   x1, x2, sig_lt            # -1 < 0
        j     fail
sig_lt:
        bltu  x1, x2, fail              # 4294967295 < 0 is false
        bgeu  x1, x2, uns_ge            # 4294967295 >= 0 is true
        j     fail
uns_ge:

        li    x1, 0x80000000            # -2147483648 / 2147483648
        li    x2, 0
        blt   x1, x2, neg_lt            # signed: negative
        j     fail
neg_lt:
        bltu  x1, x2, fail              # unsigned: 2^31 < 0 is false
        bge   x2, x1, pos_ge            # signed: 0 >= INT_MIN
        j     fail
pos_ge:

#--------------------------------------------------------------- LB vs LBU
        li    x1, 0x80
        sb    x1, 0(x29)
        li    x1, 0x7F
        sb    x1, 1(x29)
        lb    x3, 0(x29)                # 0x80 -> -128
        li    x31, -128
        bne   x3, x31, fail
        lbu   x4, 0(x29)                # 0x80 -> 128
        li    x31, 128
        bne   x4, x31, fail
        lb    x5, 1(x29)                # 0x7F -> 127
        li    x31, 127
        bne   x5, x31, fail
        lbu   x6, 1(x29)
        li    x31, 127
        bne   x6, x31, fail

#--------------------------------------------------------------- LH vs LHU
        li    x1, 0x8000
        sh    x1, 4(x29)
        li    x1, 0x7FFF
        sh    x1, 8(x29)
        lh    x3, 4(x29)                # 0x8000 -> -32768
        li    x31, -32768
        bne   x3, x31, fail
        lhu   x4, 4(x29)                # 0x8000 -> 32768
        li    x31, 32768
        bne   x4, x31, fail
        lh    x5, 8(x29)                # 0x7FFF -> 32767
        li    x31, 32767
        bne   x5, x31, fail
        lhu   x6, 8(x29)
        li    x31, 32767
        bne   x6, x31, fail

#--------------------------------------------------------------- SRA vs SRL
        li    x1, 0xFFFFFF00            # -256
        srli  x3, x1, 4                 # 0x0FFFFFF0
        li    x31, 0x0FFFFFF0
        bne   x3, x31, fail
        srai  x4, x1, 4                 # 0xFFFFFFF0
        li    x31, 0xFFFFFFF0
        bne   x4, x31, fail

#--------------------------------------------------------------- SLTI vs SLTIU
        li    x1, 0xFFFFFFFF
        slti  x5, x1, 0                 # signed: -1 < 0 -> 1
        li    x31, 1
        bne   x5, x31, fail
        sltiu x6, x1, 0                 # unsigned: 4294967295 < 0 -> 0
        bne   x6, x0, fail
        sltiu x7, x1, -1                # imm -1 sign extends to 0xFFFFFFFF,
        bne   x7, x0, fail              # so the comparison is equal -> 0

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
