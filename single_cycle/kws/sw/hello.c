/* hello.c - tiny bring-up program: proves crt0, the linker script, the data image,
 * multiply, divide, the custom instructions and the marker all work on the core.
 * It writes 12 result bytes to kws_output, then a last marker.
 *
 * All three builds must give the same bytes: `python sim/run_tests.py kws` compares
 * them with hello_expect.hex at marker 3 (table: hello_layers.hex). */
#include <stdint.h>
#include "nn_insn.h"

extern int8_t  kws_output[12];
extern int32_t kws_label;

/* volatile, or the compiler folds them away and the image is never read */
static const volatile int8_t table[8] __attribute__((aligned(4))) = {1, -2, 3, -4, 5, -6, 7, -8};
static volatile int32_t initialised = 1000;   /* .data */
static volatile int32_t cleared;              /* .bss */

/* Keep the compiler from folding these at build time. */
static int32_t opaque(int32_t v)
{
    __asm__ volatile("" : "+r"(v));
    return v;
}

int main(void)
{
    uint32_t a = *(const volatile uint32_t *)table;
    int32_t  acc = opaque(-100);
    int32_t  sum = 0;
    int32_t  product = opaque(-1234) * opaque(5678);          /* -7006652 */
    int64_t  wide = (int64_t)opaque(-2000000000) * opaque(3); /* -6000000000 */
    int32_t  quotient = (opaque(-16000) - 62) / 125;          /* -128 */

    mark(0);
    for (int i = 0; i < 8; i++) sum += table[i];              /* -4 */
    mark(1);
#ifdef HAVE_NN
    acc = dot4_s8(acc, a, a);                                 /* -100 + 1+4+9+16 = -70 */
    int32_t low = clip_s8(opaque(-129));
    int32_t high = clip_s8(opaque(128));
#else
    int8_t *p = (int8_t *)&a;
    for (int i = 0; i < 4; i++) acc += p[i] * p[i];
    int32_t low = -128, high = 127;
#endif
    mark(2);
    kws_output[0] = (int8_t)sum;
    kws_output[1] = (int8_t)acc;
    kws_output[2] = (int8_t)low;
    kws_output[3] = (int8_t)high;
    kws_output[4] = (int8_t)(product >> 16);                  /* product = 0xFF951644 */
    kws_output[5] = (int8_t)(product >> 8);
    kws_output[6] = (int8_t)product;
    kws_output[7] = (int8_t)(wide >> 32);                     /* wide = 0xFFFFFFFE_9A5F4400 */
    kws_output[8] = (int8_t)(wide >> 24);
    kws_output[9] = (int8_t)quotient;
    kws_output[10] = (int8_t)(initialised / 10);              /* 100 */
    kws_output[11] = (int8_t)cleared;                         /* 0 */
    kws_label = sum + acc + product + quotient;
    mark(3);
    return 0;
}
