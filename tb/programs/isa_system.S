# isa_system.S -- FENCE / FENCE.I (architectural NOPs in this core) and
# EBREAK (which halts with code 0, matching the reference model).

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- FENCE as NOP
        li    x1, 0x11112222
        fence
        add   x2, x1, x0                # fence must not disturb anything
        bne   x2, x1, fail
        fence
        fence.i
        sw    x1, 0(x29)
        fence
        lw    x3, 0(x29)
        bne   x3, x1, fail
        fence.i
        bne   x3, x1, fail

#--------------------------------------------------------------- result + EBREAK
        li    x31, 80
        sb    x31, 0(x30)
        ebreak                          # stops the run with HALT 00

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
