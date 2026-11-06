/* SPDX-License-Identifier: GPL-3.0-only */
/* audio_in.c -- CoreAudio (AUHAL) input capture into a ring buffer, drained
 * by a feeder thread. The client format is negotiated against the device
 * (float32, non-interleaved, the device's own rate), so any interface works;
 * the decoder takes whatever rate came back. */
#include "audio_in.h"

#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RING_SAMPLES (1u << 18)          /* 5.9 s at 44100 */
#define RING_MASK    (RING_SAMPLES - 1u)
#define CHUNK        1024

static int16_t ring[RING_SAMPLES];
static volatile uint32_t g_w, g_r;       /* free-running sample counters */
static volatile uint32_t g_lost;         /* samples dropped since last report */
static volatile uint64_t g_lost_total;   /* dropped since start (overruns) */
static volatile int g_run;
static volatile int g_live;
static volatile int g_render_err;        /* last AudioUnitRender error, 0 = fine */

static AudioUnit g_unit;
static pthread_t g_thread;
static float *g_scratch;                 /* realtime scratch, preallocated */
static size_t g_scratch_cap;             /* in floats per channel */
static int g_ch = 1;
static int g_rate = 44100;
static char g_name[256];
static audio_in_feed_fn g_feed;
static audio_in_gap_fn  g_gap;
static void *g_ctx;

/* ------------------------------------------------------------ device list */

static int device_list(AudioDeviceID **out)
{
    UInt32 size = 0;
    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyDevices,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr || !size)
        return 0;
    int n = (int)(size / sizeof(AudioDeviceID));
    AudioDeviceID *ids = malloc(size);
    if (!ids) return -1;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, ids) != noErr) {
        free(ids);
        return -1;
    }
    *out = ids;
    return n;
}

static int device_input_channels(AudioDeviceID id)
{
    AudioObjectPropertyAddress addr = { kAudioDevicePropertyStreamConfiguration,
                                        kAudioObjectPropertyScopeInput,
                                        kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &addr, 0, NULL, &size) != noErr || !size) return 0;
    AudioBufferList *bl = malloc(size);
    if (!bl) return 0;
    int ch = 0;
    if (AudioObjectGetPropertyData(id, &addr, 0, NULL, &size, bl) == noErr)
        for (UInt32 i = 0; i < bl->mNumberBuffers; i++) ch += (int)bl->mBuffers[i].mNumberChannels;
    free(bl);
    return ch;
}

static void device_name(AudioDeviceID id, char *out, size_t len)
{
    AudioObjectPropertyAddress addr = { kAudioObjectPropertyName,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    CFStringRef s = NULL;
    UInt32 size = sizeof s;
    out[0] = 0;
    if (AudioObjectGetPropertyData(id, &addr, 0, NULL, &size, &s) == noErr && s) {
        CFStringGetCString(s, out, (CFIndex)len, kCFStringEncodingUTF8);
        CFRelease(s);
    }
}

static AudioDeviceID default_input(void)
{
    AudioDeviceID id = 0;
    UInt32 size = sizeof id;
    AudioObjectPropertyAddress addr = { kAudioHardwarePropertyDefaultInputDevice,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &id) != noErr) return 0;
    return id;
}

static AudioDeviceID nth_input(int index)
{
    AudioDeviceID *ids = NULL;
    int n = device_list(&ids), shown = 0;
    AudioDeviceID found = 0;
    if (n <= 0) return 0;
    for (int i = 0; i < n; i++)
        if (device_input_channels(ids[i]) > 0 && shown++ == index) { found = ids[i]; break; }
    free(ids);
    return found;
}

/* The rate the hardware actually runs at: AUHAL does not resample on input, so
 * the client format has to match this one. */
static double nominal_rate(AudioDeviceID id)
{
    Float64 hz = 0;
    UInt32 size = sizeof hz;
    AudioObjectPropertyAddress addr = { kAudioDevicePropertyNominalSampleRate,
                                        kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(id, &addr, 0, NULL, &size, &hz) != noErr) return 0;
    return hz;
}

int audio_in_list(void)
{
    AudioDeviceID *ids = NULL;
    int n = device_list(&ids), shown = 0;
    if (n < 0) return -1;
    AudioDeviceID def = default_input();
    for (int i = 0; i < n; i++) {
        int ch = device_input_channels(ids[i]);
        if (ch <= 0) continue;                       /* output-only device */
        char nm[256];
        device_name(ids[i], nm, sizeof nm);
        printf("%2d  %-44s %2d ch%s\n", shown, nm, ch, ids[i] == def ? "  (default)" : "");
        shown++;
    }
    free(ids);
    return shown;
}

/* ------------------------------------------------------------- realtime */

static OSStatus input_cb(void *refCon, AudioUnitRenderActionFlags *flags,
                         const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                         AudioBufferList *ioData)
{
    (void)refCon; (void)ioData;
    if ((size_t)frames > g_scratch_cap) return noErr;   /* never grow in realtime */
    AudioBufferList bl;
    bl.mNumberBuffers = (UInt32)g_ch;
    for (int c = 0; c < g_ch; c++) {
        bl.mBuffers[c].mNumberChannels = 1;
        bl.mBuffers[c].mDataByteSize = frames * 4u;
        bl.mBuffers[c].mData = g_scratch + (size_t)c * g_scratch_cap;
    }
    OSStatus rst = AudioUnitRender(g_unit, flags, ts, bus, frames, &bl);
    if (rst != noErr) { g_render_err = (int)rst; return noErr; }

    /* channel 0 only, float -> s16, into the ring */
    const float *f = g_scratch;
    uint32_t w = g_w, r = g_r;
    for (UInt32 i = 0; i < frames; i++) {
        float v = f[i * 1];
        if (v > 1.0f) v = 1.0f; else if (v < -1.0f) v = -1.0f;
        if (w - r >= RING_SAMPLES) { g_lost++; g_lost_total++; r++; }
        ring[w & RING_MASK] = (int16_t)(v * 32767.0f);
        w++;
    }
    if (r != g_r) g_r = r;                           /* overflow: drop oldest */
    g_w = w;
    return noErr;
}

static void *feeder(void *arg)
{
    (void)arg;
    static int16_t buf[CHUNK];
    while (g_run) {
        uint32_t avail = g_w - g_r;
        if (!avail) { usleep(2000); continue; }
        int n = avail > CHUNK ? CHUNK : (int)avail;
        for (int i = 0; i < n; i++) buf[i] = ring[(g_r + i) & RING_MASK];
        g_r += (uint32_t)n;
        uint32_t lost = g_lost;
        if (lost) { g_lost = 0; if (g_gap) g_gap(g_ctx, (int)lost); }
        if (g_feed) g_feed(g_ctx, buf, n);
    }
    return NULL;
}

/* ----------------------------------------------------------------- open */

/* Set the client format on the input bus; returns the rate that took. */
static int set_client_format(int want_rate, int channels, char *err, size_t errlen)
{
    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof fmt);
    fmt.mSampleRate = (Float64)want_rate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    fmt.mFramesPerPacket = 1;
    fmt.mChannelsPerFrame = (UInt32)channels;
    fmt.mBitsPerChannel = 32;
    fmt.mBytesPerFrame = 4;
    fmt.mBytesPerPacket = 4;
    /* bus 1 = capture; its *client* side is the Output scope (the device side
     * is Input), so the format the app sees is set there. */
    OSStatus st = AudioUnitSetProperty(g_unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &fmt, sizeof fmt);
    if (st != noErr) {
        snprintf(err, errlen, "client format %d Hz %d ch: %d", want_rate, channels, (int)st);
        return 0;
    }
    return want_rate;
}

int audio_in_open(int device_index, int want_rate,
                  audio_in_feed_fn feed, audio_in_gap_fn gap, void *ctx,
                  int *out_rate, char *errbuf, size_t errlen)
{
    AudioDeviceID dev = device_index >= 0 ? nth_input(device_index) : default_input();
    if (!dev) {
        snprintf(errbuf, errlen, device_index >= 0 ? "no input device #%d (see --list)"
                                                   : "no default input device", device_index);
        return -1;
    }
    device_name(dev, g_name, sizeof g_name);

    AudioComponentDescription desc = { kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
                                       kAudioUnitManufacturer_Apple, 0, 0 };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) { snprintf(errbuf, errlen, "no HAL audio unit"); return -1; }
    OSStatus st;
    if ((st = AudioComponentInstanceNew(comp, &g_unit)) != noErr) {
        snprintf(errbuf, errlen, "AudioComponentInstanceNew: %d", (int)st);
        return -1;
    }
    UInt32 one = 1, zero = 0;
    AudioUnitSetProperty(g_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, sizeof one);
    AudioUnitSetProperty(g_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, sizeof zero);
    if ((st = AudioUnitSetProperty(g_unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &dev, sizeof dev)) != noErr) {
        snprintf(errbuf, errlen, "select device \"%s\": %d", g_name, (int)st);
        return -1;
    }

    /* what the device actually runs at, and with how many channels */
    AudioStreamBasicDescription devFmt;
    UInt32 sz = sizeof devFmt;
    memset(&devFmt, 0, sizeof devFmt);
    AudioUnitGetProperty(g_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &devFmt, &sz);
    int devRate = (int)(devFmt.mSampleRate > 0 ? devFmt.mSampleRate : 44100);
    int ch = (int)devFmt.mChannelsPerFrame;
    if (ch < 1) ch = 1;
    if (ch > 16) ch = 16;

    if (getenv("APRICOT_DEBUG"))
        fprintf(stderr, "[dev] \"%s\" rate=%.0f ch=%u format=%u flags=0x%x bits=%u\n", g_name,
                devFmt.mSampleRate, (unsigned)devFmt.mChannelsPerFrame, (unsigned)devFmt.mFormatID,
                (unsigned)devFmt.mFormatFlags, (unsigned)devFmt.mBitsPerChannel);

    int hw = (int)nominal_rate(dev);
    if (hw <= 0) hw = devRate > 0 ? devRate : 48000;

    int rate = 0;
    char e1[256] = "", e2[256] = "";
    int first = want_rate > 0 ? want_rate : hw;
    rate = set_client_format(first, ch, e1, sizeof e1);
    if (!rate && first != hw) rate = set_client_format(hw, ch, e2, sizeof e2);
    if (!rate && ch != 1) {                        /* mono is the common case */
        rate = set_client_format(hw, 1, e2, sizeof e2);
        if (rate) ch = 1;
    }
    if (!rate) {
        snprintf(errbuf, errlen, "cannot set a %d Hz %d ch client format (%s)", first, ch,
                 e2[0] ? e2 : e1);
        return -1;
    }

    g_ch = ch;
    g_rate = rate;
    g_scratch_cap = 16384;
    g_scratch = malloc(g_scratch_cap * sizeof(float) * (size_t)ch);
    if (!g_scratch) { snprintf(errbuf, errlen, "out of memory"); return -1; }

    AURenderCallbackStruct cb;
    cb.inputProc = input_cb;
    cb.inputProcRefCon = NULL;
    if ((st = AudioUnitSetProperty(g_unit, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 0, &cb, sizeof cb)) != noErr) {
        snprintf(errbuf, errlen, "set input callback: %d", (int)st);
        return -1;
    }
    if ((st = AudioUnitInitialize(g_unit)) != noErr) {
        snprintf(errbuf, errlen, "AudioUnitInitialize: %d", (int)st);
        return -1;
    }
    g_feed = feed; g_gap = gap; g_ctx = ctx;
    g_w = g_r = g_lost = 0;
    g_lost_total = 0;
    g_render_err = 0;
    if (out_rate) *out_rate = rate;
    return 0;
}

int audio_in_run(void)
{
    OSStatus st;
    if (g_run) return 0;
    if ((st = AudioOutputUnitStart(g_unit)) != noErr) return (int)st;
    g_live = 1;
    g_run = 1;
    if (pthread_create(&g_thread, NULL, feeder, NULL) != 0) {
        g_run = 0;
        return -1;
    }
    return 0;
}

void audio_in_stop(void)
{
    if (g_live) {
        AudioOutputUnitStop(g_unit);
        AudioUnitUninitialize(g_unit);
        AudioComponentInstanceDispose(g_unit);
        g_live = 0;
    }
    if (g_run) {
        g_run = 0;
        pthread_join(g_thread, NULL);
    }
    free(g_scratch);
    g_scratch = NULL;
}

int audio_in_health(void) { return g_render_err; }
unsigned long long audio_in_lost(void) { return g_lost_total; }

const char *audio_in_device_name(void) { return g_name; }
int audio_in_rate(void) { return g_rate; }
