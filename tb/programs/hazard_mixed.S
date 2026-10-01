# hazard_mixed.S -- squash behaviour around control transfers and stalls.
#
# Checks the parts of the pipeline control that only show up when several
# mechanisms interact: a redirect squashing the instruction behind it, a
# redirect squashing a pending store, a load-use stall immediately followed by
# a taken branch, and a halt that must not let in-flight work commit.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- redirect squashes the next insn
        li    x1, 0
        beq   x0, x0, mx_t1             # taken
        addi  x1, x1, 1                 # wrong path: must be squashed
        addi  x1, x1, 1                 # wrong path (second slot)
mx_t1:
        bne   x1, x0, fail

#--------------------------------------------------------------- redirect squashes a pending store
        li    x2, 0x11112222
        sw    x2, 0(x29)
        beq   x0, x0, mx_t2
        sw    x0, 0(x29)                # wrong path store: must not happen
        sw    x0, 4(x29)
mx_t2:
        lw    x3, 0(x29)
        bne   x3, x2, fail
        lw    x4, 4(x29)
        bne   x4, x0, fail

#--------------------------------------------------------------- jal squashes the next insn
        li    x5, 0
        jal   x6, mx_t3
mx_t3_link:                             # the link value is this address
        addi  x5, x5, 1                 # wrong path
mx_t3:
        bne   x5, x0, fail
        la    x31, mx_t3_link
        bne   x6, x31, fail

#--------------------------------------------------------------- load-use stall then taken branch
        li    x7, 0x33334444
        sw    x7, 8(x29)
        lw    x8, 8(x29)
        add   x9, x8, x0                # stall -> H2 forward
        beq   x9, x7, mx_t4             # taken immediately after the stall
        j     fail
mx_t4:
        bne   x9, x7, fail

#--------------------------------------------------------------- back to back redirects
        li    x10, 0
        beq   x0, x0, mx_t5
        j     fail
mx_t5:
        beq   x0, x0, mx_t6
        j     fail
mx_t6:
        jal   x11, mx_t7
mx_t7_link:                             # the link value is this address
        j     fail
mx_t7:
        la    x31, mx_t7_link
        bne   x11, x31, fail

#--------------------------------------------------------------- load-use chain in a loop
        li    x12, 0                     # accumulator
        li    x13, 5                     # iterations
        li    x14, 1
mx_loop:
        add   x12, x12, x14
        addi  x13, x13, -1
        bne   x13, x0, mx_loop          # backward branch, taken 5 times
        li    x31, 5
        bne   x12, x31, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
