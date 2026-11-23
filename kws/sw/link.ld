/* link.ld - memory map of the KWS programs (see the README).
 *
 * The core is Harvard: code is in instruction memory, and loads cannot read it,
 * so constant data lives in data memory. Each memory is indexed by the low
 * address bits only, so linking data at 0x1000_0000 needs no address decoder.
 *
 * The marker address 0xFFFFFFF0 aliases data-memory offset 0xFFF0, so that word
 * must stay unused: the stack starts below it, at 0x1000_FFE0.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  IMEM  (rx) : ORIGIN = 0x00000000, LENGTH = 32K
  ROM   (r)  : ORIGIN = 0x10000000, LENGTH = 36K   /* weights, biases, requant tables */
  ACT   (rw) : ORIGIN = 0x10009000, LENGTH = 0x5200 /* activation buffers (fixed, below) */
  DATA  (rw) : ORIGIN = 0x1000E200, LENGTH = 0x0E00 /* .data and .bss */
  IO    (rw) : ORIGIN = 0x1000F000, LENGTH = 1K    /* input and output buffers */
}

/* Activation buffers. */
buf_a       = 0x10009000;   /* 12,096 B: 27 x 7 x 64, padded with -128 */
buf_b       = 0x1000BF40;   /*  8,000 B: 25 x 5 x 64 */
input_pad   = 0x1000DE80;   /*    696 B: 58 x 12, padded with 83 */
pool_out    = 0x1000E140;   /*     64 B */

/* Input and output buffers, at fixed addresses for the host (later: the ARM side). */
kws_input   = 0x1000F000;   /* 490 B: the INT8 MFCC features, 49 x 10 */
kws_output  = 0x1000F200;   /*  12 B: the FC scores */
kws_label   = 0x1000F20C;   /*   4 B: index of the largest score */

/* The stack runs down from here to 0x1000_F400; 0x1000_FFF0 stays free (marker). */
__stack_top   = 0x1000FFE0;
__stack_limit = 0x1000F400;

SECTIONS
{
  .text : { KEEP(*(.text.init)) *(.text .text.*) } > IMEM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ROM
  .data : { *(.data .data.* .sdata .sdata.*) } > DATA
  .bss (NOLOAD) : {
    . = ALIGN(4);
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > DATA
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note .note.*) *(.eh_frame .eh_frame_hdr) }
}
