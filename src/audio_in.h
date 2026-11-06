/* SPDX-License-Identifier: GPL-3.0-only */
/* audio_in.h -- live audio input capture (CoreAudio AUHAL) for the SSTV
 * decoder. Hands mono s16 samples to a feeder on its own thread, so the
 * realtime callback never touches the decoder. */
#ifndef APRICOT_AUDIO_IN_H
#define APRICOT_AUDIO_IN_H

#include <stddef.h>
#include <stdint.h>

/* Called from the capture thread with mono s16 samples. */
typedef void (*audio_in_feed_fn)(void *ctx, const int16_t *x, int n);
/* Called when input samples were dropped (ring overflow): the decoder must
 * keep its time base exact without filtering silence. */
typedef void (*audio_in_gap_fn)(void *ctx, int n);

/* Print the input devices, one per line: "<index>  <name>  [<ch> ch]  (default)".
 * Returns the number of devices, or -1 on error. */
int audio_in_list(void);

/* Set the capture up without starting it.
 *   device_index: index from audio_in_list(), or -1 for the default input.
 *   want_rate: the rate you would like; 0 or unsupported falls back to the
 *              device's own rate.
 * Returns 0 on success and writes the rate the device settled on to *out_rate
 * (create the decoder with it). -1 on error (errbuf gets a message). */
int  audio_in_open(int device_index, int want_rate,
                   audio_in_feed_fn feed, audio_in_gap_fn gap, void *ctx,
                   int *out_rate, char *errbuf, size_t errlen);

/* Start the unit and the feeder thread. Needs the decoder ready, because
 * samples can arrive immediately. Returns 0 or an OSStatus. */
int  audio_in_run(void);
void audio_in_stop(void);

/* 0 if AudioUnitRender is delivering, else the last OSStatus it returned
 * (-10863 = the device will not convert to the client format: try another
 * rate, the hardware does not resample on input). */
int audio_in_health(void);

/* Input samples dropped since the capture started (ring overruns: the feeder
 * could not keep up, e.g. the process was throttled). */
unsigned long long audio_in_lost(void);

/* Name of the device being captured, "" before open. */
const char *audio_in_device_name(void);
/* Rate negotiated by audio_in_open. */
int audio_in_rate(void);

#endif
