# halt_drain.S -- a system halt must not let younger work commit.
#
# The halt store reaches the MEM stage while younger instructions are still in
# EX/ID/IF.  Those younger instructions must be squashed: the halt means "stop
# now", so neither the register write nor the second store may happen.  The
# older store (already committed) must be visible in the final memory image.

        li    x28, 0x10000004
        li    x29, 0x2000

        li    x1, 0x5A5A5A5A
        sw    x1, 0(x29)                # older: commits before the halt

        sw    x0, 0(x28)                # halt, code 0

        li    x2, 0xFFFFFFFF            # younger: must not reach the register file
        sw    x2, 4(x29)                # younger: must not reach memory
