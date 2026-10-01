# trap_ecall.S -- ECALL is detected, reported with cause 11 and the PC of the
# instruction, and behaves precisely.  The reference model raises the same
# trap, so this is a differential test: log and state must match exactly.

        li    x29, 0x2000

        li    x1, 0xCAFEBABE
        sw    x1, 0(x29)                # older store: commits

        li    x2, 0x1111                # older work: commits
        ecall                           # trap, cause 11

        li    x3, 0x2222                # younger: squashed
        sw    x3, 4(x29)                # younger: squashed
