#import "Map.h"
#import "MapView.h"

#import "Country.h"
#import "IotaGroups.h"
#import "PotaParks.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "adif_detail.h"
#include "adif_geo.h"
#include "adif_palette.h"
#include "adif_projection.h"
#include "adif_spec.h"
#include "adif_world.h"

#include <algorithm>
#include <cmath>
#include <dlfcn.h>
#include <functional>
#include <fstream>
#include <sstream>
#include <map>
#include <set>
#include <tuple>

using namespace adifhost;

using namespace mapkit;


// The QSOs of what was clicked: a small table; double-click goes to the record.
@interface ADIFMapList : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, copy) void (^onActivate)(NSInteger row);
@property(nonatomic) std::vector<std::vector<std::string>> rows;
@end

@implementation ADIFMapList
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    return (NSInteger)_rows.size();
}
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSTextField *f = [t makeViewWithIdentifier:@"map.cell" owner:self];
    if (!f) {
        f = [NSTextField labelWithString:@""];
        f.identifier = @"map.cell";
        f.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        f.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    size_t c = (size_t)col.identifier.integerValue;
    f.stringValue = row >= 0 && (size_t)row < _rows.size() && c < _rows[(size_t)row].size() ? ADIFString(_rows[(size_t)row][c]) : @"";
    return f;
}
- (void)activated:(id)sender {
    NSTableView *t = sender;
    if (self.onActivate && t.clickedRow >= 0) self.onActivate(t.clickedRow);
}
@end

namespace worldmap {
namespace {

struct {
    NSPanel *window = nil;
    ADIFMapView *view = nil;
    ADIFMapList *list = nil;
    NSTableView *table = nil;
    NSButton *squares = nil, *grid = nil, *labels = nil, *entities = nil, *contacts = nil, *parks = nil, *mine = nil;
    NSButton *cqZones = nil, *ituZones = nil, *states = nil, *countries = nil;
    NSButton *cqLabels = nil, *ituLabels = nil, *stateLabels = nil, *countryLabels = nil;  // labels: the grid squares'
    NSButton *counties = nil, *countyLabels = nil, *cities = nil, *cityLabels = nil, *iota = nil, *iotaLabels = nil, *pota = nil, *potaLabels = nil;
    NSPopUpButton *programs = nil, *style = nil, *projection = nil, *colorBy = nil, *region = nil;
    NSPopUpButton *band = nil, *mode = nil, *dates = nil, *confirmed = nil;
    NSTextField *target = nil, *status = nil, *zoomLabel = nil;
    adif::MapData data;
    std::vector<ADIFMapEntity> dxcc;
    std::vector<size_t> listed;   // the table's rows: indexes into data.qsos
    std::string summary, chosen;  // what the status line says when nothing is under the pointer
    std::string home;             // the grid the globe, rings and paths start from
    intptr_t buffer = 0;
} mw;

// Saved choices, in ADIFLint.ini.
bool flag(const char *key, bool fallback) {
    std::string v = setting(key);
    return v.empty() ? fallback : v == "1";
}
int number(const char *key, int fallback, int max) {
    std::string v = setting(key);
    int n = v.empty() ? fallback : std::atoi(v.c_str());
    return std::clamp(n, 0, max);
}
void saveFlag(const char *key, bool on) { setSetting(key, on ? "1" : "0"); }

std::set<std::string> hiddenPrograms() {
    std::string v = setting("mapHiddenPrograms");
    if (v.empty() && setting("mapHiddenProgramsSet").empty()) return {"IOTA"};  // callbooks fill IOTA in for every island station
    std::set<std::string> out;
    for (size_t b = 0; b < v.size();) {
        size_t e = v.find(',', b);
        if (e == std::string::npos) e = v.size();
        if (e > b) out.insert(v.substr(b, e - b));
        b = e + 1;
    }
    return out;
}

void saveHidden(const std::set<std::string> &hidden) {
    std::string v;
    for (const std::string &p : hidden) v += (v.empty() ? "" : ",") + p;
    setSetting("mapHiddenPrograms", v);
    setSetting("mapHiddenProgramsSet", "1");
}

ADIFMapStyle savedStyle() {
    ADIFMapStyle s;
    static const double kSizes[] = {0.75, 1.0, 1.4, 1.9};
    s.colorBy = number("mapColorBy", 0, 4);
    s.palette = number("mapPalette", 0, 3);
    s.shape = number("mapMarkerShape", 0, 2);
    s.fill = number("mapSquareFill", 0, 2);
    s.marker = kSizes[number("mapMarkerSize", 1, 3)];
    s.contact = number("mapContactMarker", 0, 2);
    s.grid = flag("mapGrid", true);
    s.cqZones = flag("mapCqZones", false);
    s.ituZones = flag("mapItuZones", false);
    s.states = flag("mapUsStates", false);
    s.countries = flag("mapCountries", false);
    s.labels = flag("mapLabels", true);
    s.cqLabels = flag("mapCqLabels", true);
    s.ituLabels = flag("mapItuLabels", true);
    s.countryLabels = flag("mapCountryLabels", true);
    s.stateLabels = flag("mapStateLabels", true);
    s.counties = flag("mapCounties", false);
    s.countyLabels = flag("mapCountyLabels", true);
    s.cities = flag("mapCities", false);
    s.cityLabels = flag("mapCityLabels", true);
    s.iota = flag("mapIota", false);
    s.iotaLabels = flag("mapIotaLabels", true);
    s.pota = flag("mapPota", false);
    s.potaLabels = flag("mapPotaLabels", true);
    s.legend = flag("mapLegend", true);
    s.rings = flag("mapRings", false);
    s.paths = flag("mapPaths", false);
    s.lineStyle = number("mapLineStyle", 0, 2);
    s.lineWidth = number("mapLineWidth", 1, 2);
    s.arcs = flag("mapArcs", true);
    s.mine = flag("mapMine", true);
    return s;
}

void setStatus(const std::string &text) { mw.status.stringValue = ADIFString(text); }

std::string callsOf(const std::vector<size_t> &qsos) {
    std::vector<std::string> calls;
    for (size_t i : qsos)
        if (i < mw.data.qsos.size() && std::find(calls.begin(), calls.end(), mw.data.qsos[i].call) == calls.end()) calls.push_back(mw.data.qsos[i].call);
    std::string out;
    for (size_t k = 0; k < calls.size() && k < 5; ++k) out += (out.empty() ? "" : ", ") + calls[k];
    if (calls.size() > 5) out += ", +" + std::to_string(calls.size() - 5);
    return out;
}

std::string describe(const ADIFMapHit &h) {
    std::string where;
    if (!mw.home.empty() && !h.square.empty()) {
        std::string d = adif::gridDistanceText(mw.home, h.square);
        if (!d.empty()) where = " " + d + " from " + mw.home + ".";
    }
    switch (h.kind) {
        case ADIFMapHit::Square: {
            const adif::MapSquare &sq = mw.data.squares[h.index];
            return sq.grid + ": " + plural(sq.qsos, "QSO") + (sq.confirmed ? ", confirmed" : "") + " (" + callsOf(sq.qsoIndex) + ")." + where;
        }
        case ADIFMapHit::Dxcc: {
            const ADIFMapEntity &e = mw.dxcc[h.index];
            return e.name + " (DXCC " + std::to_string(e.dxcc) + "): " + plural(e.qsos.size(), "QSO") + (e.confirmed ? ", confirmed" : "") + " (" +
                   callsOf(e.qsos) + ")";
        }
        case ADIFMapHit::Park: {
            const adif::MapPark &p = mw.data.parks[h.index];
            size_t n = 0;
            for (const adif::MapPark &o : mw.data.parks) n += o.reference == p.reference && o.program == p.program;
            const adif::MapQso &q = mw.data.qsos[p.qso];
            return p.program + " " + p.reference + ": " + plural(n, "QSO") + ", in " + p.grid + " (" + q.call + " " + q.date + ")";
        }
        case ADIFMapHit::Contact: {
            const ADIFMapContact &c = mw.view.contacts[h.index];
            const adif::MapQso &q = mw.data.qsos[c.qsos[0]];
            char at[64];
            snprintf(at, sizeof at, "%.4f %c, %.4f %c", std::fabs(c.lat), c.lat < 0 ? 'S' : 'N', std::fabs(c.lon), c.lon < 0 ? 'W' : 'E');
            std::string from;
            double hlat, hlon;
            if (!mw.home.empty() && adif::gridToLatLon(mw.home, &hlat, &hlon)) {
                char d[96];
                snprintf(d, sizeof d, " %ld km at %.0f° from %s.", std::lround(adif::greatCircleKm(hlat, hlon, c.lat, c.lon)),
                         adif::initialBearing(hlat, hlon, c.lat, c.lon), mw.home.c_str());
                from = d;
            }
            return callsOf(c.qsos) + ": " + plural(c.qsos.size(), "QSO") + " at " + at + " (from " + q.locatedBy + ")." + from;
        }
        case ADIFMapHit::Pota: {
            if (h.index >= ADIFPotaParks().size()) break;
            const adif::PotaPark &p = ADIFPotaParks().parks()[h.index];
            ADIFParkWork w = [mw.view parkWork:p.ref];
            std::string what;
            if (!w.hunted.empty()) {
                bool confirmed = false;
                for (size_t qi : w.hunted) confirmed |= qi < mw.data.qsos.size() && mw.data.qsos[qi].confirmed;
                what = "hunted, " + plural(w.hunted.size(), "QSO") + (confirmed ? ", confirmed" : "") + " (" + callsOf(w.hunted) + ")";
            }
            if (!w.activated.empty()) what += (what.empty() ? "" : "; ") + std::string("activated by you, ") + plural(w.activated.size(), "QSO");
            if (what.empty()) what = "not worked";
            std::string from;
            double hlat, hlon;
            if (!mw.home.empty() && adif::gridToLatLon(mw.home, &hlat, &hlon)) {
                char d[96];
                snprintf(d, sizeof d, " %ld km at %.0f° from %s.", std::lround(adif::greatCircleKm(hlat, hlon, p.lat, p.lon)),
                         adif::initialBearing(hlat, hlon, p.lat, p.lon), mw.home.c_str());
                from = d;
            }
            return "POTA " + p.ref + " " + p.name + " (" + p.location + (p.active ? "" : ", inactive") + "): " + what + "." + from;
        }
        case ADIFMapHit::PotaCluster: {
            size_t n = [mw.view parkClusterCount:h.index];
            std::string count = std::to_string(n);
            for (int i = (int)count.size() - 3; i > 0; i -= 3) count.insert((size_t)i, ",");
            return count + (n == 1 ? " POTA park" : " POTA parks") + " not worked here; click to zoom in.";
        }
        case ADIFMapHit::Iota: {
            if (h.index >= ADIFIotaGroups().size()) break;
            const adif::IotaGroup &g = ADIFIotaGroups()[h.index];
            std::vector<size_t> qsos = [mw.view iotaQsos:g.ref];
            bool confirmed = false;
            for (size_t qi : qsos) confirmed |= qi < mw.data.qsos.size() && mw.data.qsos[qi].confirmed;
            return "IOTA " + g.ref + " " + g.name + ": " +
                   (qsos.empty() ? "not worked" : plural(qsos.size(), "QSO") + (confirmed ? ", confirmed" : "") + " (" + callsOf(qsos) + ")") + "." + where;
        }
        case ADIFMapHit::Empty: return h.square + ": no QSOs." + where;
        case ADIFMapHit::None: break;
    }
    return "";
}

void showList(const std::vector<size_t> &qsos) {
    mw.listed = qsos;
    std::vector<std::vector<std::string>> rows;
    for (size_t i : qsos) {
        if (i >= mw.data.qsos.size()) continue;
        const adif::MapQso &q = mw.data.qsos[i];
        rows.push_back({std::to_string(q.record), q.call, q.date, q.time, q.band, q.mode, q.grid, q.confirmed ? "yes" : ""});
    }
    mw.list.rows = rows;
    [mw.table reloadData];
}

void selected(const ADIFMapHit &h) {
    std::vector<size_t> qsos;
    if (h.kind == ADIFMapHit::Square) qsos = mw.data.squares[h.index].qsoIndex;
    else if (h.kind == ADIFMapHit::Dxcc) qsos = mw.dxcc[h.index].qsos;
    else if (h.kind == ADIFMapHit::Contact) qsos = mw.view.contacts[h.index].qsos;
    else if (h.kind == ADIFMapHit::Iota && h.index < ADIFIotaGroups().size()) qsos = [mw.view iotaQsos:ADIFIotaGroups()[h.index].ref];
    else if (h.kind == ADIFMapHit::Pota && h.index < ADIFPotaParks().size()) {
        ADIFParkWork w = [mw.view parkWork:ADIFPotaParks().parks()[h.index].ref];
        qsos = w.hunted;
        for (size_t qi : w.activated)
            if (std::find(qsos.begin(), qsos.end(), qi) == qsos.end()) qsos.push_back(qi);
    }
    else if (h.kind == ADIFMapHit::Park)
        for (const adif::MapPark &p : mw.data.parks)
            if (p.reference == mw.data.parks[h.index].reference && p.program == mw.data.parks[h.index].program) qsos.push_back(p.qso);
    showList(qsos);
    mw.chosen = h.kind == ADIFMapHit::None ? "" : describe(h) + (qsos.empty() ? "" : " Double-click a QSO to go to it in the log.");
    setStatus(mw.chosen.empty() ? mw.summary : mw.chosen);
}

void updateZoomLabel() {
    double z = mw.view.zoom;
    mw.zoomLabel.stringValue = z < 10 ? [NSString stringWithFormat:@"%.1f×", z] : [NSString stringWithFormat:@"%.0f×", z];
}

// The map's projection; the globe is centred on home, else on the log's squares.
void applyProjection() {
    double lat = 0, lon = 0;
    bool home = !mw.home.empty() && adif::gridToLatLon(mw.home, &lat, &lon);
    int p = number("mapProjection", 0, 3);
    static const adif::Projection kinds[] = {adif::Projection::Equirectangular, adif::Projection::Mercator, adif::Projection::EqualEarth,
                                             adif::Projection::Globe};
    double clat = lat, clon = lon;
    if (!home) {  // the middle of the squares worked (the mean of their directions from the Earth's centre)
        double x = 0, y = 0, z = 0;
        for (const adif::MapSquare &sq : mw.data.squares) {
            double a, o;
            if (!adif::gridToLatLon(sq.grid, &a, &o)) continue;
            a *= M_PI / 180, o *= M_PI / 180;
            x += std::cos(a) * std::cos(o), y += std::cos(a) * std::sin(o), z += std::sin(a);
        }
        if (std::hypot(x, y, z) > 1e-9) clat = std::atan2(z, std::hypot(x, y)) * 180 / M_PI, clon = std::atan2(y, x) * 180 / M_PI;
        else clat = 20, clon = 0;
    }
    adif::Projector pr(kinds[p], clat, clon);
    [mw.view setProjector:pr home:home ? ADIFString(mw.home) : @"" lat:lat lon:lon];
    [mw.projection itemAtIndex:3].title = home ? [NSString stringWithFormat:@"Globe from %@", ADIFString(mw.home)] : @"Globe";
    [mw.projection selectItemAtIndex:p];
}

void applyStyle() {
    mw.view.style = savedStyle();
    mw.view.hiddenPrograms = hiddenPrograms();
}

NSImage *swatch(NSColor *color, bool diamond) {
    return [NSImage imageWithSize:NSMakeSize(12, 12)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect r) {
                       NSBezierPath *p = [NSBezierPath bezierPath];
                       if (diamond) {
                           [p moveToPoint:NSMakePoint(6, 11)];
                           [p lineToPoint:NSMakePoint(1, 6)];
                           [p lineToPoint:NSMakePoint(6, 1)];
                           [p lineToPoint:NSMakePoint(11, 6)];
                           [p closePath];
                       } else {
                           p = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 1, 1)];
                       }
                       [color setFill];
                       [p fill];
                       return YES;
                   }];
}

NSMenuItem *menuItem(NSMenu *menu, NSString *title, bool on, void (^action)(void)) {
    NSMenuItem *i = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    i.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if (action) ADIFBlockMenuItem(i, action);
    else i.enabled = NO;
    return i;
}

void refresh();
void fillPrograms();
void fillStyle();

// The Other programs list: the common programs, then any other SIG in the log, each with its count.
void fillPrograms() {
    NSMenu *menu = mw.programs.menu;
    menu.autoenablesItems = NO;
    [menu removeAllItems];
    [menu addItemWithTitle:@"Other programs" action:nil keyEquivalent:@""];  // the pull-down's own title
    std::map<std::string, std::set<std::string>> refs;
    for (const adif::MapPark &p : mw.data.parks)
        if (!p.park()) refs[p.program].insert(p.reference);
    std::vector<std::pair<std::string, std::string>> list;  // key, label
    for (size_t i = 0; i < kProgramCount; ++i) list.emplace_back(kPrograms[i].key, kPrograms[i].label);
    for (const auto &kv : refs) {
        bool known = false;
        for (size_t i = 0; i < kProgramCount; ++i) known |= kv.first == kPrograms[i].key;
        if (!known) list.emplace_back(kv.first, kv.first);
    }
    std::set<std::string> hidden = hiddenPrograms();
    menuItem(menu, @"Show All", false, ^{
        saveHidden({});
        applyStyle();
        fillPrograms();
    });
    menuItem(menu, @"Hide All", false, ^{
        std::set<std::string> all;
        for (size_t i = 0; i < kProgramCount; ++i) all.insert(kPrograms[i].key);
        for (const adif::MapPark &p : mw.data.parks)
            if (!p.park()) all.insert(p.program);
        saveHidden(all);
        applyStyle();
        fillPrograms();
    });
    [menu addItem:[NSMenuItem separatorItem]];
    for (const auto &[key, label] : list) {
        size_t n = refs.count(key) ? refs[key].size() : 0;
        NSString *title = n ? [NSString stringWithFormat:@"%@: %zu", ADIFString(label), n]
                            : [NSString stringWithFormat:@"%@: none in this log", ADIFString(label)];
        std::string k = key;
        NSMenuItem *item = menuItem(menu, title, !hidden.count(key), ^{
            std::set<std::string> h = hiddenPrograms();
            if (!h.erase(k)) h.insert(k);
            saveHidden(h);
            applyStyle();
            fillPrograms();
        });
        item.image = swatch([mw.view programColor:key], true);
    }
}

// Options: palette, marker size and shape, contact markers, square fill, lines to contacts,
// legend, distance rings.
void fillStyle() {
    NSMenu *menu = mw.style.menu;
    menu.autoenablesItems = NO;
    [menu removeAllItems];
    [menu addItemWithTitle:@"Options" action:nil keyEquivalent:@""];
    ADIFMapStyle s = savedStyle();
    auto choose = [](const char *key, int value) {
        return ^{
            setSetting(key, std::to_string(value));
            applyStyle();
            fillStyle();
            fillPrograms();  // program swatches follow the palette
        };
    };
    auto toggle = [](const char *key, bool now) {
        return ^{
            saveFlag(key, !now);
            applyStyle();
            fillStyle();
        };
    };
    menuItem(menu, @"Colours", false, nil);
    NSArray *palettes = @[ @"Standard", @"Colour-blind safe", @"High contrast", @"Light (for printing)" ];
    for (NSInteger i = 0; i < 4; ++i) menuItem(menu, palettes[(NSUInteger)i], s.palette == i, choose("mapPalette", (int)i)).indentationLevel = 1;
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Marker size", false, nil);
    NSArray *sizes = @[ @"Small", @"Medium", @"Large", @"Extra large" ];
    int size = number("mapMarkerSize", 1, 3);
    for (NSInteger i = 0; i < 4; ++i) menuItem(menu, sizes[(NSUInteger)i], size == i, choose("mapMarkerSize", (int)i)).indentationLevel = 1;
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Markers", false, nil);
    NSArray *shapes = @[ @"By layer: dots, triangles, diamonds", @"All circles", @"All squares" ];
    for (NSInteger i = 0; i < 3; ++i) menuItem(menu, shapes[(NSUInteger)i], s.shape == i, choose("mapMarkerShape", (int)i)).indentationLevel = 1;
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Contacts", false, nil);
    NSArray *contactShapes = @[ @"Pins", @"Dots", @"Crosshairs" ];
    for (NSInteger i = 0; i < 3; ++i)
        menuItem(menu, contactShapes[(NSUInteger)i], s.contact == i, choose("mapContactMarker", (int)i)).indentationLevel = 1;
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Worked squares", false, nil);
    NSArray *fills = @[ @"Solid", @"See-through", @"Outline" ];
    for (NSInteger i = 0; i < 3; ++i) menuItem(menu, fills[(NSUInteger)i], s.fill == i, choose("mapSquareFill", (int)i)).indentationLevel = 1;
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Lines to contacts", s.paths, toggle("mapPaths", s.paths)).toolTip =
        @"Great-circle lines from your station (each QSO's MY_GRIDSQUARE, else home) to each contact (its LAT and LON, else its grid, else "
        @"its DXCC entity), coloured as the map colours";
    NSArray *lineStyles = @[ @"Solid line", @"Dashed line", @"Dotted line" ];
    for (NSInteger i = 0; i < 3; ++i) {
        NSMenuItem *item = menuItem(menu, lineStyles[(NSUInteger)i], s.lineStyle == i, choose("mapLineStyle", (int)i));
        item.indentationLevel = 1;
        item.enabled = s.paths;
    }
    {
        NSMenuItem *item = menuItem(menu, @"Arch over the globe", s.arcs, toggle("mapArcs", s.arcs));
        item.indentationLevel = 1;
        item.enabled = s.paths;
        item.toolTip = @"On the globe, draw each line as an arch rising over it (for looks: the true path, and the beam heading, is the "
                       @"straight line you get with this off)";
    }
    NSArray *lineWidths = @[ @"Thin line", @"Medium line", @"Thick line" ];
    for (NSInteger i = 0; i < 3; ++i) {
        NSMenuItem *item = menuItem(menu, lineWidths[(NSUInteger)i], s.lineWidth == i, choose("mapLineWidth", (int)i));
        item.indentationLevel = 1;
        item.enabled = s.paths;
    }
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Legend", s.legend, toggle("mapLegend", s.legend));
    menuItem(menu, @"Distance rings from my grid", s.rings, toggle("mapRings", s.rings)).enabled = !mw.home.empty();
}

// Home: Settings → Your Station's grid, else the log's most used MY_GRIDSQUARE.
std::string homeGrid() {
    std::string g = setting("stationGrid");
    double lat, lon;
    if (!g.empty() && adif::gridToLatLon(g, &lat, &lon)) return g;
    std::map<std::string, size_t> n;
    for (const adif::MapQso &q : mw.data.qsos)
        if (q.myGrid.size() >= 4 && !adif::isPlaceholderGrid(q.myGrid)) ++n[q.myGrid];
    size_t most = 0;
    for (const auto &kv : n)
        if (kv.second > most) most = kv.second, g = kv.first;
    return most ? g : "";
}

void refresh() {
    if (!mw.window) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        mw.buffer = buffer();
        mw.target.stringValue = [@"Log: " stringByAppendingString:ADIFString(documentName())];
        // The bands, modes and years in the log, for the filters.
        std::set<std::string> bands, modes, years;
        std::map<std::string, size_t> qsosPerBand;
        for (const adif::Record &rec : adif::records(text, r.model)) {
            if (std::string b = adif::effectiveBand(rec); !b.empty()) bands.insert(b), ++qsosPerBand[b];
            if (std::string m = rec.get("MODE"); !m.empty()) modes.insert(m);
            if (std::string d = rec.get("QSO_DATE"); d.size() == 8) years.insert(d.substr(0, 4));
        }
        auto fill = [](NSPopUpButton *p, NSArray<NSString *> *first, const std::vector<std::string> &items) {
            NSString *keep = p.indexOfSelectedItem > 0 ? p.titleOfSelectedItem : nil;
            [p removeAllItems];
            [p addItemsWithTitles:first];
            for (const std::string &i : items) [p addItemWithTitle:ADIFString(i)];
            if (keep && [p itemWithTitle:keep]) [p selectItemWithTitle:keep];
        };
        fill(mw.band, @[ @"All bands" ], std::vector<std::string>(bands.begin(), bands.end()));
        fill(mw.mode, @[ @"All modes" ], std::vector<std::string>(modes.begin(), modes.end()));
        fill(mw.dates, @[ @"All dates", @"Last 30 days", @"Last 12 months", @"This year" ], std::vector<std::string>(years.rbegin(), years.rend()));
        adif::MapFilter f;
        f.band = mw.band.indexOfSelectedItem > 0 ? ADIFStd(mw.band.titleOfSelectedItem) : "";
        f.mode = mw.mode.indexOfSelectedItem > 0 ? ADIFStd(mw.mode.titleOfSelectedItem) : "";
        f.confirmed = (int)std::clamp<NSInteger>(mw.confirmed.indexOfSelectedItem, 0, 2);
        std::string today = utcNow("%Y%m%d");
        auto daysAgo = [](int days) {
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"yyyyMMdd";
            df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            return ADIFStd([df stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0 * days]]);
        };
        switch (mw.dates.indexOfSelectedItem) {
            case 1: f.from = daysAgo(30); break;
            case 2: f.from = daysAgo(365); break;
            case 3: f.from = today.substr(0, 4) + "0101"; break;
            default:
                if (mw.dates.indexOfSelectedItem > 3) {
                    std::string y = ADIFStd(mw.dates.titleOfSelectedItem);
                    f.from = y + "0101", f.to = y + "1231";
                }
                break;
        }
        mw.data = adif::mapData(text, r.model, f);
        // DXCC from the calls, by country data.
        std::map<int, ADIFMapEntity> byDxcc;
        const adif::CountryTable &countries = ADIFCountries();
        for (size_t i = 0; i < mw.data.qsos.size(); ++i) {
            adif::CountryInfo info;
            if (countries.empty() || !countries.lookup(mw.data.qsos[i].call, &info) || !info.dxcc) continue;
            ADIFMapEntity &e = byDxcc[info.dxcc];
            e.dxcc = info.dxcc, e.lat = info.lat, e.lon = info.lon, e.name = info.name;
            e.qsos.push_back(i);
            e.confirmed |= mw.data.qsos[i].confirmed;
        }
        // Each entity's land, worked out once from the country file's names and places.
        static std::map<int, std::vector<adif::RingRef>> land;
        static size_t landFor = 0;
        if (landFor != countries.entities()) {
            std::vector<adif::EntityPlace> places;
            for (const adif::CountryInfo &c : countries.all()) places.push_back({c.dxcc, c.lat, c.lon, c.name});
            land = adif::dxccRings(places);
            landFor = countries.entities();
        }
        for (auto &kv : byDxcc)
            if (auto it = land.find(kv.first); it != land.end()) kv.second.land = it->second;
        mw.dxcc.clear();
        size_t confirmedDxcc = 0, confirmedSquares = 0;
        for (auto &kv : byDxcc) {
            confirmedDxcc += kv.second.confirmed;
            mw.dxcc.push_back(kv.second);
        }
        for (const adif::MapSquare &sq : mw.data.squares) confirmedSquares += sq.confirmed;
        mw.view.showSquares = mw.squares.state == NSControlStateValueOn;
        mw.view.showEntities = mw.entities.state == NSControlStateValueOn;
        mw.view.showParks = mw.parks.state == NSControlStateValueOn;
        mw.view.showContacts = mw.contacts.state == NSControlStateValueOn;
        mw.view.qsosPerBand = qsosPerBand;
        mw.home = homeGrid();
        applyStyle();
        applyProjection();
        [mw.view setData:mw.data entities:mw.dxcc];
        fillPrograms();
        fillStyle();
        showList({});
        size_t located = 0;
        for (const adif::MapQso &q : mw.data.qsos) located += q.located;
        std::set<std::string> parkRefs, otherRefs;
        for (const adif::MapPark &p : mw.data.parks) (p.park() ? parkRefs : otherRefs).insert(p.program + " " + p.reference);
        mw.summary = plural(mw.data.squares.size(), "grid square") + " (" + std::to_string(confirmedSquares) + " confirmed), " +
                     std::to_string(mw.dxcc.size()) + " DXCC (" + std::to_string(confirmedDxcc) + " confirmed), " +
                     plural(parkRefs.size(), "park") + " (POTA, WWFF) where the QSO has a grid, " + plural(otherRefs.size(), "other reference") +
                     " (IOTA, SOTA, GMA... under Other programs)" + (mw.home.empty() ? "" : "; home " + mw.home) + ". " +
                     (mw.data.withoutGrid ? plural(mw.data.withoutGrid, "QSO") + " without GRIDSQUARE " + (mw.data.withoutGrid == 1 ? "isn't" : "aren't") +
                                                " on the squares. "
                                          : "") +
                     plural(located, "QSO") + " with an exact place (Contacts" +
                     (mw.data.unusedLatLon ? "; " + std::to_string(mw.data.unusedLatLon) + " LAT/LON not used: a placeholder, or far from the QSO's grid" : "") +
                     "). "
                     "The legend shows the colours. Scroll or pinch to zoom, drag to move (on the globe, to turn it), "
                     "click a square, dot, pin or park for its QSOs.";
        mw.chosen.clear();
        setStatus(mw.summary);
    } catch (...) {
    }
}

void goToQso(NSInteger row) {
    if (row < 0 || (size_t)row >= mw.listed.size()) return;
    const adif::MapQso &q = mw.data.qsos[mw.listed[(size_t)row]];
    if (buffer() != mw.buffer) {
        setStatus("Switch back to the map's log to go to the record.");
        return;
    }
    NppHandle h = scintilla();
    const adif::LintResult &r = lint(h);
    if (q.group >= 0 && (size_t)q.group < r.model.groups.size()) goTo(h, adif::groupStart(r.model, r.model.groups[(size_t)q.group]), true);
}

void exportPng() {
    std::string base = documentName();
    if (size_t dot = base.rfind('.'); dot != std::string::npos) base.resize(dot);
    std::string path;
    if (const char *dir = getenv("ADIFLINT_TEST_SAVE_DIR")) {
        path = std::string(dir) + "/" + base + " map.png";
    } else {
        NSSavePanel *p = [NSSavePanel savePanel];
        p.nameFieldStringValue = ADIFString(base + " map.png");
        if (UTType *t = [UTType typeWithFilenameExtension:@"png"]) p.allowedContentTypes = @[ t ];
        if ([p runModal] != NSModalResponseOK || !p.URL) return;
        path = ADIFStd(p.URL.path);
    }
    // What the map shows now, legend included, at twice the screen's size.
    NSRect r = mw.view.bounds;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                    pixelsWide:(NSInteger)(r.size.width * 2)
                                                                    pixelsHigh:(NSInteger)(r.size.height * 2)
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    rep.size = r.size;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [mw.view drawRect:r];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:ADIFString(path) atomically:YES]) {
        setStatus("Could not save the map.");
        return;
    }
    setStatus("Saved " + ADIFStd(ADIFString(path).lastPathComponent) + ". " + mw.summary);
}

// Apple's unified map URL for a place card (developer.apple.com/documentation/mapkit/
// unified-map-urls, read 2026-10-13): the Maps app opens there. Under the tests, the URL is
// written to a file instead.
void openInAppleMaps() {
    double lat = 0, lon = 0;
    std::string name;
    [mw.view selectedPlace:&lat lon:&lon name:&name];
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://maps.apple.com/place"];
    NSMutableArray *query = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"coordinate"
                                                                                       value:[NSString stringWithFormat:@"%.5f,%.5f", lat, lon]]];
    if (!name.empty()) [query addObject:[NSURLQueryItem queryItemWithName:@"name" value:ADIFString(name)]];
    url.queryItems = query;
    if (const char *dir = getenv("ADIFLINT_TEST_SAVE_DIR")) {
        [url.URL.absoluteString writeToFile:[@(dir) stringByAppendingPathComponent:@"apple-maps-url.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    if (url.URL) [[NSWorkspace sharedWorkspace] openURL:url.URL];
}

NSButton *smallButton(NSString *title, NSString *tip, void (^action)(void)) {
    NSButton *b = [NSButton buttonWithTitle:title target:nil action:nil];
    b.toolTip = tip;
    ADIFOnAction(b, action);
    return b;
}

NSPopUpButton *pullDown(NSString *title, NSString *tip) {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [p addItemWithTitle:title];
    p.toolTip = tip;
    return p;
}

}  // namespace

void cmdMap() {
    if (!mw.window) {
        mw.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 820)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                         NSWindowStyleMaskUtilityWindow
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
        mw.window.title = @"Map";
        mw.window.releasedWhenClosed = NO;
        mw.window.hidesOnDeactivate = NO;
        mw.window.contentMinSize = NSMakeSize(920, 620);
        NSView *root = mw.window.contentView;
        mw.target = ADIFLabel(@"");
        // Row 1: what to show.
        mw.squares = ADIFCheckbox(@"Worked squares", flag("mapSquares", true));
        mw.grid = ADIFCheckbox(@"Grid squares", flag("mapGrid", true));
        mw.grid.toolTip = @"The Maidenhead grid: its fields (20 x 10 degrees), and its squares (2 x 1) when zoomed in";
        // The Labels row: each overlay's names or numbers, under its box in the Overlays row.
        mw.labels = ADIFCheckbox(@"Grid squares", flag("mapLabels", true));
        mw.labels.toolTip = @"Field names (FN, EM...), and square names (FN31) when zoomed in";
        mw.cqLabels = ADIFCheckbox(@"CQ zones", flag("mapCqLabels", true));
        mw.cqLabels.toolTip = @"The CQ zones' numbers";
        mw.ituLabels = ADIFCheckbox(@"ITU zones", flag("mapItuLabels", true));
        mw.ituLabels.toolTip = @"The ITU zones' numbers";
        mw.countryLabels = ADIFCheckbox(@"Countries", flag("mapCountryLabels", true));
        mw.countryLabels.toolTip = @"Each country's name, where it fits inside the country on screen";
        mw.stateLabels = ADIFCheckbox(@"US states", flag("mapStateLabels", true));
        mw.stateLabels.toolTip = @"Each state's postal code, where it fits";
        mw.counties = ADIFCheckbox(@"US counties", flag("mapCounties", false));
        mw.counties.toolTip = @"County lines (Natural Earth, public domain), from 2.5x zoom";
        mw.countyLabels = ADIFCheckbox(@"US counties", flag("mapCountyLabels", true));
        mw.countyLabels.toolTip = @"Each county's name, where it fits";
        mw.cities = ADIFCheckbox(@"Cities", flag("mapCities", false));
        mw.cities.toolTip = @"7,300 cities and towns (Natural Earth, public domain), more as you zoom in";
        mw.cityLabels = ADIFCheckbox(@"Cities", flag("mapCityLabels", true));
        mw.cityLabels.toolTip = @"City names, where they don't run into each other";
        mw.pota = ADIFCheckbox(@"POTA", flag("mapPota", false));
        mw.pota.toolTip = @"POTA parks: a pin at each park you hunted or activated, at the park itself, and a ring at each park you haven't "
                          @"worked (a count where there are many: click it to zoom in). POTA's park list is downloaded in Settings (POTA Parks)";
        mw.potaLabels = ADIFCheckbox(@"POTA", flag("mapPotaLabels", true));
        mw.potaLabels.toolTip = @"Each park's reference (US-1234): the parks you worked always, the others once zoomed in to a few hundred, "
                                @"and names once zoomed in to fewer";
        mw.potaLabels.identifier = @"map.labels.pota";
        mw.iota = ADIFCheckbox(@"IOTA", flag("mapIota", false));
        mw.iota.toolTip = @"IOTA's island groups, the ones in your log filled in. The group list is downloaded in Settings (IOTA Groups)";
        mw.iotaLabels = ADIFCheckbox(@"IOTA", flag("mapIotaLabels", true));
        mw.iotaLabels.toolTip = @"Each group's reference (EU-005), and its name where there is room";
        mw.countyLabels.identifier = @"map.labels.counties", mw.cityLabels.identifier = @"map.labels.cities", mw.iotaLabels.identifier = @"map.labels.iota";
        mw.labels.identifier = @"map.labels.grid", mw.cqLabels.identifier = @"map.labels.cq", mw.ituLabels.identifier = @"map.labels.itu";
        mw.countryLabels.identifier = @"map.labels.countries", mw.stateLabels.identifier = @"map.labels.states";
        mw.cqZones = ADIFCheckbox(@"CQ zones", flag("mapCqZones", false));
        mw.ituZones = ADIFCheckbox(@"ITU zones", flag("mapItuZones", false));
        mw.states = ADIFCheckbox(@"US states", flag("mapUsStates", false));
        mw.states.toolTip = @"State lines (Natural Earth, public domain)";
        mw.countries = ADIFCheckbox(@"Countries", flag("mapCountries", false));
        mw.countries.toolTip = @"Every country outlined, coasts and borders (Natural Earth, public domain)";
        mw.cqZones.toolTip = @"CQ zones 1-40 (HB9HIL's hamradio-zones-geojson, MIT); approximate";
        mw.ituZones.toolTip = @"ITU zones 1-90 (HB9HIL's hamradio-zones-geojson, MIT); approximate";
        mw.entities = ADIFCheckbox(@"DXCC", flag("mapDxcc", true));
        mw.entities.toolTip = @"Each DXCC entity worked, its own land shaded (Alaska apart from the United States, Sardinia from Italy, "
                              @"Scotland from England); a dot for one too small to shade";
        mw.contacts = ADIFCheckbox(@"Contacts", flag("mapContacts", false));
        mw.contacts.toolTip = @"A marker at each contact's own place: its LAT and LON, else a GRIDSQUARE of 6 or 8 characters (a 4-character "
                              @"square is 100 km or more across: Worked squares shows those). Style chooses pins, dots or crosshairs";
        mw.parks = ADIFCheckbox(@"Parks", flag("mapParks", true));
        mw.parks.toolTip = @"POTA and WWFF parks you hunted, where the QSO has a grid";
        mw.programs = pullDown(@"Other programs", @"Other programs' references, a colour each: SOTA summits, IOTA islands, GMA, bunkers, "
                                                  @"castles... (IOTA starts hidden: callbooks fill it in for every island station)");
        mw.mine = ADIFCheckbox(@"My station", flag("mapMine", true));
        mw.mine.toolTip = @"A star at each MY_GRIDSQUARE in the log";
        // Row 2: which QSOs, and how to colour them.
        mw.band = ADIFPopup(@[ @"All bands" ]);
        mw.mode = ADIFPopup(@[ @"All modes" ]);
        mw.dates = ADIFPopup(@[ @"All dates", @"Last 30 days", @"Last 12 months", @"This year" ]);
        mw.confirmed = ADIFPopup(@[ @"All QSOs", @"Confirmed", @"Not confirmed" ]);
        mw.colorBy = ADIFPopup(@[ @"Colour by confirmation", @"Colour by band", @"Colour by mode", @"Colour by QSO count",
                                  @"Colour by year first worked" ]);
        [mw.colorBy selectItemAtIndex:number("mapColorBy", 0, 4)];
        // Row 3: zoom, projection, style.
        mw.projection = ADIFPopup(@[ @"Equirectangular", @"Mercator", @"Equal Earth", @"Globe" ]);
        mw.projection.autoenablesItems = NO;
        mw.projection.toolTip = @"Equirectangular: the grid as rectangles. Mercator: familiar shapes. Equal Earth: true sizes. Globe: the Earth "
                                @"as seen from space, centred on your grid; drag (or the arrow keys) to turn it any way, zoom in for detail, "
                                @"World to come home. Bearings from the centre are true (beam headings)";
        mw.style = pullDown(@"Options", @"Colours, marker size and shape, contact markers, how worked squares are filled, lines to contacts "
                                        @"and their style, the legend, distance rings");
        mw.region = pullDown(@"Region", @"Zoom to a continent (on the globe, turn to face it)");
        {
            // Continents as ADIF's CONT names them, each a box of longitude and latitude to show.
            struct Box {
                NSString *name;
                double w, s, e, n;
            };
            static const Box kRegions[] = {{@"Africa", -20, -36, 53, 38},           {@"Antarctica", -180, -90, 180, -60},
                                           {@"Asia", 25, -11, 180, 78},             {@"Europe", -25, 34, 45, 72},
                                           {@"North America", -170, 5, -50, 75},    {@"Oceania", 110, -48, 180, 0},
                                           {@"South America", -82, -56, -34, 13}};
            for (const Box &b : kRegions) {
                NSMenuItem *item = [mw.region.menu addItemWithTitle:b.name action:nil keyEquivalent:@""];
                Box box = b;
                ADIFBlockMenuItem(item, ^{ [mw.view showWest:box.w south:box.s east:box.e north:box.n]; });
            }
        }
        for (NSControl *c in @[ mw.squares, mw.entities, mw.contacts, mw.parks, mw.band, mw.mode, mw.dates, mw.confirmed ]) ADIFOnAction(c, ^{
            saveFlag("mapSquares", mw.squares.state == NSControlStateValueOn);
            saveFlag("mapDxcc", mw.entities.state == NSControlStateValueOn);
            saveFlag("mapContacts", mw.contacts.state == NSControlStateValueOn);
            saveFlag("mapParks", mw.parks.state == NSControlStateValueOn);
            refresh();
        });
        // A Labels box works while its overlay is shown.
        void (^labelsFollow)(void) = ^{
            mw.labels.enabled = mw.grid.state == NSControlStateValueOn;
            mw.cqLabels.enabled = mw.cqZones.state == NSControlStateValueOn;
            mw.ituLabels.enabled = mw.ituZones.state == NSControlStateValueOn;
            mw.countryLabels.enabled = mw.countries.state == NSControlStateValueOn;
            mw.stateLabels.enabled = mw.states.state == NSControlStateValueOn;
            mw.countyLabels.enabled = mw.counties.state == NSControlStateValueOn;
            mw.cityLabels.enabled = mw.cities.state == NSControlStateValueOn;
            mw.iotaLabels.enabled = mw.iota.state == NSControlStateValueOn;
            mw.potaLabels.enabled = mw.pota.state == NSControlStateValueOn;
        };
        labelsFollow();
        for (NSButton *b in @[ mw.grid, mw.labels, mw.mine, mw.cqZones, mw.ituZones, mw.states, mw.countries, mw.cqLabels, mw.ituLabels,
                               mw.countryLabels, mw.stateLabels, mw.counties, mw.countyLabels, mw.cities, mw.cityLabels, mw.pota, mw.potaLabels, mw.iota, mw.iotaLabels ])
            ADIFOnAction(b, ^{
            saveFlag("mapGrid", mw.grid.state == NSControlStateValueOn);
            saveFlag("mapLabels", mw.labels.state == NSControlStateValueOn);
            saveFlag("mapCqLabels", mw.cqLabels.state == NSControlStateValueOn);
            saveFlag("mapItuLabels", mw.ituLabels.state == NSControlStateValueOn);
            saveFlag("mapCountryLabels", mw.countryLabels.state == NSControlStateValueOn);
            saveFlag("mapStateLabels", mw.stateLabels.state == NSControlStateValueOn);
            saveFlag("mapCounties", mw.counties.state == NSControlStateValueOn);
            saveFlag("mapCountyLabels", mw.countyLabels.state == NSControlStateValueOn);
            saveFlag("mapCities", mw.cities.state == NSControlStateValueOn);
            saveFlag("mapCityLabels", mw.cityLabels.state == NSControlStateValueOn);
            saveFlag("mapPota", mw.pota.state == NSControlStateValueOn);
            saveFlag("mapPotaLabels", mw.potaLabels.state == NSControlStateValueOn);
            saveFlag("mapIota", mw.iota.state == NSControlStateValueOn);
            saveFlag("mapIotaLabels", mw.iotaLabels.state == NSControlStateValueOn);
            labelsFollow();
            saveFlag("mapCqZones", mw.cqZones.state == NSControlStateValueOn);
            saveFlag("mapItuZones", mw.ituZones.state == NSControlStateValueOn);
            saveFlag("mapUsStates", mw.states.state == NSControlStateValueOn);
            saveFlag("mapCountries", mw.countries.state == NSControlStateValueOn);
            saveFlag("mapMine", mw.mine.state == NSControlStateValueOn);
            applyStyle();
            fillStyle();
            if (b == mw.iota && mw.iota.state == NSControlStateValueOn && ADIFIotaGroups().empty())
                setStatus("IOTA: download IOTA's group list first, in Settings (IOTA Groups).");
            if (b == mw.pota && mw.pota.state == NSControlStateValueOn && !ADIFPotaParks().size())
                setStatus("POTA: download POTA's park list first, in Settings (POTA Parks). Until then, Parks shows the parks you "
                          "hunted at the QSO's grid.");
        });
        ADIFOnAction(mw.colorBy, ^{
            setSetting("mapColorBy", std::to_string(mw.colorBy.indexOfSelectedItem));
            applyStyle();
        });
        ADIFOnAction(mw.projection, ^{
            setSetting("mapProjection", std::to_string(mw.projection.indexOfSelectedItem));
            applyProjection();
        });
        mw.zoomLabel = ADIFLabel(@"1.0×");
        [mw.zoomLabel.widthAnchor constraintEqualToConstant:40].active = YES;
        NSButton *out = smallButton(@"−", @"Zoom out (−)", ^{ [mw.view zoomBy:1 / 1.5]; });
        NSButton *in = smallButton(@"+", @"Zoom in (+, or double-click the map)", ^{ [mw.view zoomBy:1.5]; });
        NSButton *fit = smallButton(@"Fit Log", @"Zoom to the log's QSOs", ^{ [mw.view fitLog]; });
        NSButton *world = smallButton(@"World", @"The whole world (0)", ^{ [mw.view showWorld]; });
        NSButton *save = smallButton(@"Export PNG...", @"Save the map as it is shown now, with its legend", ^{ exportPng(); });
        NSButton *apple = smallButton(@"Apple Maps", @"Open what you clicked (a contact, square, park or entity), or the middle of the map, in Apple's Maps "
                                                      @"app: streets and satellite. Maps goes online; ADIF Lint sends nothing.",
                                      ^{ openInAppleMaps(); });
        NSStackView *row = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Show:"), mw.squares, mw.entities, mw.contacts, mw.parks, mw.programs, mw.mine ]];
        row.spacing = 10;
        NSStackView *row2 = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Only:"), mw.band, mw.mode, mw.dates, mw.confirmed, mw.colorBy ]];
        row2.spacing = 8;
        [row2 setCustomSpacing:24 afterView:mw.confirmed];
        // Overlays, and under each one the box for its labels.
        NSGridView *overlays = [NSGridView gridViewWithViews:@[
            @[ ADIFLabel(@"Overlays:"), mw.grid, mw.cqZones, mw.ituZones, mw.countries, mw.states, mw.counties, mw.cities, mw.pota, mw.iota ],
            @[ ADIFLabel(@"Labels:"), mw.labels, mw.cqLabels, mw.ituLabels, mw.countryLabels, mw.stateLabels, mw.countyLabels, mw.cityLabels, mw.potaLabels, mw.iotaLabels ]
        ]];
        overlays.rowSpacing = 6;
        overlays.columnSpacing = 10;
        overlays.rowAlignment = NSGridRowAlignmentFirstBaseline;
        NSStackView *row3 =
            [NSStackView stackViewWithViews:@[ ADIFLabel(@"Zoom:"), out, mw.zoomLabel, in, fit, world, mw.region, mw.projection, mw.style, save, apple ]];
        row3.spacing = 8;
        [row3 setCustomSpacing:24 afterView:world];
        mw.view = [[ADIFMapView alloc] initWithFrame:NSZeroRect];
        mw.view.onHover = ^(const ADIFMapHit &h) {
            std::string d = describe(h);
            setStatus(!d.empty() ? d : !mw.chosen.empty() ? mw.chosen : mw.summary);
        };
        mw.view.onSelect = ^(const ADIFMapHit &h) { selected(h); };
        mw.view.onViewChanged = ^{ updateZoomLabel(); };
        mw.list = [[ADIFMapList alloc] init];
        mw.list.onActivate = ^(NSInteger rowIndex) { goToQso(rowIndex); };
        mw.table = [[NSTableView alloc] initWithFrame:NSZeroRect];
        const char *titles[] = {"Record", "Call", "Date", "UTC", "Band", "Mode", "Grid", "Confirmed"};
        const CGFloat widths[] = {60, 100, 90, 60, 60, 70, 80, 80};
        for (size_t i = 0; i < 8; ++i) {
            NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%zu", i]];
            c.title = @(titles[i]);
            c.width = widths[i];
            [mw.table addTableColumn:c];
        }
        mw.table.dataSource = mw.list;
        mw.table.delegate = mw.list;
        mw.table.target = mw.list;
        mw.table.doubleAction = @selector(activated:);
        mw.table.usesAlternatingRowBackgroundColors = YES;
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        scroll.documentView = mw.table;
        scroll.hasVerticalScroller = YES;
        scroll.borderType = NSBezelBorder;
        mw.status = [NSTextField wrappingLabelWithString:@""];
        mw.status.maximumNumberOfLines = 3;
        mw.status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        for (NSView *v in @[ mw.target, row, overlays, row2, row3, mw.view, scroll, mw.status ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [root addSubview:v];
        }
        CGFloat m = 14;
        [NSLayoutConstraint activateConstraints:@[
            [mw.target.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
            [mw.target.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [row.topAnchor constraintEqualToAnchor:mw.target.bottomAnchor constant:8],
            [row.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [row.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [overlays.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:6],
            [overlays.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [overlays.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [row2.topAnchor constraintEqualToAnchor:overlays.bottomAnchor constant:6],
            [row2.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [row2.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [row3.topAnchor constraintEqualToAnchor:row2.bottomAnchor constant:6],
            [row3.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [row3.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [mw.view.topAnchor constraintEqualToAnchor:row3.bottomAnchor constant:8],
            [mw.view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [mw.view.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [scroll.topAnchor constraintEqualToAnchor:mw.view.bottomAnchor constant:8],
            [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [scroll.heightAnchor constraintEqualToConstant:120],
            [mw.status.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:8],
            [mw.status.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [mw.status.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [mw.status.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-m],
            [mw.status.heightAnchor constraintGreaterThanOrEqualToConstant:30],
        ]];
        [mw.window center];
    }
    refresh();
    [mw.window makeKeyAndOrderFront:nil];
    [mw.window makeFirstResponder:mw.view];
}

void iotaGroupsChanged() {
    if (mw.view) mw.view.needsDisplay = YES;
}

void parkListChanged() {
    if (mw.view) mw.view.needsDisplay = YES;
}

void documentChanged() {
    if (mw.window && mw.window.visible) refresh();
}

}  // namespace worldmap

