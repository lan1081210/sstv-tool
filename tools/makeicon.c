/* SPDX-License-Identifier: GPL-3.0-only */
/* makeicon.c -- turn a picture into a macOS-style app icon: 1024x1024,
 * rounded corners, aspect-filled. Used by the Makefile to build AppIcon.icns.
 *
 *   makeicon in.png out.png [size] [radius_percent]
 */
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CGImageRef load(const char *path)
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

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: %s in.png out.png [size] [radius%%]\n", argv[0]); return 2; }
    int size = argc > 3 ? atoi(argv[3]) : 1024;
    double radpct = argc > 4 ? atof(argv[4]) : 22.0;
    if (size < 64) size = 64;

    CGImageRef src = load(argv[1]);
    if (!src) { fprintf(stderr, "%s: cannot read\n", argv[1]); return 1; }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)size, (size_t)size, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast);
    if (!ctx) { fprintf(stderr, "no context\n"); return 1; }

    /* rounded-square mask, like every other macOS icon */
    double r = size * radpct / 100.0;
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, r, 0);
    CGPathAddLineToPoint(path, NULL, size - r, 0);
    CGPathAddArcToPoint(path, NULL, size, 0, size, r, r);
    CGPathAddLineToPoint(path, NULL, size, size - r);
    CGPathAddArcToPoint(path, NULL, size, size, size - r, size, r);
    CGPathAddLineToPoint(path, NULL, r, size);
    CGPathAddArcToPoint(path, NULL, 0, size, 0, size - r, r);
    CGPathAddLineToPoint(path, NULL, 0, r);
    CGPathAddArcToPoint(path, NULL, 0, 0, r, 0, r);
    CGPathCloseSubpath(path);

    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);

    /* aspect-fill the picture behind the mask */
    double iw = CGImageGetWidth(src), ih = CGImageGetHeight(src);
    double sc = size / (iw < ih ? iw : ih);
    double dw = iw * sc, dh = ih * sc;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake((size - dw) / 2, (size - dh) / 2, dw, dh), src);
    CGContextRestoreGState(ctx);

    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[2],
                                                           (CFIndex)strlen(argv[2]), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    int rc = 1;
    if (dst) {
        CGImageDestinationAddImage(dst, out, NULL);
        rc = CGImageDestinationFinalize(dst) ? 0 : 1;
        CFRelease(dst);
    }
    CFRelease(url);
    CGImageRelease(out);
    CGPathRelease(path);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CGImageRelease(src);
    if (rc) fprintf(stderr, "%s: write failed\n", argv[2]);
    return rc;
}
