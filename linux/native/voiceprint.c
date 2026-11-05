/* 分出对方的每个人 on Linux: the Mac's voiceprint (WeSpeaker ResNet34-LM, VoxCeleb, CC BY 4.0) without
 * Core ML. A stock Ubuntu desktop has no BLAS and Python can't run a ResNet in real time, so the model
 * runs here, built into libcicada-voice.so for each architecture and loaded with ctypes. Our own code:
 * no third-party library. Weights come from linux/scripts/convert-voiceprint.py.
 *
 * The steps match SpeakerID.swift (Fbank, Voiceprints.embed) so a Linux voiceprint is the Mac's:
 * Kaldi fbank (16 kHz, 25 ms Povey windows every 10 ms, DC removed, pre-emphasis 0.97, 512-point power
 * spectrum, 80 mel bins 20 Hz to 8 kHz, natural log), per-bin mean removed over the clip, the ResNet
 * trunk, statistics pooling (mean, unbiased std + 1e-8), the 256-d layer minus mean_vec, unit length. */
#define _GNU_SOURCE
#include <math.h>
#include <float.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BINS 80
#define FRAME 400
#define SHIFT 160
#define NFFT 512
#define COLS (NFFT / 2 + 1)
#define RATE 16000
#define MIN_SECONDS 0.5
#define MAX_SECONDS 20.0
#define MAX_THREADS 4

#if defined(__GNUC__) && defined(__x86_64__) && !defined(__clang__)
/* One .so for every x86_64 machine: the GEMM also built for AVX2, picked at load. */
#define FAST __attribute__((target_clones("avx2", "default")))
#else
#define FAST
#endif

typedef struct {
    int type; /* 1 conv, 2 add */
    int src, src2, dst, cin, cout, k, stride, relu;
    float *w, *b;
    int last_use_src, last_use_src2; /* free a slot after its last reader */
} Op;

typedef struct {
    int nops, nslots;
    Op *ops;
    int channels, freq, dims;
    float *fc, *fc_b, *mean;
    float window[FRAME];
    float mel[BINS * COLS];
    float cos_t[NFFT / 2], sin_t[NFFT / 2];
} Model;

static float half(uint16_t h) {
    uint32_t s = (uint32_t)(h & 0x8000) << 16, e = (h >> 10) & 0x1F, m = h & 0x3FF, bits;
    if (e == 0) {
        if (m == 0) bits = s;
        else { /* subnormal */
            e = 127 - 15 + 1;
            while (!(m & 0x400)) { m <<= 1; e--; }
            bits = s | (e << 23) | ((m & 0x3FF) << 13);
        }
    } else if (e == 31) bits = s | 0x7F800000 | (m << 13);
    else bits = s | ((e - 15 + 127) << 23) | (m << 13);
    float f;
    memcpy(&f, &bits, 4);
    return f;
}

static int read_all(FILE *f, void *p, size_t n) { return fread(p, 1, n, f) == n; }

static float *read_f16(FILE *f, size_t n) {
    uint16_t *h = malloc(n * 2);
    float *out = malloc(n * sizeof(float));
    if (!h || !out || !read_all(f, h, n * 2)) { free(h); free(out); return NULL; }
    for (size_t i = 0; i < n; i++) out[i] = half(h[i]);
    free(h);
    return out;
}

static float *read_f32(FILE *f, size_t n) {
    float *out = malloc(n * sizeof(float));
    if (!out || !read_all(f, out, n * sizeof(float))) { free(out); return NULL; }
    return out;
}

static void tables(Model *m) {
    for (int i = 0; i < FRAME; i++)
        m->window[i] = powf(0.5f - 0.5f * cosf(2 * (float)M_PI * (float)i / (float)(FRAME - 1)), 0.85f);
    /* `BINS` rows of `COLS` weights, the Nyquist column zero, as in Kaldi (Fbank.melBanks). */
    double lo = 1127 * log(1 + 20 / 700.0), hi = 1127 * log(1 + 8000 / 700.0), delta = (hi - lo) / (BINS + 1);
    memset(m->mel, 0, sizeof m->mel);
    for (int b = 0; b < BINS; b++) {
        double left = lo + b * delta, center = left + delta, right = center + delta;
        for (int k = 0; k < NFFT / 2; k++) {
            double x = 1127 * log(1 + (double)k * RATE / NFFT / 700);
            double v = fmin((x - left) / (center - left), (right - x) / (right - center));
            if (v > 0) m->mel[b * COLS + k] = (float)v;
        }
    }
    for (int i = 0; i < NFFT / 2; i++) {
        m->cos_t[i] = (float)cos(-2 * M_PI * i / NFFT);
        m->sin_t[i] = (float)sin(-2 * M_PI * i / NFFT);
    }
}

void *cvp_load(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    char magic[4];
    uint32_t n;
    Model *m = calloc(1, sizeof(Model));
    if (!m || !read_all(f, magic, 4) || memcmp(magic, "CVP1", 4) || !read_all(f, &n, 4)) goto fail;
    m->nops = (int)n;
    m->ops = calloc(n, sizeof(Op));
    for (uint32_t i = 0; i < n; i++) {
        uint32_t t;
        Op *o = &m->ops[i];
        if (!read_all(f, &t, 4)) goto fail;
        o->type = (int)t;
        if (t == 1) {
            uint32_t v[7];
            if (!read_all(f, v, sizeof v)) goto fail;
            o->src = v[0]; o->dst = v[1]; o->cin = v[2]; o->cout = v[3]; o->k = v[4]; o->stride = v[5]; o->relu = v[6];
            o->src2 = -1;
            o->w = read_f16(f, (size_t)o->cout * o->cin * o->k * o->k);
            o->b = read_f32(f, o->cout);
            if (!o->w || !o->b) goto fail;
        } else if (t == 2) {
            uint32_t v[4];
            if (!read_all(f, v, sizeof v)) goto fail;
            o->src = v[0]; o->src2 = v[1]; o->dst = v[2]; o->relu = v[3];
        } else goto fail;
        if (o->dst + 1 > m->nslots) m->nslots = o->dst + 1;
    }
    uint32_t head[3];
    if (!read_all(f, head, sizeof head)) goto fail;
    m->channels = head[0]; m->freq = head[1]; m->dims = head[2];
    m->fc = read_f16(f, (size_t)m->dims * m->channels * m->freq * 2);
    m->fc_b = read_f32(f, m->dims);
    m->mean = read_f32(f, m->dims);
    if (!m->fc || !m->fc_b || !m->mean) goto fail;
    /* A slot is freed after the op that reads it last. */
    for (int i = 0; i < m->nops; i++) {
        Op *o = &m->ops[i];
        o->last_use_src = o->last_use_src2 = 1;
        for (int j = i + 1; j < m->nops; j++) {
            Op *p = &m->ops[j];
            if (p->src == o->src || p->src2 == o->src) o->last_use_src = 0;
            if (o->src2 >= 0 && (p->src == o->src2 || p->src2 == o->src2)) o->last_use_src2 = 0;
        }
    }
    tables(m);
    fclose(f);
    return m;
fail:
    fclose(f);
    free(m);
    return NULL;
}

/* In-place radix-2 FFT of NFFT complex values. */
static void fft(const Model *m, float *re, float *im) {
    for (int i = 1, j = 0; i < NFFT; i++) {
        int bit = NFFT >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            float t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (int len = 2; len <= NFFT; len <<= 1) {
        int step = NFFT / len;
        for (int i = 0; i < NFFT; i += len)
            for (int k = 0; k < len / 2; k++) {
                float wr = m->cos_t[k * step], wi = m->sin_t[k * step];
                int a = i + k, b = i + k + len / 2;
                float xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
                re[b] = re[a] - xr; im[b] = im[a] - xi;
                re[a] += xr; im[a] += xi;
            }
    }
}

/* Frames x BINS, row-major (Fbank.compute). Returns the frame count. */
int cvp_fbank(void *model, const float *samples, int n, float *out) {
    const Model *m = model;
    if (n < FRAME) return 0;
    int frames = 1 + (n - FRAME) / SHIFT;
    if (!out) return frames;
    float frame[NFFT], im[NFFT], power[COLS];
    for (int f = 0; f < frames; f++) {
        const float *s = samples + (size_t)f * SHIFT;
        float mean = 0;
        for (int i = 0; i < FRAME; i++) { frame[i] = s[i] * 32768; mean += frame[i]; }
        mean /= FRAME;
        for (int i = 0; i < FRAME; i++) frame[i] -= mean;
        for (int i = FRAME - 1; i > 0; i--) frame[i] -= 0.97f * frame[i - 1];
        frame[0] -= 0.97f * frame[0];
        for (int i = 0; i < FRAME; i++) frame[i] *= m->window[i];
        for (int i = FRAME; i < NFFT; i++) frame[i] = 0;
        memset(im, 0, sizeof im);
        fft(m, frame, im);
        for (int k = 0; k < COLS; k++) power[k] = frame[k] * frame[k] + im[k] * im[k];
        for (int b = 0; b < BINS; b++) {
            const float *w = m->mel + b * COLS;
            float acc = 0;
            for (int k = 0; k < COLS; k++) acc += w[k] * power[k];
            out[(size_t)f * BINS + b] = logf(acc > FLT_EPSILON ? acc : FLT_EPSILON);
        }
    }
    return frames;
}

/* ---- the ResNet ---- */

typedef struct {
    const Op *o;
    const float *in;
    float *out;
    int h, w, ho, wo;
    int tile, tiles, next;
    pthread_mutex_t *lock;
} ConvJob;

/* c_q[j] += a_q * b[j] for eight output channels: restrict parameters (GCC ignores them on locals) let
 * the compiler see the rows never overlap, so the loop over pixels vectorizes (NEON, SSE, AVX2). */
static inline __attribute__((always_inline)) void axpy8(const float *restrict b, int nt, const float *a,
        float *restrict c0, float *restrict c1, float *restrict c2, float *restrict c3,
        float *restrict c4, float *restrict c5, float *restrict c6, float *restrict c7) {
    float a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3], a4 = a[4], a5 = a[5], a6 = a[6], a7 = a[7];
    for (int j = 0; j < nt; j++) {
        float x = b[j];
        c0[j] += a0 * x; c1[j] += a1 * x; c2[j] += a2 * x; c3[j] += a3 * x;
        c4[j] += a4 * x; c5[j] += a5 * x; c6[j] += a6 * x; c7[j] += a7 * x;
    }
}

static inline __attribute__((always_inline)) void axpy1(const float *restrict b, int nt, float a, float *restrict c) {
    for (int j = 0; j < nt; j++) c[j] += a * b[j];
}

/* C[rows][nt] = W[rows][K] . col[K][nt], 8 output channels at a time so each col row is read once per 8. */
FAST static void gemm(const float *w, int K, int rows, const float *col, int nt, float *acc) {
    int r = 0;
    float a8[8];
    for (; r + 8 <= rows; r += 8) {
        float *c = acc + (size_t)r * nt;
        memset(c, 0, (size_t)8 * nt * sizeof(float));
        for (int k = 0; k < K; k++) {
            for (int q = 0; q < 8; q++) a8[q] = w[(size_t)(r + q) * K + k];
            axpy8(col + (size_t)k * nt, nt, a8, c, c + nt, c + 2 * nt, c + 3 * nt, c + 4 * nt, c + 5 * nt, c + 6 * nt, c + 7 * nt);
        }
    }
    for (; r < rows; r++) {
        float *c = acc + (size_t)r * nt;
        memset(c, 0, nt * sizeof(float));
        for (int k = 0; k < K; k++) axpy1(col + (size_t)k * nt, nt, w[(size_t)r * K + k], c);
    }
}

static void *conv_worker(void *arg) {
    ConvJob *j = arg;
    const Op *o = j->o;
    int K = o->cin * o->k * o->k, P = j->ho * j->wo;
    float *col = malloc((size_t)K * j->tile * sizeof(float));
    float *acc = malloc((size_t)o->cout * j->tile * sizeof(float));
    for (;;) {
        pthread_mutex_lock(j->lock);
        int t = j->next++;
        pthread_mutex_unlock(j->lock);
        if (t >= j->tiles) break;
        int p0 = t * j->tile, nt = P - p0 < j->tile ? P - p0 : j->tile;
        /* im2col for pixels p0..p0+nt */
        int pad = o->k / 2;
        for (int ci = 0; ci < o->cin; ci++)
            for (int ky = 0; ky < o->k; ky++)
                for (int kx = 0; kx < o->k; kx++) {
                    float *row = col + (size_t)((ci * o->k + ky) * o->k + kx) * nt;
                    const float *plane = j->in + (size_t)ci * j->h * j->w;
                    for (int q = 0; q < nt; q++) {
                        int p = p0 + q, y = (p / j->wo) * o->stride + ky - pad, x = (p % j->wo) * o->stride + kx - pad;
                        row[q] = (y >= 0 && y < j->h && x >= 0 && x < j->w) ? plane[(size_t)y * j->w + x] : 0.f;
                    }
                }
        gemm(o->w, K, o->cout, col, nt, acc);
        for (int co = 0; co < o->cout; co++) {
            float *dst = j->out + (size_t)co * P + p0;
            const float *a = acc + (size_t)co * nt;
            float bias = o->b[co];
            if (o->relu) for (int q = 0; q < nt; q++) { float v = a[q] + bias; dst[q] = v > 0 ? v : 0; }
            else for (int q = 0; q < nt; q++) dst[q] = a[q] + bias;
        }
    }
    free(col);
    free(acc);
    return NULL;
}

static float *conv(const Op *o, const float *in, int h, int w, int *ho, int *wo, int threads) {
    *ho = (h + 2 * (o->k / 2) - o->k) / o->stride + 1;
    *wo = (w + 2 * (o->k / 2) - o->k) / o->stride + 1;
    int K = o->cin * o->k * o->k, P = *ho * *wo;
    float *out = malloc((size_t)o->cout * P * sizeof(float));
    if (!out) return NULL;
    /* The column tile stays within ~256 KB of cache. */
    int tile = 65536 / K;
    tile = tile < 32 ? 32 : tile > 512 ? 512 : tile;
    tile -= tile % 8;
    pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    ConvJob job = {o, in, out, h, w, *ho, *wo, tile, (P + tile - 1) / tile, 0, &lock};
    pthread_t ids[MAX_THREADS];
    int started = 0;
    for (int i = 1; i < threads; i++)
        if (pthread_create(&ids[started], NULL, conv_worker, &job) == 0) started++;
    conv_worker(&job);
    for (int i = 0; i < started; i++) pthread_join(ids[i], NULL);
    return out;
}

/* A unit-length voiceprint of 16 kHz mono samples in -1...1 into out[dims]. 0, or -1 when too short. */
int cvp_embed(void *model, const float *samples, int n, float *out, int threads) {
    Model *m = model;
    if (n < MIN_SECONDS * RATE) return -1;
    if (n > MAX_SECONDS * RATE) n = (int)(MAX_SECONDS * RATE);
    if (threads <= 0) {
        long cpus = sysconf(_SC_NPROCESSORS_ONLN);
        threads = cpus > 0 ? (int)cpus : 1;
    }
    if (threads > MAX_THREADS) threads = MAX_THREADS;
    int frames = cvp_fbank(m, samples, n, NULL);
    if (frames < 50) return -1;
    float *feats = malloc((size_t)frames * BINS * sizeof(float));
    cvp_fbank(m, samples, n, feats);
    for (int b = 0; b < BINS; b++) {
        double sum = 0;
        for (int f = 0; f < frames; f++) sum += feats[(size_t)f * BINS + b];
        float mean = (float)(sum / frames);
        for (int f = 0; f < frames; f++) feats[(size_t)f * BINS + b] -= mean;
    }
    /* [frames][BINS] -> [1][BINS][frames]: height is frequency, width is time. */
    float **slot = calloc(m->nslots, sizeof(float *));
    int *hs = calloc(m->nslots, sizeof(int)), *ws = calloc(m->nslots, sizeof(int)), *cs = calloc(m->nslots, sizeof(int));
    float *x = malloc((size_t)frames * BINS * sizeof(float));
    for (int b = 0; b < BINS; b++)
        for (int f = 0; f < frames; f++) x[(size_t)b * frames + f] = feats[(size_t)f * BINS + b];
    free(feats);
    slot[0] = x; hs[0] = BINS; ws[0] = frames; cs[0] = 1;
    int last = 0, ok = 1;
    for (int i = 0; i < m->nops && ok; i++) {
        Op *o = &m->ops[i];
        if (o->type == 1) {
            int ho, wo;
            float *y = conv(o, slot[o->src], hs[o->src], ws[o->src], &ho, &wo, threads);
            if (!y) { ok = 0; break; }
            slot[o->dst] = y; hs[o->dst] = ho; ws[o->dst] = wo; cs[o->dst] = o->cout;
        } else {
            size_t len = (size_t)cs[o->src] * hs[o->src] * ws[o->src];
            float *y = malloc(len * sizeof(float));
            if (!y) { ok = 0; break; }
            const float *a = slot[o->src], *b = slot[o->src2];
            if (o->relu) for (size_t q = 0; q < len; q++) { float v = a[q] + b[q]; y[q] = v > 0 ? v : 0; }
            else for (size_t q = 0; q < len; q++) y[q] = a[q] + b[q];
            slot[o->dst] = y; hs[o->dst] = hs[o->src]; ws[o->dst] = ws[o->src]; cs[o->dst] = cs[o->src];
        }
        if (o->last_use_src && o->src != o->dst) { free(slot[o->src]); slot[o->src] = NULL; }
        if (o->src2 >= 0 && o->last_use_src2 && o->src2 != o->src) { free(slot[o->src2]); slot[o->src2] = NULL; }
        last = o->dst;
    }
    int result = -1;
    if (ok) {
        /* Statistics pooling over time: mean, then unbiased std + 1e-8, per (channel, frequency). */
        const float *t = slot[last];
        int rows = cs[last] * hs[last], w = ws[last];
        float *z = malloc((size_t)rows * 2 * sizeof(float));
        for (int r = 0; r < rows; r++) {
            const float *v = t + (size_t)r * w;
            double mu = 0, var = 0;
            for (int q = 0; q < w; q++) mu += v[q];
            mu /= w;
            for (int q = 0; q < w; q++) var += (v[q] - mu) * (v[q] - mu);
            var = w > 1 ? var / (w - 1) : 0;
            z[r] = (float)mu;
            z[rows + r] = (float)sqrt(var + 1e-8);
        }
        double norm = 0;
        for (int d = 0; d < m->dims; d++) {
            const float *wr = m->fc + (size_t)d * rows * 2;
            double acc = m->fc_b[d];
            for (int q = 0; q < rows * 2; q++) acc += wr[q] * z[q];
            out[d] = (float)(acc - m->mean[d]);
            norm += (double)out[d] * out[d];
        }
        free(z);
        if (norm > 0) {
            float s = (float)(1 / sqrt(norm));
            for (int d = 0; d < m->dims; d++) out[d] *= s;
            result = 0;
        }
    }
    for (int i = 0; i < m->nslots; i++) free(slot[i]);
    free(slot); free(hs); free(ws); free(cs);
    return result;
}

int cvp_dims(void *model) { return ((Model *)model)->dims; }

void cvp_free(void *model) {
    Model *m = model;
    if (!m) return;
    for (int i = 0; i < m->nops; i++) { free(m->ops[i].w); free(m->ops[i].b); }
    free(m->ops); free(m->fc); free(m->fc_b); free(m->mean);
    free(m);
}

/* The same for 16-bit samples, as the segmenter keeps them. */
int cvp_embed_s16(void *model, const int16_t *samples, int n, float *out, int threads) {
    if (n > MAX_SECONDS * RATE) n = (int)(MAX_SECONDS * RATE);
    float *f = malloc((size_t)(n > 0 ? n : 1) * sizeof(float));
    if (!f) return -1;
    for (int i = 0; i < n; i++) f[i] = samples[i] / 32768.f;
    int r = cvp_embed(model, f, n, out, threads);
    free(f);
    return r;
}
