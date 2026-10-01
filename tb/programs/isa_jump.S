# isa_jump.S -- JAL and JALR: link values, targets, computed jumps, nested
# calls and returns, and the jalr target bit-0 clearing rule.

        li    x30, 0x10000000
        li    x28, 0x10000004
        li    x29, 0x2000

#--------------------------------------------------------------- JAL link value
        # the link register must hold the address of the instruction after the
        # jal; check it against a label the assembler resolves independently
        jal   x1, jal_sub
jal_back:
        la    x31, jal_back
        bne   x1, x31, fail

#--------------------------------------------------------------- JALR link value
        la    x2, jalr_sub
        jalr  x3, x2, 0
jalr_back:
        la    x31, jalr_back
        bne   x3, x31, fail

#--------------------------------------------------------------- JALR with offset
        la    x4, off_sub
        addi  x4, x4, 4                 # skip the first instruction of the sub
        jalr  x5, x4, 0
jalr_off_back:
        li    x31, 1
        bne   x6, x31, fail             # the skipped-first form sets x6 = 1

#--------------------------------------------------------------- nested calls
        li    x7, 0
        jal   x8, outer
        li    x31, 3
        bne   x7, x31, fail             # outer + inner + inner2 increments

#--------------------------------------------------------------- jump table
        la    x10, jtab
        li    x11, 2                    # index
        slli  x11, x11, 2               # * 4
        add   x10, x10, x11
        lw    x12, 0(x10)               # address of case 2
        jalr  x13, x12, 0
jt_done:
        li    x31, 0x2222
        bne   x14, x31, fail
        j     jt_ok
jt_case0:
        li    x14, 0x0000
        j     jt_done
jt_case1:
        li    x14, 0x1111
        j     jt_done
jt_case2:
        li    x14, 0x2222
        j     jt_done
jt_ok:

#--------------------------------------------------------------- loop + call
        li    x15, 0
        li    x16, 4
        jal   x17, count
        li    x31, 10                   # 4 + 3 + 2 + 1
        bne   x15, x31, fail

#--------------------------------------------------------------- result
        li    x31, 80
        sb    x31, 0(x30)
        sw    x0, 0(x28)

fail:
        li    x31, 70
        sb    x31, 0(x30)
        li    x31, 1
        sw    x31, 0(x28)

#--------------------------------------------------------------- subroutines
jal_sub:
        li    x9, 1
        jr    x1                        # jalr x0, x1, 0

jalr_sub:
        li    x6, 0
        li    x6, 1
        jr    x3

off_sub:
        li    x6, 0                     # skipped by the offset jalr above
        li    x6, 1
        jr    x5

outer:
        addi  x7, x7, 1
        jal   x18, inner
        addi  x7, x7, 1
        jr    x8
inner:
        addi  x7, x7, 1
        jr    x18

count:                                  # sum x16 .. 1 into x15, then return
        beq   x16, x0, count_done
        add   x15, x15, x16
        addi  x16, x16, -1
        j     count
count_done:
        jr    x17

        .align 2
jtab:
        .word jt_case0
        .word jt_case1
        .word jt_case2
