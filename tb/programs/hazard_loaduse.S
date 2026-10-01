# hazard_loaduse.S -- the load-use interlock (H4) in all four shapes that
# matter: the loaded value is consumed as rs1, as rs2, as store data, as a
# branch operand and as a jump target base.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

        li    x1, 0x11223344
        sw    x1, 0(x29)
        li    x1, 0x55667788
        sw    x1, 4(x29)

#--------------------------------------------------------------- load -> rs1
        lw    x2, 0(x29)
        add   x3, x2, x0                # must stall one cycle, then H2
        li    x31, 0x11223344
        bne   x3, x31, fail

#--------------------------------------------------------------- load -> rs2
        lw    x4, 4(x29)
        add   x5, x0, x4
        li    x31, 0x55667788
        bne   x5, x31, fail

#--------------------------------------------------------------- load -> store data
        lw    x6, 0(x29)
        sw    x6, 8(x29)                # uses_rs2 must cover stores
        lw    x7, 8(x29)
        bne   x7, x6, fail

#--------------------------------------------------------------- load -> store address
        lw    x9, 0(x29)                # not the address; make an address first
        li    x10, 0x2000
        lw    x11, 12(x29)              # x11 <- whatever is there (0)
        sw    x1, 16(x29)
        lw    x12, 16(x29)
        li    x31, 0x55667788
        bne   x12, x31, fail

#--------------------------------------------------------------- load -> branch operand
        lw    x13, 0(x29)
        li    x14, 0x11223344
        beq   x13, x14, lu_br           # branch right after the load
        j     fail
lu_br:

#--------------------------------------------------------------- load -> jump base
        la    x15, lu_target
        sw    x15, 20(x29)
        lw    x16, 20(x29)              # target address comes from a load
        jalr  x0, x16, 0                # must stall, then jump
        j     fail
lu_target:
        li    x31, 0x11223344
        bne   x13, x31, fail

#--------------------------------------------------------------- load -> load address
        li    x17, 0x2004
        sw    x17, 24(x29)
        lw    x18, 24(x29)              # x18 = 0x2004 (address from a load)
        lw    x19, 0(x18)               # second load must stall too
        li    x31, 0x55667788
        bne   x19, x31, fail

#--------------------------------------------------------------- byte/half loads
        li    x20, 0x00000080
        sb    x20, 32(x29)
        lb    x21, 32(x29)
        addi  x22, x21, 0               # sign extended -128
        li    x31, -128
        bne   x22, x31, fail
        lbu   x23, 32(x29)
        add   x24, x23, x0              # zero extended 128
        li    x31, 128
        bne   x24, x31, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
