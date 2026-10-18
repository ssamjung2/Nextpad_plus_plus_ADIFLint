// Map Detail on the Map: OpenStreetMap's land, water, land use, buildings, roads, rail,
// boundaries and place and street names, from the regions downloaded in Settings → Map Detail
// (MapDetail.h), drawn over the Natural Earth base where a region has tiles. Each tile is
// decoded once (adif_mvt) into paths on the map's plane, by kind, and kept for the next frames
// (on the globe, while it isn't turned). The layers and kinds are those of Protomaps' basemap
// v4 (docs.protomaps.com/basemaps/layers, read 2026-10-18); the colours follow the Map's
// palette, so worked areas and markers stay readable over them.
#import "MapView.h"

#import "MapDetail.h"

#include "adif_mvt.h"
#include "adif_pmtiles.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <tuple>

using namespace mapkit;
namespace pm = adif::pmtiles;

namespace {

enum Fill { kFillWater, kFillEarth, kFillFarm, kFillGreen, kFillBuilt, kFillLake, kFillBuildings, kFillCount };
enum Stroke { kStrokeRiver, kStrokeStream, kStrokeBoundary, kStrokeRail, kStrokePath, kStrokeMinor, kStrokeMajor, kStrokeHighway, kStrokeCount };

struct Label {
    double x = 0, y = 0;  // plane
    std::string text;
    int rank = 0;  // smaller first: countries, regions, cities, towns, neighbourhoods
    bool road = false;
    std::vector<std::pair<double, double>> line;  // a road's points on the plane
};

struct Tile {
    CGMutablePathRef fill[kFillCount] = {};
    CGMutablePathRef stroke[kStrokeCount] = {};
    std::vector<Label> labels;
    unsigned used = 0;
    Tile() {
        for (auto &p : fill) p = CGPathCreateMutable();
        for (auto &p : stroke) p = CGPathCreateMutable();
    }
    ~Tile() {
        for (auto &p : fill) CGPathRelease(p);
        for (auto &p : stroke) CGPathRelease(p);
    }
    Tile(const Tile &) = delete;
    Tile &operator=(const Tile &) = delete;
};

}  // namespace

// The tiles decoded so far, for the projection they were made for.
struct OsmCache {
    using Key = std::tuple<const void *, int, uint32_t, uint32_t>;
    std::map<Key, std::unique_ptr<Tile>> tiles;  // nullptr: the region has no such tile
    int projection = -1;
    double centerLat = 0, centerLon = 0;
    unsigned clock = 0;
};

namespace {

int fillOf(const std::string &layer, const std::string &kind) {
    if (layer == "water") return kFillLake;
    if (layer == "earth") return kFillEarth;
    if (layer == "buildings") return kFillBuildings;
    static const std::set<std::string> green = {"park",        "forest",        "wood",         "nature_reserve", "grass",     "garden",
                                                "golf_course", "cemetery",      "meadow",       "grassland",      "scrub",     "village_green",
                                                "dog_park",    "allotments",    "recreation_ground", "pitch",     "playground", "wetland",
                                                "national_park", "protected_area", "zoo",         "theme_park",    "beach",     "glacier"};
    static const std::set<std::string> farm = {"farmland", "farmyard", "orchard", "vineyard", "crop", "barren", "quarry"};
    if (layer == "landuse" || layer == "landcover") {
        if (green.count(kind) || kind == "forest" || kind == "grassland" || kind == "scrub") return kFillGreen;
        if (farm.count(kind)) return kFillFarm;
        if (kind == "snow" || kind == "urban_area" || kind.empty()) return kind == "urban_area" ? kFillBuilt : -1;
        return kFillBuilt;
    }
    return -1;
}

int strokeOf(const std::string &layer, const std::string &kind, const std::string &detail) {
    if (layer == "water") return kind == "river" || kind == "canal" ? kStrokeRiver : kStrokeStream;
    if (layer == "boundaries") return kind == "country" || kind == "region" ? kStrokeBoundary : -1;
    if (layer != "roads") return -1;
    if (kind == "highway") return kStrokeHighway;
    if (kind == "major_road") return kStrokeMajor;
    if (kind == "minor_road" || kind == "aeroway") return kStrokeMinor;
    if (kind == "path") return detail == "sidewalk" || detail == "crossing" ? -1 : kStrokePath;
    if (kind == "rail") return kStrokeRail;
    return -1;
}

int placeRank(const std::string &kind) {
    if (kind == "country") return 0;
    if (kind == "region") return 1;
    if (kind == "locality") return 2;
    if (kind == "macrohood" || kind == "neighbourhood") return 4;
    return 3;
}

std::unique_ptr<Tile> buildTile(pm::Archive &archive, int z, uint32_t x, uint32_t y, const adif::Projector &pr) {
    std::string bytes;
    if (!archive.tile(z, x, y, &bytes)) return nullptr;
    std::vector<adif::mvt::Layer> layers;
    if (!adif::mvt::decode(bytes, &layers, nullptr)) return nullptr;
    auto t = std::make_unique<Tile>();
    // The tile's own square, as water: OSM's coast, not the coarser base map's, inside it.
    {
        double px[4], py[4];
        bool ok = true;
        const double cx[4] = {0, 1, 1, 0}, cy[4] = {0, 0, 1, 1};
        for (int k = 0; k < 4; ++k) ok = ok && pr.forward(pm::tileLon(x + cx[k], z), pm::tileLat(y + cy[k], z), &px[k], &py[k]);
        if (ok) {
            CGPathMoveToPoint(t->fill[kFillWater], nullptr, px[0], py[0]);
            for (int k = 1; k < 4; ++k) CGPathAddLineToPoint(t->fill[kFillWater], nullptr, px[k], py[k]);
            CGPathCloseSubpath(t->fill[kFillWater]);
        }
    }
    std::vector<adif::mvt::Path> geom;
    for (const adif::mvt::Layer &l : layers) {
        const double e = l.extent;
        auto plane = [&](const std::pair<int32_t, int32_t> &p, double *X, double *Y) {
            return pr.forward(pm::tileLon(x + p.first / e, z), pm::tileLat(y + p.second / e, z), X, Y);
        };
        for (const adif::mvt::Feature &f : l.features) {
            std::string kind = l.text(f, "kind");
            if (l.name == "places" || (l.name == "roads" && f.type == adif::mvt::GeomType::Line)) {
                std::string name = l.text(f, "name");
                if (!name.empty() && adif::mvt::geometry(f, &geom) && !geom.empty() && !geom[0].points.empty()) {
                    Label lab;
                    lab.text = name;
                    if (l.name == "places") {
                        if (!plane(geom[0].points[0], &lab.x, &lab.y)) continue;
                        lab.rank = placeRank(kind);
                    } else {
                        lab.road = true;
                        lab.rank = kind == "highway" ? 5 : kind == "major_road" ? 6 : 7;
                        for (const auto &p : geom[0].points) {
                            double X, Y;
                            if (plane(p, &X, &Y)) lab.line.emplace_back(X, Y);
                        }
                        if (lab.line.size() < 2) continue;
                    }
                    t->labels.push_back(std::move(lab));
                }
                if (l.name == "places") continue;
            }
            if (f.type == adif::mvt::GeomType::Polygon) {
                int k = fillOf(l.name, kind);
                if (k < 0 || !adif::mvt::geometry(f, &geom)) continue;
                for (const adif::mvt::Path &ring : geom) {
                    bool open = false;
                    for (const auto &p : ring.points) {
                        double X, Y;
                        if (!plane(p, &X, &Y)) {
                            open = false;
                            continue;
                        }
                        if (!open) CGPathMoveToPoint(t->fill[k], nullptr, X, Y), open = true;
                        else CGPathAddLineToPoint(t->fill[k], nullptr, X, Y);
                    }
                    if (open) CGPathCloseSubpath(t->fill[k]);
                }
            } else if (f.type == adif::mvt::GeomType::Line) {
                int k = strokeOf(l.name, kind, l.text(f, "kind_detail"));
                if (k < 0 || !adif::mvt::geometry(f, &geom)) continue;
                for (const adif::mvt::Path &line : geom) {
                    bool open = false;
                    for (const auto &p : line.points) {
                        double X, Y;
                        if (!plane(p, &X, &Y)) {
                            open = false;
                            continue;
                        }
                        if (!open) CGPathMoveToPoint(t->stroke[k], nullptr, X, Y), open = true;
                        else CGPathAddLineToPoint(t->stroke[k], nullptr, X, Y);
                    }
                }
            }
        }
    }
    return t;
}

NSColor *mix(unsigned base, unsigned with, double f) { return [rgb(base) blendedColorWithFraction:f ofColor:rgb(with)]; }

}  // namespace

@implementation ADIFMapView (Osm)

- (void)osmChanged {
    _osm.reset();
    [self setNeedsDisplay:YES];
}

// Zoomed in up to 16,384× where a downloaded region is (its zoom 15 needs it), else 1,024×.
- (double)maxZoomHere {
    double lon, lat;
    NSRect b = self.bounds;
    if (![self lonLatAt:NSMakePoint(NSMidX(b), NSMidY(b)) lon:&lon lat:&lat]) return kMaxZoom;
    for (const mapdetail::Region &r : mapdetail::regions())
        if (lon >= r.bounds[0] && lon <= r.bounds[2] && lat >= r.bounds[1] && lat <= r.bounds[3]) return kMaxDetailZoom;
    return kMaxZoom;
}

- (void)drawOsm:(MapDrawCtx &)d {
    _osmDrawn = NO;
    const std::vector<mapdetail::Region> &regions = mapdetail::regions();
    if (regions.empty()) return;
    NSRect b = self.bounds;
    double lonC, latC;
    if (![self lonLatAt:NSMakePoint(NSMidX(b), NSMidY(b)) lon:&lonC lat:&latC]) return;
    double perDegree = [self pixelsForLon:lonC lat:latC span:0.01] / 0.01;
    if (perDegree <= 0) return;
    // The zoom whose 512-point tiles match the view; below about 8 the base map is enough.
    double zf = std::log2(perDegree * 360 / 512);
    if (zf < 7.5) return;
    if (!_osm) _osm = std::make_shared<OsmCache>();
    OsmCache &cache = *_osm;
    if (cache.projection != (int)_pr.kind() || cache.centerLat != _pr.centerLat() || cache.centerLon != _pr.centerLon()) {
        cache.tiles.clear();
        cache.projection = (int)_pr.kind(), cache.centerLat = _pr.centerLat(), cache.centerLon = _pr.centerLon();
    }
    double west = d.west, south = d.south, east = d.east, north = d.north;
    std::vector<Tile *> shown;
    for (const mapdetail::Region &r : regions) {
        double w = std::max(west, r.bounds[0]), e = std::min(east, r.bounds[2]), s = std::max(south, r.bounds[1]), n = std::min(north, r.bounds[3]);
        if (w > e || s > n) continue;
        const pm::Header &h = r.archive->header();
        int z = std::clamp((int)std::floor(zf), (int)h.minZoom, (int)h.maxZoom);
        long x0, x1, y0, y1;
        for (;; --z) {
            x0 = (long)std::floor(pm::tileX(w, z)), x1 = (long)std::floor(pm::tileX(e, z));
            y0 = (long)std::floor(pm::tileY(n, z)), y1 = (long)std::floor(pm::tileY(s, z));
            if ((x1 - x0 + 1) * (y1 - y0 + 1) <= 160 || z <= h.minZoom) break;
        }
        long last = (1L << z) - 1;
        x0 = std::clamp(x0, 0L, last), x1 = std::clamp(x1, 0L, last), y0 = std::clamp(y0, 0L, last), y1 = std::clamp(y1, 0L, last);
        for (long ty = y0; ty <= y1; ++ty)
            for (long tx = x0; tx <= x1; ++tx) {
                OsmCache::Key key{r.archive.get(), z, (uint32_t)tx, (uint32_t)ty};
                auto it = cache.tiles.find(key);
                if (it == cache.tiles.end()) it = cache.tiles.emplace(key, buildTile(*r.archive, z, (uint32_t)tx, (uint32_t)ty, _pr)).first;
                if (it->second) it->second->used = ++cache.clock, shown.push_back(it->second.get());
            }
    }
    while (cache.tiles.size() > 200) {  // the least recently drawn go first
        auto oldest = cache.tiles.begin();
        for (auto it = cache.tiles.begin(); it != cache.tiles.end(); ++it)
            if (!it->second || (oldest->second && it->second->used < oldest->second->used)) oldest = it;
        cache.tiles.erase(oldest);
    }
    if (shown.empty()) return;
    _osmDrawn = YES;
    const MapPalette &pal = *d.pal;
    CGContextRef ctx = d.ctx ? d.ctx : NSGraphicsContext.currentContext.CGContext;
    double ppu = [self ppu];
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, NSRectToCGRect(b));
    CGContextTranslateCTM(ctx, NSMidX(b) - _cx * ppu, NSMidY(b) - _cy * ppu);
    CGContextScaleCTM(ctx, ppu, ppu);
    unsigned white = 0xFFFFFF, grey = 0x808080;
    NSColor *fills[kFillCount] = {
        rgb(pal.ocean),
        rgb(pal.land),
        mix(pal.land, 0xB8A060, pal.dark ? 0.12 : 0.18),
        mix(pal.land, 0x3E7D4A, pal.dark ? 0.38 : 0.3),
        mix(pal.land, pal.dark ? white : grey, pal.dark ? 0.06 : 0.1),
        rgb(pal.ocean),
        mix(pal.land, pal.dark ? white : grey, pal.dark ? 0.17 : 0.28),
    };
    for (int k = 0; k < kFillCount; ++k) {
        if (k == kFillBuildings && zf < 13.5) continue;  // buildings only when they are more than specks
        CGContextSetFillColorWithColor(ctx, fills[k].CGColor);
        for (Tile *t : shown) CGContextAddPath(ctx, t->fill[k]);
        // Nonzero, not even-odd: neighbouring tiles overlap at their edges (each carries a
        // margin), and a vector tile's holes wind the other way round from their outer rings.
        CGContextFillPath(ctx);
    }
    // Lines: widths in points, growing with the zoom (and a little past the data's own zoom).
    double grow = std::clamp(std::exp2(zf - 15), 0.25, 3.0);
    struct LineStyle {
        NSColor *colour;
        double width, minWidth;
        bool dashed;
    };
    LineStyle lines[kStrokeCount] = {
        {rgb(pal.river), 2.4, 0.8, false},
        {rgb(pal.river), 1.0, 0.4, false},
        {[rgb(pal.border) colorWithAlphaComponent:0.8], 1.2, 0.8, true},
        {mix(pal.land, pal.dark ? white : 0x606060, 0.45), 1.4, 0.5, true},
        {mix(pal.land, pal.dark ? white : 0x8A8A8A, pal.dark ? 0.28 : 0.55), 0.9, 0.4, true},
        {mix(pal.land, white, pal.dark ? 0.3 : 0.85), 2.6, 0.5, false},
        {mix(pal.land, white, pal.dark ? 0.48 : 0.95), 4.0, 0.8, false},
        {mix(pal.land, 0xF2B544, pal.dark ? 0.6 : 0.75), 5.5, 1.0, false},
    };
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    for (int k = 0; k < kStrokeCount; ++k) {
        const LineStyle &s = lines[k];
        double w = std::max(s.minWidth, s.width * grow);
        if (!pal.dark && (k == kStrokeMajor || k == kStrokeHighway)) {  // a darker edge on a light map
            CGContextSetStrokeColorWithColor(ctx, mix(pal.land, 0x707070, 0.6).CGColor);
            CGContextSetLineWidth(ctx, (w + 1.2) / ppu);
            for (Tile *t : shown) CGContextAddPath(ctx, t->stroke[k]);
            CGContextStrokePath(ctx);
        }
        CGContextSetStrokeColorWithColor(ctx, s.colour.CGColor);
        CGContextSetLineWidth(ctx, w / ppu);
        if (s.dashed) {
            CGFloat dash[] = {(CGFloat)(std::max(3.0, w * 3) / ppu), (CGFloat)(std::max(2.0, w * 2) / ppu)};
            CGContextSetLineDash(ctx, 0, dash, 2);
        }
        for (Tile *t : shown) CGContextAddPath(ctx, t->stroke[k]);
        CGContextStrokePath(ctx);
        CGContextSetLineDash(ctx, 0, nullptr, 0);
    }
    CGContextRestoreGState(ctx);
    // Names: places, then streets along them, each clear of the others.
    std::vector<const Label *> labels;
    for (Tile *t : shown)
        for (const Label &l : t->labels) labels.push_back(&l);
    std::stable_sort(labels.begin(), labels.end(), [](const Label *a, const Label *b) { return a->rank < b->rank; });
    std::vector<NSRect> taken;
    std::set<std::string> said;
    NSColor *ink = [NSColor colorWithCalibratedWhite:pal.dark ? 0.95 : 0.1 alpha:1], *halo = [rgb(pal.land) colorWithAlphaComponent:0.85];
    for (const Label *l : labels) {
        if (l->road && zf < 13.5) continue;
        if (!l->road && l->rank >= 4 && zf < 12) continue;
        if (l->road && said.count(l->text)) continue;  // a street's name once in view
        CGFloat size = l->road ? 9.5 : l->rank <= 1 ? 13 : l->rank == 2 ? 12.5 : l->rank == 3 ? 11 : 10;
        NSFont *font = l->rank <= 2 ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
        NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : ink, NSStrokeColorAttributeName : halo,
                                NSStrokeWidthAttributeName : @(-3.5)};
        NSDictionary *plain = @{NSFontAttributeName : font, NSForegroundColorAttributeName : ink};
        NSString *text = @(l->text.c_str());
        if (!text.length) continue;
        NSSize sz = [text sizeWithAttributes:plain];
        if (!l->road) {
            NSPoint p = [self planeToView:l->x y:l->y];
            NSRect r = NSMakeRect(p.x - sz.width / 2, p.y - sz.height / 2, sz.width, sz.height);
            if (!NSIntersectsRect(r, b)) continue;
            bool clear = true;
            for (const NSRect &o : taken) clear = clear && !NSIntersectsRect(NSInsetRect(r, -3, -2), o);
            if (!clear) continue;
            taken.push_back(r);
            [text drawAtPoint:r.origin withAttributes:attrs];
            [text drawAtPoint:r.origin withAttributes:plain];
            continue;
        }
        // A street: along its longest piece in view that the name fits on.
        NSPoint best0{}, best1{};
        double bestLen = 0;
        for (size_t i = 0; i + 1 < l->line.size(); ++i) {
            NSPoint a = [self planeToView:l->line[i].first y:l->line[i].second], c = [self planeToView:l->line[i + 1].first y:l->line[i + 1].second];
            NSPoint mid = NSMakePoint((a.x + c.x) / 2, (a.y + c.y) / 2);
            double len = std::hypot(c.x - a.x, c.y - a.y);
            if (len > bestLen && NSPointInRect(mid, NSInsetRect(b, 20, 10))) bestLen = len, best0 = a, best1 = c;
        }
        if (bestLen < sz.width + 16) continue;
        double angle = std::atan2(best1.y - best0.y, best1.x - best0.x);
        if (angle > M_PI / 2) angle -= M_PI;
        if (angle < -M_PI / 2) angle += M_PI;
        NSPoint mid = NSMakePoint((best0.x + best1.x) / 2, (best0.y + best1.y) / 2);
        double hw = (std::fabs(std::cos(angle)) * sz.width + std::fabs(std::sin(angle)) * sz.height) / 2;
        double hh = (std::fabs(std::sin(angle)) * sz.width + std::fabs(std::cos(angle)) * sz.height) / 2;
        NSRect r = NSMakeRect(mid.x - hw, mid.y - hh, hw * 2, hh * 2);
        bool clear = true;
        for (const NSRect &o : taken) clear = clear && !NSIntersectsRect(r, o);
        if (!clear) continue;
        taken.push_back(r);
        said.insert(l->text);
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *tr = [NSAffineTransform transform];
        [tr translateXBy:mid.x yBy:mid.y];
        [tr rotateByRadians:angle];
        [tr concat];
        NSPoint at = NSMakePoint(-sz.width / 2, -sz.height / 2);
        [text drawAtPoint:at withAttributes:attrs];
        [text drawAtPoint:at withAttributes:plain];
        [NSGraphicsContext restoreGraphicsState];
    }
}

// The credit OpenStreetMap's licence asks for, in the corner, whenever its data shows (also
// in an exported PNG). OSMF Attribution Guidelines (osmfoundation.org, read 2026-10-18).
- (void)drawOsmCredit {
    if (!_osmDrawn) return;
    const MapPalette &pal = paletteAt(_style.palette);
    NSString *credit = @"© OpenStreetMap contributors";
    NSDictionary *attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:10],
                            NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:pal.dark ? 0.9 : 0.15 alpha:1]};
    NSSize s = [credit sizeWithAttributes:attrs];
    NSRect b = self.bounds;
    NSRect box = NSMakeRect(NSMaxX(b) - s.width - 10, NSMinY(b) + 4, s.width + 6, s.height + 2);
    [[NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.55] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3] fill];
    [credit drawAtPoint:NSMakePoint(NSMinX(box) + 3, NSMinY(box) + 1) withAttributes:attrs];
}

@end
