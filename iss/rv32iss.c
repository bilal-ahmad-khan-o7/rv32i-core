/* rv32iss.c - instruction-set simulator for this core: RV32I + Zmmul + DOT4.S8 + CLIP.S8.
 *
 * The golden model of the core. It matches the RTL's visible behaviour, not
 * only the ISA, so the two can be compared instruction by instruction:
 *   - Harvard memories, indexed by the low address bits only: addresses alias,
 *     exactly as in imem.sv / dmem.sv (no address decoder).
 *   - The decode holes listed in the README act as they do in control.sv
 *     (e.g. a load with funct3 011 reads a word; any SYSTEM word stops the run).
 *   - Misaligned accesses behave as in lsu.sv.
 *
 * On a single-cycle core one instruction takes one cycle, so counts here equal
 * cycle counts on the RTL. --pipeline also counts the cycles of the 5-stage
 * pipelined core (pipelined/), without changing what is executed:
 *   - every instruction is in EX one cycle after the one before it, plus
 *   - 1 cycle (load-use stall) if the one before is a load to a register rd != 0
 *     that this one names in its rs1 or rs2 field, or in its rd field if it is
 *     DOT4.S8 (the fields are compared whether or not they are read, as
 *     hazard_unit.sv does), and
 *   - 2 cycles (flush) if the one before was a taken branch, jal or jalr;
 *   - the first instruction is in EX in cycle 2, and the run ends when ebreak
 *     reaches WB, 2 cycles after its EX.
 *   Markers are timed when the marker store is in EX, as tb_core_kws.sv does.
 *
 * Build:  gcc -O2 -std=gnu11 -o build/rv32iss iss/rv32iss.c
 * Usage:  rv32iss --imem prog.hex [--dmem data.hex] [options]
 *   --imem-words N   instruction memory size in 32-bit words (default 8192, power of 2)
 *   --dmem-words N   data memory size in 32-bit words (default 16384, power of 2)
 *   --load F@ADDR    load a word-hex file into data memory at byte address ADDR
 *   --load-bin F@ADDR  the same for a raw binary file
 *   --layers F --expect F   at each marker, compare memory with expected bytes (below)
 *   --trace F        write one line per register write: pc, rd, value
 *   --trace-max N    stop writing the trace after N lines
 *   --max N          stop after N instructions (default 2000000000)
 *   --dump ADDR LEN  at the end, print LEN bytes of data memory as hex
 *   --pipeline       count cycles for the pipelined core (above)
 *   --quiet          print only the result line and any --dump output
 *
 * Marker: a store to 0xFFFFFFF0 reports the instructions executed since the
 * previous marker. Like every store, it also writes the memory word it aliases.
 *
 * Layer check: --layers holds 5 hex words per row: marker, base, len, stride,
 * count. At that marker, `count` spans of `len` bytes, `stride` bytes apart, are
 * compared with the next bytes of the --expect file (little-endian words). A
 * row's bytes start right after the previous row's.
 *
 * Exit status is 0 only if the program reached ebreak with no mismatch.
 */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MARKER_ADDR 0xFFFFFFF0u

enum { OP_LOAD = 0x03, OP_CUSTOM0 = 0x0B, OP_FENCE = 0x0F, OP_IMM = 0x13, OP_AUIPC = 0x17,
       OP_STORE = 0x23, OP_REG = 0x33, OP_LUI = 0x37, OP_BRANCH = 0x63, OP_JALR = 0x67,
       OP_JAL = 0x6F, OP_SYSTEM = 0x73 };

static uint32_t *imem, *dmem;
static uint32_t imask, dmask;              /* word-index masks */

static uint32_t *layers, *expected;        /* the --layers table and --expect bytes */
static uint32_t n_layer_rows, n_expected_bytes, rows_checked;
static uint64_t mismatches;
static int quiet, pipeline;

/* Does the instruction really read rs1 / rs2? The pipeline compares the fields
 * either way; this only counts the load-use stalls a decoder with rs1_read /
 * rs2_read outputs would not take. */
static int reads_rs1(uint32_t op)
{
    return op == OP_REG || op == OP_IMM || op == OP_LOAD || op == OP_STORE || op == OP_BRANCH ||
           op == OP_JALR || op == OP_CUSTOM0;
}

static int reads_rs2(uint32_t op)
{
    return op == OP_REG || op == OP_STORE || op == OP_BRANCH || op == OP_CUSTOM0;
}

static void die(const char *what, const char *arg)
{
    fprintf(stderr, "rv32iss: %s%s%s\n", what, arg ? ": " : "", arg ? arg : "");
    exit(2);
}

/* Read a $readmemh-style file: hex words, // comments, @index. Returns words read. */
static uint32_t load_hex(const char *path, uint32_t *mem, uint32_t mask, uint32_t start)
{
    FILE *f = fopen(path, "r");
    uint32_t idx = start, n = 0;
    int c;
    if (!f) die("cannot open", path);
    while ((c = fgetc(f)) != EOF) {
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
        if (c == '/') {                    /* a comment runs to the end of the line */
            while ((c = fgetc(f)) != EOF && c != '\n') ;
            continue;
        }
        uint32_t v = 0;
        int at = (c == '@');
        if (at) c = fgetc(f);
        for (; c != EOF && strchr("0123456789abcdefABCDEF_", c); c = fgetc(f)) {
            if (c == '_') continue;
            v = (v << 4) | (uint32_t)(c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10);
        }
        if (c != EOF) ungetc(c, f);
        if (at) idx = v;
        else { mem[idx++ & mask] = v; n++; }
    }
    fclose(f);
    return n;
}

static void store_byte(uint32_t addr, uint32_t v)
{
    uint32_t *w = &dmem[(addr >> 2) & dmask];
    unsigned sh = 8 * (addr & 3);
    *w = (*w & ~(0xFFu << sh)) | ((v & 0xFF) << sh);
}

static uint32_t load_byte(uint32_t addr)
{
    return (dmem[(addr >> 2) & dmask] >> (8 * (addr & 3))) & 0xFF;
}

static void load_bin(const char *spec)
{
    char path[1024];
    const char *at = strrchr(spec, '@');
    if (!at || (size_t)(at - spec) >= sizeof path) die("expected FILE@ADDR, got", spec);
    memcpy(path, spec, at - spec);
    path[at - spec] = 0;
    uint32_t addr = strtoul(at + 1, NULL, 0);
    FILE *f = fopen(path, "rb");
    int c;
    if (!f) die("cannot open", path);
    while ((c = fgetc(f)) != EOF) store_byte(addr++, (uint32_t)c);
    fclose(f);
}

static void load_hex_at(const char *spec)
{
    char path[1024];
    const char *at = strrchr(spec, '@');
    if (!at || (size_t)(at - spec) >= sizeof path) die("expected FILE@ADDR, got", spec);
    memcpy(path, spec, at - spec);
    path[at - spec] = 0;
    load_hex(path, dmem, dmask, (strtoul(at + 1, NULL, 0) >> 2) & dmask);
}

/* Compare the regions listed for this marker with the expected bytes. */
static void check_marker(uint32_t marker)
{
    uint32_t off = 0;
    for (uint32_t r = 0; r < n_layer_rows; r++) {
        const uint32_t *row = &layers[5 * r];
        uint32_t base = row[1], len = row[2], stride = row[3], count = row[4];
        if (row[0] == marker) {
            uint64_t bad = 0;
            uint32_t o = off;
            for (uint32_t s = 0; s < count; s++)
                for (uint32_t j = 0; j < len; j++, o++) {
                    uint32_t addr = base + s * stride + j;
                    uint32_t want = o < n_expected_bytes
                                  ? (expected[o >> 2] >> (8 * (o & 3))) & 0xFF : 0x100;
                    uint32_t got = load_byte(addr);
                    if (got != want) {
                        if (!bad && !quiet)
                            printf("  layer %u: first difference at %08x (span %u, byte %u): "
                                   "got %02x, expected %02x\n", marker, addr, s, j, got, want);
                        bad++;
                    }
                }
            if (bad && !quiet) printf("  layer %u: %" PRIu64 " bytes differ\n", marker, bad);
            mismatches += bad;
            rows_checked++;
        }
        off += len * count;
    }
}

int main(int argc, char **argv)
{
    const char *imem_file = NULL, *dmem_file = NULL, *layers_file = NULL, *expect_file = NULL;
    const char *trace_file = NULL;
    uint32_t imem_words = 8192, dmem_words = 16384;
    uint64_t max_count = 2000000000ULL, trace_max = ~0ULL;
    uint32_t dump_addr = 0, dump_len = 0;
    const char *loads[64];
    int n_loads = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
#define VALUE() (++i < argc ? argv[i] : (die("missing value for", a), ""))
        if      (!strcmp(a, "--imem"))       imem_file = VALUE();
        else if (!strcmp(a, "--dmem"))       dmem_file = VALUE();
        else if (!strcmp(a, "--imem-words")) imem_words = strtoul(VALUE(), NULL, 0);
        else if (!strcmp(a, "--dmem-words")) dmem_words = strtoul(VALUE(), NULL, 0);
        else if (!strcmp(a, "--load") || !strcmp(a, "--load-bin")) {
            if (n_loads + 2 > 64) die("too many loads", NULL);
            loads[n_loads++] = !strcmp(a, "--load") ? "h" : "b";
            loads[n_loads++] = VALUE();
        }
        else if (!strcmp(a, "--layers"))     layers_file = VALUE();
        else if (!strcmp(a, "--expect"))     expect_file = VALUE();
        else if (!strcmp(a, "--trace"))      trace_file = VALUE();
        else if (!strcmp(a, "--trace-max"))  trace_max = strtoull(VALUE(), NULL, 0);
        else if (!strcmp(a, "--max"))        max_count = strtoull(VALUE(), NULL, 0);
        else if (!strcmp(a, "--dump")) {
            dump_addr = strtoul(VALUE(), NULL, 0);
            dump_len  = strtoul(VALUE(), NULL, 0);
        }
        else if (!strcmp(a, "--quiet"))      quiet = 1;
        else if (!strcmp(a, "--pipeline"))   pipeline = 1;
        else die("unknown option", a);
    }
    if (!imem_file) die("--imem is required", NULL);
    if ((imem_words & (imem_words - 1)) || (dmem_words & (dmem_words - 1)))
        die("memory sizes must be powers of 2", NULL);

    imem = malloc(imem_words * 4);
    dmem = calloc(dmem_words, 4);
    if (!imem || !dmem) die("out of memory", NULL);
    imask = imem_words - 1;
    dmask = dmem_words - 1;
    for (uint32_t i = 0; i < imem_words; i++) imem[i] = 0x00000013;  /* nop fill, as imem.sv */
    load_hex(imem_file, imem, imask, 0);
    if (dmem_file) load_hex(dmem_file, dmem, dmask, 0);
    for (int i = 0; i < n_loads; i += 2) {
        if (loads[i][0] == 'h') load_hex_at(loads[i + 1]);
        else                    load_bin(loads[i + 1]);
    }
    if (layers_file) {
        layers = malloc(4 * 5 * 64);
        n_layer_rows = load_hex(layers_file, layers, 0xFFFFFFFFu, 0) / 5;
    }
    if (expect_file) {
        expected = malloc(1 << 20);
        n_expected_bytes = 4 * load_hex(expect_file, expected, (1u << 18) - 1, 0);
    }
    FILE *trace = NULL;
    if (trace_file && !(trace = fopen(trace_file, "w"))) die("cannot write", trace_file);

    uint32_t x[32] = {0};
    uint32_t pc = 0;
    uint64_t count = 0, last_mark = 0, trace_lines = 0;
    uint32_t min_sp = 0xFFFFFFFFu;             /* the deepest stack pointer seen */
    const char *why = "instruction limit";
    /* --pipeline: the cycle the next instruction is in EX, and the cycle accounting */
    uint64_t ex = 2, e = 0, n_lu = 0, n_fl = 0, n_false = 0;
    uint64_t m_cyc = 0, m_ins = 0, m_lu = 0, m_fl = 0, m_oth = 0;
    uint32_t prev_load_rd = 0;
    int prev_redirect = 0;

    while (count < max_count) {
        uint32_t in  = imem[(pc >> 2) & imask];
        uint32_t op  = in & 0x7F, rd = (in >> 7) & 31, f3 = (in >> 12) & 7;
        uint32_t rs1 = (in >> 15) & 31, rs2 = (in >> 20) & 31, f7 = in >> 25;
        uint32_t a = x[rs1], b = x[rs2], next = pc + 4, val = 0;
        int32_t  imm_i = (int32_t)in >> 20;
        int wr = 0, redirect = 0;

        if (pipeline) {
            int dot4 = op == OP_CUSTOM0 && f7 == 0 && f3 == 1;
            uint32_t r = prev_load_rd;
            if (r && (r == rs1 || r == rs2 || (dot4 && r == rd))) {
                ex++; n_lu++;
                if (!((r == rs1 && reads_rs1(op)) || (r == rs2 && reads_rs2(op)) || (dot4 && r == rd)))
                    n_false++;
            }
            if (prev_redirect) { ex += 2; n_fl += 2; }
            e = ex++;                              /* this instruction's EX cycle */
        }

        switch (op) {
        case OP_REG:
            if (f7 == 0x01 && f3 < 4) {                        /* mul mulh mulhsu mulhu */
                if (f3 == 0)      val = a * b;
                else if (f3 == 1) val = (uint32_t)(((int64_t)(int32_t)a * (int32_t)b) >> 32);
                else if (f3 == 2) val = (uint32_t)(((int64_t)(int32_t)a * (int64_t)b) >> 32);
                else              val = (uint32_t)(((uint64_t)a * b) >> 32);
                wr = 1;
                break;
            }
            if (!(f7 == 0 || (f7 == 0x20 && (f3 == 0 || f3 == 5)))) goto illegal;
            switch (f3) {
            case 0: val = f7 ? a - b : a + b; break;
            case 1: val = a << (b & 31); break;
            case 2: val = (int32_t)a < (int32_t)b; break;
            case 3: val = a < b; break;
            case 4: val = a ^ b; break;
            case 5: val = f7 ? (uint32_t)((int32_t)a >> (b & 31)) : a >> (b & 31); break;
            case 6: val = a | b; break;
            default: val = a & b; break;
            }
            wr = 1;
            break;
        case OP_IMM:
            if (f3 == 1 && f7 != 0) goto illegal;
            if (f3 == 5 && f7 != 0 && f7 != 0x20) goto illegal;
            switch (f3) {
            case 0: val = a + imm_i; break;
            case 1: val = a << rs2; break;
            case 2: val = (int32_t)a < imm_i; break;
            case 3: val = a < (uint32_t)imm_i; break;
            case 4: val = a ^ imm_i; break;
            case 5: val = f7 ? (uint32_t)((int32_t)a >> rs2) : a >> rs2; break;
            case 6: val = a | imm_i; break;
            default: val = a & imm_i; break;
            }
            wr = 1;
            break;
        case OP_LOAD: {
            uint32_t addr = a + imm_i, lo = addr & 3;
            uint32_t w = dmem[(addr >> 2) & dmask];
            uint32_t byte = (w >> (8 * lo)) & 0xFF;
            uint32_t half = (lo & 2) ? w >> 16 : w & 0xFFFF;
            switch (f3) {
            case 0:  val = (uint32_t)(int32_t)(int8_t)byte; break;
            case 1:  val = (uint32_t)(int32_t)(int16_t)half; break;
            case 4:  val = byte; break;
            case 5:  val = half; break;
            default: val = w; break;
            }
            wr = 1;
            break;
        }
        case OP_STORE: {
            int32_t imm = ((int32_t)(in & 0xFE000000) >> 20) | (int32_t)rd;
            uint32_t addr = a + imm, lo = addr & 3, mask = 0xFFFFFFFFu, data = b;
            if (f3 == 0) { data = b << (8 * lo); mask = 0xFFu << (8 * lo); }
            if (f3 == 1) { data = b << (8 * lo); mask = 0xFFFFu << (8 * lo); }
            uint32_t *w = &dmem[(addr >> 2) & dmask];
            *w = (*w & ~mask) | (data & mask);
            if (addr == MARKER_ADDR) {
                if (!quiet && pipeline) {          /* the same split as tb_core_kws.sv */
                    uint64_t cyc = e + 1, ins = count + 1, oth = 2;          /* oth: the fill */
                    printf("marker %2u: %10" PRIu64 " cycles  (total %" PRIu64 ")  instructions %" PRIu64
                           "  load-use %" PRIu64 "  flush %" PRIu64 "  other %" PRIu64 "\n", b,
                           cyc - m_cyc, cyc, ins - m_ins, n_lu - m_lu, n_fl - m_fl, oth - m_oth);
                    m_cyc = cyc; m_ins = ins; m_lu = n_lu; m_fl = n_fl; m_oth = oth;
                } else if (!quiet)
                    printf("marker %2u: %10" PRIu64 " instructions  (total %" PRIu64 ")\n", b,
                           count - last_mark, count);
                last_mark = count;
                if (layers) check_marker(b);
            }
            break;
        }
        case OP_BRANCH: {
            int taken;
            switch (f3) {
            case 0:  taken = a == b; break;
            case 1:  taken = a != b; break;
            case 4:  taken = (int32_t)a < (int32_t)b; break;
            case 5:  taken = (int32_t)a >= (int32_t)b; break;
            case 6:  taken = a < b; break;
            case 7:  taken = a >= b; break;
            default: taken = 0; break;
            }
            if (taken) {
                redirect = 1;
                int32_t imm = ((int32_t)(in & 0x80000000) >> 19) | ((in & 0x80) << 4)
                            | ((in >> 20) & 0x7E0) | ((in >> 7) & 0x1E);
                next = pc + imm;
            }
            break;
        }
        case OP_LUI:   val = in & 0xFFFFF000; wr = 1; break;
        case OP_AUIPC: val = pc + (in & 0xFFFFF000); wr = 1; break;
        case OP_JAL: {
            int32_t imm = ((int32_t)(in & 0x80000000) >> 11) | (in & 0xFF000)
                        | ((in >> 9) & 0x800) | ((in >> 20) & 0x7FE);
            val = pc + 4; wr = 1; redirect = 1;
            next = pc + imm;
            break;
        }
        case OP_JALR:
            val = pc + 4; wr = 1; redirect = 1;
            next = (a + imm_i) & ~1u;
            break;
        case OP_FENCE:
            break;
        case OP_CUSTOM0:
            if (f7 == 0 && f3 == 1) {                          /* DOT4.S8 */
                int32_t sum = 0;
                for (int i = 0; i < 24; i += 8)
                    sum += (int32_t)(int8_t)(a >> i) * (int8_t)(b >> i);
                sum += (int32_t)(int8_t)(a >> 24) * (int8_t)(b >> 24);
                val = x[rd] + (uint32_t)sum;
                wr = 1;
            } else if (f7 == 0 && f3 == 2 && rs2 == 0) {       /* CLIP.S8 */
                int32_t v = (int32_t)a;
                val = (uint32_t)(v > 127 ? 127 : v < -128 ? -128 : v);
                wr = 1;
            } else goto illegal;
            break;
        case OP_SYSTEM:
            why = "ebreak";
            goto done;
        default:
        illegal:
            why = "illegal instruction";
            goto done;
        }

        if (wr && rd) {
            x[rd] = val;
            if (rd == 2 && val < min_sp) min_sp = val;
            if (trace && trace_lines < trace_max) {
                fprintf(trace, "%08x x%-2u %08x\n", pc, rd, val);
                trace_lines++;
            }
        }
        prev_load_rd = op == OP_LOAD ? rd : 0;
        prev_redirect = redirect;
        pc = next;
        count++;
    }
done:
    if (trace) fclose(trace);
    if (!quiet) {
        printf("stopped (%s) at pc=%08x instr=%08x after %" PRIu64 " instructions\n", why, pc,
               imem[(pc >> 2) & imask], count);
        printf("lowest sp: %08x\n", min_sp);
        if (pipeline)                              /* ebreak reaches WB 2 cycles after EX */
            printf("pipeline: %" PRIu64 " cycles = %" PRIu64 " instructions + %" PRIu64 " load-use + %" PRIu64
                   " flush + 3 other  (load-use on a field the instruction does not read: %" PRIu64 ")\n",
                   e + 2, count + 1, n_lu, n_fl, n_false);
    }
    if (dump_len) {
        printf("dump %08x:", dump_addr);
        for (uint32_t i = 0; i < dump_len; i++) printf(" %02x", load_byte(dump_addr + i));
        printf("\n");
    }
    if (rows_checked != n_layer_rows)      /* a program that stops early must not pass */
        printf("  only %u of %u layer rows were reached\n", rows_checked, n_layer_rows);
    int ok = !strcmp(why, "ebreak") && mismatches == 0 && rows_checked == n_layer_rows;
    printf("%s: rv32iss (%" PRIu64 " instructions, %" PRIu64 " bytes differ)\n",
           ok ? "PASS" : "FAIL", count, mismatches);
    return ok ? 0 : 1;
}
