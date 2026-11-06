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
    o->text = NULL;
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

/* Draw the picture into an RGB888 buffer of exactly mw x mh. */
static int render(uint8_t *rgb, int mw, int mh, CGImageRef img, int fit, const char *text,
                  char *errbuf, size_t errlen)
{
    /* 32-bit RGBA while drawing (CG has no 24-bit context), RGB888 on the way out */
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)mw, (size_t)mh, 8, (size_t)mw * 4u,
                                             cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { snprintf(errbuf, errlen, "no bitmap context"); return -1; }

    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, mw, mh));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);

    double iw = CGImageGetWidth(img), ih = CGImageGetHeight(img);
    double sc;
    if (fit == 2) {                                  /* stretch: fill the frame */
        CGContextDrawImage(ctx, CGRectMake(0, 0, mw, mh), img);
    } else {
        if (fit == 1) sc = fmax((double)mw / iw, (double)mh / ih);   /* fill / crop */
        else          sc = fmin((double)mw / iw, (double)mh / ih);   /* letterbox, like SSTVEncoder2 */
        double dw = iw * sc, dh = ih * sc;
        CGRect r = CGRectMake(((double)mw - dw) / 2, ((double)mh - dh) / 2, dw, dh);
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, CGRectMake(0, 0, mw, mh));
        CGContextDrawImage(ctx, r, img);
        CGContextRestoreGState(ctx);
    }

    if (text && *text) {
        double size = mh / 12.0;
        if (size < 8) size = 8;
        CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), size, NULL);
        CFStringRef keyF = kCTFontAttributeName, keyC = kCTForegroundColorAttributeName;
        CFRange all = CFRangeMake(0, (CFIndex)strlen(text));
        CFStringRef str = CFStringCreateWithBytes(NULL, (const UInt8 *)text, all.length,
                                                  kCFStringEncodingUTF8, false);
        CGRect bounds = CGRectMake(0, 0, mw, mh);
        for (int pass = 0; pass < 2 && str; pass++) {
            CGColorRef col = pass == 0 ? CGColorCreateGenericRGB(0, 0, 0, 0.85)
                                       : CGColorCreateGenericRGB(1, 1, 1, 0.95);
            CFTypeRef keys[2] = { keyF, keyC };
            CFTypeRef vals[2] = { font, col };
            CFDictionaryRef attrs = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 2,
                                                       &kCFTypeDictionaryKeyCallBacks,
                                                       &kCFTypeDictionaryValueCallBacks);
            CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attrs);
            CTLineRef line = CTLineCreateWithAttributedString(as);
            double tw = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
            double margin = mh / 32.0;
            double x = margin + (pass == 0 ? size / 16.0 : 0);
            double y = margin * 1.5 - (pass == 0 ? size / 16.0 : 0);
            CGContextSetTextPosition(ctx, x, y);
            (void)tw; (void)bounds;
            CTLineDraw(line, ctx);
            CFRelease(line);
            CFRelease(as);
            CFRelease(attrs);
            CGColorRelease(col);
            if (tw > mw - 2 * margin && pass == 0) { /* too wide: stop after the shadow */ }
        }
        if (str) CFRelease(str);
        CFRelease(font);
    }

    /* RGBA -> RGB888 for the encoder (row 0 of the buffer is the top of the picture) */
    uint8_t *px = CGBitmapContextGetData(ctx);
    for (int y = 0; y < mh; y++) {
        const uint8_t *s = px + (size_t)y * (size_t)mw * 4u;
        uint8_t *d = rgb + (size_t)y * (size_t)mw * 3u;
        for (int x = 0; x < mw; x++) {
            d[x * 3 + 0] = s[x * 4 + 0];
            d[x * 3 + 1] = s[x * 4 + 1];
            d[x * 3 + 2] = s[x * 4 + 2];
        }
    }
    CGContextRelease(ctx);
    return 0;
}

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

    int rc = render(rgb, mw, mh, img, o->fit, o->text, errbuf, errlen);
    CGImageRelease(img);
    if (rc != 0) { free(rgb); return -1; }

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
