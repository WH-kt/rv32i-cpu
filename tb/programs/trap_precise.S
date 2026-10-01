# trap_precise.S -- trap precision.
#
# The ECALL must behave like a precise exception: every older instruction
# completes and commits, the ECALL itself and every younger instruction have no
# architectural effect at all.  The store right before the ECALL is in the MEM
# stage when the trap is taken, and the two stores after it are squashed, so
# the final memory image is decided entirely by the older store.  The reference
# model stops at the ECALL too, so its memory image must match exactly.
#
# Expected log (differential test, both sides):
#     TRAP ecall
#     CHECKSUM <value reflecting mem[0x2000] = 0x12345678, mem[0x2004] = 0>
#     STEPS <stores committed>

        li    x29, 0x2000

        # older work: must commit
        li    x1, 0x12345678
        sw    x1, 0(x29)

        ecall                           # precise trap here

        # younger work: must not commit (these are squashed in the pipeline)
        li    x2, 0xFFFFFFFF
        sw    x2, 4(x29)
        sw    x2, 8(x29)
        addi  x3, x0, 1
