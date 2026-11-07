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
#include <CoreGraphics/CoreGraphics.h>

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
    /* --- editing, the way the web encoders do it --- */
    int    rot;           /* 0 / 90 / 180 / 270 degrees */
    int    flip_h, flip_v;
    double pan_x, pan_y;  /* -1..1, 0 = centred: slides the picture in the frame */
    double zoom;          /* 1 = fit; > 1 crops in */
    double brightness;    /* -0.5 .. 0.5, added after the picture is drawn */
    double contrast;      /* 0.5 .. 2, 1 = unchanged */
    const char *text;     /* optional overlay, or NULL */
    int    text_pos;      /* 0..8 like a numpad (1 = lower left, 5 = centre); -1 = none */
    double text_scale;    /* multiplier of the automatic text size */
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

/* Draw the picture into an RGB888 buffer of the mode's size, applying the fit,
 * rotation, pan, zoom, brightness/contrast and text of `o`. This is the same
 * rendering encode_image() feeds to the modulator, exposed so the editor can
 * show exactly what will be sent. */
int encode_render_rgb(CGImageRef img, int mw, int mh, const EncodeOpts *o, uint8_t *rgb);

/* Load a picture the way the editor does (any format ImageIO reads). */
CGImageRef encode_load_image(const char *path);

/* "PD120", "Robot 36" ... or NULL for a VIS the encoder does not send. */
const char *encode_mode_name(int vis);

/* Print the modes the encoder can produce (VIS, name, picture size, length). */
void encode_list_modes(void);

#endif
