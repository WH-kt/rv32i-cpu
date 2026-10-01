# corner.S -- boundary cases that directed instruction tests do not cover:
# arithmetic wrap-around, address wrap-around, unmapped accesses, the last word
# of memory, branches to the next instruction, and large immediate splits.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- arithmetic wrap
        li    x1, 0x7FFFFFFF
        addi  x2, x1, 1                 # wraps to 0x80000000
        li    x31, 0x80000000
        bne   x2, x31, fail
        li    x3, 0x80000000
        addi  x4, x3, -1                # wraps to 0x7FFFFFFF
        li    x31, 0x7FFFFFFF
        bne   x4, x31, fail
        sub   x5, x0, x3                # 0 - INT_MIN = INT_MIN
        li    x31, 0x80000000
        bne   x5, x31, fail

#--------------------------------------------------------------- lui / addi split edges
        li    x6, 0x000007FF
        li    x31, 0x000007FF
        bne   x6, x31, fail
        li    x6, 0x00000800            # bit 11 set: the classic rounding trap
        li    x31, 0x00000800
        bne   x6, x31, fail
        li    x6, 0xFFFFF800
        li    x31, 0xFFFFF800
        bne   x6, x31, fail
        li    x6, 0x7FFFFFFF
        li    x31, 0x7FFFFFFF
        bne   x6, x31, fail
        li    x6, 0x80000000
        li    x31, 0x80000000
        bne   x6, x31, fail

#--------------------------------------------------------------- last word of memory
        li    x7, 0xFFFC                # last aligned word of the 64 KiB RAM
        li    x8, 0x13572468
        sw    x8, 0(x7)
        lw    x9, 0(x7)
        bne   x9, x8, fail

#--------------------------------------------------------------- just past memory
        li    x10, 0x10000              # one past the RAM: reads 0, writes ignored
        lw    x11, 0(x10)
        bne   x11, x0, fail
        li    x12, 0xDEADBEEF
        sw    x12, 0(x10)
        lw    x13, 0(x10)
        bne   x13, x0, fail

#--------------------------------------------------------------- far unmapped address
        li    x14, 0xFFFF0000
        lw    x15, 0(x14)
        bne   x15, x0, fail
        sw    x12, 4(x14)
        lw    x16, 4(x14)
        bne   x16, x0, fail

#--------------------------------------------------------------- address wrap-around
        li    x17, 0xFFFFFFFC
        lw    x18, 8(x17)               # address 4: reads the instruction word
        la    x19, corner_next
corner_next:
        # the word at address 4 is the second instruction of the program; it is
        # the same value in both memories, so the load must succeed
        li    x31, 0
        beq   x18, x0, fail             # must not be zero
        lw    x20, 4(x0)
        bne   x18, x20, fail

#--------------------------------------------------------------- branch to the next instruction
        beq   x0, x0, cn_a
cn_a:
        bne   x0, x0, fail              # never taken
        jal   x21, cn_b                 # jump over nothing
cn_b:
        la    x31, cn_b
        bne   x21, x31, fail

#--------------------------------------------------------------- shift by 31 and 0 on the same value
        li    x22, 1
        slli  x23, x22, 31
        srli  x24, x23, 31
        bne   x24, x22, fail
        srai  x25, x23, 31
        li    x31, 0xFFFFFFFF
        bne   x25, x31, fail

#--------------------------------------------------------------- x0 arithmetic identities
        sub   x26, x0, x0
        bne   x26, x0, fail
        xor   x27, x0, x0
        bne   x27, x0, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
