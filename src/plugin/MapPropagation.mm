// The Map's propagation layers: the aurora (NOAA SWPC's OVATION nowcast, Solar.mm), the spots
// shown as a heat map, and the NCDXF/IARU beacons with the ones sending now picked out.

#import "MapView.h"

#import "L10n.h"
#import "Solar.h"
#include "adif_beacons.h"
#include "adif_geo.h"

#include <algorithm>
#include <cmath>
#include <ctime>
#include <string>
#include <vector>

using namespace mapkit;

namespace {

// A raster drawn over the view: `colour` gives each sample's premultiplied RGBA from its place,
// at one sample every `step` points, scaled up smoothly.
template <typename F>
void drawRaster(ADIFMapView *view, MapDrawCtx &d, int step, F colour) {
    NSRect b = d.b;
    size_t w = (size_t)std::ceil(b.size.width / step), h = (size_t)std::ceil(b.size.height / step);
    if (!w || !h) return;
    std::vector<uint8_t> px(w * h * 4, 0);
    bool any = false;
    for (size_t y = 0; y < h; ++y)
        for (size_t x = 0; x < w; ++x) {
            double lon, lat;
            NSPoint p = NSMakePoint(NSMinX(b) + (x + 0.5) * step, NSMaxY(b) - (y + 0.5) * step);
            if (![view lonLatAt:p lon:&lon lat:&lat]) continue;
            any |= colour(lon, lat, &px[(y * w + x) * 4]);
        }
    if (!any) return;
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
}

void premultiplied(uint8_t *o, double r, double g, double b, double a) {
    a = std::clamp(a, 0.0, 1.0);
    o[0] = (uint8_t)std::lround(255 * r * a), o[1] = (uint8_t)std::lround(255 * g * a), o[2] = (uint8_t)std::lround(255 * b * a);
    o[3] = (uint8_t)std::lround(255 * a);
}

// The spots' heat: each spot adds a bell of about 400 km round it to a grid of whole degrees.
struct Heat {
    std::vector<float> grid;  // 360 x 181, latitude -90 first
    float most = 0;
    size_t count = 0;
    long long at = 0;
    std::string first;
};

Heat &heat() {
    static Heat h;
    return h;
}

void fillHeat(const std::vector<ADIFMapSpot> &spots, long long now) {
    Heat &h = heat();
    std::string first = spots.empty() ? "" : spots.front().spot.activator + spots.front().spot.band;
    if (h.count == spots.size() && h.at == now && h.first == first && !h.grid.empty()) return;
    h.grid.assign(360u * 181u, 0);
    h.count = spots.size(), h.at = now, h.first = first, h.most = 0;
    const double sigma = 400;  // km
    for (const ADIFMapSpot &s : spots) {
        int reach = (int)std::ceil(3 * sigma / 111.0);  // degrees of latitude
        double c = std::max(0.1, std::cos(s.lat * M_PI / 180));
        int across = std::min(180, (int)std::ceil(reach / c));
        for (int dy = -reach; dy <= reach; ++dy) {
            int lat = (int)std::lround(s.lat) + dy;
            if (lat < -90 || lat > 90) continue;
            for (int dx = -across; dx <= across; ++dx) {
                int lon = (int)std::lround(s.lon) + dx;
                double km = adif::greatCircleKm(s.lat, s.lon, lat, lon);
                if (km > 3 * sigma) continue;
                float &cell = h.grid[(size_t)(lat + 90) * 360 + (size_t)(((lon % 360) + 360) % 360)];
                cell += (float)std::exp(-km * km / (2 * sigma * sigma));
                h.most = std::max(h.most, cell);
            }
        }
    }
}

double heatAt(double lon, double lat) {
    const Heat &h = heat();
    if (h.grid.empty() || h.most <= 0) return 0;
    double x = std::fmod(lon + 360.0, 360.0), y = std::clamp(lat, -90.0, 90.0) + 90;
    int x0 = (int)std::floor(x), y0 = (int)std::floor(y);
    double tx = x - x0, ty = y - y0;
    auto v = [&](int xx, int yy) { return (double)h.grid[(size_t)std::min(yy, 180) * 360 + (size_t)(xx % 360)]; };
    double s = (v(x0, y0) * (1 - tx) + v(x0 + 1, y0) * tx) * (1 - ty) + (v(x0, y0 + 1) * (1 - tx) + v(x0 + 1, y0 + 1) * tx) * ty;
    return s / h.most;
}

}  // namespace

@implementation ADIFMapView (Propagation)

// The aurora: SWPC's chance of seeing it overhead, from 5% faint green to 50% and more red, as
// SWPC's own maps colour it.
- (void)drawAurora:(MapDrawCtx &)d {
    if (!_style.aurora) return;
    const adif::AuroraGrid &g = solar::aurora();
    if (g.value.empty()) return;
    drawRaster(self, d, 3, [&](double lon, double lat, uint8_t *o) {
        double v = g.at(lon, lat);
        if (v < 5) return false;
        double t = std::clamp((v - 5) / 45, 0.0, 1.0);  // 5% green, through yellow, 50% red
        double r = t < 0.5 ? 2 * t : 1, gr = t < 0.5 ? 1 : 2 * (1 - t);
        premultiplied(o, r, 0.25 + 0.75 * gr, 0.15, 0.25 + 0.45 * t);
        return true;
    });
}

// The spots shown (the filters' and the Quick View's), as a heat map: where many stations are
// spotted now, warmer.
- (void)drawSpotHeat:(MapDrawCtx &)d {
    if (!_style.spotHeat || !_style[kLayerSpots].show || _spots.empty()) return;
    fillHeat(_spots, _spotsNow);
    drawRaster(self, d, 4, [&](double lon, double lat, uint8_t *o) {
        double v = heatAt(lon, lat);
        if (v < 0.04) return false;
        double t = std::sqrt(v);  // a few spots still show
        double r = std::clamp(2 * t - 0.4, 0.0, 1.0), g = t < 0.7 ? t / 0.7 : (1 - t) / 0.3 * 0.6 + 0.4, b = std::clamp(1 - 2 * t, 0.0, 1.0);
        premultiplied(o, r, g, b, 0.15 + 0.4 * t);
        return true;
    });
}

- (NSPoint)beaconPoint:(size_t)i visible:(BOOL *)visible {
    double lat = 0, lon = 0;
    *visible = adif::gridToLatLon(adif::kBeacons[i].grid, &lat, &lon) && (_pr.kind() != adif::Projection::Globe || _pr.visible(lon, lat));
    return [self viewPointForLon:lon lat:lat];
}

// The beacons: each a small mast; the ones sending now (on the band picked out, else on each
// band) ringed in their band's colour with the frequency.
- (void)drawBeacons:(MapDrawCtx &)d {
    if (!_style.beacons) return;
    const MapPalette &pal = *d.pal;
    double now = [[NSDate date] timeIntervalSince1970];
    NSShadow *halo = [[NSShadow alloc] init];
    halo.shadowColor = [NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.9];
    halo.shadowBlurRadius = 2;
    NSColor *ink = [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:0.85];
    NSDictionary *callAttrs = @{NSFontAttributeName : [NSFont monospacedSystemFontOfSize:9 * _style.textScale weight:NSFontWeightRegular],
                                NSForegroundColorAttributeName : [ink colorWithAlphaComponent:0.7], NSShadowAttributeName : halo};
    NSDictionary *litAttrs = @{NSFontAttributeName : [NSFont monospacedSystemFontOfSize:10 * _style.textScale weight:NSFontWeightSemibold],
                               NSForegroundColorAttributeName : ink, NSShadowAttributeName : halo};
    for (size_t i = 0; i < adif::kBeaconCount; ++i) {
        BOOL visible = NO;
        NSPoint p = [self beaconPoint:i visible:&visible];
        if (!visible || !NSPointInRect(p, NSInsetRect(d.b, -20, -20))) continue;
        size_t band = adif::beaconBand(i, now);
        bool lit = band < adif::kBeaconBands && (self.beaconBand < 0 || (size_t)self.beaconBand == band);
        double r = (lit ? 4.5 : 3.2) * _style.marker;
        NSColor *c = lit ? [self bandColor:adif::kBeaconBandNames[band]] : [NSColor colorWithCalibratedWhite:pal.dark ? 0.8 : 0.35 alpha:1];
        // A mast: a triangle on its point, a dot at the top.
        NSBezierPath *mast = [NSBezierPath bezierPath];
        [mast moveToPoint:NSMakePoint(p.x, p.y + r)];
        [mast lineToPoint:NSMakePoint(p.x - 0.7 * r, p.y - r)];
        [mast lineToPoint:NSMakePoint(p.x + 0.7 * r, p.y - r)];
        [mast closePath];
        [c setFill];
        [mast fill];
        mast.lineWidth = 0.8;
        [[NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.8] setStroke];
        [mast stroke];
        NSString *label = @(adif::kBeacons[i].call);
        if (lit) {
            NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - 2.2 * r, p.y - 2.2 * r, 4.4 * r, 4.4 * r)];
            ring.lineWidth = 2;
            [[c colorWithAlphaComponent:0.9] setStroke];
            [ring stroke];
            char mhz[16];
            snprintf(mhz, sizeof mhz, " %.3f", adif::kBeaconMHz[band]);
            label = [label stringByAppendingString:@(mhz)];
        }
        [label drawAtPoint:NSMakePoint(p.x + (lit ? 2.4 : 1.2) * r + 2, p.y - 6) withAttributes:lit ? litAttrs : callAttrs];
    }
}

- (size_t)beaconAt:(NSPoint)p {
    if (!_style.beacons) return (size_t)-1;
    size_t best = (size_t)-1;
    double bestDistance = 8 * _style.marker;
    for (size_t i = 0; i < adif::kBeaconCount; ++i) {
        BOOL visible = NO;
        NSPoint q = [self beaconPoint:i visible:&visible];
        double dist = std::hypot(q.x - p.x, q.y - p.y);
        if (visible && dist <= bestDistance) best = i, bestDistance = dist;
    }
    return best;
}

@end
