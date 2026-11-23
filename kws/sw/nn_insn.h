/* nn_insn.h - the custom-0 instructions, as inline assembly (no compiler changes),
 * and the cycle marker. Encodings: see the README; kws/build.py checks them. */
#ifndef NN_INSN_H
#define NN_INSN_H

#include <stdint.h>

/* acc + sum over 4 lanes of signed byte a[i] * signed byte b[i]. rd is read and
 * written, so acc is "+r". */
static inline int32_t dot4_s8(int32_t acc, uint32_t a, uint32_t b)
{
    __asm__(".insn r 0x0B, 1, 0, %0, %1, %2" : "+r"(acc) : "r"(a), "r"(b));
    return acc;
}

/* Clamp to [-128, 127]. rs2 must be x0. */
static inline int32_t clip_s8(int32_t v)
{
    int32_t r;
    __asm__(".insn r 0x0B, 2, 0, %0, %1, x0" : "=r"(r) : "r"(v));
    return r;
}

/* Tell the testbench (or rv32iss) that layer n has finished: a store to
 * 0xFFFFFFF0. It must not be moved across the layer's stores, hence "memory". */
static inline void mark(uint32_t n)
{
    __asm__ volatile("sw %0, -16(zero)" : : "r"(n) : "memory");
}

#endif
