/* kws.c - the MLPerf Tiny keyword-spotting model (INT8 DS-CNN), bare metal.
 *
 * One source, three builds (kws/build.py):
 *   (a) RV32I: multiply and divide in software (libgcc)
 *   (b) + Zmmul (HAVE_ZMMUL): mul, mulh, mulhsu
 *   (c) + DOT4.S8 and CLIP.S8 (HAVE_NN)
 *
 * Every layer's output equals TFLite's reference int8 kernels byte for byte.
 * Two things make the loops simpler than TFLite's without changing the results:
 *   - The input zero point is folded into the bias offline
 *     (bias' = bias - zp * sum(w)), so the loops use raw input bytes. Padded
 *     inputs must then equal the zero point, so that (x - zp) = 0 there.
 *   - The SAME padding is real memory: the first conv reads a padded copy of the
 *     input, and depthwise reads buf_a, whose border is filled once with -128.
 *
 * Buffers (fixed addresses in link.ld):
 *   conv, pointwise output -> buf_a (27 x 7 x 64, the 25 x 5 x 64 result inside
 *                             a 1-pixel border)
 *   depthwise output       -> buf_b (25 x 5 x 64)
 * So depthwise always reads buf_a and writes buf_b, pointwise the reverse.
 *
 * The program stores the layer number to the marker address after each layer.
 */
#include <stdint.h>
#include "kws_tables.h"
#include "nn_insn.h"

/* Fixed addresses, from link.ld. */
extern const int8_t kws_input[490];
extern int8_t  kws_output[12];
extern int32_t kws_label;
extern int8_t  buf_a[12096], buf_b[8000], input_pad[696], pool_out[64];

#define CH        64
#define HEIGHT    25
#define WIDTH     5
#define ROW_A     (7 * CH)                    /* bytes per row of buf_a */
#define PIXEL_A(y, x)  (((y) + 1) * ROW_A + ((x) + 1) * CH)
#define INPUT_ZP  83
#define PAD_ROW   12                          /* bytes per row of input_pad */

/* TFLite's MultiplyByQuantizedMultiplier for 2^30 <= M < 2^31 and a right shift
 * e >= 1, in a shorter form. Both forms are exact; rq->m2 = 2 * M as a uint32:
 *   SaturatingRoundingDoublingHighMul(acc, M)
 *       = floor((acc * M + 2^30) / 2^31)         (the sign-dependent nudge cancels
 *                                                 against the truncating division)
 *       = floor(acc * M / 2^31) + bit 30 of (acc * M)
 *       = high word of (acc * m2) + top bit of the low word
 *   RoundingDivideByPOT(x, e)
 *       = (x + 2^(e-1) - (x < 0 ? 1 : 0)) >> e                                  */
static inline int32_t requant(int32_t acc, uint32_t m2, int32_t round, int32_t e)
{
    int64_t p = (int64_t)acc * (int64_t)(uint64_t)m2;
    int32_t high = (int32_t)(p >> 32) + (int32_t)((uint32_t)p >> 31);
    return (high + round + (high >> 31)) >> e;
}

/* The fully connected layer rounds once. TFLite's reference kernel for it takes
 * float scales and does round(acc * scale). For this model that equals
 *   (acc * M + 2^37) >> 38   =   (high word of (acc * m2) + 64) >> 7
 * on every accumulator an input can reach; check_ref.py tests the whole range. */
static inline int32_t requant_once(int32_t acc, uint32_t m2, int32_t round, int32_t e)
{
    int64_t p = (int64_t)acc * (int64_t)(uint64_t)m2;
    return ((int32_t)(p >> 32) + round) >> e;
}

/* For the pipelined core: a load's value is ready one cycle too late for the next
 * instruction, so an lw followed at once by the dot4.s8 that uses it costs a stall.
 * The DOT4.S8 loops therefore load each word one dot4.s8 ahead, into two variables in
 * turn. GCC would move the loads back next to their use; this empty barrier (it emits
 * no instruction) keeps every load where it is written. It saves about 550 k stall
 * cycles in build (c) and adds 0.2% instructions on the single-cycle core. */
#define LOAD_AHEAD() __asm__ volatile("" ::: "memory")

static inline int32_t clamp8(int32_t v)
{
#ifdef HAVE_NN
    return clip_s8(v);
#else
    if (v > 127) return 127;
    if (v < -128) return -128;
    return v;
#endif
}

/* ---- layer 1: CONV_2D 10x4, stride 2, 1 input channel --------------------- */
static void __attribute__((noinline)) first_conv(void)
{
    /* SAME padding: 4 rows above, 5 below, 1 column on each side. */
    const int8_t *src = kws_input;
    int8_t *row = input_pad + 4 * PAD_ROW + 1;
    for (int y = 0; y < 49; y++, row += PAD_ROW)
        for (int x = 0; x < 10; x++)
            row[x] = *src++;

    for (int y = 0; y < HEIGHT; y++) {
        for (int x = 0; x < WIDTH; x++) {
            const int8_t *p = input_pad + 2 * y * PAD_ROW + 2 * x;
            int8_t *dst = buf_a + PIXEL_A(y, x);
#ifdef HAVE_NN
            /* Every 4-tap row starts on an even byte. Load the window once for
             * this pixel and keep it in registers for all 64 filters. */
            uint32_t r0, r1, r2, r3, r4, r5, r6, r7, r8, r9;
            if (x & 1) {
#define HALVES(r) ((uint32_t)*(const uint16_t *)(p + (r) * PAD_ROW) | \
                   ((uint32_t)*(const uint16_t *)(p + (r) * PAD_ROW + 2) << 16))
                r0 = HALVES(0); r1 = HALVES(1); r2 = HALVES(2); r3 = HALVES(3); r4 = HALVES(4);
                r5 = HALVES(5); r6 = HALVES(6); r7 = HALVES(7); r8 = HALVES(8); r9 = HALVES(9);
            } else {
#define WORD(r) (*(const uint32_t *)(p + (r) * PAD_ROW))
                r0 = WORD(0); r1 = WORD(1); r2 = WORD(2); r3 = WORD(3); r4 = WORD(4);
                r5 = WORD(5); r6 = WORD(6); r7 = WORD(7); r8 = WORD(8); r9 = WORD(9);
            }
            const uint32_t *w = (const uint32_t *)conv0_w;
            for (int f = 0; f < CH; f++, w += 10) {
                int32_t acc = conv0_b[f];
                /* Each weight word is loaded one dot4.s8 ahead of its use (see LOAD_AHEAD). */
                uint32_t wa = w[0], wb;
                wb = w[1]; LOAD_AHEAD(); acc = dot4_s8(acc, r0, wa);
                wa = w[2]; LOAD_AHEAD(); acc = dot4_s8(acc, r1, wb);
                wb = w[3]; LOAD_AHEAD(); acc = dot4_s8(acc, r2, wa);
                wa = w[4]; LOAD_AHEAD(); acc = dot4_s8(acc, r3, wb);
                wb = w[5]; LOAD_AHEAD(); acc = dot4_s8(acc, r4, wa);
                wa = w[6]; LOAD_AHEAD(); acc = dot4_s8(acc, r5, wb);
                wb = w[7]; LOAD_AHEAD(); acc = dot4_s8(acc, r6, wa);
                wa = w[8]; LOAD_AHEAD(); acc = dot4_s8(acc, r7, wb);
                wb = w[9]; LOAD_AHEAD(); acc = dot4_s8(acc, r8, wa);
                                         acc = dot4_s8(acc, r9, wb);
                const rq_t *q = &conv0_rq[f];
                dst[f] = (int8_t)clamp8(requant(acc, q->m2, q->round, q->e) - 128);
            }
#else
            const int8_t *w = conv0_w[0];
            for (int f = 0; f < CH; f++, w += 40) {
                int32_t acc = conv0_b[f];
#define TAP(r, c) acc += w[(r) * 4 + (c)] * p[(r) * PAD_ROW + (c)];
#define TAPS(r)   TAP(r, 0) TAP(r, 1) TAP(r, 2) TAP(r, 3)
                TAPS(0) TAPS(1) TAPS(2) TAPS(3) TAPS(4) TAPS(5) TAPS(6) TAPS(7) TAPS(8) TAPS(9)
                const rq_t *q = &conv0_rq[f];
                dst[f] = (int8_t)clamp8(requant(acc, q->m2, q->round, q->e) - 128);
            }
#endif
        }
    }
}

/* ---- layers 2, 4, 6, 8: DEPTHWISE_CONV_2D 3x3 ----------------------------- */
/* A word holds 4 different channels, so DOT4.S8 does not apply: every build
 * multiplies. Hold one filter in registers and sweep the pixels. */
static void __attribute__((noinline)) depthwise(const int8_t (*weights)[9], const int32_t *bias, const rq_t *rq)
{
    for (int c = 0; c < CH; c++) {
        const int8_t *k = weights[c];
        const int32_t w0 = k[0], w1 = k[1], w2 = k[2], w3 = k[3], w4 = k[4], w5 = k[5],
                      w6 = k[6], w7 = k[7], w8 = k[8];
        const int32_t b = bias[c], m2 = (int32_t)rq[c].m2, round = rq[c].round, e = rq[c].e;
        const int8_t *s = buf_a + PIXEL_A(0, 0) + c;
        int8_t *d = buf_b + c;
        for (int y = 0; y < HEIGHT; y++, s += 2 * CH) {
            for (int x = 0; x < WIDTH; x++, s += CH, d += CH) {
                int32_t acc = b;
                acc += w0 * s[-ROW_A - CH];
                acc += w1 * s[-ROW_A];
                acc += w2 * s[-ROW_A + CH];
                acc += w3 * s[-CH];
                acc += w4 * s[0];
                acc += w5 * s[CH];
                acc += w6 * s[ROW_A - CH];
                acc += w7 * s[ROW_A];
                acc += w8 * s[ROW_A + CH];
                *d = (int8_t)clamp8(requant(acc, (uint32_t)m2, round, e) - 128);
            }
        }
    }
}

/* ---- layers 3, 5, 7, 9: CONV_2D 1x1 (pointwise) --------------------------- */
/* A 64-element dot product per output. Hold one filter in registers and sweep
 * the pixels; every channel count is a multiple of 4, so words fill all lanes. */
static void __attribute__((noinline)) pointwise(const int8_t (*weights)[64], const int32_t *bias, const rq_t *rq)
{
    for (int f = 0; f < CH; f++) {
        const int32_t b = bias[f], m2 = (int32_t)rq[f].m2, round = rq[f].round, e = rq[f].e;
        int8_t *d = buf_a + PIXEL_A(0, 0) + f;
#ifdef HAVE_NN
        const uint32_t *k = (const uint32_t *)weights[f];
        const uint32_t k0 = k[0], k1 = k[1], k2 = k[2], k3 = k[3], k4 = k[4], k5 = k[5], k6 = k[6],
                       k7 = k[7], k8 = k[8], k9 = k[9], k10 = k[10], k11 = k[11], k12 = k[12],
                       k13 = k[13], k14 = k[14], k15 = k[15];
        const uint32_t *s = (const uint32_t *)buf_b;
#else
        const int8_t *k = weights[f];
        const int8_t *s = buf_b;
#endif
        for (int y = 0; y < HEIGHT; y++, d += 2 * CH) {
            for (int x = 0; x < WIDTH; x++, d += CH) {
                int32_t acc = b;
#ifdef HAVE_NN
                /* Each input word is loaded one dot4.s8 ahead of its use (see LOAD_AHEAD). */
                uint32_t va = s[0], vb;
                vb = s[1];  LOAD_AHEAD(); acc = dot4_s8(acc, va, k0);
                va = s[2];  LOAD_AHEAD(); acc = dot4_s8(acc, vb, k1);
                vb = s[3];  LOAD_AHEAD(); acc = dot4_s8(acc, va, k2);
                va = s[4];  LOAD_AHEAD(); acc = dot4_s8(acc, vb, k3);
                vb = s[5];  LOAD_AHEAD(); acc = dot4_s8(acc, va, k4);
                va = s[6];  LOAD_AHEAD(); acc = dot4_s8(acc, vb, k5);
                vb = s[7];  LOAD_AHEAD(); acc = dot4_s8(acc, va, k6);
                va = s[8];  LOAD_AHEAD(); acc = dot4_s8(acc, vb, k7);
                vb = s[9];  LOAD_AHEAD(); acc = dot4_s8(acc, va, k8);
                va = s[10]; LOAD_AHEAD(); acc = dot4_s8(acc, vb, k9);
                vb = s[11]; LOAD_AHEAD(); acc = dot4_s8(acc, va, k10);
                va = s[12]; LOAD_AHEAD(); acc = dot4_s8(acc, vb, k11);
                vb = s[13]; LOAD_AHEAD(); acc = dot4_s8(acc, va, k12);
                va = s[14]; LOAD_AHEAD(); acc = dot4_s8(acc, vb, k13);
                vb = s[15]; LOAD_AHEAD(); acc = dot4_s8(acc, va, k14);
                                          acc = dot4_s8(acc, vb, k15);
                s += 16;
#else
/* Weight second, as GCC already has it in the first conv and depthwise. This matters
 * in build (a): __mulsi3 loops over the bits of its second argument, and the activations
 * are nearly all negative, so as the second argument they take the full 32 passes. */
#define MAC(i)   acc += (int32_t)s[i] * (int32_t)k[i];
#define MAC4(i)  MAC(i) MAC((i) + 1) MAC((i) + 2) MAC((i) + 3)
#define MAC16(i) MAC4(i) MAC4((i) + 4) MAC4((i) + 8) MAC4((i) + 12)
                MAC16(0) MAC16(16) MAC16(32) MAC16(48)
                s += CH;
#endif
                *d = (int8_t)clamp8(requant(acc, (uint32_t)m2, round, e) - 128);
            }
        }
    }
}

/* ---- layer 10: AVERAGE_POOL_2D over the 25 x 5 grid ----------------------- */
static void __attribute__((noinline)) average_pool(void)
{
    for (int c = 0; c < CH; c++) {
        const int8_t *s = buf_a + PIXEL_A(0, 0) + c;
        int32_t acc = 0;
        for (int y = 0; y < HEIGHT; y++, s += 2 * CH)
            for (int x = 0; x < WIDTH; x++, s += CH)
                acc += *s;
        /* TFLite: round to the closest integer, with a truncating division. */
        pool_out[c] = (int8_t)((acc > 0 ? acc + 125 / 2 : acc - 125 / 2) / 125);
    }
}

/* ---- layer 12: FULLY_CONNECTED 64 -> 12 ------------------------------------ */
static void __attribute__((noinline)) fully_connected(void)
{
#ifdef HAVE_NN
    const uint32_t *s = (const uint32_t *)pool_out;
    const uint32_t *w = (const uint32_t *)fc_w;
    for (int o = 0; o < 12; o++, w += 16) {
        int32_t acc = fc_b[o];
        for (int i = 0; i < 16; i++)
            acc = dot4_s8(acc, s[i], w[i]);
#else
    const int8_t *s = pool_out;
    for (int o = 0; o < 12; o++) {
        const int8_t *k = fc_w[o];
        int32_t acc = fc_b[o];
        MAC16(0) MAC16(16) MAC16(32) MAC16(48)
#endif
        kws_output[o] = (int8_t)clamp8(requant_once(acc, fc_rq.m2, fc_rq.round, fc_rq.e) + FC_OUTPUT_ZP);
    }
}

int main(void)
{
    /* The padding never changes, so this happens once, before the first marker. */
    for (int i = 0; i < 696; i++) input_pad[i] = INPUT_ZP;
    for (int i = 0; i < 12096; i++) buf_a[i] = -128;

    mark(0);
    first_conv();
    mark(1);
    for (int i = 0; i < 4; i++) {
        depthwise(dw_w[i], dw_b[i], dw_rq[i]);
        mark(2 + 2 * i);
        pointwise(pw_w[i], pw_b[i], pw_rq[i]);
        mark(3 + 2 * i);
    }
    average_pool();
    mark(10);
    fully_connected();
    mark(12);

    /* The arg-max of the 12 scores, where layer 13 (softmax) would be. Softmax is
     * not run: it would not change which score is largest. */
    int best = 0;
    for (int o = 1; o < 12; o++)
        if (kws_output[o] > kws_output[best]) best = o;
    kws_label = best;
    mark(13);
    return 0;
}
