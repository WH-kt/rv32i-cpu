# isa_upper.S -- LUI and AUIPC.
#
# AUIPC is PC relative.  The program checks it two ways: differences between
# adjacent auipc instructions (which pin down the PC dependency exactly), and a
# cross-check against the assembler's own absolute address of a label, which is
# computed by a completely different code path.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- LUI
        lui   x1, 0x12345               # 0x12345000
        li    x31, 0x12345000
        bne   x1, x31, fail
        lui   x2, 0xFFFFF               # 0xFFFFF000
        li    x31, 0xFFFFF000
        bne   x2, x31, fail
        lui   x3, 0                     # 0
        bne   x3, x0, fail
        lui   x4, 0x80000               # 0x80000000
        li    x31, 0x80000000
        bne   x4, x31, fail

#--------------------------------------------------------------- AUIPC
        # four back to back auipc instructions with known immediates
q0:     auipc x5, 0                     # pc + 0
        auipc x6, 0                     # pc + 4
        auipc x7, 0x10                  # pc + 4 + 0x10000
        auipc x8, 0xFFFFF               # pc + 4 - 0x1000

        sub   x9, x6, x5                # 4
        li    x31, 4
        bne   x9, x31, fail

        sub   x10, x7, x6               # 4 + 0x10000
        li    x31, 0x10004
        bne   x10, x31, fail

        sub   x11, x8, x7               # 4 - 0x1000 - 0x10000 = -69628
        li    x31, -69628
        bne   x11, x31, fail

        # cross-check the absolute value against the assembler's label value
        la    x12, q0
        bne   x12, x5, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)
