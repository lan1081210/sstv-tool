/* SPDX-License-Identifier: GPL-3.0-only */
/* sstv_tx.c -- make an SSTV test WAV from a PPM (P6).
 *
 *   sstv_tx in.ppm out.wav [--mode VIS] [--rate R] [--skew PPM] [--offset HZ]
 *                          [--snr DB] [--novis] [--lead S]
 *
 * --mode takes the VIS code: 8 Robot 36 (default), 12 Robot 72, 44 Martin M1,
 * 40 M2, 60 Scottie S1, 56 S2, 76 DX, 93 PD50, 99 PD90, 95 PD120, 98 PD160,
 * 96 PD180, 97 PD240, 94 PD290. The picture is resized to the mode's size if needed.
 *
 * Play it into the iPod (or a radio) to exercise the receiver. --skew
 * stretches the timeline (simulates the sender's clock); --snr adds noise
 * measured in a 3 kHz bandwidth. */
#include "enc.h"
#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    EncOpts o;
    const char *in = 0, *out = 0;
    int i, w, h, mw, mh;
    long n;
    uint8_t *img;
    int16_t *x;
    enc_default_opts(&o);
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--rate") && i + 1 < argc) o.rate = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mode") && i + 1 < argc) o.mode = o.vis_code = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--skew") && i + 1 < argc) o.skew_ppm = atof(argv[++i]);
        else if (!strcmp(argv[i], "--offset") && i + 1 < argc) o.offset_hz = atof(argv[++i]);
        else if (!strcmp(argv[i], "--snr") && i + 1 < argc) o.snr_db = atof(argv[++i]);
        else if (!strcmp(argv[i], "--lead") && i + 1 < argc) o.lead_s = atof(argv[++i]);
        else if (!strcmp(argv[i], "--novis")) o.vis_code = -2;
        else if (!in) in = argv[i];
        else out = argv[i];
    }
    if (!in || !out) { fprintf(stderr, "usage: %s in.ppm out.wav [--mode VIS] [--rate R] [--skew PPM] [--offset HZ] [--snr DB] [--novis] [--lead S]\n", argv[0]); return 2; }
    if (o.vis_code == -2) o.vis_code = -1;
    if (!enc_mode_size(o.mode, &mw, &mh)) { fprintf(stderr, "unknown mode %d\n", o.mode); return 2; }
    img = ppm_read(in, &w, &h);
    if (!img) { fprintf(stderr, "%s: need a binary PPM (P6)\n", in); return 1; }
    if (w != mw || h != mh) { uint8_t *r = rgb_resize(img, w, h, mw, mh); free(img); img = r; }
    x = enc_encode(img, &o, &n);
    if (!wav_write_mono(out, x, n, o.rate)) { fprintf(stderr, "%s: write failed\n", out); return 1; }
    printf("%s: %s %dx%d, %.1f s at %d Hz\n", out, enc_mode_name(o.mode), mw, mh, (double)n / o.rate, o.rate);
    free(x); free(img);
    return 0;
}
