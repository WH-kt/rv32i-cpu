# isa_imm.S -- I-type ALU instructions and shift immediates, including the
# sign extension boundaries of the 12 bit immediate field.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- ADDI
        li    x1, 10
        addi  x2, x1, 5                 # 15
        li    x31, 15
        bne   x2, x31, fail
        addi  x3, x1, -5                # 5
        li    x31, 5
        bne   x3, x31, fail
        addi  x4, x1, -2048             # sign extended 12 bit minimum
        li    x31, -2038
        bne   x4, x31, fail
        addi  x5, x1, 2047              # 12 bit maximum
        li    x31, 2057
        bne   x5, x31, fail
        addi  x6, x0, -1                # 0xFFFFFFFF
        li    x31, 0xFFFFFFFF
        bne   x6, x31, fail

#--------------------------------------------------------------- SLTI / SLTIU
        li    x1, 5
        slti  x2, x1, 10                # 1
        li    x31, 1
        bne   x2, x31, fail
        slti  x3, x1, 5                 # 0 (equal)
        bne   x3, x0, fail
        slti  x4, x1, -1                # 0 (5 < -1 false)
        bne   x4, x0, fail
        li    x1, 0xFFFFFFFF            # -1
        slti  x5, x1, 0                 # signed: -1 < 0 -> 1
        li    x31, 1
        bne   x5, x31, fail
        # SLTIU sign extends the immediate first, then compares unsigned:
        # rs1 = -1 = 0xFFFFFFFF, imm = -1 = 0xFFFFFFFF -> not less -> 0
        sltiu x6, x1, -1
        bne   x6, x0, fail
        sltiu x7, x1, 1                 # 0xFFFFFFFF < 1 -> 0
        bne   x7, x0, fail
        li    x1, 1
        sltiu x8, x1, -1                # 1 < 0xFFFFFFFF -> 1
        li    x31, 1
        bne   x8, x31, fail

#--------------------------------------------------------------- XORI/ORI/ANDI
        li    x1, 0xF0F0F0F0
        xori  x2, x1, 0x0FF             # 0xF0F0F00F
        li    x31, 0xF0F0F00F
        bne   x2, x31, fail
        xori  x3, x1, -1                # ~x1 = 0x0F0F0F0F
        li    x31, 0x0F0F0F0F
        bne   x3, x31, fail
        ori   x4, x0, 0x7FF             # 2047
        li    x31, 2047
        bne   x4, x31, fail
        ori   x5, x0, -2048             # sign extended: 0xFFFFF800
        li    x31, 0xFFFFF800
        bne   x5, x31, fail
        andi  x6, x1, 0x0F0             # 0xF0
        li    x31, 0xF0
        bne   x6, x31, fail
        andi  x7, x1, 0x00F             # 0xF0F0F0F0 & 0x00F = 0
        bne   x7, x0, fail

#--------------------------------------------------------------- SLLI/SRLI/SRAI
        li    x1, 1
        slli  x2, x1, 31                # 0x80000000
        li    x31, 0x80000000
        bne   x2, x31, fail
        slli  x3, x1, 0                 # unchanged
        bne   x3, x1, fail

        li    x1, 0x80000000
        srli  x4, x1, 31                # 1
        li    x31, 1
        bne   x4, x31, fail
        srai  x5, x1, 31                # 0xFFFFFFFF
        li    x31, 0xFFFFFFFF
        bne   x5, x31, fail
        srli  x6, x1, 0
        bne   x6, x1, fail
        srai  x7, x1, 4                 # 0xF8000000
        li    x31, 0xF8000000
        bne   x7, x31, fail

        li    x1, 0x7FFFFFFF
        srai  x8, x1, 4                 # 0x07FFFFFF
        li    x31, 0x07FFFFFF
        bne   x8, x31, fail

        # immediate values produced by lui+addi must be exact
        li    x1, 0x00000800            # bit 11 set: lui/addi split must round
        li    x31, 0x00000800
        bne   x1, x31, fail
        li    x1, 0xFFFFF800            # bit 11 set, negative
        li    x31, 0xFFFFF800
        bne   x1, x31, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
