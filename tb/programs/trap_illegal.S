# trap_illegal.S -- an encoding that RV32I does not define must be detected as
# an illegal instruction (cause 2), not executed as a no-op and not silently
# ignored.  0x00000000 is the canonical illegal encoding; the reference model
# reports it with the same text, so this is a differential test.
#
# Also exercised here: a CSR instruction (csrrs) belongs to Zicsr, which this
# core does not implement, so it must trap as illegal as well.  That case is
# checked in trap_csr.S because the reference model implements the counters.

        li    x29, 0x2000
        li    x1, 0x1234ABCD
        sw    x1, 0(x29)                # older store: commits

        .word 0x00000000                # illegal instruction

        li    x2, 0x9999                # younger: squashed
        sw    x2, 4(x29)                # younger: squashed
