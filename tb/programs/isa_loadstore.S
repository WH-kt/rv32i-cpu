# isa_loadstore.S -- LB LH LW LBU LHU and SB SH SW, every byte lane,
# sign extension boundaries, and "adjacent bytes must not be disturbed".

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000               # data area

#--------------------------------------------------------------- SW / LW
        li    x1, 0x11223344
        sw    x1, 0(x29)
        lw    x2, 0(x29)
        bne   x2, x1, fail

        # offsets must scale with the address, not with the register number
        li    x1, 0xAABBCCDD
        sw    x1, 8(x29)
        lw    x3, 8(x29)
        bne   x3, x1, fail
        lw    x4, 0(x29)                # word 0 must be untouched
        li    x31, 0x11223344
        bne   x4, x31, fail

#--------------------------------------------------------------- SB / LB / LBU
        li    x1, 0x0000007F
        sb    x1, 16(x29)               # byte 0 -> 0x7F
        li    x1, 0x00000080
        sb    x1, 17(x29)               # byte 1 -> 0x80
        li    x1, 0x000000FF
        sb    x1, 18(x29)               # byte 2 -> 0xFF
        li    x1, 0x00000001
        sb    x1, 19(x29)               # byte 3 -> 0x01
        lw    x2, 16(x29)               # 0x01FF807F
        li    x31, 0x01FF807F
        bne   x2, x31, fail

        lb    x3, 16(x29)               # 0x7F -> 127
        li    x31, 127
        bne   x3, x31, fail
        lb    x4, 17(x29)               # 0x80 -> -128
        li    x31, -128
        bne   x4, x31, fail
        lb    x5, 18(x29)               # 0xFF -> -1
        li    x31, -1
        bne   x5, x31, fail
        lbu   x6, 17(x29)               # 0x80 -> 128
        li    x31, 128
        bne   x6, x31, fail
        lbu   x7, 18(x29)               # 0xFF -> 255
        li    x31, 255
        bne   x7, x31, fail
        lbu   x8, 19(x29)               # 0x01 -> 1
        li    x31, 1
        bne   x8, x31, fail

#--------------------------------------------------------------- SH / LH / LHU
        li    x1, 0x00007FFF
        sh    x1, 24(x29)               # half 0 -> 0x7FFF
        li    x1, 0x00008000
        sh    x1, 26(x29)               # half 1 -> 0x8000
        lw    x2, 24(x29)               # 0x80007FFF
        li    x31, 0x80007FFF
        bne   x2, x31, fail

        lh    x3, 24(x29)               # 0x7FFF -> 32767
        li    x31, 32767
        bne   x3, x31, fail
        lh    x4, 26(x29)               # 0x8000 -> -32768
        li    x31, -32768
        bne   x4, x31, fail
        lhu   x5, 26(x29)               # 0x8000 -> 32768
        li    x31, 32768
        bne   x5, x31, fail
        lhu   x6, 24(x29)               # 0x7FFF -> 32767
        li    x31, 32767
        bne   x6, x31, fail

#--------------------------------------------------------------- partial stores
        li    x1, 0xFFFFFFFF
        sw    x1, 32(x29)
        li    x1, 0x00000000
        sb    x1, 33(x29)               # clear byte 1 only
        lw    x2, 32(x29)               # 0xFFFF00FF
        li    x31, 0xFFFF00FF
        bne   x2, x31, fail

        li    x1, 0x0000FFFF
        sh    x1, 34(x29)               # half 1 of word 8
        lw    x3, 32(x29)               # 0xFFFF00FF
        bne   x3, x31, fail

        li    x1, 0x12345678
        sw    x1, 40(x29)
        li    x1, 0x000000AA
        sb    x1, 43(x29)               # top byte
        lw    x4, 40(x29)               # 0xAA345678
        li    x31, 0xAA345678
        bne   x4, x31, fail

#--------------------------------------------------------------- store to load
        li    x1, 0x0BADF00D
        sw    x1, 48(x29)
        lw    x2, 48(x29)               # immediately after: no stale data
        bne   x2, x1, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
