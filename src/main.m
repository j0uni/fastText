// FastText: a plain-text editor built for minimal launch time.
// Pure AppKit, no nib/storyboard, no NSDocument, no state restoration.
#import <AppKit/AppKit.h>

#ifdef FT_BENCH
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>
static void FTReportAndExit(void) {
    struct kinfo_proc kp; size_t n = sizeof kp;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    sysctl(mib, 4, &kp, &n, NULL, 0);
    struct timeval st = kp.kp_proc.p_un.__p_starttime, now;
    gettimeofday(&now, NULL);
    printf("%.1f ms (exec -> first window drawn)\n",
           (now.tv_sec - st.tv_sec) * 1e3 + (now.tv_usec - st.tv_usec) / 1e3);
    fflush(stdout);
    _exit(0);
}
#endif

static void FTOpenPaths(NSArray<NSString *> *paths);

// Text view that opens dropped files in their own windows instead of inserting their paths.
@interface FTTextView : NSTextView
@property (nonatomic) BOOL highlightLine;
@property (nonatomic, strong) NSColor *highlightColor;
- (void)selectionDidChange;
@end

// Layout manager that can draw markers for spaces, tabs and line breaks.
@interface FTLayoutManager : NSLayoutManager
@property (nonatomic) BOOL showWhitespace;
@end

// Line-number gutter. Numbers are derived incrementally from a cached (offset, line) anchor, so
// scrolling a huge file only counts newlines across the distance scrolled.
@interface FTRuler : NSRulerView
- (instancetype)initWithScrollView:(NSScrollView *)sv;
- (void)invalidateFrom:(NSUInteger)loc;
@end

static NSArray<NSString *> *FTDroppedPaths(id<NSDraggingInfo> info) {
    NSArray<NSURL *> *urls = [info.draggingPasteboard
        readObjectsForClasses:@[ NSURL.class ]
                      options:@{ NSPasteboardURLReadingFileURLsOnlyKey : @YES }];
    NSMutableArray *paths = [NSMutableArray new];
    for (NSURL *u in urls) [paths addObject:u.path];
    return paths;
}

@implementation FTTextView

- (NSRect)highlightRect {
    NSRange sel = self.selectedRange;
    if (!_highlightLine || sel.length) return NSZeroRect;
    NSString *str = self.string;
    NSLayoutManager *lm = self.layoutManager;
    NSRect r;
    if (sel.location >= str.length && (!str.length || [str characterAtIndex:str.length - 1] == '\n')) {
        r = lm.extraLineFragmentRect;
        if (NSIsEmptyRect(r)) return NSZeroRect;
    } else {
        NSRange pr = [str lineRangeForRange:NSMakeRange(sel.location, 0)];
        NSRange gr = [lm glyphRangeForCharacterRange:pr actualCharacterRange:NULL];
        r = [lm boundingRectForGlyphRange:gr inTextContainer:self.textContainer];
    }
    r.origin.x = 0;
    r.size.width = self.bounds.size.width;
    r.origin.y += self.textContainerOrigin.y;
    return r;
}

- (void)drawViewBackgroundInRect:(NSRect)rect {
    [super drawViewBackgroundInRect:rect];
    if (!_highlightLine) return;
    NSRect r = NSIntersectionRect([self highlightRect], rect);
    if (NSIsEmptyRect(r)) return;
    [_highlightColor setFill];
    NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
}

- (void)selectionDidChange { if (_highlightLine) self.needsDisplay = YES; }
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    return FTDroppedPaths(info).count ? NSDragOperationCopy : [super draggingEntered:info];
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    return FTDroppedPaths(info).count ? NSDragOperationCopy : [super draggingUpdated:info];
}
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info {
    return FTDroppedPaths(info).count ? YES : [super prepareForDragOperation:info];
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    NSArray *paths = FTDroppedPaths(info);
    if (!paths.count) return [super performDragOperation:info];
    FTOpenPaths(paths);
    return YES;
}
@end

@implementation FTLayoutManager

- (void)drawGlyphsForGlyphRange:(NSRange)glyphs atPoint:(NSPoint)origin {
    [super drawGlyphsForGlyphRange:glyphs atPoint:origin];
    NSTextView *tv = self.firstTextView;
    if (!_showWhitespace || !tv) return;
    NSFont *font = tv.font;
    NSDictionary *attrs = @{ NSFontAttributeName : font,
                             NSForegroundColorAttributeName : [tv.textColor colorWithAlphaComponent:0.30] };
    NSString *str = self.textStorage.string;
    NSRange cr = [self characterRangeForGlyphRange:glyphs actualGlyphRange:NULL];
    for (NSUInteger i = cr.location; i < NSMaxRange(cr); i++) {
        unichar ch = [str characterAtIndex:i];
        NSString *mark;
        switch (ch) {
            case ' ': mark = @"·"; break;
            case 0x00A0: mark = @"°"; break;
            case '\t': mark = @"→"; break;
            case '\n': mark = @"¬"; break;
            default: continue;
        }
        NSUInteger g = [self glyphIndexForCharacterAtIndex:i];
        NSRect frag = [self lineFragmentRectForGlyphAtIndex:g effectiveRange:NULL];
        NSPoint loc = [self locationForGlyphAtIndex:g];
        CGFloat x = origin.x + frag.origin.x + loc.x;
        if (ch == ' ' || ch == 0x00A0) {
            NSTextContainer *tc = [self textContainerForGlyphAtIndex:g effectiveRange:NULL];
            CGFloat w = [self boundingRectForGlyphRange:NSMakeRange(g, 1) inTextContainer:tc].size.width;
            x += (w - [mark sizeWithAttributes:attrs].width) / 2;
        } else if (ch == '\t') {
            x += 1;
        }
        [mark drawAtPoint:NSMakePoint(x, origin.y + frag.origin.y + loc.y - font.ascender) withAttributes:attrs];
    }
}

@end

static NSUInteger FTCountLineBreaks(NSString *s, NSUInteger a, NSUInteger b) {
    unichar buf[4096];
    NSUInteger n = 0, total = s.length;
    while (a < b) {
        NSUInteger len = MIN((NSUInteger)4096, b - a);
        [s getCharacters:buf range:NSMakeRange(a, len)];
        for (NSUInteger i = 0; i < len; i++) {
            unichar c = buf[i];
            if (c == '\r') {
                unichar nx = i + 1 < len ? buf[i + 1] : (a + i + 1 < total ? [s characterAtIndex:a + i + 1] : 0);
                if (nx != '\n') n++;
            } else if (c == '\n' || c == 0x2028 || c == 0x2029 || c == 0x85) n++;
        }
        a += len;
    }
    return n;
}

@implementation FTRuler {
    NSUInteger _anchorLoc, _anchorLine;
}

- (instancetype)initWithScrollView:(NSScrollView *)sv {
    self = [super initWithScrollView:sv orientation:NSVerticalRuler];
    _anchorLine = 1;
    self.ruleThickness = 40;
    return self;
}

- (void)invalidateFrom:(NSUInteger)loc {
    if (loc < _anchorLoc) { _anchorLoc = 0; _anchorLine = 1; }
}

- (NSUInteger)lineNumberForLineStart:(NSUInteger)ls string:(NSString *)str {
    NSUInteger a = MIN(_anchorLoc, str.length), line;
    if (ls >= a) line = _anchorLine + FTCountLineBreaks(str, a, ls);
    else line = _anchorLine - FTCountLineBreaks(str, ls, a);
    _anchorLoc = ls;
    _anchorLine = line;
    return line;
}

- (void)drawHashMarksAndLabelsInRect:(NSRect)rect {
    NSTextView *tv = (NSTextView *)self.clientView;
    if (![tv isKindOfClass:NSTextView.class]) return;
    NSLayoutManager *lm = tv.layoutManager;
    NSString *str = tv.string;
    NSColor *fg = tv.textColor;
    [tv.backgroundColor setFill];
    NSRectFill(self.bounds);
    [[fg colorWithAlphaComponent:0.15] setFill];
    NSRectFill(NSMakeRect(NSMaxX(self.bounds) - 1, NSMinY(self.bounds), 1, self.bounds.size.height));

    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:MAX(9, tv.font.pointSize - 2) weight:NSFontWeightRegular];
    NSDictionary *dim = @{ NSFontAttributeName : font, NSForegroundColorAttributeName : [fg colorWithAlphaComponent:0.45] };
    NSDictionary *cur = @{ NSFontAttributeName : font, NSForegroundColorAttributeName : fg };

    NSRect vis = tv.visibleRect;
    NSPoint org = tv.textContainerOrigin;
    NSRange gr = [lm glyphRangeForBoundingRect:NSOffsetRect(vis, -org.x, -org.y) inTextContainer:tv.textContainer];
    NSRange cr = [lm characterRangeForGlyphRange:gr actualGlyphRange:NULL];
    NSUInteger len = str.length, ls = 0, curStart = 0;
    [str getLineStart:&ls end:NULL contentsEnd:NULL forRange:NSMakeRange(MIN(cr.location, len), 0)];
    [str getLineStart:&curStart end:NULL contentsEnd:NULL forRange:NSMakeRange(MIN(tv.selectedRange.location, len), 0)];
    NSUInteger line = [self lineNumberForLineStart:ls string:str];

    while (YES) {
        NSRect r;
        CGFloat baseline;
        if (ls >= len) { // empty document, or text ending with a line break
            r = lm.extraLineFragmentRect;
            if (NSIsEmptyRect(r)) break;
            baseline = tv.font.ascender;
        } else {
            NSUInteger g = [lm glyphIndexForCharacterAtIndex:ls];
            r = [lm lineFragmentRectForGlyphAtIndex:g effectiveRange:NULL];
            baseline = [lm locationForGlyphAtIndex:g].y;
        }
        CGFloat top = r.origin.y + org.y;
        if (top > NSMaxY(vis)) break;
        NSString *num = [NSString stringWithFormat:@"%lu", (unsigned long)line];
        NSDictionary *at = ls == curStart ? cur : dim;
        CGFloat w = [num sizeWithAttributes:at].width;
        CGFloat by = [self convertPoint:NSMakePoint(0, top + baseline) fromView:tv].y;
        CGFloat y = self.isFlipped ? by - font.ascender : by + font.descender;
        [num drawAtPoint:NSMakePoint(NSMaxX(self.bounds) - w - 7, y) withAttributes:at];
        if (ls >= len) break;
        NSUInteger end;
        [str getLineStart:NULL end:&end contentsEnd:NULL forRange:NSMakeRange(ls, 0)];
        ls = end;
        line++;
    }

    NSUInteger lineDigits = [NSString stringWithFormat:@"%lu", (unsigned long)line].length;
    NSUInteger digits = MAX((NSUInteger)3, lineDigits);
    CGFloat need = ceil(digits * [@"0" sizeWithAttributes:dim].width + 16);
    if (fabs(need - self.ruleThickness) > 0.5)
        dispatch_async(dispatch_get_main_queue(), ^{ self.ruleThickness = need; });
}

@end

static NSString *const kRecentKey = @"recentFiles";
static const NSUInteger kRecentMax = 12;

static void FTNoteRecent(NSString *path) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableArray *r = [([d arrayForKey:kRecentKey] ?: @[]) mutableCopy];
    [r removeObject:path];
    [r insertObject:path atIndex:0];
    if (r.count > kRecentMax) [r removeObjectsInRange:NSMakeRange(kRecentMax, r.count - kRecentMax)];
    [d setObject:r forKey:kRecentKey];
}


// ---- Appearance settings (NSUserDefaults: fontName, fontSize, bg, fg; colors are RRGGBB hex) ----
static NSString *const kFontName = @"fontName"; // font family; absent = system monospaced
static NSString *const kFontSize = @"fontSize";
static NSString *const kBG = @"bg";             // absent = system colors
static NSString *const kFG = @"fg";
static NSString *const kPreset = @"preset";
static NSString *const kWrap = @"wrap";                 // default YES
static NSString *const kLineNumbers = @"lineNumbers";   // default NO
static NSString *const kHighlightLine = @"highlightLine";
static NSString *const kShowWhitespace = @"showWhitespace";
static NSString *const kTabWidth = @"tabWidth";         // in spaces, default 4
static const NSInteger kTabMin = 1, kTabMax = 16, kTabDefault = 4;
static const double kSizeMin = 8, kSizeMax = 72, kSizeDefault = 13;

// name, background, text. The first entry follows the system appearance.
static NSArray<NSArray<NSString *> *> *FTPresets(void) {
    return @[
        @[ @"System", @"", @"" ],
        @[ @"Light", @"FFFFFF", @"1D1D1F" ],
        @[ @"Paper", @"F4ECD8", @"4B3B2A" ],
        @[ @"Solarized Light", @"FDF6E3", @"657B83" ],
        @[ @"Dark", @"1E1E1E", @"D4D4D4" ],
        @[ @"Midnight", @"000000", @"E6E6E6" ],
        @[ @"Solarized Dark", @"002B36", @"93A1A1" ],
        @[ @"Nord", @"2E3440", @"D8DEE9" ],
        @[ @"Dracula", @"282A36", @"F8F8F2" ],
        @[ @"Monokai", @"272822", @"F8F8F2" ],
        @[ @"Gruvbox Dark", @"282828", @"EBDBB2" ],
        @[ @"Terminal Green", @"000000", @"33FF33" ],
        @[ @"Amber", @"1A1100", @"FFB000" ],
    ];
}

static NSColor *FTColorFromHex(NSString *h) {
    unsigned v = 0;
    if (h.length != 6 || ![[NSScanner scannerWithString:h] scanHexInt:&v]) return nil;
    return [NSColor colorWithSRGBRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0
                                blue:(v & 255) / 255.0 alpha:1];
}

static NSString *FTHexFromColor(NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: c;
    return [NSString stringWithFormat:@"%02X%02X%02X", (int)lround(s.redComponent * 255),
            (int)lround(s.greenComponent * 255), (int)lround(s.blueComponent * 255)];
}

static double FTFontSize(void) {
    double v = [NSUserDefaults.standardUserDefaults doubleForKey:kFontSize];
    return v < kSizeMin ? kSizeDefault : MIN(v, kSizeMax);
}

static NSFont *FTCurrentFont(void) {
    NSString *family = [NSUserDefaults.standardUserDefaults stringForKey:kFontName];
    NSFont *f = family.length ? [NSFontManager.sharedFontManager fontWithFamily:family traits:0 weight:5
                                                                           size:FTFontSize()] : nil;
    return f ?: [NSFont monospacedSystemFontOfSize:FTFontSize() weight:NSFontWeightRegular];
}

static NSColor *FTBackground(void) {
    return FTColorFromHex([NSUserDefaults.standardUserDefaults stringForKey:kBG]) ?: NSColor.textBackgroundColor;
}
static NSColor *FTForeground(void) {
    return FTColorFromHex([NSUserDefaults.standardUserDefaults stringForKey:kFG]) ?: NSColor.textColor;
}

static BOOL FTBool(NSString *key) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : [key isEqualToString:kWrap];
}

static NSInteger FTTabWidth(void) {
    NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:kTabWidth];
    return v < kTabMin ? kTabDefault : MIN(v, kTabMax);
}

static void FTRestyleAll(void);

@interface FTDoc : NSObject <NSWindowDelegate, NSTextViewDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) NSTextView *textView;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) NSStringEncoding encoding;
@property (nonatomic) BOOL dirty;
@property (nonatomic) FTRuler *ruler;
@property (nonatomic) NSInteger wrapState;
- (instancetype)initWithPath:(NSString *)path;
- (BOOL)confirmClose;
- (void)applyStyle;
@end

static NSMutableArray<FTDoc *> *gDocs;

static void FTAlert(NSString *msg, NSString *info) {
    NSAlert *a = [NSAlert new];
    a.messageText = msg;
    a.informativeText = info ?: @"";
    [a runModal];
}

@implementation FTDoc

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    _encoding = NSUTF8StringEncoding;
    _wrapState = 1; // matches the wrapped layout built below
    NSString *text = @"";
    if (path) {
        NSError *err = nil;
        NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&err];
        if (!d) { FTAlert(@"Cannot open file", err.localizedDescription); return nil; }
        if (memchr(d.bytes, 0, MIN(d.length, (NSUInteger)8192))) {
            NSAlert *a = [NSAlert new];
            a.messageText = [NSString stringWithFormat:@"“%@” looks like a binary file.", path.lastPathComponent];
            a.informativeText = @"Opening it as text may show garbage and be slow.";
            [a addButtonWithTitle:@"Cancel"];
            [a addButtonWithTitle:@"Open Anyway"];
            if ([a runModal] != NSAlertSecondButtonReturn) return nil;
        }
        text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (!text) { // Latin-1 decodes any byte sequence
            _encoding = NSISOLatin1StringEncoding;
            text = [[NSString alloc] initWithData:d encoding:_encoding];
        }
        _path = [path copy];
        dispatch_async(dispatch_get_main_queue(), ^{ FTNoteRecent(path); });
    }

    NSRect frame = NSMakeRect(0, 0, 760, 540);
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    w.releasedWhenClosed = NO;
    w.restorable = NO;
    w.delegate = self;
    _window = w;

    // TextKit 1 stack: cheaper to set up and supports non-contiguous layout for big files.
    NSTextStorage *ts = [NSTextStorage new];
    NSLayoutManager *lm = [FTLayoutManager new];
    lm.allowsNonContiguousLayout = YES;
    [ts addLayoutManager:lm];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(frame.size.width, 1e7)];
    tc.widthTracksTextView = YES;
    [lm addTextContainer:tc];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:frame];
    sv.hasVerticalScroller = YES;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTextView *tv = [[FTTextView alloc] initWithFrame:frame textContainer:tc];
    tv.minSize = NSMakeSize(0, frame.size.height);
    tv.maxSize = NSMakeSize(1e7, 1e7);
    tv.verticallyResizable = YES;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.richText = NO;
    tv.importsGraphics = NO;
    tv.allowsUndo = YES;
    tv.usesFindBar = YES;
    tv.incrementalSearchingEnabled = YES;
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.automaticDashSubstitutionEnabled = NO;
    tv.automaticTextReplacementEnabled = NO;
    tv.automaticSpellingCorrectionEnabled = NO;
    tv.automaticLinkDetectionEnabled = NO;
    tv.automaticDataDetectionEnabled = NO;
    tv.continuousSpellCheckingEnabled = NO;
    tv.grammarCheckingEnabled = NO;
    tv.textContainerInset = NSMakeSize(6, 6);
    if (text.length) tv.string = text;
    [tv registerForDraggedTypes:[tv.registeredDraggedTypes arrayByAddingObject:NSPasteboardTypeFileURL]];
    tv.delegate = self;
    sv.documentView = tv;
    w.contentView = sv;
    _textView = tv;
    [self applyStyle];
    [w makeFirstResponder:tv];

    [self updateTitle];
    NSWindow *k = NSApp.keyWindow;
    if (k) [w setFrameTopLeftPoint:NSMakePoint(NSMinX(k.frame) + 24, NSMaxY(k.frame) - 24)];
    else [w center];
    [gDocs addObject:self];
    [w makeKeyAndOrderFront:nil];
    return self;
}

- (void)applyStyle {
    NSTextView *tv = _textView;
    NSFont *font = FTCurrentFont();
    NSColor *bg = FTBackground(), *fg = FTForeground();
    tv.font = font;
    tv.textColor = fg;
    tv.typingAttributes = @{ NSFontAttributeName : font, NSForegroundColorAttributeName : fg };
    tv.backgroundColor = bg;
    tv.insertionPointColor = fg;
    NSScrollView *sv = tv.enclosingScrollView;
    sv.backgroundColor = bg;

    // Tab width
    CGFloat space = [@" " sizeWithAttributes:@{ NSFontAttributeName : font }].width;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.tabStops = @[];
    ps.defaultTabInterval = FTTabWidth() * space;
    tv.defaultParagraphStyle = ps;
    tv.typingAttributes = @{ NSFontAttributeName : font, NSForegroundColorAttributeName : fg,
                             NSParagraphStyleAttributeName : ps };
    NSTextStorage *ts = tv.textStorage;
    if (ts.length) {
        [ts beginEditing];
        [ts addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, ts.length)];
        [ts endEditing];
    }

    // Line numbers (gutter is created on first use)
    BOOL nums = FTBool(kLineNumbers);
    if (nums && !_ruler) {
        _ruler = [[FTRuler alloc] initWithScrollView:sv];
        sv.verticalRulerView = _ruler;
        sv.hasVerticalRuler = YES;
        _ruler.clientView = tv;
    }
    if (_ruler) { sv.rulersVisible = nums; [sv tile]; _ruler.needsDisplay = YES; }

    // Line wrap
    BOOL wrap = FTBool(kWrap);
    if (wrap != _wrapState) {
        _wrapState = wrap;
        NSTextContainer *tc = tv.textContainer;
        sv.hasHorizontalScroller = !wrap;
        tv.horizontallyResizable = !wrap;
        tv.autoresizingMask = wrap ? NSViewWidthSizable : NSViewNotSizable;
        tc.widthTracksTextView = wrap;
        if (wrap) {
            [tv setFrameSize:NSMakeSize(sv.contentSize.width, tv.frame.size.height)];
        } else {
            tc.size = NSMakeSize(1e7, 1e7);
            [tv sizeToFit];
        }
    }

    // Current-line highlight, whitespace markers
    FTTextView *ftv = (FTTextView *)tv;
    ftv.highlightLine = FTBool(kHighlightLine);
    ftv.highlightColor = [fg colorWithAlphaComponent:0.09];
    ((FTLayoutManager *)tv.layoutManager).showWhitespace = FTBool(kShowWhitespace);
    tv.needsDisplay = YES;
    // Match scrollbars / find bar to the chosen background.
    NSString *hex = [NSUserDefaults.standardUserDefaults stringForKey:kBG];
    if (!hex.length) _window.appearance = nil;
    else {
        NSColor *c = [bg colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        double lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent;
        _window.appearance = [NSAppearance appearanceNamed:lum < 0.5 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    }
}

- (void)updateTitle {
    _window.title = _path ? _path.lastPathComponent : @"Untitled";
    _window.representedFilename = _path ?: @"";
    _window.documentEdited = _dirty;
}

- (BOOL)textView:(NSTextView *)tv shouldChangeTextInRange:(NSRange)r replacementString:(NSString *)s {
    [_ruler invalidateFrom:r.location];
    return YES;
}

- (void)textViewDidChangeSelection:(NSNotification *)n {
    [(FTTextView *)_textView selectionDidChange];
    if (_ruler) _ruler.needsDisplay = YES;
}

- (void)textDidChange:(NSNotification *)n {
    if (!_dirty) { _dirty = YES; _window.documentEdited = YES; }
}

- (BOOL)writeToPath:(NSString *)path {
    NSError *err = nil;
    if (![_textView.string writeToFile:path atomically:YES encoding:_encoding error:&err]) {
        FTAlert(@"Cannot save file", err.localizedDescription);
        return NO;
    }
    _path = [path copy];
    FTNoteRecent(path);
    _dirty = NO;
    [self updateTitle];
    return YES;
}

- (BOOL)saveAs {
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = _path.lastPathComponent ?: @"Untitled.txt";
    if (_path) p.directoryURL = [NSURL fileURLWithPath:_path.stringByDeletingLastPathComponent];
    if ([p runModal] != NSModalResponseOK) return NO;
    return [self writeToPath:p.URL.path];
}

- (void)saveDocument:(id)sender { [self save]; }
- (void)saveDocumentAs:(id)sender { [self saveAs]; }
- (BOOL)save { return _path ? [self writeToPath:_path] : [self saveAs]; }

- (BOOL)confirmClose {
    if (!_dirty) return YES;
    [_window makeKeyAndOrderFront:nil];
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Do you want to save changes to “%@”?", _window.title];
    a.informativeText = @"Your changes will be lost if you don’t save them.";
    [a addButtonWithTitle:@"Save"];
    [a addButtonWithTitle:@"Cancel"];
    [a addButtonWithTitle:@"Don’t Save"];
    switch ([a runModal]) {
        case NSAlertFirstButtonReturn: return [self save];
        case NSAlertThirdButtonReturn: return YES;
        default: return NO;
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender { return [self confirmClose]; }
- (void)windowWillClose:(NSNotification *)n {
    _window.delegate = nil;
    _textView.delegate = nil;
    [gDocs removeObject:self];
}

@end


static void FTRestyleAll(void) {
    for (FTDoc *d in gDocs) [d applyStyle];
}

@interface FTPrefs : NSObject
@property (nonatomic) NSWindow *window;
@property (nonatomic) NSPopUpButton *presetPop, *fontPop;
@property (nonatomic) NSColorWell *bgWell, *fgWell;
@property (nonatomic) NSTextField *sizeField, *preview;
@property (nonatomic) NSStepper *stepper, *tabStepper;
@property (nonatomic) NSTextField *tabField;
@property (nonatomic) NSArray<NSButton *> *checks;
+ (instancetype)shared;
+ (void)syncIfLoaded;
- (void)show;
@end

@implementation FTPrefs

static FTPrefs *gPrefs;

+ (instancetype)shared {
    if (!gPrefs) gPrefs = [FTPrefs new];
    return gPrefs;
}

+ (void)syncIfLoaded { if (gPrefs.window) [gPrefs syncControls]; }

static NSTextField *Label(NSString *t) {
    NSTextField *l = [NSTextField labelWithString:t];
    l.alignment = NSTextAlignmentRight;
    return l;
}

- (void)build {
    _presetPop = [NSPopUpButton new];
    for (NSArray *p in FTPresets()) [_presetPop addItemWithTitle:p[0]];
    [_presetPop addItemWithTitle:@"Custom"];
    _presetPop.target = self; _presetPop.action = @selector(presetChanged:);

    _bgWell = [NSColorWell new]; _fgWell = [NSColorWell new];
    for (NSColorWell *w in @[ _bgWell, _fgWell ]) {
        w.target = self; w.action = @selector(colorChanged:);
        [w.widthAnchor constraintEqualToConstant:44].active = YES;
        [w.heightAnchor constraintEqualToConstant:24].active = YES;
    }

    // Fixed-pitch families only; the list is computed here, never at launch.
    _fontPop = [NSPopUpButton new];
    [_fontPop addItemWithTitle:@"System Monospaced"];
    NSMutableSet *families = [NSMutableSet new];
    NSFontManager *fm = NSFontManager.sharedFontManager;
    for (NSString *n in [fm availableFontNamesWithTraits:NSFixedPitchFontMask]) {
        NSString *fam = [NSFont fontWithName:n size:12].familyName;
        if (fam) [families addObject:fam];
    }
    [_fontPop addItemsWithTitles:[families.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]];
    _fontPop.target = self; _fontPop.action = @selector(fontChanged:);

    _sizeField = [NSTextField textFieldWithString:@""];
    _sizeField.alignment = NSTextAlignmentRight;
    [_sizeField.widthAnchor constraintEqualToConstant:48].active = YES;
    _sizeField.target = self; _sizeField.action = @selector(sizeChanged:);
    _stepper = [NSStepper new];
    _stepper.minValue = kSizeMin; _stepper.maxValue = kSizeMax; _stepper.increment = 1;
    _stepper.target = self; _stepper.action = @selector(sizeChanged:);
    NSStackView *sizeRow = [NSStackView stackViewWithViews:@[ _sizeField, _stepper, [NSTextField labelWithString:@"pt"] ]];
    sizeRow.spacing = 6;

    _tabField = [NSTextField textFieldWithString:@""];
    _tabField.alignment = NSTextAlignmentRight;
    [_tabField.widthAnchor constraintEqualToConstant:48].active = YES;
    _tabField.target = self; _tabField.action = @selector(tabChanged:);
    _tabStepper = [NSStepper new];
    _tabStepper.minValue = kTabMin; _tabStepper.maxValue = kTabMax; _tabStepper.increment = 1;
    _tabStepper.target = self; _tabStepper.action = @selector(tabChanged:);
    NSStackView *tabRow = [NSStackView stackViewWithViews:@[ _tabField, _tabStepper, [NSTextField labelWithString:@"spaces"] ]];
    tabRow.spacing = 6;

    NSMutableArray *checks = [NSMutableArray new];
    for (NSArray *o in @[ @[ kWrap, @"Wrap lines" ], @[ kLineNumbers, @"Show line numbers" ],
                          @[ kHighlightLine, @"Highlight current line" ], @[ kShowWhitespace, @"Show whitespace" ] ]) {
        NSButton *b = [NSButton checkboxWithTitle:o[1] target:self action:@selector(optionChanged:)];
        b.identifier = o[0];
        [checks addObject:b];
    }
    _checks = checks;
    NSStackView *checkCol = [NSStackView stackViewWithViews:checks];
    checkCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    checkCol.alignment = NSLayoutAttributeLeading;
    checkCol.spacing = 6;

    _preview = [NSTextField wrappingLabelWithString:
        @"The quick brown fox jumps over the lazy dog.\n{ \"id\": 42, \"ok\": true }\nfunc main() { print(0123456789) }"];
    _preview.drawsBackground = YES;
    _preview.selectable = NO;
    [_preview.heightAnchor constraintEqualToConstant:84].active = YES;
    [_preview.widthAnchor constraintEqualToConstant:300].active = YES;

    NSGridView *g = [NSGridView gridViewWithViews:@[
        @[ Label(@"Preset:"), _presetPop ],
        @[ Label(@"Background:"), _bgWell ],
        @[ Label(@"Text color:"), _fgWell ],
        @[ Label(@"Font:"), _fontPop ],
        @[ Label(@"Size:"), sizeRow ],
        @[ Label(@"Tab width:"), tabRow ],
        @[ Label(@"Editor:"), checkCol ],
        @[ NSGridCell.emptyContentView, _preview ],
    ]];
    g.rowSpacing = 10;
    g.columnSpacing = 10;
    [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    g.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = [NSView new];
    [content addSubview:g];
    [NSLayoutConstraint activateConstraints:@[
        [g.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
        [g.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20],
        [g.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [g.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
    ]];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 300)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Settings";
    w.releasedWhenClosed = NO;
    w.restorable = NO;
    w.contentView = content;
    [content layoutSubtreeIfNeeded];
    [w setContentSize:content.fittingSize];
    [w center];
    _window = w;
}

- (void)syncControls {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *preset = [d stringForKey:kPreset];
    [_presetPop selectItemWithTitle:preset.length ? preset : @"System"];
    if (_presetPop.indexOfSelectedItem < 0) [_presetPop selectItemWithTitle:@"Custom"];
    _bgWell.color = FTBackground();
    _fgWell.color = FTForeground();
    NSString *fam = [d stringForKey:kFontName];
    if (!fam.length || ![_fontPop itemWithTitle:fam]) [_fontPop selectItemAtIndex:0];
    else [_fontPop selectItemWithTitle:fam];
    _sizeField.integerValue = (NSInteger)lround(FTFontSize());
    _stepper.doubleValue = FTFontSize();
    _tabField.integerValue = FTTabWidth();
    _tabStepper.integerValue = FTTabWidth();
    for (NSButton *b in _checks) b.state = FTBool(b.identifier) ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshPreview];
}

- (void)refreshPreview {
    _preview.font = FTCurrentFont();
    _preview.textColor = FTForeground();
    _preview.backgroundColor = FTBackground();
}

- (void)show {
    if (!_window) [self build];
    [self syncControls];
    [_window makeKeyAndOrderFront:nil];
}

- (void)changed { [self refreshPreview]; FTRestyleAll(); }

- (void)presetChanged:(NSPopUpButton *)pop {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *presets = FTPresets();
    NSInteger i = pop.indexOfSelectedItem;
    if (i >= (NSInteger)presets.count) return; // "Custom"
    NSArray *p = presets[i];
    [d setObject:p[0] forKey:kPreset];
    if ([p[1] length]) { [d setObject:p[1] forKey:kBG]; [d setObject:p[2] forKey:kFG]; }
    else { [d removeObjectForKey:kBG]; [d removeObjectForKey:kFG]; }
    _bgWell.color = FTBackground();
    _fgWell.color = FTForeground();
    [self changed];
}

- (void)colorChanged:(NSColorWell *)well {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    // Pin both colors so a half-custom scheme never mixes with system colors.
    [d setObject:FTHexFromColor(_bgWell.color) forKey:kBG];
    [d setObject:FTHexFromColor(_fgWell.color) forKey:kFG];
    [d setObject:@"Custom" forKey:kPreset];
    [_presetPop selectItemWithTitle:@"Custom"];
    [self changed];
}

- (void)fontChanged:(NSPopUpButton *)pop {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (pop.indexOfSelectedItem == 0) [d removeObjectForKey:kFontName];
    else [d setObject:pop.titleOfSelectedItem forKey:kFontName];
    [self changed];
}

- (void)optionChanged:(NSButton *)b {
    [NSUserDefaults.standardUserDefaults setBool:b.state == NSControlStateValueOn forKey:b.identifier];
    [self changed];
}

- (void)tabChanged:(id)sender {
    NSInteger v = MAX(kTabMin, MIN(kTabMax, [sender integerValue]));
    [NSUserDefaults.standardUserDefaults setInteger:v forKey:kTabWidth];
    _tabField.integerValue = v;
    _tabStepper.integerValue = v;
    [self changed];
}

- (void)sizeChanged:(id)sender {
    double v = [sender doubleValue];
    v = MAX(kSizeMin, MIN(kSizeMax, v));
    [NSUserDefaults.standardUserDefaults setDouble:v forKey:kFontSize];
    _sizeField.integerValue = (NSInteger)lround(v);
    _stepper.doubleValue = v;
    [self changed];
}

@end

static void FTOpenPaths(NSArray<NSString *> *paths) {
    for (NSString *p in paths) {
        FTDoc *existing = nil;
        for (FTDoc *d in gDocs) if ([d.path isEqualToString:p]) existing = d;
        if (existing) [existing.window makeKeyAndOrderFront:nil];
        else (void)[[FTDoc alloc] initWithPath:p];
    }
}

@interface FTApp : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation FTApp

- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)files {
    FTOpenPaths(files);
    [app replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

// Rebuilt lazily, only when the Open Recent menu is about to be shown.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *p in [NSUserDefaults.standardUserDefaults arrayForKey:kRecentKey]) {
        if (![fm fileExistsAtPath:p]) continue;
        NSMenuItem *i = [menu addItemWithTitle:p.lastPathComponent action:@selector(openRecent:) keyEquivalent:@""];
        i.representedObject = p;
        i.toolTip = p;
    }
    if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Clear Menu" action:@selector(clearRecent:) keyEquivalent:@""].enabled = menu.numberOfItems > 0;
}

- (void)openRecent:(NSMenuItem *)item { FTOpenPaths(@[ item.representedObject ]); }
- (void)clearRecent:(id)sender { [NSUserDefaults.standardUserDefaults removeObjectForKey:kRecentKey]; }

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    if (!gDocs.count) (void)[[FTDoc alloc] initWithPath:nil];
    [NSApp activate];
#ifdef FT_BENCH
    [NSApp.windows.firstObject displayIfNeeded];
    dispatch_async(dispatch_get_main_queue(), ^{ FTReportAndExit(); });
#endif
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    if (!flag) (void)[[FTDoc alloc] initWithPath:nil];
    return YES;
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)app { return NO; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return NO; }

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    for (FTDoc *d in [gDocs copy]) if (![d confirmClose]) return NSTerminateCancel;
    return NSTerminateNow;
}

- (void)toggleOption:(NSMenuItem *)item {
    NSString *key = item.representedObject;
    [NSUserDefaults.standardUserDefaults setBool:!FTBool(key) forKey:key];
    FTRestyleAll();
    [FTPrefs syncIfLoaded];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleOption:))
        item.state = FTBool(item.representedObject) ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
}

- (void)showPreferences:(id)sender { [[FTPrefs shared] show]; }

- (void)zoom:(double)size {
    [NSUserDefaults.standardUserDefaults setDouble:MAX(kSizeMin, MIN(kSizeMax, size)) forKey:kFontSize];
    FTRestyleAll();
}
- (void)biggerFont:(id)sender { [self zoom:FTFontSize() + 1]; }
- (void)smallerFont:(id)sender { [self zoom:FTFontSize() - 1]; }
- (void)actualFont:(id)sender { [self zoom:kSizeDefault]; }

- (void)newDocument:(id)sender { (void)[[FTDoc alloc] initWithPath:nil]; }

- (void)openDocument:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowsMultipleSelection = YES;
    if ([p runModal] != NSModalResponseOK) return;
    NSMutableArray *paths = [NSMutableArray new];
    for (NSURL *u in p.URLs) [paths addObject:u.path];
    FTOpenPaths(paths);
}

@end

static NSMenuItem *FTItem(NSMenu *m, NSString *title, SEL action, NSString *key,
                          NSEventModifierFlags mods) {
    NSMenuItem *i = [m addItemWithTitle:title action:action keyEquivalent:key];
    if (mods) i.keyEquivalentModifierMask = mods;
    return i;
}

static NSMenu *FTSubmenu(NSMenu *bar, NSString *title) {
    NSMenuItem *host = [bar addItemWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:title];
    host.submenu = m;
    return m;
}

static void FTBuildMenu(void) {
    const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    NSMenu *bar = [NSMenu new];

    NSMenu *app = FTSubmenu(bar, @"FastText");
    FTItem(app, @"About FastText", @selector(orderFrontStandardAboutPanel:), @"", 0);
    [app addItem:NSMenuItem.separatorItem];
    FTItem(app, @"Settings…", @selector(showPreferences:), @",", cmd);
    [app addItem:NSMenuItem.separatorItem];
    FTItem(app, @"Hide FastText", @selector(hide:), @"h", cmd);
    FTItem(app, @"Hide Others", @selector(hideOtherApplications:), @"h", cmd | NSEventModifierFlagOption);
    [app addItem:NSMenuItem.separatorItem];
    FTItem(app, @"Quit FastText", @selector(terminate:), @"q", cmd);

    NSMenu *file = FTSubmenu(bar, @"File");
    FTItem(file, @"New", @selector(newDocument:), @"n", cmd);
    FTItem(file, @"Open…", @selector(openDocument:), @"o", cmd);
    NSMenuItem *recent = [file addItemWithTitle:@"Open Recent" action:nil keyEquivalent:@""];
    recent.submenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
    recent.submenu.delegate = (id<NSMenuDelegate>)NSApp.delegate;
    [file addItem:NSMenuItem.separatorItem];
    FTItem(file, @"Close", @selector(performClose:), @"w", cmd);
    FTItem(file, @"Save", @selector(saveDocument:), @"s", cmd);
    FTItem(file, @"Save As…", @selector(saveDocumentAs:), @"s", cmd | NSEventModifierFlagShift);

    NSMenu *edit = FTSubmenu(bar, @"Edit");
    FTItem(edit, @"Undo", @selector(undo:), @"z", cmd);
    FTItem(edit, @"Redo", @selector(redo:), @"z", cmd | NSEventModifierFlagShift);
    [edit addItem:NSMenuItem.separatorItem];
    FTItem(edit, @"Cut", @selector(cut:), @"x", cmd);
    FTItem(edit, @"Copy", @selector(copy:), @"c", cmd);
    FTItem(edit, @"Paste", @selector(paste:), @"v", cmd);
    FTItem(edit, @"Select All", @selector(selectAll:), @"a", cmd);
    [edit addItem:NSMenuItem.separatorItem];
    FTItem(edit, @"Find…", @selector(performTextFinderAction:), @"f", cmd).tag = NSTextFinderActionShowFindInterface;
    FTItem(edit, @"Find Next", @selector(performTextFinderAction:), @"g", cmd).tag = NSTextFinderActionNextMatch;
    FTItem(edit, @"Find Previous", @selector(performTextFinderAction:), @"g", cmd | NSEventModifierFlagShift).tag = NSTextFinderActionPreviousMatch;

    NSMenu *view = FTSubmenu(bar, @"View");
    FTItem(view, @"Bigger", @selector(biggerFont:), @"+", cmd);
    FTItem(view, @"Smaller", @selector(smallerFont:), @"-", cmd);
    FTItem(view, @"Actual Size", @selector(actualFont:), @"0", cmd);
    [view addItem:NSMenuItem.separatorItem];
    const NSEventModifierFlags cmdOpt = cmd | NSEventModifierFlagOption;
    FTItem(view, @"Wrap Lines", @selector(toggleOption:), @"w", cmdOpt).representedObject = kWrap;
    FTItem(view, @"Show Line Numbers", @selector(toggleOption:), @"l", cmdOpt).representedObject = kLineNumbers;
    FTItem(view, @"Highlight Current Line", @selector(toggleOption:), @"h", cmdOpt).representedObject = kHighlightLine;
    FTItem(view, @"Show Whitespace", @selector(toggleOption:), @"i", cmdOpt).representedObject = kShowWhitespace;

    NSMenu *win = FTSubmenu(bar, @"Window");
    FTItem(win, @"Minimize", @selector(performMiniaturize:), @"m", cmd);
    FTItem(win, @"Zoom", @selector(performZoom:), @"", 0);
    NSApp.windowsMenu = win;

    NSApp.mainMenu = bar;
}

int main(void) {
    @autoreleasepool {
        gDocs = [NSMutableArray new];
        NSApplication *app = [NSApplication sharedApplication];
        FTApp *delegate = [FTApp new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        FTBuildMenu();
        [app run];
    }
    return 0;
}
