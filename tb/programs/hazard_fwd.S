# hazard_fwd.S -- the forwarding network, on purpose.
#
# Every sequence below places the producer exactly 1, 2 or 3 instructions
# before the consumer, which is what selects the EX/MEM path (H1), the MEM/WB
# path (H2) or the register file write-through path (H3).  The consumer reads
# the value in the rs1 position, the rs2 position, as a store address, as a
# store data operand and as a branch operand.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- distance 1 (EX/MEM)
        li    x1, 0x1000
        addi  x2, x1, 1                 # x2 ready in EX
        add   x3, x2, x0                # H1 on rs1
        li    x31, 0x1001
        bne   x3, x31, fail

        li    x4, 55
        addi  x4, x4, 1                 # x4 = 56, produced one before
        add   x5, x0, x4                # H1 on rs2
        li    x31, 56
        bne   x5, x31, fail

#--------------------------------------------------------------- distance 2 (MEM/WB)
        li    x6, 0x2000
        addi  x7, x0, 7                 # distance 1 filler
        add   x8, x7, x6                # H2 on rs1 (x7 from two back)
        li    x31, 0x2007
        bne   x8, x31, fail

        li    x9, 0x12340000
        li    x10, 0x5678               # filler
        or    x11, x10, x9              # H2 on rs2
        li    x31, 0x12345678
        bne   x11, x31, fail

#--------------------------------------------------------------- distance 3 (write-through)
        # the consumer reads the register file in ID in the very cycle the
        # producer writes it in WB: only the write-through bypass can supply
        # the right value, no forwarding path can reach this far
        li    x12, 0xAAAA0000
        li    x13, 0x1111
        li    x14, 0x2222
        add   x15, x12, x13             # written in WB when add below is in ID
        add   x16, x15, x14
        li    x31, 0xAAAA3333
        bne   x16, x31, fail

        li    x17, 0x0000FFFF
        li    x18, 0
        li    x19, 0
        or    x20, x17, x18             # distance 3 producer
        xor   x21, x20, x19
        li    x31, 0x0000FFFF
        bne   x21, x31, fail

#--------------------------------------------------------------- store data through H1/H2
        li    x22, 0xDEADBEEF
        sw    x22, 0(x29)               # H1 as store data
        lw    x23, 0(x29)
        li    x31, 0xDEADBEEF
        bne   x23, x31, fail

        li    x24, 0x0BADF00D
        li    x25, 0
        sw    x24, 4(x29)               # H2 as store data
        lw    x26, 4(x29)
        li    x31, 0x0BADF00D
        bne   x26, x31, fail

#--------------------------------------------------------------- store address
        li    x1, 0x2000
        addi  x1, x1, 8                 # address produced one before
        sw    x22, 0(x1)                # H1 into the address operand
        lw    x2, 8(x29)
        bne   x2, x22, fail

#--------------------------------------------------------------- branch operand
        li    x3, 0x40
        addi  x3, x3, 0                 # H1 feeding a branch
        beq   x3, x3, br_ok
        j     fail
br_ok:

#--------------------------------------------------------------- load -> use at distance 2
        li    x4, 0x5150
        sw    x4, 16(x29)
        li    x5, 0                     # filler between load and use
        lw    x6, 16(x29)
        add   x7, x6, x0                # consumer two after the load: H2
        bne   x7, x4, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
