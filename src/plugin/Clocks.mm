// The Clocks panel: see Clocks.h.
#import "Clocks.h"

#import "L10n.h"
#import "Night.h"
#import "PluginHost.h"
#import "Theme.h"
#import "ToolWindow.h"
#import "Workspace.h"

#include <algorithm>
#include <cmath>
#include <map>

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

// A clock as an operating position's status display: a dark block with a status light, its name,
// the time in large digits and the date. UTC is the log's time (green); local time is the
// operator's own (amber); a city's is blue. Each ticks on the second while it is in a window.
@interface ADIFStatusClock : NSView
- (instancetype)initWithZone:(const std::string &)zone;  // "UTC", "local" or an IANA name
@end

namespace {

NSColor *rgb(int hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:1];
}

NSTimeZone *zoneOf(const std::string &id) {
    if (id == "UTC") return [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    if (id == "local") return NSTimeZone.localTimeZone;
    return [NSTimeZone timeZoneWithName:ADIFString(id)];
}

// "America/Los_Angeles": "Los Angeles"; "America/Argentina/Buenos_Aires": "Buenos Aires".
NSString *cityOf(const std::string &id) {
    NSString *last = [ADIFString(id) componentsSeparatedByString:@"/"].lastObject ?: @"";
    return [last stringByReplacingOccurrencesOfString:@"_" withString:@" "];
}

}  // namespace

@implementation ADIFStatusClock {
    std::string _zone;
    NSTextField *_name, *_date;
    ADIFSegmentDisplay *_time;
    NSTimer *_timer;
}

- (instancetype)initWithZone:(const std::string &)zone {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _zone = zone;
    bool utc = zone == "UTC", local = zone == "local";
    // Fixed colours, light or dark: a status display looks the same either way (Night Mode tints it red).
    NSColor *lit = rgb(utc ? 0x4BE07A : local ? 0xFFB938 : 0x5CC8F5), *dim = rgb(utc ? 0x2E7D46 : local ? 0x8A6418 : 0x2B6A85);
    self.wantsLayer = YES;
    self.layer.cornerRadius = 6;
    self.layer.borderWidth = 1;
    self.layer.borderColor = dim.CGColor;
    self.layer.backgroundColor = rgb(utc ? 0x0C1D12 : local ? 0x221807 : 0x061820).CGColor;
    self.identifier = utc ? @"clock.utc" : local ? @"clock.local" : [@"clock." stringByAppendingString:ADIFString(zone)];
    self.toolTip = utc ? T(@"UTC: the time QSOs are logged in")
                   : local ? T(@"Your local time (this Mac's time zone)")
                           : TF(@"The time in {city} ({zone})", @{@"city" : cityOf(zone), @"zone" : ADIFString(zone)});

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
    _name.lineBreakMode = NSLineBreakByTruncatingTail;
    _time = [[ADIFSegmentDisplay alloc] initWithDigitHeight:26];
    _time.lit = lit;
    _date = [NSTextField labelWithString:@""];
    _date.font = theme::digits(11, NSFontWeightRegular);
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
    NSTimeZone *zone = zoneOf(_zone) ?: NSTimeZone.localTimeZone;
    static NSDateFormatter *time, *date;
    if (!time) {
        time = [[NSDateFormatter alloc] init], date = [[NSDateFormatter alloc] init];
        time.locale = date.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        time.dateFormat = @"HH:mm:ss", date.dateFormat = @"yyyy-MM-dd EEE";
    }
    time.timeZone = date.timeZone = zone;
    _time.text = [time stringFromDate:now];
    _date.stringValue = [date stringFromDate:now];
    NSString *abbreviation = [zone abbreviationForDate:now] ?: zone.name;
    _name.stringValue = _zone == "UTC"     ? T(@"UTC · LOG TIME")
                        : _zone == "local" ? [T(@"LOCAL · ") stringByAppendingString:abbreviation]
                                           : [NSString stringWithFormat:@"%@ · %@", cityOf(_zone).uppercaseString, abbreviation];
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

// The clocks in rows, as many to a row as fit at their least width, each row's sharing its width.
@interface ADIFClockShelf : NSView
@end
static const CGFloat kGap = 10, kLeast = 200;  // between clocks; a clock's least width
@implementation ADIFClockShelf
- (BOOL)isFlipped {
    return YES;
}
- (CGFloat)rowsHeightFor:(CGFloat)width {
    NSUInteger n = self.subviews.count, across = [self acrossFor:width];
    CGFloat tile = [self tileHeight];
    NSUInteger rows = (n + across - 1) / std::max<NSUInteger>(across, 1);
    return rows ? rows * tile + (rows - 1) * kGap : 0;
}
- (NSUInteger)acrossFor:(CGFloat)width {
    return std::max<NSUInteger>(1, std::min<NSUInteger>(self.subviews.count, (NSUInteger)((width + kGap) / (kLeast + kGap))));
}
- (CGFloat)tileHeight {
    return self.subviews.count ? std::ceil(self.subviews.firstObject.fittingSize.height) : 0;
}
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, [self rowsHeightFor:NSWidth(self.bounds)]);
}
- (void)layout {
    [super layout];
    CGFloat w = NSWidth(self.bounds), tile = [self tileHeight];
    NSUInteger across = [self acrossFor:w];
    CGFloat each = std::floor((w - kGap * (across - 1)) / across);
    NSUInteger i = 0;
    for (NSView *v in self.subviews) {
        NSUInteger r = i / across, c = i % across;
        v.frame = NSMakeRect(c * (each + kGap), r * (tile + kGap), each, tile);
        ++i;
    }
    [self invalidateIntrinsicContentSize];
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self invalidateIntrinsicContentSize];
}
@end

// ── The panel ──

namespace {

struct {
    ADIFDockPanel *window;
    ADIFClockShelf *shelf;
    NSPopUpButton *add;
} gClocks;

const char *const kZonesKey = "clockZones";

std::vector<std::string> savedZones() {
    std::vector<std::string> out;
    std::string v = adifhost::setting(kZonesKey);
    if (v.empty()) v = "UTC,local";  // as New QSO had them
    size_t start = 0;
    while (start <= v.size()) {
        size_t comma = v.find(',', start);
        std::string z = v.substr(start, comma == std::string::npos ? std::string::npos : comma - start);
        if (!z.empty() && zoneOf(z) && std::find(out.begin(), out.end(), z) == out.end()) out.push_back(z);
        if (comma == std::string::npos) break;
        start = comma + 1;
    }
    if (out.empty()) out = {"UTC", "local"};
    return out;
}

void fill();

void saveZones(const std::vector<std::string> &zones) {
    std::string v;
    for (const std::string &z : zones) v += (v.empty() ? "" : ",") + z;
    adifhost::setSetting(kZonesKey, v);
    fill();
}

// A clock's own menu: moved along the row, or removed (the last one stays).
NSMenu *clockMenu(const std::string &zone) {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    std::vector<std::string> zones = savedZones();
    size_t at = (size_t)(std::find(zones.begin(), zones.end(), zone) - zones.begin());
    auto move = [&](NSString *title, int by) {
        NSMenuItem *mi = [menu addItemWithTitle:T(title) action:nil keyEquivalent:@""];
        size_t to = at + by;
        mi.enabled = at < zones.size() && to < zones.size();
        ADIFBlockMenuItem(mi, ^{
            std::vector<std::string> now = savedZones();
            if (at < now.size() && to < now.size()) std::swap(now[at], now[to]);
            saveZones(now);
        });
    };
    move(N(@"Move Left"), -1);
    move(N(@"Move Right"), 1);
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *remove = [menu addItemWithTitle:T(@"Remove This Clock") action:nil keyEquivalent:@""];
    remove.enabled = zones.size() > 1;
    std::string z = zone;
    ADIFBlockMenuItem(remove, ^{
        std::vector<std::string> now = savedZones();
        now.erase(std::remove(now.begin(), now.end(), z), now.end());
        saveZones(now);
    });
    menu.autoenablesItems = NO;
    return menu;
}

// Add Clock: UTC and local time, the cities operators often keep (the US's zones, Europe's,
// Japan's, Australia's), then every time zone by region. Those shown already are ticked, not added again.
void fillAddMenu() {
    NSMenu *menu = gClocks.add.menu;
    while (menu.numberOfItems > 1) [menu removeItemAtIndex:1];
    std::vector<std::string> zones = savedZones();
    auto item = [&](NSMenu *into, NSString *title, const std::string &zone) {
        NSMenuItem *mi = [into addItemWithTitle:title action:nil keyEquivalent:@""];
        bool there = std::find(zones.begin(), zones.end(), zone) != zones.end();
        mi.state = there ? NSControlStateValueOn : NSControlStateValueOff;
        mi.enabled = !there;
        std::string z = zone;  // a copy: the block keeps it (a reference would outlive what it refers to)
        ADIFBlockMenuItem(mi, ^{
            std::vector<std::string> now = savedZones();
            if (std::find(now.begin(), now.end(), z) == now.end()) now.push_back(z);
            saveZones(now);
        });
        return mi;
    };
    NSDate *now = NSDate.date;
    auto titled = [&](const std::string &zone) {
        NSTimeZone *z = zoneOf(zone);
        return [NSString stringWithFormat:@"%@ (%@)", cityOf(zone), [z abbreviationForDate:now] ?: z.name];
    };
    item(menu, T(@"UTC"), "UTC");
    item(menu, TF(@"Local Time ({zone})", @{@"zone" : [NSTimeZone.localTimeZone abbreviationForDate:now] ?: NSTimeZone.localTimeZone.name}), "local");
    [menu addItem:NSMenuItem.separatorItem];
    for (const char *zone : {"America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles", "America/Anchorage",
                             "Pacific/Honolulu", "Europe/London", "Europe/Berlin", "Asia/Tokyo", "Australia/Sydney"})
        if (zoneOf(zone)) item(menu, titled(zone), zone);
    [menu addItem:NSMenuItem.separatorItem];
    NSMenu *regions = [[NSMenu alloc] initWithTitle:T(@"Other Time Zones")];
    std::map<std::string, NSMenu *> byRegion;
    NSArray<NSString *> *names = [NSTimeZone.knownTimeZoneNames sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        NSRange slash = [name rangeOfString:@"/"];
        if (slash.location == NSNotFound) continue;
        std::string region = ADIFStd([name substringToIndex:slash.location]);
        NSMenu *sub = byRegion.count(region) ? byRegion[region] : nil;
        if (!sub) {
            sub = byRegion[region] = [[NSMenu alloc] initWithTitle:ADIFString(region)];
            [regions addItemWithTitle:ADIFString(region) action:nil keyEquivalent:@""].submenu = sub;
        }
        item(sub, titled(ADIFStd(name)), ADIFStd(name));
    }
    [menu addItemWithTitle:T(@"Other Time Zones") action:nil keyEquivalent:@""].submenu = regions;
}

void fill() {
    if (!gClocks.shelf) return;
    for (NSView *v in [gClocks.shelf.subviews copy]) [v removeFromSuperview];
    for (const std::string &zone : savedZones()) {
        ADIFStatusClock *c = [[ADIFStatusClock alloc] initWithZone:zone];
        c.translatesAutoresizingMaskIntoConstraints = YES;
        c.menu = clockMenu(zone);
        [gClocks.shelf addSubview:c];
    }
    gClocks.shelf.needsLayout = YES;
    [gClocks.shelf invalidateIntrinsicContentSize];
    fillAddMenu();
}

void make() {
    if (gClocks.window) return;
    ADIFDockPanel *w = [[ADIFDockPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 150)
                                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                          backing:NSBackingStoreBuffered
                                                            defer:YES];
    w.dockItem = kDockClocks;
    w.title = T(@"Clocks");
    w.identifier = @"clocks.window";
    w.releasedWhenClosed = NO;
    w.floatingPanel = YES;  // to look at, chosen from menus: a panel (HIG)
    w.hidesOnDeactivate = NO;  // a clock is wanted in sight
    w.contentMinSize = NSMakeSize(220, 110);
    gClocks.add = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    gClocks.add.controlSize = NSControlSizeSmall;
    gClocks.add.font = theme::small();
    [gClocks.add addItemWithTitle:T(@"Add Clock")];
    gClocks.add.identifier = @"clocks.add";
    gClocks.add.toolTip = T(@"A clock for another time zone: UTC, your local time, a city's. A clock's own menu (Control-click) moves or removes it");
    gClocks.add.menu.autoenablesItems = NO;
    gClocks.shelf = [[ADIFClockShelf alloc] initWithFrame:NSZeroRect];
    gClocks.shelf.identifier = @"clocks.shelf";
    NSView *root = [[NSView alloc] initWithFrame:NSZeroRect];
    for (NSView *v in @[ gClocks.add, gClocks.shelf ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:v];
    }
    const CGFloat m = theme::kMargin;
    [NSLayoutConstraint activateConstraints:@[
        [gClocks.add.topAnchor constraintEqualToAnchor:root.topAnchor constant:m - 4],
        [gClocks.add.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [gClocks.shelf.topAnchor constraintEqualToAnchor:gClocks.add.bottomAnchor constant:6],
        [gClocks.shelf.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [gClocks.shelf.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [gClocks.shelf.bottomAnchor constraintLessThanOrEqualToAnchor:root.bottomAnchor constant:-m],
    ]];
    w.contentView = root;
    [w center];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification  // closed (or its frame): the Map's button follows
                                                      object:w
                                                       queue:nil
                                                  usingBlock:^(NSNotification *) { ADIFPanelShownChanged(); }];
    gClocks.window = w;
    fill();
}

}  // namespace

namespace clocks {

bool shown() { return gClocks.window && gClocks.window.visible; }

void open() {
    make();
    [gClocks.window makeKeyAndOrderFront:nil];
    ADIFPanelShownChanged();
}

void close() {
    if (shown()) [gClocks.window performClose:nil];  // docked: its frame closes
}

std::vector<std::string> zones() { return savedZones(); }

}  // namespace clocks
