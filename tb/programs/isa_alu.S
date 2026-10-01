# isa_alu.S -- every R-type instruction (ADD SUB SLL SLT SLTU XOR SRL SRA OR AND)
# with directed operands, signed/unsigned boundaries and shift-amount wrap.
#
# Convention used by all programs in this directory:
#   x30 = putchar MMIO, x28 = halt MMIO, x29 = data area, x31 = expected value
#   a failing check prints 'F' and halts with code 1, success prints 'P'.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- ADD / SUB
        li    x1, 5
        li    x2, 7
        add   x3, x1, x2                # 12
        li    x31, 12
        bne   x3, x31, fail
        sub   x4, x2, x1                # 2
        li    x31, 2
        bne   x4, x31, fail

        li    x1, 0xFFFFFFFF            # -1
        li    x2, 1
        add   x3, x1, x2                # 0
        bne   x3, x0, fail
        sub   x4, x1, x1                # 0
        bne   x4, x0, fail

        li    x1, 0x80000000            # INT_MIN
        li    x2, 0x7FFFFFFF            # INT_MAX
        add   x3, x1, x2                # 0xFFFFFFFF
        li    x31, 0xFFFFFFFF
        bne   x3, x31, fail
        sub   x4, x2, x1                # 0xFFFFFFFF  (INT_MAX - INT_MIN)
        bne   x4, x31, fail

#--------------------------------------------------------------- SLL / SRL / SRA
        li    x1, 1
        li    x2, 4
        sll   x3, x1, x2                # 16
        li    x31, 16
        bne   x3, x31, fail

        li    x1, 0xF0000000
        li    x2, 4
        srl   x3, x1, x2                # 0x0F000000
        li    x31, 0x0F000000
        bne   x3, x31, fail
        sra   x4, x1, x2                # 0xFF000000
        li    x31, 0xFF000000
        bne   x4, x31, fail

        li    x1, 0x80000000
        li    x2, 31
        srl   x3, x1, x2                # 1
        li    x31, 1
        bne   x3, x31, fail
        sra   x4, x1, x2                # 0xFFFFFFFF
        li    x31, 0xFFFFFFFF
        bne   x4, x31, fail

        li    x1, 0x12345678
        li    x2, 0
        sll   x3, x1, x2                # shift by 0
        bne   x3, x1, fail
        srl   x4, x1, x2
        bne   x4, x1, fail
        sra   x5, x1, x2
        bne   x5, x1, fail

        # RV32I takes rs2[4:0]: shift by 32 is a shift by 0, 33 is a shift by 1
        li    x2, 32
        sll   x3, x1, x2
        bne   x3, x1, fail
        li    x2, 33
        sll   x3, x1, x2                # 0x2468ACF0
        li    x31, 0x2468ACF0
        bne   x3, x31, fail

#--------------------------------------------------------------- SLT / SLTU
        li    x1, 0xFFFFFFFF            # -1
        li    x2, 1
        slt   x3, x1, x2                # signed: -1 < 1  -> 1
        li    x31, 1
        bne   x3, x31, fail
        sltu  x4, x1, x2                # unsigned: 0xFFFFFFFF < 1 -> 0
        bne   x4, x0, fail

        li    x1, 0x80000000
        li    x2, 0x7FFFFFFF
        slt   x3, x1, x2                # signed: INT_MIN < INT_MAX -> 1
        li    x31, 1
        bne   x3, x31, fail
        sltu  x4, x1, x2                # unsigned: 0x80000000 < 0x7FFFFFFF -> 0
        bne   x4, x0, fail

        li    x1, 7
        li    x2, 7
        slt   x3, x1, x2                # equal -> 0
        bne   x3, x0, fail
        sltu  x4, x1, x2
        bne   x4, x0, fail

#--------------------------------------------------------------- XOR / OR / AND
        li    x1, 0xF0F0F0F0
        li    x2, 0x0FF00FF0
        xor   x3, x1, x2                # 0xFF00FF00
        li    x31, 0xFF00FF00
        bne   x3, x31, fail
        or    x4, x1, x2                # 0xFFF0FFF0
        li    x31, 0xFFF0FFF0
        bne   x4, x31, fail
        and   x5, x1, x2                # 0x00F000F0
        li    x31, 0x00F000F0
        bne   x5, x31, fail

        li    x1, 0
        li    x2, 0xFFFFFFFF
        xor   x3, x1, x2
        bne   x3, x2, fail
        or    x4, x1, x1
        bne   x4, x0, fail
        and   x5, x2, x1
        bne   x5, x0, fail

#--------------------------------------------------------------- result
        li    x31, 80                   # 'P'
        sb    x31, 0(x30)
        sw    x0, 0(x28)                # halt 0

fail:
        li    x31, 70                   # 'F'
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)               # halt 1
