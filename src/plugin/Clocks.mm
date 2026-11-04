// The Clocks panel: see Clocks.h.
#import "Clocks.h"

#import "Accordion.h"  // ADIFDropLine
#import "L10n.h"
#import "Night.h"
#import "PluginHost.h"
#import "Theme.h"
#import "ToolWindow.h"
#import "Workspace.h"

#include <algorithm>
#include <cmath>
#include <functional>
#include <map>
#include <sstream>

// ── How a clock looks ──

namespace {

// From its own menu; kept as `clockLooks` (Clocks.h), only what differs from these.
struct Look {
    int colour = -1;  // -1: its zone's (UTC green, local amber, a city's blue); else kColours
    int size = 1;     // 0 small, 1 medium, 2 large
    int label = 1;    // its name's and date's size, the same three
    bool date = true;
    bool hours24 = true;
    bool seconds = true;
    bool analog = false;
    int face = 0;  // analog: kFaces
};

// A status display's colours: the lit digits, the dim border and name, the dark block. Fixed,
// light or dark: a status display looks the same either way (Night Mode tints it red).
struct Colour {
    const char *key;
    int lit, dim, back;
};
const Colour kColours[] = {
    {"green", 0x4BE07A, 0x2E7D46, 0x0C1D12}, {"amber", 0xFFB938, 0x8A6418, 0x221807},  {"blue", 0x5CC8F5, 0x2B6A85, 0x061820},
    {"red", 0xFF6159, 0x8C332E, 0x230B0A},   {"violet", 0xB894FF, 0x5E4B8C, 0x130D22}, {"white", 0xE4EBF0, 0x737B82, 0x121517},
};
const int kColourCount = sizeof kColours / sizeof *kColours;
const char *const kSizes[] = {"small", "medium", "large"};
// Analog faces: Studio, a broadcast studio's ring of LEDs filling with the seconds; Dial, a
// rig's dial, numbered; Minimal, bars and a dot for the seconds.
const char *const kFaces[] = {"studio", "dial", "minimal"};
const CGFloat kDigitHeights[] = {18, 26, 40}, kDiameters[] = {64, 96, 140}, kLabelSizes[] = {9, 11, 14}, kLights[] = {6, 7, 9};

NSArray<NSString *> *colourNames() { return @[ T(@"Green"), T(@"Amber"), T(@"Blue"), T(@"Red"), T(@"Violet"), T(@"White") ]; }
NSArray<NSString *> *sizeNames() { return @[ T(@"Small"), T(@"Medium##size"), T(@"Large") ]; }
NSArray<NSString *> *faceNames() { return @[ T(@"Studio"), T(@"Dial"), T(@"Minimal") ]; }

NSColor *rgb(int hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:1];
}

const Colour &colourOf(const std::string &zone, const Look &look) {
    if (look.colour >= 0 && look.colour < kColourCount) return kColours[look.colour];
    return kColours[zone == "UTC" ? 0 : zone == "local" ? 1 : 2];
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

// What the menus call a clock: "UTC", "Local Time (CST)", "Chicago (CST)".
NSString *titled(const std::string &zone) {
    NSDate *now = NSDate.date;
    if (zone == "UTC") return T(@"UTC");
    if (zone == "local") return TF(@"Local Time ({zone})", @{@"zone" : [NSTimeZone.localTimeZone abbreviationForDate:now] ?: NSTimeZone.localTimeZone.name});
    NSTimeZone *z = zoneOf(zone);
    return [NSString stringWithFormat:@"%@ (%@)", cityOf(zone), [z abbreviationForDate:now] ?: z.name];
}

void moveClock(const std::string &zone, int by);  // the panel's, below

}  // namespace

static NSPasteboardType const kClockPasteboardType = @"io.github.ssamjung2.adiflint.clock";

// Digits as an LED display draws them: seven segments each, slanted a little, the lit ones glowing
// and the unlit ones faintly there; ':' as two dots, ' ' a digit with none lit. Drawn, so no font
// has to be installed.
@interface ADIFSegmentDisplay : NSView
@property(nonatomic, copy) NSString *text;      // digits, ':', '-' and ' '
@property(nonatomic, copy) NSString *meridiem;  // "AM" or "PM", lit beside the digits over the other unlit; nil: neither
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
- (NSFont *)meridiemFont { return [NSFont monospacedSystemFontOfSize:std::max<CGFloat>(7, std::round(_h * 0.3)) weight:NSFontWeightBold]; }

- (CGFloat)digitsWidth {
    CGFloat w = 0;
    for (NSUInteger i = 0; i < _text.length; ++i) w += ([_text characterAtIndex:i] == ':' ? self.colonWidth : self.digitWidth) + (i ? self.gap : 0);
    return w;
}

- (NSSize)intrinsicContentSize {
    CGFloat w = self.digitsWidth + _h * self.slant + 4;  // room for the slant and the glow
    if (_meridiem) w += self.gap + std::ceil([@"PM" sizeWithAttributes:@{NSFontAttributeName : self.meridiemFont}].width);
    return NSMakeSize(std::ceil(w), std::ceil(_h + 4));
}

- (void)setText:(NSString *)text {
    BOOL resize = text.length != _text.length;
    _text = [text copy];
    if (resize) [self invalidateIntrinsicContentSize];
    self.needsDisplay = YES;
}

- (void)setMeridiem:(NSString *)meridiem {
    BOOL resize = !meridiem != !_meridiem;
    _meridiem = [meridiem copy];
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
    // AM over PM, as an LED clock's indicators: the one that is now lit.
    if (_meridiem) {
        NSFont *font = self.meridiemFont;
        CGFloat left = x + self.gap + h * self.slant + 2, line = std::ceil(font.ascender - font.descender);
        for (NSString *which in @[ @"AM", @"PM" ]) {
            BOOL on = [which isEqualToString:_meridiem];
            CGFloat y = [which isEqualToString:@"AM"] ? 2 + h - line : 2;
            [NSGraphicsContext saveGraphicsState];
            if (on) [glow set];
            [which drawAtPoint:NSMakePoint(left, y) withAttributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : on ? _lit : off}];
            [NSGraphicsContext restoreGraphicsState];
        }
    }
}
@end

// An analog clock's face (kFaces), in the clock's colours, drawn: its marks lit as the digital
// clocks' segments are, its hands glowing.
@interface ADIFAnalogFace : NSView
@property(nonatomic, strong) NSColor *lit, *dim;
@property(nonatomic) BOOL seconds, hours24;  // a second hand (or ring, or dot); 13-24 on the Dial, AM or PM if not
- (instancetype)initWithDiameter:(CGFloat)diameter face:(int)face;
- (void)setHour:(long)hour minute:(long)minute second:(long)second;  // hour 0-23
@end

@implementation ADIFAnalogFace {
    CGFloat _d;
    int _face;
    long _hour, _minute, _second;
}

- (instancetype)initWithDiameter:(CGFloat)diameter face:(int)face {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _d = diameter;
    _face = face;
    _lit = _dim = NSColor.labelColor;
    _seconds = _hours24 = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.accessibilityElement = NO;  // the clock speaks for it
    return self;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(_d, _d);
}

- (void)setHour:(long)hour minute:(long)minute second:(long)second {
    if (hour == _hour && minute == _minute && second == _second) return;
    _hour = hour, _minute = minute, _second = second;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty {
    const CGFloat r = _d / 2 - 1, cx = NSMidX(self.bounds), cy = NSMidY(self.bounds);
    // A point `turn` of the way round from 12, clockwise, `radius` from the middle (behind it if negative).
    auto at = [&](double turn, CGFloat radius) {
        double a = M_PI_2 - 2 * M_PI * turn;
        return NSMakePoint(cx + radius * std::cos(a), cy + radius * std::sin(a));
    };
    NSShadow *glow = [[NSShadow alloc] init];
    glow.shadowColor = [_lit colorWithAlphaComponent:0.7];
    glow.shadowBlurRadius = std::max<CGFloat>(2, r * 0.08);
    glow.shadowOffset = NSZeroSize;
    NSColor *off = [_lit colorWithAlphaComponent:0.12];
    auto paint = [&](NSBezierPath *p, NSColor *c, bool glowing, bool stroke) {
        [NSGraphicsContext saveGraphicsState];
        if (glowing) [glow set];
        if (stroke) {
            [c setStroke];
            [p stroke];
        } else {
            [c setFill];
            [p fill];
        }
        [NSGraphicsContext restoreGraphicsState];
    };
    auto line = [&](double turn, CGFloat from, CGFloat to, CGFloat width, NSColor *c, bool glowing) {
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p moveToPoint:at(turn, from)];
        [p lineToPoint:at(turn, to)];
        p.lineWidth = width;
        p.lineCapStyle = NSLineCapStyleRound;
        paint(p, c, glowing, true);
    };
    auto dot = [&](NSPoint p, CGFloat radius, NSColor *c, bool glowing) {
        paint([NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - radius, p.y - radius, 2 * radius, 2 * radius)], c, glowing, false);
    };
    // A dial's hand: narrow to its tip, with a short tail behind the middle.
    auto hand = [&](double turn, CGFloat length, CGFloat width, NSColor *c) {
        double a = M_PI_2 - 2 * M_PI * turn;
        CGFloat dx = std::cos(a), dy = std::sin(a), px = -dy * width / 2, py = dx * width / 2, tail = r * 0.12;
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p moveToPoint:NSMakePoint(cx - dx * tail + px, cy - dy * tail + py)];
        [p lineToPoint:NSMakePoint(cx + dx * length + px * 0.25, cy + dy * length + py * 0.25)];
        [p lineToPoint:NSMakePoint(cx + dx * length - px * 0.25, cy + dy * length - py * 0.25)];
        [p lineToPoint:NSMakePoint(cx - dx * tail - px, cy - dy * tail - py)];
        [p closePath];
        paint(p, c, true, false);
    };
    auto text = [&](NSString *s, NSPoint p, NSFont *font, NSColor *c) {
        NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : c};
        NSSize size = [s sizeWithAttributes:attrs];
        [s drawAtPoint:NSMakePoint(p.x - size.width / 2, p.y - size.height / 2) withAttributes:attrs];
    };
    const double hourTurn = ((_hour % 12) + _minute / 60.0 + _second / 3600.0) / 12, minuteTurn = (_minute + _second / 60.0) / 60,
                 secondTurn = _second / 60.0;
    NSColor *caption = [_dim highlightWithLevel:0.3] ?: _dim;

    // The marks.
    if (_face == 0) {  // Studio: sixty LEDs, lit to the second; twelve for the hours inside them
        for (int i = 0; i < 60; ++i) {
            bool on = _seconds && i <= _second;
            dot(at(i / 60.0, r * 0.9), std::max<CGFloat>(1, r * 0.035), on ? _lit : off, on);
        }
        for (int i = 0; i < 12; ++i) dot(at(i / 12.0, r * 0.74), std::max<CGFloat>(1.25, r * 0.05), _lit, true);
    } else if (_face == 1) {  // Dial: a scale, numbered
        NSBezierPath *rim = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - r * 0.98, cy - r * 0.98, r * 1.96, r * 1.96)];
        paint(rim, [_lit colorWithAlphaComponent:0.06], false, false);
        rim.lineWidth = std::max<CGFloat>(1, r * 0.025);
        paint(rim, _dim, false, true);
        for (int i = 0; i < 60; ++i) {
            if (i % 5) line(i / 60.0, r * 0.86, r * 0.92, std::max<CGFloat>(0.75, r * 0.012), _dim, false);
            else line(i / 60.0, r * 0.78, r * 0.92, std::max<CGFloat>(1.25, r * 0.03), _lit, false);
        }
        bool small = r < 40;  // only 12, 3, 6 and 9 fit
        NSFont *numbers = theme::digits(std::max<CGFloat>(7, std::round(r * (small ? 0.2 : 0.17))), NSFontWeightSemibold);
        for (int n = 1; n <= 12; ++n)
            if (!small || n % 3 == 0) text([NSString stringWithFormat:@"%d", n], at(n / 12.0, r * (small ? 0.58 : 0.62)), numbers, _lit);
        if (_hours24 && !small) {
            NSFont *inner = theme::digits(std::max<CGFloat>(6, std::round(r * 0.085)), NSFontWeightMedium);
            for (int n = 13; n <= 24; ++n) text([NSString stringWithFormat:@"%d", n], at((n - 12) / 12.0, r * 0.42), inner, caption);
        }
    } else {  // Minimal: bars, 12, 3, 6 and 9 lit
        for (int i = 0; i < 12; ++i) {
            bool major = i % 3 == 0;
            line(i / 12.0, r * (major ? 0.64 : 0.7), r * 0.8, std::max<CGFloat>(1, r * (major ? 0.06 : 0.035)), major ? _lit : _dim, major);
        }
        if (_seconds) {
            NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - r * 0.93, cy - r * 0.93, r * 1.86, r * 1.86)];
            track.lineWidth = std::max<CGFloat>(0.5, r * 0.01);
            paint(track, off, false, true);
        }
    }
    if (!_hours24) text(_hour < 12 ? @"AM" : @"PM", NSMakePoint(cx, cy - r * 0.36), theme::digits(std::max<CGFloat>(7, std::round(r * 0.14)), NSFontWeightSemibold), caption);

    // The hands.
    if (_face == 0) {
        line(hourTurn, 0, r * 0.44, std::max<CGFloat>(2, r * 0.075), _lit, true);
        line(minuteTurn, 0, r * 0.64, std::max<CGFloat>(1.5, r * 0.05), _lit, true);
        dot(NSMakePoint(cx, cy), std::max<CGFloat>(2, r * 0.07), _lit, true);
    } else if (_face == 1) {
        NSColor *bright = [_lit blendedColorWithFraction:0.55 ofColor:NSColor.whiteColor] ?: _lit;
        hand(hourTurn, r * 0.48, std::max<CGFloat>(3, r * 0.09), bright);
        hand(minuteTurn, r * 0.72, std::max<CGFloat>(2.5, r * 0.065), bright);
        if (_seconds) line(secondTurn, -r * 0.18, r * 0.84, std::max<CGFloat>(0.75, r * 0.015), _lit, true);
        dot(NSMakePoint(cx, cy), std::max<CGFloat>(1.75, r * 0.05), _seconds ? _lit : bright, true);
    } else {
        line(hourTurn, 0, r * 0.42, std::max<CGFloat>(2.5, r * 0.1), _lit, true);
        line(minuteTurn, 0, r * 0.62, std::max<CGFloat>(2, r * 0.07), _lit, true);
        dot(NSMakePoint(cx, cy), std::max<CGFloat>(2, r * 0.08), _dim, false);
        if (_seconds) dot(at(secondTurn, r * 0.93), std::max<CGFloat>(1.5, r * 0.05), _lit, true);
    }
}
@end

// A clock as an operating position's status display: a dark block with a status light, its name,
// the time (LED digits or an analog face) and the date. UTC is the log's time (green); local time
// is the operator's own (amber); a city's is blue; or the colour chosen. It ticks on the second
// while it is in a window. Dragged, it moves among the others (ADIFClockShelf).
@interface ADIFStatusClock : NSView <NSDraggingSource>
- (instancetype)initWithZone:(const std::string &)zone look:(const Look &)look;
@property(nonatomic, readonly) NSString *zoneName;
@end

@implementation ADIFStatusClock {
    std::string _zone;
    Look _look;
    NSTextField *_name, *_date;
    ADIFSegmentDisplay *_digits;
    ADIFAnalogFace *_face;
    NSTimer *_timer;
    NSPoint _downAt;
    BOOL _pressed;
}

- (instancetype)initWithZone:(const std::string &)zone look:(const Look &)look {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _zone = zone;
    _look = look;
    bool utc = zone == "UTC", local = zone == "local";
    const Colour &colour = colourOf(zone, look);
    NSColor *lit = rgb(colour.lit), *dim = rgb(colour.dim);
    self.wantsLayer = YES;
    self.layer.cornerRadius = 6;
    self.layer.borderWidth = 1;
    self.layer.borderColor = dim.CGColor;
    self.layer.backgroundColor = rgb(colour.back).CGColor;
    self.identifier = utc ? @"clock.utc" : local ? @"clock.local" : [@"clock." stringByAppendingString:ADIFString(zone)];
    NSString *what = utc ? T(@"UTC: the time QSOs are logged in")
                     : local ? T(@"Your local time (this Mac's time zone)")
                             : TF(@"The time in {city} ({zone})", @{@"city" : cityOf(zone), @"zone" : ADIFString(zone)});
    self.toolTip = [NSString stringWithFormat:@"%@\n%@", what, T(@"Drag it to move it. Control-click for its menu: style, colour, size, format, and adding or removing clocks.")];

    const int label = std::clamp(look.label, 0, 2), size = std::clamp(look.size, 0, 2);
    CGFloat lightSize = kLights[label];
    NSView *light = [[NSView alloc] initWithFrame:NSZeroRect];
    light.wantsLayer = YES;
    light.layer.cornerRadius = lightSize / 2;
    light.layer.backgroundColor = lit.CGColor;
    light.layer.shadowColor = lit.CGColor;  // a glow, as a lamp
    light.layer.shadowOpacity = 0.8;
    light.layer.shadowRadius = 3;
    light.layer.shadowOffset = CGSizeZero;
    [light.widthAnchor constraintEqualToConstant:lightSize].active = YES;
    [light.heightAnchor constraintEqualToConstant:lightSize].active = YES;
    _name = [NSTextField labelWithString:@""];
    _name.font = [NSFont monospacedSystemFontOfSize:kLabelSizes[label] weight:NSFontWeightSemibold];
    _name.textColor = [dim highlightWithLevel:0.25] ?: dim;
    _name.lineBreakMode = NSLineBreakByTruncatingTail;
    NSView *time;
    if (look.analog) {
        _face = [[ADIFAnalogFace alloc] initWithDiameter:kDiameters[size] face:std::clamp(look.face, 0, 2)];
        _face.lit = lit, _face.dim = dim;
        _face.seconds = look.seconds, _face.hours24 = look.hours24;
        _face.identifier = @"clock.face";
        time = _face;
    } else {
        _digits = [[ADIFSegmentDisplay alloc] initWithDigitHeight:kDigitHeights[size]];
        _digits.lit = lit;
        _digits.identifier = @"clock.digits";
        time = _digits;
    }
    NSStackView *top = [NSStackView stackViewWithViews:@[ light, _name ]];
    top.spacing = 6;
    NSMutableArray<NSView *> *rows = [NSMutableArray arrayWithObjects:top, time, nil];
    if (look.date) {
        _date = [NSTextField labelWithString:@""];
        _date.font = theme::digits(kLabelSizes[label] + 1, NSFontWeightRegular);
        _date.textColor = _name.textColor;
        _date.identifier = @"clock.date";
        [rows addObject:_date];
    }
    NSStackView *column = [NSStackView stackViewWithViews:rows];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = look.analog ? NSLayoutAttributeCenterX : NSLayoutAttributeLeading;  // a face under its name, centred
    column.spacing = look.analog ? 4 : 1;
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

- (NSString *)zoneName {
    return ADIFString(_zone);
}

- (void)tick {
    NSDate *now = [NSDate date];
    NSTimeZone *zone = zoneOf(_zone) ?: NSTimeZone.localTimeZone;
    static NSCalendar *calendar;
    static NSDateFormatter *date;
    if (!calendar) {
        calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        date = [[NSDateFormatter alloc] init];
        date.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        date.dateFormat = @"yyyy-MM-dd EEE";
    }
    calendar.timeZone = date.timeZone = zone;
    NSDateComponents *c = [calendar components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:now];
    long h = c.hour, m = c.minute, s = c.second;
    // 24-hour "07:05:09"; 12-hour " 7:05:09" (an LED clock leaves the first digit dark) and PM.
    NSString *text = _look.hours24 ? [NSString stringWithFormat:@"%02ld:%02ld", h, m] : [NSString stringWithFormat:@"%2ld:%02ld", h % 12 ? h % 12 : 12, m];
    if (_look.seconds) text = [text stringByAppendingFormat:@":%02ld", s];
    NSString *meridiem = _look.hours24 ? nil : h < 12 ? @"AM" : @"PM";
    if (_digits) {
        _digits.text = text;
        _digits.meridiem = meridiem;
    }
    [_face setHour:h minute:m second:s];
    _date.stringValue = [date stringFromDate:now];
    NSString *abbreviation = [zone abbreviationForDate:now] ?: zone.name;
    _name.stringValue = _zone == "UTC"     ? T(@"UTC · LOG TIME")
                        : _zone == "local" ? [T(@"LOCAL · ") stringByAppendingString:abbreviation]
                                           : [NSString stringWithFormat:@"%@ · %@", cityOf(_zone).uppercaseString, abbreviation];
    NSString *spoken = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (meridiem) spoken = [spoken stringByAppendingFormat:@" %@", meridiem];
    self.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", _name.stringValue, spoken];
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

// The clock is one thing to the pointer: dragged by any part, Control-clicked anywhere for its menu.
- (NSView *)hitTest:(NSPoint)point {
    return [super hitTest:point] ? self : nil;
}

- (void)mouseDown:(NSEvent *)event {
    if (event.modifierFlags & NSEventModifierFlagControl) {  // Control-click: its menu, not a drag
        [NSMenu popUpContextMenu:[self menuForEvent:event] withEvent:event forView:self];
        return;
    }
    _pressed = YES;
    _downAt = event.locationInWindow;
}

// Moved a few points with the button down, it starts moving: a picture of it follows the pointer.
- (void)mouseDragged:(NSEvent *)event {
    if (!_pressed) return;
    NSPoint at = event.locationInWindow;
    if (std::hypot(at.x - _downAt.x, at.y - _downAt.y) < 3) return;
    _pressed = NO;
    NSPasteboardItem *board = [[NSPasteboardItem alloc] init];
    [board setString:self.zoneName forType:kClockPasteboardType];
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:board];
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
    [self cacheDisplayInRect:self.bounds toBitmapImageRep:rep];
    NSImage *picture = [[NSImage alloc] initWithSize:self.bounds.size];
    [picture addRepresentation:rep];
    [item setDraggingFrame:self.bounds contents:picture];
    [self beginDraggingSessionWithItems:@[ item ] event:event source:self];  // it slides back if it isn't dropped among the clocks
}

- (void)mouseUp:(NSEvent *)event {
    _pressed = NO;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return context == NSDraggingContextWithinApplication ? NSDragOperationMove : NSDragOperationNone;
}

- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session {
    return YES;  // a clock only moves: Option doesn't make it a copy
}

- (void)draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)screenPoint {
    self.alphaValue = 0.35;  // it stays where it is, dim, to show where it comes from
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    self.alphaValue = 1;
}

// Without a pointer: VoiceOver's actions, as its menu's Move Left and Move Right.
- (NSArray<NSAccessibilityCustomAction *> *)accessibilityCustomActions {
    std::string zone = _zone;
    return @[
        [[NSAccessibilityCustomAction alloc] initWithName:T(@"Move Left")
                                                  handler:^BOOL {
                                                      moveClock(zone, -1);
                                                      return YES;
                                                  }],
        [[NSAccessibilityCustomAction alloc] initWithName:T(@"Move Right")
                                                  handler:^BOOL {
                                                      moveClock(zone, 1);
                                                      return YES;
                                                  }],
    ];
}
@end

// The clocks in rows, in their order: as many to a row as fit at their least widths (a large or
// analog clock needs more), the room left shared among the row's clocks; each row as tall as its
// tallest. A clock dragged among them shows where it will go with a line, and goes there.
@interface ADIFClockShelf : NSView
@property(nonatomic, copy) void (^onMove)(NSString *zone, NSString *before);  // before nil: last
@end

static const CGFloat kGap = 10, kLeast = 110;  // between clocks; a clock's least width

@implementation ADIFClockShelf {
    ADIFDropLine *_line;
    ADIFStatusClock *_before;  // where a drop would put the clock dragged: ahead of this one, or last
    BOOL _changes;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    [self registerForDraggedTypes:@[ kClockPasteboardType ]];
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (NSArray<ADIFStatusClock *> *)clocks {
    NSMutableArray<ADIFStatusClock *> *out = [NSMutableArray array];
    for (NSView *v in self.subviews)
        if ([v isKindOfClass:ADIFStatusClock.class]) [out addObject:(ADIFStatusClock *)v];
    return out;
}

// Each clock's frame at this width, and how tall they are together.
- (std::vector<NSRect>)framesFor:(CGFloat)width height:(CGFloat *)height {
    NSArray<ADIFStatusClock *> *clocks = [self clocks];
    size_t n = clocks.count;
    std::vector<NSSize> fit(n);
    for (size_t i = 0; i < n; ++i) {
        NSSize f = clocks[i].fittingSize;
        fit[i] = NSMakeSize(std::max(kLeast, std::ceil(f.width)), std::ceil(f.height));
    }
    std::vector<NSRect> out(n);
    CGFloat y = 0, lastExtra = -1;
    for (size_t i = 0; i < n;) {
        size_t j = i;
        CGFloat used = 0;
        while (j < n && (j == i || used + kGap + fit[j].width <= width)) {
            used += (j > i ? kGap : 0) + fit[j].width;
            ++j;
        }
        CGFloat extra = std::max<CGFloat>(0, width - used) / (j - i), rowHeight = 0;
        if (j == n && i > 0 && lastExtra >= 0) extra = std::min(extra, lastExtra);  // the last row's clocks no wider than the others
        lastExtra = extra;
        for (size_t k = i; k < j; ++k) rowHeight = std::max(rowHeight, fit[k].height);
        CGFloat x = 0;
        for (size_t k = i; k < j; ++k) {
            CGFloat w = std::floor(fit[k].width + extra);
            out[k] = NSMakeRect(x, y, w, rowHeight);
            x += w + kGap;
        }
        y += rowHeight + kGap;
        i = j;
    }
    if (height) *height = n ? y - kGap : 0;
    return out;
}

- (NSSize)intrinsicContentSize {
    CGFloat height = 0;
    [self framesFor:NSWidth(self.bounds) height:&height];
    return NSMakeSize(NSViewNoIntrinsicMetric, height);
}

- (void)layout {
    [super layout];
    NSArray<ADIFStatusClock *> *clocks = [self clocks];
    std::vector<NSRect> frames = [self framesFor:NSWidth(self.bounds) height:nullptr];
    for (size_t i = 0; i < clocks.count && i < frames.size(); ++i) clocks[i].frame = frames[i];
    [self invalidateIntrinsicContentSize];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self invalidateIntrinsicContentSize];
}

#pragma mark Dropping

// The clock being dragged, if it is one of these.
- (ADIFStatusClock *)clockDragged:(id<NSDraggingInfo>)info {
    NSString *zone = [info.draggingPasteboard stringForType:kClockPasteboardType];
    for (ADIFStatusClock *c in [self clocks])
        if (zone.length && [c.zoneName isEqualToString:zone]) return c;
    return nil;
}

// With the pointer where it is: the clock the dragged one would go ahead of (the first, in reading
// order, whose middle is past the pointer), and a line in the gap it would go into. Nothing shows
// where the clock would stay where it is.
- (void)showDestination:(id<NSDraggingInfo>)info {
    ADIFStatusClock *dragged = [self clockDragged:info];
    NSArray<ADIFStatusClock *> *clocks = [self clocks];
    NSUInteger at = dragged ? [clocks indexOfObject:dragged] : NSNotFound;
    _before = nil;
    _changes = NO;
    if (at == NSNotFound) {
        _line.hidden = YES;
        return;
    }
    [self layoutSubtreeIfNeeded];  // the clocks where they are seen, not where they were before a change
    NSPoint p = [self convertPoint:info.draggingLocation fromView:nil];
    ADIFStatusClock *after = nil;  // the one before the gap
    for (ADIFStatusClock *c in clocks) {
        if (c == dragged) continue;
        NSRect f = c.frame;
        if (p.y < NSMinY(f) || (p.y <= NSMaxY(f) && p.x < NSMidX(f))) {
            _before = c;
            break;
        }
        after = c;
    }
    _changes = _before != (at + 1 < clocks.count ? clocks[at + 1] : nil);
    if (!_changes || (!_before && !after)) {
        _line.hidden = YES;
        return;
    }
    // Down the gap: after the clock before it when the pointer is on that one's row (the end of a
    // row), else ahead of the one it goes before.
    BOOL atRowEnd = after && (!_before || (NSMinY(after.frame) != NSMinY(_before.frame) && p.y <= NSMaxY(after.frame)));
    NSRect beside = atRowEnd ? after.frame : _before.frame;
    CGFloat thickness = 3, x = atRowEnd ? NSMaxX(beside) + kGap / 2 : NSMinX(beside) - kGap / 2;
    x = std::clamp<CGFloat>(x, thickness / 2, NSWidth(self.bounds) - thickness / 2);
    if (!_line) _line = [[ADIFDropLine alloc] initWithFrame:NSZeroRect];
    if (self.subviews.lastObject != _line) [self addSubview:_line positioned:NSWindowAbove relativeTo:nil];  // over the clocks
    _line.frame = NSMakeRect(x - thickness / 2, NSMinY(beside), thickness, NSHeight(beside));
    _line.hidden = NO;
}

- (NSDragOperation)trackDrag:(id<NSDraggingInfo>)info {
    if (![self clockDragged:info]) {
        [self finishDrag];
        return NSDragOperationNone;
    }
    [self showDestination:info];
    return NSDragOperationMove;
}

- (void)finishDrag {
    _line.hidden = YES;
    _before = nil;
    _changes = NO;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    return [self trackDrag:info];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    return [self trackDrag:info];
}

- (void)draggingExited:(id<NSDraggingInfo>)info {
    [self finishDrag];
}

- (void)draggingEnded:(id<NSDraggingInfo>)info {
    [self finishDrag];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info {
    return [self clockDragged:info] != nil;
}

// A drop that changes nothing isn't one: the picture goes back to where the clock is.
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    ADIFStatusClock *dragged = [self clockDragged:info];
    [self showDestination:info];
    NSString *before = _before.zoneName;
    BOOL changes = _changes;
    [self finishDrag];
    if (!dragged || !changes) return NO;
    if (self.onMove) self.onMove(dragged.zoneName, before);
    return YES;
}
@end

// ── The panel ──

namespace {

struct {
    ADIFDockPanel *window;
    NSView *root;
    ADIFClockShelf *shelf;
} gClocks;

const char *const kZonesKey = "clockZones", *const kLooksKey = "clockLooks";

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

int indexOf(const char *const *keys, int n, const std::string &key, int otherwise) {
    for (int i = 0; i < n; ++i)
        if (key == keys[i]) return i;
    return otherwise;
}

// `clockLooks`: "UTC size=large;America/Chicago style=analog face=dial colour=red". A word it
// doesn't know leaves that part as it was at first.
std::map<std::string, Look> savedLooks() {
    std::map<std::string, Look> out;
    std::string v = adifhost::setting(kLooksKey);
    std::istringstream clocks(v);
    std::string one;
    const char *const colourKeys[] = {kColours[0].key, kColours[1].key, kColours[2].key, kColours[3].key, kColours[4].key, kColours[5].key};
    while (std::getline(clocks, one, ';')) {
        std::istringstream words(one);
        std::string zone, word;
        if (!(words >> zone)) continue;
        Look &l = out[zone];
        while (words >> word) {
            size_t eq = word.find('=');
            if (eq == std::string::npos) continue;
            std::string key = word.substr(0, eq), value = word.substr(eq + 1);
            if (key == "style") l.analog = value == "analog";
            else if (key == "face") l.face = indexOf(kFaces, 3, value, 0);
            else if (key == "colour") l.colour = indexOf(colourKeys, kColourCount, value, -1);
            else if (key == "size") l.size = indexOf(kSizes, 3, value, 1);
            else if (key == "label") l.label = indexOf(kSizes, 3, value, 1);
            else if (key == "date") l.date = value != "no";
            else if (key == "hours") l.hours24 = value != "12";
            else if (key == "seconds") l.seconds = value != "no";
        }
    }
    return out;
}

Look lookOf(const std::string &zone) {
    std::map<std::string, Look> looks = savedLooks();
    auto it = looks.find(zone);
    return it == looks.end() ? Look() : it->second;
}

// The looks of the clocks there are, in their order, each with only what differs from the first look.
void saveLooks(const std::map<std::string, Look> &looks) {
    std::string v;
    for (const std::string &zone : savedZones()) {
        auto it = looks.find(zone);
        if (it == looks.end()) continue;
        const Look &l = it->second;
        std::string words;
        auto word = [&](const char *key, const std::string &value) { words += std::string(" ") + key + "=" + value; };
        if (l.analog) word("style", "analog");
        if (l.face > 0 && l.face < 3) word("face", kFaces[l.face]);
        if (l.colour >= 0 && l.colour < kColourCount) word("colour", kColours[l.colour].key);
        if (l.size != 1) word("size", kSizes[std::clamp(l.size, 0, 2)]);
        if (l.label != 1) word("label", kSizes[std::clamp(l.label, 0, 2)]);
        if (!l.date) word("date", "no");
        if (!l.hours24) word("hours", "12");
        if (!l.seconds) word("seconds", "no");
        if (!words.empty()) v += (v.empty() ? "" : ";") + zone + words;
    }
    adifhost::setSetting(kLooksKey, v);
}

void fill();

void saveZones(const std::vector<std::string> &zones) {
    std::string v;
    for (const std::string &z : zones) v += (v.empty() ? "" : ",") + z;
    adifhost::setSetting(kZonesKey, v);
    saveLooks(savedLooks());  // a clock removed: its look goes with it
    fill();
}

void relook(const std::string &zone, const std::function<void(Look &)> &change) {
    std::map<std::string, Look> looks = savedLooks();
    change(looks[zone]);
    saveLooks(looks);
    fill();
}

void moveClock(const std::string &zone, int by) {
    std::vector<std::string> now = savedZones();
    size_t at = (size_t)(std::find(now.begin(), now.end(), zone) - now.begin()), to = at + by;
    if (at < now.size() && to < now.size()) {
        std::swap(now[at], now[to]);
        saveZones(now);
    }
}

// `zone` put ahead of `before` (last when it's empty): dropped there.
void placeClock(const std::string &zone, const std::string &before) {
    std::vector<std::string> now = savedZones();
    now.erase(std::remove(now.begin(), now.end(), zone), now.end());
    auto at = std::find(now.begin(), now.end(), before);
    now.insert(before.empty() ? now.end() : at, zone);
    saveZones(now);
}

void removeClock(const std::string &zone) {
    std::vector<std::string> now = savedZones();
    if (now.size() < 2) return;  // the last one stays
    now.erase(std::remove(now.begin(), now.end(), zone), now.end());
    saveZones(now);
}

NSMenu *newMenu(NSString *title) {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    menu.autoenablesItems = NO;
    return menu;
}

NSMenu *submenu(NSMenu *menu, NSString *title) {
    NSMenu *sub = newMenu(title);
    [menu addItemWithTitle:title action:nil keyEquivalent:@""].submenu = sub;
    return sub;
}

NSMenuItem *choice(NSMenu *menu, NSString *title, bool on, void (^act)(void)) {
    NSMenuItem *mi = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    mi.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    ADIFBlockMenuItem(mi, act);
    return mi;
}

void header(NSMenu *menu, NSString *title) {
    if (@available(macOS 14.0, *)) {
        [menu addItem:[NSMenuItem sectionHeaderWithTitle:title]];
    } else {
        [menu addItemWithTitle:title action:nil keyEquivalent:@""].enabled = NO;
    }
}

// A dot of a clock colour, for its menu item.
NSImage *swatch(NSColor *c) {
    return [NSImage imageWithSize:NSMakeSize(12, 12)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect r) {
                       [c setFill];
                       [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 1, 1)] fill];
                       return YES;
                   }];
}

// A time zone to add: ticked, not added again, when it has a clock already.
void zoneItem(NSMenu *into, NSString *title, const std::string &zone, const std::vector<std::string> &zones) {
    bool there = std::find(zones.begin(), zones.end(), zone) != zones.end();
    std::string z = zone;  // a copy: the block keeps it (a reference would outlive what it refers to)
    NSMenuItem *mi = choice(into, title, there, ^{
        std::vector<std::string> now = savedZones();
        if (std::find(now.begin(), now.end(), z) == now.end()) now.push_back(z);
        saveZones(now);
    });
    mi.enabled = !there;
}

// Other Time Zones: every one by region, made when it opens (they are hundreds).
void fillRegions(NSMenu *menu) {
    std::vector<std::string> zones = savedZones();
    std::map<std::string, NSMenu *> byRegion;
    for (NSString *name in [NSTimeZone.knownTimeZoneNames sortedArrayUsingSelector:@selector(compare:)]) {
        NSRange slash = [name rangeOfString:@"/"];
        if (slash.location == NSNotFound) continue;
        std::string region = ADIFStd([name substringToIndex:slash.location]);
        __strong NSMenu *&sub = byRegion[region];
        if (!sub) sub = submenu(menu, ADIFString(region));
        zoneItem(sub, titled(ADIFStd(name)), ADIFStd(name), zones);
    }
}

}  // namespace

@interface ADIFZoneMenus : NSObject <NSMenuDelegate>
@end
@implementation ADIFZoneMenus
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    fillRegions(menu);
}
@end

namespace {

ADIFZoneMenus *gZoneMenus;  // the Other Time Zones menus' delegate (a menu holds its delegate weakly)

// Add Clock: UTC and local time, the cities operators often keep (the US's zones, Europe's,
// Japan's, Australia's), then every time zone by region. Those shown already are ticked, not added again.
void addZoneItems(NSMenu *menu) {
    std::vector<std::string> zones = savedZones();
    zoneItem(menu, titled("UTC"), "UTC", zones);
    zoneItem(menu, titled("local"), "local", zones);
    [menu addItem:NSMenuItem.separatorItem];
    for (const char *zone : {"America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles", "America/Anchorage",
                             "Pacific/Honolulu", "Europe/London", "Europe/Berlin", "Asia/Tokyo", "Australia/Sydney"})
        if (zoneOf(zone)) zoneItem(menu, titled(zone), zone, zones);
    [menu addItem:NSMenuItem.separatorItem];
    if (!gZoneMenus) gZoneMenus = [[ADIFZoneMenus alloc] init];
    NSMenu *regions = submenu(menu, T(@"Other Time Zones"));
    regions.delegate = gZoneMenus;
}

// The panel's own menu (Control-click between the clocks): add one, or remove one.
NSMenu *panelMenu() {
    NSMenu *menu = newMenu(@"");
    addZoneItems(submenu(menu, T(@"Add Clock")));
    NSMenu *remove = submenu(menu, T(@"Remove Clock"));
    std::vector<std::string> zones = savedZones();
    for (const std::string &zone : zones) {
        std::string z = zone;
        choice(remove, titled(zone), false, ^{ removeClock(z); }).enabled = zones.size() > 1;  // the last one stays
    }
    return menu;
}

// A clock's own menu: how it looks, where it is, and the panel's Add Clock and Remove.
NSMenu *clockMenu(const std::string &zone) {
    NSMenu *menu = newMenu(@"");
    const Look l = lookOf(zone);
    std::string z = zone;
    auto set = [z](std::function<void(Look &)> change) { return ^{ relook(z, change); }; };

    NSMenu *style = submenu(menu, T(@"Style"));
    choice(style, T(@"Digital"), !l.analog, set([](Look &x) { x.analog = false; }));
    choice(style, T(@"Analog"), l.analog, set([](Look &x) { x.analog = true; }));
    [style addItem:NSMenuItem.separatorItem];
    header(style, T(@"Analog Face"));
    NSArray<NSString *> *faces = faceNames();
    for (int i = 0; i < 3; ++i) choice(style, faces[i], l.analog && l.face == i, set([i](Look &x) { x.analog = true, x.face = i; }));

    NSMenu *colour = submenu(menu, T(@"Colour"));
    NSMenuItem *byZone = choice(colour, T(@"By Time Zone"), l.colour < 0, set([](Look &x) { x.colour = -1; }));
    byZone.toolTip = T(@"UTC green, local time amber, a city's blue");
    byZone.image = swatch(rgb(colourOf(zone, Look()).lit));
    [colour addItem:NSMenuItem.separatorItem];
    NSArray<NSString *> *colours = colourNames();
    for (int i = 0; i < kColourCount; ++i) choice(colour, colours[i], l.colour == i, set([i](Look &x) { x.colour = i; })).image = swatch(rgb(kColours[i].lit));

    NSArray<NSString *> *sizes = sizeNames();
    NSMenu *size = submenu(menu, T(@"Size"));
    for (int i = 0; i < 3; ++i) choice(size, sizes[i], l.size == i, set([i](Look &x) { x.size = i; }));
    NSMenu *label = submenu(menu, T(@"Label Size"));
    for (int i = 0; i < 3; ++i) choice(label, sizes[i], l.label == i, set([i](Look &x) { x.label = i; }));

    NSMenu *format = submenu(menu, T(@"Time Format"));
    choice(format, T(@"24-Hour"), l.hours24, set([](Look &x) { x.hours24 = true; }));
    choice(format, T(@"12-Hour"), !l.hours24, set([](Look &x) { x.hours24 = false; }));
    [format addItem:NSMenuItem.separatorItem];
    choice(format, T(@"Show Seconds"), l.seconds, set([](Look &x) { x.seconds = !x.seconds; }));
    choice(menu, T(@"Show Date"), l.date, set([](Look &x) { x.date = !x.date; }));

    [menu addItem:NSMenuItem.separatorItem];
    std::vector<std::string> zones = savedZones();
    size_t at = (size_t)(std::find(zones.begin(), zones.end(), zone) - zones.begin());
    choice(menu, T(@"Move Left"), false, ^{ moveClock(z, -1); }).enabled = at > 0 && at < zones.size();
    choice(menu, T(@"Move Right"), false, ^{ moveClock(z, 1); }).enabled = at + 1 < zones.size();

    [menu addItem:NSMenuItem.separatorItem];
    addZoneItems(submenu(menu, T(@"Add Clock")));
    choice(menu, T(@"Remove This Clock"), false, ^{ removeClock(z); }).enabled = zones.size() > 1;  // the last one stays
    return menu;
}

// As its own window, the panel as tall as its clocks need (a large or analog clock is taller),
// never shorter than you made it; docked, its frame's size is the console's.
void fitHeight() {
    ADIFDockPanel *w = gClocks.window;
    if (!w || w.dockHost || !w.visible) return;
    [gClocks.root layoutSubtreeIfNeeded];
    NSSize now = gClocks.root.frame.size;
    CGFloat need = std::ceil(gClocks.shelf.intrinsicContentSize.height + 2 * theme::kMargin);
    if (need > now.height) [w setContentSize:NSMakeSize(now.width, need)];
}

void fill() {
    if (!gClocks.shelf) return;
    for (NSView *v in [gClocks.shelf.subviews copy]) [v removeFromSuperview];
    std::map<std::string, Look> looks = savedLooks();
    for (const std::string &zone : savedZones()) {
        ADIFStatusClock *c = [[ADIFStatusClock alloc] initWithZone:zone look:looks.count(zone) ? looks[zone] : Look()];
        c.translatesAutoresizingMaskIntoConstraints = YES;
        c.menu = clockMenu(zone);
        [gClocks.shelf addSubview:c];
    }
    gClocks.shelf.menu = panelMenu();
    gClocks.root.menu = panelMenu();  // the margins round the clocks too
    gClocks.shelf.needsLayout = YES;
    [gClocks.shelf invalidateIntrinsicContentSize];
    fitHeight();
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
    w.contentMinSize = NSMakeSize(220, 90);
    gClocks.shelf = [[ADIFClockShelf alloc] initWithFrame:NSZeroRect];
    gClocks.shelf.identifier = @"clocks.shelf";
    gClocks.shelf.toolTip = T(@"Control-click to add or remove a clock; drag a clock to move it.");
    gClocks.shelf.onMove = ^(NSString *zone, NSString *before) { placeClock(ADIFStd(zone), before ? ADIFStd(before) : std::string()); };
    gClocks.shelf.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *root = gClocks.root = [[NSView alloc] initWithFrame:NSZeroRect];
    [root addSubview:gClocks.shelf];
    const CGFloat m = theme::kMargin;
    [NSLayoutConstraint activateConstraints:@[
        [gClocks.shelf.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
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
    fitHeight();
    ADIFPanelShownChanged();
}

void close() {
    if (shown()) [gClocks.window performClose:nil];  // docked: its frame closes
}

std::vector<std::string> zones() { return savedZones(); }

}  // namespace clocks
