#import "NewQsoPanel.h"
#import "Night.h"
#import "Panels.h"
#import "L10n.h"
#import "ToolWindow.h"
#import "Workspace.h"

#include "adif_layout.h"

#include <algorithm>
#include <cmath>
#include <ctime>

// Problems in their colour; plain text dimmed.
static NSColor *severityColor(int severity) { return severity < 0 ? theme::faint() : ADIFSeverityColor(severity); }

// A scroll view's document view must be flipped for content to start at the top.
@interface ADIFFlippedView : NSView
@end
@implementation ADIFFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

// ── The Operating Aids strip (New QSO's, and the Operating Aids panel's) ──

// A line of Operating Aids as a message bubble (the Cards layout): rounded, with a tail at its foot
// on the side it comes from: the aids' on the left (what they tell you), yours on the right (what
// you say or send). Drawn, not a layer's, so a snapshot of the panel has it as the screen does.
@interface ADIFAidBubble : NSView
- (instancetype)initWithContent:(NSView *)content fill:(NSColor *)fill outgoing:(BOOL)outgoing;
@end

static const CGFloat kAidTail = 6;  // the tail's width beside the bubble

@implementation ADIFAidBubble {
    NSColor *_fill;
    BOOL _outgoing;
}
- (instancetype)initWithContent:(NSView *)content fill:(NSColor *)fill outgoing:(BOOL)outgoing {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _fill = fill;
    _outgoing = outgoing;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [content.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-7],
        [content.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:outgoing ? 11 : 11 + kAidTail],
        [content.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:outgoing ? -(11 + kAidTail) : -11],
    ]];
    return self;
}
- (void)drawRect:(NSRect)dirty {
    NSRect body = self.bounds;
    body.size.width -= kAidTail;
    if (!_outgoing) body.origin.x += kAidTail;
    CGFloat r = std::min<CGFloat>(14, NSHeight(body) / 2);
    NSBezierPath *bubble = [NSBezierPath bezierPathWithRoundedRect:body xRadius:r yRadius:r];
    // The tail: from the side, near the foot, curving out to a point level with the foot.
    CGFloat side = _outgoing ? NSMaxX(body) : NSMinX(body), out = _outgoing ? 1 : -1, y = NSMinY(body);
    NSBezierPath *tail = [NSBezierPath bezierPath];
    [tail moveToPoint:NSMakePoint(side, y + std::min<CGFloat>(14, NSHeight(body) - 2))];
    [tail curveToPoint:NSMakePoint(side + out * kAidTail, y) controlPoint1:NSMakePoint(side, y + 4) controlPoint2:NSMakePoint(side + out * kAidTail * 0.5, y)];
    [tail curveToPoint:NSMakePoint(side - out * 10, y + 1) controlPoint1:NSMakePoint(side + out * 1, y) controlPoint2:NSMakePoint(side - out * 4, y)];
    [tail closePath];
    // One fill for both, through a transparency layer: a translucent colour isn't doubled where they meet.
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    NSColor *fill = [_fill colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: _fill;
    CGContextSetAlpha(cg, fill.alphaComponent);
    CGContextBeginTransparencyLayer(cg, NULL);
    [[fill colorWithAlphaComponent:1] setFill];
    [bubble fill];
    [tail fill];
    CGContextEndTransparencyLayer(cg);
}
@end

@implementation ADIFAidsView {
    NSString *_prefix;  // its controls' names: <prefix>.title, .row.N, .note.N, .skip.N...
    NSTextField *_head;
    NSMutableArray<NSTextField *> *_bubbleText;  // the bubbles' text: wraps at most of the view's width
}

- (instancetype)initWithPrefix:(NSString *)prefix {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _prefix = [prefix copy];
    _bubbleText = [NSMutableArray array];
    self.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.alignment = NSLayoutAttributeLeading;
    self.spacing = 8;
    self.identifier = prefix;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    return self;
}

- (CGFloat)baseSize {
    return _textSize >= 2 ? 16 : _textSize == 1 ? NSFont.systemFontSize : NSFont.smallSystemFontSize;
}

// The font chosen, at a size and weight: the system's, rounded, monospaced or serif.
- (NSFont *)fontOfSize:(CGFloat)size weight:(NSFontWeight)weight {
    NSFont *f = _fontFamily == 2 ? [NSFont monospacedSystemFontOfSize:size weight:weight] : [NSFont systemFontOfSize:size weight:weight];
    NSFontDescriptorSystemDesign design = _fontFamily == 1 ? NSFontDescriptorSystemDesignRounded : _fontFamily == 3 ? NSFontDescriptorSystemDesignSerif : nil;
    if (design)
        if (NSFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:design]) f = [NSFont fontWithDescriptor:d size:size] ?: f;
    return f;
}

// A bubble is at most this wide; its text wraps inside it.
- (CGFloat)bubbleTextWidth {
    CGFloat w = NSWidth(self.bounds) > 0 ? NSWidth(self.bounds) : 300;
    return std::max<CGFloat>(80, std::floor(w * 0.85) - 22 - kAidTail - 24);  // its padding, tail and a symbol
}

- (void)setFrameSize:(NSSize)size {
    BOOL wider = std::fabs(size.width - NSWidth(self.bounds)) >= 0.5;
    [super setFrameSize:size];
    if (!wider) return;
    CGFloat w = self.bubbleTextWidth;
    for (NSTextField *t in _bubbleText) {
        t.preferredMaxLayoutWidth = w;
        [t invalidateIntrinsicContentSize];
    }
}

- (void)setTitle:(NSString *)title rows:(const std::vector<ADIFAidRow> &)rows menu:(NSMenu *)menu hidden:(BOOL)hidden {
    for (NSView *v in [self.arrangedSubviews copy]) [self removeView:v];
    [_bubbleText removeAllObjects];
    self.menu = menu;  // Control-click anywhere on the aids
    const BOOL bubbles = _layoutStyle == 1, minimal = _layoutStyle == 2;
    self.spacing = bubbles ? 6 : minimal ? 6 : 8;
    if (!title) return;
    const CGFloat size = self.baseSize;
    NSFont *plain = [self fontOfSize:size weight:NSFontWeightRegular], *italic = [[NSFontManager sharedFontManager] convertFont:plain toHaveTrait:NSItalicFontMask];
    NSFont *caption = [self fontOfSize:std::max<CGFloat>(9, size - 1) weight:NSFontWeightSemibold];
    NSColor *accent = _tint ?: theme::faint();  // symbols, headings, scripts' names
    // Your bubbles: the tint, else the accent colour, with white or black text, whichever reads on it.
    NSColor *mine = [(_tint ?: NSColor.controlAccentColor) colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.systemBlueColor;
    CGFloat luminance = 0.2126 * mine.redComponent + 0.7152 * mine.greenComponent + 0.0722 * mine.blueComponent;
    NSColor *onMine = luminance > 0.55 ? NSColor.blackColor : NSColor.whiteColor;
    auto symbolView = [&](NSString *name, NSColor *tint) {
        NSImageView *i = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] ?: [[NSImage alloc] init]];
        i.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightRegular];
        i.contentTintColor = tint;
        [i setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [i setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        return i;
    };
    auto link = [&](NSString *name, NSString *ident, NSString *tip, NSInteger row, NSFont *font) {  // its action is in its identifier
        NSButton *b = [NSButton buttonWithTitle:name target:self action:@selector(aidPressed:)];
        b.bordered = NO;
        b.font = font;
        b.contentTintColor = NSColor.linkColor;
        b.identifier = ident;
        b.toolTip = tip;
        b.tag = row;
        [b setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [b setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        return b;
    };
    auto fullWidth = [&](NSView *v) {
        [self addArrangedSubview:v];
        [v.widthAnchor constraintEqualToAnchor:self.widthAnchor].active = YES;
    };
    // The title: what it is and for which style, Hide or Show. Its menu is the whole view's.
    _head = [NSTextField labelWithString:title];
    _head.font = [self fontOfSize:size weight:NSFontWeightSemibold];
    _head.textColor = theme::faint();
    _head.lineBreakMode = NSLineBreakByTruncatingTail;
    _head.identifier = [_prefix stringByAppendingString:@".title"];
    _head.toolTip = menu ? T(@"Control-click for Operating Aids' menu: suggestions, scripts, previous QSOs, text size and style") : nil;
    [_head setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSMutableArray<NSView *> *top = [NSMutableArray array];
    if (!minimal) [top addObject:symbolView(@"text.bubble", accent)];
    [top addObject:_head];
    [top addObject:hidden ? link(T(@"Show"), [_prefix stringByAppendingString:@".show"], T(@"Show Operating Aids again"), -1, plain)
                          : link(T(@"Hide"), [_prefix stringByAppendingString:@".hide"],
                                 T(@"Hide Operating Aids until ADIF Lint starts again (Suggestions at Once, in their menu, turns them off for good)"), -1, plain)];
    NSStackView *topRow = [NSStackView stackViewWithViews:top];
    topRow.spacing = 6;
    topRow.alignment = NSLayoutAttributeCenterY;
    fullWidth(topRow);
    if (hidden) return;
    NSRegularExpression *gap = [NSRegularExpression regularExpressionWithPattern:@"\\{[A-Z0-9_]+\\}" options:0 error:nil];
    NSInteger i = 0;
    for (const ADIFAidRow &r : rows) {
        const NSInteger row = i++;
        auto named = [&](NSString *what) { return [NSString stringWithFormat:@"%@.%@.%ld", _prefix, what, (long)row]; };
        const bool script = !r.title.empty();
        // Minimal: only what to say or do (the scripts, the suggestions, Chasing's next), and warnings.
        if (minimal && (r.heading || (!script && !r.suggestion && !r.next && r.severity != 2))) continue;
        if (r.heading) {  // a group's heading: in the list, a line; among bubbles, a caption between them
            NSTextField *h = [NSTextField labelWithString:ADIFString(r.text)];
            h.font = caption;
            h.textColor = bubbles ? theme::faint() : accent;
            h.identifier = named(@"row");
            h.toolTip = r.why.empty() ? nil : ADIFString(r.why);
            NSView *before = self.arrangedSubviews.lastObject;
            if (bubbles) {
                h.alignment = NSTextAlignmentCenter;
                h.lineBreakMode = NSLineBreakByTruncatingTail;
                [h setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
                fullWidth(h);
                [self setCustomSpacing:4 afterView:h];
            } else {
                NSStackView *line = [NSStackView stackViewWithViews:@[ symbolView(r.symbol ?: @"list.bullet", accent), h ]];
                line.spacing = 6;
                line.alignment = NSLayoutAttributeCenterY;
                [self addArrangedSubview:line];
                [self setCustomSpacing:4 afterView:line];
            }
            if (before) [self setCustomSpacing:14 afterView:before];  // room above each group
            continue;
        }
        // The links: a suggestion's Note, Skip and Dismiss; a script's Dismiss; Chasing's Next.
        NSFont *linkFont = bubbles ? caption : plain;
        NSMutableArray<NSView *> *links = [NSMutableArray array];
        if (r.suggestion) {
            if (r.note)
                [links addObject:link(T(@"Note"), named(@"note"), T(@"Start a note on this topic in NOTES, for you to finish (nothing is sent anywhere)"), row, linkFont)];
            [links addObject:link(T(@"Skip"), named(@"skip"), T(@"Another suggestion in its place"), row, linkFont)];
            [links addObject:link(T(@"Dismiss"), named(@"dismiss"), T(@"Don't suggest this again (the menu brings dismissed suggestions back)"), row, linkFont)];
        } else if (r.next) {
            [links addObject:link(T(@"Next"), named(@"next"), T(@"Choose it on the map: the next opportunity (⌘G in the Map)"), row, linkFont)];
        } else if (script) {
            [links addObject:link(T(@"Dismiss"), named(@"dismiss"), T(@"Don't show this script (the menu's Scripts shows it again)"), row, linkFont)];
        }
        // The words: a script's written out, a {VARIABLE} still in it marked as not known yet.
        NSColor *textColour = bubbles && script ? onMine
                              : r.suggestion    ? theme::faint()
                              : r.severity == 1 || r.severity == 2 ? theme::severity(r.severity)
                                                                    : NSColor.labelColor;
        NSTextField *t = bubbles ? [NSTextField wrappingLabelWithString:@""] : ADIFWrappingLabel();
        NSFont *font = r.suggestion ? italic : plain;
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:ADIFString(r.text)
                                                                              attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : textColour}];
        if (script)
            for (NSTextCheckingResult *m in [gap matchesInString:s.string options:0 range:NSMakeRange(0, s.length)]) {
                if (bubbles) {  // bold and underlined: it reads on any bubble colour
                    [s addAttribute:NSFontAttributeName value:[self fontOfSize:size weight:NSFontWeightBold] range:m.range];
                    [s addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:m.range];
                } else {
                    [s addAttribute:NSForegroundColorAttributeName value:theme::warning() range:m.range];
                }
            }
        t.attributedStringValue = s;
        t.maximumNumberOfLines = script ? 0 : 3;
        std::string tip = minimal && script ? r.title + (r.why.empty() ? "" : "\n" + r.why) : r.why;  // Minimal: a script's name in its tooltip
        t.toolTip = tip.empty() ? nil : ADIFString(tip);
        t.identifier = named(@"row");
        t.accessibilityLabel = r.suggestion ? TF(@"Suggestion: {text}", @{@"text" : t.stringValue}) : script ? [NSString stringWithFormat:@"%@: %@", ADIFString(r.title), t.stringValue] : nil;
        NSView *words = t;
        if (script && !minimal) {  // its name over it
            NSTextField *name = [NSTextField labelWithString:ADIFString(r.title)];
            name.font = caption;
            name.textColor = bubbles ? [onMine colorWithAlphaComponent:0.8] : accent;
            name.identifier = named(@"name");
            name.lineBreakMode = NSLineBreakByTruncatingTail;
            [name setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
            NSStackView *both = [NSStackView stackViewWithViews:@[ name, t ]];
            both.orientation = NSUserInterfaceLayoutOrientationVertical;
            both.alignment = NSLayoutAttributeLeading;
            both.spacing = 2;
            if (!bubbles) {  // as wide as the line lets it: the text wraps there
                [both setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
                [both setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
                [both setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
                [t.widthAnchor constraintEqualToAnchor:both.widthAnchor].active = YES;
            }
            words = both;
        }
        NSString *symbol = r.symbol ?: (r.suggestion ? @"bubble.left" : script ? @"text.quote" : @"circle.fill");
        NSColor *symbolTint = r.suggestion ? theme::faint() : script ? accent : theme::severity(r.severity == 1 || r.severity == 2 ? r.severity : 3);
        if (bubbles) {
            // The bubble: yours (a script) on the right, in your colour; the aids' on the left, grey.
            t.preferredMaxLayoutWidth = self.bubbleTextWidth;
            [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
            [_bubbleText addObject:t];
            NSView *inside = words;
            if (!script) {
                NSStackView *withSymbol = [NSStackView stackViewWithViews:@[ symbolView(symbol, symbolTint), words ]];
                withSymbol.spacing = 6;
                withSymbol.alignment = NSLayoutAttributeFirstBaseline;
                inside = withSymbol;
            }
            ADIFAidBubble *bubble = [[ADIFAidBubble alloc] initWithContent:inside
                                                                      fill:script ? mine : [NSColor.labelColor colorWithAlphaComponent:0.1]
                                                                  outgoing:script];
            NSMutableArray<NSView *> *parts = [NSMutableArray arrayWithObject:bubble];
            if (links.count) {  // under it, small, as a message's status is
                NSStackView *under = [NSStackView stackViewWithViews:links];
                under.spacing = 10;
                [parts addObject:under];
            }
            NSStackView *message = [NSStackView stackViewWithViews:parts];
            message.orientation = NSUserInterfaceLayoutOrientationVertical;
            message.alignment = script ? NSLayoutAttributeTrailing : NSLayoutAttributeLeading;
            message.spacing = 2;
            if (links.count) message.edgeInsets = NSEdgeInsetsMake(0, script ? 0 : kAidTail + 4, 0, script ? kAidTail + 4 : 0);
            fullWidth(message);
            [bubble.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor multiplier:0.85].active = YES;
            continue;
        }
        [t setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [t setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSMutableArray<NSView *> *parts = [NSMutableArray array];
        if (!minimal) [parts addObject:symbolView(symbol, symbolTint)];
        [parts addObject:words];
        [parts addObjectsFromArray:links];
        NSStackView *line = [NSStackView stackViewWithViews:parts];
        line.spacing = 6;
        line.alignment = NSLayoutAttributeFirstBaseline;
        for (NSUInteger k = 0; k + 1 < links.count; ++k) [line setCustomSpacing:10 afterView:links[k]];  // each link's own label is wider than it
        fullWidth(line);
    }
}

- (void)aidPressed:(NSButton *)sender {
    // <prefix>.<action>[.<row>]
    NSString *rest = [sender.identifier substringFromIndex:MIN(_prefix.length + 1, sender.identifier.length)];
    NSString *action = [rest componentsSeparatedByString:@"."].firstObject;
    if (self.onAid && action.length) self.onAid(action, sender.tag);
}

// VoiceOver's Show Menu: the aids' menu, under the title.
- (BOOL)accessibilityPerformShowMenu {
    if (!self.menu || !_head) return NO;
    [self.menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(_head.bounds) + 2) inView:_head];
    return YES;
}

@end

@implementation ADIFNewQsoPanel {
    NSWindow *_window;
    NSTextField *_target, *_summary, *_note;
    NSScrollView *_scroll;
    ADIFFlippedView *_document;
    NSGridView *_grid;
    NSLayoutConstraint *_scrollHeight;
    NSButton *_currentTime, *_log, *_close, *_fields, *_spots, *_contest;
    NSButton *_spotCluster, *_spotPota;
    NSTextField *_spotStatus;
    NSGridView *_spotGrid;
    NSLayoutConstraint *_logAfterGrid, *_logAfterStatus;  // one is active: the status line shown or not
    NSGridView *_facts;  // what the lookup says of itself (found, failed); its facts are in QSO Details
    NSButton *_detailsLink;  // Show in QSO Details, while the lookup has facts and QSO Details is closed
    BOOL _hasFacts;
    NSStackView *_lookupRow, *_stationRow;
    NSTextField *_stationSummary;
    NSPopUpButton *_lookup, *_station;
    NSTimer *_timer;
    std::vector<ADIFQsoRow> _rows;
    NSMutableArray<NSTextField *> *_controls;  // NSTextField or NSComboBox, per row
    NSMutableArray<NSTextField *> *_status;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _timeDigits = 6;
    _controls = [NSMutableArray array];
    _status = [NSMutableArray array];

    // A normal window, not a floating panel: Apple's guidelines keep typing out of panels, and a
    // window stays in sight when you switch to another app to look something up.
    _window = [[ADIFDockWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 480)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                    NSWindowStyleMaskMiniaturizable
                                            backing:NSBackingStoreBuffered
                                              defer:YES];
    ((ADIFDockWindow *)_window).dockItem = kDockNewQso;
    _window.title = T(@"QSO");
    _window.releasedWhenClosed = NO;
    _window.tabbingMode = NSWindowTabbingModeDisallowed;
    _window.delegate = self;
    _window.autorecalculatesKeyViewLoop = YES;
    _window.contentMinSize = NSMakeSize(420, 260);
    [_window center];
    NSView *root = _window.contentView;

    _target = [NSTextField labelWithString:@""];
    _target.textColor = theme::faint();
    _target.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _target.translatesAutoresizingMaskIntoConstraints = NO;
    [_target setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.drawsBackground = NO;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _document = [[ADIFFlippedView alloc] initWithFrame:NSZeroRect];
    _document.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.documentView = _document;

    _currentTime = [NSButton checkboxWithTitle:T(@"Use the current UTC date and time when logging") target:self
                                        action:@selector(currentTimeChanged:)];
    _currentTime.state = NSControlStateValueOn;
    _currentTime.translatesAutoresizingMaskIntoConstraints = NO;

    _note = ADIFWrappingLabel();
    _note.font = theme::small();
    _note.textColor = theme::faint();
    _note.maximumNumberOfLines = 3;
    _note.identifier = @"newqso.note";
    _note.translatesAutoresizingMaskIntoConstraints = NO;

    _summary = ADIFWrappingLabel();  // as the note: wraps at the panel's width
    _summary.maximumNumberOfLines = 4;
    _summary.translatesAutoresizingMaskIntoConstraints = NO;

    _log = [NSButton buttonWithTitle:T(@"Log QSO") target:self action:@selector(logPressed:)];
    _log.keyEquivalent = @"\r";
    _close = [NSButton buttonWithTitle:T(@"Close") target:self action:@selector(closePressed:)];
    _close.keyEquivalent = @"\033";
    _fields = [NSButton buttonWithTitle:T(@"Fields...") target:self action:@selector(fieldsPressed:)];
    _fields.toolTip = T(@"Choose and order the fields this window asks for");
    _spots = [NSButton buttonWithTitle:T(@"Spots...") target:self action:@selector(spotsPressed:)];
    _spots.toolTip = T(@"Activators spotted now (POTA, WWFF, and GMA, WWBOTA, IOTA and more from Spothole): pick one to fill CALL, "
                     @"FREQ, MODE and their reference");
    _contest = [NSButton buttonWithTitle:T(@"Contest...") target:self action:@selector(contestPressed:)];
    _contest.toolTip = T(@"ARRL Field Day, Winter Field Day or serial numbers: the exchange to ask for, the contest's fields and "
                       @"its duplicate rule");

    _lookup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_lookup addItemsWithTitles:@[ T(@"Off"), T(@"Country data"), @"QRZ.com", @"HamQTH" ]];  // chosen by index
    _lookup.target = self;
    _lookup.action = @selector(lookupChanged:);
    _lookup.toolTip = T(@"Look the call up as you type and fill the fields that are still empty: country and zones from the "
                      @"call's prefix, or name, QTH, state, grid and more from a callbook (accounts in Settings)");
    // Under the popup, what the lookup says, a fact a row: its name on the left, the fact (one line,
    // whole in its tooltip) on the right.
    _facts = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
    _facts.rowSpacing = 3;
    _facts.columnSpacing = 8;
    _facts.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [_facts columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    _facts.identifier = @"qso.facts";
    _facts.translatesAutoresizingMaskIntoConstraints = NO;
    _station = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _station.target = self;
    _station.action = @selector(stationChanged:);
    _station.toolTip = T(@"Your station's fields for the QSOs you log: from the log's last record, or a station profile");
    [self setStations:@[] selected:0];
    // The station first: its profile, and what it writes (your call, grid, power, rig, park).
    _stationSummary = [NSTextField labelWithString:@""];
    _stationSummary.textColor = theme::faint();
    _stationSummary.lineBreakMode = NSLineBreakByTruncatingTail;
    _stationSummary.identifier = @"qso.station.summary";
    // Cut short (its tooltip has it all) before it widens the panel: below a docked frame's fit (Workspace.mm).
    [_stationSummary setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _station.identifier = @"qso.station";
    _stationRow = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:T(@"Station:")], _station, _stationSummary ]];
    _stationRow.spacing = 8;
    _stationRow.alignment = NSLayoutAttributeCenterY;
    _stationRow.translatesAutoresizingMaskIntoConstraints = NO;
    // The lookup's facts (the operator, country and zones, grid, distance, local time...) are in QSO Details.
    _detailsLink = [NSButton buttonWithTitle:T(@"Show in QSO Details") target:self action:@selector(showDetails:)];
    _detailsLink.bezelStyle = NSBezelStyleInline;
    _detailsLink.controlSize = NSControlSizeSmall;
    _detailsLink.font = theme::small();
    _detailsLink.identifier = @"qso.lookup.details";
    _detailsLink.toolTip = T(@"What the lookup found (the operator, country and zones, grid, distance and bearing, local time, LoTW, worked "
                             @"before) is in QSO Details");
    _detailsLink.hidden = YES;
    _lookupRow = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:T(@"Look up:")], _lookup, _detailsLink ]];
    _lookupRow.spacing = 8;
    _lookupRow.alignment = NSLayoutAttributeCenterY;
    _lookupRow.translatesAutoresizingMaskIntoConstraints = NO;

    // Spot when logging, beside Log QSO: two boxes that stay as they are left, then what the last spots did.
    _spotCluster = [NSButton checkboxWithTitle:T(@"The station, on the DX cluster") target:self action:@selector(spotChanged:)];
    _spotCluster.identifier = @"qso.spot.cluster";
    _spotPota = [NSButton checkboxWithTitle:T(@"Myself, on pota.app") target:self action:@selector(spotChanged:)];
    _spotPota.identifier = @"qso.spot.pota";
    _spotGrid = [NSGridView gridViewWithViews:@[
        @[ [NSTextField labelWithString:T(@"Spot when logging:")], _spotCluster ], @[ [NSGridCell emptyContentView], _spotPota ]
    ]];
    _spotGrid.rowSpacing = 4;
    _spotGrid.columnSpacing = 8;
    _spotGrid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    _spotGrid.translatesAutoresizingMaskIntoConstraints = NO;
    _spotStatus = ADIFWrappingLabel();
    _spotStatus.font = theme::small();
    _spotStatus.textColor = theme::faint();
    _spotStatus.maximumNumberOfLines = 2;
    _spotStatus.cell.truncatesLastVisibleLine = YES;
    _spotStatus.identifier = @"qso.spot.status";
    _spotStatus.hidden = YES;
    _spotStatus.translatesAutoresizingMaskIntoConstraints = NO;
    [_spotStatus setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    // The buttons wrap onto another line rather than leave the window when it is narrow.
    ADIFButtonRow *buttons = [[ADIFButtonRow alloc] initWithFrame:NSZeroRect];
    for (NSView *b in @[ _fields, _spots, _contest ]) [buttons addLeading:b];
    [buttons addLeading:_close];
    [buttons addLeading:_log];
    for (NSView *v in @[ _target, _stationRow, _scroll, _currentTime, _lookupRow, _facts, _note, _summary, _spotGrid, _spotStatus, buttons ])
        [root addSubview:v];
    __weak ADIFNewQsoPanel *me = self;  // the link follows QSO Details opening and closing
    [[NSNotificationCenter defaultCenter] addObserverForName:ADIFPanelShownNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *) { [me showDetailsLink]; }];
    const CGFloat m = kADIFMargin;
    _logAfterGrid = [buttons.topAnchor constraintEqualToAnchor:_spotGrid.bottomAnchor constant:8];
    _logAfterStatus = [buttons.topAnchor constraintEqualToAnchor:_spotStatus.bottomAnchor constant:8];
    // The lookup's line no taller than its row (with none, nothing): the window's spare height goes
    // to the message under the notes, not to an empty grid.
    for (NSView *v in @[ _facts ]) {
        NSLayoutConstraint *tight = [v.heightAnchor constraintEqualToConstant:0];
        tight.priority = NSLayoutPriorityDefaultLow + 1;
        tight.active = YES;
    }
    _scrollHeight = [_scroll.heightAnchor constraintEqualToConstant:300];
    _scrollHeight.priority = NSLayoutPriorityDefaultHigh - 1;
    [NSLayoutConstraint activateConstraints:@[
        [_target.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
        [_target.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_target.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [_stationRow.topAnchor constraintEqualToAnchor:_target.bottomAnchor constant:8],
        [_stationRow.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_stationRow.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
        [_scroll.topAnchor constraintEqualToAnchor:_stationRow.bottomAnchor constant:8],
        [_scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        _scrollHeight,
        [_scroll.heightAnchor constraintGreaterThanOrEqualToConstant:120],
        [_document.leadingAnchor constraintEqualToAnchor:_scroll.contentView.leadingAnchor],
        [_document.trailingAnchor constraintEqualToAnchor:_scroll.contentView.trailingAnchor],
        [_document.topAnchor constraintEqualToAnchor:_scroll.contentView.topAnchor],
        [_currentTime.topAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:8],
        [_currentTime.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_lookupRow.topAnchor constraintEqualToAnchor:_currentTime.bottomAnchor constant:6],
        [_lookupRow.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_lookupRow.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
        [_facts.topAnchor constraintEqualToAnchor:_lookupRow.bottomAnchor constant:6],
        [_facts.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_facts.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
        [_note.topAnchor constraintEqualToAnchor:_facts.bottomAnchor constant:6],
        [_note.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_note.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [_summary.topAnchor constraintEqualToAnchor:_note.bottomAnchor constant:6],
        [_summary.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_summary.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [_summary.heightAnchor constraintGreaterThanOrEqualToConstant:34],  // room for a two-line message
        [_spotGrid.topAnchor constraintEqualToAnchor:_summary.bottomAnchor constant:6],
        [_spotGrid.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_spotGrid.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
        [_spotStatus.topAnchor constraintEqualToAnchor:_spotGrid.bottomAnchor constant:4],
        [_spotStatus.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_spotStatus.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        _logAfterGrid,
        [buttons.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [buttons.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [buttons.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-m],
    ]];
    return self;
}

- (NSWindow *)window {
    return _window;
}

- (BOOL)useCurrentTime {
    return _currentTime.state == NSControlStateValueOn;
}

- (NSInteger)indexOf:(const std::string &)name {
    for (size_t i = 0; i < _rows.size(); ++i)
        if (_rows[i].name == name) return (NSInteger)i;
    return -1;
}

- (NSTextField *)makeControlForRow:(const ADIFQsoRow &)row {
    NSTextField *control;
    if (row.suggest) {
        NSComboBox *c = [[NSComboBox alloc] initWithFrame:NSZeroRect];
        c.delegate = self;
        ADIFSuggestAsYouType(c, row.suggest);
        control = c;
    } else if (!row.choices.empty()) {
        NSComboBox *c = [[NSComboBox alloc] initWithFrame:NSZeroRect];
        c.completes = YES;
        c.numberOfVisibleItems = 14;
        for (const std::string &v : row.choices) [c addItemWithObjectValue:ADIFString(v)];
        c.delegate = self;
        control = c;
    } else {
        control = [NSTextField textFieldWithString:@""];
        control.delegate = self;
    }
    control.stringValue = ADIFString(row.value);
    control.placeholderString = row.required ? T(@"required") : @"";
    control.toolTip = ADIFString(row.description);
    control.font = [NSFont monospacedSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [control.widthAnchor constraintGreaterThanOrEqualToConstant:190].active = YES;
    return control;
}

- (void)setRows:(const std::vector<ADIFQsoRow> &)rows {
    _rows = rows;
    [_grid removeFromSuperview];
    [_controls removeAllObjects];
    [_status removeAllObjects];
    NSMutableArray<NSArray<NSView *> *> *cells = [NSMutableArray array];
    for (const ADIFQsoRow &row : rows) {
        NSTextField *label = [NSTextField labelWithString:ADIFString(row.name)];
        label.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
        label.alignment = NSTextAlignmentRight;
        label.toolTip = ADIFString(row.description);
        NSTextField *control = [self makeControlForRow:row];
        NSTextField *status = [NSTextField labelWithString:@""];
        status.font = theme::small();
        status.lineBreakMode = NSLineBreakByTruncatingTail;
        // Cut short (its tooltip has it all), never wider than the panel: the rows' problems take the room left.
        [status setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_controls addObject:control];
        [_status addObject:status];
        [cells addObject:@[ label, control, status ]];
    }
    _grid = [NSGridView gridViewWithViews:cells];
    _grid.translatesAutoresizingMaskIntoConstraints = NO;
    _grid.rowSpacing = 6;
    _grid.columnSpacing = 8;
    _grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    // The problems' column takes what is left of the width rather than a width of its own: at 150 it made
    // the panel 493 wide, past the Operating Console's 420 frame (its clocks and notes cut off at the edge).
    if (_grid.numberOfColumns == 3) [_grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [_document addSubview:_grid];
    [NSLayoutConstraint activateConstraints:@[
        [_grid.topAnchor constraintEqualToAnchor:_document.topAnchor constant:4],
        [_grid.leadingAnchor constraintEqualToAnchor:_document.leadingAnchor],
        [_grid.trailingAnchor constraintEqualToAnchor:_document.trailingAnchor],
        [_grid.bottomAnchor constraintEqualToAnchor:_document.bottomAnchor constant:-4],
    ]];
    _scrollHeight.constant = MIN(520.0, 30.0 * rows.size() + 8);
    [self updateTimeEditability];
    // Fit the window to the rows (keeping any width the user gave it).
    NSView *root = _window.contentView;
    [root layoutSubtreeIfNeeded];
    NSSize fit = root.fittingSize;
    [_window setContentSize:NSMakeSize(MAX(NSWidth(root.frame), fit.width), fit.height)];
}

- (std::vector<std::pair<std::string, std::string>>)values {
    std::vector<std::pair<std::string, std::string>> out;
    for (size_t i = 0; i < _rows.size(); ++i)
        out.emplace_back(_rows[i].name, _controls[i].stringValue.UTF8String ?: "");
    return out;
}

- (std::string)valueForField:(const std::string &)name {
    NSInteger i = [self indexOf:name];
    return i < 0 ? std::string() : std::string(_controls[(NSUInteger)i].stringValue.UTF8String ?: "");
}

- (void)setValue:(const std::string &)value forField:(const std::string &)name {
    NSInteger i = [self indexOf:name];
    if (i >= 0) _controls[(NSUInteger)i].stringValue = ADIFString(value);
}

- (void)setChoices:(const std::vector<std::string> &)choices forField:(const std::string &)name {
    NSInteger i = [self indexOf:name];
    if (i < 0 || ![_controls[(NSUInteger)i] isKindOfClass:NSComboBox.class]) return;
    NSComboBox *c = (NSComboBox *)_controls[(NSUInteger)i];
    NSString *keep = c.stringValue;
    [c removeAllItems];
    for (const std::string &v : choices) [c addItemWithObjectValue:ADIFString(v)];
    c.stringValue = keep;
}

- (void)setRowStatus:(const std::vector<std::pair<int, std::string>> &)status {
    for (size_t i = 0; i < _status.count && i < status.size(); ++i) {
        _status[i].stringValue = ADIFString(status[i].second);
        _status[i].toolTip = ADIFString(status[i].second);
        _status[i].textColor = severityColor(status[i].first);
    }
}

- (void)setSummary:(const std::string &)text severity:(int)severity {
    _summary.stringValue = ADIFString(tr(text));  // a fixed text in the user's language
    _summary.textColor = severityColor(severity);
}

- (BOOL)spotCluster {
    return _spotCluster.state == NSControlStateValueOn;
}

- (void)setSpotCluster:(BOOL)on {
    _spotCluster.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (BOOL)spotPota {
    return _spotPota.state == NSControlStateValueOn;
}

- (void)setSpotPota:(BOOL)on {
    _spotPota.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)spotChanged:(id)sender {
    if (self.onSpotChanged) self.onSpotChanged();
}

- (void)setSpotReady:(BOOL)cluster clusterTip:(NSString *)clusterTip pota:(BOOL)pota potaTip:(NSString *)potaTip {
    _spotCluster.enabled = cluster;
    _spotCluster.toolTip = clusterTip;
    _spotPota.enabled = pota;
    _spotPota.toolTip = potaTip;
}

- (BOOL)spotClusterReady {
    return _spotCluster.enabled;
}

- (BOOL)spotPotaReady {
    return _spotPota.enabled;
}

- (void)setSpotStatus:(NSString *)text {
    _spotStatus.stringValue = text ?: @"";
    _spotStatus.toolTip = text;
    _spotStatus.hidden = _spotStatus.stringValue.length == 0;
    _logAfterGrid.active = _spotStatus.hidden;
    _logAfterStatus.active = !_spotStatus.hidden;
}

- (void)setStationSummary:(NSString *)text {
    _stationSummary.stringValue = text ?: @"";
    _stationSummary.toolTip = text.length ? text : nil;
}

- (void)setNote:(NSString *)note {
    _note.stringValue = note ?: @"";
}

- (void)fieldsPressed:(id)sender {
    if (self.onCustomize) self.onCustomize();
}

- (void)spotsPressed:(id)sender {
    if (self.onSpots) self.onSpots();
}

- (void)contestPressed:(id)sender {
    if (self.onContest) self.onContest();
}

- (void)lookupChanged:(id)sender {
    if (self.onLookupChanged) self.onLookupChanged(self.lookupSource);
}

- (NSInteger)lookupSource {
    return _lookup.indexOfSelectedItem;
}

- (void)setLookupSource:(NSInteger)source {
    [_lookup selectItemAtIndex:source >= 0 && source < 4 ? source : 0];
}

- (void)setLookupFacts:(NSArray<NSArray<NSString *> *> *)facts message:(NSString *)message severity:(int)severity {
    for (NSView *v in [_facts.subviews copy]) [v removeFromSuperview];  // a row removed keeps its views
    while (_facts.numberOfRows > 0) [_facts removeRowAtIndex:0];
    auto label = [](NSString *text, NSColor *colour) {
        NSTextField *t = [NSTextField labelWithString:text ?: @""];
        t.font = theme::small();
        t.textColor = colour;
        t.lineBreakMode = NSLineBreakByTruncatingTail;
        return t;
    };
    _hasFacts = facts.count > 0;
    [self showDetailsLink];
    if (message.length) {
        NSTextField *note = label(message, severityColor(severity));
        note.toolTip = message;
        note.identifier = @"qso.fact.message";
        [note setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_facts addRowWithViews:@[ [NSGridCell emptyContentView], note ]];
    }
}

- (void)showDetailsLink {
    _detailsLink.hidden = !_hasFacts || workspace::qsoDetailsShown();
}

- (void)showDetails:(id)sender {
    panels::setShown(adif::layout::kQsoDetails, true);
}

- (BOOL)hasField:(const std::string &)name {
    return [self indexOf:name] >= 0;
}

- (void)appendText:(const std::string &)text toField:(const std::string &)name {
    NSInteger i = [self indexOf:name];
    if (i < 0) return;
    NSTextField *f = _controls[(NSUInteger)i];
    NSString *now = [f.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    f.stringValue = now.length ? [NSString stringWithFormat:@"%@; %@", now, ADIFString(text)] : ADIFString(text);
    [_window makeFirstResponder:f];
    if (NSText *editor = [_window fieldEditor:NO forObject:f]) editor.selectedRange = NSMakeRange(f.stringValue.length, 0);  // the caret after it, to finish
    if (self.onChange) self.onChange();
}

- (void)setStations:(NSArray<NSString *> *)names selected:(NSInteger)index {
    [_station removeAllItems];
    [_station addItemWithTitle:T(@"From the log")];
    for (NSString *n in names) [_station addItemWithTitle:n];
    [_station.menu addItem:[NSMenuItem separatorItem]];
    [_station addItemWithTitle:T(@"Edit Profiles...")];
    [_station selectItemAtIndex:index >= 0 && index <= (NSInteger)names.count ? index : 0];
}

- (void)stationChanged:(NSPopUpButton *)sender {
    NSInteger i = sender.indexOfSelectedItem;
    BOOL edit = i == sender.numberOfItems - 1;
    if (self.onStationChosen) self.onStationChosen(edit ? -1 : i);
}

- (void)setTarget:(const std::string &)documentName {
    _target.stringValue = [T(@"Logging to: ") stringByAppendingString:ADIFString(documentName)];
}

// ── Time ────────────────────────────────────────────────────────────────────

- (void)refreshTime {
    std::time_t now = std::time(nullptr);
    std::tm utc{};
    gmtime_r(&now, &utc);
    char date[16], tod[16];
    std::strftime(date, sizeof date, "%Y%m%d", &utc);
    std::strftime(tod, sizeof tod, _timeDigits == 4 ? "%H%M" : "%H%M%S", &utc);
    [self setValue:date forField:"QSO_DATE"];
    [self setValue:tod forField:"TIME_ON"];
}

- (void)updateTimeEditability {
    BOOL editable = !self.useCurrentTime;
    for (const char *name : {"QSO_DATE", "TIME_ON"}) {
        NSInteger i = [self indexOf:name];
        if (i >= 0) {
            _controls[(NSUInteger)i].editable = editable;
            _controls[(NSUInteger)i].enabled = editable;
        }
    }
    [_timer invalidate];
    _timer = nil;
    if (!editable) {
        [self refreshTime];
        _timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}

- (void)tick:(NSTimer *)timer {
    if (!_window.visible) return;
    [self refreshTime];
}

- (void)currentTimeChanged:(id)sender {
    [self updateTimeEditability];
    if (self.onChange) self.onChange();
}

// ── Editing ─────────────────────────────────────────────────────────────────

- (void)controlTextDidChange:(NSNotification *)notification {
    if (self.onChange) self.onChange();
}

- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    // The combo box's string updates after this notification.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onChange) self.onChange();
    });
}

- (void)focusField:(const std::string &)name {
    NSInteger i = [self indexOf:name];
    if (i >= 0) [_window makeFirstResponder:_controls[(NSUInteger)i]];
}

- (void)show {
    [self updateTimeEditability];
    [_window makeKeyAndOrderFront:nil];
}

- (void)logPressed:(id)sender {
    [_window makeFirstResponder:nil];  // commit the field being edited
    if (self.useCurrentTime) [self refreshTime];
    if (self.onLog) self.onLog();
}

- (void)closePressed:(id)sender {
    [_window performClose:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    [_timer invalidate];
    _timer = nil;
}

@end
