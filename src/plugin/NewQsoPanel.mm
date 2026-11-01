#import "NewQsoPanel.h"
#import "Night.h"
#import "L10n.h"
#import "ToolWindow.h"
#import "Workspace.h"

#include <algorithm>
#include <cmath>
#include <ctime>

// Problems in their colour; plain text dimmed.
static NSColor *severityColor(int severity) { return severity < 0 ? NSColor.secondaryLabelColor : ADIFSeverityColor(severity); }

// A scroll view's document view must be flipped for content to start at the top.
@interface ADIFFlippedView : NSView
@end
@implementation ADIFFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

// Digits as an LED display draws them: seven segments each, slanted a little, the lit ones glowing
// and the unlit ones faintly there; ':' as two dots. Drawn, so no font has to be installed.
@interface ADIFSegmentDisplay : NSView
@property(nonatomic, copy) NSString *text;  // digits, ':' and '-'
@property(nonatomic, strong) NSColor *lit;
- (instancetype)initWithDigitHeight:(CGFloat)height;
@end

@implementation ADIFSegmentDisplay {
    CGFloat _h;
}

- (instancetype)initWithDigitHeight:(CGFloat)height {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _h = height;
    _text = @"--:--:--";
    _lit = NSColor.labelColor;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.accessibilityElement = NO;  // the clock speaks for it
    return self;
}

- (CGFloat)digitWidth { return std::round(_h * 0.56); }
- (CGFloat)thickness { return std::max<CGFloat>(2, std::round(_h * 0.13)); }
- (CGFloat)gap { return std::round(_h * 0.16); }
- (CGFloat)colonWidth { return std::round(_h * 0.28); }
- (CGFloat)slant { return 0.1; }  // x moves right by this much of y: the italic of an LED display

- (NSSize)intrinsicContentSize {
    CGFloat w = 0;
    for (NSUInteger i = 0; i < _text.length; ++i) w += ([_text characterAtIndex:i] == ':' ? self.colonWidth : self.digitWidth) + (i ? self.gap : 0);
    return NSMakeSize(std::ceil(w + _h * self.slant + 4), std::ceil(_h + 4));  // room for the slant and the glow
}

- (void)setText:(NSString *)text {
    BOOL resize = text.length != _text.length;
    _text = [text copy];
    if (resize) [self invalidateIntrinsicContentSize];
    self.needsDisplay = YES;
}

- (void)setLit:(NSColor *)lit {
    _lit = lit;
    self.needsDisplay = YES;
}

// A segment from (x0, y0) to (x1, y1), horizontal or vertical, pointed at both ends.
static NSBezierPath *segment(CGFloat x0, CGFloat y0, CGFloat x1, CGFloat y1, CGFloat t) {
    NSBezierPath *p = [NSBezierPath bezierPath];
    CGFloat h = t / 2;
    if (y0 == y1) {
        [p moveToPoint:NSMakePoint(x0, y0)];
        [p lineToPoint:NSMakePoint(x0 + h, y0 + h)];
        [p lineToPoint:NSMakePoint(x1 - h, y0 + h)];
        [p lineToPoint:NSMakePoint(x1, y0)];
        [p lineToPoint:NSMakePoint(x1 - h, y0 - h)];
        [p lineToPoint:NSMakePoint(x0 + h, y0 - h)];
    } else {
        [p moveToPoint:NSMakePoint(x0, y0)];
        [p lineToPoint:NSMakePoint(x0 + h, y0 + h)];
        [p lineToPoint:NSMakePoint(x0 + h, y1 - h)];
        [p lineToPoint:NSMakePoint(x0, y1)];
        [p lineToPoint:NSMakePoint(x0 - h, y1 - h)];
        [p lineToPoint:NSMakePoint(x0 - h, y0 + h)];
    }
    [p closePath];
    return p;
}

- (void)drawRect:(NSRect)dirty {
    // Segments a (top) b (upper right) c (lower right) d (bottom) e (lower left) f (upper left) g (middle).
    static const unsigned char kDigits[10] = {0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F};
    const CGFloat w = self.digitWidth, h = _h, t = self.thickness, s = std::max<CGFloat>(0.75, t * 0.12);
    NSColor *off = [_lit colorWithAlphaComponent:0.09];
    NSShadow *glow = [[NSShadow alloc] init];
    glow.shadowColor = [_lit colorWithAlphaComponent:0.7];
    glow.shadowBlurRadius = std::max<CGFloat>(2, h * 0.12);
    glow.shadowOffset = NSZeroSize;
    NSAffineTransform *lean = [NSAffineTransform transform];
    NSAffineTransformStruct m = {1, 0, self.slant, 1, 2, 2};  // x += slant * y, inside a 2 pt margin
    lean.transformStruct = m;
    CGFloat x = 0;
    for (NSUInteger i = 0; i < _text.length; ++i) {
        unichar c = [_text characterAtIndex:i];
        if (i) x += self.gap;
        if (c == ':') {
            CGFloat cw = self.colonWidth, d = t;
            [NSGraphicsContext saveGraphicsState];
            [glow set];
            [_lit setFill];
            for (CGFloat cy : {h * 0.3, h * 0.7}) {
                NSBezierPath *dot = [NSBezierPath bezierPathWithRect:NSMakeRect(x + (cw - d) / 2, cy - d / 2, d, d)];
                [dot transformUsingAffineTransform:lean];
                [dot fill];
            }
            [NSGraphicsContext restoreGraphicsState];
            x += cw;
            continue;
        }
        unsigned mask = c >= '0' && c <= '9' ? kDigits[c - '0'] : c == '-' ? 0x40 : 0;
        const CGFloat l = x + t / 2, r = x + w - t / 2, top = h - t / 2, mid = h / 2, bottom = t / 2;
        NSBezierPath *segs[7] = {
            segment(l + s, top, r - s, top, t),     segment(r, mid + s, r, top - s, t),    segment(r, bottom + s, r, mid - s, t),
            segment(l + s, bottom, r - s, bottom, t), segment(l, bottom + s, l, mid - s, t), segment(l, mid + s, l, top - s, t),
            segment(l + s, mid, r - s, mid, t),
        };
        for (int k = 0; k < 7; ++k) {
            [segs[k] transformUsingAffineTransform:lean];
            BOOL on = (mask >> k) & 1;
            [NSGraphicsContext saveGraphicsState];
            if (on) [glow set];
            [(on ? _lit : off) setFill];
            [segs[k] fill];
            [NSGraphicsContext restoreGraphicsState];
        }
        x += w;
    }
}
@end

// A clock at the top of New QSO, as an operating position's status display: a dark block with a
// status light, its name, the time in large digits and the date. UTC is the log's time (green);
// local time is the operator's own (amber). Each ticks on the second while it is in a window.
@interface ADIFStatusClock : NSView
- (instancetype)initUtc:(BOOL)utc;
@end

@implementation ADIFStatusClock {
    BOOL _utc;
    NSTextField *_name, *_date;
    ADIFSegmentDisplay *_time;
    NSTimer *_timer;
}

static NSColor *rgb(int hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:1];
}

- (instancetype)initUtc:(BOOL)utc {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _utc = utc;
    // Fixed colours, light or dark: a status display looks the same either way (Night Mode tints it red).
    NSColor *lit = rgb(utc ? 0x4BE07A : 0xFFB938), *dim = rgb(utc ? 0x2E7D46 : 0x8A6418);
    self.wantsLayer = YES;
    self.layer.cornerRadius = 6;
    self.layer.borderWidth = 1;
    self.layer.borderColor = dim.CGColor;
    self.layer.backgroundColor = rgb(utc ? 0x0C1D12 : 0x221807).CGColor;
    self.identifier = utc ? @"newqso.clock.utc" : @"newqso.clock.local";
    self.toolTip = utc ? T(@"UTC: the time QSOs are logged in") : T(@"Your local time (this Mac's time zone)");

    NSView *light = [[NSView alloc] initWithFrame:NSZeroRect];
    light.wantsLayer = YES;
    light.layer.cornerRadius = 3.5;
    light.layer.backgroundColor = lit.CGColor;
    light.layer.shadowColor = lit.CGColor;  // a glow, as a lamp
    light.layer.shadowOpacity = 0.8;
    light.layer.shadowRadius = 3;
    light.layer.shadowOffset = CGSizeZero;
    [light.widthAnchor constraintEqualToConstant:7].active = YES;
    [light.heightAnchor constraintEqualToConstant:7].active = YES;
    _name = [NSTextField labelWithString:@""];
    _name.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightSemibold];
    _name.textColor = [dim highlightWithLevel:0.25] ?: dim;
    _time = [[ADIFSegmentDisplay alloc] initWithDigitHeight:26];
    _time.lit = lit;
    _date = [NSTextField labelWithString:@""];
    _date.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _date.textColor = _name.textColor;
    NSStackView *top = [NSStackView stackViewWithViews:@[ light, _name ]];
    top.spacing = 6;
    NSStackView *column = [NSStackView stackViewWithViews:@[ top, _time, _date ]];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeLeading;
    column.spacing = 1;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:column];
    // The reading centred in the block, with the same room on every side.
    [NSLayoutConstraint activateConstraints:@[
        [column.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [column.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:12],
        [column.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [column.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
    ]];
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityStaticTextRole;
    [self tick];
    return self;
}

- (void)tick {
    NSDate *now = [NSDate date];
    NSTimeZone *zone = _utc ? [NSTimeZone timeZoneWithAbbreviation:@"UTC"] : NSTimeZone.localTimeZone;
    static NSDateFormatter *time, *date;
    if (!time) {
        time = [[NSDateFormatter alloc] init], date = [[NSDateFormatter alloc] init];
        time.locale = date.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        time.dateFormat = @"HH:mm:ss", date.dateFormat = @"yyyy-MM-dd EEE";
    }
    time.timeZone = date.timeZone = zone;
    _time.text = [time stringFromDate:now];
    _date.stringValue = [date stringFromDate:now];
    _name.stringValue = _utc ? T(@"UTC · LOG TIME") : [T(@"LOCAL · ") stringByAppendingString:[zone abbreviationForDate:now] ?: zone.name];
    self.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", _name.stringValue, _time.text];
}

// On the second, while it is shown; and in every run loop mode, so it keeps time while a menu is open.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [_timer invalidate];
    _timer = nil;
    if (!self.window) return;
    [self tick];
    __weak ADIFStatusClock *weakSelf = self;
    double wait = 1 - fmod(NSDate.date.timeIntervalSince1970, 1);
    _timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *) { [weakSelf tick]; }];
    _timer.fireDate = [NSDate dateWithTimeIntervalSinceNow:wait + 0.01];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
@end

@implementation ADIFNewQsoPanel {
    NSWindow *_window;
    NSTextField *_target, *_summary, *_note;
    NSStackView *_clocks;
    NSScrollView *_scroll;
    ADIFFlippedView *_document;
    NSGridView *_grid;
    NSLayoutConstraint *_scrollHeight;
    NSButton *_currentTime, *_log, *_close, *_fields, *_spots, *_contest;
    NSButton *_spotCluster, *_spotPota;
    NSTextField *_spotStatus;
    NSGridView *_spotGrid;
    NSLayoutConstraint *_logAfterGrid, *_logAfterStatus;  // one is active: the status line shown or not
    NSGridView *_facts;  // what the lookup says, a fact a row
    NSStackView *_aids;  // Operating Aids: its title, its facts and suggestions
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
    _window.title = T(@"New QSO");
    ADIFNightTrack(_window);
    _window.releasedWhenClosed = NO;
    _window.tabbingMode = NSWindowTabbingModeDisallowed;
    _window.delegate = self;
    _window.autorecalculatesKeyViewLoop = YES;
    _window.contentMinSize = NSMakeSize(420, 260);
    [_window center];
    NSView *root = _window.contentView;

    _target = [NSTextField labelWithString:@""];
    _target.textColor = NSColor.secondaryLabelColor;
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
    _note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _note.textColor = NSColor.secondaryLabelColor;
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
    _stationSummary.textColor = NSColor.secondaryLabelColor;
    _stationSummary.lineBreakMode = NSLineBreakByTruncatingTail;
    _stationSummary.identifier = @"qso.station.summary";
    // Cut short (its tooltip has it all) before it widens the panel: below a docked frame's fit (Workspace.mm).
    [_stationSummary setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _station.identifier = @"qso.station";
    _stationRow = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:T(@"Station:")], _station, _stationSummary ]];
    _stationRow.spacing = 8;
    _stationRow.alignment = NSLayoutAttributeCenterY;
    _stationRow.translatesAutoresizingMaskIntoConstraints = NO;
    _lookupRow = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:T(@"Look up:")], _lookup ]];
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
    _spotStatus.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _spotStatus.textColor = NSColor.secondaryLabelColor;
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
    _clocks = [NSStackView stackViewWithViews:@[ [[ADIFStatusClock alloc] initUtc:YES], [[ADIFStatusClock alloc] initUtc:NO] ]];
    _clocks.distribution = NSStackViewDistributionFillEqually;
    _clocks.spacing = 10;
    _clocks.identifier = @"newqso.clocks";
    _clocks.translatesAutoresizingMaskIntoConstraints = NO;
    _aids = [[NSStackView alloc] initWithFrame:NSZeroRect];
    _aids.orientation = NSUserInterfaceLayoutOrientationVertical;
    _aids.alignment = NSLayoutAttributeLeading;
    _aids.spacing = 3;
    _aids.identifier = @"newqso.aids";
    _aids.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[ _clocks, _target, _stationRow, _scroll, _currentTime, _lookupRow, _facts, _aids, _note, _summary, _spotGrid, _spotStatus, buttons ])
        [root addSubview:v];
    const CGFloat m = kADIFMargin;
    _logAfterGrid = [buttons.topAnchor constraintEqualToAnchor:_spotGrid.bottomAnchor constant:8];
    _logAfterStatus = [buttons.topAnchor constraintEqualToAnchor:_spotStatus.bottomAnchor constant:8];
    // The lookup's facts and the aids no taller than their rows (with none, nothing): the window's
    // spare height goes to the message under the notes, not to an empty grid.
    for (NSView *v in @[ _facts, _aids ]) {
        NSLayoutConstraint *tight = [v.heightAnchor constraintEqualToConstant:0];
        tight.priority = NSLayoutPriorityDefaultLow + 1;
        tight.active = YES;
    }
    _scrollHeight = [_scroll.heightAnchor constraintEqualToConstant:300];
    _scrollHeight.priority = NSLayoutPriorityDefaultHigh - 1;
    [NSLayoutConstraint activateConstraints:@[
        [_clocks.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
        [_clocks.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_clocks.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [_target.topAnchor constraintEqualToAnchor:_clocks.bottomAnchor constant:12],
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
        [_aids.topAnchor constraintEqualToAnchor:_facts.bottomAnchor constant:6],
        [_aids.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_aids.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [_note.topAnchor constraintEqualToAnchor:_aids.bottomAnchor constant:6],
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
        status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
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
        t.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        t.textColor = colour;
        t.lineBreakMode = NSLineBreakByTruncatingTail;
        return t;
    };
    NSUInteger i = 0;
    for (NSArray<NSString *> *f in facts) {
        NSTextField *name = label(f[0], NSColor.secondaryLabelColor), *value = label(f.count > 1 ? f[1] : @"", NSColor.labelColor);
        value.selectable = YES;
        [value setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];  // cut short, not wider
        value.toolTip = f.count > 2 && f[2].length ? [NSString stringWithFormat:@"%@\n%@", value.stringValue, f[2]] : value.stringValue;
        value.identifier = [NSString stringWithFormat:@"qso.fact.%lu", (unsigned long)i++];
        [value setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_facts addRowWithViews:@[ name, value ]];
    }
    if (message.length) {
        NSTextField *note = label(message, severityColor(severity));
        note.toolTip = message;
        note.identifier = @"qso.fact.message";
        [note setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_facts addRowWithViews:@[ [NSGridCell emptyContentView], note ]];
    }
}

- (BOOL)hasField:(const std::string &)name {
    return [self indexOf:name] >= 0;
}

// Operating Aids: suggestions in italics after a speech bubble, each with its buttons; facts plain,
// coloured as they matter. Each line wraps at the panel's width.
- (void)setAidsTitle:(NSString *)title rows:(const std::vector<ADIFAidRow> &)rows menu:(NSMenu *)menu hidden:(BOOL)hidden {
    for (NSView *v in [_aids.arrangedSubviews copy]) [_aids removeView:v];
    if (!title) return;
    NSFont *small = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    auto symbolView = [](NSString *name, NSColor *tint) {
        NSImageView *i = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] ?: [[NSImage alloc] init]];
        i.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        i.contentTintColor = tint;
        [i setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [i setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        return i;
    };
    auto link = [&](NSString *name, NSString *ident, NSString *tip, NSInteger row) {  // its action is in its identifier

        NSButton *b = [NSButton buttonWithTitle:name target:self action:@selector(aidPressed:)];
        b.bordered = NO;
        b.font = small;
        b.contentTintColor = NSColor.linkColor;
        b.identifier = ident;
        b.toolTip = tip;
        b.tag = row;
        [b setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [b setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        return b;
    };
    // The title: what it is and for which style, its menu, Hide or Show.
    NSTextField *head = [NSTextField labelWithString:title];
    head.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold];
    head.textColor = NSColor.secondaryLabelColor;
    head.lineBreakMode = NSLineBreakByTruncatingTail;
    head.identifier = @"newqso.aids.title";
    [head setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSMutableArray<NSView *> *top = [NSMutableArray arrayWithObjects:symbolView(@"text.bubble", NSColor.secondaryLabelColor), head, nil];
    if (menu && !hidden) {
        NSPopUpButton *m = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
        m.bordered = NO;
        m.controlSize = NSControlSizeSmall;
        m.font = small;
        NSMenuItem *face = [[NSMenuItem alloc] initWithTitle:T(@"Options") action:nil keyEquivalent:@""];
        [menu insertItem:face atIndex:0];  // a pull-down's title
        m.menu = menu;
        m.identifier = @"newqso.aids.menu";
        m.toolTip = T(@"Operating Aids: how many suggestions, when they change, which topics, and the prompts you dismissed");
        m.accessibilityLabel = T(@"Operating Aids options");
        [m setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [top addObject:m];
    }
    [top addObject:hidden ? link(T(@"Show"), @"newqso.aids.show", T(@"Show Operating Aids again"), -1)
                          : link(T(@"Hide"), @"newqso.aids.hide", T(@"Hide Operating Aids until ADIF Lint starts again (Options turns them off for good)"), -1)];
    NSStackView *topRow = [NSStackView stackViewWithViews:top];
    topRow.spacing = 6;
    topRow.alignment = NSLayoutAttributeCenterY;
    [_aids addArrangedSubview:topRow];
    [topRow.widthAnchor constraintEqualToAnchor:_aids.widthAnchor].active = YES;
    if (hidden) return;
    NSInteger i = 0;
    for (const ADIFAidRow &r : rows) {
        NSTextField *t = ADIFWrappingLabel();
        t.stringValue = ADIFString(r.text);
        t.font = r.suggestion ? [[NSFontManager sharedFontManager] convertFont:small toHaveTrait:NSItalicFontMask] : small;
        t.textColor = r.suggestion ? NSColor.secondaryLabelColor : r.severity == 2 ? NSColor.systemRedColor : r.severity == 1 ? NSColor.systemOrangeColor : NSColor.labelColor;
        t.maximumNumberOfLines = 3;
        t.toolTip = r.why.empty() ? nil : ADIFString(r.why);
        t.identifier = [NSString stringWithFormat:@"newqso.aids.row.%ld", (long)i];
        t.accessibilityLabel = r.suggestion ? TF(@"Suggestion: {text}", @{@"text" : t.stringValue}) : nil;
        [t setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [t setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSColor *tint = r.suggestion ? NSColor.secondaryLabelColor
                                     : r.severity == 2 ? NSColor.systemRedColor : r.severity == 1 ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
        NSMutableArray<NSView *> *parts = [NSMutableArray arrayWithObjects:symbolView(r.symbol ?: (r.suggestion ? @"bubble.left" : @"circle.fill"), tint), t, nil];
        if (r.suggestion) {
            if (r.note)
                [parts addObject:link(T(@"Note"), [NSString stringWithFormat:@"newqso.aids.note.%ld", (long)i],
                                      T(@"Start a note on this topic in NOTES, for you to finish (nothing is sent anywhere)"), i)];
            [parts addObject:link(T(@"Skip"), [NSString stringWithFormat:@"newqso.aids.skip.%ld", (long)i], T(@"Another suggestion in its place"), i)];
            [parts addObject:link(T(@"Dismiss"), [NSString stringWithFormat:@"newqso.aids.dismiss.%ld", (long)i],
                                  T(@"Don't suggest this again (Options brings dismissed suggestions back)"), i)];
        }
        NSStackView *line = [NSStackView stackViewWithViews:parts];
        line.spacing = 6;
        line.alignment = NSLayoutAttributeFirstBaseline;
        [_aids addArrangedSubview:line];
        [line.widthAnchor constraintEqualToAnchor:_aids.widthAnchor].active = YES;
        ++i;
    }
}

- (void)aidPressed:(NSButton *)sender {
    NSArray<NSString *> *parts = [sender.identifier componentsSeparatedByString:@"."];  // newqso.aids.<action>[.<row>]
    if (self.onAid && parts.count >= 3) self.onAid(parts[2], sender.tag);
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
