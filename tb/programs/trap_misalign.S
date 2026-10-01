# trap_misalign.S -- a misaligned halfword load traps with cause 4 and the
# faulting address, and performs no memory access at all.
#
# This is an EXPECTED-FILE test: RV32I allows either trapping or handling
# misaligned accesses in hardware, this core traps, while the reference model is
# byte granular and executes the access.  The checked in .expected file is
# therefore the authority here (see docs/06-verification-plan.md section 2).

        li    x29, 0x2000

        li    x1, 0x11223344
        sw    x1, 0(x29)                # older store: commits

        lb    x2, 1(x29)                # aligned byte access: fine
        lh    x3, 1(x29)                # odd address: trap cause 4, tval = 0x2001

        li    x4, 0x5555                # younger: squashed
        sw    x4, 4(x29)                # younger: squashed
