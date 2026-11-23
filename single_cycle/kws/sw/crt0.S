# crt0.S - bare-metal start-up for the programs in this folder.
# Sets the stack pointer, clears .bss, calls main, then stops with ebreak.
# .rodata and .data need no copying: the data-memory image already holds them.
    .section .text.init, "ax"
    .globl  _start
_start:
    la      sp, __stack_top
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:  call    main
    ebreak
