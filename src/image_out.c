/* SPDX-License-Identifier: GPL-3.0-only */
/* image_out.c -- PNG output via ImageIO (no external image libraries). */
#include "image_out.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <stdlib.h>
#include <string.h>

static void rgb565_to_888(uint16_t v, uint8_t *o)
{
    unsigned r = (v >> 11) & 0x1f, g = (v >> 5) & 0x3f, b = v & 0x1f;
    o[0] = (uint8_t)((r << 3) | (r >> 2));
    o[1] = (uint8_t)((g << 2) | (g >> 4));
    o[2] = (uint8_t)((b << 3) | (b >> 2));
}

static int write_rgb888(const char *path, const uint8_t *rgb, int w, int h)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, rgb, (size_t)w * (size_t)h * 3u, NULL);
    if (!cs || !dp) { if (cs) CGColorSpaceRelease(cs); if (dp) CGDataProviderRelease(dp); return -1; }

    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 24, (size_t)w * 3u, cs,
                                   kCGBitmapByteOrderDefault | kCGImageAlphaNone,
                                   dp, NULL, false, kCGRenderingIntentDefault);
    int rc = -1;
    if (img) {
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
        if (url) {
            CFStringRef uti = CFSTR("public.png");
            CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, uti, 1, NULL);
            if (dst) {
                CGImageDestinationAddImage(dst, img, NULL);
                rc = CGImageDestinationFinalize(dst) ? 0 : -1;
                CFRelease(dst);
            }
            CFRelease(url);
        }
        CGImageRelease(img);
    }
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    return rc;
}

int png_write_rgb(const char *path, const uint8_t *rgb, int w, int h, int scale)
{
    if (scale <= 1) return write_rgb888(path, rgb, w, h);
    size_t stride = (size_t)w * 3u, ws = (size_t)w * (size_t)scale;
    uint8_t *big = malloc(ws * (size_t)h * (size_t)scale);
    if (!big) return -1;
    for (int y = 0; y < h; y++) {
        const uint8_t *src = rgb + (size_t)y * stride;
        for (int sx = 0; sx < w; sx++) {
            const uint8_t *p = src + (size_t)sx * 3u;
            for (int k = 0; k < scale; k++) {
                uint8_t *d = big + (size_t)(y * scale) * ws + ((size_t)sx * (size_t)scale + (size_t)k) * 3u;
                d[0] = p[0]; d[1] = p[1]; d[2] = p[2];
            }
        }
        /* replicate the row vertically */
        for (int k = 1; k < scale; k++)
            memcpy(big + (size_t)(y * scale + k) * ws, big + (size_t)(y * scale) * ws, ws);
    }
    int rc = write_rgb888(path, big, w * scale, h * scale);
    free(big);
    return rc;
}

int png_write_565(const char *path, const uint16_t *px, int w, int h, int scale)
{
    if (w <= 0 || h <= 0) return -1;
    uint8_t *rgb = malloc((size_t)w * (size_t)h * 3u);
    if (!rgb) return -1;
    for (int i = 0; i < w * h; i++) rgb565_to_888(px[i], rgb + (size_t)i * 3u);
    int rc = png_write_rgb(path, rgb, w, h, scale);
    free(rgb);
    return rc;
}
