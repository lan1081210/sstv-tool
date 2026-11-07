/* SPDX-License-Identifier: GPL-3.0-only */
/* encode.m -- picture -> SSTV WAV, the transmit side of the tool.
 *
 * The waveform itself comes from tools/enc.c (the host encoder that ships with
 * the decoder); this file is the desktop skin around it: any image format in,
 * aspect ratio kept with black borders, optional text overlay, WAV out, and
 * optional playback so a radio can be fed straight away. The feature list
 * follows SSTVEncoder2 (olgamiller): pick mode, keep aspect, overlay text,
 * save as WAVE, play.
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <CoreText/CoreText.h>
#include <ImageIO/ImageIO.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>

#include "encode.h"
#include "enc.h"
#include "util.h"

void encode_defaults(EncodeOpts *o)
{
    memset(o, 0, sizeof *o);
    o->vis = 8;              /* Robot 36 */
    o->rate = 44100;
    o->lead_s = 0.7;
    o->tail_s = 0.5;
    o->snr_db = 99.0;
    o->amplitude = 12000.0;   /* s16 units, like enc.c's own default (not 0..1!) */
    o->fit = 0;
    o->rot = 0;
    o->flip_h = o->flip_v = 0;
    o->pan_x = o->pan_y = 0.0;
    o->zoom = 1.0;
    o->brightness = 0.0;
    o->contrast = 1.0;
    o->text = NULL;
    o->text_pos = 1;              /* lower left, like the old behaviour */
    o->text_scale = 1.0;
    o->play = 0;
    o->wait_play = 1;
}

/* compare ignoring case, spaces and separators: "Robot36" == "robot 36" */
static int norm_eq(const char *a, const char *b)
{
    char x[64], y[64];
    int i = 0, j = 0;
    for (; *a && i < 63; a++)
        if (isalnum((unsigned char)*a)) x[i++] = (char)tolower((unsigned char)*a);
    for (; *b && j < 63; b++)
        if (isalnum((unsigned char)*b)) y[j++] = (char)tolower((unsigned char)*b);
    x[i] = 0; y[j] = 0;
    if (!strcmp(x, y)) return 1;
    /* "m1" / "martin1": accept a family prefix too */
    return 0;
}

int encode_mode_from_string(const char *s)
{
    if (!s || !*s) return -1;
    int only_digits = 1;
    for (const char *p = s; *p; p++) if (!isdigit((unsigned char)*p)) { only_digits = 0; break; }
    if (only_digits) {
        int v = atoi(s), w, h;
        return enc_mode_size(v, &w, &h) ? v : -1;
    }
    for (int v = 1; v < 128; v++) {
        int w, h;
        if (!enc_mode_size(v, &w, &h)) continue;
        const char *nm = enc_mode_name(v);
        if (nm && norm_eq(s, nm)) return v;
    }
    /* short forms: "M1" (last word), "r36" / "sdx" (family initial + last word) */
    for (int v = 1; v < 128; v++) {
        int w, h;
        if (!enc_mode_size(v, &w, &h)) continue;
        const char *nm = enc_mode_name(v);
        if (!nm) continue;
        const char *last = strrchr(nm, ' ');
        last = last ? last + 1 : nm;                    /* "M1" from "Martin M1" */
        char cand[64];
        if (norm_eq(s, last)) return v;
        snprintf(cand, sizeof cand, "%c%s", nm[0], last);          /* r36, sdx */
        if (norm_eq(s, cand)) return v;
        snprintf(cand, sizeof cand, "%c%s", tolower((unsigned char)nm[0]), last);
        if (norm_eq(s, cand)) return v;
    }
    return -1;
}

static CGImageRef load_image(const char *path)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path,
                                                           (CFIndex)strlen(path), false);
    if (!url) return NULL;
    CGImageSourceRef src = CGImageSourceCreateWithURL(url, NULL);
    CFRelease(url);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    return img;
}

/* Draw the picture into an RGB888 buffer of exactly mw x mh: fit, rotation,
 * flips, zoom, pan, brightness/contrast and the text overlay -- the same code
 * path the modulator uses, so the editor previews exactly what will be sent. */
int encode_render_rgb(CGImageRef img, int mw, int mh, const EncodeOpts *o, uint8_t *rgb)
{
    if (!img || !rgb || mw <= 0 || mh <= 0) return -1;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)mw, (size_t)mh, 8, (size_t)mw * 4u,
                                             cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return -1;

    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, mw, mh));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);

    const double iw = (double)CGImageGetWidth(img), ih = (double)CGImageGetHeight(img);
    int rot = ((o->rot % 360) + 360) % 360;
    int swap = (rot == 90 || rot == 270);
    const double rw = swap ? ih : iw, rh = swap ? iw : ih;      /* bounds after rotation */
    double zoom = o->zoom > 0.05 ? o->zoom : 1.0;

    double sc;
    if (o->fit == 2) sc = zoom;                                  /* stretch: fill the frame */
    else if (o->fit == 1) sc = fmax(mw / rw, mh / rh) * zoom;    /* fill / crop */
    else sc = fmin(mw / rw, mh / rh) * zoom;                     /* letterbox */
    if (sc <= 0) sc = 1;

    const double dw = iw * sc, dh = ih * sc;
    double slack_x = fmax(0.0, (dw - mw) / 2.0), slack_y = fmax(0.0, (dh - mh) / 2.0);
    double ox = (o->pan_x < -1 ? -1 : o->pan_x > 1 ? 1 : o->pan_x) * slack_x;
    double oy = (o->pan_y < -1 ? -1 : o->pan_y > 1 ? 1 : o->pan_y) * slack_y;

    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(0, 0, mw, mh));
    CGContextTranslateCTM(ctx, mw / 2.0 + ox, mh / 2.0 + oy);
    CGContextRotateCTM(ctx, rot * M_PI / 180.0);
    CGContextScaleCTM(ctx, o->flip_h ? -1 : 1, o->flip_v ? -1 : 1);
    if (o->fit == 2) {
        double fw = swap ? mh : mw, fh = swap ? mw : mh;
        CGContextDrawImage(ctx, CGRectMake(-fw / 2.0, -fh / 2.0, fw, fh), img);
    } else {
        CGContextDrawImage(ctx, CGRectMake(-dw / 2.0, -dh / 2.0, dw, dh), img);
    }
    CGContextRestoreGState(ctx);

    /* text overlay, anchored like a numpad: 1 lower-left ... 9 upper-right */
    if (o->text && *o->text && o->text_pos >= 0) {
        double size = (mh / 12.0) * (o->text_scale > 0.1 ? o->text_scale : 1.0);
        if (size < 7) size = 7;
        CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), size, NULL);
        CFStringRef str = CFStringCreateWithBytes(NULL, (const UInt8 *)o->text,
                                                  (CFIndex)strlen(o->text),
                                                  kCFStringEncodingUTF8, false);
        int pos = o->text_pos < 1 ? 1 : o->text_pos > 9 ? 9 : o->text_pos;
        int col = (pos - 1) % 3, row = (pos - 1) / 3;
        double margin = mh / 40.0;
        for (int pass = 0; str && pass < 2; pass++) {
            CGColorRef colr = pass == 0 ? CGColorCreateGenericRGB(0, 0, 0, 0.85)
                                        : CGColorCreateGenericRGB(1, 1, 1, 0.95);
            CFTypeRef keys[2] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
            CFTypeRef vals[2] = { font, colr };
            CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 2,
                                                       &kCFTypeDictionaryKeyCallBacks,
                                                       &kCFTypeDictionaryValueCallBacks);
            CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attrs);
            CTLineRef line = CTLineCreateWithAttributedString(as);
            double tw = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
            double x = col == 0 ? margin : col == 1 ? (mw - tw) / 2.0 : mw - margin - tw;
            double y = row == 0 ? margin : row == 1 ? (mh - size) / 2.0 : mh - margin - size * 1.15;
            double sh = pass == 0 ? fmax(1.0, size / 16.0) : 0.0;
            CGContextSetTextPosition(ctx, x + sh, y - sh);
            CTLineDraw(line, ctx);
            CFRelease(line);
            CFRelease(as);
            CFRelease(attrs);
            CGColorRelease(colr);
            if (tw > mw - 2 * margin) break;
        }
        if (str) CFRelease(str);
        CFRelease(font);
    }

    /* RGBA -> RGB888, with brightness / contrast applied on the way */
    double contrast = o->contrast > 0.05 ? o->contrast : 1.0;
    double brightness = o->brightness;
    uint8_t lut[256];
    for (int i = 0; i < 256; i++) {
        double v = ((i / 255.0) - 0.5) * contrast + 0.5 + brightness;
        v = v < 0 ? 0 : v > 1 ? 1 : v;
        lut[i] = (uint8_t)(v * 255.0 + 0.5);
    }
    const uint8_t *px = CGBitmapContextGetData(ctx);
    for (int y = 0; y < mh; y++) {
        const uint8_t *s = px + (size_t)y * (size_t)mw * 4u;
        uint8_t *d = rgb + (size_t)y * (size_t)mw * 3u;
        for (int x = 0; x < mw; x++) {
            d[x * 3 + 0] = lut[s[x * 4 + 0]];
            d[x * 3 + 1] = lut[s[x * 4 + 1]];
            d[x * 3 + 2] = lut[s[x * 4 + 2]];
        }
    }
    CGContextRelease(ctx);
    return 0;
}

CGImageRef encode_load_image(const char *path) { return load_image(path); }

const char *encode_mode_name(int vis)
{
    int w, h;
    if (!enc_mode_size(vis, &w, &h)) return NULL;
    return enc_mode_name(vis);
}

int encode_image(const char *image_path, const char *wav_path, const EncodeOpts *o,
                 char *errbuf, size_t errlen, long *frames_out)
{
    int mw = 0, mh = 0;
    if (!enc_mode_size(o->vis, &mw, &mh)) {
        snprintf(errbuf, errlen, "mode %d cannot be encoded", o->vis);
        return -1;
    }
    CGImageRef img = load_image(image_path);
    if (!img) {
        snprintf(errbuf, errlen, "%s: not an image this Mac can read", image_path);
        return -1;
    }

    uint8_t *rgb = malloc((size_t)mw * (size_t)mh * 3u);
    if (!rgb) { CGImageRelease(img); snprintf(errbuf, errlen, "out of memory"); return -1; }

    int rc = encode_render_rgb(img, mw, mh, o, rgb);
    CGImageRelease(img);
    if (rc != 0) { free(rgb); CGImageRelease(img); snprintf(errbuf, errlen, "cannot render the picture"); return -1; }

    EncOpts e;
    enc_default_opts(&e);
    e.mode = o->vis;
    e.vis_code = o->vis;
    e.rate = o->rate;
    e.lead_s = o->lead_s;
    e.tail_s = o->tail_s;
    e.skew_ppm = o->skew_ppm;
    e.offset_hz = o->offset_hz;
    e.snr_db = o->snr_db;
    e.amplitude = o->amplitude;
    e.lines = 0;

    long n = 0;
    int16_t *x = enc_encode(rgb, &e, &n);
    free(rgb);
    if (!x) { snprintf(errbuf, errlen, "encoder failed"); return -1; }

    if (!wav_write_mono(wav_path, x, n, o->rate)) {
        free(x);
        snprintf(errbuf, errlen, "%s: cannot write", wav_path);
        return -1;
    }
    if (frames_out) *frames_out = n;
    if (!o->play) { free(x); return 0; }

    /* play it out so a radio held next to the speaker gets the picture */
    NSSound *s = [[NSSound alloc] initWithContentsOfFile:@(wav_path) byReference:YES];
    if (!s || ![s play]) { free(x); snprintf(errbuf, errlen, "cannot play the WAV"); return -1; }
    if (o->wait_play) while ([s isPlaying]) usleep(100000);
    free(x);
    return 0;
}

void encode_list_modes(void)
{
    printf("VIS  mode          picture\\n");
    for (int v = 1; v < 128; v++) {
        int w, h;
        if (!enc_mode_size(v, &w, &h)) continue;
        const char *nm = enc_mode_name(v);
        if (!nm) continue;
        printf("%3d  %-13s %dx%d\\n", v, nm, w, h);
    }
}
