# smoke.s - whole-core smoke test for the single-cycle RV32I core (tb_core.sv).
#
# Hand-encoded: there is no assembler in this iteration. Every line shows
# [byte address] machine word, then the expected effect. smoke.hex holds the
# words in order, one per line, loaded into imem at address 0.
#
# Layout of results:
#   sig[k] = dmem word at 0x200 + 4k  (arithmetic results, checked by tb_core)
#   x4..x19 : load/store results       x20/x21 : branch outcomes
#   x22..x24: backward-branch loop     x25..x29: jal / jalr
#   x30, sig[23]: writes to x0 are ignored
# The program ends with ebreak (tb_core stops on the `system` signal).
        addi  x31, x0, 0x200    # [000] 20000f93  x31 = signature base 0x200
        addi  x1, x0, 5         # [004] 00500093  x1 = 5
        addi  x2, x0, -3        # [008] ffd00113  x2 = 0xFFFFFFFD (bit 30 of imm set: catches the OP_IMM funct7_5 bug)
        add   x3, x1, x2        # [00c] 002081b3  2
        sw    x3, 0(x31)        # [010] 003fa023  sig[0]  = 0x00000002
        sub   x3, x1, x2        # [014] 402081b3  8
        sw    x3, 4(x31)        # [018] 003fa223  sig[1]  = 0x00000008
        sll   x3, x1, x1        # [01c] 001091b3  5 << 5
        sw    x3, 8(x31)        # [020] 003fa423  sig[2]  = 0x000000A0
        slt   x3, x2, x1        # [024] 001121b3  -3 < 5 signed
        sw    x3, 12(x31)       # [028] 003fa623  sig[3]  = 0x00000001
        sltu  x3, x2, x1        # [02c] 001131b3  0xFFFFFFFD < 5 unsigned
        sw    x3, 16(x31)       # [030] 003fa823  sig[4]  = 0x00000000
        xor   x3, x1, x2        # [034] 0020c1b3
        sw    x3, 20(x31)       # [038] 003faa23  sig[5]  = 0xFFFFFFF8
        srl   x3, x2, x1        # [03c] 001151b3  logical: zeros in
        sw    x3, 24(x31)       # [040] 003fac23  sig[6]  = 0x07FFFFFF
        sra   x3, x2, x1        # [044] 401151b3  arithmetic: sign in
        sw    x3, 28(x31)       # [048] 003fae23  sig[7]  = 0xFFFFFFFF
        or    x3, x1, x2        # [04c] 0020e1b3
        sw    x3, 32(x31)       # [050] 023fa023  sig[8]  = 0xFFFFFFFD
        and   x3, x1, x2        # [054] 0020f1b3
        sw    x3, 36(x31)       # [058] 023fa223  sig[9]  = 0x00000005
        slti  x3, x2, -2        # [05c] ffe12193  -3 < -2
        sw    x3, 40(x31)       # [060] 023fa423  sig[10] = 0x00000001
        sltiu x3, x1, -1        # [064] fff0b193  5 < 0xFFFFFFFF unsigned
        sw    x3, 44(x31)       # [068] 023fa623  sig[11] = 0x00000001
        xori  x3, x1, -1        # [06c] fff0c193  ~5
        sw    x3, 48(x31)       # [070] 023fa823  sig[12] = 0xFFFFFFFA
        ori   x3, x1, 0x7F0     # [074] 7f00e193
        sw    x3, 52(x31)       # [078] 023faa23  sig[13] = 0x000007F5
        andi  x3, x2, 0xF0      # [07c] 0f017193
        sw    x3, 56(x31)       # [080] 023fac23  sig[14] = 0x000000F0
        slli  x3, x1, 31        # [084] 01f09193
        sw    x3, 60(x31)       # [088] 023fae23  sig[15] = 0x80000000
        srli  x3, x2, 28        # [08c] 01c15193
        sw    x3, 64(x31)       # [090] 043fa023  sig[16] = 0x0000000F
        srai  x3, x2, 1         # [094] 40115193  -3 >> 1 = -2
        sw    x3, 68(x31)       # [098] 043fa223  sig[17] = 0xFFFFFFFE
        lui   x3, 0x12345       # [09c] 123451b7
        addi  x3, x3, 0x678     # [0a0] 67818193
        sw    x3, 72(x31)       # [0a4] 043fa423  sig[18] = 0x12345678
        lui   x3, 0xFFFFF       # [0a8] fffff1b7  U-imm is not sign-extended, low 12 bits zero
        sw    x3, 76(x31)       # [0ac] 043fa623  sig[19] = 0xFFFFF000
auipc1: auipc x3, 1             # [0b0] 00001197  pc + 0x1000
        sw    x3, 80(x31)       # [0b4] 043fa823  sig[20] = auipc1 + 0x1000
        lui   x3, 0x80000       # [0b8] 800001b7
        addi  x3, x3, -1        # [0bc] fff18193  0x7FFFFFFF
        sw    x3, 84(x31)       # [0c0] 043faa23  sig[21] = 0x7FFFFFFF
        add   x3, x3, x1        # [0c4] 001181b3  overflow wraps
        sw    x3, 88(x31)       # [0c8] 043fac23  sig[22] = 0x80000004
        addi  x4, x0, 0x100     # [0cc] 10000213  x4 = data base 0x100
        lui   x5, 0x12345       # [0d0] 123452b7
        addi  x5, x5, 0x678     # [0d4] 67828293  x5 = 0x12345678
        sw    x5, 0(x4)         # [0d8] 00522023  M[0x100] = 12345678
        sw    x5, -4(x4)        # [0dc] fe522e23  M[0x0FC] = 12345678 (negative S offset)
        addi  x6, x0, 0x80      # [0e0] 08000313  x6 = 0x80
        sb    x6, 1(x4)         # [0e4] 006200a3  M[0x100] = 12348078
        addi  x7, x0, -1        # [0e8] fff00393  x7 = 0xFFFFFFFF
        sb    x7, 3(x4)         # [0ec] 007201a3  M[0x100] = FF348078
        lui   x8, 0x8           # [0f0] 00008437  x8 = 0x00008000
        sh    x8, 6(x4)         # [0f4] 00821323  M[0x104] = 80000000
        sh    x7, 4(x4)         # [0f8] 00721223  M[0x104] = 8000FFFF
        lw    x9, 0(x4)         # [0fc] 00022483  x9  = FF348078
        lb    x10, 1(x4)        # [100] 00120503  x10 = FFFFFF80 (sign-extended)
        lbu   x11, 1(x4)        # [104] 00124583  x11 = 00000080 (zero-extended)
        lb    x12, 2(x4)        # [108] 00220603  x12 = 00000034
        lbu   x13, 3(x4)        # [10c] 00324683  x13 = 000000FF
        lh    x14, 6(x4)        # [110] 00621703  x14 = FFFF8000
        lhu   x15, 6(x4)        # [114] 00625783  x15 = 00008000
        lh    x16, 0(x4)        # [118] 00021803  x16 = FFFF8078
        lhu   x17, 4(x4)        # [11c] 00425883  x17 = 0000FFFF
        lw    x18, 4(x4)        # [120] 00422903  x18 = 8000FFFF
        lw    x19, -4(x4)       # [124] ffc22983  x19 = 12345678 (negative I offset)
        addi  x20, x0, 0        # [128] 00000a13  x20: one bit per correctly NOT-taken branch
        addi  x21, x0, 0        # [12c] 00000a93  x21: error count (wrong path executed)
        beq   x1, x1, c1        # [130] 00108463  taken
        addi  x21, x21, 1       # [134] 001a8a93  (must be skipped)
c1:     beq   x1, x2, c2        # [138] 00208463  not taken
        ori   x20, x20, 1       # [13c] 001a6a13
c2:     bne   x1, x2, c3        # [140] 00209463  taken
        addi  x21, x21, 1       # [144] 001a8a93  (must be skipped)
c3:     bne   x1, x1, c4        # [148] 00109463  not taken
        ori   x20, x20, 2       # [14c] 002a6a13
c4:     blt   x2, x1, c5        # [150] 00114463  taken: -3 < 5 signed
        addi  x21, x21, 1       # [154] 001a8a93  (must be skipped)
c5:     blt   x1, x2, c6        # [158] 0020c463  not taken
        ori   x20, x20, 4       # [15c] 004a6a13
c6:     bge   x1, x2, c7        # [160] 0020d463  taken: 5 >= -3
        addi  x21, x21, 1       # [164] 001a8a93  (must be skipped)
c7:     bge   x1, x1, c8        # [168] 0010d463  taken: equal
        addi  x21, x21, 1       # [16c] 001a8a93  (must be skipped)
c8:     bge   x2, x1, c9        # [170] 00115463  not taken
        ori   x20, x20, 8       # [174] 008a6a13
c9:     bltu  x1, x2, c10       # [178] 0020e463  taken: 5 < 0xFFFFFFFD unsigned
        addi  x21, x21, 1       # [17c] 001a8a93  (must be skipped)
c10:    bltu  x2, x1, c11       # [180] 00116463  not taken
        ori   x20, x20, 16      # [184] 010a6a13
c11:    bgeu  x2, x1, c12       # [188] 00117463  taken
        addi  x21, x21, 1       # [18c] 001a8a93  (must be skipped)
c12:    bgeu  x1, x2, c13       # [190] 0020f463  not taken
        ori   x20, x20, 32      # [194] 020a6a13  -> x20 = 0x3F, x21 = 0
c13:    addi  x22, x0, 0        # [198] 00000b13  x22: loop counter
        addi  x23, x0, 10       # [19c] 00a00b93  x23 = 10
        addi  x24, x0, 0        # [1a0] 00000c13  x24: sum
loop:   addi  x22, x22, 1       # [1a4] 001b0b13
        add   x24, x24, x22     # [1a8] 016c0c33
        bne   x22, x23, loop    # [1ac] ff7b1ce3  backward branch -> x22 = 10, x24 = 55
jal1:   jal   x25, func         # [1b0] 00c00cef  call: x25 = jal1 + 4
        addi  x26, x26, 7       # [1b4] 007d0d13  after return: x26 = 107
        jal   x0, after         # [1b8] 00c0006f  j after
func:   addi  x26, x0, 100      # [1bc] 06400d13  x26 = 100
        jalr  x0, 0(x25)        # [1c0] 000c8067  return
after:  auipc x27, 0            # [1c4] 00000d97  x27 = after
        addi  x27, x27, 12      # [1c8] 00cd8d93  x27 = after + 12
        jalr  x28, 5(x27)       # [1cc] 005d8e67  x28 = after + 12; target (after+17) & ~1 = after + 16
        addi  x21, x21, 1       # [1d0] 001a8a93  (must be skipped)
        addi  x29, x0, 1        # [1d4] 00100e93  x29 = 1: landed on the cleared-bit target
        addi  x30, x0, 99       # [1d8] 06300f13  x30 = 99
        addi  x0, x1, 1         # [1dc] 00108013  write to x0: ignored
        lui   x0, 0x12345       # [1e0] 12345037  write to x0: ignored
        add   x30, x0, x0       # [1e4] 00000f33  x30 = 0
        add   x3, x0, x1        # [1e8] 001001b3  x3 = 5 only if x0 still reads 0
        sw    x3, 92(x31)       # [1ec] 043fae23  sig[23] = 0x00000005
        fence                   # [1f0] 0ff0000f  nop
        ebreak                  # [1f4] 00100073  stop
        word  0                 # [1f8] 00000000  never reached (would be illegal)
