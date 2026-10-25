#import "Charts.h"

#import "L10n.h"
#import "ToolWindow.h"

#include "adif_tools.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace {

NSColor *rgb(unsigned c) { return [NSColor colorWithSRGBRed:((c >> 16) & 255) / 255.0 green:((c >> 8) & 255) / 255.0 blue:(c & 255) / 255.0 alpha:1]; }

// The guidance's blue: its light step on the light background, its dark step on the dark one
// (both checked against this window's background: white and #1e1e1e, 3:1 and up).
NSColor *seriesColour(bool dark) { return rgb(dark ? 0x3987e5 : 0x2a78d6); }

// Its sequential ramp, steps 100 to 700, for the heat grid: more is darker on light, lighter on dark.
const unsigned kRamp[] = {0xcde2fb, 0xb7d3f6, 0x9ec5f4, 0x86b6ef, 0x6da7ec, 0x5598e7, 0x3987e5,
                          0x2a78d6, 0x256abf, 0x1c5cab, 0x184f95, 0x104281, 0x0d366b};
constexpr size_t kRampSteps = sizeof kRamp / sizeof kRamp[0];

NSColor *rampColour(double t, bool dark) {  // t in (0, 1]
    size_t i = std::min(kRampSteps - 1, (size_t)std::lround(1 + std::clamp(t, 0.0, 1.0) * (kRampSteps - 2)));  // step 150 up
    return rgb(kRamp[dark ? kRampSteps - 1 - i : i]);
}

// "1,234", and from 10,000 "12.9K".
std::string compact(double n) {
    char b[32];
    if (n >= 10000) {
        std::snprintf(b, sizeof b, n >= 100000 ? "%.0fK" : "%.1fK", n / 1000);
        return b;
    }
    std::string s = std::to_string((long long)std::llround(n));
    for (int i = (int)s.size() - 3; i > 0; i -= 3) s.insert((size_t)i, ",");
    return s;
}

// The axis's top: 1, 2 or 5 times a power of ten, at least `v`.
double niceMax(double v) {
    if (v <= 1) return 1;
    double p = std::pow(10, std::floor(std::log10(v)));
    for (double m : {1.0, 2.0, 5.0, 10.0})
        if (m * p >= v) return m * p;
    return 10 * p;
}

NSDictionary *textAttrs(CGFloat size, NSFontWeight weight, NSColor *colour) {
    return @{NSFontAttributeName : [NSFont systemFontOfSize:size weight:weight], NSForegroundColorAttributeName : colour};
}

}  // namespace

@implementation ADIFChartsView {
    adif::SummaryStats _s;
    CGFloat _laidOutWidth;
    struct Tip {
        NSRect rect;
        std::string text;
    };
    std::vector<Tip> _tips;
    std::string _spoken;  // what VoiceOver says the charts show
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setStats:(const adif::SummaryStats &)stats {
    _s = stats;
    _laidOutWidth = -1;
    [self relayout];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    if (size.width != _laidOutWidth) [self relayout];
}

// The height the charts take at this width, the tooltips, and what VoiceOver says.
- (void)relayout {
    CGFloat width = NSWidth(self.frame);
    if (width <= 0) return;
    _laidOutWidth = width;
    _tips.clear();
    CGFloat height = [self paint:NO];
    if (std::fabs(NSHeight(self.frame) - height) > 0.5) [super setFrameSize:NSMakeSize(width, height)];
    [self removeAllToolTips];
    for (const Tip &t : _tips) [self addToolTipRect:t.rect owner:ADIFString(t.text) userData:nil];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(self.bounds);
    std::vector<Tip> kept = _tips;
    [self paint:YES];
    _tips = kept;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (bool)dark {
    return [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
}

// Lays the charts out top to bottom, drawing them when `draw`; their height.
- (CGFloat)paint:(BOOL)draw {
    const CGFloat margin = 20, width = _laidOutWidth > 0 ? _laidOutWidth : NSWidth(self.bounds), plotW = width - 2 * margin;
    bool dark = [self dark];
    NSColor *ink = NSColor.labelColor, *quiet = NSColor.secondaryLabelColor, *grid = NSColor.separatorColor, *blue = seriesColour(dark);
    CGFloat y = margin;
    auto text = [&](const std::string &s, NSPoint at, CGFloat size, NSFontWeight weight, NSColor *colour, int align) {  // align -1 left, 0 centre, 1 right
        NSString *str = ADIFString(s);
        NSDictionary *a = textAttrs(size, weight, colour);
        NSSize sz = [str sizeWithAttributes:a];
        NSPoint p = NSMakePoint(align < 0 ? at.x : align == 0 ? at.x - sz.width / 2 : at.x - sz.width, at.y);
        if (draw) [str drawAtPoint:p withAttributes:a];
        return sz;
    };
    auto heading = [&](const std::string &title, const std::string &sub) {
        y += text(title, NSMakePoint(margin, y), NSFont.systemFontSize + 1, NSFontWeightSemibold, ink, -1).height + 2;
        if (!sub.empty()) y += text(sub, NSMakePoint(margin, y), NSFont.smallSystemFontSize, NSFontWeightRegular, quiet, -1).height;
        y += 10;
    };
    auto hairline = [&](CGFloat x0, CGFloat x1, CGFloat yy) {
        if (!draw) return;
        [grid setFill];
        NSRectFill(NSMakeRect(x0, yy, x1 - x0, 1 / (self.window.backingScaleFactor ?: 2)));
    };
    // A bar from its baseline, square there and rounded 4 points at its data end.
    auto bar = [&](NSRect r, bool horizontal) {
        if (!draw || r.size.width <= 0 || r.size.height <= 0) return;
        CGFloat rad = std::min<CGFloat>(4, std::min(r.size.width, r.size.height) / 2);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
        NSRect square = horizontal ? NSMakeRect(NSMinX(r), NSMinY(r), std::min(rad, NSWidth(r)), NSHeight(r))
                                   : NSMakeRect(NSMinX(r), NSMaxY(r) - std::min(rad, NSHeight(r)), NSWidth(r), std::min(rad, NSHeight(r)));
        [blue setFill];
        [p fill];
        NSRectFill(square);
    };
    if (_s.qsos == 0) {
        text(adif::i18n::tr("No QSOs to chart yet."), NSMakePoint(margin, y), NSFont.systemFontSize, NSFontWeightRegular, quiet, -1);
        _spoken = adif::i18n::tr("No QSOs to chart yet.");
        return y + 40;
    }
    _spoken = adif::i18n::trp("Charts of {n} QSO", "Charts of {n} QSOs", (long long)_s.qsos);

    // ── QSOs by band: columns, low bands on the left ──
    if (!_s.bands.empty()) {
        heading(adif::i18n::tr("QSOs by band"), "");
        const CGFloat axis = 40, plotH = 130, left = margin + axis, w = plotW - axis;
        size_t most = 0;
        for (const auto &b : _s.bands) most = std::max(most, b.second);
        double top = niceMax((double)most);
        for (double f : {0.0, 0.5, 1.0}) {
            CGFloat yy = y + plotH - plotH * f;
            hairline(left, left + w, yy);
            text(compact(top * f), NSMakePoint(left - 6, yy - 7), NSFont.smallSystemFontSize - 1, NSFontWeightRegular, quiet, 1);
        }
        CGFloat slot = w / (CGFloat)_s.bands.size(), thick = std::min<CGFloat>(24, slot * 0.6);
        for (size_t i = 0; i < _s.bands.size(); ++i) {
            const auto &[band, n] = _s.bands[i];
            CGFloat h = plotH * (CGFloat)(n / top), cx = left + slot * (i + 0.5);
            NSRect r = NSMakeRect(cx - thick / 2, y + plotH - h, thick, h);
            bar(r, false);
            if (slot >= 26) text(compact((double)n), NSMakePoint(cx, NSMinY(r) - 15), NSFont.smallSystemFontSize - 1, NSFontWeightMedium, ink, 0);
            text(band, NSMakePoint(cx, y + plotH + 4), NSFont.smallSystemFontSize - 1, NSFontWeightRegular, quiet, 0);
            _tips.push_back({NSMakeRect(left + slot * i, y, slot, plotH + 18),
                             adif::i18n::trp("{band}: {n} QSO", "{band}: {n} QSOs", (long long)n, {{"band", band}})});
        }
        y += plotH + 22 + 18;
    }

    // ── Horizontal bars: modes (the eight most, then the rest together) and continents ──
    auto barList = [&](const std::string &title, const std::vector<std::pair<std::string, size_t>> &items) {
        if (items.empty()) return;
        heading(title, "");
        CGFloat labelW = 0;
        for (const auto &it : items) labelW = std::max(labelW, [ADIFString(it.first) sizeWithAttributes:textAttrs(NSFont.smallSystemFontSize, NSFontWeightRegular, quiet)].width);
        labelW = std::min<CGFloat>(labelW + 10, plotW * 0.4);
        const CGFloat row = 22, thick = 14, valueW = 52, maxW = plotW - labelW - valueW;
        size_t most = 0;
        for (const auto &it : items) most = std::max(most, it.second);
        for (const auto &[name, n] : items) {
            text(name, NSMakePoint(margin + labelW - 10, y + 3), NSFont.smallSystemFontSize, NSFontWeightRegular, quiet, 1);
            CGFloat len = std::max<CGFloat>(2, maxW * (CGFloat)n / (CGFloat)std::max<size_t>(1, most));
            NSRect r = NSMakeRect(margin + labelW, y + (row - thick) / 2, len, thick);
            bar(r, true);
            text(compact((double)n), NSMakePoint(NSMaxX(r) + 6, y + 3), NSFont.smallSystemFontSize, NSFontWeightMedium, ink, -1);
            _tips.push_back({NSMakeRect(margin, y, plotW, row), adif::i18n::trp("{what}: {n} QSO", "{what}: {n} QSOs", (long long)n, {{"what", name}})});
            y += row;
        }
        y += 20;
    };
    {
        std::vector<std::pair<std::string, size_t>> modes(_s.modes.begin(), _s.modes.begin() + (long)std::min<size_t>(8, _s.modes.size()));
        size_t rest = 0;
        for (size_t i = 8; i < _s.modes.size(); ++i) rest += _s.modes[i].second;
        if (rest) modes.emplace_back(adif::i18n::tr("Other modes"), rest);
        barList(adif::i18n::tr("QSOs by mode"), modes);
    }
    {
        std::vector<std::pair<std::string, size_t>> conts;
        for (const auto &[code, n] : _s.continents) {
            static const std::pair<const char *, const char *> kNames[] = {{"AF", N_("Africa")}, {"AN", N_("Antarctica")}, {"AS", N_("Asia")},
                                                                           {"EU", N_("Europe")}, {"NA", N_("North America")}, {"OC", N_("Oceania")},
                                                                           {"SA", N_("South America")}};
            std::string name = code;
            for (const auto &[c, full] : kNames)
                if (code == c) name = adif::i18n::tr(full);
            conts.emplace_back(name, n);
        }
        barList(adif::i18n::tr("QSOs by continent"), conts);
    }

    // ── Over time: a line, by day, week or month as the log's span asks (one day: nothing to draw) ──
    if (_s.days.size() > 1) {
        long first = 0, last = 0;
        adif::parseAdifDate(_s.days.front().first, &first);
        adif::parseAdifDate(_s.days.back().first, &last);
        long span = last - first + 1;
        int unit = span <= 120 ? 1 : span <= 3 * 366 ? 7 : 30;  // days a point
        std::vector<std::pair<long, size_t>> points;  // first day of each bucket, QSOs in it
        for (long d = first; d <= last; d += unit) points.emplace_back(d, 0);
        for (const auto &[date, n] : _s.days) {
            long d = 0;
            adif::parseAdifDate(date, &d);
            points[(size_t)((d - first) / unit)].second += n;
        }
        heading(unit == 1 ? adif::i18n::tr("QSOs per day") : unit == 7 ? adif::i18n::tr("QSOs per week") : adif::i18n::tr("QSOs per 30 days"),
                adif::displayDate(adif::formatAdifDate(first)) + " – " + adif::displayDate(adif::formatAdifDate(last)));
        const CGFloat axis = 40, plotH = 120, left = margin + axis, w = plotW - axis - 30;
        size_t most = 0;
        for (const auto &p : points) most = std::max(most, p.second);
        double top = niceMax((double)most);
        for (double f : {0.0, 0.5, 1.0}) {
            CGFloat yy = y + plotH - plotH * f;
            hairline(left, left + w, yy);
            text(compact(top * f), NSMakePoint(left - 6, yy - 7), NSFont.smallSystemFontSize - 1, NSFontWeightRegular, quiet, 1);
        }
        auto at = [&](size_t i) {
            CGFloat x = points.size() == 1 ? left + w / 2 : left + w * (CGFloat)i / (CGFloat)(points.size() - 1);
            return NSMakePoint(x, y + plotH - plotH * (CGFloat)(points[i].second / top));
        };
        if (draw) {
            NSBezierPath *line = [NSBezierPath bezierPath], *area = [NSBezierPath bezierPath];
            for (size_t i = 0; i < points.size(); ++i) {
                NSPoint p = at(i);
                if (i == 0) [line moveToPoint:p], [area moveToPoint:NSMakePoint(p.x, y + plotH)];
                else [line lineToPoint:p];
                [area lineToPoint:p];
            }
            [area lineToPoint:NSMakePoint(at(points.size() - 1).x, y + plotH)];
            [area closePath];
            [[blue colorWithAlphaComponent:0.10] setFill];
            [area fill];
            line.lineWidth = 2;
            line.lineJoinStyle = NSLineJoinStyleRound;
            line.lineCapStyle = NSLineCapStyleRound;
            [blue setStroke];
            [line stroke];
        }
        for (size_t i = 0; i < points.size(); ++i) {
            NSPoint p = at(i);
            CGFloat half = std::max<CGFloat>(4, w / (CGFloat)std::max<size_t>(1, points.size()) / 2);
            std::string from = adif::displayDate(adif::formatAdifDate(points[i].first));
            _tips.push_back({NSMakeRect(p.x - half, y, 2 * half, plotH),
                             (unit == 1 ? from : adif::i18n::trf("{from} on", {{"from", from}})) + ": " +
                                 adif::i18n::trp("{n} QSO", "{n} QSOs", (long long)points[i].second)});
        }
        {  // the busiest point marked, and its value
            size_t best = 0;
            for (size_t i = 1; i < points.size(); ++i)
                if (points[i].second > points[best].second) best = i;
            NSPoint p = at(best);
            if (draw) {
                NSRect dot = NSMakeRect(p.x - 4, p.y - 4, 8, 8);
                [NSColor.windowBackgroundColor setFill];
                [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -2, -2)] fill];
                [blue setFill];
                [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
            }
            text(compact((double)points[best].second), NSMakePoint(p.x, p.y - 20), NSFont.smallSystemFontSize - 1, NSFontWeightMedium, ink, 0);
        }
        text(adif::displayDate(adif::formatAdifDate(first)), NSMakePoint(left, y + plotH + 4), NSFont.smallSystemFontSize - 1, NSFontWeightRegular, quiet, -1);
        text(adif::displayDate(adif::formatAdifDate(last)), NSMakePoint(left + w, y + plotH + 4), NSFont.smallSystemFontSize - 1, NSFontWeightRegular, quiet, 1);
        y += plotH + 22 + 18;
    }

    // ── When: UTC hour by weekday, a heat grid ──
    {
        size_t most = 0;
        for (const auto &day : _s.hourWeekday)
            for (size_t n : day) most = std::max(most, n);
        if (most) {
            heading(adif::i18n::tr("When you were on the air"), dark ? adif::i18n::tr("QSOs by UTC hour and weekday; brighter is more")
                                                                     : adif::i18n::tr("QSOs by UTC hour and weekday; darker is more"));
            static const char *const kDays[] = {N_("Mon##weekday"), N_("Tue##weekday"), N_("Wed##weekday"), N_("Thu##weekday"),
                                                N_("Fri##weekday"), N_("Sat##weekday"), N_("Sun##weekday")};  // "Sun" is also the Sun
            static const char *const kDayNames[] = {N_("Monday"), N_("Tuesday"), N_("Wednesday"), N_("Thursday"), N_("Friday"), N_("Saturday"), N_("Sunday")};
            const CGFloat axis = 40, cellW = std::max<CGFloat>(8, (plotW - axis) / 24), cellH = 18;
            for (size_t d = 0; d < 7; ++d) {
                text(adif::i18n::tr(kDays[d]), NSMakePoint(margin + axis - 6, y + d * cellH + 2), NSFont.smallSystemFontSize - 1, NSFontWeightRegular, quiet, 1);
                for (size_t h = 0; h < 24; ++h) {
                    size_t n = _s.hourWeekday[d][h];
                    NSRect cell = NSMakeRect(margin + axis + h * cellW, y + d * cellH, cellW, cellH);
                    if (draw) {  // a 2-point gap between cells; an empty one a faint neutral that recedes, never the scale's first step
                        (n ? rampColour((double)n / (double)most, dark) : [NSColor.labelColor colorWithAlphaComponent:dark ? 0.06 : 0.05]).set;
                        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(cell, 1, 1) xRadius:2 yRadius:2] fill];
                    }
                    char hours[32];
                    std::snprintf(hours, sizeof hours, "%02zu:00–%02zu:00", h, (h + 1) % 24);
                    _tips.push_back({cell, adif::i18n::tr(kDayNames[d]) + " " + hours + " UTC: " +
                                               adif::i18n::trp("{n} QSO", "{n} QSOs", (long long)n)});
                }
            }
            for (size_t h = 0; h < 24; h += 3) {
                char label[8];
                std::snprintf(label, sizeof label, "%02zu", h);
                text(label, NSMakePoint(margin + axis + h * cellW, y + 7 * cellH + 4), NSFont.smallSystemFontSize - 1, NSFontWeightRegular, quiet, -1);
            }
            y += 7 * cellH + 22 + 18;
        }
    }

    // ── Reached: DXCC entities, US states and grid squares, each on its own scale ──
    if (_s.growth.size() == 1) {  // one day: the numbers, as tiles
        heading(adif::i18n::tr("What you reached"), adif::displayDate(_s.growth.front().day));
        const CGFloat gap = 24, w = (plotW - 2 * gap) / 3;
        const std::pair<std::string, size_t> tiles[] = {{adif::i18n::tr("DXCC entities"), _s.growth.front().dxcc},
                                                        {adif::i18n::tr("US states"), _s.growth.front().states},
                                                        {adif::i18n::tr("Grid squares"), _s.growth.front().grids}};
        for (size_t k = 0; k < 3; ++k) {
            CGFloat x0 = margin + k * (w + gap);
            text(tiles[k].first, NSMakePoint(x0, y), NSFont.smallSystemFontSize, NSFontWeightRegular, quiet, -1);
            text(compact((double)tiles[k].second), NSMakePoint(x0, y + 16), 26, NSFontWeightSemibold, ink, -1);
            _spoken += ". " + tiles[k].first + ": " + compact((double)tiles[k].second);
        }
        y += 16 + 34 + 20;
    } else if (!_s.growth.empty()) {
        heading(adif::i18n::tr("What you reached, over time"), adif::i18n::tr("Each on its own scale"));
        const CGFloat gap = 24, w = (plotW - 2 * gap) / 3, plotH = 80;
        long first = 0, last = 0;
        adif::parseAdifDate(_s.growth.front().day, &first);
        adif::parseAdifDate(_s.growth.back().day, &last);
        struct Small {
            std::string title;
            size_t adif::SummaryStats::Growth::*value;
        };
        const Small smalls[] = {{adif::i18n::tr("DXCC entities"), &adif::SummaryStats::Growth::dxcc},
                                {adif::i18n::tr("US states"), &adif::SummaryStats::Growth::states},
                                {adif::i18n::tr("Grid squares"), &adif::SummaryStats::Growth::grids}};
        CGFloat top0 = y;
        for (size_t k = 0; k < 3; ++k) {
            CGFloat x0 = margin + k * (w + gap), yy = top0;
            size_t end = _s.growth.back().*smalls[k].value;
            text(smalls[k].title, NSMakePoint(x0, yy), NSFont.smallSystemFontSize, NSFontWeightSemibold, ink, -1);
            yy += 20;
            double top = niceMax((double)std::max<size_t>(1, end));
            hairline(x0, x0 + w, yy + plotH);
            auto at = [&](const adif::SummaryStats::Growth &g) {
                long d = 0;
                adif::parseAdifDate(g.day, &d);
                CGFloat x = last > first ? x0 + (w - 30) * (CGFloat)(d - first) / (CGFloat)(last - first) : x0 + (w - 30) / 2;
                return NSMakePoint(x, yy + plotH - plotH * (CGFloat)((double)(g.*smalls[k].value) / top));
            };
            if (draw && _s.growth.size() > 1) {
                NSBezierPath *line = [NSBezierPath bezierPath];
                for (size_t i = 0; i < _s.growth.size(); ++i) {  // a step at each day: the count holds until the next
                    NSPoint p = at(_s.growth[i]);
                    if (i == 0) [line moveToPoint:p];
                    else [line lineToPoint:NSMakePoint(p.x, line.currentPoint.y)], [line lineToPoint:p];
                }
                line.lineWidth = 2;
                line.lineJoinStyle = NSLineJoinStyleRound;
                [blue setStroke];
                [line stroke];
            }
            NSPoint endAt = at(_s.growth.back());
            if (draw) {
                NSRect dot = NSMakeRect(endAt.x - 4, endAt.y - 4, 8, 8);
                [NSColor.windowBackgroundColor setFill];
                [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -2, -2)] fill];
                [blue setFill];
                [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
            }
            text(compact((double)end), NSMakePoint(endAt.x + 7, endAt.y - 8), NSFont.smallSystemFontSize, NSFontWeightSemibold, ink, -1);
            _tips.push_back({NSMakeRect(x0, top0, w, plotH + 20),
                             adif::i18n::trf("{what}: {n} by {date}", {{"what", smalls[k].title},
                                                                        {"n", compact((double)end)},
                                                                        {"date", adif::displayDate(_s.growth.back().day)}})});
            _spoken += ". " + smalls[k].title + ": " + compact((double)end);
        }
        y = top0 + 20 + plotH + 20;
    }
    if (!_s.bands.empty()) {
        auto busiest = std::max_element(_s.bands.begin(), _s.bands.end(), [](const auto &a, const auto &b) { return a.second < b.second; });
        _spoken += ". " + adif::i18n::trp("Most on {band}, {n} QSO", "Most on {band}, {n} QSOs", (long long)busiest->second, {{"band", busiest->first}});
    }
    return y + margin;
}

- (NSData *)pngData {
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
    [self cacheDisplayInRect:self.bounds toBitmapImageRep:rep];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityImageRole;
}

- (NSString *)accessibilityLabel {
    return ADIFString(_spoken) ?: @"";
}

@end
