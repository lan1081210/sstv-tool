/* SPDX-License-Identifier: GPL-3.0-only */
/*
 * sstv_dsp.c -- see sstv_dsp.h.
 *
 * Freestanding: uses only malloc/free/memset (no libm; the few trig values
 * needed at init come from m_sin below), so nothing here can drag a
 * MOVW/MOVT libm table into the NanoApps image. Every block is taken in
 * sstv_new, at a size fixed by the input rate's decimation (never by the
 * mode), so the app can serve them from a static pool.
 *
 * Every mode is one row of the table below: its sync, line period, picture
 * size and the place of each colour channel, in seconds from the START of the
 * mode's sync pulse (Scottie's G and B come before its sync, so they're
 * negative). The decoder locks on syncs, fits the line period, and samples
 * the channels from that table; nothing else is mode-specific except the
 * Robot 36 chroma (alternating R-Y / B-Y lines, picked by the separator tone).
 *
 * VIS: 1900 leader 300 ms, 1200 break 10 ms, 1900 leader 300 ms, 1200 start
 * bit 30 ms, 7 data bits LSB first + even parity (1100 = 1, 1300 = 0, 30 ms
 * each), 1200 stop bit 30 ms. Robot, Martin and PD send line 0's sync right
 * after the stop bit; Scottie sends an extra 9 ms sync, then a whole G/B half
 * line before line 0's sync (the `first` column).
 */
#include "sstv_dsp.h"
#include <stdlib.h>
#include <string.h>

#ifdef SSTV_POOL                        /* the nano: the app's pool (sstv_support.c) */
void *sstv_pool_alloc(size_t n);
void  sstv_pool_free(void *p);
#define D_ALLOC(n) sstv_pool_alloc(n)
#define D_FREE(p)  sstv_pool_free(p)
#else
#define D_ALLOC(n) malloc(n)
#define D_FREE(p)  free(p)
#endif
static void *d_calloc(size_t n, size_t sz)
{
    void *p = D_ALLOC(n * sz);
    if (p) memset(p, 0, n * sz);
    return p;
}

#define PI_D     3.14159265358979323846
#define FC_HZ    1700                   /* mixer centre: 1100..2300 -> -600..+600 */
#define FIR_FCUT 1500.0                 /* low-pass -6 dB point (image at -2800 Hz is rejected) */
#define FIR_TAPS_44K 127

#define VB_N     1024                   /* 1 ms tone bins kept for the VIS detector */
#define VB_MASK  (VB_N - 1)

#define MAXP         320                /* sync periods per image (Martin/Scottie: 256, PD290: 308) */
#define R36_W        320
#define R36_H        240

#define SYNC_Q_MIN   0.60f              /* matched-template score for a "good" sync */
#define AUTO_PULSE_Q 0.60f              /* pulse candidates for autosync (each is then checked
                                           against every mode's sync length, grid and landmarks) */
#define LV_LEN       (1u << 17)         /* level ring, tone samples: 11.9 s at Fs = 11025.
                                           Lines older than that keep the timing they were
                                           drawn with. Fixed, so memory doesn't depend on the rate */
#define FH_LEN       (1u << 16)         /* tone history: 5.9 s at 11025 (autosync looks back
                                           4 PD240 lines) */
#define FH_HZ0       900.0f             /* tone history as uint8: 900 + 6 * q Hz */
#define FH_STEP      6.0f
#define IMG_BYTES    (2u * R36_W * R36_H + 2u * R36_W * R36_H)   /* Robot 36 picture + Y + C lines;
                                           >= SSTV_MAX_W * SSTV_MAX_H * 2 for every other mode */
typedef char img_bytes_cover_max[(IMG_BYTES >= 2u * SSTV_MAX_W * SSTV_MAX_H) ? 1 : -1];
#define LOST_S_VIS   12.0               /* seconds of missed syncs -> give up (VIS start) */
#define LOST_S_SYNC  6.0                /* ... after an autosync start */
#define MAX_SKEW     0.03               /* clamp the fitted line period to +-3 % */
#define RD_BUDGET    10240              /* channel-pixels re-timed per sstv_feed call (bounds
                                           the per-frame cost on the nano) */
#define NPULSE       32
#define NGAPS        8                  /* recent input gaps remembered (tone-index ranges) */
#define RESUME_S     120.0              /* resume a lost picture if its syncs return within this */

/* ------------------------------------------------------------------ modes */
enum { CM_R36, CM_YUV, CM_RGB };
enum { CH_Y, CH_Y2, CH_V, CH_U, CH_R, CH_G, CH_B, CH_C };
typedef struct { float t0, len; uint8_t what; } Chan;
typedef struct { float a, b, f1, f2; } Shape;     /* tone in [a,b] s after sync start ~ f1 (or f2) */
typedef struct {
    const char *name;
    int    vis, w, h, rows, color;               /* rows: picture rows per sync (PD: 2) */
    double line, sync, porch, first;             /* s; first = VIS end -> line 0's sync */
    int    nch;
    Chan   ch[4];
    int    nshape;
    Shape  shape[3];
} Mode;

#define PDM(nm, v, W, H, L, T) { nm, v, W, H, 2, CM_YUV, L, 0.020, 0.00208, 0.0, 4, \
    { { 0.02208f, T, CH_Y }, { 0.02208f + (T), T, CH_V }, { 0.02208f + 2 * (T), T, CH_U }, \
      { 0.02208f + 3 * (T), T, CH_Y2 } }, 1, { { 0.0203f, 0.0218f, 1500, 0 } } }

static const Mode MODES[] = {
    { "Robot 36", 8, 320, 240, 1, CM_R36, 0.150, 0.009, 0.003, 0.0, 2,
      { { 0.012f, 0.088f, CH_Y }, { 0.106f, 0.044f, CH_C } },
      3, { { 0.0095f, 0.0115f, 1500, 0 }, { 0.1007f, 0.1038f, 1500, 2300 }, { 0.1048f, 0.1058f, 1900, 0 } } },
    { "Robot 72", 12, 320, 240, 1, CM_YUV, 0.300, 0.009, 0.003, 0.0, 3,
      { { 0.012f, 0.138f, CH_Y }, { 0.156f, 0.069f, CH_V }, { 0.231f, 0.069f, CH_U } },
      3, { { 0.0095f, 0.0115f, 1500, 0 }, { 0.1507f, 0.1538f, 1500, 0 }, { 0.2257f, 0.2288f, 2300, 0 } } },
    { "Martin M1", 44, 320, 256, 1, CM_RGB, 0.446446, 0.004862, 0.000572, 0.0, 3,
      { { 0.005434f, 0.146432f, CH_G }, { 0.152438f, 0.146432f, CH_B }, { 0.299442f, 0.146432f, CH_R } },
      0, { { 0, 0, 0, 0 } } },
    { "Martin M2", 40, 320, 256, 1, CM_RGB, 0.226798, 0.004862, 0.000572, 0.0, 3,
      { { 0.005434f, 0.073216f, CH_G }, { 0.079222f, 0.073216f, CH_B }, { 0.153010f, 0.073216f, CH_R } },
      0, { { 0, 0, 0, 0 } } },
    { "Scottie S1", 60, 320, 256, 1, CM_RGB, 0.42822, 0.009, 0.0015, 0.28848, 3,
      { { 0.0105f, 0.13824f, CH_R }, { -0.27798f, 0.13824f, CH_G }, { -0.13824f, 0.13824f, CH_B } },
      1, { { 0.0093f, 0.0102f, 1500, 0 } } },
    { "Scottie S2", 56, 320, 256, 1, CM_RGB, 0.277692, 0.009, 0.0015, 0.188128, 3,
      { { 0.0105f, 0.088064f, CH_R }, { -0.177628f, 0.088064f, CH_G }, { -0.088064f, 0.088064f, CH_B } },
      1, { { 0.0093f, 0.0102f, 1500, 0 } } },
    { "Scottie DX", 76, 320, 256, 1, CM_RGB, 1.0503, 0.009, 0.0015, 0.7032, 3,
      { { 0.0105f, 0.3456f, CH_R }, { -0.6927f, 0.3456f, CH_G }, { -0.3456f, 0.3456f, CH_B } },
      1, { { 0.0093f, 0.0102f, 1500, 0 } } },
    PDM("PD50",  93, 320, 256, 0.38816,  0.09152f),
    PDM("PD90",  99, 320, 256, 0.70304,  0.17024f),
    PDM("PD120", 95, 640, 496, 0.50848,  0.1216f),
    PDM("PD160", 98, 512, 400, 0.804416, 0.195584f),
    PDM("PD180", 96, 640, 496, 0.75424,  0.18304f),
    PDM("PD240", 97, 640, 496, 1.0,      0.24448f),
    PDM("PD290", 94, 800, 616, 0.93728,  0.2288f),
};
#define NMODES ((int)(sizeof MODES / sizeof MODES[0]))

static const Mode *mode_by_vis(int vis)
{
    int i;
    for (i = 0; i < NMODES; i++) if (MODES[i].vis == vis) return &MODES[i];
    return 0;
}
static int mode_periods(const Mode *m) { return m->h / m->rows; }
/* stored size: modes wider than SSTV_MAX_W at half size (all PD, 2 rows per
 * sync, so one stored row per sync) */
static int mode_half(const Mode *m) { return m->w > SSTV_MAX_W; }
static int mode_sw(const Mode *m) { return mode_half(m) ? m->w / 2 : m->w; }
static int mode_sh(const Mode *m) { return mode_half(m) ? m->h / 2 : m->h; }
static int mode_srows(const Mode *m) { return mode_half(m) ? m->rows / 2 : m->rows; }
static double mode_t_min(const Mode *m)
{
    double t = 0; int c;
    for (c = 0; c < m->nch; c++) if (m->ch[c].t0 < t) t = m->ch[c].t0;
    return t;
}
static double mode_t_max(const Mode *m)
{
    double t = m->sync + m->porch; int c;
    for (c = 0; c < m->nch; c++) if (m->ch[c].t0 + m->ch[c].len > t) t = m->ch[c].t0 + m->ch[c].len;
    return t;
}

enum { CT_V = 0, CT_U = 1 };            /* Robot 36: chroma carried by a line */

typedef struct { uint32_t edge; } Pulse;      /* autosync: a sync's trailing edge */

struct SstvRx {
    int    in_rate, D;
    double Fs;                          /* tone (decimated) rate */

    /* mixer + decimating complex FIR at the input rate */
    float lo_re, lo_im, lo_cr, lo_ci;   /* mixer: rotating phasor and its per-sample step */
    float *h; int L, M;                 /* M = (L-1)/2, symmetric taps h[0..M] */
    float *bi, *bq; int bpos, dcount;
    float zr1, zi1;                     /* previous decimated sample */

    /* tone stream */
    uint32_t n;                         /* tone samples produced so far */
    uint8_t *fh; uint32_t fh_mask;      /* raw tone history, FH_HZ0 + FH_STEP * q */
    uint8_t *lv; uint8_t *sb; uint32_t lv_mask;   /* level + sync-bit rings */
    float    off;                       /* tuning offset (Hz) applied to lv/sb */
    float    tone_ema, ema_a;
    float    med1, med2;                /* median-of-3 history */

    /* VIS detector (1 ms bins) */
    float    bins[VB_N];
    uint32_t bin_j;                     /* index of the bin being accumulated */
    uint32_t bin_end;                   /* tone sample index where it ends */
    double   bin_acc; int bin_cnt;
    int      vis_active; uint32_t vis_first, vis_last, vis_deadline;
    int      vis_code; float vis_off;

    /* sync-pulse detector (autosync): generic 4 ms sync + 1 ms non-sync */
    int      autosync;
    int      gA, gB, runA, runB;
    int      cand; int candC; uint32_t candT1, candT2;
    Pulse    pulses[NPULSE]; int npulses;

    /* the image */
    const Mode *m;                      /* current/last mode */
    int      Ls, La, Lp;                /* its sync, sync-template, porch lengths (tone samples) */
    int      state, start_kind, end_kind, last_vis, last_vis_ok;
    double   Pnom, Pprior; int ppm_prior;
    double   t_ref;                     /* absolute tone index all line times are relative to */
    double   fa, fb;                    /* period k's sync starts at t_ref + fa + fb*k */
    int      fit_n, fit_span, fit_full;
    int      k, nper;                   /* next sync period to decode, periods per image */
    int      miss_run, sync_good, sync_seen, redraws, relocks;
    int      can_resume;                /* last picture ended early (lost/aborted), not counted */
    uint32_t t_end;                     /* tone index where it ended */
    uint32_t gap0[NGAPS], gap1[NGAPS]; int gapi;   /* [gap0, gap1): tone samples that were gaps */
    int      rd_pending, rd_j;          /* re-timing sweep in progress, next period */
    double   mpos[MAXP];  uint8_t mgood[MAXP];
    double   tused[MAXP]; uint8_t done[MAXP], ct[R36_H];
    uint8_t  *Y, *C;                    /* Robot 36 lines, R36_W each (chroma pairs across lines);
                                           in the picture block's tail */
    uint8_t  chbuf[4][SSTV_MAX_W];      /* one period's channels, levels */
    uint16_t *img;                      /* RGB565, mode_sw x mode_sh (IMG_BYTES block) */
    int      dirty, dy0, dy1;
    unsigned revision;
    unsigned long images, gaps;
};

/* ------------------------------------------------------------------ math */
static double m_sin(double x)
{
    int q; double x2, t, s; int i;
    q = (int)(x / (2.0 * PI_D) + (x >= 0 ? 0.5 : -0.5));
    x -= q * 2.0 * PI_D;                            /* [-pi, pi] */
    if (x > PI_D / 2)  x = PI_D - x;                /* [-pi/2, pi/2] */
    if (x < -PI_D / 2) x = -PI_D - x;
    x2 = x * x; t = x; s = x;
    for (i = 1; i < 9; i++) { t *= -x2 / ((2 * i) * (2 * i + 1)); s += t; }
    return s;
}
static double m_cos(double x) { return m_sin(x + PI_D / 2); }

/* atan2 with a degree-11 odd polynomial on [0,1]: measured |error| < 2e-6 rad
 * in float (0.003 Hz of tone at 11025). No libm. */
static inline float f_atan2(float y, float x)
{
    float ax = x < 0 ? -x : x, ay = y < 0 ? -y : y, a, s, r;
    if (ax == 0.0f && ay == 0.0f) return 0.0f;
    a = ax > ay ? ay / ax : ax / ay;
    s = a * a;
    r = a * (0.99997726f + s * (-0.33262347f + s * (0.19354346f +
        s * (-0.11643287f + s * (0.05265332f + s * -0.01172120f)))));
    if (ay > ax) r = 1.57079637f - r;
    if (x < 0)   r = 3.14159274f - r;
    return y < 0 ? -r : r;
}

static int iround(double x) { return (int)(x + (x >= 0 ? 0.5 : -0.5)); }

/* ------------------------------------------------------------ ring access */
static inline int sbit(const SstvRx *s, uint32_t i)
{
    i &= s->lv_mask;
    return (s->sb[i >> 3] >> (i & 7u)) & 1;
}
static inline void put_tone(SstvRx *s, uint32_t i, float f)
{
    float v = (f - s->off - 1500.0f) * (255.0f / 800.0f) + 0.5f;
    uint32_t j = i & s->lv_mask;
    uint8_t bit = (uint8_t)(1u << (j & 7u));
    s->lv[j] = (uint8_t)(v <= 0.0f ? 0 : v >= 255.0f ? 255 : (int)v);
    if (f - s->off < 1350.0f) s->sb[j >> 3] |= bit; else s->sb[j >> 3] &= (uint8_t)~bit;
}
static inline float fh_at(const SstvRx *s, uint32_t i) { return FH_HZ0 + FH_STEP * (float)s->fh[i & s->fh_mask]; }

/* --------------------------------------------------------------- picture */
static inline int clip8(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }
static inline uint16_t rgb565(int r, int g, int b)
{
    r = clip8(r); g = clip8(g); b = clip8(b);
    return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}
/* full-range BT.601 (Q8): R = Y + 1.402V, G = Y - 0.344U - 0.714V, B = Y + 1.772U */
static inline uint16_t yuv565(int y, int v, int u)
{
    v -= 128; u -= 128;
    return rgb565(y + ((359 * v + 128) >> 8), y - ((88 * u + 183 * v + 128) >> 8), y + ((454 * u + 128) >> 8));
}
static void mark_rows(SstvRx *s, int y0, int y1)
{
    if (y0 < 0) y0 = 0;
    if (y1 >= mode_sh(s->m)) y1 = mode_sh(s->m) - 1;
    if (y1 < y0) return;
    if (!s->dirty) { s->dirty = 1; s->dy0 = y0; s->dy1 = y1; }
    else { if (y0 < s->dy0) s->dy0 = y0; if (y1 > s->dy1) s->dy1 = y1; }
}

/* Robot 36: a line takes its partner's chroma (the other kind, R-Y vs B-Y) */
static void compose36(SstvRx *s, int j)
{
    const uint8_t *V, *U, *O = 0;
    int t, i, cand[3], c;
    uint16_t *row;
    if (j < 0 || j >= R36_H || !s->done[j]) return;
    t = s->ct[j];
    cand[0] = (j & 1) ? j - 1 : j + 1; cand[1] = j - 1; cand[2] = j + 1;
    for (c = 0; c < 3 && !O; c++) {
        int p = cand[c];
        if (p >= 0 && p < R36_H && s->done[p] && s->ct[p] != t) O = s->C + p * R36_W;
    }
    V = (t == CT_V) ? s->C + j * R36_W : O;
    U = (t == CT_U) ? s->C + j * R36_W : O;
    row = s->img + j * R36_W;
    for (i = 0; i < R36_W; i++)                     /* missing partner line -> no colour */
        row[i] = yuv565(s->Y[j * R36_W + i], V ? V[i] : 128, U ? U[i] : 128);
    mark_rows(s, j, j);
}

static inline float clampf(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }

/* level at base + off (off >= 0, a few thousand samples at most): single
 * precision, which the A5's VFP does much faster than double */
static inline float lvl_rel(const SstvRx *s, uint32_t base, float off)
{
    uint32_t i;
    float fr, a, b;
    if (off < 0.0f) off = 0.0f;
    i = (uint32_t)off;
    fr = off - (float)i;
    i += base;
    if (i + 1u >= s->n) { i = s->n - 2u; fr = 1.0f; }  /* never read unwritten samples */
    a = s->lv[i & s->lv_mask]; b = s->lv[(i + 1u) & s->lv_mask];
    return a + (b - a) * fr;
}

/* npix pixels of a channel starting at `start` (samples from base), lasting
 * `len` samples. Sample points stay a little inside the scan so the filter's
 * smear of the neighbouring tones (porch, separator, the next sync) does not
 * tint the first/last pixels. */
static void sample_chan(const SstvRx *s, uint32_t base, float start, float len, int npix, uint8_t *out)
{
    float pt = len / (float)npix, ms = (float)(0.001 * s->fb / s->m->line);   /* samples per ms */
    float lo = start + (0.15f * ms < pt * 0.5f ? 0.15f * ms : pt * 0.5f);
    float hi = start + len - (0.25f * ms < pt * 0.5f ? 0.25f * ms : pt * 0.5f);
    int i;
    for (i = 0; i < npix; i++) {
        float c = start + ((float)i + 0.5f) * pt;
        float v = (lvl_rel(s, base, clampf(c - pt / 3, lo, hi)) + lvl_rel(s, base, clampf(c, lo, hi)) +
                   lvl_rel(s, base, clampf(c + pt / 3, lo, hi))) * (1.0f / 3.0f);
        out[i] = (uint8_t)(v + 0.5f);
    }
}

/* is most of [a, b) (tone indices) inside recorded input gaps? (Short gaps
 * are drawn: sstv_gap holds the last tone across them, a small smear.) */
static int in_gap(const SstvRx *s, double a, double b)
{
    int i;
    double lost = 0;
    for (i = 0; i < NGAPS; i++) {
        double g0 = (double)s->gap0[i], g1 = (double)s->gap1[i];
        if (g1 <= g0 || b <= g0 || a >= g1) continue;
        lost += (b < g1 ? b : g1) - (a > g0 ? a : g0);
    }
    return lost * 2.0 > b - a;
}

/* Sample sync period k, whose sync starts at tone index t (from the fit), and
 * write its picture row(s). */
static void render_period(SstvRx *s, int k, double t)
{
    const Mode *m = s->m;
    double t_model = t, Fs = s->fb / m->line;      /* the sender's clock as we see it (fitted) */
    double tmin = mode_t_min(m) * Fs;
    uint32_t base;
    int c, i, w = mode_sw(m);
    /* the measured sync edge is the first porch-bit index, i.e. ~half a tone
     * sample after the true crossing; take it back (edge test: decoded edges
     * sat 0.17 px early without this, within 0.05 px with it) */
    t -= 0.5;
    /* t is (trailing edge - nominal sync); lay the channels out from the edge
     * itself with the fitted clock, so a big skew doesn't shift them */
    t += s->Ls - m->sync * Fs;
    if (t + tmin < 0) t = -tmin;
    if (in_gap(s, t + tmin, t + mode_t_max(m) * Fs)) {   /* audio lost: leave the row as it is */
        s->tused[k] = t_model;
        return;
    }
    base = (uint32_t)(t + tmin);
    t -= (double)base;                             /* everything below is relative to base */
    for (c = 0; c < m->nch; c++)
        sample_chan(s, base, (float)(t + m->ch[c].t0 * Fs), (float)(m->ch[c].len * Fs),
                    w, s->chbuf[c]);
    if (m->color == CM_R36) {
        float sep = 0, p, p1 = (float)(t + 0.1040 * Fs);
        int ns = 0;
        for (p = (float)(t + 0.1005 * Fs); p < p1; p += 1.0f) { sep += lvl_rel(s, base, p); ns++; }
        sep = ns ? sep / (float)ns : 128.0f;
        s->ct[k] = (uint8_t)(sep < 80 ? CT_V : sep > 175 ? CT_U : ((k & 1) ? CT_U : CT_V));
        memcpy(s->Y + k * R36_W, s->chbuf[0], R36_W);
        memcpy(s->C + k * R36_W, s->chbuf[1], R36_W);
        s->done[k] = 1;
        compose36(s, k - 1); compose36(s, k); compose36(s, k + 1);
    } else {
        const uint8_t *Y = 0, *Y2 = 0, *V = 0, *U = 0, *R = 0, *G = 0, *B = 0;
        for (c = 0; c < m->nch; c++) {
            const uint8_t *b = s->chbuf[c];
            switch (m->ch[c].what) {
            case CH_Y: Y = b; break;  case CH_Y2: Y2 = b; break;
            case CH_V: V = b; break;  case CH_U: U = b; break;
            case CH_R: R = b; break;  case CH_G: G = b; break;  case CH_B: B = b; break;
            default: break;
            }
        }
        if (m->color == CM_RGB) {
            uint16_t *row = s->img + k * w;
            for (i = 0; i < w; i++) row[i] = rgb565(R[i], G[i], B[i]);
        } else if (mode_half(m)) {                 /* half size: the two rows averaged */
            uint16_t *row = s->img + k * w;
            for (i = 0; i < w; i++) row[i] = yuv565((Y[i] + Y2[i] + 1) >> 1, V[i], U[i]);
        } else {
            uint16_t *row = s->img + k * m->rows * w;
            for (i = 0; i < w; i++) row[i] = yuv565(Y[i], V[i], U[i]);
            if (m->rows == 2) {
                row += w;
                for (i = 0; i < w; i++) row[i] = yuv565(Y2[i], V[i], U[i]);
            }
        }
        s->done[k] = 1;
        mark_rows(s, k * mode_srows(m), k * mode_srows(m) + mode_srows(m) - 1);
    }
    s->tused[k] = t_model;
}

static double line_t(const SstvRx *s, int k) { return s->t_ref + s->fa + s->fb * k; }

/* ---------------------------------------------------------------- timing */
/* Matched template over the sync bits, anchored on the sync's TRAILING edge
 * (always 1200 -> 1500 Hz, so the 1350 Hz threshold sits exactly mid-step):
 * +1 for sync during the last La samples of the pulse, -1 for sync during the
 * porch after it. The leading edge comes from whatever picture ended the
 * previous line, so the threshold crossing there is late by a content-
 * dependent amount; using it biased timing by ~half a pixel. Unique peak for
 * line 0 too (its sync runs on from the 1200 Hz VIS stop bit). Returns the
 * sync START (edge - sync length). */
static float find_sync(const SstvRx *s, double centre, double W, double *pos)
{
    long a = (long)(centre - W), b = (long)(centre + W), t;
    int Ls = s->Ls, La = s->La, Lp = s->Lp, A = 0, B = 0, i, best = -0x7fffffff;
    long t1 = 0, t2 = 0;
    if (a < 0) a = 0;
    if (b < a) b = a;
    for (i = Ls - La; i < Ls; i++) A += sbit(s, (uint32_t)(a + i));
    for (i = Ls; i < Ls + Lp; i++) B += sbit(s, (uint32_t)(a + i));
    for (t = a; t <= b; t++) {
        int C = (2 * A - La) - (2 * B - Lp);
        if (C > best) { best = C; t1 = t2 = t; }
        else if (C == best && t == t2 + 1) t2 = t;
        A += sbit(s, (uint32_t)(t + Ls)) - sbit(s, (uint32_t)(t + Ls - La));
        B += sbit(s, (uint32_t)(t + Ls + Lp)) - sbit(s, (uint32_t)(t + Ls));
    }
    *pos = 0.5 * (double)(t1 + t2);
    return (float)best / (float)(La + Lp);
}

static void sort_d(double *v, int n)
{
    int i, j;
    for (i = 1; i < n; i++) { double x = v[i]; for (j = i; j > 0 && v[j - 1] > x; j--) v[j] = v[j - 1]; v[j] = x; }
}

/* Fit sync starts (k, mpos) for the good periods so far: offset only (prior
 * period) until there are enough, then least squares with outlier rejection.
 * Result in fa, fb. */
static void fit_model(SstvRx *s)
{
    static double r[MAXP];
    static uint8_t use[MAXP];
    double Pmin = s->Pnom * (1 - MAX_SKEW), Pmax = s->Pnom * (1 + MAX_SKEW);
    double a0, thr, b;
    int k, n = 0, kmin = MAXP, kmax = -1, pass;
    for (k = 0; k <= s->k && k < MAXP; k++)
        if (s->mgood[k]) { r[n++] = s->mpos[k] - s->Pprior * k; if (k < kmin) kmin = k; if (k > kmax) kmax = k; }
    s->fit_n = n; s->fit_span = n ? kmax - kmin : 0; s->fit_full = 0;
    if (n == 0) return;                               /* keep the start guess */
    if (n < 4 || s->fit_span < 4) {                   /* too few: prior period, median offset */
        sort_d(r, n);
        a0 = (n & 1) ? r[n / 2] : 0.5 * (r[n / 2 - 1] + r[n / 2]);
        s->fa = a0; s->fb = s->Pprior;
        return;
    }
    thr = 1e30;                                       /* first pass: every good sync */
    for (pass = 0; pass < 3; pass++) {
        double sk = 0, sm = 0, skk = 0, skm = 0, rr = 0, a;
        int mcount = 0;
        for (k = 0; k <= s->k && k < MAXP; k++) {
            double e;
            use[k] = 0;
            if (!s->mgood[k]) continue;
            e = s->mpos[k] - (pass ? s->fa + s->fb * k : 0.0);
            if (pass && (e > thr || e < -thr)) continue;
            use[k] = 1;
            sk += k; sm += s->mpos[k]; skk += (double)k * k; skm += k * s->mpos[k]; mcount++;
        }
        if (mcount < 4) return;
        {
            double den = mcount * skk - sk * sk;
            if (den <= 0) return;
            b = (mcount * skm - sk * sm) / den;
        }
        if (b < Pmin || b > Pmax) return;             /* nonsense: keep what we had */
        a = (sm - b * sk) / mcount;
        for (k = 0; k <= s->k && k < MAXP; k++) {
            double e;
            if (!use[k]) continue;
            e = s->mpos[k] - (a + b * k);
            rr += e * e;
        }
        s->fa = a; s->fb = b; s->fit_full = (s->fit_span >= 8);
        rr = mcount > 2 ? rr / mcount : 0;            /* mean square residual */
        /* next pass keeps |e| <= max(3 sigma, 0.6 ms), capped at 3 ms; sqrt by bisection */
        thr = 0.0006 * s->Fs;
        if (rr * 9.0 > thr * thr) {
            double lo = thr, hi = 0.003 * s->Fs;
            int it;
            for (it = 0; it < 24; it++) { double mid = 0.5 * (lo + hi); if (mid * mid < 9.0 * rr) lo = mid; else hi = mid; }
            thr = hi;
        }
    }
}

static double search_window(const SstvRx *s)
{
    if (s->fit_n < 4 || s->miss_run >= 3) return 0.015 * s->Fs;
    if (!s->fit_full || s->fit_span < 20) return 0.006 * s->Fs;
    return 0.004 * s->Fs;
}

/* is period j's audio still in the level ring? */
static int period_in_ring(const SstvRx *s, int j)
{
    double t0 = line_t(s, j) + mode_t_min(s->m) * s->Fs - 2.0;
    return t0 >= 0 && (double)s->n - t0 < (double)s->lv_mask - 64.0;
}

static int period_cost(const Mode *m) { return m->nch * mode_sw(m); }

static void redraw_step(SstvRx *s, int budget)
{
    int j;
    if (!s->rd_pending) return;
    for (j = s->rd_j; j < s->k && j < s->nper && budget > 0; j++) {
        if (!period_in_ring(s, j)) continue;           /* too old: keeps its timing */
        render_period(s, j, line_t(s, j));
        budget -= period_cost(s->m);
    }
    s->rd_j = j;
    if (j >= s->k || j >= s->nper) s->rd_pending = 0;
    s->revision++;
}

static void finish(SstvRx *s, int why)
{
    redraw_step(s, 1 << 30);                        /* the saved picture is fully re-timed */
    s->state = SSTV_IDLE;
    s->end_kind = why;
    s->t_end = s->n;
    s->can_resume = (why == SSTV_END_LOST || why == SSTV_END_ABORT) && s->k * 6 < s->nper * 5 && s->fit_n >= 4;
    if (s->k * 6 >= s->nper * 5) s->images++;
    if (s->k * 6 >= s->nper * 5 && s->fit_full && s->fit_n * 4 >= s->nper && s->fit_span * 2 >= s->nper) {
        double ppm = (s->fb / s->Pnom - 1.0) * 1e6;
        s->ppm_prior = iround(ppm);
    }
    s->revision++;
}

/* (Re)quantise [from, n) with the current offset, from the raw tone history. */
static void requant(SstvRx *s, double from)
{
    uint32_t i, i0;
    if (from < 0) from = 0;
    i0 = (uint32_t)from;
    if (s->n - i0 > s->fh_mask) i0 = s->n - s->fh_mask;
    for (i = i0; i != s->n; i++) put_tone(s, i, fh_at(s, i));
}

/* Recompute the autosync running sums (after the sync bits were rewritten). */
static void autosync_resync(SstvRx *s)
{
    uint32_t i, e = s->n, w = (uint32_t)(s->gA + s->gB);
    s->runA = s->runB = 0;
    if (e < w) return;
    for (i = e - w; i < e - (uint32_t)s->gB; i++) s->runA += sbit(s, i);
    for (; i < e; i++) s->runB += sbit(s, i);
}

/* t0: sync start of period 0 (tone index) */
static void start_rx(SstvRx *s, const Mode *m, double t0, int kind, float off)
{
    uint32_t need = (uint32_t)(mode_sw(m) * mode_sh(m));
    int k;
    if (s->state == SSTV_RX) finish(s, SSTV_END_NEWVIS);
    s->m = m;
    if (off > 150) off = 150;
    if (off < -150) off = -150;
    s->off = off;
    requant(s, t0 + mode_t_min(m) * s->Fs - 0.03 * s->Fs);
    autosync_resync(s);
    s->Ls = iround(m->sync * s->Fs);
    s->La = iround((m->sync * 0.75 < 0.006 ? m->sync * 0.75 : 0.006) * s->Fs);
    s->Lp = iround((m->porch < 0.003 ? m->porch : 0.003) * s->Fs);
    if (s->Lp < 2) s->Lp = 2;
    s->Pnom = m->line * s->Fs;
    s->Pprior = s->Pnom * (1.0 + s->ppm_prior * 1e-6);
    s->nper = mode_periods(m);
    s->state = SSTV_RX; s->start_kind = kind; s->end_kind = SSTV_END_NONE;
    s->t_ref = t0; s->fa = 0; s->fb = s->Pprior;
    s->fit_n = s->fit_span = s->fit_full = 0;
    s->k = 0; s->miss_run = 0; s->sync_good = s->sync_seen = 0; s->redraws = 0;
    s->rd_pending = 0; s->rd_j = 0;
    for (k = 0; k < MAXP; k++) { s->mgood[k] = 0; s->done[k] = 0; }
    memset(s->img, 0, need * sizeof *s->img);
    s->dirty = 0; mark_rows(s, 0, mode_sh(m) - 1);
    s->cand = 0; s->npulses = 0;
    s->can_resume = 0; s->relocks = 0;
    s->revision++;
}

static void process_period(SstvRx *s)
{
    int k = s->k, lost;
    double W = search_window(s), pos, t;
    float q = find_sync(s, line_t(s, k), W, &pos);
    s->sync_seen++;
    if (q >= SYNC_Q_MIN) { s->mgood[k] = 1; s->mpos[k] = pos - s->t_ref; s->sync_good++; s->miss_run = 0; }
    else { s->mgood[k] = 0; s->miss_run++; }
    fit_model(s);
    t = line_t(s, k);
    /* straighten: if the fit moved, re-time the periods already drawn. Done as
     * a sweep, RD_BUDGET channel-pixels per feed call (see redraw_step),
     * restarted from the top whenever the fit moves again. */
    if (k > 0) {
        int j0 = 0;
        double d0, d1;
        while (j0 < k - 1 && !period_in_ring(s, j0)) j0++;
        d0 = line_t(s, j0) - s->tused[j0]; d1 = line_t(s, k - 1) - s->tused[k - 1];
        if (d0 > 0.5 || d0 < -0.5 || d1 > 0.5 || d1 < -0.5) {
            if (!s->rd_pending) s->redraws++;
            s->rd_pending = 1; s->rd_j = j0;
        }
    }
    render_period(s, k, t);
    s->k = k + 1;
    s->revision++;
    lost = (int)((s->start_kind == SSTV_START_VIS ? LOST_S_VIS : LOST_S_SYNC) / s->m->line);
    if (lost < 8) lost = 8;
    if (s->k >= s->nper) finish(s, SSTV_END_COMPLETE);
    else if (s->miss_run >= lost) finish(s, SSTV_END_LOST);
}

/* ------------------------------------------------------------------ VIS */
static float bin_mean(const SstvRx *s, uint32_t j0, int len)
{
    float a = 0; int i;
    for (i = 0; i < len; i++) a += s->bins[(j0 + (uint32_t)i) & VB_MASK];
    return a / (float)len;
}

/* Hypothesis: the VIS stop bit is bins [j-29, j]. Returns 1 and sets code/off/err.
 * Tolerances are set for ~8 dB SNR (3 kHz): noise pulls bin means toward the
 * band centre, so bits are decided against the 1200 Hz midpoint with a margin
 * rather than by distance to 1100/1300. A false start would need a 170 ms
 * steady leader (picture content can't: line syncs break the std test), plus
 * 10 matching regions and even parity. */
static int vis_test(const SstvRx *s, uint32_t j, int *code, float *off, float *err)
{
    float lead, var = 0, m, e = 0, d, mid;
    int b, bits = 0, ones = 0, i;
    if (j < 620) return 0;
    m = bin_mean(s, j - 29 + 5, 20);                   /* stop bit */
    if (m > 1440.0f || m < 960.0f) return 0;           /* cheap reject (runs every 1 ms) */
    lead = bin_mean(s, j - 480, 170);                  /* second leader, inner part */
    *off = lead - 1900.0f;
    if (*off > 150.0f || *off < -150.0f) return 0;
    mid = 1200.0f + *off;
    d = m - mid; if (d > 90.0f || d < -90.0f) return 0; e += d * d;
    m = bin_mean(s, j - 299 + 5, 20);                  /* start bit */
    d = m - mid; if (d > 90.0f || d < -90.0f) return 0; e += d * d;
    for (i = 0; i < 170; i++) { float x = s->bins[(j - 480 + (uint32_t)i) & VB_MASK] - lead; var += x * x; }
    if (var > 170.0f * 120.0f * 120.0f) return 0;      /* leader must be a steady tone */
    for (b = 0; b < 8; b++) {
        d = bin_mean(s, j - 29 - 30u * (uint32_t)(8 - b) + 5, 20) - mid;
        if (d < -25.0f && d > -200.0f) { bits |= 1 << b; ones++; d += 100.0f; }
        else if (d > 25.0f && d < 200.0f) d -= 100.0f;
        else return 0;
        e += d * d;
    }
    if (ones & 1) return 0;                            /* even parity over 8 bits */
    *code = bits & 0x7f;
    *err = e;
    return 1;
}

static void vis_bin_done(SstvRx *s, uint32_t j)
{
    int code; float off, err;
    if (vis_test(s, j, &code, &off, &err)) {
        if (!s->vis_active) { s->vis_active = 1; s->vis_first = j; s->vis_deadline = j + 14; s->vis_code = code; s->vis_off = off; }
        if (code == s->vis_code) s->vis_last = j;
    }
    if (s->vis_active && j >= s->vis_deadline) {
        uint32_t jc = s->vis_first + (s->vis_last - s->vis_first) / 2;
        double t_end = (double)(uint32_t)((jc + 1) * (s->Fs / 1000.0) + 0.5);  /* end of the stop bit */
        const Mode *m = mode_by_vis(s->vis_code);
        s->vis_active = 0;
        s->last_vis = s->vis_code;
        s->last_vis_ok = m != 0;
        s->revision++;
        if (m && !(s->state == SSTV_RX && t_end < s->t_ref + 1.0 * s->Fs))
            start_rx(s, m, t_end + m->first * s->Fs * (1.0 + s->ppm_prior * 1e-6), SSTV_START_VIS, s->vis_off);
    }
}

/* ------------------------------------------------------------- autosync */
static float fh_mean(const SstvRx *s, double from, double to)
{
    double a = 0; uint32_t i, i0 = (uint32_t)from, i1 = (uint32_t)to; int c = 0;
    for (i = i0; i < i1; i++) { a += fh_at(s, i); c++; }
    return c ? (float)(a / c) : 0.0f;
}
/* Does the period whose sync starts at p have the mode's landmarks (porch /
 * separator tones)? -1 if its audio is no longer in the tone history. */
static int line_shape(const SstvRx *s, const Mode *m, double p, float off)
{
    int i;
    double Fs = s->Fs;
    if ((double)s->n - (p + m->shape[0].a * Fs) > (double)s->fh_mask - 16.0) return -1;
    for (i = 0; i < m->nshape; i++) {
        float f = fh_mean(s, p + m->shape[i].a * Fs, p + m->shape[i].b * Fs) - off;
        int ok = f > m->shape[i].f1 - 130.0f && f < m->shape[i].f1 + 130.0f;
        if (m->shape[i].f2 > 0) ok |= f > m->shape[i].f2 - 130.0f && f < m->shape[i].f2 + 130.0f;
        if (!ok) return 0;
    }
    return 1;
}

static int sbits(const SstvRx *s, uint32_t a, uint32_t b)       /* sync bits in [a, b) */
{
    int c = 0;
    for (; a < b; a++) c += sbit(s, a);
    return c;
}
/* Is the pulse ending at `edge` this mode's sync? Mostly sync for the mode's
 * sync length, mostly not just before it (so a 20 ms PD sync isn't taken for
 * a 9 ms one, nor a 9 ms one for Martin's 4.9 ms). Counts, not a contiguous
 * run, so noise doesn't break it. */
static int sync_len_ok(const SstvRx *s, const Mode *m, uint32_t edge)
{
    uint32_t Ls = (uint32_t)iround(m->sync * s->Fs), g = (uint32_t)iround(0.0005 * s->Fs);
    uint32_t pre = (uint32_t)iround((m->sync * 0.4 < 0.003 ? m->sync * 0.4 : 0.003) * s->Fs);
    uint32_t in0 = edge - Ls + Ls / 10u, in1 = edge - Ls / 10u;
    if (edge < Ls + g + pre + 1u) return 0;
    if (sbits(s, in0, in1) * 10 < (int)(in1 - in0) * 7) return 0;
    return sbits(s, edge - Ls - g - pre, edge - Ls - g) * 10 <= (int)pre * 3;
}

/* The last picture ended early (a fade longer than the lost timeout, or a
 * long gap) and syncs of the same mode are back: if the sync at t0 sits on
 * that picture's fitted line grid, carry on with the same picture from that
 * line instead of starting a new one at the top. 1 if resumed. */
static int try_resume(SstvRx *s, const Mode *m, double t0)
{
    double x, e;
    int j;
    if (!s->can_resume || s->m != m || s->state != SSTV_IDLE) return 0;
    if ((double)(s->n - s->t_end) > RESUME_S * s->Fs) { s->can_resume = 0; return 0; }
    x = (t0 - s->t_ref - s->fa) / s->fb;
    j = (int)(x + 0.5);
    e = (x - j) * s->fb; if (e < 0) e = -e;
    /* on the grid to 4 ms plus 2 ms per minute of extrapolation (fit error) */
    if (e > 0.004 * s->Fs + 0.002 * s->Fs * (t0 - s->t_ref) / (60.0 * s->Fs)) return 0;
    if (j < 0 || j >= s->nper) return 0;
    if (j < s->k) j = s->k;                         /* grid found from older pulses: go on from here */
    s->state = SSTV_RX; s->end_kind = SSTV_END_NONE;
    s->k = j; s->miss_run = 0; s->can_resume = 0;
    s->rd_pending = 0;
    s->relocks++;
    s->cand = 0; s->npulses = 0;
    s->revision++;
    return 1;
}

/* A new pulse arrived: does it and its predecessors form some mode's grid? */
static void autosync_try(SstvRx *s)
{
    int mi;
    const Pulse *np = &s->pulses[s->npulses - 1];
    for (mi = 0; mi < NMODES; mi++) {
        const Mode *m = &MODES[mi];
        double Ls = m->sync * s->Fs, P = m->line * s->Fs * (1.0 + s->ppm_prior * 1e-6);
        int q, on = 1, first = s->npulses - 1, need = m->nshape ? 4 : 5;
        if (!sync_len_ok(s, m, np->edge)) continue;
        for (q = s->npulses - 2; q >= 0; q--) {
            const Pulse *pq = &s->pulses[q];
            double d = (double)(np->edge - pq->edge), e;
            int mul = (int)(d / P + 0.5);
            if (mul < 1 || mul > 8) continue;
            e = d - mul * P; if (e < 0) e = -e;
            if (e >= 0.001 * s->Fs + 0.0015 * d) continue;
            if (s->n - pq->edge > s->lv_mask - 64u || !sync_len_ok(s, m, pq->edge)) continue;
            on++; first = q;
        }
        if (on < need) continue;
        {
            /* tuning offset from the sync tone itself, then the landmarks of the
             * grid's periods (all but one of those still in history must pass) */
            double om[NPULSE];
            int cnt = 0, shaped = 0, tried = 0;
            uint32_t a, e0 = s->pulses[first].edge;
            float off;
            /* median over the grid's syncs of each sync's mean tone */
            for (q = first; q < s->npulses; q++) {
                uint32_t e = s->pulses[q].edge;
                double d = (double)(np->edge - e), ee = d - (int)(d / P + 0.5) * P, acc = 0;
                int c2 = 0;
                if (ee < 0) ee = -ee;
                if (ee >= 0.001 * s->Fs + 0.0015 * d || s->n - e > s->fh_mask - 16u || !sync_len_ok(s, m, e)) continue;
                for (a = e - (uint32_t)(Ls * 0.8); a < e - (uint32_t)(Ls * 0.2); a++) { acc += fh_at(s, a); c2++; }
                if (c2) om[cnt++] = acc / c2;
            }
            if (cnt) { sort_d(om, cnt); off = (float)om[cnt / 2] - 1200.0f; } else off = 0.0f;
            if (off > 150.0f || off < -150.0f) continue;
            for (q = first; m->nshape && q < s->npulses; q++) {
                double d = (double)(np->edge - s->pulses[q].edge), e = d - (int)(d / P + 0.5) * P;
                int r;
                if (e < 0) e = -e;
                if (e >= 0.001 * s->Fs + 0.0015 * d) continue;      /* not on the grid */
                if (q == s->npulses - 1 && (double)s->n < s->pulses[q].edge - Ls + m->shape[m->nshape - 1].b * s->Fs)
                    continue;                                       /* landmarks not heard yet */
                r = line_shape(s, m, (double)s->pulses[q].edge - Ls, off);
                if (r < 0) continue;
                tried++; shaped += r;
            }
            if (m->nshape && (tried < 2 || shaped < tried - 1)) continue;
            if (!try_resume(s, m, (double)e0 - Ls)) start_rx(s, m, (double)e0 - Ls, SSTV_START_SYNC, off);
            return;
        }
    }
}

static void autosync_sample(SstvRx *s)
{
    uint32_t i = s->n - 1;                             /* newest tone sample */
    int gA = s->gA, gB = s->gB, C;
    uint32_t t;
    s->runB += sbit(s, i) - sbit(s, i - (uint32_t)gB);
    s->runA += sbit(s, i - (uint32_t)gB) - sbit(s, i - (uint32_t)(gB + gA));
    if (s->n < (uint32_t)(gA + gB + 1)) return;
    t = s->n - (uint32_t)gB;                           /* candidate trailing edge */
    C = (2 * s->runA - gA) - (2 * s->runB - gB);
    if (C >= (int)(AUTO_PULSE_Q * (float)(gA + gB))) {
        if (!s->cand || C > s->candC) { s->cand = 1; s->candC = C; s->candT1 = s->candT2 = t; }
        else if (C == s->candC && t == s->candT2 + 1) s->candT2 = t;
    }
    if (s->cand && t > s->candT2 + (uint32_t)(0.003 * s->Fs)) {
        uint32_t e = s->candT1 + (s->candT2 - s->candT1) / 2;
        int q;
        s->cand = 0;
        if (s->npulses == NPULSE) { for (q = 1; q < NPULSE; q++) s->pulses[q - 1] = s->pulses[q]; s->npulses = NPULSE - 1; }
        s->pulses[s->npulses].edge = e;
        s->npulses++;
        if (s->state == SSTV_IDLE && s->autosync && !s->vis_active && s->npulses >= 4) autosync_try(s);
    }
}

/* ------------------------------------------------------------ per tone */
static void on_tone(SstvRx *s, float f)
{
    uint32_t i = s->n;
    float a = s->med1, b = s->med2;
    /* clamp FM clicks, then a 3-tap median: kills single-sample spikes at low
     * SNR without blurring edges (one tone sample of delay, same everywhere) */
    if (f < 800.0f) f = 800.0f;
    if (f > 2600.0f) f = 2600.0f;
    s->med1 = b; s->med2 = f;
    f = (a > b) ? (b > f ? b : (a > f ? f : a)) : (a > f ? a : (b > f ? f : b));
    {
        float q = (f - FH_HZ0) * (1.0f / FH_STEP) + 0.5f;    /* f is clamped to 800..2600 above */
        s->fh[i & s->fh_mask] = (uint8_t)(q <= 0.0f ? 0 : q >= 255.0f ? 255 : (int)q);
    }
    put_tone(s, i, f);
    s->n = i + 1;
    s->tone_ema += s->ema_a * (f - s->tone_ema);

    s->bin_acc += f; s->bin_cnt++;
    if (s->n >= s->bin_end) {
        s->bins[s->bin_j & VB_MASK] = s->bin_cnt ? (float)(s->bin_acc / s->bin_cnt) : (float)FC_HZ;
        s->bin_acc = 0; s->bin_cnt = 0;
        vis_bin_done(s, s->bin_j);
        s->bin_j++;
        s->bin_end = (uint32_t)((s->bin_j + 1) * (s->Fs / 1000.0) + 0.5);
    }

    autosync_sample(s);

    while (s->state == SSTV_RX &&
           (double)s->n > line_t(s, s->k) + mode_t_max(s->m) * s->fb / s->m->line + 2.0 * search_window(s) + 8.0)
        process_period(s);
}

/* -------------------------------------------------------------- public */
SstvRx *sstv_new(int in_rate)
{
    SstvRx *s;
    int i;
    if (in_rate < 8000) return 0;
    s = (SstvRx *)d_calloc(1, sizeof *s);
    if (!s) return 0;
    s->in_rate = in_rate;
    s->D = (in_rate + 5512) / 11025; if (s->D < 1) s->D = 1;
    s->Fs = (double)in_rate / s->D;

    s->L = (int)(FIR_TAPS_44K * (double)in_rate / 44100.0 + 0.5) | 1;
    if (s->L < 15) s->L = 15;
    s->M = (s->L - 1) / 2;

    s->fh_mask = FH_LEN - 1;
    s->lv_mask = LV_LEN - 1;

    s->h  = (float *)D_ALLOC(sizeof(float) * (size_t)(s->M + 1));
    s->bi = (float *)d_calloc((size_t)(2 * s->L), sizeof(float));
    s->bq = (float *)d_calloc((size_t)(2 * s->L), sizeof(float));
    s->fh = (uint8_t *)d_calloc((size_t)s->fh_mask + 1, 1);
    s->lv = (uint8_t *)d_calloc((size_t)s->lv_mask + 1, 1);
    s->sb = (uint8_t *)d_calloc(((size_t)s->lv_mask + 1) / 8, 1);
    s->img = (uint16_t *)d_calloc(IMG_BYTES / 2u, sizeof(uint16_t));
    if (!s->h || !s->bi || !s->bq || !s->fh || !s->lv || !s->sb || !s->img) {
        sstv_free(s); return 0;
    }
    s->Y = (uint8_t *)(s->img + R36_W * R36_H);
    s->C = s->Y + R36_W * R36_H;

    /* mixer: e^(-j 2 pi FC t), as a phasor rotated each sample (any rate, no
     * table) and pulled back to unit length at each decimated output */
    s->lo_re = 1.0f; s->lo_im = 0.0f;
    s->lo_cr = (float)m_cos(-2.0 * PI_D * FC_HZ / in_rate);
    s->lo_ci = (float)m_sin(-2.0 * PI_D * FC_HZ / in_rate);
    /* windowed-sinc (Blackman) low-pass, unity DC gain, symmetric half */
    {
        double sum = 0, wc = 2.0 * FIR_FCUT / in_rate;
        double *tmp = (double *)D_ALLOC(sizeof(double) * (size_t)s->L);
        if (!tmp) { sstv_free(s); return 0; }
        for (i = 0; i < s->L; i++) {
            double x = i - s->M, w, sn;
            w = 0.42 - 0.5 * m_cos(2 * PI_D * i / (s->L - 1)) + 0.08 * m_cos(4 * PI_D * i / (s->L - 1));
            sn = (x == 0) ? wc : m_sin(PI_D * wc * x) / (PI_D * x);
            tmp[i] = w * sn; sum += tmp[i];
        }
        for (i = 0; i <= s->M; i++) s->h[i] = (float)(tmp[i] / sum);
        D_FREE(tmp);
    }

    s->med1 = s->med2 = (float)FC_HZ;
    s->tone_ema = (float)FC_HZ; s->ema_a = (float)(1.0 / (0.05 * s->Fs));
    s->zr1 = 1.0f; s->zi1 = 0.0f;
    s->bin_j = 0; s->bin_end = (uint32_t)(s->Fs / 1000.0 + 0.5);
    s->gA = iround(0.004 * s->Fs);                         /* fits inside Martin's 4.9 ms sync */
    s->gB = iround(0.001 * s->Fs); if (s->gB < 2) s->gB = 2;
    s->autosync = 1;
    s->m = &MODES[0];
    s->last_vis = -1;
    return s;
}

void sstv_free(SstvRx *s)
{
    if (!s) return;
    /* reverse order of sstv_new, so a stack-like pool gives it all back */
    D_FREE(s->img); D_FREE(s->sb); D_FREE(s->lv); D_FREE(s->fh);
    D_FREE(s->bq); D_FREE(s->bi); D_FREE(s->h);
    D_FREE(s);
}

void sstv_feed(SstvRx *s, const int16_t *x, int n, int stride)
{
    int L, M, D, i, k;
    const float *h;
    float Fs2pi;
    if (!s || !x || n <= 0) return;
    L = s->L; M = s->M; D = s->D; h = s->h;
    Fs2pi = (float)(s->Fs / (2.0 * PI_D));
    if (stride < 1) stride = 1;
    for (i = 0; i < n; i++) {
        float v = (float)x[(long)i * stride];
        int p = s->bpos;
        float lr = s->lo_re, li = s->lo_im;
        float re = v * lr, im = v * li;
        s->lo_re = lr * s->lo_cr - li * s->lo_ci;
        s->lo_im = lr * s->lo_ci + li * s->lo_cr;
        s->bi[p] = s->bi[p + L] = re;
        s->bq[p] = s->bq[p + L] = im;
        if (++p == L) p = 0;
        s->bpos = p;
        if (++s->dcount == D) {
            const float *wi = s->bi + p, *wq = s->bq + p;   /* oldest .. newest */
            float zr = h[M] * wi[M], zi = h[M] * wq[M], zr2 = 0, zi2 = 0, dr, di;
            s->dcount = 0;
            {   /* renormalise the phasor (one Newton step: |lo| stays 1 to ~1e-7) */
                float g = 1.5f - 0.5f * (s->lo_re * s->lo_re + s->lo_im * s->lo_im);
                s->lo_re *= g; s->lo_im *= g;
            }
            /* symmetric taps; two accumulators per rail to hide the VFP's MAC latency */
            for (k = 0; k + 1 < M; k += 2) {
                zr  += h[k] * (wi[k] + wi[L - 1 - k]);
                zi  += h[k] * (wq[k] + wq[L - 1 - k]);
                zr2 += h[k + 1] * (wi[k + 1] + wi[L - 2 - k]);
                zi2 += h[k + 1] * (wq[k + 1] + wq[L - 2 - k]);
            }
            for (; k < M; k++) {
                zr += h[k] * (wi[k] + wi[L - 1 - k]);
                zi += h[k] * (wq[k] + wq[L - 1 - k]);
            }
            zr += zr2; zi += zi2;
            dr = zr * s->zr1 + zi * s->zi1;
            di = zi * s->zr1 - zr * s->zi1;
            s->zr1 = zr; s->zi1 = zi;
            on_tone(s, (float)FC_HZ + f_atan2(di, dr) * Fs2pi);
        }
    }
    if (s->state == SSTV_RX) redraw_step(s, RD_BUDGET);
}

void sstv_gap(SstvRx *s, int n)
{
    uint32_t t, g0;
    int k;
    if (!s || n <= 0) return;
    s->gaps += (unsigned long)n;
    t = (uint32_t)((s->dcount + n) / s->D);        /* tone samples the gap spans */
    s->dcount = (s->dcount + n) % s->D;
    if (t == 0) return;
    g0 = s->n;
    s->gap0[s->gapi] = g0; s->gap1[s->gapi] = g0 + t + 8u;   /* + the filter's settling */
    s->gapi = (s->gapi + 1) % NGAPS;
    for (k = 0; k < 2 * s->L; k++) s->bi[k] = s->bq[k] = 0.0f;   /* restart the filter clean */
    s->zr1 = 1.0f; s->zi1 = 0.0f;
    {   /* hold the last tone (never a sync tone, so no false syncs) */
        float f = s->med2 < 1450.0f ? 1500.0f : s->med2;
        while (t--) on_tone(s, f);
    }
    if (s->state == SSTV_RX) redraw_step(s, RD_BUDGET);
}

void sstv_status(const SstvRx *s, SstvStatus *st)
{
    double ppm;
    memset(st, 0, sizeof *st);
    st->last_vis = -1;
    if (!s) return;
    st->state = s->state;
    if (s->start_kind != SSTV_START_NONE) {
        st->mode = s->m->name; st->width = s->m->w; st->height = s->m->h;   /* as sent */
        st->line = s->k * s->m->rows;
    }
    st->start_kind = s->start_kind;
    st->end_kind = s->end_kind;
    st->last_vis = s->last_vis;
    st->last_vis_ok = s->last_vis_ok;
    st->tone_hz = (int)(s->tone_ema + 0.5f);
    st->offset_hz = iround(s->off);
    if (s->start_kind != SSTV_START_NONE && s->fit_full && s->fit_span >= 40) {
        ppm = (s->fb / s->Pnom - 1.0) * 1e6;
        st->ppm_valid = 1;
    } else ppm = s->ppm_prior;
    st->ppm = iround(ppm);
    st->sync_good = s->sync_good;
    st->sync_seen = s->sync_seen;
    st->slant_redraws = s->redraws;
    st->relocks = s->relocks;
    st->images = s->images;
    st->gaps = s->gaps;
    st->revision = s->revision;
}

const uint16_t *sstv_image(const SstvRx *s, int *w, int *h)
{
    if (!s || s->start_kind == SSTV_START_NONE) { if (w) *w = 0; if (h) *h = 0; return 0; }
    if (w) *w = mode_sw(s->m);
    if (h) *h = mode_sh(s->m);
    return s->img;
}

int sstv_dirty(SstvRx *s, int *y0, int *y1)
{
    if (!s || !s->dirty) return 0;
    *y0 = s->dy0; *y1 = s->dy1;
    s->dirty = 0;
    return 1;
}

void sstv_abort(SstvRx *s) { if (s && s->state == SSTV_RX) finish(s, SSTV_END_ABORT); }

void sstv_clear(SstvRx *s)
{
    int k;
    if (!s) return;
    if (s->state == SSTV_RX) finish(s, SSTV_END_ABORT);
    if (s->start_kind != SSTV_START_NONE) {
        memset(s->img, 0, (size_t)(mode_sw(s->m) * mode_sh(s->m)) * sizeof *s->img);
        mark_rows(s, 0, mode_sh(s->m) - 1);
    }
    for (k = 0; k < MAXP; k++) s->done[k] = 0;
    s->k = 0;
    s->can_resume = 0;
    s->revision++;
}

void sstv_set_autosync(SstvRx *s, int on) { if (s) s->autosync = on ? 1 : 0; }

void sstv_set_ppm_prior(SstvRx *s, int ppm)
{
    if (!s) return;
    if (ppm > 20000) ppm = 20000;
    if (ppm < -20000) ppm = -20000;
    s->ppm_prior = ppm;
}

const char *sstv_vis_name(int code)
{
    const Mode *m = mode_by_vis(code);
    if (m) return m->name;
    switch (code) {
    case 0:  return "Robot 12";
    case 4:  return "Robot 24";
    default: return 0;
    }
}

int sstv_vis_supported(int code) { return mode_by_vis(code) != 0; }
