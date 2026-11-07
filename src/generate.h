/* SPDX-License-Identifier: GPL-3.0-only */
/* generate.h -- the "generate" side of the window: pick a picture, crop/rotate
 * it with the mouse, add a caption, then make the SSTV audio. */
#ifndef APRICOT_GENERATE_H
#define APRICOT_GENERATE_H

#import <AppKit/AppKit.h>
#include "encode.h"

@interface GenerateView : NSView
- (instancetype)initWithFrame:(NSRect)frame;
/* Load a picture as if the user picked it (used by --send). */
- (void)loadImageAtPath:(NSString *)path;
/* Encode what is on the canvas and either play it or just write the WAV. */
- (void)sendNow:(BOOL)play;
@end

#endif
