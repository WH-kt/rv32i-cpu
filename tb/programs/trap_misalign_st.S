# trap_misalign_st.S -- a misaligned halfword store traps with cause 6 and must
# not modify memory, not even partially.
#
# EXPECTED-FILE test (the reference model is byte granular, see
# trap_misalign.S).  The checksum in the expected log is the authority that the
# store really did not happen.

        li    x29, 0x2000

        li    x1, 0x11223344
        sw    x1, 0(x29)                # older store: commits

        li    x2, 0xFFFFFFFF
        sh    x2, 3(x29)                # odd address: trap cause 6, tval = 0x2003

        li    x3, 0x6666                # younger: squashed
        sw    x3, 4(x29)                # younger: squashed
