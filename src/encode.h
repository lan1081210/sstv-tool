/* SPDX-License-Identifier: GPL-3.0-only */
/* encode.h -- picture -> SSTV audio (the transmit side).
 *
 * Modes and timings come from tools/enc.c, the host encoder that already sits
 * next to the decoder (Robot 36/72, Martin M1/M2, Scottie S1/S2/DX,
 * PD50/90/120/160/180/240/290), plus the impairments a receiver has to cope
 * with: sender clock error, mistuning, noise. Feature set follows
 * SSTVEncoder2: any mode, keep the aspect ratio with black borders, text
 * overlay, save a WAV, play it out loud.
 */
#ifndef APRICOT_ENCODE_H
#define APRICOT_ENCODE_H

#include <stddef.h>

typedef struct {
    int    vis;           /* VIS code of the mode (8 Robot 36 ... 95 PD120) */
    int    rate;          /* sample rate of the WAV */
    double lead_s;        /* silence before the VIS header */
    double tail_s;        /* silence after the picture */
    double skew_ppm;      /* simulate the sender's clock error */
    double offset_hz;     /* simulate mistuning */
    double snr_db;        /* add noise; >= 99 = clean */
    double amplitude;     /* peak in s16 units (32767 = full scale) */
    int    fit;           /* 0 letterbox (default), 1 fill/crop, 2 stretch */
    const char *text;     /* optional overlay, or NULL */
    int    play;          /* play the result after writing it */
    int    wait_play;     /* block until playback finishes */
} EncodeOpts;

void encode_defaults(EncodeOpts *o);

/* Resolve "robot36", "Robot 36", "pd120", "m1" ... to a VIS code; -1 if unknown. */
int encode_mode_from_string(const char *s);

/* Load any image CoreAudio's ImageIO can read, scale it to the mode, encode it
 * and write the WAV. Returns 0 on success; errbuf gets a message. */
int encode_image(const char *image_path, const char *wav_path, const EncodeOpts *o,
                 char *errbuf, size_t errlen, long *frames_out);

/* "PD120", "Robot 36" ... or NULL for a VIS the encoder does not send. */
const char *encode_mode_name(int vis);

/* Print the modes the encoder can produce (VIS, name, picture size, length). */
void encode_list_modes(void);

#endif
