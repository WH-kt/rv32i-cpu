# hazard_store.S -- store data and store address hazards (H6 route).
#
# Store data is resolved in EX by the same forwarding network as any other
# operand, so the distance 1/2/3 cases must all be right, for every width.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- distance 1, all widths
        li    x1, 0x000000A5
        sb    x1, 0(x29)                # H1 store data (byte)
        lbu   x2, 0(x29)
        li    x31, 0xA5
        bne   x2, x31, fail

        li    x3, 0x0000BEEF
        sh    x3, 4(x29)                # H1 store data (half)
        lhu   x4, 4(x29)
        li    x31, 0xBEEF
        bne   x4, x31, fail

        li    x5, 0x10C0FFEE
        sw    x5, 8(x29)                # H1 store data (word)
        lw    x6, 8(x29)
        bne   x6, x5, fail

#--------------------------------------------------------------- distance 2
        li    x7, 0x22223333
        li    x8, 0                     # filler
        sw    x7, 16(x29)               # H2 store data
        lw    x9, 16(x29)
        bne   x9, x7, fail

#--------------------------------------------------------------- distance 3 (write-through)
        li    x10, 0x44445555
        li    x11, 0
        li    x12, 0
        sw    x10, 24(x29)              # store data from a distance 3 producer
        lw    x13, 24(x29)
        bne   x13, x10, fail

#--------------------------------------------------------------- store address distances
        li    x14, 0x2000
        sh    x3, 8(x14)                # H1 address
        lhu   x15, 8(x14)
        li    x31, 0xBEEF
        bne   x15, x31, fail

        li    x16, 0x2000
        li    x17, 0
        sw    x5, 20(x16)               # H2 address
        lw    x18, 20(x16)
        bne   x18, x5, fail

#--------------------------------------------------------------- store then load, same address
        li    x19, 0x0F0F0F0F
        sw    x19, 32(x29)
        lw    x20, 32(x29)              # the load's MEM cycle is after the store's
        bne   x20, x19, fail
        sb    x0, 33(x29)               # partial overwrite
        lw    x21, 32(x29)
        li    x31, 0x0F0F000F
        bne   x21, x31, fail

#--------------------------------------------------------------- load -> store -> load chain
        li    x22, 0x76543210
        sw    x22, 40(x29)
        lw    x23, 40(x29)              # stalls the next store
        sw    x23, 44(x29)
        lw    x24, 44(x29)
        bne   x24, x22, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
