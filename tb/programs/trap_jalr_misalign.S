# trap_jalr_misalign.S -- a JALR target with bit 1 set is an instruction address
# misalignment (cause 0): the jump must not be taken and nothing may be
# committed, but the link register write must not happen either.
#
# EXPECTED-FILE test.

        li    x29, 0x2000
        li    x1, 0x1234
        sw    x1, 0(x29)                # older store: commits

        la    x2, tj_target
        addi  x2, x2, 2                 # force bit 1 -> misaligned target
        jalr  x3, x2, 0                 # trap cause 0, tval = target

        sw    x1, 4(x29)                # younger: squashed
tj_target:
        li    x4, 0x7777                # must not be reached
