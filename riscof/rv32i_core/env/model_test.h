// model_test.h - the "model" macros riscv-arch-test needs from THIS core.
// Every test does  #include "model_test.h"  and then uses these names.
// They describe how this particular target boots, halts and marks its
// signature. Spike has its own copy in ../../spike/env/.
#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

// Extra data placed in front of the signature. This core does not use any
// of it; it is copied from Spike's model_test.h on purpose, so that the DUT
// ELF and the Spike ELF have the SAME addresses for code and data. Then a
// trace of the core and a Spike log can be compared line by line.
#define RVMODEL_DATA_SECTION                                            \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

// End of test. riscv_core raises dbg_system for ecall/ebreak and
// tb_riscof stops there, so ebreak is the halt. The loop after it is a
// safety net: if ebreak were ever ignored, the PC stays here instead of
// running off into data. Four instructions, the same length as Spike's
// halt, so nothing after it moves.
#define RVMODEL_HALT                                                    \
  fence;                                                                \
  ebreak;                                                               \
rvmodel_halt_loop:                                                      \
  j rvmodel_halt_loop;                                                  \
  nop;

// Code that runs before the test. The core starts at 0x80000000 with
// all registers zero, so nothing is needed.
#define RVMODEL_BOOT

// Start of the signature region. The label is global so that nm (and
// tools/run_test.py) can find its address in the ELF.
#define RVMODEL_DATA_BEGIN                                              \
  RVMODEL_DATA_SECTION                                                  \
  .align 4;                                                             \
  .global begin_signature; begin_signature:

// End of the signature region (one past the last word).
#define RVMODEL_DATA_END                                                \
  .align 4;                                                             \
  .global end_signature; end_signature:

// Console output macros. This core has no UART, so they expand to nothing.
#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

// Interrupt macros, used only by the privileged/interrupt tests.
// This core has no interrupts, so they are empty.
#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif // _COMPLIANCE_MODEL_H
