/* SPDX-License-Identifier: GPL-3.0-only */
/* main.m -- Apricot SSTV for macOS (arm64): a desktop front end for the
 * portable decoder core in sstv_dsp.c (the one the iPod nano runs).
 *
 *   apricot-sstv <file> [more files...]   decode recordings (any CoreAudio format)
 *   apricot-sstv --listen [--device N]    live decode from an audio input
 *   apricot-sstv --simulate <file>        replay a file in real time through
 *                                         the live path (with the on-screen UI)
 *   apricot-sstv --list                   list audio input devices
 *
 * Pictures are written as PNG next to the recordings (or --out DIR), one file
 * per completed image, plus the one in progress at the end of a recording.
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "sstv_dsp.h"
#include "image_out.h"
#include "audio_in.h"

/* ------------------------------------------------------------------ state */

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static SstvRx *g_rx = NULL;
static SstvStatus g_prev;
static SstvStatus g_st;
static NSString *g_outDir = nil;
static NSString *g_prefix = nil;
static int g_nimg = 0;
static int g_scale = 1;
static int g_quiet = 0;
static double g_rate = 44100.0;
static double g_samples = 0.0;
static NSString *g_lastSaved = nil;
static volatile int g_sigint = 0;
static float g_level = 0.0f;          /* smoothed RMS of the decoded input, 0..1 */
static NSString *g_note = nil;        /* one line of state/warning for the window */

static const char *start_name(int k)
{
    return k == SSTV_START_VIS ? "VIS" : k == SSTV_START_SYNC ? "sync run (no VIS)" : "-";
}

static const char *end_name(int k)
{
    switch (k) {
    case SSTV_END_COMPLETE: return "complete";
    case SSTV_END_LOST:     return "signal lost";
    case SSTV_END_ABORT:    return "aborted";
    case SSTV_END_NEWVIS:   return "new VIS";
    case SSTV_END_NOMEM:    return "out of memory";
    default:                return "-";
    }
}

/* ------------------------------------------------------------ mode table */

/* Every mode this build decodes, asked of the decoder itself (no hard-coded
 * list that can drift). */
static NSArray<NSString *> *supported_modes(void)
{
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    for (int v = 1; v < 128; v++) {
        if (!sstv_vis_supported(v)) continue;
        const char *n = sstv_vis_name(v);
        if (n) [a addObject:@(n)];
    }
    return a;
}

/* ------------------------------------------------------------- image save */

/* Caller holds g_lock. Returns the path written, or nil. */
static NSString *save_image_locked(void)
{
    int w = 0, h = 0;
    const uint16_t *px = sstv_image(g_rx, &w, &h);
    if (!px || w <= 0 || h <= 0) return nil;

    NSString *dir = g_outDir ? g_outDir : [@"." stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                             attributes:nil error:NULL];
    NSString *prefix = g_prefix ? g_prefix : @"sstv";
    NSString *path = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@-%d.png", prefix, ++g_nimg]];

    if (png_write_565(path.fileSystemRepresentation, px, w, h, g_scale) != 0) {
        fprintf(stderr, "cannot write %s\n", path.fileSystemRepresentation);
        return nil;
    }
    g_lastSaved = path;
    return path;
}

/* ------------------------------------------------------------- audio feed */

/* Called from the capture thread (live) or the main/decode thread (files).
 * Owns the decoder: everything that touches g_rx goes through here or the UI
 * under the same mutex. */
static void feed_mono(void *ctx, const int16_t *x, int n)
{
    (void)ctx;
    if (n <= 0) return;
    double sum = 0;
    for (int i = 0; i < n; i++) {
        double v = (double)x[i] / 32768.0;
        sum += v * v;
    }
    float rms = (float)sqrt(sum / (double)n);

    pthread_mutex_lock(&g_lock);
    sstv_feed(g_rx, x, n, 1);
    g_samples += n;
    g_level = 0.75f * g_level + 0.25f * rms;
    sstv_status(g_rx, &g_st);

    double t = g_samples / g_rate;
    if (g_st.last_vis != g_prev.last_vis && g_st.last_vis >= 0) {
        const char *nm = sstv_vis_name(g_st.last_vis);
        if (!g_quiet)
            printf("%7.2f s  VIS %d (%s)%s\n", t, g_st.last_vis, nm ? nm : "unknown",
                   g_st.last_vis_ok ? "" : " - not decoded by this build");
        fflush(stdout);
    }
    if (g_st.state == SSTV_RX && (g_prev.state != SSTV_RX || g_st.line < g_prev.line)) {
        if (!g_quiet)
            printf("%7.2f s  %s started (%s), tuning offset %+d Hz\n", t, g_st.mode,
                   start_name(g_st.start_kind), g_st.offset_hz);
        fflush(stdout);
    }
    if (g_st.state != SSTV_RX && g_prev.state == SSTV_RX) {
        NSString *p = save_image_locked();
        if (!g_quiet)
            printf("%7.2f s  image ended (%s): %s, %d/%d rows, syncs %d/%d, clock %+d ppm%s -> %s\n",
                   t, end_name(g_st.end_kind), g_st.mode, g_st.line, g_st.height,
                   g_st.sync_good, g_st.sync_seen, g_st.ppm,
                   g_st.ppm_valid ? "" : " (prior)", p ? p.fileSystemRepresentation : "(not saved)");
        if (g_st.end_kind == SSTV_END_COMPLETE && !g_quiet)
            printf("            listening for the next one\n");
        fflush(stdout);
    }
    g_prev = g_st;
    pthread_mutex_unlock(&g_lock);
}

static void feed_gap(void *ctx, int n)
{
    (void)ctx;
    pthread_mutex_lock(&g_lock);
    sstv_gap(g_rx, n);
    pthread_mutex_unlock(&g_lock);
}

static void on_sigint(int sig)
{
    (void)sig;
    g_sigint = 1;
}

/* Anything still on screen when the run stops is worth keeping. */
static void save_partial(void)
{
    pthread_mutex_lock(&g_lock);
    SstvStatus st;
    sstv_status(g_rx, &st);
    if (st.state == SSTV_RX) {
        NSString *p = save_image_locked();
        printf("  stopped mid-image (%s, %d/%d rows) -> %s\n", st.mode, st.line, st.height,
               p ? p.fileSystemRepresentation : "(not saved)");
    }
    pthread_mutex_unlock(&g_lock);
}

/* ------------------------------------------------------------- file input */

/* Force the client format to s16 at a rate the decoder likes. */
static int pick_rate(int file_rate)
{
    if (file_rate < 8000 || file_rate > 48000) return 44100;
    return file_rate;
}

static int decode_file(NSString *path, int autosync, int have_ppm, int ppm)
{
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, (__bridge CFStringRef)path,
                                                 kCFURLPOSIXPathStyle, false);
    if (!url) return -1;
    ExtAudioFileRef ef = NULL;
    OSStatus st = ExtAudioFileOpenURL(url, &ef);
    CFRelease(url);
    if (st != noErr) {
        fprintf(stderr, "%s: cannot open (%d)\n", path.fileSystemRepresentation, (int)st);
        return -1;
    }

    AudioStreamBasicDescription fileFmt;
    UInt32 sz = sizeof fileFmt;
    if (ExtAudioFileGetProperty(ef, kExtAudioFileProperty_FileDataFormat, &sz, &fileFmt) != noErr) {
        fprintf(stderr, "%s: no audio format\n", path.fileSystemRepresentation);
        ExtAudioFileDispose(ef);
        return -1;
    }
    int rate = pick_rate((int)fileFmt.mSampleRate);
    int ch = (int)fileFmt.mChannelsPerFrame;
    if (ch < 1) ch = 1;
    if (ch > 8) ch = 8;

    AudioStreamBasicDescription client;
    memset(&client, 0, sizeof client);
    client.mSampleRate = (Float64)rate;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    client.mFramesPerPacket = 1;
    client.mChannelsPerFrame = (UInt32)ch;
    client.mBitsPerChannel = 16;
    client.mBytesPerFrame = (UInt32)(2 * ch);
    client.mBytesPerPacket = (UInt32)(2 * ch);
    if (ExtAudioFileSetProperty(ef, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client) != noErr) {
        fprintf(stderr, "%s: cannot convert to 16-bit PCM\n", path.fileSystemRepresentation);
        ExtAudioFileDispose(ef);
        return -1;
    }

    g_rate = rate;
    g_samples = 0;
    memset(&g_prev, 0, sizeof g_prev);
    g_prev.last_vis = -1;
    g_rx = sstv_new(rate);
    if (!g_rx) {
        fprintf(stderr, "decoder: rate %d unsupported or out of memory\n", rate);
        ExtAudioFileDispose(ef);
        return -1;
    }
    sstv_set_autosync(g_rx, autosync);
    if (have_ppm) sstv_set_ppm_prior(g_rx, ppm);
    sstv_status(g_rx, &g_prev);
    g_samples = 0;

    if (!g_quiet)
        printf("%s: %d Hz, %d ch (decoding channel 1)\n", path.fileSystemRepresentation, rate, ch);

    const int frames = 4096;
    int16_t *buf = malloc((size_t)frames * (size_t)ch * sizeof(int16_t));
    if (!buf) { ExtAudioFileDispose(ef); sstv_free(g_rx); g_rx = NULL; return -1; }

    for (;;) {
        AudioBufferList abl;
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = (UInt32)ch;
        abl.mBuffers[0].mDataByteSize = (UInt32)frames * 2u * (UInt32)ch;
        abl.mBuffers[0].mData = buf;
        UInt32 got = (UInt32)frames;
        if (ExtAudioFileRead(ef, &got, &abl) != noErr || got == 0) break;
        pthread_mutex_lock(&g_lock);
        sstv_feed(g_rx, buf, (int)got, ch);
        g_samples += got;
        sstv_status(g_rx, &g_st);
        double t = g_samples / g_rate;
        int vis_changed = g_st.last_vis != g_prev.last_vis && g_st.last_vis >= 0;
        int started = g_st.state == SSTV_RX && (g_prev.state != SSTV_RX || g_st.line < g_prev.line);
        int ended = g_st.state != SSTV_RX && g_prev.state == SSTV_RX;
        if (ended) {
            NSString *p = save_image_locked();
            if (!g_quiet)
                printf("%7.2f s  image ended (%s): %s, %d/%d rows, syncs %d/%d, clock %+d ppm%s -> %s\n",
                       t, end_name(g_st.end_kind), g_st.mode, g_st.line, g_st.height,
                       g_st.sync_good, g_st.sync_seen, g_st.ppm,
                       g_st.ppm_valid ? "" : " (prior)", p ? p.fileSystemRepresentation : "(not saved)");
            if (g_st.end_kind == SSTV_END_COMPLETE && !g_quiet) {
                printf("            listening for the next one\n");
            }
        }
        SstvStatus now = g_st;
        pthread_mutex_unlock(&g_lock);

        if (vis_changed && !g_quiet) {
            const char *nm = sstv_vis_name(now.last_vis);
            printf("%7.2f s  VIS %d (%s)%s\n", t, now.last_vis, nm ? nm : "unknown",
                   now.last_vis_ok ? "" : " - not decoded by this build");
        }
        if (started && !g_quiet)
            printf("%7.2f s  %s started (%s), tuning offset %+d Hz\n", t, now.mode,
                   start_name(now.start_kind), now.offset_hz);
        fflush(stdout);
        g_prev = now;
    }

    pthread_mutex_lock(&g_lock);
    sstv_status(g_rx, &g_st);
    if (g_st.state == SSTV_RX) {
        NSString *p = save_image_locked();
        if (!g_quiet)
            printf("  end of file mid-image (%s, %d/%d rows) -> %s\n", g_st.mode, g_st.line,
                   g_st.height, p ? p.fileSystemRepresentation : "(not saved)");
    }
    if (!g_quiet && g_nimg == 0) printf("no image found\n");
    sstv_free(g_rx);
    g_rx = NULL;
    pthread_mutex_unlock(&g_lock);

    free(buf);
    ExtAudioFileDispose(ef);
    return 0;
}

/* ------------------------------------------------ real-time file playback */

typedef struct { NSString *path; } SimCtx;

static void *sim_thread(void *arg)
{
    SimCtx *c = (SimCtx *)arg;
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, (__bridge CFStringRef)c->path,
                                                 kCFURLPOSIXPathStyle, false);
    ExtAudioFileRef ef = NULL;
    if (ExtAudioFileOpenURL(url, &ef) != noErr) { CFRelease(url); return NULL; }
    CFRelease(url);

    AudioStreamBasicDescription fileFmt;
    UInt32 sz = sizeof fileFmt;
    ExtAudioFileGetProperty(ef, kExtAudioFileProperty_FileDataFormat, &sz, &fileFmt);
    int rate = pick_rate((int)fileFmt.mSampleRate);
    int ch = (int)fileFmt.mChannelsPerFrame; if (ch < 1) ch = 1; if (ch > 8) ch = 8;

    AudioStreamBasicDescription client;
    memset(&client, 0, sizeof client);
    client.mSampleRate = (Float64)rate;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    client.mFramesPerPacket = 1;
    client.mChannelsPerFrame = (UInt32)ch;
    client.mBitsPerChannel = 16;
    client.mBytesPerFrame = (UInt32)(2 * ch);
    client.mBytesPerPacket = (UInt32)(2 * ch);
    ExtAudioFileSetProperty(ef, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client);

    pthread_mutex_lock(&g_lock);
    g_rate = rate;
    g_samples = 0;
    sstv_free(g_rx);
    g_rx = sstv_new(rate);
    sstv_set_autosync(g_rx, 1);
    sstv_status(g_rx, &g_prev);
    g_prev.last_vis = -1;
    pthread_mutex_unlock(&g_lock);

    const int frames = 1024;
    int16_t *buf = malloc((size_t)frames * (size_t)ch * sizeof(int16_t));
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    long long fed = 0;

    while (!g_sigint) {
        AudioBufferList abl;
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = (UInt32)ch;
        abl.mBuffers[0].mDataByteSize = (UInt32)frames * 2u * (UInt32)ch;
        abl.mBuffers[0].mData = buf;
        UInt32 got = (UInt32)frames;
        if (ExtAudioFileRead(ef, &got, &abl) != noErr || got == 0) break;
        feed_mono(NULL, buf, (int)got);
        fed += got;

        double due = (double)fed / rate;
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double el = (double)(now.tv_sec - t0.tv_sec) + (double)(now.tv_nsec - t0.tv_nsec) / 1e9;
        if (due > el) usleep((useconds_t)((due - el) * 1e6));
    }
    save_partial();
    free(buf);
    ExtAudioFileDispose(ef);
    return NULL;
}

/* -------------------------------------------------------------------- UI */

@interface PreviewView : NSView {
    CGImageRef _img;
    unsigned _rev;
    BOOL _hasRev;
}
- (void)refresh;
@end

static void free_rgb(void *info, const void *data, size_t size)
{
    (void)info; (void)size;
    free((void *)data);
}

@implementation PreviewView

- (BOOL)isOpaque { return YES; }

- (void)refresh { [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    [[NSColor colorWithCalibratedWhite:0.05 alpha:1.0] setFill];
    NSRectFill(self.bounds);
    if (!g_rx) return;

    SstvStatus st;
    int w = 0, h = 0;
    const uint16_t *px = NULL;
    float level = 0;

    pthread_mutex_lock(&g_lock);
    sstv_status(g_rx, &st);
    px = sstv_image(g_rx, &w, &h);
    if (px && w > 0 && h > 0 && (!_hasRev || st.revision != _rev)) {
        uint8_t *rgb = malloc((size_t)w * (size_t)h * 3u);
        if (rgb) {
            for (int i = 0; i < w * h; i++) {
                uint16_t v = px[i];
                unsigned r = (v >> 11) & 0x1f, g = (v >> 5) & 0x3f, b = v & 0x1f;
                rgb[i * 3 + 0] = (uint8_t)((r << 3) | (r >> 2));
                rgb[i * 3 + 1] = (uint8_t)((g << 2) | (g >> 4));
                rgb[i * 3 + 2] = (uint8_t)((b << 3) | (b >> 2));
            }
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, rgb,
                                    (size_t)w * (size_t)h * 3u, free_rgb);
            CGImageRef im = CGImageCreate((size_t)w, (size_t)h, 8, 24, (size_t)w * 3u, cs,
                                          kCGBitmapByteOrderDefault | kCGImageAlphaNone,
                                          dp, NULL, false, kCGRenderingIntentDefault);
            CGDataProviderRelease(dp);
            CGColorSpaceRelease(cs);
            if (im) {
                if (_img) CGImageRelease(_img);
                _img = im;
                _rev = st.revision;
                _hasRev = YES;
            }
        }
    }
    level = g_level;
    pthread_mutex_unlock(&g_lock);

    NSRect b = self.bounds;
    CGFloat barTop = 74, barBot = 26;
    NSRect imgArea = NSMakeRect(12, barBot + 10, b.size.width - 24, b.size.height - barTop - barBot - 10);

    if (_img) {
        size_t iw = CGImageGetWidth(_img), ih = CGImageGetHeight(_img);
        double sc = fmin(imgArea.size.width / (double)iw, imgArea.size.height / (double)ih);
        CGFloat dw = (CGFloat)(iw * sc), dh = (CGFloat)(ih * sc);
        NSRect dr = NSMakeRect(imgArea.origin.x + (imgArea.size.width - dw) / 2,
                               imgArea.origin.y + (imgArea.size.height - dh) / 2, dw, dh);
        CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, NSRectToCGRect(dr), _img);
        [[NSColor colorWithCalibratedWhite:0.35 alpha:1.0] setStroke];
        NSFrameRect(dr);
    } else {
        NSDictionary *a = @{ NSFontAttributeName: [NSFont systemFontOfSize:15],
                             NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.5 alpha:1] };
        NSString *msg = @"等待 SSTV 信号 · 自动识别，无需选模式";
        NSSize sz = [msg sizeWithAttributes:a];
        [msg drawAtPoint:NSMakePoint(imgArea.origin.x + (imgArea.size.width - sz.width) / 2,
                                     imgArea.origin.y + imgArea.size.height / 2)
          withAttributes:a];
        NSDictionary *al = @{ NSFontAttributeName: [NSFont systemFontOfSize:11],
                              NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.42 alpha:1] };
        NSArray<NSString *> *modes = supported_modes();
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        for (NSUInteger i = 0; i < modes.count; i += 4)
            [rows addObject:[[modes subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)4, modes.count - i))]
                             componentsJoinedByString:@"   "]];
        NSMutableString *blk = [NSMutableString stringWithString:@"听 VIS 头自动选模式；丢了 VIS 就靠行同步脉冲锁：\n"];
        for (NSString *r in rows) [blk appendFormat:@"%@\n", r];
        NSSize bs = [blk sizeWithAttributes:al];
        [blk drawAtPoint:NSMakePoint(imgArea.origin.x + (imgArea.size.width - bs.width) / 2,
                                     imgArea.origin.y + imgArea.size.height / 2 - bs.height - 8)
          withAttributes:al];
    }

    /* status text */
    NSFont *mono = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSDictionary *w1 = @{ NSFontAttributeName: [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightBold],
                          NSForegroundColorAttributeName: [NSColor whiteColor] };
    NSDictionary *w2 = @{ NSFontAttributeName: mono,
                          NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.78 alpha:1] };

    NSString *line1;
    if (st.state == SSTV_RX)
        line1 = [NSString stringWithFormat:@"%@  %@  %d/%d 行  (%s)", st.mode ? @(st.mode) : @"?", st.end_kind == SSTV_END_NONE ? @"接收中" : @"", st.line, st.height,
                 start_name(st.start_kind)];
    else if (st.mode)
        line1 = [NSString stringWithFormat:@"%@ 完成 · 已在听下一个（本轮 %d 张）", @(st.mode), g_nimg];
    else if (st.last_vis >= 0)
        line1 = [NSString stringWithFormat:@"待机 · 自动识别（上次 VIS %d%s）",
                 st.last_vis, st.last_vis_ok ? "" : "，本版不解"];
    else
        line1 = [NSString stringWithFormat:@"待机 · 自动识别（%lu 种模式）", (unsigned long)supported_modes().count];
    [line1 drawAtPoint:NSMakePoint(14, b.size.height - 56) withAttributes:w1];

    NSString *line2 = [NSString stringWithFormat:@"调谐 %d Hz (偏移 %+d)   时钟 %+d ppm%s   同步 %d/%d   电平 %.0f dBFS",
                        st.tone_hz, st.offset_hz, st.ppm, st.ppm_valid ? "" : "(先验)",
                        st.sync_good, st.sync_seen,
                        level > 0.0001f ? 20.0 * log10(level) : -99.0];
    [line2 drawAtPoint:NSMakePoint(14, b.size.height - 38) withAttributes:w2];

    NSString *line3 = g_lastSaved ? [NSString stringWithFormat:@"已存 %@", [g_lastSaved lastPathComponent]]
                                  : @"图片自动保存到输出目录";
    [line3 drawAtPoint:NSMakePoint(14, b.size.height - 22) withAttributes:w2];
    if (g_note) {
        NSDictionary *wn = @{ NSFontAttributeName: mono,
                              NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:1.0 green:0.62 blue:0.25 alpha:1] };
        [g_note drawAtPoint:NSMakePoint(14, imgArea.origin.y - 2 - 16) withAttributes:wn];
    }

    /* level meter (left) and tuning indicator (right) */
    CGFloat mw = (b.size.width - 40) / 2;
    NSRect lv = NSMakeRect(14, 10, mw, 12);
    [[NSColor colorWithCalibratedWhite:0.22 alpha:1] setFill];
    NSRectFill(lv);
    double dbfs = level > 0.0001f ? 20.0 * log10(level) : -60.0;
    double frac = (dbfs + 60.0) / 60.0;
    if (frac < 0) frac = 0; if (frac > 1) frac = 1;
    [[NSColor colorWithCalibratedRed:0.25 green:0.85 blue:0.45 alpha:1] setFill];
    NSRectFill(NSMakeRect(lv.origin.x, lv.origin.y, (CGFloat)(lv.size.width * frac), lv.size.height));
    /* -20 dBFS reference tick */
    [[NSColor colorWithCalibratedWhite:0.8 alpha:0.9] setFill];
    NSRectFill(NSMakeRect(lv.origin.x + (CGFloat)(lv.size.width * (40.0 / 60.0)), lv.origin.y, 1, lv.size.height));

    NSRect tb = NSMakeRect(b.size.width / 2 + 6, 10, mw, 12);
    [[NSColor colorWithCalibratedWhite:0.22 alpha:1] setFill];
    NSRectFill(tb);
    /* the sync/porch band the decoder cares about: 1500..2300 Hz, 1200 = black */
    double tf = (st.tone_hz - 1000.0) / 1400.0;
    if (tf < 0) tf = 0; if (tf > 1) tf = 1;
    [[NSColor colorWithCalibratedRed:0.85 green:0.3 blue:0.3 alpha:0.35] setFill];
    NSRectFill(NSMakeRect(tb.origin.x + (CGFloat)(tb.size.width * ((1500.0 - 1000.0) / 1400.0)),
                          tb.origin.y, (CGFloat)(tb.size.width * ((2300.0 - 1500.0) / 1400.0)), tb.size.height));
    [[NSColor colorWithCalibratedRed:1.0 green:0.82 blue:0.25 alpha:1] setFill];
    NSRectFill(NSMakeRect(tb.origin.x + (CGFloat)(tb.size.width * tf) - 2, tb.origin.y - 2, 4, tb.size.height + 4));
}

- (void)keyDown:(NSEvent *)e
{
    NSString *s = [e charactersIgnoringModifiers];
    if (s.length && ([s characterAtIndex:0] == 'q' || [s characterAtIndex:0] == 27))
        [NSApp terminate:nil];
    else
        [super keyDown:e];
}

@end

@interface AppDel : NSObject <NSApplicationDelegate>
@end
@implementation AppDel
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { (void)s; return YES; }
@end

static PreviewView *g_view = nil;

static void run_ui(NSString *title, void (^start)(void))
{
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    AppDel *del = [[AppDel alloc] init];
    [NSApp setDelegate:del];

    NSRect frame = NSMakeRect(0, 0, 760, 620);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    [win setTitle:title];
    [win center];
    g_view = [[PreviewView alloc] initWithFrame:frame];
    [win setContentView:g_view];
    [win makeFirstResponder:g_view];
    [win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (start) dispatch_async(dispatch_get_main_queue(), start);   /* capture after the window is up */

    NSTimer *t = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *tt) {
        (void)tt;
        [g_view refresh];
    }];
    [[NSRunLoop currentRunLoop] addTimer:t forMode:NSRunLoopCommonModes];

    [NSApp run];
}

/* ---------------------------------------------------------------- devices */

/* The microphone is a TCC-protected resource; ask once, and say what to do
 * when it is refused, instead of running on silence. */
static int mic_allowed(void)
{
    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (st == AVAuthorizationStatusAuthorized) return 1;
    if (st == AVAuthorizationStatusDenied || st == AVAuthorizationStatusRestricted) {
        fprintf(stderr, "麦克风权限被拒绝：系统设置 → 隐私与安全性 → 麦克风，勾选运行本程序的终端（Terminal / iTerm）\n");
        return 0;
    }
    __block BOOL granted = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok) {
        granted = ok;
        dispatch_semaphore_signal(sem);
    }];
    printf("等待麦克风授权…（若系统弹窗没出现，到 系统设置 → 隐私与安全性 → 麦克风 里勾选终端）\n");
    fflush(stdout);
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60LL * NSEC_PER_SEC));
    if (!granted) {
        fprintf(stderr, "没有麦克风权限，无法采集音频\n");
        return 0;
    }
    return 1;
}

/* Permission, device format negotiation, decoder creation, start. Returns 0
 * when samples are flowing. */
static int begin_capture(int device_index, int autosync, int have_ppm, int ppm)
{
    char err[512] = "";
    int rate = 0;

    g_note = @"等待麦克风授权…";
    if (!mic_allowed()) {
        g_note = @"没有麦克风权限：系统设置 → 隐私与安全性 → 麦克风";
        return 1;
    }

    /* Open the device first: the decoder must be built at the rate the unit
     * ends up running, and the hardware does not resample on input, so a
     * format it refuses only shows up once frames start flowing. Try the
     * device's own rate first, then the usual ones. */
    int cand[4] = { 0, 48000, 44100, 32000 };
    int opened = 0;
    err[0] = 0;
    for (int i = 0; i < 4 && !opened; i++) {
        if (audio_in_open(device_index, cand[i], feed_mono, feed_gap, NULL, &rate, err, sizeof err) != 0) {
            if (cand[i] == 0) {
                fprintf(stderr, "capture: %s\n", err[0] ? err : "failed");
                g_note = [NSString stringWithFormat:@"打不开输入设备：%s", err];
                return 1;
            }
            continue;
        }
        if (rate <= 0) rate = 48000;

        pthread_mutex_lock(&g_lock);
        g_rx = sstv_new(rate);
        g_rate = rate;
        g_samples = 0;
        g_level = 0;
        if (g_rx) {
            sstv_set_autosync(g_rx, autosync);
            if (have_ppm) sstv_set_ppm_prior(g_rx, ppm);
            sstv_status(g_rx, &g_prev);
            g_prev.last_vis = -1;
        }
        pthread_mutex_unlock(&g_lock);
        if (!g_rx) { fprintf(stderr, "decoder: out of memory\n"); audio_in_stop(); return 1; }

        if (audio_in_run() != 0) {
            pthread_mutex_lock(&g_lock); sstv_free(g_rx); g_rx = NULL; pthread_mutex_unlock(&g_lock);
            audio_in_stop();
            continue;
        }
        usleep(400000);                       /* let a few buffers through */
        if (audio_in_health() == 0) { opened = 1; break; }
        pthread_mutex_lock(&g_lock); sstv_free(g_rx); g_rx = NULL; pthread_mutex_unlock(&g_lock);
        audio_in_stop();
    }
    if (!opened) {
        fprintf(stderr, "capture: the device refused every sample rate we tried "
                        "(last error %d) — another app may be holding the input\n", audio_in_health());
        g_note = [NSString stringWithFormat:@"设备拒绝了所有采样率（%d），可能有别的程序占着输入", audio_in_health()];
        return 1;
    }
    g_note = nil;

    if (!g_quiet) {
        printf("capturing from \"%s\" at %d Hz, saving to %s\n",
               audio_in_device_name(), rate,
               [(g_outDir ?: @".") fileSystemRepresentation]);
        printf("plug the radio into the input; Ctrl-C to stop\n");
        fflush(stdout);
    }
    return 0;
}

static void live_cleanup(void)
{
    signal(SIGINT, SIG_DFL);
    audio_in_stop();          /* no more samples first, then keep what's on screen */
    save_partial();
    pthread_mutex_lock(&g_lock);
    sstv_free(g_rx);
    g_rx = NULL;
    pthread_mutex_unlock(&g_lock);
}

static int live_capture(int device_index, BOOL view, int autosync, int have_ppm, int ppm)
{
    if (view) {
        run_ui([NSString stringWithFormat:@"Apricot SSTV — %@", @(audio_in_device_name())],
               ^{ begin_capture(device_index, autosync, have_ppm, ppm); });
        live_cleanup();
        return 0;
    }

    if (begin_capture(device_index, autosync, have_ppm, ppm) != 0) return 1;
    signal(SIGINT, on_sigint);
    {
        time_t t0 = time(NULL), last = 0;
        while (!g_sigint) {
            usleep(200000);
            SstvStatus st;
            double t, lvl;
            pthread_mutex_lock(&g_lock);
            sstv_status(g_rx, &st);
            t = g_samples / g_rate;
            lvl = g_level;
            pthread_mutex_unlock(&g_lock);
            if (!g_quiet && time(NULL) - last >= 5) {
                last = time(NULL);
                printf("%6.1f s  %s  tone %d Hz  level %.0f dBFS  offset %+d Hz\n", t,
                       st.state == SSTV_RX ? st.mode : "listening", st.tone_hz,
                       lvl > 0.0001f ? 20.0 * log10(lvl) : -99.0, st.offset_hz);
                fflush(stdout);
                if (t <= 0.0 && time(NULL) - t0 >= 6)
                    fprintf(stderr, "warning: no audio is arriving — check the input device "
                                    "and the microphone permission of your terminal\n");
            }
        }
    }
    live_cleanup();
    return 0;
}

/* ------------------------------------------------------------------ main */

static void usage(const char *argv0)
{
    printf("Apricot SSTV for macOS — multi-mode SSTV decoder (14 modes)\n\n");
    printf("usage:\n");
    printf("  %s <file> [more files...]      decode recordings (wav/aiff/m4a/flac/caf ...)\n", argv0);
    printf("  %s --listen                    decode live from an audio input\n", argv0);
    printf("  %s --simulate <file>           replay a file in real time through the live path\n", argv0);
    printf("  %s --list                      list audio input devices\n\n", argv0);
    printf("options:\n");
    printf("  --out DIR        where PNGs go (default: next to the recording / current dir)\n");
    printf("  --prefix NAME    file name prefix for live/simulated runs (default: live)\n");
    printf("  --scale N        save PNGs at N x the decoded size (default 1)\n");
    printf("  --device N       input device index from --list (default: system default)\n");
    printf("  --no-view        no window (live / simulate)\n");
    printf("  --no-autosync    do not start on sync pulses when the VIS was missed\n");
    printf("  --ppm N          clock-error prior (ppm), used until the fit settles\n");
    printf("  --quiet          no event log\n");
    printf("  --modes          list the modes this build decodes, then exit\n\n");
    printf("modes: Robot 36/72, Martin M1/M2, Scottie S1/S2/DX, PD50/90/120/160/180/240/290\n");
}

int main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);

    NSMutableArray<NSString *> *files = [NSMutableArray array];
    BOOL listen = NO, view = YES, simulate = NO;
    const char *simfile = NULL;
    int device = -1, autosync = 1, have_ppm = 0, ppm = 0;
    NSString *outDir = nil, *prefix = nil;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--listen")) listen = YES;
        else if (!strcmp(argv[i], "--simulate") && i + 1 < argc) { simulate = YES; simfile = argv[++i]; }
        else if (!strcmp(argv[i], "--list")) { int n = audio_in_list(); return n > 0 ? 0 : 1; }
        else if (!strcmp(argv[i], "--modes")) {
            printf("VIS  mode          status\n");
            for (int v = 1; v < 128; v++) {
                const char *nm = sstv_vis_name(v);
                if (!nm) continue;
                printf("%3d  %-13s %s\n", v, nm,
                       sstv_vis_supported(v) ? "decoded" : "not decoded by this build");
            }
            printf("\nthe mode is read from the VIS header; if the VIS was missed the decoder\n"
                   "locks onto any supported mode's line syncs (-autosync, on by default)\n");
            return 0;
        }
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) outDir = @(argv[++i]);
        else if (!strcmp(argv[i], "--prefix") && i + 1 < argc) prefix = @(argv[++i]);
        else if (!strcmp(argv[i], "--scale") && i + 1 < argc) g_scale = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--device") && i + 1 < argc) device = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-view")) view = NO;
        else if (!strcmp(argv[i], "--no-autosync")) autosync = 0;
        else if (!strcmp(argv[i], "--ppm") && i + 1 < argc) { ppm = atoi(argv[++i]); have_ppm = 1; }
        else if (!strcmp(argv[i], "--quiet")) g_quiet = 1;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
        else if (argv[i][0] != '-') [files addObject:@(argv[i])];
        else { fprintf(stderr, "unknown option %s\n", argv[i]); usage(argv[0]); return 2; }
    }
    if (g_scale < 1) g_scale = 1;
    g_outDir = outDir ? [outDir stringByExpandingTildeInPath] : nil;

    @autoreleasepool {
        if (simulate) {
            if (!simfile) { usage(argv[0]); return 2; }
            g_prefix = prefix ?: @"live";
            SimCtx ctx = { [@(simfile) stringByExpandingTildeInPath] };
            pthread_t th;
            pthread_create(&th, NULL, sim_thread, &ctx);
            if (view) {
                run_ui([NSString stringWithFormat:@"Apricot SSTV — %@", [ctx.path lastPathComponent]], nil);
            } else {
                pthread_join(th, NULL);
                return 0;
            }
            g_sigint = 1;
            pthread_join(th, NULL);
            return 0;
        }

        if (listen) {
            g_prefix = prefix ?: @"live";
            return live_capture(device, view, autosync, have_ppm, ppm);
        }

        if (!files.count) {
            /* launched from the .app bundle with no arguments: go live */
            if ([[NSBundle mainBundle] bundleIdentifier] != nil) {
                g_prefix = prefix ?: @"live";
                return live_capture(device, YES, autosync, have_ppm, ppm);
            }
            usage(argv[0]);
            return 2;
        }
        int rc = 0;
        for (NSString *f in files) {
            NSString *path = [f stringByExpandingTildeInPath];
            if (prefix) {
                g_prefix = prefix;            /* one run, one numbering */
            } else {
                g_prefix = [[path lastPathComponent] stringByDeletingPathExtension];
                g_nimg = 0;                   /* per-recording numbering */
            }
            g_lastSaved = nil;
            if (decode_file(path, autosync, have_ppm, ppm) != 0) rc = 1;
        }
        return rc;
    }
}
