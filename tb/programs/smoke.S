# smoke.S -- bring-up program: the smallest thing that exercises every
# functional block of the core (ALU, immediate, load/store, branch, jump,
# MMIO putchar, halt).  It prints "OK\n" and halts with code 0 when it passes,
# and halts with code 1 at the first failure.
#
# Assembled with tools/asm.py; the image is loaded into both memories, so the
# reference model (tools/iss.py) runs exactly the same words from address 0.

        .org 0

        li    x1, 3
        li    x2, 4
        add   x3, x1, x2            # x3 = 7
        sub   x4, x2, x1            # x4 = 1

        li    x5, 0x10000000        # simulation MMIO base
        li    x6, 79                # 'O'
        sb    x6, 0(x5)
        li    x6, 75                # 'K'
        sb    x6, 0(x5)
        li    x6, 10                # '\n'
        sb    x6, 0(x5)

        li    x7, 0x400             # data area, well past the code
        sw    x3, 0(x7)
        lw    x8, 0(x7)
        bne   x8, x3, fail

        jal   x9, addfn             # x10 <- 1 on return
        bne   x10, x4, fail

ok:
        li    x11, 0x10000004
        sw    x0, 0(x11)            # halt code 0

fail:
        li    x11, 1
        li    x12, 0x10000004
        sw    x11, 0(x12)           # halt code 1

addfn:
        li    x10, 1
        jr    x9                    # jalr x0, x9, 0
