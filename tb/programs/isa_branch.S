# isa_branch.S -- BEQ BNE BLT BGE BLTU BGEU: taken and not taken, forward and
# backward, and the signed/unsigned boundaries where the two disagree.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- BEQ / BNE
        li    x1, 5
        li    x2, 5
        beq   x1, x2, beq_t
        j     fail
beq_t:
        li    x2, 6
        beq   x1, x2, fail              # must not be taken
        bne   x1, x2, bne_t
        j     fail
bne_t:
        li    x2, 5
        bne   x1, x2, fail              # must not be taken
        beq   x0, x0, zero_eq           # x0 compares as zero
        j     fail
zero_eq:

#--------------------------------------------------------------- BLT / BGE (signed)
        li    x1, -1
        li    x2, 0
        blt   x1, x2, blt_t             # -1 < 0
        j     fail
blt_t:
        blt   x2, x1, fail              # 0 < -1 false
        bge   x2, x1, bge_t             # 0 >= -1
        j     fail
bge_t:
        bge   x1, x2, fail              # -1 >= 0 false
        blt   x2, x2, fail              # equal is not less
        bge   x2, x2, eq_ge             # equal is >=
        j     fail
eq_ge:

        li    x1, 0x80000000            # INT_MIN
        li    x2, 0x7FFFFFFF            # INT_MAX
        blt   x1, x2, blt_min           # signed: INT_MIN < INT_MAX
        j     fail
blt_min:
        bge   x2, x1, bge_max           # signed: INT_MAX >= INT_MIN
        j     fail
bge_max:

#--------------------------------------------------------------- BLTU / BGEU
        li    x1, 0x80000000
        li    x2, 0x7FFFFFFF
        bltu  x2, x1, bltu_t            # unsigned: 0x7FFFFFFF < 0x80000000
        j     fail
bltu_t:
        bgeu  x1, x2, bgeu_t            # unsigned: 0x80000000 >= 0x7FFFFFFF
        j     fail
bgeu_t:
        bltu  x1, x2, fail              # unsigned: 0x80000000 < 0x7FFFFFFF false
        bgeu  x2, x1, fail              # unsigned false

        li    x1, 0xFFFFFFFF
        li    x2, 1
        bltu  x2, x1, bltu_max          # 1 < 0xFFFFFFFF
        j     fail
bltu_max:
        bgeu  x1, x2, bgeu_max          # 0xFFFFFFFF >= 1
        j     fail
bgeu_max:
        bltu  x1, x2, fail
        bgeu  x2, x1, fail

#--------------------------------------------------------------- backward branch loop
        li    x3, 0                     # counter
        li    x4, 10                    # iterations
loop:
        addi  x3, x3, 1
        blt   x3, x4, loop              # backward, taken 9 times
        li    x31, 10
        bne   x3, x31, fail

        # a backward branch that is never taken
        li    x5, 0
        li    x6, 0
        bne   x5, x6, loop              # not taken
        beq   x5, x6, after_skip
        j     fail
after_skip:

#--------------------------------------------------------------- branch on a load result
        li    x7, 0x1234
        sw    x7, 0(x29)
        lw    x8, 0(x29)
        beq   x8, x7, ld_ok             # load-use hazard feeding a branch
        j     fail
ld_ok:

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
