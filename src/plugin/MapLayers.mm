#import "MapView.h"
#import "L10n.h"

#import "IotaGroups.h"
#import "PluginHost.h"
#import "PotaParks.h"
#import "ToolWindow.h"
#include "adif_geo.h"
#include "adif_worked.h"
#include "adif_regions.h"
#include "adif_sun.h"
#import "Country.h"
#include "adif_spec.h"

#include <algorithm>
#include <cmath>
#include <ctime>
#include <dlfcn.h>
#include <fstream>
#include <set>
#include <sstream>
#include <tuple>

using namespace adifhost;
using namespace mapkit;

@implementation ADIFMapView (Layers)

// The time the sun is drawn for: now, or the selected QSO's (its first, for a square or entity).
- (double)sunSeconds {
    double t = [self qsoSunSeconds];
    return t >= 0 ? t : [[NSDate date] timeIntervalSince1970];
}

// The selected QSO's time, when Sun at is the selected QSO's time and one is selected; else -1.
- (double)qsoSunSeconds {
    const double now = -1;
    if (_style.sunTime != 1) return now;
    const ADIFMapHit &h = _selected;
    std::vector<size_t> qsos;
    if (h.kind == ADIFMapHit::Contact && h.index < _contacts.size()) qsos = _contacts[h.index].qsos;
    else if (h.kind == ADIFMapHit::Square && h.index < _data.squares.size()) qsos = _data.squares[h.index].qsoIndex;
    else if (h.kind == ADIFMapHit::Dxcc && h.index < _entities.size()) qsos = _entities[h.index].qsos;
    else if (h.kind == ADIFMapHit::Park && h.index < _data.parks.size()) qsos = {_data.parks[h.index].qso};
    if (qsos.empty() || qsos[0] >= _data.qsos.size()) return now;
    const adif::MapQso &q = _data.qsos[qsos[0]];
    std::string t;
    for (char c : q.time)
        if (c >= '0' && c <= '9') t += c;
    if (q.date8.size() != 8 || t.size() < 4) return now;
    struct tm tm{};
    tm.tm_year = std::atoi(q.date8.substr(0, 4).c_str()) - 1900, tm.tm_mon = std::atoi(q.date8.substr(4, 2).c_str()) - 1;
    tm.tm_mday = std::atoi(q.date8.substr(6, 2).c_str()), tm.tm_hour = std::atoi(t.substr(0, 2).c_str()), tm.tm_min = std::atoi(t.substr(2, 2).c_str());
    return (double)timegm(&tm);
}

// Day and night: the night side shaded, deeper towards astronomical twilight (the sun 18
// degrees below the horizon), and the grey line, the twilight band from sunset until the sun is
// 6 degrees down (civil twilight), tinted gold. Drawn as an image of the view at a quarter of its
// size, each pixel by the sun's height there (adif_sun), so it fits every projection.
- (void)drawDayNight:(MapDrawCtx &)d {
    if (!_style.dayNight && !_style.greyLine) return;
    NSRect b = d.b;
    double t = [self sunSeconds];
    adif::SunPosition sun = adif::sunAt(t);
    const int step = 4;
    size_t w = (size_t)std::ceil(b.size.width / step), h = (size_t)std::ceil(b.size.height / step);
    std::vector<uint8_t> px(w * h * 4, 0);
    for (size_t y = 0; y < h; ++y)
        for (size_t x = 0; x < w; ++x) {
            double lon, lat;
            NSPoint p = NSMakePoint(NSMinX(b) + (x + 0.5) * step, NSMaxY(b) - (y + 0.5) * step);
            if (![self lonLatAt:p lon:&lon lat:&lat]) continue;
            double e = adif::solarElevation(sun, lat, lon);
            double dark = 0, gold = 0;
            if (_style.dayNight && e < 0) dark = 0.6 * std::min(1.0, -e / 18.0);  // black, up to 60% at 18 degrees down
            if (_style.greyLine && e < 0.8 && e > -6) gold = 0.32 * (1 - std::fabs(e + 2.6) / 3.4);
            gold = std::max(0.0, gold);
            // Premultiplied RGBA: black for the night, gold (0xFFB340) for the grey line, over each other.
            double a = gold + dark * (1 - gold);
            uint8_t *o = &px[(y * w + x) * 4];
            o[0] = (uint8_t)std::lround(255 * gold * 1.0), o[1] = (uint8_t)std::lround(255 * gold * 0.70), o[2] = (uint8_t)std::lround(255 * gold * 0.25);
            o[3] = (uint8_t)std::lround(255 * std::min(1.0, a));
        }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast);
    CGImageRef image = bitmap ? CGBitmapContextCreateImage(bitmap) : nullptr;
    if (image) {
        CGContextSetInterpolationQuality(d.ctx, kCGInterpolationHigh);
        CGContextDrawImage(d.ctx, CGRectMake(NSMinX(b), NSMaxY(b) - h * step, w * step, h * step), image);
        CGImageRelease(image);
    }
    if (bitmap) CGContextRelease(bitmap);
    CGColorSpaceRelease(space);
    // The terminator, and the sun where it is overhead.
    if (_style.dayNight) {
        std::vector<std::pair<double, double>> edge = adif::sunCircle(sun, 0, 2);
        edge.push_back(edge.front());
        NSBezierPath *line = [self viewPath:edge close:NO wraps:YES];
        line.lineWidth = 1;
        [[NSColor colorWithCalibratedWhite:d.ink alpha:0.4] setStroke];
        [line stroke];
    }
    NSPoint s = [self viewPointForLon:sun.subLon lat:sun.subLat];
    if (NSPointInRect(s, NSInsetRect(b, -10, -10))) {
        NSBezierPath *disc = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(s.x - 5, s.y - 5, 10, 10)];
        NSBezierPath *rays = [NSBezierPath bezierPath];
        for (int k = 0; k < 8; ++k) {
            double a = k * M_PI / 4;
            [rays moveToPoint:NSMakePoint(s.x + 7 * std::cos(a), s.y + 7 * std::sin(a))];
            [rays lineToPoint:NSMakePoint(s.x + 11 * std::cos(a), s.y + 11 * std::sin(a))];
        }
        [rgb(0xFFC83D) setFill];
        [disc fill];
        rays.lineWidth = 1.5;
        [rgb(0xFFC83D) setStroke];
        [rays stroke];
    }
}

// The areas worked: each CQ and ITU zone, US state and county in the log, shaded in the map's
// colours, the most particular on top (zones, then states, then counties).
- (void)drawWorkedAreas:(MapDrawCtx &)d {
    NSRect b = d.b;
    for (MapLayerId l : {kLayerCq, kLayerItu, kLayerStates, kLayerCounties}) {
        if (!_style[l].show) continue;
        const adif::AreaIndex &index = adif::areaIndex(layerOverlay(l));
        for (const auto &[name, qsos] : _areaQsos[l]) {
            size_t i = index.byName(name);
            if (i == adif::AreaIndex::npos) continue;
            NSBezierPath *region = [NSBezierPath bezierPath];
            for (const auto &ring : index.area(i).rings) [region appendBezierPath:[self viewPath:ring close:YES wraps:NO]];
            if (region.isEmpty || !NSIntersectsRect(region.bounds, b)) continue;
            NSColor *c = [self colorFor:_areaAgg[l][name] entity:NO];
            bool lit = false;
            for (const ADIFMapHit *h : {&_hover, &_selected}) lit = lit || (h->kind == ADIFMapHit::Area && h->layer == l && h->index == i);
            region.windingRule = NSWindingRuleEvenOdd;
            static const CGFloat kShade[] = {0.22, 0.38, 0.55};
            [[c colorWithAlphaComponent:lit ? 0.62 : kShade[std::clamp(_style.areaShade, 0, 2)]] setFill];
            [region fill];
            region.lineWidth = lit ? 2 : 0.8;
            region.lineJoinStyle = NSLineJoinStyleRound;
            [[c colorWithAlphaComponent:0.9] setStroke];
            [region stroke];
        }
    }
}

- (size_t)workedAreaAt:(MapLayerId)layer lon:(double)lon lat:(double)lat {
    const adif::AreaIndex &index = adif::areaIndex(layerOverlay(layer));
    size_t i = index.at(lon, lat);
    if (i == adif::AreaIndex::npos || !_areaQsos[layer].count(index.area(i).name)) return adif::AreaIndex::npos;
    return i;
}

// The world: ocean, clipped to its outline; then land, lakes, rivers and borders on the plane.
// Leaves two states saved, the view's bounds and the world's outline, which drawRect restores.
- (void)drawBase:(MapDrawCtx &)d {
    NSRect b = self.bounds;
    const MapPalette &pal = paletteAt(_style.palette);
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    // Views don't clip their drawing to their bounds since macOS 14: zoomed in, the
    // world would paint over the controls above and the list below.
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, NSRectToCGRect(b));
    setFill(ctx, pal.background);
    CGContextFillRect(ctx, NSRectToCGRect(b));
    double ppu = [self ppu];
    CGFloat ink = pal.dark ? 1 : 0;
    NSBezierPath *world = [NSBezierPath bezierPath];
    std::vector<std::pair<double, double>> outline = _pr.outline();
    for (size_t i = 0; i < outline.size(); ++i) {
        NSPoint v = [self planeToView:outline[i].first y:outline[i].second];
        if (i == 0) [world moveToPoint:v];
        else [world lineToPoint:v];
    }
    [world closePath];
    CGContextSaveGState(ctx);
    bool globe = [self globe];
    NSPoint middle = [self planeToView:0 y:0];
    double radius = 180 / M_PI * ppu;  // the globe's, in points
    if (globe) {  // a thin glow of air round it
        NSGradient *air = [[NSGradient alloc] initWithColors:@[ rgb(pal.river, pal.dark ? 0.45 : 0.35), rgb(pal.river, 0) ]];
        [air drawFromCenter:middle radius:radius toCenter:middle radius:radius * 1.07 options:0];
    }
    [rgb(pal.ocean) setFill];
    [world fill];
    [world addClip];
    if (globe) {  // lit from the upper left
        NSColor *sea = rgb(pal.ocean);
        NSGradient *light = [[NSGradient alloc] initWithColors:@[ [sea blendedColorWithFraction:0.22 ofColor:NSColor.whiteColor], sea,
                                                                  [sea blendedColorWithFraction:0.3 ofColor:NSColor.blackColor] ]];
        [light drawFromCenter:NSMakePoint(middle.x - radius * 0.35, middle.y + radius * 0.35) radius:0 toCenter:middle radius:radius options:0];
    }
    double west, south, east, north;  // the longitudes and latitudes in view
    [self visibleWest:&west south:&south east:&east north:&north];
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, NSMidX(b) - _cx * ppu, NSMidY(b) - _cy * ppu);
    CGContextScaleCTM(ctx, ppu, ppu);
    if (_zoom >= kDetailZoom && !mapDetail().empty()) {
        // Zoomed in: the 1:10m detail, only the shapes in view (with a margin).
        double w = west - 1, s = south - 1, e = east + 1, n = north + 1, web = webZoom(_zoom);
        auto all = [](int) { return true; };
        auto draw = [&](adif::DetailLayer l, bool polygons, const std::function<bool(int)> &keep) {
            CGMutablePathRef path = detailPath(_pr, l, polygons, w, s, e, n, keep);
            CGContextAddPath(ctx, path);
            CGPathRelease(path);
        };
        setFill(ctx, pal.land);
        draw(adif::DetailLayer::Land, true, all);
        CGContextEOFillPath(ctx);
        // Towns and cities, a little lighter than the land around them.
        CGContextSetFillColorWithColor(ctx, [rgb(pal.land) blendedColorWithFraction:pal.dark ? 0.14 : 0.18 ofColor:pal.dark ? NSColor.whiteColor : NSColor.grayColor].CGColor);
        draw(adif::DetailLayer::Urban, true, all);
        CGContextFillPath(ctx);
        setFill(ctx, pal.ocean);
        draw(adif::DetailLayer::Lakes, true, all);
        CGContextEOFillPath(ctx);
        setStroke(ctx, pal.river, 0.85);
        CGContextSetLineWidth(ctx, 1.0 / ppu);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        draw(adif::DetailLayer::Rivers, false, [&](int rank) { return rank <= (web < 6 ? 6 : 12); });
        CGContextStrokePath(ctx);
        CGFloat dash[] = {(CGFloat)(3 / ppu), (CGFloat)(2 / ppu)};
        CGContextSetLineDash(ctx, 0, dash, 2);
        setStroke(ctx, pal.border, 0.45);
        CGContextSetLineWidth(ctx, 0.6 / ppu);
        draw(adif::DetailLayer::States, false, [&](int rank) { return rank <= (web + 1.5) * 10; });
        CGContextStrokePath(ctx);
        CGContextSetLineDash(ctx, 0, nullptr, 0);
        setStroke(ctx, pal.border, 0.7);
        CGContextSetLineWidth(ctx, 1.0 / ppu);
        draw(adif::DetailLayer::Borders, false, all);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    } else {  // the 1:110m and 1:50m maps
        bool fine = _zoom >= 3;
        setFill(ctx, pal.land);
        CGContextAddPath(ctx, projectedLayer(_pr, fine ? adif::MapLayer::Land50 : adif::MapLayer::Land110));
        CGContextEOFillPath(ctx);
        setFill(ctx, pal.ocean);  // lakes: the ocean's colour; their islands stay land
        CGContextAddPath(ctx, projectedLayer(_pr, fine ? adif::MapLayer::Lakes50 : adif::MapLayer::Lakes110));
        CGContextEOFillPath(ctx);
        setStroke(ctx, pal.river, 0.85);
        CGContextSetLineWidth(ctx, (_zoom >= 8 ? 1.0 : 0.7) / ppu);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextAddPath(ctx, projectedLayer(_pr, adif::MapLayer::Rivers50, _zoom < 2 ? 2 : _zoom < 4 ? 4 : 6));
        CGContextStrokePath(ctx);
        if (_zoom >= 2.5) {  // states and provinces: US, Canada, Australia, Russia...
            CGFloat dash[] = {(CGFloat)(3 / ppu), (CGFloat)(2 / ppu)};
            CGContextSetLineDash(ctx, 0, dash, 2);
            setStroke(ctx, pal.border, 0.4);
            CGContextSetLineWidth(ctx, 0.5 / ppu);
            CGContextAddPath(ctx, projectedLayer(_pr, adif::MapLayer::States50));
            CGContextStrokePath(ctx);
            CGContextSetLineDash(ctx, 0, nullptr, 0);
        }
        setStroke(ctx, pal.border, _zoom >= 2 ? 0.6 : 0.35);
        CGContextSetLineWidth(ctx, (_zoom >= 4 ? 0.9 : 0.6) / ppu);
        CGContextAddPath(ctx, projectedLayer(_pr, adif::MapLayer::Borders50));
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }
    if (globe) {  // the edge turns away into shadow, so the globe looks round
        NSGradient *edge = [[NSGradient alloc] initWithColors:@[ [NSColor colorWithCalibratedWhite:0 alpha:0], [NSColor colorWithCalibratedWhite:0 alpha:pal.dark ? 0.38 : 0.18] ]];
        [edge drawFromCenter:middle radius:radius * 0.72 toCenter:middle radius:radius options:0];
    }
    d.ctx = ctx, d.b = b, d.pal = &pal, d.ink = ink, d.ppu = ppu, d.world = world, d.globe = globe;
    d.west = west, d.south = south, d.east = east, d.north = north;

    double clon = 0, clat = 0;
    [self lonLatAt:NSMakePoint(NSMidX(b), NSMidY(b)) lon:&clon lat:&clat];
    d.squareW = [self pixelsForLon:clon lat:clat span:2], d.fieldW = d.squareW * 10;
    d.curved = _pr.kind() != adif::Projection::Equirectangular;

}

    // Maidenhead fields (20 x 10 degrees), and squares (2 x 1) when they are big enough to see.
- (void)drawGridLines:(MapDrawCtx &)d {
    CGFloat ink = d.ink;
    bool curved = d.curved;
    double west = d.west, south = d.south, east = d.east, north = d.north;
    double squareW = d.squareW;
    if (_style[kLayerSquares].overlay) {
        NSBezierPath *grid = [NSBezierPath bezierPath];
        double step = curved ? 2 : 180;
        for (int lon = -180; lon <= 180; lon += 20) {
            std::vector<std::pair<double, double>> line;
            for (double lat = -90; lat <= 90 + 1e-9; lat += step) line.emplace_back(lon, lat);
            [grid appendBezierPath:[self viewPath:line close:NO wraps:NO]];
        }
        for (int lat = -90; lat <= 90; lat += 10) {
            std::vector<std::pair<double, double>> line;
            for (double lon = -180; lon <= 180 + 1e-9; lon += curved ? 2 : 360) line.emplace_back(lon, lat);
            [grid appendBezierPath:[self viewPath:line close:NO wraps:NO]];
        }
        grid.lineWidth = 0.6;
        [[NSColor colorWithCalibratedWhite:ink alpha:0.18] setStroke];
        [grid stroke];
        if (squareW >= 12) {
            NSBezierPath *fineGrid = [NSBezierPath bezierPath];
            for (double lon = std::floor(west / 2) * 2; lon <= east; lon += 2) {
                std::vector<std::pair<double, double>> line;
                for (double lat = south; lat <= north + 1e-9; lat += curved ? 0.5 : north - south) line.emplace_back(lon, lat);
                [fineGrid appendBezierPath:[self viewPath:line close:NO wraps:NO]];
            }
            for (double lat = std::floor(south); lat <= north; lat += 1) {
                std::vector<std::pair<double, double>> line;
                for (double lon = west; lon <= east + 1e-9; lon += curved ? 1 : east - west) line.emplace_back(lon, lat);
                [fineGrid appendBezierPath:[self viewPath:line close:NO wraps:NO]];
            }
            fineGrid.lineWidth = 0.4;
            [[NSColor colorWithCalibratedWhite:ink alpha:0.08] setStroke];
            [fineGrid stroke];
        }
    }
}

    // DXCC: each worked entity's own land, shaded (Alaska and Hawaii apart from the United
    // States, Sardinia from Italy: adif::dxccRings). One with no land at this scale, or whose
    // land is too small on screen to see, is a dot, drawn further down.
- (void)drawDxccLand:(MapDrawCtx &)d {
    NSRect b = d.b;
    _entityDot.assign(_entities.size(), true);
    if (_style[kLayerCountries].show) {
        const OverlayCache &land = overlay(adif::Overlay::Subunits);
        for (size_t i = 0; i < _entities.size(); ++i) {
            const ADIFMapEntity &e = _entities[i];
            if (e.land.empty()) continue;
            NSBezierPath *region = [NSBezierPath bezierPath];
            for (const adif::RingRef &ref : e.land)
                if (ref.area < land.areas.size() && ref.ring < land.areas[ref.area].rings.size())
                    [region appendBezierPath:[self viewPath:land.areas[ref.area].rings[ref.ring] close:YES wraps:NO]];
            if (region.isEmpty) continue;  // behind the globe
            NSRect r = region.bounds;
            if (std::max(r.size.width, r.size.height) < 9) continue;  // a speck: the dot shows it
            _entityDot[i] = false;
            if (!NSIntersectsRect(r, b)) continue;
            NSColor *c = [self colorFor:_entityAgg[i] entity:YES];
            bool lit = (_hover.kind == ADIFMapHit::Dxcc && _hover.index == i) || (_selected.kind == ADIFMapHit::Dxcc && _selected.index == i);
            region.windingRule = NSWindingRuleEvenOdd;  // a country inside another (Lesotho) stays out
            static const CGFloat kShade[] = {0.25, 0.42, 0.6};
            [[c colorWithAlphaComponent:lit ? 0.62 : kShade[std::clamp(_style.areaShade, 0, 2)]] setFill];
            [region fill];
            region.lineWidth = lit ? 2 : 1;
            region.lineJoinStyle = NSLineJoinStyleRound;
            [[c colorWithAlphaComponent:0.95] setStroke];
            [region stroke];
        }
    }
}

    // Overlays: countries, US states, ITU zones and CQ zones, outlined, each named (when its
    // Labels box is ticked) where its name fits inside it on screen.
- (void)drawOverlays:(MapDrawCtx &)d {
    NSRect b = d.b;
    const MapPalette &pal = *d.pal;
    CGFloat ink = d.ink;
    struct OverlayStyle {
        bool on, names;
        adif::Overlay which;
        NSColor *color;
        CGFloat width, labelSize, minPixels;
    };
    const OverlayStyle overlayStyles[] = {
        {_style[kLayerCountries].overlay, _style[kLayerCountries].labels, adif::Overlay::Countries, [NSColor colorWithCalibratedWhite:ink alpha:0.6], 0.8, 10, 24},
        {_style[kLayerStates].overlay, _style[kLayerStates].labels, adif::Overlay::UsStates, [NSColor colorWithCalibratedWhite:ink alpha:0.5], 0.7, 10, 26},
        {_style[kLayerItu].overlay, _style[kLayerItu].labels, adif::Overlay::ItuZones, pal.dark ? rgb(0x4FC3F7, 0.75) : rgb(0x0277BD, 0.8), 1.0, 12, 30},
        {_style[kLayerCq].overlay, _style[kLayerCq].labels, adif::Overlay::CqZones, pal.dark ? rgb(0xFFB74D, 0.8) : rgb(0xE65100, 0.8), 1.4, 14, 30},
        // US counties from 2.5x: the whole world would be a grey mesh.
        {_style[kLayerCounties].overlay && _zoom >= 2.5, _style[kLayerCounties].labels, adif::Overlay::UsCounties, [NSColor colorWithCalibratedWhite:ink alpha:0.38], 0.5, 9, 34},
    };
    // City names come before county names (Milwaukee the city, not the county, by its dot): with
    // both shown, the counties' names wait for the cities and go only where they're clear of them.
    d.countiesAfterCities = _style[kLayerCities].overlay && _style[kLayerCities].labels && !mapDetail().empty();
    for (const OverlayStyle &os : overlayStyles) {
        if (!os.on) continue;
        const OverlayCache &oc = overlay(os.which);
        NSBezierPath *lines = [NSBezierPath bezierPath];
        for (const adif::OverlayArea &a : oc.areas) [lines appendBezierPath:[self outlineOf:a]];
        lines.lineWidth = os.width;
        lines.lineJoinStyle = NSLineJoinStyleRound;
        [os.color setStroke];
        [lines stroke];
        if (!os.names) continue;
        NSDictionary *attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:os.labelSize weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName : [os.color colorWithAlphaComponent:0.95]};
        for (size_t i = 0; i < oc.areas.size(); ++i) {
            const adif::OverlayArea &a = oc.areas[i];
            NSPoint p = [self viewPointForLon:a.labelLon lat:a.labelLat];
            if (!NSPointInRect(p, NSInsetRect(b, -20, -10))) continue;
            double wide = [self pixelsForLon:a.labelLon lat:a.labelLat span:std::min(oc.span[i].first, 60.0)];
            // A county is named "WI,Dane" (as CNTY writes it); its label is the name.
            NSString *name = ADIFString(os.which == adif::Overlay::UsCounties ? a.name.substr(a.name.find(',') + 1) : a.name);
            NSSize sz = [name sizeWithAttributes:attrs];
            if (wide < std::max((double)os.minPixels, sz.width + 6)) continue;  // too small on screen for its name
            NSRect r = NSMakeRect(p.x - sz.width / 2, p.y - sz.height / 2, sz.width, sz.height);
            if (os.which == adif::Overlay::UsCounties && d.countiesAfterCities) {
                d.countyNames.emplace_back(name, r);
                d.countyAttrs = attrs;
                continue;
            }
            [name drawAtPoint:r.origin withAttributes:attrs];
        }
    }
}

// IOTA: IOTA's island groups (downloaded in Settings), each the box of longitude and latitude
// IOTA gives it. Show: the groups in the log, filled (more strongly when confirmed). Overlay: the
// rest, dashed. Each named by its reference where there's room, the log's groups first, and with
// its name too where the box is wide enough.
- (void)drawIota:(MapDrawCtx &)d {
    NSRect b = d.b;
    const MapPalette &pal = *d.pal;
    double south = d.south, north = d.north;
    bool showWorked = _style[kLayerIota].show, showOthers = _style[kLayerIota].overlay;
    if (showWorked || showOthers) {
        const std::vector<adif::IotaGroup> &groups = ADIFIotaGroups();
        NSColor *tint = pal.dark ? rgb(0x4DD0E1) : rgb(0x00838F);
        NSBezierPath *unworked = [NSBezierPath bezierPath];
        std::vector<std::pair<size_t, NSRect>> shown;  // group, where its name goes (its larger box in view): worked first
        size_t worked = 0;
        for (size_t i = 0; i < groups.size(); ++i) {
            const adif::IotaGroup &g = groups[i];
            if (g.north < south || g.south > north) continue;
            auto it = _iotaQsos.find(g.ref);
            if (!(it == _iotaQsos.end() ? showOthers : showWorked)) continue;
            NSBezierPath *box = [NSBezierPath bezierPath];
            NSRect named = NSZeroRect;  // across the 180th meridian a group is two boxes, at the map's two edges
            for (const std::array<double, 4> &piece : adif::iotaBoxes(g)) {
                NSBezierPath *p = [self iotaBoxPath:piece];
                if (p.isEmpty) continue;
                [box appendBezierPath:p];
                NSRect r = NSIntersectionRect(p.bounds, b);
                if (r.size.width * r.size.height > named.size.width * named.size.height) named = r;
            }
            if (NSIsEmptyRect(named)) continue;
            if (it == _iotaQsos.end()) {
                [unworked appendBezierPath:box];
                shown.emplace_back(i, named);
                continue;
            }
            bool confirmed = false;
            for (size_t qi : it->second) confirmed |= _data.qsos[qi].confirmed;
            bool lit = (_hover.kind == ADIFMapHit::Iota && _hover.index == i) || (_selected.kind == ADIFMapHit::Iota && _selected.index == i);
            [[tint colorWithAlphaComponent:(confirmed ? 0.42 : 0.22) + (lit ? 0.15 : 0)] setFill];
            [box fill];
            box.lineWidth = lit ? 2 : 1.2;
            [[tint colorWithAlphaComponent:0.95] setStroke];
            [box stroke];
            shown.insert(shown.begin() + (long)worked++, {i, named});
        }
        unworked.lineWidth = 0.8;
        CGFloat dash[] = {4, 3};
        [unworked setLineDash:dash count:2 phase:0];
        [[tint colorWithAlphaComponent:0.75] setStroke];
        [unworked stroke];
        if (_style[kLayerIota].labels) {
            NSShadow *halo = [[NSShadow alloc] init];
            halo.shadowColor = [NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.9];
            halo.shadowBlurRadius = 2;
            NSDictionary *attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                                    NSForegroundColorAttributeName : [tint colorWithAlphaComponent:0.95], NSShadowAttributeName : halo};
            std::vector<NSRect> taken;
            for (size_t k = 0; k < shown.size(); ++k) {
                const adif::IotaGroup &g = groups[shown[k].first];
                NSRect box = shown[k].second;
                NSString *ref = ADIFString(g.ref), *full = ADIFString(g.ref + " " + g.name);
                NSSize sz = [full sizeWithAttributes:attrs];
                NSString *text = sz.width + 6 <= box.size.width ? full : ref;
                sz = [text sizeWithAttributes:attrs];
                if (k >= worked && sz.width + 6 > box.size.width) continue;  // an unworked group too small on screen for its name
                NSRect r = NSMakeRect(NSMidX(box) - sz.width / 2, NSMidY(box) - sz.height / 2, sz.width, sz.height);
                bool clear = true;
                for (const NSRect &t : taken) clear &= !NSIntersectsRect(NSInsetRect(t, -3, -1), r);
                if (!clear) continue;
                [text drawAtPoint:r.origin withAttributes:attrs];
                taken.push_back(r);
            }
        }
    }
}

    // Cities: Natural Earth's 7,300, more as you zoom in (each from its own zoom), the most
    // populous first, each name only where it doesn't run into another.
- (void)drawCities:(MapDrawCtx &)d {
    NSRect b = d.b;
    const MapPalette &pal = *d.pal;
    CGFloat ink = d.ink;
    double south = d.south, north = d.north;
    if (_style[kLayerCities].overlay && !mapDetail().empty()) {
        double web = webZoom(_zoom);
        NSShadow *halo = [[NSShadow alloc] init];
        halo.shadowColor = [NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.9];
        halo.shadowBlurRadius = 2.5;
        NSDictionary *attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
                                NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:ink alpha:0.92], NSShadowAttributeName : halo};
        size_t shown = 0;
        for (const adif::DetailCity &c : mapDetail().cities()) {
            if (c.minZoom > web + 0.5 || c.lat < south - 1 || c.lat > north + 1) continue;
            NSPoint p = [self viewPointForLon:c.lon lat:c.lat];
            if (!NSPointInRect(p, NSInsetRect(b, -4, -4))) continue;
            NSRect dotRect = NSMakeRect(p.x - 2.2, p.y - 2.2, 4.4, 4.4);
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:dotRect];
            [[NSColor colorWithCalibratedWhite:ink alpha:0.9] setFill];
            [dot fill];
            [[NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.8] setStroke];
            dot.lineWidth = 0.8;
            [dot stroke];
            if (_style[kLayerCities].labels) {
                NSString *name = ADIFString(c.name);
                NSSize sz = [name sizeWithAttributes:attrs];
                NSRect r = NSMakeRect(p.x + 4, p.y - sz.height / 2, sz.width, sz.height);
                bool clear = true;
                for (const NSRect &t : d.taken) clear &= !NSIntersectsRect(NSInsetRect(t, -2, -1), r);
                if (clear) {
                    [name drawAtPoint:r.origin withAttributes:attrs];
                    d.taken.push_back(r);
                }
            }
            if (d.countiesAfterCities) d.taken.push_back(dotRect);
            if (++shown > 800) break;
        }
    }
    for (const auto &[name, r] : d.countyNames) {
        bool clear = true;
        for (const NSRect &t : d.taken) clear &= !NSIntersectsRect(NSInsetRect(t, -2, -1), r);
        if (clear) [name drawAtPoint:r.origin withAttributes:d.countyAttrs];
    }
}

    // Lines to contacts: from your station (the QSO's MY_GRIDSQUARE, else home) to the contact
    // (its LAT and LON, else its GRIDSQUARE, else its DXCC entity's centre), along great
    // circles; each pair once, coloured as the map colours. On the globe they can arch over
    // it: an arch rises with the distance and leans to one side, so it reads as an arch from
    // above your station too, where a great circle is a straight line. Arches show past the
    // globe's edge, so they are drawn outside the world's clip.
- (void)drawLines:(MapDrawCtx &)d {
    CGContextRef ctx = d.ctx;
    bool globe = d.globe;
    bool arched = globe && _style.arcs;
    if (_style.paths && arched) CGContextRestoreGState(ctx);
    if (_style.paths) {
        std::map<size_t, size_t> entityOf, squareOf, contactOf;  // QSO -> entity, square, contact
        for (size_t e = 0; e < _entities.size(); ++e)
            for (size_t qi : _entities[e].qsos) entityOf[qi] = e;
        for (size_t c = 0; c < _contacts.size(); ++c)
            for (size_t qi : _contacts[c].qsos) contactOf[qi] = c;
        for (size_t s = 0; s < _data.squares.size(); ++s)
            for (size_t qi : _data.squares[s].qsoIndex) squareOf.emplace(qi, s);
        std::set<std::tuple<long, long, long, long>> drawn;
        for (size_t qi = 0; qi < _data.qsos.size(); ++qi) {
            const adif::MapQso &q = _data.qsos[qi];
            double flat = _homeLat, flon = _homeLon, tlat = 0, tlon = 0;
            if (q.myGrid.size() >= 4 && !adif::isPlaceholderGrid(q.myGrid)) {
                if (!adif::gridToLatLon(q.myGrid, &flat, &flon)) continue;
            } else if (!_hasHome) {
                continue;
            }
            if (q.located) {
                tlat = q.lat, tlon = q.lon;
            } else if (adif::isPlaceholderGrid(q.grid) || !adif::gridToLatLon(q.grid, &tlat, &tlon)) {
                auto e = entityOf.find(qi);
                if (e == entityOf.end()) continue;
                tlat = _entities[e->second].lat, tlon = _entities[e->second].lon;
            }
            if (!drawn.insert({std::lround(flat * 100), std::lround(flon * 100), std::lround(tlat * 100), std::lround(tlon * 100)}).second) continue;
            // The line takes the colour of the marker at its far end: the contact's pin, else its
            // square, else its entity's dot.
            NSColor *colour = nil;
            if (auto c = contactOf.find(qi); q.located && c != contactOf.end()) colour = [self colorFor:_contactAgg[c->second] entity:NO];
            else if (auto sq = squareOf.find(qi); sq != squareOf.end()) colour = [self colorFor:_squareAgg[sq->second] entity:NO];
            else if (auto e = entityOf.find(qi); e != entityOf.end()) colour = [self colorFor:_entityAgg[e->second] entity:YES];
            else colour = [self colorFor:[self aggregate:{qi}] entity:NO];
            NSBezierPath *path = nil;
            if (arched) {
                double arc = adif::greatCircleKm(flat, flon, tlat, tlon) / 6371.0;  // radians
                path = [NSBezierPath bezierPath];
                for (const adif::ShapePiece &piece :
                     adif::projectSpace(_pr, adif::archedPath(flat, flon, tlat, tlon, std::min(0.28, 0.2 * arc), 30, 2)))
                    for (size_t k = 0; k < piece.pts.size(); ++k) {
                        NSPoint v = [self planeToView:piece.pts[k].first y:piece.pts[k].second];
                        if (k == 0) [path moveToPoint:v];
                        else [path lineToPoint:v];
                    }
            } else {
                path = [self viewPath:adif::greatCirclePath(flat, flon, tlat, tlon, 3) close:NO wraps:YES];
            }
            [self styleLine:path];
            path.lineJoinStyle = NSLineJoinStyleRound;
            static const CGFloat kStrength[] = {0.35, 0.65, 0.95};
            [[colour colorWithAlphaComponent:kStrength[std::clamp(_style.lineOpacity, 0, 2)]] setStroke];
            [path stroke];
        }
    }
    if (_style.paths && arched) {  // back inside the world for the rest
        CGContextSaveGState(ctx);
        [d.world addClip];
    }
}

    // Worked squares.
- (void)drawSquares:(MapDrawCtx &)d {
    NSRect b = d.b;
    const MapPalette &pal = *d.pal;
    if (_style[kLayerSquares].show) {
        CGFloat alpha = _style.fill == 1 ? 0.45 : 0.85;
        for (size_t i = 0; i < _data.squares.size(); ++i) {
            NSBezierPath *cell = [self squarePath:_data.squares[i].grid];
            if (!cell || cell.isEmpty) continue;
            NSRect r = cell.bounds;
            if (!NSIntersectsRect(NSInsetRect(r, -2, -2), b)) continue;
            NSColor *c = [self colorFor:_squareAgg[i] entity:NO];
            if (r.size.width < 2) {  // the whole world: at least a dot
                [[c colorWithAlphaComponent:alpha] setFill];
                NSRectFill(NSMakeRect(NSMidX(r) - 1, NSMidY(r) - 1, 2, 2));
            } else if (_style.fill == 2) {
                cell.lineWidth = 1.5;
                [c setStroke];
                [cell stroke];
            } else {
                [[c colorWithAlphaComponent:alpha] setFill];
                [cell fill];
                if (pal.dark && darkColour(c)) {  // a dark square (60m's navy) needs an edge on a dark map
                    cell.lineWidth = 1;
                    [[NSColor colorWithCalibratedWhite:1 alpha:0.5] setStroke];
                    [cell stroke];
                }
            }
        }
    }
}

    // Field and square names, once there is room for them.
- (void)drawGridLabels:(MapDrawCtx &)d {
    NSRect b = d.b;
    bool curved = d.curved;
    double west = d.west, south = d.south, east = d.east, north = d.north;
    double squareW = d.squareW;
    double fieldW = d.fieldW;
    if (_style[kLayerSquares].overlay && _style[kLayerSquares].labels) {
        if (fieldW >= 44 && squareW < 36)
            for (int fx = 0; fx < 18; ++fx)
                for (int fy = 0; fy < 18; ++fy) {
                    double lon = -180 + fx * 20 + 10, lat = -90 + fy * 10 + 5;
                    if (lon + 10 < west || lon - 10 > east || lat + 5 < south || lat - 5 > north) continue;
                    NSPoint p = [self viewPointForLon:lon lat:lat];
                    double w = curved ? [self pixelsForLon:lon lat:lat span:20] : fieldW;
                    NSPoint top = [self viewPointForLon:lon lat:lat + 5], bottom = [self viewPointForLon:lon lat:lat - 5];
                    double tall = std::hypot(top.x - bottom.x, top.y - bottom.y);  // fields near Equal Earth's poles get thin
                    if (!NSPointInRect(p, NSInsetRect(b, -40, -20)) || w < 30 || tall < 16) continue;
                    [self drawLabel:[NSString stringWithFormat:@"%c%c", 'A' + fx, 'A' + fy] at:p size:std::min(16.0, w / 6) alpha:0.35];
                }
        if (squareW >= 36)
            for (double lon = std::floor(west / 2) * 2; lon < east; lon += 2)
                for (double lat = std::floor(south); lat < north; lat += 1) {
                    std::string sq = adif::squareAt(lon + 1, lat + 0.5);
                    NSPoint p = [self viewPointForLon:lon + 1 lat:lat + 0.5];
                    if (sq.empty() || !NSPointInRect(p, NSInsetRect(b, -30, -15))) continue;
                    [self drawLabel:@(sq.c_str()) at:p size:std::min(13.0, squareW / 6) alpha:0.32];
                }
    }
}

    // Distance rings around home (and bearings on the globe, when it is centred there).
- (void)drawRings:(MapDrawCtx &)d {
    NSRect b = d.b;
    CGFloat ink = d.ink;
    bool globe = d.globe;
    double ppu = d.ppu;
    if (_style.rings && _hasHome) {
        double step = _zoom < 3 ? 2500 : _zoom < 8 ? 1000 : 500;
        NSBezierPath *rings = [NSBezierPath bezierPath];
        for (double km = step; km < 20000; km += step) {
            std::vector<std::pair<double, double>> ring;
            for (int a = 0; a <= 360; a += 2) {
                double la, lo;
                adif::destinationPoint(_homeLat, _homeLon, a, km, &la, &lo);
                ring.emplace_back(lo, la);
            }
            [rings appendBezierPath:[self viewPath:ring close:NO wraps:YES]];
            // The distance where the ring crosses north of home, beside the N spoke rather than on it.
            double la, lo, x, y;
            adif::destinationPoint(_homeLat, _homeLon, 0, km, &la, &lo);
            if (!_pr.forward(lo, la, &x, &y) || (globe && std::hypot(x, y) > 180 / M_PI - 30 / ppu)) continue;  // behind, or cut by the rim
            NSPoint p = [self planeToView:x y:y];
            if (NSPointInRect(p, b))
                [self drawLabel:[NSString stringWithFormat:T(@"%.0f km"), km] at:NSMakePoint(p.x + 30, p.y + 7) size:10 alpha:0.55];
        }
        CGFloat dash[] = {4, 3};
        [rings setLineDash:dash count:2 phase:0];
        rings.lineWidth = 0.8;
        [[NSColor colorWithCalibratedWhite:ink alpha:0.35] setStroke];
        [rings stroke];
        if (globe && [self atHome]) {  // great circles through the centre are straight lines on the globe
            NSBezierPath *spokes = [NSBezierPath bezierPath];
            double rim = 180 / M_PI;
            for (int a = 0; a < 360; a += 30) {
                double s = std::sin(a * M_PI / 180), c = std::cos(a * M_PI / 180);
                [spokes moveToPoint:[self planeToView:0 y:0]];
                [spokes lineToPoint:[self planeToView:rim * s y:rim * c]];
                NSString *name = a == 0 ? @"N" : a == 90 ? @"E" : a == 180 ? @"S" : a == 270 ? @"W" : [NSString stringWithFormat:@"%d°", a];
                NSPoint p = [self planeToView:rim * 0.93 * s y:rim * 0.93 * c];
                if (NSPointInRect(p, b)) [self drawLabel:name at:p size:11 alpha:0.6];
            }
            spokes.lineWidth = 0.5;
            [[NSColor colorWithCalibratedWhite:ink alpha:0.22] setStroke];
            [spokes stroke];
        }
    }
}

    // DXCC dots, for the entities whose land isn't shaded.
- (void)drawDxccDots:(MapDrawCtx &)d {
    NSRect b = d.b;
    CGFloat ink = d.ink;
    if (_style[kLayerCountries].show)
        for (size_t i = 0; i < _entities.size(); ++i) {
            if (i < _entityDot.size() && !_entityDot[i]) continue;
            const ADIFMapEntity &e = _entities[i];
            NSPoint p = [self viewPointForLon:e.lon lat:e.lat];
            if (!NSPointInRect(p, NSInsetRect(b, -10, -10))) continue;
            NSBezierPath *dot = [self marker:0 at:p size:[self dotRadius:e.qsos.size()]];
            [[self colorFor:_entityAgg[i] entity:YES] setFill];
            [dot fill];
            bool lit = (_hover.kind == ADIFMapHit::Dxcc && _hover.index == i) || (_selected.kind == ADIFMapHit::Dxcc && _selected.index == i);
            [[NSColor colorWithCalibratedWhite:ink alpha:lit ? 1 : 0.6] setStroke];
            dot.lineWidth = lit ? 2 : 1;
            [dot stroke];
        }
}

    // Contacts: a marker at each QSO's own place (LAT and LON, else a 6 or 8 character grid).
- (void)drawContacts:(MapDrawCtx &)d {
    NSRect b = d.b;
    const MapPalette &pal = *d.pal;
    CGFloat ink = d.ink;
    if (_showContacts)
        for (size_t i = 0; i < _contacts.size(); ++i) {
            NSPoint p = [self viewPointForLon:_contacts[i].lon lat:_contacts[i].lat];
            if (!NSPointInRect(p, NSInsetRect(b, -12, -12))) continue;
            // In the map's colours, outlined dark so a marker shows on a square of its own colour.
            NSBezierPath *m = [self contactMarkerAt:p];
            NSColor *c = [self colorFor:_contactAgg[i] entity:NO];
            bool lit = (_hover.kind == ADIFMapHit::Contact && _hover.index == i) || (_selected.kind == ADIFMapHit::Contact && _selected.index == i);
            NSColor *edge = lit ? [NSColor colorWithCalibratedWhite:ink alpha:1]
                                : [NSColor colorWithCalibratedWhite:pal.dark && darkColour(c) ? 1 : 0 alpha:0.85];
            if (_style.contact == 2) {  // crosshairs: a dark halo under the coloured lines
                m.lineWidth = 3.2;
                [edge setStroke];
                [m stroke];
                m.lineWidth = lit ? 1.8 : 1.4;
                [c setStroke];
                [m stroke];
                continue;
            }
            [c setFill];
            [m fill];
            [edge setStroke];
            m.lineWidth = lit ? 1.6 : 1;
            [m stroke];
        }
}

    // Parks (triangles) and other programs' references (diamonds, a colour each).
- (void)drawPrograms:(MapDrawCtx &)d {
    NSRect b = d.b;
    const MapPalette &pal = *d.pal;
    CGFloat ink = d.ink;
    for (size_t i = 0; i < _data.parks.size(); ++i) {
        const adif::MapPark &pk = _data.parks[i];
        if (![self programShown:pk] || [self parkPinned:pk]) continue;
        double lat = 0, lon = 0;
        if (!adif::gridToLatLon(pk.grid, &lat, &lon)) continue;
        NSPoint p = [self viewPointForLon:lon lat:lat];
        if (!NSPointInRect(p, NSInsetRect(b, -10, -10))) continue;
        bool pota = pk.program == "POTA";
        NSBezierPath *m = [self marker:pota ? 1 : 2 at:p size:(pota ? 5.5 : 5) * _style.marker];
        [(pota ? rgb(pal.park) : [self programColor:pk.program]) setFill];
        [m fill];
        bool lit = (_hover.kind == ADIFMapHit::Park && _hover.index == i) || (_selected.kind == ADIFMapHit::Park && _selected.index == i);
        [[NSColor colorWithCalibratedWhite:ink alpha:lit ? 1 : 0.35] setStroke];
        m.lineWidth = lit ? 1.5 : 0.6;
        [m stroke];
    }
}

    // Your station: a star at each MY_GRIDSQUARE.
- (void)drawMine:(MapDrawCtx &)d {
    const MapPalette &pal = *d.pal;
    CGFloat ink = d.ink;
    if (_style.mine)
        for (const std::string &g : _data.mine) {
            double lat = 0, lon = 0;
            if (!adif::gridToLatLon(g, &lat, &lon)) continue;
            NSBezierPath *star = [self marker:3 at:[self viewPointForLon:lon lat:lat] size:7.5 * _style.marker];
            [rgb(pal.me) setFill];
            [star fill];
            [[NSColor colorWithCalibratedWhite:ink alpha:1] setStroke];
            [star stroke];
        }
}

    // The square under the pointer and the one chosen, outlined.
- (void)drawSelection:(MapDrawCtx &)d {
    CGFloat ink = d.ink;
    for (const ADIFMapHit *h : {&_hover, &_selected}) {
        if (h->square.empty() || (h->kind != ADIFMapHit::Square && h->kind != ADIFMapHit::Empty)) continue;
        NSBezierPath *box = [self squarePath:h->square];
        if (!box || box.isEmpty || box.bounds.size.width < 3) continue;  // behind the globe, or too small to see
        box.lineWidth = h == &_selected ? 2 : 1;
        [[NSColor colorWithCalibratedWhite:ink alpha:h == &_selected ? 0.95 : 0.6] setStroke];
        [box stroke];
    }
}

// ── POTA ──

// A POTA park's pin, its point at p: a head 2.2 radii above it, with a triangle in it for a
// park you hunted, or a star for one you activated.
- (void)drawParkPinAt:(NSPoint)p color:(NSColor *)c activated:(BOOL)activated lit:(BOOL)lit {
    const MapPalette &pal = paletteAt(_style.palette);
    double r = kPin * 1.2 * _style.marker;
    NSPoint head = NSMakePoint(p.x, p.y + 2.2 * r);
    double t = std::acos(1 / 2.2) * 180 / M_PI;  // the tangent points, from straight down
    NSBezierPath *pin = [NSBezierPath bezierPath];
    [pin moveToPoint:p];
    [pin appendBezierPathWithArcWithCenter:head radius:r startAngle:-90 + t endAngle:270 - t clockwise:NO];
    [pin closePath];
    [c setFill];
    [pin fill];
    [[NSColor colorWithCalibratedWhite:lit ? (pal.dark ? 1 : 0) : (pal.dark && darkColour(c) ? 1 : 0) alpha:lit ? 1 : 0.85] setStroke];
    pin.lineWidth = lit ? 1.6 : 1;
    [pin stroke];
    NSBezierPath *mark;
    if (activated) {
        mark = [self marker:3 at:head size:r * 0.78];
    } else {
        double e = r * 0.6;
        mark = [NSBezierPath bezierPath];
        [mark moveToPoint:NSMakePoint(head.x, head.y + e)];
        [mark lineToPoint:NSMakePoint(head.x - e * 0.95, head.y - e * 0.7)];
        [mark lineToPoint:NSMakePoint(head.x + e * 0.95, head.y - e * 0.7)];
        [mark closePath];
    }
    [[NSColor colorWithCalibratedWhite:darkColour(c) ? 1 : 0 alpha:0.85] setFill];
    [mark fill];
}

// Where the POTA layer's markers go in the view as it is now. Show: a pin at each park you
// worked (hunted first, then the ones you activated, on top). Overlay: a ring at each other
// active park, or a small dot each where more than 1,500 would show (the Filters limit them).
// Worked out again when the view, the log or the list changes; the pointer finds them here.
- (void)placeParks {
    NSRect b = self.bounds;
    const adif::PotaParks &list = ADIFPotaParks();
    bool show = _style[kLayerPota].show, open = _style[kLayerPota].overlay;
    auto key = std::make_tuple(_cx, _cy, _zoom, _pr.centerLat(), _pr.centerLon(), (int)_pr.kind(), b.size.width, b.size.height, _style.marker,
                               (int)show * 2 + (int)open, (uintptr_t)list.parks().data(), list.size(), _dataGeneration);
    if (key == _parksPlacedFor) return;
    _parksPlacedFor = key;
    _potaSpots.clear();
    if ((!show && !open) || !list.size()) return;
    double west, south, east, north;
    [self visibleWest:&west south:&south east:&east north:&north];
    std::map<size_t, ADIFParkWork> byPark;  // an old K- reference and its US- park are one park
    for (const auto &[ref, work] : _potaWork) {
        const adif::PotaPark *p = list.find(ref);
        if (!p || !p->placed) continue;
        ADIFParkWork &w = byPark[list.indexOf(p)];
        w.hunted.insert(w.hunted.end(), work.hunted.begin(), work.hunted.end());
        w.activated.insert(w.activated.end(), work.activated.begin(), work.activated.end());
    }
    if (open) {
        std::vector<std::pair<size_t, NSPoint>> notWorked;
        for (size_t i = 0; i < list.parks().size(); ++i) {
            const adif::PotaPark &p = list.parks()[i];
            if (!p.active || !p.placed || p.lat < south - 1 || p.lat > north + 1 || byPark.count(i) || ![self parkFiltered:p]) continue;
            NSPoint q = [self viewPointForLon:p.lon lat:p.lat];
            if (NSPointInRect(q, NSInsetRect(b, -6, -6))) notWorked.emplace_back(i, q);
        }
        bool dots = notWorked.size() > 1500;
        for (const auto &[i, q] : notWorked) _potaSpots.push_back({i, q, false, false, {}, dots});
    }
    if (!show) return;
    double rise = 2.2 * kPin * 1.2 * _style.marker;  // a pin's head above its point
    for (int pass = 0; pass < 2; ++pass)
        for (const auto &[i, w] : byPark) {
            bool activated = !w.activated.empty();
            if (activated != (pass == 1)) continue;
            const adif::PotaPark &p = list.parks()[i];
            NSPoint q = [self viewPointForLon:p.lon lat:p.lat];
            if (NSPointInRect(q, NSInsetRect(b, -12, -12)))
                _potaSpots.push_back({i, NSMakePoint(q.x, q.y + rise), true, activated, [self aggregate:w.hunted], false});
        }
}

// Whether the Filters' places let a park (one you haven't worked) show: its locations, its
// state and region, its entity and continent. Without "Also limit the POTA parks you haven't
// worked", every park shows.
- (BOOL)parkFiltered:(const adif::PotaPark &)p {
    const adif::MapFilter &f = _parkFilter;
    if (!_filterParks || !f.any()) return YES;
    std::vector<std::string> locs;
    for (size_t b = 0; b <= p.location.size();) {
        size_t e = p.location.find(',', b);
        if (e == std::string::npos) e = p.location.size();
        if (e > b) locs.push_back(p.location.substr(b, e - b));
        b = e + 1;
    }
    auto anyLoc = [&](const std::function<bool(const std::string &)> &ok) {
        for (const std::string &l : locs)
            if (ok(l)) return true;
        return false;
    };
    auto usState = [](const std::string &loc) { return loc.size() == 5 && loc.compare(0, 3, "US-") == 0 ? loc.substr(3) : std::string(); };
    if (!f.potaLocations.empty() && !anyLoc([&](const std::string &l) { return f.potaLocations.count(l) > 0; })) return NO;
    if (!f.states.empty() && !anyLoc([&](const std::string &l) { return f.states.count(usState(l)) > 0; })) return NO;
    if (!f.regions.empty() && !anyLoc([&](const std::string &l) {
            for (const std::string &id : f.regions)
                if (const adif::UsRegion *r = adif::usRegion(id); r && adif::inUsRegion(*r, usState(l), "")) return true;
            return false;
        }))
        return NO;
    if (!f.dxcc.empty() && !f.dxcc.count(p.entity)) return NO;
    if (!f.continents.empty()) {
        std::string cont;
        for (const adif::CountryInfo &c : ADIFCountries().all())
            if (c.dxcc == p.entity) {
                cont = c.continent;
                break;
            }
        if (!f.continents.count(cont)) return NO;
    }
    return YES;
}

// The parks you haven't worked: rings, or dots where they are many.
- (void)drawParkRings {
    const MapPalette &pal = paletteAt(_style.palette);
    CGFloat ink = pal.dark ? 1 : 0;
    NSColor *tint = rgb(pal.park);
    double r = 3.2 * _style.marker, dr = 1.7 * _style.marker;
    NSBezierPath *rings = [NSBezierPath bezierPath], *dots = [NSBezierPath bezierPath], *lit = [NSBezierPath bezierPath];
    for (const ADIFParkSpot &sp : _potaSpots) {
        if (sp.pin) continue;
        bool on = (_hover.kind == ADIFMapHit::Pota && _hover.index == sp.park) || (_selected.kind == ADIFMapHit::Pota && _selected.index == sp.park);
        double rr = on ? r : sp.dot ? dr : r;
        [(on ? lit : sp.dot ? dots : rings) appendBezierPathWithOvalInRect:NSMakeRect(sp.at.x - rr, sp.at.y - rr, 2 * rr, 2 * rr)];
    }
    [[tint colorWithAlphaComponent:0.85] setFill];
    [dots fill];
    [[NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.55] setFill];
    [rings fill];
    [lit fill];
    rings.lineWidth = 1.3;
    [[tint colorWithAlphaComponent:0.95] setStroke];
    [rings stroke];
    lit.lineWidth = 2.2;
    [[NSColor colorWithCalibratedWhite:ink alpha:1] setStroke];
    [lit stroke];
}

// The pins of the parks you hunted (a triangle, in the map's colours) and activated (a star, in
// your station's colour).
- (void)drawParkPins {
    const MapPalette &pal = paletteAt(_style.palette);
    double rise = 2.2 * kPin * 1.2 * _style.marker;
    for (const ADIFParkSpot &sp : _potaSpots) {
        if (!sp.pin) continue;
        bool lit = (_hover.kind == ADIFMapHit::Pota && _hover.index == sp.park) || (_selected.kind == ADIFMapHit::Pota && _selected.index == sp.park);
        [self drawParkPinAt:NSMakePoint(sp.at.x, sp.at.y - rise) color:sp.activated ? rgb(pal.me) : [self colorFor:sp.agg entity:NO]
                  activated:sp.activated
                        lit:lit];
    }
}

// Each park's reference beside its marker, where it doesn't run into another: the parks you
// worked always, the others once the view is down to 400 of them, and names too once it is down
// to 150.
- (void)drawParkLabelsIn:(NSRect)b {
    const adif::PotaParks &list = ADIFPotaParks();
    const MapPalette &pal = paletteAt(_style.palette);
    NSShadow *halo = [[NSShadow alloc] init];
    halo.shadowColor = [NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.9];
    halo.shadowBlurRadius = 2;
    NSDictionary *attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                            NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:0.9], NSShadowAttributeName : halo};
    size_t rings = (size_t)std::count_if(_potaSpots.begin(), _potaSpots.end(), [](const ADIFParkSpot &sp) { return !sp.pin; });
    bool ringLabels = rings <= 400, names = _potaSpots.size() <= 150;
    std::vector<NSRect> taken;
    for (int pass = 0; pass < 2; ++pass)
        for (const ADIFParkSpot &sp : _potaSpots) {
            if (sp.pin != (pass == 0) || sp.park >= list.size() || (!sp.pin && !ringLabels)) continue;
            const adif::PotaPark &p = list.parks()[sp.park];
            NSString *text = ADIFString(names ? p.ref + " " + p.name : p.ref);
            NSSize sz = [text sizeWithAttributes:attrs];
            double gap = sp.pin ? kPin * 1.2 * _style.marker + 3 : 3.2 * _style.marker + 3;
            NSRect r = NSMakeRect(sp.at.x + gap, sp.at.y - sz.height / 2, sz.width, sz.height);
            if (!NSIntersectsRect(r, b)) continue;
            bool clear = true;
            for (const NSRect &t : taken) clear &= !NSIntersectsRect(NSInsetRect(t, -2, -1), r);
            if (!clear) continue;
            [text drawAtPoint:r.origin withAttributes:attrs];
            taken.push_back(r);
        }
}


// ── Spots ──

// A spot: a dot inside a ring, in its band's colour, like a station calling.
- (NSBezierPath *)spotMarkerAt:(NSPoint)p {
    double r = 3 * _style.marker, ring = 6 * _style.marker;
    NSBezierPath *m = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - r, p.y - r, 2 * r, 2 * r)];
    [m appendBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - ring, p.y - ring, 2 * ring, 2 * ring)]];
    return m;
}

// Newer spots solid, older ones fainter (unless Style Options turns fading off): full for the
// first 10 minutes, then down to 0.45 at the Spots filter's age (or an hour).
- (CGFloat)spotAlpha:(const ADIFMapSpot &)s {
    if (!_style.spotFade || s.spot.epoch <= 0 || _spotsNow <= 0) return 1;
    double age = (double)(_spotsNow - s.spot.epoch), span = _spotMaxAge > 600 ? (double)_spotMaxAge : 3600;
    if (age <= 600) return 1;
    return (CGFloat)std::max(0.45, 1 - 0.55 * (age - 600) / std::max(1.0, span - 600));
}

// The spot and the spotter under the pointer or chosen.
- (bool)spotLit:(size_t)k {
    return (_hover.kind == ADIFMapHit::Spot && _hover.index == k) || (_selected.kind == ADIFMapHit::Spot && _selected.index == k);
}
- (bool)spotterLit:(size_t)j {
    if ((_hover.kind == ADIFMapHit::Spotter && _hover.index == j) || (_selected.kind == ADIFMapHit::Spotter && _selected.index == j)) return true;
    if (j >= _spotters.size()) return false;
    for (size_t k : _spotters[j].spots)  // a spotter of the spot under the pointer
        if ([self spotLit:k]) return true;
    return false;
}

// Overlay: a line from each spotter to the station it heard, in the band's colour. The lines of
// the spot or spotter under the pointer or chosen show while Show is on, Overlay or not, on top.
- (void)drawSpotLines:(MapDrawCtx &)d {
    if (!_style[kLayerSpots].show) return;
    std::set<std::string> litSpotters;
    for (const ADIFMapHit *h : {&_hover, &_selected})
        if (h->kind == ADIFMapHit::Spotter && h->index < _spotters.size()) litSpotters.insert(adif::spotterCall(_spotters[h->index].call));
    std::set<std::tuple<long, long, long, long>> drawn;
    for (int pass = 0; pass < 2; ++pass)  // the others, then the lit ones over them
        for (size_t k = 0; k < _spots.size(); ++k) {
            const ADIFMapSpot &s = _spots[k];
            bool spotLit = [self spotLit:k];
            for (const ADIFSpotHeard &h : s.heard) {
                bool lit = spotLit || litSpotters.count(adif::spotterCall(h.call));
                if (lit != (pass == 1) || (!lit && !_style[kLayerSpots].overlay)) continue;
                if (!lit && !drawn.insert({std::lround(h.lat * 10), std::lround(h.lon * 10), std::lround(s.lat * 10), std::lround(s.lon * 10)}).second)
                    continue;
                NSBezierPath *path = [self viewPath:adif::greatCirclePath(h.lat, h.lon, s.lat, s.lon, 3) close:NO wraps:YES];
                path.lineWidth = lit ? 1.8 : 0.8;
                path.lineJoinStyle = NSLineJoinStyleRound;
                [[[self bandColor:s.spot.band] colorWithAlphaComponent:lit ? 0.9 : 0.45 * [self spotAlpha:s]] setStroke];
                [path stroke];
            }
        }
}

// A spotter's marker, a triangle like a listening antenna, centred on p with radius r. The spots
// are what matter, so it is see-through: a faint fill of the map's background colour inside a
// faint outline in its ink; solid ink when lit (a spotter of the spot under the pointer).
- (void)drawSpotterAt:(NSPoint)p radius:(double)r lit:(BOOL)lit dark:(BOOL)dark {
    NSBezierPath *tri = [NSBezierPath bezierPath];
    [tri moveToPoint:NSMakePoint(p.x, p.y + r)];
    [tri lineToPoint:NSMakePoint(p.x - 0.87 * r, p.y - 0.5 * r)];
    [tri lineToPoint:NSMakePoint(p.x + 0.87 * r, p.y - 0.5 * r)];
    [tri closePath];
    tri.lineJoinStyle = NSLineJoinStyleRound;
    CGFloat ink = dark ? 1 : 0, paper = dark ? 0 : 1;
    [[NSColor colorWithCalibratedWhite:lit ? ink : paper alpha:lit ? 0.9 : 0.35] setFill];
    [tri fill];
    tri.lineWidth = lit ? 1.3 : 1.0;
    [[NSColor colorWithCalibratedWhite:lit ? paper : ink alpha:lit ? 0.9 : 0.55] setStroke];
    [tri stroke];
}

- (double)spotterRadius:(bool)lit {
    return (lit ? 6.5 : 5.0) * _style.marker;
}

// The stations that heard the spots (Style Options → Spotters), bigger and solid for the spot or
// spotter under the pointer or chosen.
- (void)drawSpotters:(MapDrawCtx &)d {
    if (!_style[kLayerSpots].show || _style.spotters == 0) return;
    for (size_t j = 0; j < _spotters.size(); ++j) {
        NSPoint p = [self viewPointForLon:_spotters[j].lon lat:_spotters[j].lat];
        if (!NSPointInRect(p, NSInsetRect(d.b, -12, -12))) continue;
        bool lit = [self spotterLit:j];
        [self drawSpotterAt:p radius:[self spotterRadius:lit] lit:lit dark:d.pal->dark];
    }
}

// Show: a marker at each station spotted. Labels: its call beside it, where there's room, with
// what Style Options chooses under it (mode, frequency, age, report); then the spotters' calls.
- (void)drawSpots:(MapDrawCtx &)d {
    if (!_style[kLayerSpots].show) return;
    const MapPalette &pal = *d.pal;
    CGFloat ink = d.ink;
    NSShadow *halo = [[NSShadow alloc] init];
    halo.shadowColor = [NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.9];
    halo.shadowBlurRadius = 2;
    NSColor *textColor = [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:0.9];
    NSDictionary *attrs = @{NSFontAttributeName : [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightSemibold],
                            NSForegroundColorAttributeName : textColor, NSShadowAttributeName : halo};
    NSDictionary *small = @{NSFontAttributeName : [NSFont systemFontOfSize:9], NSForegroundColorAttributeName : textColor,
                            NSShadowAttributeName : halo};
    NSDictionary *spotterAttrs = @{NSFontAttributeName : [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular],
                                   NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:0.7],
                                   NSShadowAttributeName : halo};
    std::vector<NSRect> taken = d.taken;
    // The oldest first, so the newest are on top.
    for (size_t k = _spots.size(); k-- > 0;) {
        const ADIFMapSpot &s = _spots[k];
        NSPoint p = [self viewPointForLon:s.lon lat:s.lat];
        if (!NSPointInRect(p, NSInsetRect(d.b, -12, -12))) continue;
        bool lit = [self spotLit:k];
        CGFloat alpha = [self spotAlpha:s];
        NSColor *c = [[self bandColor:s.spot.band] colorWithAlphaComponent:alpha];
        double r = 3 * _style.marker, ring = 6 * _style.marker;
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - r, p.y - r, 2 * r, 2 * r)];
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - ring, p.y - ring, 2 * ring, 2 * ring)];
        [c setFill];
        [dot fill];
        circle.lineWidth = lit ? 2.2 : 1.4;
        [c setStroke];
        [circle stroke];
        [[NSColor colorWithCalibratedWhite:lit ? ink : (pal.dark && darkColour(c) ? 1 : 0) alpha:lit ? 1 : 0.7 * alpha] setStroke];
        dot.lineWidth = lit ? 1.4 : 0.8;
        [dot stroke];
    }
    if (_style[kLayerSpots].labels) {
        long long now = (long long)time(nullptr);
        for (size_t k = 0; k < _spots.size() && k < 400; ++k) {  // the newest first get the room
            const ADIFMapSpot &s = _spots[k];
            NSPoint p = [self viewPointForLon:s.lon lat:s.lat];
            NSString *call = ADIFString(s.spot.activator);
            NSString *details = ADIFString(adif::spotLabelDetails(s.spot, _style.spotLabel, now));
            NSSize cs = [call sizeWithAttributes:attrs];
            NSSize ds = details.length ? [details sizeWithAttributes:small] : NSZeroSize;
            double gap = 6 * _style.marker + 2;
            NSRect r = NSMakeRect(p.x + gap, p.y - (cs.height + ds.height) / 2, std::max(cs.width, ds.width), cs.height + ds.height);
            if (!NSIntersectsRect(r, d.b)) continue;
            bool clear = true;
            for (const NSRect &t : taken) clear &= !NSIntersectsRect(NSInsetRect(t, -2, -1), r);
            if (!clear) continue;
            [call drawAtPoint:NSMakePoint(r.origin.x, r.origin.y + ds.height) withAttributes:attrs];
            if (details.length) [details drawAtPoint:r.origin withAttributes:small];
            taken.push_back(r);
        }
    }
    if (_style.spotters == 2)  // the spotters' calls last: they give way to everything else
        for (size_t j = 0; j < _spotters.size(); ++j) {
            NSPoint p = [self viewPointForLon:_spotters[j].lon lat:_spotters[j].lat];
            NSString *text = ADIFString(_spotters[j].call);
            NSSize sz = [text sizeWithAttributes:spotterAttrs];
            double gap = [self spotterRadius:false] + 2;
            NSRect r = NSMakeRect(p.x + gap, p.y - sz.height / 2, sz.width, sz.height);
            if (!NSIntersectsRect(r, d.b)) continue;
            bool clear = true;
            for (const NSRect &t : taken) clear &= !NSIntersectsRect(NSInsetRect(t, -2, -1), r);
            if (!clear) continue;
            [text drawAtPoint:r.origin withAttributes:spotterAttrs];
            taken.push_back(r);
        }
}

- (size_t)spotAt:(NSPoint)p {
    if (!_style[kLayerSpots].show) return (size_t)-1;
    size_t best = (size_t)-1;
    double bestDistance = 6 * _style.marker + 2;
    for (size_t k = 0; k < _spots.size(); ++k) {  // newest first: on top
        NSPoint q = [self viewPointForLon:_spots[k].lon lat:_spots[k].lat];
        double dist = std::hypot(q.x - p.x, q.y - p.y);
        if (dist < bestDistance) best = k, bestDistance = dist - 0.01;
    }
    return best;
}

- (size_t)spotterAt:(NSPoint)p {
    if (!_style[kLayerSpots].show || _style.spotters == 0) return (size_t)-1;
    size_t best = (size_t)-1;
    double bestDistance = [self spotterRadius:false] + 2;
    for (size_t j = 0; j < _spotters.size(); ++j) {
        NSPoint q = [self viewPointForLon:_spotters[j].lon lat:_spotters[j].lat];
        double dist = std::hypot(q.x - p.x, q.y - p.y);
        if (dist < bestDistance) best = j, bestDistance = dist - 0.01;
    }
    return best;
}

@end
