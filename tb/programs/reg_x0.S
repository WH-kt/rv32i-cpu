# reg_x0.S -- x0 hardwired to zero, including the forwarding paths.
#
# A load into x0 immediately followed by a read of x0 is the interesting case:
# the write must be dropped and the forwarding network must not deliver the
# loaded value into x0 reads (rd == 0 gating).

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- x0 as source
        li    x1, 0x12345678
        add   x2, x0, x1
        bne   x2, x1, fail
        sub   x3, x1, x0
        bne   x3, x1, fail
        xor   x4, x0, x0
        bne   x4, x0, fail
        or    x5, x0, x0
        bne   x5, x0, fail
        and   x6, x1, x0
        bne   x6, x0, fail
        slt   x7, x0, x1                # 0 < 0x12345678 -> 1
        li    x31, 1
        bne   x7, x31, fail
        sll   x8, x0, x1
        bne   x8, x0, fail
        srl   x9, x1, x0                # shift by 0
        bne   x9, x1, fail

#--------------------------------------------------------------- x0 as destination
        add   x0, x1, x1
        bne   x0, x0, fail              # always false; x0 is still zero
        li    x31, 0
        bne   x0, x31, fail
        addi  x0, x0, 100
        bne   x0, x31, fail
        lui   x0, 0xFFFFF
        bne   x0, x31, fail
        auipc x0, 0
        bne   x0, x31, fail
        jal   x0, x0_skip               # a jump whose link register is x0
x0_skip:
        bne   x0, x31, fail

#--------------------------------------------------------------- load into x0
        li    x10, 0xDEADBEEF
        sw    x10, 0(x29)
        lw    x0, 0(x29)                # must be discarded
        li    x31, 0
        bne   x0, x31, fail
        add   x11, x0, x0               # and must not be forwarded as DEADBEEF
        bne   x11, x0, fail
        lbu   x0, 0(x29)                # same for the other load widths
        bne   x0, x31, fail
        lh    x0, 0(x29)
        bne   x0, x31, fail

#--------------------------------------------------------------- x0 as base
        li    x12, 0xCAFEBABE
        sw    x12, 0x400(x0)            # absolute, x0-based address
        lw    x13, 0x400(x0)
        bne   x13, x12, fail
        sw    x0, 0x404(x0)             # store zero through x0
        lw    x14, 0x404(x0)
        bne   x14, x0, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
