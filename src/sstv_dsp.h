/* SPDX-License-Identifier: GPL-3.0-only */
/*
 * sstv_dsp.h -- portable SSTV receiver core, float, no libm.
 *
 * Modes: Robot 36 / 72, Martin M1 / M2, Scottie S1 / S2 / DX,
 * PD50 / 90 / 120 / 160 / 180 / 240 / 290 -- every mode is a row of one table
 * (sstv_dsp.c), described relative to its sync pulse.
 *
 * Feed it raw s16 audio at the capture rate (44100 on the nano; any rate from
 * 8000 up works, for WAV files on a computer). It demodulates, watches for a
 * VIS header (or, optionally, for a run of line syncs with a mode's period and
 * sync length when the VIS was missed), decodes the picture line by line, and
 * straightens it as it goes: every line's sync is measured and a line-period
 * fit (offset + rate) re-times the picture, so clock skew between sender and
 * receiver does not shear it. The fitted rate is reported as ppm.
 *
 * DSP chain (at the input rate R, decimation D = round(R/11025), Fs = R/D):
 *   x[n] * e^{-j 2pi 1700 n/R}  ->  127-tap Blackman low-pass (complex),
 *   decimate by D  ->  FM discriminator arg(z[m] z*[m-1])  ->  tone in Hz
 *   tone -> level ring (uint8, 1500..2300 Hz = 0..255) + sync-bit ring
 *   tone -> 1 ms bins -> VIS detector (leader offset = tuning correction)
 *
 * Re-timing reaches back as far as the level ring (~12 s); lines older than
 * that keep the timing they were drawn with (by then the fit has settled).
 *
 * Threading: none. One owner calls everything (the nano: hb_raw_frame, where
 * the FPU is live). Never call from hb_raw_init.
 *
 * Memory: one fixed set of blocks, all taken by sstv_new and nothing after
 * (SSTV_MEM_BYTES at most, for any input rate up to 48000): 128 KiB level ring
 * (11.9 s at Fs = 11025), 16 KiB sync bits, 64 KiB tone history, 300 KiB
 * picture (RGB565, with the Robot 36 line data in its tail) and ~15 KiB of
 * state. The picture is stored at most SSTV_MAX_W x SSTV_MAX_H: modes wider
 * than that (PD120/160/180/240/290) are stored at half size, which is still more
 * than the nano's 320x240 picture area shows.
 */
#ifndef SSTV_DSP_H
#define SSTV_DSP_H
#include <stdint.h>

#define SSTV_MAX_W 400               /* stored picture size limit (see above): PD290 at half */
#define SSTV_MAX_H 308
#define SSTV_MEM_BYTES (540u * 1024u) /* everything sstv_new allocates, rounded up */

enum { SSTV_IDLE = 0, SSTV_RX = 1 };
enum { SSTV_START_NONE = 0, SSTV_START_VIS = 1, SSTV_START_SYNC = 2 };
enum { SSTV_END_NONE = 0, SSTV_END_COMPLETE = 1, SSTV_END_LOST = 2,
       SSTV_END_ABORT = 3, SSTV_END_NEWVIS = 4, SSTV_END_NOMEM = 5 };

typedef struct {
    int state;              /* SSTV_IDLE / SSTV_RX */
    const char *mode;       /* current/last image's mode ("PD120"), 0 if none yet */
    int width, height;      /* its picture size as sent (PD120: 640x496) */
    int line;               /* picture rows decoded (0..height, as sent) */
    int start_kind;         /* how the current/last image started */
    int end_kind;           /* how the last image ended (SSTV_END_*) */
    int last_vis;           /* last VIS code decoded, -1 if none yet */
    int last_vis_ok;        /* 1 if that VIS is a mode we decode */
    int tone_hz;            /* smoothed tone (tuning indicator) */
    int offset_hz;          /* tuning offset applied to the current/last image */
    int ppm;                /* line-period fit: rx clock vs tx clock, ppm (+ = rx fast) */
    int ppm_valid;          /* 1 once the fit has enough lines to mean something */
    int sync_good;          /* lines whose sync pulse was found ... */
    int sync_seen;          /* ... out of lines searched */
    int slant_redraws;      /* times the picture was re-timed (straightened) */
    int relocks;            /* times the picture was resumed after a fade or gap */
    unsigned long images;   /* images completed (>= 83 % of their lines) */
    unsigned long gaps;     /* input samples reported lost (sstv_gap) */
    unsigned revision;      /* bumps whenever the picture changes */
} SstvStatus;

typedef struct SstvRx SstvRx;

/* in_rate: input sample rate (Hz). NULL on OOM or a rate below 8000. */
SstvRx *sstv_new(int in_rate);
void    sstv_free(SstvRx *s);

/* Feed n input samples, taking every `stride`-th s16 (stride 2 = left channel
 * of interleaved stereo, as the nano's capture DMA delivers). */
void sstv_feed(SstvRx *s, const int16_t *x, int n, int stride);

/* n input samples were lost (capture overrun / the app stalled). Keeps the
 * time base exact without filtering silence: costs ~nothing per sample, so a
 * multi-second gap doesn't stall the caller. Picture rows whose audio falls
 * in a gap are left as they were (not drawn from silence). */
void sstv_gap(SstvRx *s, int n);

void sstv_status(const SstvRx *s, SstvStatus *st);

/* The current/last picture, RGB565, row-major, *w x *h as stored: the size
 * sent, or half of it for modes wider than SSTV_MAX_W (0 x 0 before the
 * first image). Valid until the next image starts. sstv_dirty's rows are
 * stored rows. */
const uint16_t *sstv_image(const SstvRx *s, int *w, int *h);
/* Rows changed since the last call: 1 and [*y0, *y1] (inclusive), or 0. */
int sstv_dirty(SstvRx *s, int *y0, int *y1);

/* Stop the current image (picture kept, back to listening). */
void sstv_abort(SstvRx *s);
/* Blank the picture. */
void sstv_clear(SstvRx *s);
/* Start on a run of line syncs when no VIS was heard (default on). */
void sstv_set_autosync(SstvRx *s, int on);
/* Prior for the clock error (ppm), used until the fit takes over. The decoder
 * updates its own prior after every good image; this seeds it. */
void sstv_set_ppm_prior(SstvRx *s, int ppm);

/* Name for a VIS code ("Robot 36", "Martin M1", ...), or 0 if unknown. */
const char *sstv_vis_name(int code);
/* 1 if this build decodes that VIS code */
int sstv_vis_supported(int code);

#endif /* SSTV_DSP_H */
