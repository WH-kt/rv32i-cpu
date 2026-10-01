# hazard_wbthru.S -- the register file write-through path (hazard H3).
#
# A consumer three instructions behind its producer reads the register file in
# ID during the very cycle the producer writes it in WB.  Both forwarding paths
# are already out of reach by then, so without the write-through bypass the
# consumer silently reads the stale value.  This is the hazard that uniform
# random testing almost never produces, so it is pinned down explicitly here
# for an ALU producer and for a load producer.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- ALU producer, rs1
        li    x1, 0x11110000
        li    x2, 0x00002222
        li    x3, 0                      # filler (index 2)
        add   x4, x1, x2                 # producer (index 0)
        li    x5, 0                      # filler (index 1)
        add   x6, x4, x3                 # consumer at distance 3 -> H3
        li    x31, 0x11112222
        bne   x6, x31, fail

#--------------------------------------------------------------- ALU producer, rs2
        li    x7, 0x0000FFFF
        li    x8, 0
        li    x9, 0
        or    x10, x7, x8                # producer
        li    x11, 0xFFFF0000
        xor   x12, x11, x10              # consumer at distance 3 (rs2 position)
        li    x31, 0xFFFFFFFF
        bne   x12, x31, fail

#--------------------------------------------------------------- load producer, distance 3
        li    x13, 0xCAFEBABE
        sw    x13, 0(x29)
        lw    x14, 0(x29)                # producer is a load
        li    x15, 1                     # filler
        li    x16, 2                     # filler
        add   x17, x14, x15              # consumer at distance 3 -> H3
        li    x31, 0xCAFEBABF
        bne   x17, x31, fail

#--------------------------------------------------------------- store data at distance 3
        li    x18, 0x5A5A5A5A
        li    x19, 0
        li    x20, 0
        addi  x21, x18, 1                # producer (0x5A5A5A5B)
        li    x22, 0
        sw    x21, 4(x29)                # store data from a distance 3 producer
        lw    x23, 4(x29)
        li    x31, 0x5A5A5A5B
        bne   x23, x31, fail

#--------------------------------------------------------------- branch operand at distance 3
        li    x24, 7
        li    x25, 0
        li    x26, 0
        addi  x27, x24, 1                # producer -> 8
        li    x1, 0
        beq   x27, x27, wt_ok            # consumer at distance 3 (self compare)
        j     fail
wt_ok:

#--------------------------------------------------------------- chain of distance 3
        # every instruction below consumes a value produced three slots earlier,
        # so the whole chain runs back to back through the write-through path
        li    x2, 1
        li    x3, 1
        li    x4, 1
        add   x5, x2, x3                 # 2
        add   x6, x5, x4                 # 3
        add   x7, x6, x5                 # 5
        add   x8, x7, x6                 # 8
        add   x9, x8, x7                 # 13
        li    x31, 13
        bne   x9, x31, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
