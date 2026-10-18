#import "MapView.h"

#import "IotaGroups.h"
#import "PluginHost.h"
#import "PotaParks.h"
#import "ToolWindow.h"
#include "adif_geo.h"
#include "adif_worked.h"
#include "adif_spec.h"

#include <algorithm>
#include <cmath>
#include <dlfcn.h>
#include <fstream>
#include <sstream>

using namespace adifhost;
using namespace mapkit;

namespace mapkit {

// ── Colours ──

NSColor *rgb(unsigned hex, CGFloat a) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:a];
}

// The palettes and band colours live in adif_palette (the tests check them).
const MapPalette &paletteAt(int i) { return adif::mapPalette(i); }

void setFill(CGContextRef ctx, unsigned hex, CGFloat a) {
    CGContextSetRGBFillColor(ctx, ((hex >> 16) & 0xFF) / 255.0, ((hex >> 8) & 0xFF) / 255.0, (hex & 0xFF) / 255.0, a);
}
void setStroke(CGContextRef ctx, unsigned hex, CGFloat a) {
    CGContextSetRGBStrokeColor(ctx, ((hex >> 16) & 0xFF) / 255.0, ((hex >> 8) & 0xFF) / 255.0, (hex & 0xFF) / 255.0, a);
}

int bandIndex(const std::string &band) { return adif::bandOrder(band); }

// Whether a marker in this colour needs a light edge to show on a dark map (60m's navy).
bool darkColour(NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return s && 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent < 0.22;
}

NSColor *ramp(double t, const MapPalette &p) {
    return rgb(adif::viridisColour(p.rampFrom + std::clamp(t, 0.0, 1.0) * (1 - p.rampFrom) * (p.dark ? 1 : 0.9)));
}

// QSO counts in five steps: 1, 2-4, 5-9, 10-24, 25 and more.
int countBucket(size_t n) { return n <= 1 ? 0 : n <= 4 ? 1 : n <= 9 ? 2 : n <= 24 ? 3 : 4; }
const char *const kCountLabels[5] = {"1 QSO", "2-4", "5-9", "10-24", "25+"};
const char *const kModeLabels[3] = {"CW", "Phone", "Data"};

// ── Programs ──

const ProgramInfo kPrograms[] = {{"WWFF", "WWFF (parks)"},       {"SOTA", "SOTA (summits)"},       {"IOTA", "IOTA (islands)"},        {"GMA", "GMA (mountains)"},
                                 {"WWBOTA", "WWBOTA (bunkers)"},   {"HEMA", "HEMA (hills)"},          {"SIOTA", "SiOTA (silos)"},
                                 {"WCA", "WCA (castles)"},         {"ILLW", "ILLW (lighthouses)"},    {"ARLHS", "ARLHS (lighthouses)"},
                                 {"MOTA", "MOTA (mills)"},         {"ZLOTA", "ZLOTA (New Zealand)"}, {"WOTA", "WOTA (Lake District)"}};
const size_t kProgramCount = sizeof(kPrograms) / sizeof(kPrograms[0]);

const OverlayCache &overlay(adif::Overlay o) {
    static std::map<int, OverlayCache> all;
    OverlayCache &c = all[(int)o];
    if (c.areas.empty())
        for (size_t i = 0; i < adif::overlayCount(o); ++i) {
            c.areas.push_back(adif::overlayArea(o, i));
            double w = 999, e = -999, so = 999, n = -999;
            for (const auto &ring : c.areas.back().rings)
                for (const auto &p : ring) w = std::min(w, p.first), e = std::max(e, p.first), so = std::min(so, p.second), n = std::max(n, p.second);
            c.span.emplace_back(e - w, n - so);
        }
    return c;
}

// The 1:10m detail, read once from map-detail.bin beside the plugin; empty without it (the
// map then stays on the 1:50m maps).
const adif::MapDetail &mapDetail() {
    static adif::MapDetail detail;
    static bool tried = false;
    if (!tried) {
        tried = true;
        Dl_info info{};
        if (dladdr((const void *)&mapDetail, &info) && info.dli_fname) {
            std::string path = info.dli_fname;
            path = path.substr(0, path.find_last_of('/')) + "/map-detail.bin";
            std::ifstream in(path, std::ios::binary);
            std::stringstream bytes;
            bytes << in.rdbuf();
            detail.load(bytes.str());
        }
    }
    return detail;
}

// Natural Earth's zoom levels are a web map's: the whole world is about 2 on ours at 1x.
double webZoom(double zoom) { return std::log2(std::max(1.0, zoom)) + 2; }

// A detail layer's shapes in a box of longitude and latitude, on the plane; `keep` decides by
// a shape's rank.
CGMutablePathRef detailPath(const adif::Projector &pr, adif::DetailLayer l, bool polygons, double west, double south, double east, double north,
                            const std::function<bool(int)> &keep) {
    const adif::MapDetail &detail = mapDetail();
    CGMutablePathRef m = CGPathCreateMutable();
    for (size_t i : detail.within(l, west, south, east, north)) {
        const adif::DetailShape &shape = detail.shapes(l)[i];
        if (!keep(shape.rank)) continue;
        for (const adif::ShapePiece &piece : adif::projectShape(pr, detail.points(l, shape), polygons, false)) {
            for (size_t k = 0; k < piece.pts.size(); ++k)
                if (k == 0) CGPathMoveToPoint(m, nullptr, piece.pts[k].first, piece.pts[k].second);
                else CGPathAddLineToPoint(m, nullptr, piece.pts[k].first, piece.pts[k].second);
            if (piece.closed) CGPathCloseSubpath(m);
        }
    }
    return m;
}

// A layer projected onto the plane, kept for the projection in use (and the globe's turn).
// On the globe, shapes are cut where they go behind (adif::projectShape).
CGPathRef projectedLayer(const adif::Projector &pr, adif::MapLayer l, int maxRank) {
    static std::map<std::tuple<int, int>, CGPathRef> cache;
    static std::tuple<int, long, long> cachedFor{-1, 0, 0};
    std::tuple<int, long, long> key{(int)pr.kind(), std::lround(pr.centerLat() * 1e6), std::lround(pr.centerLon() * 1e6)};
    if (key != cachedFor) {
        for (auto &kv : cache) CGPathRelease(kv.second);
        cache.clear();
        cachedFor = key;
    }
    CGPathRef &p = cache[{(int)l, maxRank}];
    if (p) return p;
    bool polygons = l == adif::MapLayer::Land110 || l == adif::MapLayer::Land50 || l == adif::MapLayer::Lakes110 || l == adif::MapLayer::Lakes50;
    CGMutablePathRef m = CGPathCreateMutable();
    for (size_t i = 0; i < adif::layerShapeCount(l); ++i) {
        if (adif::layerShapeRank(l, i) > maxRank) continue;
        for (const adif::ShapePiece &piece : adif::projectShape(pr, adif::layerShape(l, i), polygons, false)) {
            for (size_t k = 0; k < piece.pts.size(); ++k)
                if (k == 0) CGPathMoveToPoint(m, nullptr, piece.pts[k].first, piece.pts[k].second);
                else CGPathAddLineToPoint(m, nullptr, piece.pts[k].first, piece.pts[k].second);
            if (piece.closed) CGPathCloseSubpath(m);
        }
    }
    p = m;
    return p;
}

}  // namespace mapkit

@implementation ADIFMapView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _style.layer[kLayerSquares].show = _style.layer[kLayerCountries].show = _style.layer[kLayerPota].show = true;
        _zoom = 1;
        _minYear = _maxYear = 0;
        _hasHome = false;
        _homeLat = _homeLon = 0;
    }
    return self;
}

- (BOOL)isFlipped {
    return NO;
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}
- (double)zoom {
    return _zoom;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                                     NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (ADIFMapAgg)aggregate:(const std::vector<size_t> &)qsos {
    ADIFMapAgg a;
    std::map<std::string, size_t> bands;
    size_t modes[3] = {0, 0, 0};
    std::string first;
    for (size_t i : qsos) {
        if (i >= _data.qsos.size()) continue;
        const adif::MapQso &q = _data.qsos[i];
        ++a.count;
        a.confirmed |= q.confirmed;
        if (!q.band.empty()) ++bands[q.band];
        ++modes[std::clamp(q.modeGroup, 0, 2)];
        if (q.date8.size() == 8 && (first.empty() || q.date8 < first)) first = q.date8;
    }
    size_t most = 0;
    for (const auto &kv : bands)  // ties: the lower band
        if (kv.second > most || (kv.second == most && bandIndex(kv.first) < bandIndex(a.band))) most = kv.second, a.band = kv.first;
    a.mode = modes[0] >= modes[1] && modes[0] >= modes[2] ? 0 : modes[1] >= modes[2] ? 1 : 2;
    a.year = first.empty() ? 0 : std::atoi(first.substr(0, 4).c_str());
    return a;
}

- (void)setData:(const adif::MapData &)data entities:(const std::vector<ADIFMapEntity> &)entities {
    _data = data;
    _entities = entities;
    _squareAgg.clear();
    _entityAgg.clear();
    _contactAgg.clear();
    _contacts.clear();
    for (const adif::MapSquare &sq : _data.squares) _squareAgg.push_back([self aggregate:sq.qsoIndex]);
    for (const ADIFMapEntity &e : _entities) _entityAgg.push_back([self aggregate:e.qsos]);
    std::map<std::pair<long, long>, size_t> at;  // QSOs at the same place (to about 10 m) share a marker
    for (size_t i = 0; i < _data.qsos.size(); ++i) {
        const adif::MapQso &q = _data.qsos[i];
        if (!q.located) continue;
        auto [it, added] = at.emplace(std::make_pair(std::lround(q.lat * 1e4), std::lround(q.lon * 1e4)), _contacts.size());
        if (added) _contacts.push_back({q.lat, q.lon, {}});
        _contacts[it->second].qsos.push_back(i);
    }
    for (const ADIFMapContact &c : _contacts) _contactAgg.push_back([self aggregate:c.qsos]);
    for (auto &m : _areaQsos) m.clear();
    for (auto &m : _areaAgg) m.clear();
    for (size_t i = 0; i < _data.qsos.size(); ++i) {
        const adif::QsoAreas &a = _data.qsos[i].areas;
        if (!a.state.empty()) _areaQsos[kLayerStates][a.state].push_back(i);
        if (!a.county.empty()) _areaQsos[kLayerCounties][a.county].push_back(i);
        if (a.cq) _areaQsos[kLayerCq][std::to_string(a.cq)].push_back(i);
        if (a.itu) _areaQsos[kLayerItu][std::to_string(a.itu)].push_back(i);
    }
    for (size_t l = 0; l < kLayerCount; ++l)
        for (const auto &[name, qsos] : _areaQsos[l]) _areaAgg[l][name] = [self aggregate:qsos];
    _iotaQsos.clear();
    _potaWork.clear();
    ++_dataGeneration;
    for (size_t i = 0; i < _data.qsos.size(); ++i) {
        if (!_data.qsos[i].iota.empty()) _iotaQsos[_data.qsos[i].iota].push_back(i);
        for (const std::string &ref : _data.qsos[i].potaHunted) _potaWork[ref].hunted.push_back(i);
        for (const std::string &ref : _data.qsos[i].potaActivated) _potaWork[ref].activated.push_back(i);
    }
    std::set<std::string> bands;
    _minYear = _maxYear = 0;
    for (const adif::MapQso &q : _data.qsos) {
        if (!q.band.empty()) bands.insert(q.band);
        int y = q.date8.size() == 8 ? std::atoi(q.date8.substr(0, 4).c_str()) : 0;
        if (y > 0) _minYear = _minYear ? std::min(_minYear, y) : y, _maxYear = std::max(_maxYear, y);
    }
    _bands.assign(bands.begin(), bands.end());
    std::sort(_bands.begin(), _bands.end(), [](const std::string &a, const std::string &b) {
        int x = bandIndex(a), y = bandIndex(b);
        if (x < 0) x = 1000;
        if (y < 0) y = 1000;
        return x != y ? x < y : a < b;
    });
    _hover = ADIFMapHit();
    _selected = ADIFMapHit();
    self.needsDisplay = YES;
}

- (void)setProjector:(const adif::Projector &)projector home:(NSString *)homeGrid lat:(double)lat lon:(double)lon {
    bool same = projector.kind() == _base.kind() && projector.centerLat() == _base.centerLat() && projector.centerLon() == _base.centerLon();
    _base = projector;
    if (!same) _pr = projector;
    _homeGrid = homeGrid;
    _hasHome = homeGrid.length > 0;
    _homeLat = lat, _homeLon = lon;
    if (!same) [self showWorld];
    else self.needsDisplay = YES;
}

- (const std::vector<ADIFMapContact> &)contacts {
    return _contacts;
}

- (void)setParkFilter:(const adif::MapFilter &)filter on:(BOOL)on {
    _parkFilter = filter, _filterParks = on;
    _parksPlacedFor = {};
    self.needsDisplay = YES;
}

- (std::vector<size_t>)areaQsos:(int)layer name:(const std::string &)name {
    if (layer < 0 || layer >= kLayerCount) return {};
    auto it = _areaQsos[(size_t)layer].find(name);
    return it == _areaQsos[(size_t)layer].end() ? std::vector<size_t>() : it->second;
}

- (std::vector<size_t>)iotaQsos:(const std::string &)ref {
    auto it = _iotaQsos.find(ref);
    return it == _iotaQsos.end() ? std::vector<size_t>() : it->second;
}

- (ADIFParkWork)parkWork:(const std::string &)ref {
    // The log's references as written, matched through the list (an old K- reference is the US- park).
    ADIFParkWork out;
    const adif::PotaParks &list = ADIFPotaParks();
    for (const auto &[key, work] : _potaWork) {
        const adif::PotaPark *p = list.find(key);
        if (key != ref && (!p || p->ref != ref)) continue;
        out.hunted.insert(out.hunted.end(), work.hunted.begin(), work.hunted.end());
        out.activated.insert(out.activated.end(), work.activated.begin(), work.activated.end());
    }
    return out;
}

// Where the clicked thing is (a contact, square, park or DXCC entity) and what to call it;
// with nothing clicked, the middle of the map.
- (void)selectedPlace:(double *)lat lon:(double *)lon name:(std::string *)name {
    const ADIFMapHit &h = _selected;
    double la = 0, lo = 0;
    *name = "";
    if (h.kind == ADIFMapHit::Contact && h.index < _contacts.size()) {
        la = _contacts[h.index].lat, lo = _contacts[h.index].lon;
        if (!_contacts[h.index].qsos.empty() && _contacts[h.index].qsos[0] < _data.qsos.size()) *name = _data.qsos[_contacts[h.index].qsos[0]].call;
    } else if (h.kind == ADIFMapHit::Dxcc && h.index < _entities.size()) {
        la = _entities[h.index].lat, lo = _entities[h.index].lon, *name = _entities[h.index].name;
    } else if (h.kind == ADIFMapHit::Park && h.index < _data.parks.size() && adif::gridToLatLon(_data.parks[h.index].grid, &la, &lo)) {
        *name = _data.parks[h.index].program + " " + _data.parks[h.index].reference;
    } else if (h.kind == ADIFMapHit::Pota && h.index < ADIFPotaParks().size()) {
        const adif::PotaPark &p = ADIFPotaParks().parks()[h.index];
        la = p.lat, lo = p.lon, *name = p.ref + " " + p.name;
    } else if (h.kind == ADIFMapHit::Iota && h.index < ADIFIotaGroups().size()) {
        const adif::IotaGroup &g = ADIFIotaGroups()[h.index];
        la = (g.south + g.north) / 2, lo = (g.west + g.east) / 2;
        if (lo > 180) lo -= 360;
        *name = g.ref + " " + g.name;
    } else if (!h.square.empty() && adif::gridToLatLon(h.square, &la, &lo)) {
        *name = h.square;
    } else {
        NSRect b = self.bounds;
        [self lonLatAt:NSMakePoint(NSMidX(b), NSMidY(b)) lon:&lo lat:&la];
    }
    *lat = la, *lon = lo;
}

- (void)setShowContacts:(BOOL)on {
    _showContacts = on;
    self.needsDisplay = YES;
}

- (void)setStyle:(ADIFMapStyle)style {
    _style = style;
    self.needsDisplay = YES;
}

- (void)setHiddenPrograms:(std::set<std::string>)hidden {
    _hiddenPrograms = hidden;
    self.needsDisplay = YES;
}

// ── The plane and the view ──

- (double)ppu {  // pixels per plane unit
    double minX, minY, maxX, maxY;
    _pr.bounds(&minX, &minY, &maxX, &maxY);
    NSRect b = self.bounds;
    return std::min(b.size.width / (maxX - minX), b.size.height / (maxY - minY)) * _zoom;
}

- (BOOL)globe {
    return _pr.kind() == adif::Projection::Globe;
}

// The globe turns rather than pans: the place at plane point (x, y) becomes the centre.
- (void)turnTo:(double)x y:(double)y {
    double lon, lat;
    if (!_pr.inverse(x, y, &lon, &lat)) return;
    _pr = adif::Projector(adif::Projection::Globe, lat, lon);
    [self viewChanged];
}

// Turn the globe so its surface moves (dx, dy) plane units: exactly with the pointer at the
// centre, where a unit is a degree of arc. North stays up, so it stops with a pole in the
// middle; near a pole, sideways moves spin the globe about it.
- (void)rotateBy:(double)dx y:(double)dy {
    double lat = std::clamp(_pr.centerLat() - dy, -90.0, 90.0);
    double lon = _pr.centerLon() - dx / std::max(std::cos(_pr.centerLat() * M_PI / 180), 0.2);
    _pr = adif::Projector(adif::Projection::Globe, lat, lon);
    [self viewChanged];
}

- (BOOL)atHome {
    return std::fabs(_pr.centerLat() - _base.centerLat()) < 1e-9 && std::fabs(_pr.centerLon() - _base.centerLon()) < 1e-9;
}

- (void)clampCenter {
    if ([self globe]) {  // always centred on the globe's centre
        _cx = _cy = 0;
        return;
    }
    double ppu = [self ppu];
    if (ppu <= 0) return;
    double minX, minY, maxX, maxY;
    _pr.bounds(&minX, &minY, &maxX, &maxY);
    double halfW = self.bounds.size.width / 2 / ppu, halfH = self.bounds.size.height / 2 / ppu;
    _cx = halfW >= (maxX - minX) / 2 ? (minX + maxX) / 2 : std::clamp(_cx, minX + halfW, maxX - halfW);
    _cy = halfH >= (maxY - minY) / 2 ? (minY + maxY) / 2 : std::clamp(_cy, minY + halfH, maxY - halfH);
}

- (NSPoint)planeToView:(double)x y:(double)y {
    double ppu = [self ppu];
    return NSMakePoint(NSMidX(self.bounds) + (x - _cx) * ppu, NSMidY(self.bounds) + (y - _cy) * ppu);
}

- (void)viewToPlane:(NSPoint)p x:(double *)x y:(double *)y {
    double ppu = [self ppu];
    *x = _cx + (p.x - NSMidX(self.bounds)) / ppu;
    *y = _cy + (p.y - NSMidY(self.bounds)) / ppu;
}

// A point on the map in view coordinates; far outside the view when it has no place.
- (NSPoint)viewPointForLon:(double)lon lat:(double)lat {
    double x, y;
    if (!_pr.forward(lon, lat, &x, &y)) return NSMakePoint(-1e6, -1e6);
    return [self planeToView:x y:y];
}

- (BOOL)lonLatAt:(NSPoint)p lon:(double *)lon lat:(double *)lat {
    double x, y;
    [self viewToPlane:p x:&x y:&y];
    return _pr.inverse(x, y, lon, lat);
}

// A run of (lon, lat) points as a path in view coordinates: on the globe, cut where it goes
// behind (a closed shape follows the rim there); on a flat map, cut where it crosses the
// 180th meridian when it `wraps` (paths and rings do, the grid doesn't).
- (NSBezierPath *)viewPath:(const std::vector<std::pair<double, double>> &)pts close:(BOOL)close wraps:(BOOL)wraps {
    NSBezierPath *path = [NSBezierPath bezierPath];
    for (const adif::ShapePiece &piece : adif::projectShape(_pr, pts, close, wraps)) {
        for (size_t k = 0; k < piece.pts.size(); ++k) {
            NSPoint v = [self planeToView:piece.pts[k].first y:piece.pts[k].second];
            if (k == 0) [path moveToPoint:v];
            else [path lineToPoint:v];
        }
        if (piece.closed) [path closePath];
    }
    return path;
}

// A 4-character square's outline, its edges curved as the projection bends them.
- (NSBezierPath *)squarePath:(const std::string &)grid {
    double w, s, e, n;
    if (!adif::squareBounds(grid, &w, &s, &e, &n)) return nil;
    int steps = _pr.kind() == adif::Projection::Equirectangular ? 1 : 4;
    std::vector<std::pair<double, double>> pts;
    for (int i = 0; i < steps; ++i) pts.emplace_back(w + (e - w) * i / steps, s);
    for (int i = 0; i < steps; ++i) pts.emplace_back(e, s + (n - s) * i / steps);
    for (int i = 0; i < steps; ++i) pts.emplace_back(e - (e - w) * i / steps, n);
    for (int i = 0; i < steps; ++i) pts.emplace_back(w, n - (n - s) * i / steps);
    return [self viewPath:pts close:YES wraps:NO];
}

// One box of an IOTA group (adif::iotaBoxes), its edges curved as the projection bends them.
- (NSBezierPath *)iotaBoxPath:(const std::array<double, 4> &)box {
    bool straight = _pr.kind() == adif::Projection::Equirectangular || _pr.kind() == adif::Projection::Mercator;
    double w = box[0], s = box[1], e = box[2], n = box[3];
    int sx = straight ? 1 : std::max(1, (int)std::ceil((e - w) / 2)), sy = straight ? 1 : std::max(1, (int)std::ceil((n - s) / 2));
    std::vector<std::pair<double, double>> pts;
    for (int i = 0; i < sx; ++i) pts.emplace_back(w + (e - w) * i / sx, s);
    for (int i = 0; i < sy; ++i) pts.emplace_back(e, s + (n - s) * i / sy);
    for (int i = 0; i < sx; ++i) pts.emplace_back(e - (e - w) * i / sx, n);
    for (int i = 0; i < sy; ++i) pts.emplace_back(w, n - (n - s) * i / sy);
    return [self viewPath:pts close:YES wraps:NO];
}

// The longitudes and latitudes in view (sampled; the whole world when it all shows).
- (void)visibleWest:(double *)west south:(double *)south east:(double *)east north:(double *)north {
    *west = 180, *east = -180, *south = 90, *north = -90;
    NSRect b = self.bounds;
    int hits = 0;
    for (int i = 0; i <= 8; ++i)
        for (int j = 0; j <= 8; ++j) {
            double lon, lat;
            if (![self lonLatAt:NSMakePoint(NSMinX(b) + b.size.width * i / 8, NSMinY(b) + b.size.height * j / 8) lon:&lon lat:&lat]) continue;
            ++hits;
            *west = std::min(*west, lon), *east = std::max(*east, lon), *south = std::min(*south, lat), *north = std::max(*north, lat);
        }
    for (double pole : {90.0, -90.0}) {  // a pole in view: every longitude, up to the pole
        NSPoint at = [self viewPointForLon:0 lat:pole];
        if (!NSPointInRect(at, b)) continue;
        *west = -180, *east = 180;
        if (pole > 0) *north = 90;
        else *south = -90;
    }
    if (hits < 81 || [self globe] || *east - *west > 300) {  // edges show, or the view wraps
        if (_zoom < 2 || hits < 81) *west = -180, *east = 180, *south = -90, *north = 90;
    }
    *west = std::max(-180.0, *west - 2), *east = std::min(180.0, *east + 2);
    *south = std::max(-90.0, *south - 1), *north = std::min(90.0, *north + 1);
}

// Pixels across a span of longitude at a place, for sizing labels and the square grid.
- (double)pixelsForLon:(double)lon lat:(double)lat span:(double)span {
    NSPoint a = [self viewPointForLon:lon - span / 2 lat:lat], b = [self viewPointForLon:lon + span / 2 lat:lat];
    if (a.x < -1e5 || b.x < -1e5) return 0;
    return std::hypot(b.x - a.x, b.y - a.y);
}

- (void)viewChanged {
    [self clampCenter];
    self.needsDisplay = YES;
    if (self.onViewChanged) self.onViewChanged();
}

- (void)zoomBy:(double)factor at:(NSPoint)p {
    double x, y;
    [self viewToPlane:p x:&x y:&y];
    double z = std::clamp(_zoom * factor, 1.0, std::max([self maxZoomHere], _zoom));
    if (z == _zoom) return;
    if ([self globe]) {  // turn toward the pointer so the place under it stays about there
        double f = z / _zoom;
        _zoom = z;
        [self turnTo:x * (1 - 1 / f) y:y * (1 - 1 / f)];
        return;
    }
    _zoom = z;
    double ppu = [self ppu];  // keep the point under the pointer where it was
    _cx = x - (p.x - NSMidX(self.bounds)) / ppu;
    _cy = y - (p.y - NSMidY(self.bounds)) / ppu;
    [self viewChanged];
}

- (void)zoomBy:(double)factor {
    [self zoomBy:factor at:NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds))];
}

- (void)showWorld {
    _pr = _base;  // the globe back on home
    double minX, minY, maxX, maxY;
    _pr.bounds(&minX, &minY, &maxX, &maxY);
    _zoom = 1, _cx = (minX + maxX) / 2, _cy = (minY + maxY) / 2;
    [self viewChanged];
}

// Zoom to a box of longitudes and latitudes (a continent): the flat maps fit it, the globe
// turns to face its middle (a pole, for a box that reaches one) and fits it.
- (void)showWest:(double)w south:(double)s east:(double)e north:(double)n {
    if ([self globe]) {
        double clat = s <= -89.9 ? -90 : n >= 89.9 ? 90 : (s + n) / 2;
        _pr = adif::Projector(adif::Projection::Globe, clat, (w + e) / 2);
    } else {
        _pr = _base;
    }
    double west = 1e9, east = -1e9, south = 1e9, north = -1e9;
    for (int i = 0; i <= 24; ++i)
        for (int j = 0; j <= 12; ++j) {
            double x, y;
            if (!_pr.forward(w + (e - w) * i / 24, s + (n - s) * j / 12, &x, &y)) continue;
            west = std::min(west, x), east = std::max(east, x), south = std::min(south, y), north = std::max(north, y);
        }
    if (west > east) return [self showWorld];
    [self fitPlaneWest:west south:south east:east north:north];
}

- (void)fitLog {
    _pr = _base;
    double west = 1e9, east = -1e9, south = 1e9, north = -1e9;
    auto add = [&](double lon, double lat) {
        double x, y;
        if (!_pr.forward(lon, lat, &x, &y)) return;
        west = std::min(west, x), east = std::max(east, x), south = std::min(south, y), north = std::max(north, y);
    };
    if (_style[kLayerSquares].show)
        for (const adif::MapSquare &sq : _data.squares) {
            double w, s, e, n;
            if (adif::squareBounds(sq.grid, &w, &s, &e, &n)) add(w, s), add(e, n), add(w, n), add(e, s);
        }
    if (_style[kLayerCountries].show)
        for (const ADIFMapEntity &e : _entities) add(e.lon, e.lat);
    if (_showContacts)
        for (const ADIFMapContact &c : _contacts) add(c.lon, c.lat);
    for (const std::string &g : _data.mine) {
        double lat, lon;
        if (adif::gridToLatLon(g, &lat, &lon)) add(lon, lat);
    }
    if (west > east) return [self showWorld];
    [self fitPlaneWest:west south:south east:east north:north];
}

// Fit the view to a part of the plane; on the globe, centred where it is turned to.
- (void)fitPlaneWest:(double)west south:(double)south east:(double)east north:(double)north {
    if ([self globe]) {  // the span is twice the farthest point in front
        double r = std::max({std::fabs(west), std::fabs(east), std::fabs(south), std::fabs(north)});
        west = -r, east = r, south = -r, north = r;
    }
    double spanX = std::max(8.0, (east - west) * 1.15), spanY = std::max(4.0, (north - south) * 1.15);
    double minX, minY, maxX, maxY;
    _pr.bounds(&minX, &minY, &maxX, &maxY);
    NSRect b = self.bounds;
    double base = std::min(b.size.width / (maxX - minX), b.size.height / (maxY - minY));
    _zoom = std::clamp(std::min(b.size.width / spanX, b.size.height / spanY) / base, 1.0, kMaxZoom);  // a region: not into Map Detail
    _cx = (west + east) / 2, _cy = (south + north) / 2;
    [self viewChanged];
}

// ── Colours of things ──

// By band: PSKReporter's colours, or on the colour-blind safe palette its own set, given to
// the log's most used bands.
- (NSColor *)bandColor:(const std::string &)band {
    const MapPalette &p = paletteAt(_style.palette);
    if (!p.safeBands) return rgb(adif::pskReporterBandColour(band));
    static std::map<std::string, size_t> countedFor;
    static std::map<std::string, unsigned> colours;
    if (countedFor != _qsosPerBand) countedFor = _qsosPerBand, colours = adif::colourBlindBandColours(_qsosPerBand);
    for (const auto &kv : colours)
        if (adif::equalsNoCase(kv.first, band)) return rgb(kv.second);
    return rgb(adif::kUnknownBandColour);
}

- (void)setQsosPerBand:(std::map<std::string, size_t>)counts {
    _qsosPerBand = counts;
    self.needsDisplay = YES;
}

- (NSColor *)colorFor:(const ADIFMapAgg &)a entity:(BOOL)entity {
    const MapPalette &p = paletteAt(_style.palette);
    switch (_style.colorBy) {
        case 1: return [self bandColor:a.band];
        case 2: return rgb(p.qualitative[(size_t)std::clamp(a.mode, 0, 2) % p.qualitative.size()]);
        case 3: return ramp(countBucket(a.count) / 4.0, p);
        case 4: return ramp(_maxYear > _minYear && a.year ? (double)(a.year - _minYear) / (_maxYear - _minYear) : 1.0, p);
        default: return rgb(entity ? (a.confirmed ? p.dxccConfirmed : p.dxccWorked) : (a.confirmed ? p.confirmed : p.worked));
    }
}

- (NSColor *)programColor:(const std::string &)program {
    const MapPalette &p = paletteAt(_style.palette);
    size_t i = kProgramCount;
    for (size_t k = 0; k < kProgramCount; ++k)
        if (program == kPrograms[k].key) i = k;
    if (i == kProgramCount) {  // a program the map doesn't list: a stable colour from its name
        size_t h = 0;
        for (char c : program) h = h * 31 + (unsigned char)c;
        i = h;
    }
    return rgb(p.qualitative[i % p.qualitative.size()]);
}

// A marker centred on p: kind 0 dot, 1 triangle, 2 diamond, 3 star, 4 pin (its point at p),
// 5 crosshair; Style's shape overrides 0-2.
- (NSBezierPath *)marker:(int)kind at:(NSPoint)p size:(double)r {
    if (kind < 3 && _style.shape == 1) kind = 0;
    if (kind < 3 && _style.shape == 2) return [NSBezierPath bezierPathWithRect:NSMakeRect(p.x - r * 0.85, p.y - r * 0.85, r * 1.7, r * 1.7)];
    NSBezierPath *m = [NSBezierPath bezierPath];
    switch (kind) {
        case 4: {  // a head of radius r, 2.2 r above the point, the sides tangent to it
            NSPoint head = NSMakePoint(p.x, p.y + 2.2 * r);
            double t = std::acos(1 / 2.2) * 180 / M_PI;  // the tangent points, from straight down
            [m moveToPoint:p];
            [m appendBezierPathWithArcWithCenter:head radius:r startAngle:-90 + t endAngle:270 - t clockwise:NO];
            [m closePath];
            [m appendBezierPathWithOvalInRect:NSMakeRect(head.x - r * 0.38, head.y - r * 0.38, r * 0.76, r * 0.76)];
            m.windingRule = NSWindingRuleEvenOdd;  // the head's hole
            return m;
        }
        case 5:
            [m appendBezierPathWithOvalInRect:NSMakeRect(p.x - r, p.y - r, 2 * r, 2 * r)];
            [m moveToPoint:NSMakePoint(p.x - r * 1.6, p.y)];
            [m lineToPoint:NSMakePoint(p.x + r * 1.6, p.y)];
            [m moveToPoint:NSMakePoint(p.x, p.y - r * 1.6)];
            [m lineToPoint:NSMakePoint(p.x, p.y + r * 1.6)];
            return m;
        case 1:
            [m moveToPoint:NSMakePoint(p.x, p.y + r * 1.15)];
            [m lineToPoint:NSMakePoint(p.x - r, p.y - r * 0.75)];
            [m lineToPoint:NSMakePoint(p.x + r, p.y - r * 0.75)];
            break;
        case 2:
            [m moveToPoint:NSMakePoint(p.x, p.y + r)];
            [m lineToPoint:NSMakePoint(p.x - r * 0.9, p.y)];
            [m lineToPoint:NSMakePoint(p.x, p.y - r)];
            [m lineToPoint:NSMakePoint(p.x + r * 0.9, p.y)];
            break;
        case 3:
            for (int k = 0; k < 10; ++k) {
                double a = M_PI / 2 + k * M_PI / 5, rad = k % 2 ? r * 0.4 : r;
                NSPoint q = NSMakePoint(p.x + rad * std::cos(a), p.y + rad * std::sin(a));
                if (k == 0) [m moveToPoint:q];
                else [m lineToPoint:q];
            }
            break;
        default: return [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - r, p.y - r, 2 * r, 2 * r)];
    }
    [m closePath];
    return m;
}

- (double)dotRadius:(size_t)qsos {
    return std::min(8.0, 3.0 + std::log2((double)qsos + 1)) * _style.marker;
}

// An overlay area's outline as lines: each ring closed, its edges followed in steps of a
// degree or so (zone lines run along parallels and meridians), but not along the 180th
// meridian, where a shape is cut that goes on beyond, nor along 85 degrees north or south,
// the edge of the web map the zone files were drawn for (no zone line runs there).
- (NSBezierPath *)outlineOf:(const adif::OverlayArea &)a {
    NSBezierPath *path = [NSBezierPath bezierPath];
    for (const auto &ring : a.rings) {
        std::vector<std::pair<double, double>> run;
        auto flush = [&]() {
            if (run.size() > 1) [path appendBezierPath:[self viewPath:run close:NO wraps:YES]];
            run.clear();
        };
        size_t n = ring.size();
        for (size_t k = 0; k <= n; ++k) {
            std::pair<double, double> p = ring[k % n];
            if (!run.empty()) {
                std::pair<double, double> q = run.back();
                bool cut = (std::fabs(q.first) > 179.99 && std::fabs(p.first) > 179.99 && q.first * p.first > 0) ||
                           (std::fabs(q.second) > 84.99 && std::fabs(p.second) > 84.99 && q.second * p.second > 0);
                if (cut) {
                    flush();
                } else if (std::fabs(p.first - q.first) <= 180) {
                    int steps = (int)std::ceil(std::max(std::fabs(p.first - q.first), std::fabs(p.second - q.second)));
                    for (int j = 1; j < steps; ++j)
                        run.emplace_back(q.first + (p.first - q.first) * j / steps, q.second + (p.second - q.second) * j / steps);
                }
            }
            run.push_back(p);
        }
        flush();
    }
    return path;
}

// A line to a contact as Options sets it: solid, dashed or dotted; thin, medium or thick.
- (void)styleLine:(NSBezierPath *)path {
    static const double kWidths[] = {0.6, 1.0, 1.8};
    double w = kWidths[std::clamp(_style.lineWidth, 0, 2)];
    path.lineWidth = w;
    if (_style.lineStyle == 1) {
        CGFloat dash[] = {(CGFloat)(5 + 2 * w), (CGFloat)(3 + w)};
        [path setLineDash:dash count:2 phase:0];
    } else if (_style.lineStyle == 2) {
        CGFloat dot[] = {0, (CGFloat)(2 + 1.5 * w)};
        [path setLineDash:dot count:2 phase:0];
        path.lineCapStyle = NSLineCapStyleRound;
    }
}

// The contact marker's shape and size, by Style Options.
- (NSBezierPath *)contactMarkerAt:(NSPoint)p {
    switch (_style.contact) {
        case 1: return [self marker:0 at:p size:3 * _style.marker];
        case 2: return [self marker:5 at:p size:3.6 * _style.marker];
        default: return [self marker:4 at:p size:kPin * _style.marker];
    }
}

- (BOOL)programShown:(const adif::MapPark &)pk {
    return pk.program == "POTA" ? _style[kLayerPota].show : !_hiddenPrograms.count(pk.program);
}

// A POTA park the POTA overlay pins at the park itself, so the Parks layer leaves it out.
- (BOOL)parkPinned:(const adif::MapPark &)pk {
    if (!_style[kLayerPota].show || pk.program != "POTA") return NO;
    const adif::PotaPark *p = ADIFPotaParks().find(pk.reference);
    return p && p->placed;
}

// ── Drawing ──

- (void)drawLabel:(NSString *)text at:(NSPoint)p size:(CGFloat)size alpha:(CGFloat)alpha {
    const MapPalette &pal = paletteAt(_style.palette);
    NSDictionary *attrs = @{NSFontAttributeName : [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:alpha]};
    NSSize s = [text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint(p.x - s.width / 2, p.y - s.height / 2) withAttributes:attrs];
}

// On the night palette the map is drawn off screen and shown as reds of its brightness (red on
// black keeps night vision), the legend and labels too; in an exported PNG as well.
- (void)drawRect:(NSRect)dirty {
    if (!paletteAt(_style.palette).night) {
        [self drawMap];
        return;
    }
    NSRect b = self.bounds;
    CGFloat scale = self.window ? self.window.backingScaleFactor : 2;
    NSInteger w = (NSInteger)std::ceil(b.size.width * scale), h = (NSInteger)std::ceil(b.size.height * scale);
    if (w <= 0 || h <= 0) return;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                    pixelsWide:w
                                                                    pixelsHigh:h
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    rep.size = b.size;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *off = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext setCurrentContext:off];
    CGContextTranslateCTM(off.CGContext, -NSMinX(b), -NSMinY(b));
    [self drawMap];
    [NSGraphicsContext restoreGraphicsState];
    unsigned char *data = rep.bitmapData;
    NSInteger row = rep.bytesPerRow;
    for (NSInteger y = 0; y < h; ++y)
        for (NSInteger x = 0; x < w; ++x) {
            unsigned char *p = data + y * row + x * 4;
            double lum = 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2];  // premultiplied, so dark where transparent
            p[0] = (unsigned char)std::min<double>(p[3], lum * 1.15), p[1] = (unsigned char)(lum * 0.10), p[2] = (unsigned char)(lum * 0.06);
        }
    // In the screen's own colours: its red, with no green or blue added by a colour conversion.
    NSColorSpace *screen = self.window.colorSpace;
    if (screen && screen.colorSpaceModel == NSColorSpaceModelRGB)
        if (NSBitmapImageRep *shown = [rep bitmapImageRepByRetaggingWithColorSpace:screen]) rep = shown;
    [rep drawInRect:b];
}

- (void)drawMap {
    MapDrawCtx d;
    [self drawBase:d];
    [self drawOsm:d];  // Map Detail, where downloaded
    [self drawGridLines:d];
    [self drawDxccLand:d];
    [self drawWorkedAreas:d];
    [self drawOverlays:d];
    [self drawIota:d];
    [self drawDayNight:d];  // over the land and areas, under the markers and labels
    // POTA: the parks you haven't worked (rings, or dots when there are many); the worked ones' pins go on top, with the markers.
    [self placeParks];
    [self drawParkRings];
    [self drawCities:d];
    [self drawLines:d];
    [self drawSquares:d];
    [self drawGridLabels:d];
    [self drawRings:d];
    [self drawDxccDots:d];
    [self drawContacts:d];
    [self drawPrograms:d];
    [self drawParkPins];
    if (_style[kLayerPota].labels) [self drawParkLabelsIn:d.b];
    [self drawMine:d];
    [self drawSelection:d];
    CGContextRestoreGState(d.ctx);
    if (_style.legend) [self drawLegend];
    [self drawOsmCredit];
    CGContextRestoreGState(d.ctx);
}

// The key to the colours and markers, bottom left (in the PNG too).
- (void)drawLegend {
    const MapPalette &pal = paletteAt(_style.palette);
    struct Entry {
        // 0 swatch, 1 dot, 2 triangle, 3 diamond, 4 star, 5 line, 6 contact marker, 7 heading, 8 plain text, 9 dashed box,
        // 10 park pin (hunted), 11 park pin (activated), 12 ring
        int kind;
        NSColor *color;
        std::string text;
    };
    std::vector<Entry> rows;
    if ([self globe]) {
        std::string centre = adif::squareAt(_pr.centerLon() >= 180 ? _pr.centerLon() - 360 : _pr.centerLon(), std::clamp(_pr.centerLat(), -89.999, 89.999));
        rows.push_back({8, nil, [self atHome] && _hasHome ? "Centre: " + centre + " (home)" : "Centre: " + centre + (_hasHome ? "; World goes home" : "")});
    }
    static const char *const kBy[] = {"Colour: confirmed or not", "Colour: band (the most QSOs)", "Colour: mode (the most QSOs)",
                                      "Colour: QSO count", "Colour: year first worked"};
    bool contacts = _showContacts && !_contacts.empty();
    bool areas = false;  // states, counties or zones worked, shaded in the map's colours
    for (int l : {kLayerStates, kLayerCounties, kLayerCq, kLayerItu}) areas |= _style.layer[l].show;
    if (_style[kLayerSquares].show || _style[kLayerCountries].show || contacts || areas) {
        rows.push_back({7, nil, kBy[std::clamp(_style.colorBy, 0, 4)]});
        switch (_style.colorBy) {
            case 1:
                if (pal.safeBands) {  // the bands with a colour, then the grey ones in one row
                    std::string others;
                    for (const std::string &band : _bands) {
                        NSColor *c = [self bandColor:band];
                        if ([c isEqual:rgb(adif::kUnknownBandColour)]) others += (others.empty() ? "" : ", ") + band;
                        else rows.push_back({0, c, band});
                    }
                    if (!others.empty()) rows.push_back({0, rgb(adif::kUnknownBandColour), "other bands: " + others});
                } else {
                    for (size_t i = 0; i < _bands.size() && i < 14; ++i) rows.push_back({0, [self bandColor:_bands[i]], _bands[i]});
                }
                break;
            case 2:
                for (int m = 0; m < 3; ++m) rows.push_back({0, rgb(pal.qualitative[(size_t)m % pal.qualitative.size()]), kModeLabels[m]});
                break;
            case 3:
                for (int k = 0; k < 5; ++k) rows.push_back({0, ramp(k / 4.0, pal), kCountLabels[k]});
                break;
            case 4:
                if (_maxYear && _maxYear - _minYear <= 7)
                    for (int y = _minYear; y <= _maxYear; ++y)
                        rows.push_back({0, ramp(_maxYear > _minYear ? (double)(y - _minYear) / (_maxYear - _minYear) : 1, pal), std::to_string(y)});
                else if (_maxYear)
                    for (int k = 0; k < 5; ++k) {
                        int y = _minYear + (int)std::lround((_maxYear - _minYear) * k / 4.0);
                        rows.push_back({0, ramp(k / 4.0, pal), std::to_string(y)});
                    }
                break;
            default:
                if (_style[kLayerSquares].show || contacts || areas) rows.push_back({0, rgb(pal.confirmed), "confirmed"}), rows.push_back({0, rgb(pal.worked), "worked"});
                if (_style[kLayerCountries].show) rows.push_back({1, rgb(pal.dxccConfirmed), "DXCC confirmed"}), rows.push_back({1, rgb(pal.dxccWorked), "DXCC worked"});
                break;
        }
    }
    std::set<std::string> programs;
    bool parks = false;
    for (const adif::MapPark &pk : _data.parks)
        if ([self programShown:pk] && ![self parkPinned:pk]) pk.program == "POTA" ? (void)(parks = true) : (void)programs.insert(pk.program);
    if (contacts || parks || !programs.empty()) rows.push_back({7, nil, "Markers"});
    if (contacts) rows.push_back({6, [NSColor colorWithCalibratedWhite:pal.dark ? 0.85 : 0.35 alpha:1], "contacts (exact place)"});
    if (parks) rows.push_back({2, rgb(pal.park), "POTA parks (at the QSO's grid)"});
    for (const std::string &p : programs) rows.push_back({3, [self programColor:p], p});
    if (_style.mine && !_data.mine.empty()) rows.push_back({4, rgb(pal.me), "my station"});
    if (_style.paths) rows.push_back({5, [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:0.6], "lines to contacts (in their colours)"});
    if (_style.dayNight || _style.greyLine) {
        double at = [self qsoSunSeconds];
        time_t t = (time_t)(at >= 0 ? at : [self sunSeconds]);
        struct tm tm{};
        gmtime_r(&t, &tm);
        char when[40];
        strftime(when, sizeof when, at >= 0 ? "Sun at the QSO: %Y-%m-%d %H:%M UTC" : "Sun now: %H:%M UTC", &tm);
        rows.push_back({7, nil, when});
        if (_style.dayNight) rows.push_back({0, [NSColor colorWithCalibratedWhite:pal.dark ? 0.3 : 0.45 alpha:1], "night (darker)"});
        if (_style.greyLine) rows.push_back({0, [NSColor colorWithCalibratedRed:1 green:0.70 blue:0.25 alpha:0.6], "grey line (twilight)"});
    }
    if ((_style[kLayerPota].show || _style[kLayerPota].overlay) && ADIFPotaParks().size()) {
        std::set<std::string> hunted, activated;  // by the list's reference (K-0001 is US-0001)
        for (const auto &[ref, w] : _potaWork) {
            const adif::PotaPark *p = ADIFPotaParks().find(ref);
            if (!w.hunted.empty()) hunted.insert(p ? p->ref : ref);
            if (!w.activated.empty()) activated.insert(p ? p->ref : ref);
        }
        rows.push_back({7, nil, "POTA parks: " + std::to_string(hunted.size()) + " hunted, " + std::to_string(activated.size()) + " activated"});
        if (_style[kLayerPota].show) {
            rows.push_back({10, rgb(pal.worked), "hunted (in the map's colours)"});
            rows.push_back({11, rgb(pal.me), "activated by you"});
        }
        if (_style[kLayerPota].overlay) rows.push_back({12, rgb(pal.park), "not worked"});
    }
    if ((_style[kLayerIota].show || _style[kLayerIota].overlay) && !ADIFIotaGroups().empty()) {
        NSColor *tint = pal.dark ? rgb(0x4DD0E1) : rgb(0x00838F);
        rows.push_back({7, nil, "IOTA groups"});
        if (_style[kLayerIota].show) {
            rows.push_back({0, [tint colorWithAlphaComponent:0.42], "confirmed"});
            rows.push_back({0, [tint colorWithAlphaComponent:0.22], "worked"});
        }
        if (_style[kLayerIota].overlay) rows.push_back({9, [tint colorWithAlphaComponent:0.75], "not worked"});
    }
    if (rows.empty()) return;

    NSDictionary *text = @{NSFontAttributeName : [NSFont systemFontOfSize:11],
                           NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:0.9]};
    NSDictionary *head = @{NSFontAttributeName : [NSFont boldSystemFontOfSize:11],
                           NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:0.9]};
    CGFloat width = 0, lineH = 16;
    for (const Entry &e : rows)
        width = std::max(width, [ADIFString(e.text) sizeWithAttributes:e.kind == 7 ? head : text].width + (e.kind == 7 || e.kind == 8 ? 0 : 20));
    NSRect box = NSMakeRect(NSMinX(self.bounds) + 8, NSMinY(self.bounds) + 8, width + 16, rows.size() * lineH + 10);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:box xRadius:6 yRadius:6];
    [[NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.62] setFill];
    [bg fill];
    CGFloat y = NSMaxY(box) - 5 - lineH;
    for (const Entry &e : rows) {
        NSPoint at = NSMakePoint(NSMinX(box) + 8, y);
        if (e.kind == 10 || e.kind == 11) {
            [self drawParkPinAt:NSMakePoint(at.x + 6, y + 1) color:e.color activated:e.kind == 11 lit:NO];
            [ADIFString(e.text) drawAtPoint:NSMakePoint(at.x + 18, y + 1) withAttributes:text];
        } else if (e.kind == 7 || e.kind == 8) {
            [ADIFString(e.text) drawAtPoint:NSMakePoint(at.x, y + 1) withAttributes:e.kind == 7 ? head : text];
        } else {
            NSPoint c = NSMakePoint(at.x + 6, y + lineH / 2);
            NSBezierPath *m = nil;
            switch (e.kind) {
                case 0: m = [NSBezierPath bezierPathWithRect:NSMakeRect(c.x - 5, c.y - 5, 10, 10)]; break;
                case 1: m = [self marker:0 at:c size:4.5]; break;
                case 2: m = [self marker:1 at:c size:5]; break;
                case 3: m = [self marker:2 at:c size:5]; break;
                case 4: m = [self marker:3 at:c size:6]; break;
                case 6: m = [self contactMarkerAt:NSMakePoint(c.x, _style.contact == 0 ? c.y - 5 : c.y)]; break;
                case 12: m = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 3.5, c.y - 3.5, 7, 7)]; break;
                case 9: {
                    m = [NSBezierPath bezierPathWithRect:NSMakeRect(c.x - 5, c.y - 5, 10, 10)];
                    CGFloat dash[] = {3, 2};
                    [m setLineDash:dash count:2 phase:0];
                    break;
                }
                case 5:
                    m = [NSBezierPath bezierPath];
                    [m moveToPoint:NSMakePoint(c.x - 6, c.y)];
                    [m lineToPoint:NSMakePoint(c.x + 6, c.y)];
                    [self styleLine:m];
                    break;
                default:
                    m = [NSBezierPath bezierPath];
                    [m moveToPoint:NSMakePoint(c.x - 6, c.y)];
                    [m lineToPoint:NSMakePoint(c.x + 6, c.y)];
                    break;
            }
            if (e.kind == 5 || e.kind == 9 || e.kind == 12 || (e.kind == 6 && _style.contact == 2)) {
                if (e.kind == 6 || e.kind == 12) m.lineWidth = 1.5;
                [e.color setStroke];
                [m stroke];
            } else {
                [e.color setFill];
                [m fill];
            }
            [ADIFString(e.text) drawAtPoint:NSMakePoint(at.x + 18, y + 1) withAttributes:text];
        }
        y -= lineH;
    }
}

// ── Pointer and keys ──

- (ADIFMapHit)hitAt:(NSPoint)p {
    ADIFMapHit h;
    double lon, lat;
    if (![self lonLatAt:p lon:&lon lat:&lat]) return h;
    h.square = adif::squareAt(lon, lat);
    if (h.square.empty()) return h;
    // POTA: the pins (drawn last, on top), the rings, then the counts.
    [self placeParks];
    {  // a pin first (they're on top), else the nearest ring or dot within reach
        const ADIFParkSpot *best = nullptr;
        double bestDistance = 1e9;
        for (auto it = _potaSpots.rbegin(); it != _potaSpots.rend(); ++it) {
            double d = std::hypot(it->at.x - p.x, it->at.y - p.y);
            if (d > (it->pin ? kPin * 1.2 * _style.marker + 2 : it->dot ? 3 : 5 * _style.marker)) continue;
            if (it->pin) {
                best = &*it;
                break;
            }
            if (d < bestDistance) best = &*it, bestDistance = d;
        }
        if (best) return h.kind = ADIFMapHit::Pota, h.index = best->park, h;
    }
    for (size_t i = 0; i < _data.parks.size(); ++i) {
        if (![self programShown:_data.parks[i]] || [self parkPinned:_data.parks[i]]) continue;
        double plat, plon;
        if (!adif::gridToLatLon(_data.parks[i].grid, &plat, &plon)) continue;
        NSPoint q = [self viewPointForLon:plon lat:plat];
        if (std::hypot(q.x - p.x, q.y - p.y) <= 7 * _style.marker) return h.kind = ADIFMapHit::Park, h.index = i, h;
    }
    if (_showContacts)  // the pin's head, or the dot or crosshair
        for (size_t i = 0; i < _contacts.size(); ++i) {
            NSPoint q = [self viewPointForLon:_contacts[i].lon lat:_contacts[i].lat];
            if (_style.contact == 0) q.y += 2.2 * kPin * _style.marker;
            if (std::hypot(q.x - p.x, q.y - p.y) <= 5 * _style.marker + 1) return h.kind = ADIFMapHit::Contact, h.index = i, h;
        }
    if (_style[kLayerCountries].show)
        for (size_t i = 0; i < _entities.size(); ++i) {
            if (i < _entityDot.size() && !_entityDot[i]) continue;  // its land is shaded: found below, after the squares
            NSPoint q = [self viewPointForLon:_entities[i].lon lat:_entities[i].lat];
            if (std::hypot(q.x - p.x, q.y - p.y) <= [self dotRadius:_entities[i].qsos.size()] + 2)
                return h.kind = ADIFMapHit::Dxcc, h.index = i, h;
        }
    if (_style[kLayerSquares].show)
        for (size_t i = 0; i < _data.squares.size(); ++i)
            if (_data.squares[i].grid == h.square) return h.kind = ADIFMapHit::Square, h.index = i, h;
    // A worked county or state, more particular than the country around it.
    for (MapLayerId l : {kLayerCounties, kLayerStates})
        if (_style[l].show)
            if (size_t i = [self workedAreaAt:l lon:lon lat:lat]; i != adif::AreaIndex::npos) return h.kind = ADIFMapHit::Area, h.layer = l, h.index = i, h;
    if (_style[kLayerCountries].show) {  // a shaded entity: the point is inside an odd number of its rings
        const OverlayCache &land = overlay(adif::Overlay::Subunits);
        for (size_t i = 0; i < _entities.size(); ++i) {
            if (i >= _entityDot.size() || _entityDot[i]) continue;
            bool in = false;
            for (const adif::RingRef &ref : _entities[i].land) {
                if (ref.area >= land.areas.size() || ref.ring >= land.areas[ref.area].rings.size()) continue;
                const auto &r = land.areas[ref.area].rings[ref.ring];
                for (size_t k = 0, j = r.size() - 1; k < r.size(); j = k++)
                    if ((r[k].second > lat) != (r[j].second > lat) && lon < (r[j].first - r[k].first) * (lat - r[k].second) / (r[j].second - r[k].second) + r[k].first)
                        in = !in;
            }
            if (in) return h.kind = ADIFMapHit::Dxcc, h.index = i, h;
        }
    }
    for (MapLayerId l : {kLayerCq, kLayerItu})
        if (_style[l].show)
            if (size_t i = [self workedAreaAt:l lon:lon lat:lat]; i != adif::AreaIndex::npos) return h.kind = ADIFMapHit::Area, h.layer = l, h.index = i, h;
    if (_style[kLayerIota].show || _style[kLayerIota].overlay) {  // the smallest IOTA box the point is in
        const std::vector<adif::IotaGroup> &groups = ADIFIotaGroups();
        double best = 1e9;
        for (size_t i = 0; i < groups.size(); ++i) {
            if (!(_iotaQsos.count(groups[i].ref) ? _style[kLayerIota].show : _style[kLayerIota].overlay)) continue;
            for (const std::array<double, 4> &box : adif::iotaBoxes(groups[i])) {
                double size = (groups[i].east - groups[i].west) * (groups[i].north - groups[i].south);
                if (lon >= box[0] && lon <= box[2] && lat >= box[1] && lat <= box[3] && size < best) best = size, h.kind = ADIFMapHit::Iota, h.index = i;
            }
        }
        if (h.kind == ADIFMapHit::Iota) return h;
    }
    h.kind = ADIFMapHit::Empty;
    return h;
}

- (void)mouseMoved:(NSEvent *)event {
    ADIFMapHit h = [self hitAt:[self convertPoint:event.locationInWindow fromView:nil]];
    bool changed = h.kind != _hover.kind || h.index != _hover.index || h.square != _hover.square;
    _hover = h;
    if (!changed) return;
    self.needsDisplay = YES;
    if (self.onHover) self.onHover(h);
}

- (void)mouseExited:(NSEvent *)event {
    _hover = ADIFMapHit();
    self.needsDisplay = YES;
    if (self.onHover) self.onHover(_hover);
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    _down = [self convertPoint:event.locationInWindow fromView:nil];
    _dragged = NO;
    if (event.clickCount == 2) [self zoomBy:2 at:_down];
}

- (void)mouseDragged:(NSEvent *)event {
    double ppu = [self ppu];
    _dragged = YES;
    [[NSCursor closedHandCursor] set];
    if ([self globe]) return [self rotateBy:event.deltaX / ppu y:-event.deltaY / ppu];  // the surface moves with the pointer
    _cx -= event.deltaX / ppu;
    _cy += event.deltaY / ppu;
    [self viewChanged];
}

- (void)mouseUp:(NSEvent *)event {
    [[NSCursor arrowCursor] set];
    if (_dragged || event.clickCount > 1) return;
    ADIFMapHit h = [self hitAt:[self convertPoint:event.locationInWindow fromView:nil]];
    _selected = h;
    self.needsDisplay = YES;
    if (self.onSelect) self.onSelect(h);
}

- (void)scrollWheel:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (event.hasPreciseScrollingDeltas && !(event.modifierFlags & NSEventModifierFlagOption)) {  // a trackpad: pan
        double ppu = [self ppu];
        if ([self globe]) return [self rotateBy:event.scrollingDeltaX / ppu y:-event.scrollingDeltaY / ppu];
        _cx -= event.scrollingDeltaX / ppu;
        _cy += event.scrollingDeltaY / ppu;
        [self viewChanged];
        return;
    }
    double dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 20 : event.scrollingDeltaY;
    if (dy != 0) [self zoomBy:std::pow(1.2, dy) at:p];
}

- (void)magnifyWithEvent:(NSEvent *)event {
    [self zoomBy:1 + event.magnification at:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)keyDown:(NSEvent *)event {
    NSString *c = event.charactersIgnoringModifiers;
    unichar k = c.length ? [c characterAtIndex:0] : 0;
    double step = 60 / [self ppu];
    if ([self globe] && (k == NSLeftArrowFunctionKey || k == NSRightArrowFunctionKey || k == NSUpArrowFunctionKey || k == NSDownArrowFunctionKey)) {
        // Look west, east, north or south: the surface moves the other way.
        [self rotateBy:k == NSLeftArrowFunctionKey ? step : k == NSRightArrowFunctionKey ? -step : 0
                     y:k == NSDownArrowFunctionKey ? step : k == NSUpArrowFunctionKey ? -step : 0];
        return;
    }
    if (k == '+' || k == '=') [self zoomBy:1.5];
    else if (k == '-') [self zoomBy:1 / 1.5];
    else if (k == '0') [self showWorld];
    else if (k == NSLeftArrowFunctionKey) _cx -= step, [self viewChanged];
    else if (k == NSRightArrowFunctionKey) _cx += step, [self viewChanged];
    else if (k == NSUpArrowFunctionKey) _cy += step, [self viewChanged];
    else if (k == NSDownArrowFunctionKey) _cy -= step, [self viewChanged];
    else [super keyDown:event];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self clampCenter];
}

@end
