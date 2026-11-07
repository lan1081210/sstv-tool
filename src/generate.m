/* SPDX-License-Identifier: GPL-3.0-only */
/* generate.m -- picture -> SSTV audio, with the editing the web encoders give
 * you: drag the preview to choose what stays in the frame, rotate, flip, zoom,
 * caption, brightness/contrast. The preview is rendered by the very same
 * function that feeds the modulator, so what you see is what gets sent. */
#import "generate.h"
#import "encode.h"
#include "enc.h"   /* enc_mode_size() */

#include <string.h>

/* what the transmitter is doing right now (owned here, read by the draw code) */
static NSSound *g_tx_sound = nil;
static double g_tx_total = 0, g_tx_started = 0;
static NSString *g_tx_last = nil;
static NSString *g_tx_note = nil;

@interface GenerateView () {
    CGImageRef _src;             /* the picture as loaded */
    NSString *_srcPath;
    EncodeOpts _opt;
    uint8_t *_rgb;               /* preview of the mode's frame, RGB888 */
    int _pw, _ph;
    BOOL _dragging;
    NSPoint _dragFrom;
    double _panFromX, _panFromY;

    NSPopUpButton *_modePop;
    NSPopUpButton *_fitPop;
    NSPopUpButton *_posPop;
    NSTextField *_textField;
    NSSlider *_zoomSlider, *_brightSlider, *_contrastSlider, *_scaleSlider;
    NSButton *_playBtn, *_saveBtn, *_stopBtn;
    NSTextField *_info;
}
@end

@implementation GenerateView

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self) return nil;
    [self setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    encode_defaults(&_opt);
    _opt.vis = 8;

    CGFloat x = 16, y = 12;
    CGFloat w = frame.size.width - 32;

    /* row 1: mode, fit, edit buttons */
    _modePop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, y, 132, 24) pullsDown:NO];
    for (int v = 1; v < 128; v++) {
        const char *nm = encode_mode_name(v);
        if (!nm) continue;
        [_modePop addItemWithTitle:@(nm)];
        [[_modePop lastItem] setTag:v];
        if (v == 8) [_modePop selectItem:[_modePop lastItem]];
    }
    [_modePop setTarget:self];
    [_modePop setAction:@selector(changed:)];
    [self addSubview:_modePop];

    _fitPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x + 140, y, 120, 24) pullsDown:NO];
    [_fitPop addItemWithTitle:@"留黑边"];
    [_fitPop addItemWithTitle:@"裁满"];
    [_fitPop addItemWithTitle:@"拉伸"];
    [_fitPop setTarget:self];
    [_fitPop setAction:@selector(changed:)];
    [self addSubview:_fitPop];

    NSArray *titles = @[ @"旋转 ⟳", @"左右翻", @"上下翻", @"复位" ];
    NSArray *acts = @[ @"rotate:", @"flipH:", @"flipV:", @"reset:" ];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(x + 272 + (CGFloat)i * 86, y, 82, 24)];
        [b setTitle:titles[i]];
        [b setBezelStyle:NSBezelStyleRounded];
        [b setTarget:self];
        [b setAction:NSSelectorFromString(acts[i])];
        [self addSubview:b];
    }

    NSButton *pick = [[NSButton alloc] initWithFrame:NSMakeRect(x + w - 110, y, 110, 24)];
    [pick setTitle:@"选择图片…"];
    [pick setBezelStyle:NSBezelStyleRounded];
    [pick setTarget:self];
    [pick setAction:@selector(pick:)];
    [self addSubview:pick];

    /* row 2: caption + the three sliders */
    CGFloat y2 = y + 34;
    _textField = [[NSTextField alloc] initWithFrame:NSMakeRect(x, y2, 240, 24)];
    [_textField setPlaceholderString:@"图片上的文字（可留空）"];
    [_textField setTarget:self];
    [_textField setAction:@selector(changed:)];
    [self addSubview:_textField];

    _posPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x + 248, y2, 96, 24) pullsDown:NO];
    NSArray *posNames = @[ @"左下", @"中下", @"右下", @"左中", @"正中", @"右中", @"左上", @"中上", @"右上" ];
    for (NSString *n in posNames) [_posPop addItemWithTitle:n];
    [_posPop selectItemAtIndex:0];
    [_posPop setTarget:self];
    [_posPop setAction:@selector(changed:)];
    [self addSubview:_posPop];

    struct { const char *label; CGFloat x; double lo, hi, v; } sl[4] = {
        { "字号", x + 352, 0.5, 2.5, 1.0 },
        { "缩放", x + 470, 1.0, 3.0, 1.0 },
        { "亮度", x + 588, -0.4, 0.4, 0.0 },
        { "对比", x + 706, 0.5, 2.0, 1.0 },
    };
    NSSlider *made[4];
    for (int i = 0; i < 4; i++) {
        NSTextField *lab = [[NSTextField alloc] initWithFrame:NSMakeRect(sl[i].x, y2 + 4, 30, 18)];
        [lab setStringValue:@(sl[i].label)];
        [lab setBezeled:NO]; [lab setDrawsBackground:NO]; [lab setEditable:NO]; [lab setSelectable:NO];
        [lab setFont:[NSFont systemFontOfSize:11]];
        [lab setTextColor:[NSColor colorWithCalibratedWhite:0.7 alpha:1]];
        [self addSubview:lab];
        made[i] = [self sliderAt:NSMakeRect(sl[i].x + 32, y2, 80, 24) min:sl[i].lo max:sl[i].hi
                           value:sl[i].v action:@selector(changed:)];
        [self addSubview:made[i]];
    }
    _scaleSlider = made[0]; _zoomSlider = made[1]; _brightSlider = made[2]; _contrastSlider = made[3];

    /* row 3: the buttons that matter */
    CGFloat y3 = frame.size.height - 52;
    _playBtn = [[NSButton alloc] initWithFrame:NSMakeRect(x, y3, 150, 28)];
    [_playBtn setTitle:@"生成并播放"];
    [_playBtn setBezelStyle:NSBezelStyleRounded];
    [_playBtn setTarget:self];
    [_playBtn setAction:@selector(play:)];
    [self addSubview:_playBtn];

    _saveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(x + 158, y3, 130, 28)];
    [_saveBtn setTitle:@"存成 WAV"];
    [_saveBtn setBezelStyle:NSBezelStyleRounded];
    [_saveBtn setTarget:self];
    [_saveBtn setAction:@selector(save:)];
    [self addSubview:_saveBtn];

    _stopBtn = [[NSButton alloc] initWithFrame:NSMakeRect(x + 296, y3, 76, 28)];
    [_stopBtn setTitle:@"停止"];
    [_stopBtn setBezelStyle:NSBezelStyleRounded];
    [_stopBtn setTarget:self];
    [_stopBtn setAction:@selector(stop:)];
    [self addSubview:_stopBtn];

    _info = [[NSTextField alloc] initWithFrame:NSMakeRect(x + 384, y3 + 4, w - 384, 20)];
    [_info setBezeled:NO];
    [_info setDrawsBackground:NO];
    [_info setEditable:NO];
    [_info setSelectable:NO];
    [_info setFont:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]];
    [_info setTextColor:[NSColor colorWithCalibratedWhite:0.75 alpha:1]];
    [_info setStringValue:@"选一张图开始（也可以把图拖进来），拖动画面调整位置，滚轮缩放"];
    [self addSubview:_info];

    [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
    return self;
}

- (NSSlider *)sliderAt:(NSRect)r min:(double)lo max:(double)hi value:(double)v action:(SEL)a
{
    NSSlider *s = [[NSSlider alloc] initWithFrame:r];
    [s setMinValue:lo];
    [s setMaxValue:hi];
    [s setDoubleValue:v];
    [s setContinuous:YES];
    [s setTarget:self];
    [s setAction:a];
    return s;
}

- (void)dealloc
{
    if (_rgb) free(_rgb);
    if (_src) CGImageRelease(_src);
}

- (BOOL)isFlipped { return YES; }

/* --------------------------------------------------------------- rendering */

- (NSRect)canvasRect
{
    NSRect b = self.bounds;
    return NSMakeRect(16, 76, b.size.width - 32, b.size.height - 76 - 76);
}

- (void)rebuild
{
    int mw = 0, mh = 0;
    if (!enc_mode_size(_opt.vis, &mw, &mh)) return;
    if (_rgb && (mw != _pw || mh != _ph)) { free(_rgb); _rgb = NULL; }
    if (!_rgb) {
        _rgb = malloc((size_t)mw * (size_t)mh * 3u);
        _pw = mw; _ph = mh;
    }
    if (!_rgb) return;
    if (!_src) {
        memset(_rgb, 0, (size_t)mw * (size_t)mh * 3u);
    } else {
        encode_render_rgb(_src, mw, mh, &_opt, _rgb);
    }
    [self setNeedsDisplay:YES];
}

- (void)syncOptionsFromControls
{
    long tag = (long)[[_modePop selectedItem] tag];
    _opt.vis = tag > 0 ? (int)tag : 8;
    _opt.fit = (int)[_fitPop indexOfSelectedItem];
    _opt.zoom = [_zoomSlider doubleValue];
    _opt.brightness = [_brightSlider doubleValue];
    _opt.contrast = [_contrastSlider doubleValue];
    _opt.text = [[_textField stringValue] UTF8String];
    _opt.text_pos = (int)[_posPop indexOfSelectedItem] + 1;
    _opt.text_scale = [_scaleSlider doubleValue];
}

- (void)changed:(id)sender
{
    (void)sender;
    [self syncOptionsFromControls];
    [self rebuild];
    [self updateInfo];
}

- (void)updateInfo
{
    int mw = 0, mh = 0;
    if (!enc_mode_size(_opt.vis, &mw, &mh)) return;
    const char *nm = encode_mode_name(_opt.vis);
    NSString *s = [NSString stringWithFormat:@"%@ · %dx%d · 缩放 %.0f%%%@",
                   nm ? @(nm) : @"?", mw, mh, _opt.zoom * 100.0,
                   _srcPath ? [NSString stringWithFormat:@" · %@", [_srcPath lastPathComponent]] : @""];
    [_info setStringValue:s];
}

/* ------------------------------------------------------------------ drawing */

- (void)drawRect:(NSRect)dirty
{
    (void)dirty;
    [[NSColor colorWithCalibratedWhite:0.06 alpha:1] setFill];
    NSRectFill(self.bounds);

    NSRect c = [self canvasRect];
    [[NSColor colorWithCalibratedWhite:0.10 alpha:1] setFill];
    NSRectFill(c);

    if (_rgb && _pw > 0) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, _rgb, (size_t)_pw * _ph * 3u, NULL);
        CGImageRef im = CGImageCreate((size_t)_pw, (size_t)_ph, 8, 24, (size_t)_pw * 3u, cs,
                                      kCGBitmapByteOrderDefault | kCGImageAlphaNone,
                                      dp, NULL, false, kCGRenderingIntentDefault);
        if (im) {
            double sc = fmin(c.size.width / _pw, c.size.height / _ph);
            NSRect r = NSMakeRect(c.origin.x + (c.size.width - _pw * sc) / 2,
                                  c.origin.y + (c.size.height - _ph * sc) / 2,
                                  _pw * sc, _ph * sc);
            NSImage *ni = [[NSImage alloc] initWithCGImage:im size:NSMakeSize(_pw, _ph)];
            [ni drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                 fraction:1.0 respectFlipped:YES hints:@{ NSImageHintInterpolation : @(NSImageInterpolationNone) }];
            CGImageRelease(im);
            [[NSColor colorWithCalibratedWhite:0.4 alpha:1] setStroke];
            NSFrameRect(r);
        }
        CGDataProviderRelease(dp);
        CGColorSpaceRelease(cs);
    } else {
        NSDictionary *a = @{ NSFontAttributeName: [NSFont systemFontOfSize:15],
                             NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.5 alpha:1] };
        NSString *m = @"拖一张图片到这里，或点「选择图片…」";
        NSSize sz = [m sizeWithAttributes:a];
        [m drawAtPoint:NSMakePoint(c.origin.x + (c.size.width - sz.width) / 2,
                                   c.origin.y + c.size.height / 2 - sz.height / 2)
        withAttributes:a];
    }

    /* transmission progress */
    if (g_tx_sound) {
        double el = [NSDate timeIntervalSinceReferenceDate] - g_tx_started;
        if (![g_tx_sound isPlaying] || (g_tx_total > 0 && el >= g_tx_total)) {
            g_tx_sound = nil;
            g_tx_note = @"发射结束";
        } else if (g_tx_total > 0) {
            double f = el / g_tx_total;
            NSRect bar = NSMakeRect(16, self.bounds.size.height - 74, self.bounds.size.width - 32, 8);
            [[NSColor colorWithCalibratedWhite:0.22 alpha:1] setFill];
            NSRectFill(bar);
            [[NSColor colorWithCalibratedRed:0.95 green:0.55 blue:0.25 alpha:1] setFill];
            NSRectFill(NSMakeRect(bar.origin.x, bar.origin.y, bar.size.width * f, bar.size.height));
        }
    }
    if (g_tx_note) {
        NSDictionary *wa = @{ NSFontAttributeName: [NSFont systemFontOfSize:11],
                              NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:1 green:0.66 blue:0.3 alpha:1] };
        [g_tx_note drawInRect:NSMakeRect(16, self.bounds.size.height - 90, self.bounds.size.width - 32, 16) withAttributes:wa];
    }
}

/* ------------------------------------------------------------------- mouse */

- (void)mouseDown:(NSEvent *)e
{
    _dragging = YES;
    _dragFrom = [self convertPoint:[e locationInWindow] fromView:nil];
    _panFromX = _opt.pan_x;
    _panFromY = _opt.pan_y;
}

- (void)mouseDragged:(NSEvent *)e
{
    if (!_src || !_dragging) return;
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    NSRect c = [self canvasRect];
    int mw = 0, mh = 0;
    enc_mode_size(_opt.vis, &mw, &mh);
    double sc = fmin(c.size.width / (mw > 0 ? mw : 1), c.size.height / (mh > 0 ? mh : 1));
    if (sc <= 0) return;
    /* dragging right shows more of the left side: pan is a fraction of the slack */
    _opt.pan_x = _panFromX - (p.x - _dragFrom.x) / (mw * sc);
    _opt.pan_y = _panFromY + (p.y - _dragFrom.y) / (mh * sc);
    if (_opt.pan_x < -1) _opt.pan_x = -1; if (_opt.pan_x > 1) _opt.pan_x = 1;
    if (_opt.pan_y < -1) _opt.pan_y = -1; if (_opt.pan_y > 1) _opt.pan_y = 1;
    [self rebuild];
}

- (void)mouseUp:(NSEvent *)e { (void)e; _dragging = NO; }

- (void)scrollWheel:(NSEvent *)e
{
    if (!_src) return;
    double z = _opt.zoom + [e scrollingDeltaY] * 0.01;
    if (z < 1.0) z = 1.0; if (z > 3.0) z = 3.0;
    _opt.zoom = z;
    [_zoomSlider setDoubleValue:z];
    [self rebuild];
    [self updateInfo];
}

/* ---------------------------------------------------------------- dropping */

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    return [self loadFromPasteboard:[sender draggingPasteboard]] ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    return [self loadFromPasteboard:[sender draggingPasteboard]];
}

- (BOOL)loadFromPasteboard:(NSPasteboard *)pb
{
    NSArray *urls = [pb readObjectsForClasses:@[ [NSURL class] ]
                                      options:@{ NSPasteboardURLReadingFileURLsOnlyKey : @YES }];
    if (!urls.count) return NO;
    [self loadImageAtPath:[[urls firstObject] path]];
    return YES;
}

/* ----------------------------------------------------------------- actions */

- (void)pick:(id)sender
{
    (void)sender;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setCanChooseFiles:YES];
    [p setAllowsMultipleSelection:NO];
    [p setMessage:@"选一张要发送的图片"];
    if ([p runModal] != NSModalResponseOK) return;
    [self loadImageAtPath:[[p URL] path]];
}

- (void)loadImageAtPath:(NSString *)path
{
    CGImageRef img = encode_load_image(path.fileSystemRepresentation);
    if (!img) { g_tx_note = [NSString stringWithFormat:@"读不了这张图：%@", [path lastPathComponent]]; [self setNeedsDisplay:YES]; return; }
    if (_src) CGImageRelease(_src);
    _src = img;
    _srcPath = path;
    _opt.pan_x = _opt.pan_y = 0;
    [self rebuild];
    [self updateInfo];
}

- (void)rotate:(id)sender { (void)sender; _opt.rot = (_opt.rot + 90) % 360; [self rebuild]; }
- (void)flipH:(id)sender { (void)sender; _opt.flip_h = !_opt.flip_h; [self rebuild]; }
- (void)flipV:(id)sender { (void)sender; _opt.flip_v = !_opt.flip_v; [self rebuild]; }
- (void)reset:(id)sender
{
    (void)sender;
    _opt.rot = 0; _opt.flip_h = _opt.flip_v = 0;
    _opt.pan_x = _opt.pan_y = 0; _opt.zoom = 1.0;
    _opt.brightness = 0.0; _opt.contrast = 1.0;
    _opt.text_scale = 1.0;
    [_zoomSlider setDoubleValue:1.0];
    [_brightSlider setDoubleValue:0.0];
    [_contrastSlider setDoubleValue:1.0];
    [_scaleSlider setDoubleValue:1.0];
    [self rebuild];
}

- (void)play:(id)sender { (void)sender; [self sendNow:YES]; }
- (void)save:(id)sender { (void)sender; [self sendNow:NO]; }

- (void)stop:(id)sender
{
    (void)sender;
    if (g_tx_sound) [g_tx_sound stop];
    g_tx_sound = nil;
    g_tx_note = nil;
    [self setNeedsDisplay:YES];
}

- (void)sendNow:(BOOL)play
{
    [self syncOptionsFromControls];
    if (!_src) { g_tx_note = @"先选一张图片"; [self setNeedsDisplay:YES]; return; }

    NSString *dir = [@"~/Music/SSTV Tool" stringByExpandingTildeInPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                             attributes:nil error:NULL];
    const char *mn = encode_mode_name(_opt.vis);
    NSString *modeTitle = mn ? @(mn) : @"SSTV";
    NSString *name = [NSString stringWithFormat:@"%@-%@.wav",
                      [[_srcPath lastPathComponent] stringByDeletingPathExtension], modeTitle];
    NSString *wav = [dir stringByAppendingPathComponent:name];
    if (![[wav pathExtension] isEqualToString:@"wav"]) wav = [wav stringByAppendingPathExtension:@"wav"];

    EncodeOpts o = _opt;
    o.play = 0;
    char err[512] = "";
    long frames = 0;

    g_tx_note = [NSString stringWithFormat:@"正在生成 %@ …", modeTitle];
    [self setNeedsDisplay:YES];

    if (encode_image(_srcPath.fileSystemRepresentation, wav.fileSystemRepresentation, &o,
                     err, sizeof err, &frames) != 0) {
        g_tx_note = [NSString stringWithFormat:@"生成失败：%s", err[0] ? err : "未知错误"];
        [self setNeedsDisplay:YES];
        return;
    }
    g_tx_last = wav;
    g_tx_total = frames > 0 ? (double)frames / o.rate : 0;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:wav error:NULL];
    unsigned long long size = [attrs fileSize];
    if (!attrs || size < 1024) {
        g_tx_note = [NSString stringWithFormat:@"写 WAV 失败：%@", wav];
        [self setNeedsDisplay:YES];
        return;
    }

    if (!play) {
        g_tx_note = [NSString stringWithFormat:@"已存 %@（%.0f 秒，%.1f MB）",
                     [wav lastPathComponent], g_tx_total, (double)size / 1048576.0];
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:wav] ]];
        [self setNeedsDisplay:YES];
        return;
    }

    [self stop:nil];
    NSSound *snd = [[NSSound alloc] initWithContentsOfFile:wav byReference:YES];
    if (!snd || ![snd play]) { g_tx_note = @"播放失败（文件已生成）"; [self setNeedsDisplay:YES]; return; }
    g_tx_sound = snd;
    g_tx_started = [NSDate timeIntervalSinceReferenceDate];
    g_tx_note = nil;
    [self setNeedsDisplay:YES];
}

@end
