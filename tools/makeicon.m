// Renders the FastText app icon (black squircle, white "FT") into an .iconset directory.
// Usage: makeicon <out.iconset>
#import <AppKit/AppKit.h>

static void Render(NSInteger px, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px bitsPerSample:8
                 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                     bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = ctx;

    CGFloat s = px, inset = s * 100.0 / 1024.0, side = s - 2 * inset;
    NSRect r = NSMakeRect(inset, inset, side, side);
    [[NSColor blackColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:side * 0.2237 yRadius:side * 0.2237] fill];

    NSFont *f = [NSFont monospacedSystemFontOfSize:side * 0.46 weight:NSFontWeightBold];
    NSDictionary *attrs = @{ NSFontAttributeName : f, NSForegroundColorAttributeName : NSColor.whiteColor };
    NSAttributedString *t = [[NSAttributedString alloc] initWithString:@"FT" attributes:attrs];
    NSSize ts = t.size;
    [t drawAtPoint:NSMakePoint((s - ts.width) / 2, s / 2 - f.capHeight / 2 + f.descender)];

    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) return 1;
        NSString *dir = @(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSNumber *n in @[ @16, @32, @128, @256, @512 ]) {
            NSInteger b = n.integerValue;
            Render(b, [dir stringByAppendingFormat:@"/icon_%ldx%ld.png", (long)b, (long)b]);
            Render(b * 2, [dir stringByAppendingFormat:@"/icon_%ldx%ld@2x.png", (long)b, (long)b]);
        }
    }
    return 0;
}
