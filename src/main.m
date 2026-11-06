/* SPDX-License-Identifier: GPL-3.0-only */
/* main.m -- SSTV Tool for macOS (arm64): a desktop front end for the
 * portable decoder core in sstv_dsp.c (the one the iPod nano runs) and for the
 * transmitter in encode.m.
 *
 *   sstv-tool <file> [more files...]      decode recordings (any CoreAudio format)
 *   sstv-tool --listen [--device N]       live decode from an audio input
 *   sstv-tool --simulate <file>           replay a file in real time through
 *                                         the live path (with the on-screen UI)
 *   sstv-tool encode <image> [options]    make SSTV audio from a picture
 *   sstv-tool --list                      list audio input devices
 *
 * Pictures are written as PNG next to the recordings (or --out DIR), one file
 * per completed image, plus the one in progress at the end of a recording.
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
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
#include "encode.h"

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
static volatile sig_atomic_t g_sig_pause = 0, g_sig_cancel = 0;
static float g_level = 0.0f;          /* smoothed RMS of the decoded input, 0..1 */
static NSString *g_note = nil;        /* one line of state/warning for the window */
static int g_paused = 0;              /* 1 = not feeding the decoder (audio still runs) */
static NSSound *g_tx_sound = nil;      /* the WAV being sent, i.e. played out */
static double g_tx_total = 0;          /* its length, seconds */
static double g_tx_started = 0;        /* when playback started */
static NSString *g_tx_last = nil;      /* last WAV written by the transmitter */
static NSString *g_tx_note = nil;      /* one line about the transmission */
static NSString *g_send_image = nil;   /* --send: transmit this picture on startup */
static int g_send_play = 1;
static int g_mode_vis = 8;             /* --mode for --send */

static const char *zh_end(int k)
{
    switch (k) {
    case SSTV_END_COMPLETE: return "完成";
    case SSTV_END_LOST:     return "信号中断";
    case SSTV_END_ABORT:    return "已取消";
    case SSTV_END_NEWVIS:   return "被新信号打断";
    case SSTV_END_NOMEM:    return "内存不足";
    default:                return "结束";
    }
}

/* Launched from the .app there is no terminal: keep a log so "why did it stop
 * early" has an answer afterwards. */
static void setup_headless_log(void)
{
    if ([[NSBundle mainBundle] bundleIdentifier] == nil) return;   /* CLI: stdout is fine */
    if (isatty(fileno(stdout))) return;
    NSString *dir = [@"~/Library/Logs" stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                             attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:@"SSTV Tool.log"];
    FILE *f = freopen(path.fileSystemRepresentation, "a", stdout);
    if (!f) return;
    dup2(fileno(f), fileno(stderr));
    setvbuf(stdout, NULL, _IOLBF, 0);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    printf("\n=== %s ===\n", [[df stringFromDate:[NSDate date]] UTF8String]);
}

/* A stalled process (App Nap, a busy disk) makes the feeder thread fall behind,
 * the ring overruns, and the decoder sees a hole long enough to give up. Hold
 * the process awake while we listen. */
static id g_activity = nil;
static void keep_awake(NSString *why)
{
    if (g_activity) return;
    g_activity = [[NSProcessInfo processInfo]
                  beginActivityWithOptions:(NSActivityLatencyCritical | NSActivityUserInitiated)
                                    reason:why];
}

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
    if (g_sig_pause) {
        g_sig_pause = 0;
        g_paused = !g_paused;
        g_note = g_paused ? @"已暂停 · 空格或「继续」接着收" : nil;
    }
    if (g_sig_cancel) {
        g_sig_cancel = 0;
        if (g_rx) sstv_abort(g_rx);
    }
    if (g_paused) {
        /* tell the decoder these samples were lost, so its time base stays
         * exact and the rows in the gap are simply not drawn */
        sstv_gap(g_rx, n);
    } else {
        sstv_feed(g_rx, x, n, 1);
    }
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
        if (g_st.end_kind == SSTV_END_LOST)
            g_note = [NSString stringWithFormat:@"信号中断：%.0f 秒没同步脉冲，已把到第 %d 行的图存盘（--lost 可放宽）",
                      sstv_get_lost_seconds(), g_st.line];
        else if (g_st.end_kind == SSTV_END_COMPLETE)
            g_note = nil;
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

static void on_sig_pause(int sig)  { (void)sig; g_sig_pause = 1; }
static void on_sig_cancel(int sig) { (void)sig; g_sig_cancel = 1; }

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

    keep_awake(@"SSTV replay");
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
    NSButton *_pauseBtn;
    NSButton *_cancelBtn;
    NSPopUpButton *_modePop;
    NSButton *_txPlayBtn;
    NSButton *_txSaveBtn;
    NSButton *_txStopBtn;
}
- (void)refresh;
@end

static void free_rgb(void *info, const void *data, size_t size)
{
    (void)info; (void)size;
    free((void *)data);
}

@implementation PreviewView

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        /* the picture area is black; dark appearance keeps the buttons legible */
        [self setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
        _pauseBtn = [[NSButton alloc] initWithFrame:NSMakeRect(14, 6, 92, 24)];
        [_pauseBtn setTitle:@"暂停"];
        [_pauseBtn setBezelStyle:NSBezelStyleRounded];
        [_pauseBtn setTarget:self];
        [_pauseBtn setAction:@selector(togglePause:)];
        [_pauseBtn setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
        [_pauseBtn setToolTip:@"暂停接收（空格）：画面停住，音频照样在跑"];
        [self addSubview:_pauseBtn];

        _modePop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(14, 36, 132, 24) pullsDown:NO];
        for (int v = 1; v < 128; v++) {
            const char *nm = encode_mode_name(v);
            if (!nm) continue;
            [_modePop addItemWithTitle:@(nm)];
            [[_modePop lastItem] setTag:v];
            if (v == 8) [_modePop selectItem:[_modePop lastItem]];
        }
        [_modePop setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
        [_modePop setToolTip:@"发送用的模式（接收侧是自动识别的，跟这里无关）"];
        [self addSubview:_modePop];

        _txPlayBtn = [[NSButton alloc] initWithFrame:NSMakeRect(152, 36, 122, 24)];
        [_txPlayBtn setTitle:@"发图片并播放"];
        [_txPlayBtn setBezelStyle:NSBezelStyleRounded];
        [_txPlayBtn setTarget:self];
        [_txPlayBtn setAction:@selector(txPlay:)];
        [_txPlayBtn setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
        [_txPlayBtn setToolTip:@"选一张图，按当前模式生成 SSTV 音频并从默认输出播放"];
        [self addSubview:_txPlayBtn];

        _txSaveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(278, 36, 96, 24)];
        [_txSaveBtn setTitle:@"存成 WAV"];
        [_txSaveBtn setBezelStyle:NSBezelStyleRounded];
        [_txSaveBtn setTarget:self];
        [_txSaveBtn setAction:@selector(txSave:)];
        [_txSaveBtn setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
        [_txSaveBtn setToolTip:@"只生成 WAV，不播放"];
        [self addSubview:_txSaveBtn];

        _txStopBtn = [[NSButton alloc] initWithFrame:NSMakeRect(378, 36, 62, 24)];
        [_txStopBtn setTitle:@"停止"];
        [_txStopBtn setBezelStyle:NSBezelStyleRounded];
        [_txStopBtn setTarget:self];
        [_txStopBtn setAction:@selector(txStop:)];
        [_txStopBtn setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
        [self addSubview:_txStopBtn];

        _cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(112, 6, 100, 24)];
        [_cancelBtn setTitle:@"取消这张"];
        [_cancelBtn setBezelStyle:NSBezelStyleRounded];
        [_cancelBtn setTarget:self];
        [_cancelBtn setAction:@selector(cancelShot:)];
        [_cancelBtn setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
        [_cancelBtn setToolTip:@"放弃正在收的这张图（X）：已解出的部分照样存盘"];
        [self addSubview:_cancelBtn];
    }
    return self;
}

- (void)togglePause:(id)sender
{
    (void)sender;
    pthread_mutex_lock(&g_lock);
    g_paused = !g_paused;
    g_note = g_paused ? @"已暂停：画面停在这一行，恢复后从下一行接着收" : nil;
    pthread_mutex_unlock(&g_lock);
    [self.window makeFirstResponder:self];      /* keep space/x working */
    [self setNeedsDisplay:YES];
}

- (void)cancelShot:(id)sender
{
    (void)sender;
    pthread_mutex_lock(&g_lock);
    if (g_rx) sstv_abort(g_rx);          /* picture kept; the feed path saves it */
    pthread_mutex_unlock(&g_lock);
    [self.window makeFirstResponder:self];
    [self setNeedsDisplay:YES];
}

/* ---- transmit: picture -> SSTV WAV -> speaker line ---- */

- (void)txStop:(id)sender
{
    (void)sender;
    if (g_tx_sound) [g_tx_sound stop];
    g_tx_sound = nil;
    [self.window makeFirstResponder:self];
    [self setNeedsDisplay:YES];
}

- (void)txPlay:(id)sender { (void)sender; [self sendImage:YES]; }
- (void)txSave:(id)sender { (void)sender; [self sendImage:NO]; }

- (void)sendImage:(BOOL)play
{
    [self.window makeFirstResponder:self];
    NSMenuItem *item = [_modePop selectedItem];
    NSString *modeTitle = item ? [item title] : @"Robot 36";

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setAllowsMultipleSelection:NO];
    [panel setMessage:@"选一张要发送的图片"];
    if ([panel runModal] != NSModalResponseOK) return;
    NSString *img = [[panel URL] path];

    NSString *wav = nil;
    if (play) {
        NSString *dir = [@"~/Music/SSTV Tool" stringByExpandingTildeInPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                 attributes:nil error:NULL];
        wav = [dir stringByAppendingPathComponent:
               [NSString stringWithFormat:@"%@-%@.wav",
                [[img lastPathComponent] stringByDeletingPathExtension], modeTitle]];
    } else {
        NSSavePanel *save = [NSSavePanel savePanel];
        [save setAllowedContentTypes:@[ [UTType typeWithFilenameExtension:@"wav"] ]];
        [save setNameFieldStringValue:[NSString stringWithFormat:@"%@-%@.wav",
                                       [[img lastPathComponent] stringByDeletingPathExtension], modeTitle]];
        if ([save runModal] != NSModalResponseOK) return;
        wav = [[save URL] path];
    }
    [self encodeAndSend:img to:wav play:play];
}

/* encode one picture, then play it (or just report where it landed) */
- (void)encodeAndSend:(NSString *)img to:(NSString *)wav play:(BOOL)play
{
    NSMenuItem *item = [_modePop selectedItem];
    int vis = item ? (int)[item tag] : 8;
    NSString *modeTitle = item ? [item title] : @"Robot 36";
    EncodeOpts o;
    encode_defaults(&o);
    o.vis = vis;
    o.play = 0;                         /* playback is managed here */
    char err[512] = "";
    long frames = 0;

    g_tx_note = [NSString stringWithFormat:@"正在生成 %@ …", modeTitle];
    [self setNeedsDisplay:YES];

    if (encode_image(img.fileSystemRepresentation, wav.fileSystemRepresentation, &o,
                     err, sizeof err, &frames) != 0) {
        g_tx_note = [NSString stringWithFormat:@"生成失败：%s", err[0] ? err : "未知错误"];
        [self setNeedsDisplay:YES];
        return;
    }
    g_tx_last = wav;
    g_tx_total = frames > 0 ? (double)frames / o.rate : 0;

    if (!play) {
        g_tx_note = [NSString stringWithFormat:@"已存 %@（%.0f 秒）", [wav lastPathComponent], g_tx_total];
        [self setNeedsDisplay:YES];
        return;
    }

    [self txStop:nil];
    NSSound *snd = [[NSSound alloc] initWithContentsOfFile:wav byReference:YES];
    if (!snd || ![snd play]) {
        g_tx_note = @"播放失败（文件已生成，可手动播放）";
        [self setNeedsDisplay:YES];
        return;
    }
    g_tx_sound = snd;
    g_tx_started = [NSDate timeIntervalSinceReferenceDate];
    g_tx_note = nil;
    [self setNeedsDisplay:YES];
}

- (void)selectModeByVis:(int)vis
{
    for (NSMenuItem *it in [_modePop itemArray])
        if ((int)[it tag] == vis) { [_modePop selectItem:it]; break; }
}

/* the --send path: no file pickers, straight to encoding and playback */
- (void)startSendPath:(NSString *)img play:(BOOL)play
{
    NSMenuItem *item = [_modePop selectedItem];
    NSString *modeTitle = item ? [item title] : @"Robot 36";
    NSString *dir = [@"~/Music/SSTV Tool" stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                             attributes:nil error:NULL];
    NSString *wav = [dir stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@-%@.wav",
                      [[img lastPathComponent] stringByDeletingPathExtension], modeTitle]];
    [self encodeAndSend:img to:wav play:play];
}

- (BOOL)isOpaque { return YES; }

- (void)refresh { [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    [[NSColor colorWithCalibratedWhite:0.05 alpha:1.0] setFill];
    NSRectFill(self.bounds);
    if (!g_rx && !g_tx_sound && !g_tx_note) return;

    SstvStatus st;
    memset(&st, 0, sizeof st);
    int w = 0, h = 0;
    const uint16_t *px = NULL;
    float level = 0;

    pthread_mutex_lock(&g_lock);
    if (g_rx) sstv_status(g_rx, &st);
    px = g_rx ? sstv_image(g_rx, &w, &h) : NULL;
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
    CGFloat barTop = 74, barBot = 66;
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
        NSString *msg = g_rx ? @"等待 SSTV 信号 · 自动识别，无需选模式"
                             : @"发送模式 · 窗口只用于发图（接收请直接打开 App）";
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
        NSMutableString *blk = [NSMutableString stringWithString:
            g_rx ? @"听 VIS 头自动选模式；丢了 VIS 就靠行同步脉冲锁：\n"
                 : @"选模式 → 「发图片并播放」或「存成 WAV」：\n"];
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
    if (!g_rx)
        line1 = @"发送模式 · 不接收";
    else if (st.state == SSTV_RX)
        line1 = [NSString stringWithFormat:@"%@  %@  %d/%d 行  (%s)", st.mode ? @(st.mode) : @"?", st.end_kind == SSTV_END_NONE ? @"接收中" : @"", st.line, st.height,
                 start_name(st.start_kind)];
    else if (st.mode)
        line1 = [NSString stringWithFormat:@"%@ %s · 已在听下一个（本轮 %d 张）",
                 @(st.mode), zh_end(st.end_kind), g_nimg];
    else if (st.last_vis >= 0)
        line1 = [NSString stringWithFormat:@"待机 · 自动识别（上次 VIS %d%s）",
                 st.last_vis, st.last_vis_ok ? "" : "，本版不解"];
    else
        line1 = [NSString stringWithFormat:@"待机 · 自动识别（%lu 种模式）", (unsigned long)supported_modes().count];
    [line1 drawAtPoint:NSMakePoint(14, b.size.height - 56) withAttributes:w1];

    NSString *line2;
    if (!g_rx)
        line2 = @"输出：系统默认设备   ·   生成的 WAV 存在 ~/Music/SSTV Tool";
    else {
        unsigned long long dropped = audio_in_lost();
        line2 = [NSString stringWithFormat:@"调谐 %d Hz (偏移 %+d)   时钟 %+d ppm%s   同步 %d/%d   电平 %.0f dBFS%s",
                 st.tone_hz, st.offset_hz, st.ppm, st.ppm_valid ? "" : "(先验)",
                 st.sync_good, st.sync_seen,
                 level > 0.0001f ? 20.0 * log10(level) : -99.0,
                 dropped ? [[NSString stringWithFormat:@"   丢样 %llu", dropped] UTF8String] : ""];
    }
    [line2 drawAtPoint:NSMakePoint(14, b.size.height - 38) withAttributes:w2];

    NSString *line3 = g_lastSaved ? [NSString stringWithFormat:@"已存 %@", [g_lastSaved lastPathComponent]]
                                  : @"图片自动保存到输出目录";
    [line3 drawAtPoint:NSMakePoint(14, b.size.height - 22) withAttributes:w2];

    if (g_paused) {
        /* dim the picture and say so: the capture is still running */
        [[NSColor colorWithCalibratedWhite:0.0 alpha:0.45] setFill];
        NSRectFill(imgArea);
        NSDictionary *pa = @{ NSFontAttributeName: [NSFont systemFontOfSize:17 weight:NSFontWeightMedium],
                              NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:0.92] };
        NSString *pm = @"已暂停";
        NSSize psz = [pm sizeWithAttributes:pa];
        [pm drawAtPoint:NSMakePoint(imgArea.origin.x + (imgArea.size.width - psz.width) / 2,
                                    imgArea.origin.y + imgArea.size.height / 2)
          withAttributes:pa];
    }
    [_pauseBtn setTitle:(g_paused ? @"继续" : @"暂停")];
    [_cancelBtn setEnabled:(st.state == SSTV_RX)];

    /* level meter (left) and tuning indicator (right) */
    CGFloat mw = (b.size.width - 240) / 2;
    if (mw < 40) mw = 40;
    NSRect lv = NSMakeRect(224, 10, mw, 12);
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

    NSRect tb = NSMakeRect(224 + mw + 8, 10, mw, 12);
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

    /* transmit progress: what is being sent, how far in, and to which file */
    double txFrac = 0;
    NSString *txLine = nil;
    if (g_tx_sound) {
        double el = [NSDate timeIntervalSinceReferenceDate] - g_tx_started;
        if (![g_tx_sound isPlaying] || (g_tx_total > 0 && el >= g_tx_total)) {
            g_tx_sound = nil;
            g_tx_note = @"发射结束";
        } else if (g_tx_total > 0) {
            txFrac = el / g_tx_total;
            txLine = [NSString stringWithFormat:@"正在发射 %.0f%%  剩 %.0f s  %@",
                      txFrac * 100.0, g_tx_total - el, [(g_tx_last ?: @"") lastPathComponent]];
        }
    }
    if (txLine || g_tx_note) {
        NSString *line = txLine ?: g_tx_note;
        NSDictionary *wa = @{ NSFontAttributeName: [NSFont systemFontOfSize:11],
                              NSForegroundColorAttributeName:
                                  [NSColor colorWithCalibratedRed:1.0 green:0.66 blue:0.3 alpha:1] };
        CGFloat txX = b.size.width / 2 - 10;
        CGFloat txW = b.size.width - txX - 14;
        if (txW > 40) {
            [line drawInRect:NSMakeRect(txX, 62, txW, 16) withAttributes:wa];
            NSRect bar = NSMakeRect(txX, 42, txW, 10);
            [[NSColor colorWithCalibratedWhite:0.22 alpha:1] setFill];
            NSRectFill(bar);
            if (txLine) {
                [[NSColor colorWithCalibratedRed:0.95 green:0.55 blue:0.25 alpha:1] setFill];
                NSRectFill(NSMakeRect(bar.origin.x, bar.origin.y,
                                      (CGFloat)(bar.size.width * txFrac), bar.size.height));
            }
        }
    }

    /* hint / warning line, right of the buttons and above the meters */
    if (g_note) {
        NSDictionary *wn = @{ NSFontAttributeName: [NSFont systemFontOfSize:11],
                              NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:1.0 green:0.66 blue:0.3 alpha:1] };
        NSPoint at = NSMakePoint(224, 26);
        NSRect room = NSMakeRect(224, 24, b.size.width - 238, 16);
        [g_note drawInRect:room withAttributes:wn];
        (void)at;
    }
}

- (void)keyDown:(NSEvent *)e
{
    NSString *s = [e charactersIgnoringModifiers];
    if (!s.length) return;
    unichar c = [s characterAtIndex:0];
    if (c == 'q' || c == 27) [NSApp terminate:nil];
    else if (c == ' ') [self togglePause:nil];
    else if (c == 'x' || c == 'X') [self cancelShot:nil];
    else [super keyDown:e];
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

    NSRect frame = NSMakeRect(0, 0, 820, 660);
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

    keep_awake(@"SSTV receive");

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
        run_ui([NSString stringWithFormat:@"SSTV Tool — %@", @(audio_in_device_name())],
               ^{ begin_capture(device_index, autosync, have_ppm, ppm); });
        live_cleanup();
        return 0;
    }

    if (begin_capture(device_index, autosync, have_ppm, ppm) != 0) return 1;
    signal(SIGINT, on_sigint);
    signal(SIGUSR1, on_sig_pause);
    signal(SIGUSR2, on_sig_cancel);
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

static void encode_usage(const char *argv0)
{
    printf("usage:\n");
    printf("  %s encode <image> [options]    make SSTV audio from a picture\n", argv0);
    printf("  %s encode --list-modes         list what it can send\n\n", argv0);
    printf("options:\n");
    printf("  --mode M         mode name or VIS code (default 8 Robot 36; e.g. pd120, m1, s2)\n");
    printf("  --out FILE       output WAV (default: <image>-<mode>.wav next to the image)\n");
    printf("  --rate HZ        sample rate (default 44100)\n");
    printf("  --fit MODE       letterbox (default, keeps the aspect with black borders),\n");
    printf("                   fill (crop to fill), stretch\n");
    printf("  --text STRING    text overlay in the lower left corner\n");
    printf("  --lead S         silence before the picture (default 0.7)\n");
    printf("  --tail S         silence after it (default 0.5)\n");
    printf("  --gain F         amplitude 0..1 (default 0.9)\n");
    printf("  --ppm N          simulate the sender's clock error\n");
    printf("  --offset HZ      simulate mistuning\n");
    printf("  --snr DB         add noise (measured in 3 kHz)\n");
    printf("  --play           play the result through the default output as it is written\n");
    printf("  --no-wait        with --play: do not wait for playback to finish\n\n");
}

static void usage(const char *argv0)
{
    printf("SSTV Tool for macOS — multi-mode SSTV receiver and transmitter (14 modes)\n\n");
    printf("usage:\n");
    printf("  %s <file> [more files...]      decode recordings (wav/aiff/m4a/flac/caf ...)\n", argv0);
    printf("  %s --listen                    decode live from an audio input\n", argv0);
    printf("  %s --simulate <file>           replay a file in real time through the live path\n", argv0);
    printf("  %s encode <image>              make SSTV audio from a picture (see '%s encode -h')\n", argv0, argv0);
    printf("  %s --send <image> [--mode M]   send a picture from the window (progress bar)\n", argv0);
    printf("  %s --list                      list audio input devices\n\n", argv0);
    printf("options:\n");
    printf("  --out DIR        where PNGs go (default: next to the recording / current dir)\n");
    printf("  --prefix NAME    file name prefix for live/simulated runs (default: live)\n");
    printf("  --scale N        save PNGs at N x the decoded size (default 1)\n");
    printf("  --device N       input device index from --list (default: system default)\n");
    printf("  --no-view        no window (live / simulate)\n");
    printf("  --no-autosync    do not start on sync pulses when the VIS was missed\n");
    printf("  --ppm N          clock-error prior (ppm), used until the fit settles\n");
    printf("  --lost S         give up on a picture after S seconds without sync (default 12;\n");
    printf("                   a marginal or fading signal survives longer with a bigger value)\n");
    printf("  --quiet          no event log\n");
    printf("  --modes          list the modes this build decodes, then exit\n\n");
    printf("modes: Robot 36/72, Martin M1/M2, Scottie S1/S2/DX, PD50/90/120/160/180/240/290\n");
}

/* ---------------------------------------------------------------- encode */

static int encode_cli(int argc, char **argv)
{
    EncodeOpts o;
    encode_defaults(&o);
    const char *image = NULL, *text = NULL;
    NSString *outPath = nil;
    int fit = 0;

    for (int i = 2; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) { encode_usage(argv[0]); return 0; }
        else if (!strcmp(a, "--list-modes")) { encode_list_modes(); return 0; }
        else if (!strcmp(a, "--mode") && i + 1 < argc) {
            int v = encode_mode_from_string(argv[++i]);
            if (v < 0) { fprintf(stderr, "unknown mode \"%s\" (see --list-modes)\n", argv[i]); return 2; }
            o.vis = v;
        }
        else if (!strcmp(a, "--out") && i + 1 < argc) outPath = @(argv[++i]);
        else if (!strcmp(a, "--rate") && i + 1 < argc) o.rate = atoi(argv[++i]);
        else if (!strcmp(a, "--lead") && i + 1 < argc) o.lead_s = atof(argv[++i]);
        else if (!strcmp(a, "--tail") && i + 1 < argc) o.tail_s = atof(argv[++i]);
        else if (!strcmp(a, "--gain") && i + 1 < argc) o.amplitude = atof(argv[++i]);
        else if (!strcmp(a, "--ppm") && i + 1 < argc) o.skew_ppm = atof(argv[++i]);
        else if (!strcmp(a, "--offset") && i + 1 < argc) o.offset_hz = atof(argv[++i]);
        else if (!strcmp(a, "--snr") && i + 1 < argc) o.snr_db = atof(argv[++i]);
        else if (!strcmp(a, "--text") && i + 1 < argc) text = argv[++i];
        else if (!strcmp(a, "--play")) o.play = 1;
        else if (!strcmp(a, "--no-wait")) o.wait_play = 0;
        else if (!strcmp(a, "--fit") && i + 1 < argc) {
            const char *f = argv[++i];
            if (!strcmp(f, "letterbox") || !strcmp(f, "keep")) fit = 0;
            else if (!strcmp(f, "fill") || !strcmp(f, "crop")) fit = 1;
            else if (!strcmp(f, "stretch")) fit = 2;
            else { fprintf(stderr, "unknown --fit \"%s\"\n", f); return 2; }
        }
        else if (!image) image = a;
        else { fprintf(stderr, "unexpected argument \"%s\"\n", a); return 2; }
    }
    if (!image) { encode_usage(argv[0]); return 2; }
    o.fit = fit;
    o.text = text;
    if (o.rate < 8000 || o.rate > 192000) { fprintf(stderr, "rate %d out of range\n", o.rate); return 2; }

    NSString *img = [@(image) stringByExpandingTildeInPath];
    const char *mn = encode_mode_name(o.vis);
    char clean[64] = "sstv";
    for (int k = 0, j = 0; mn && mn[k] && j < 63; k++)
        if (isalnum((unsigned char)mn[k])) clean[j++] = mn[k];

    if (!outPath) {
        outPath = [[img stringByDeletingPathExtension] stringByAppendingFormat:@"-%s.wav", clean];
    } else if (![[outPath pathExtension] length] || [[outPath pathExtension] isEqualToString:@"dir"]) {
        NSString *base = [[img lastPathComponent] stringByDeletingPathExtension];
        outPath = [outPath stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"%@-%s.wav", base, clean]];
    }
    outPath = [outPath stringByExpandingTildeInPath];

    char err[512] = "";
    long frames = 0;
    if (encode_image(img.fileSystemRepresentation, outPath.fileSystemRepresentation, &o,
                     err, sizeof err, &frames) != 0) {
        fprintf(stderr, "encode: %s\n", err[0] ? err : "failed");
        return 1;
    }
    int mw = 0, mh = 0;
    {
        /* picture size of the mode, for the one-line report */
        extern int enc_mode_size(int, int *, int *);
        enc_mode_size(o.vis, &mw, &mh);
    }
    if (!g_quiet)
        printf("%s  %dx%d  %.1f s @ %d Hz -> %s\n", mn ? mn : "mode ?", mw, mh,
               (double)frames / o.rate, o.rate, outPath.fileSystemRepresentation);
    return 0;
}

int main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool { setup_headless_log(); }

    if (argc > 1 && !strcmp(argv[1], "encode")) {
        @autoreleasepool { return encode_cli(argc, argv); }
    }
    if (argc > 1 && !strcmp(argv[1], "decode")) {     /* symmetric spelling */
        for (int i = 1; i + 1 < argc; i++) argv[i] = argv[i + 1];
        argc--;
    }

    NSMutableArray<NSString *> *files = [NSMutableArray array];
    BOOL listen = NO, view = YES, simulate = NO;
    const char *simfile = NULL;
    int device = -1, autosync = 1, have_ppm = 0, ppm = 0;
    double lost_s = 0;
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
        else if (!strcmp(argv[i], "--lost") && i + 1 < argc) lost_s = atof(argv[++i]);
        else if (!strcmp(argv[i], "--quiet")) g_quiet = 1;
        else if (!strcmp(argv[i], "--send") && i + 1 < argc) g_send_image = [@(argv[++i]) stringByExpandingTildeInPath];
        else if (!strcmp(argv[i], "--no-play")) g_send_play = 0;
        else if (!strcmp(argv[i], "--mode") && i + 1 < argc) {
            int v = encode_mode_from_string(argv[++i]);
            if (v < 0) { fprintf(stderr, "unknown mode \"%s\"\n", argv[i]); return 2; }
            g_mode_vis = v;
        }
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
        else if (argv[i][0] != '-') [files addObject:@(argv[i])];
        else { fprintf(stderr, "unknown option %s\n", argv[i]); usage(argv[0]); return 2; }
    }
    if (g_scale < 1) g_scale = 1;
    if (lost_s > 0) sstv_set_lost_seconds(lost_s, lost_s / 2.0);
    g_outDir = outDir ? [outDir stringByExpandingTildeInPath] : nil;

    @autoreleasepool {
        if (g_send_image) {
            /* transmitter only: window, no capture */
            NSString *img = g_send_image;
            run_ui([NSString stringWithFormat:@"SSTV Tool — 发送 %@", [img lastPathComponent]], ^{
                if (g_mode_vis > 0) [g_view selectModeByVis:g_mode_vis];
                [g_view startSendPath:img play:g_send_play];
            });
            return 0;
        }

        if (simulate) {
            if (!simfile) { usage(argv[0]); return 2; }
            g_prefix = prefix ?: @"live";
            signal(SIGUSR1, on_sig_pause);
            signal(SIGUSR2, on_sig_cancel);
            SimCtx ctx = { [@(simfile) stringByExpandingTildeInPath] };
            pthread_t th;
            pthread_create(&th, NULL, sim_thread, &ctx);
            if (view) {
                run_ui([NSString stringWithFormat:@"SSTV Tool — %@", [ctx.path lastPathComponent]], nil);
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
