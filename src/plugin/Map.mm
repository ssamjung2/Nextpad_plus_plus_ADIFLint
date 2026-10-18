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
#include "adif_worked.h"
#include "adif_regions.h"
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

// Completions for a token field: the candidates that start with what was typed, then those that
// contain it.
@interface ADIFTokenCompleter : NSObject <NSTokenFieldDelegate>
@property(nonatomic, copy) NSArray<NSString *> *candidates;
@end

@implementation ADIFTokenCompleter
- (NSArray *)tokenField:(NSTokenField *)tokenField
    completionsForSubstring:(NSString *)substring
               indexOfToken:(NSInteger)tokenIndex
        indexOfSelectedItem:(NSInteger *)selectedIndex {
    NSMutableArray *starts = [NSMutableArray array], *contains = [NSMutableArray array];
    for (NSString *c in _candidates) {
        NSRange r = [c rangeOfString:substring options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
        if (r.location == 0) [starts addObject:c];
        else if (r.location != NSNotFound) [contains addObject:c];
        if (starts.count >= 40) break;
    }
    [starts addObjectsFromArray:[contains subarrayWithRange:NSMakeRange(0, std::min<NSUInteger>(contains.count, 40 - std::min<NSUInteger>(40, starts.count)))]];
    if (selectedIndex) *selectedIndex = starts.count ? 0 : -1;
    return starts;
}
@end

namespace worldmap {
namespace {

struct {
    NSPanel *window = nil;
    ADIFMapView *view = nil;
    ADIFMapList *list = nil;
    NSTableView *table = nil;
    NSButton *show[kLayerCount] = {}, *overlay[kLayerCount] = {}, *labels[kLayerCount] = {};  // the layers' boxes (no Show for cities)
    NSButton *contacts = nil, *lines = nil, *mine = nil;
    NSPopUpButton *programs = nil, *projection = nil, *colorBy = nil, *region = nil;
    NSPanel *styleWindow = nil;  // Style Options
    NSTimer *sunTimer = nil;     // day and night, while it shows now
    NSPopUpButton *band = nil, *mode = nil, *dates = nil, *confirmed = nil;
    NSTextField *target = nil, *status = nil, *zoomLabel = nil;
    // More Filters: places.
    NSButton *moreFilters = nil, *clearFilters = nil;
    NSPopover *filterPopover = nil;
    NSButton *continent[7] = {}, *parksToo = nil;
    NSTokenField *dxccTokens = nil, *stateTokens = nil, *countyTokens = nil, *potaTokens = nil;
    NSTextField *cqField = nil, *ituField = nil;
    NSPopUpButton *regions = nil;
    NSMutableArray *completers = nil;
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

// The layers' boxes: each layer's identifier, column title, settings keys and defaults. The keys
// are the ones the earlier Show, Overlays and Labels rows saved, so choices carry over.
struct LayerUi {
    MapLayerId id;
    NSString *ident, *title;
    const char *showKey, *overlayKey, *labelsKey;
    bool showOn, overlayOn;
    NSString *showTip, *overlayTip, *labelsTip;
};
const LayerUi kLayerUi[] = {
    {kLayerSquares, @"grid", @"Grid squares", "mapSquares", "mapGrid", "mapLabels", true, true, @"Each grid square worked, in the map's colours",
     @"The Maidenhead grid: its fields (20 x 10 degrees), and its squares (2 x 1) when zoomed in",
     @"Field names (FN, EM...), and square names (FN31) when zoomed in"},
    {kLayerCountries, @"countries", @"Countries", "mapDxcc", "mapCountries", "mapCountryLabels", true, false,
     @"Each DXCC entity worked, its own land shaded (Alaska apart from the United States, Sardinia from Italy, Scotland from England); "
     @"a dot for one too small to shade",
     @"Every country outlined, coasts and borders (Natural Earth, public domain)", @"Each country's name, where it fits inside the country on screen"},
    {kLayerStates, @"states", @"US states", "mapShowStates", "mapUsStates", "mapStateLabels", false, false,
     @"Each US state worked, shaded: from STATE, else where the QSO was", @"State lines (Natural Earth, public domain)",
     @"Each state's postal code, where it fits"},
    {kLayerCounties, @"counties", @"US counties", "mapShowCounties", "mapCounties", "mapCountyLabels", false, false,
     @"Each US county worked, shaded: from CNTY, else where the QSO was (LAT/LON or a 6-character grid)",
     @"County lines (Natural Earth, public domain), from 2.5x zoom", @"Each county's name, where it fits"},
    {kLayerCq, @"cq", @"CQ zones", "mapShowCq", "mapCqZones", "mapCqLabels", false, false,
     @"Each CQ zone worked, shaded: from CQZ, else where the QSO was, else the country data",
     @"CQ zones 1-40 (HB9HIL's hamradio-zones-geojson, MIT); approximate", @"The CQ zones' numbers"},
    {kLayerItu, @"itu", @"ITU zones", "mapShowItu", "mapItuZones", "mapItuLabels", false, false,
     @"Each ITU zone worked, shaded: from ITUZ, else where the QSO was, else the country data",
     @"ITU zones 1-90 (HB9HIL's hamradio-zones-geojson, MIT); approximate", @"The ITU zones' numbers"},
    {kLayerPota, @"pota", @"POTA", "mapShowPota", "mapPota", "mapPotaLabels", true, false,
     @"The POTA parks you hunted (a pin) and activated (a pin with a star), at the parks themselves with POTA's park list "
     @"(Settings, POTA Parks), else at the QSO's grid",
     @"Every active POTA park you haven't worked, as a dot (needs POTA's park list, from Settings)",
     @"Each park's reference (US-1234): the parks you worked always, the others once zoomed in to a few hundred, and names once zoomed in to fewer"},
    {kLayerIota, @"iota", @"IOTA", "mapShowIota", "mapIota", "mapIotaLabels", false, false,
     @"The IOTA groups in your log, filled in (needs IOTA's group list, from Settings)", @"Every IOTA group's box, dashed",
     @"Each group's reference (EU-005), and its name where there is room"},
    {kLayerCities, @"cities", @"Cities", nullptr, "mapCities", "mapCityLabels", false, false, nil,
     @"7,300 cities and towns (Natural Earth, public domain), more as you zoom in", @"City names, where they don't run into each other"},
};

ADIFMapStyle savedStyle() {
    ADIFMapStyle s;
    static const double kSizes[] = {0.75, 1.0, 1.4, 1.9};
    s.colorBy = number("mapColorBy", 0, 4);
    s.palette = number("mapPalette", 0, 4);
    s.shape = number("mapMarkerShape", 0, 2);
    s.fill = number("mapSquareFill", 0, 2);
    s.marker = kSizes[number("mapMarkerSize", 1, 3)];
    s.contact = number("mapContactMarker", 0, 2);
    for (const LayerUi &l : kLayerUi) {
        LayerState &st = s.layer[l.id];
        // POTA's Show was the Parks box (mapParks).
        bool showOn = l.id == kLayerPota ? flag("mapParks", l.showOn) : l.showOn;
        st.show = l.showKey && flag(l.showKey, showOn);
        st.overlay = flag(l.overlayKey, l.overlayOn);
        st.labels = flag(l.labelsKey, true);
    }
    s.legend = flag("mapLegend", true);
    s.rings = flag("mapRings", false);
    s.paths = flag("mapPaths", false);
    s.lineStyle = number("mapLineStyle", 0, 2);
    s.lineWidth = number("mapLineWidth", 1, 2);
    s.arcs = flag("mapArcs", true);
    s.lineOpacity = number("mapLineOpacity", 1, 2);
    s.areaShade = number("mapAreaShade", 1, 2);
    s.dayNight = flag("mapDayNight", false);
    s.greyLine = flag("mapGreyLine", false);
    s.sunTime = number("mapSunTime", 0, 1);
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
        case ADIFMapHit::Area: {
            const adif::AreaIndex &index = adif::areaIndex(layerOverlay(h.layer));
            if (h.index >= index.size()) break;
            std::string name = index.area(h.index).name;
            std::vector<size_t> qsos = [mw.view areaQsos:h.layer name:name];
            bool confirmed = false;
            size_t byField = 0, byPlace = 0, byCty = 0;
            for (size_t qi : qsos) {
                if (qi >= mw.data.qsos.size()) continue;
                const adif::QsoAreas &a = mw.data.qsos[qi].areas;
                confirmed |= mw.data.qsos[qi].confirmed;
                adif::AreaFrom from = h.layer == kLayerStates ? a.stateFrom : h.layer == kLayerCounties ? a.countyFrom : h.layer == kLayerCq ? a.cqFrom : a.ituFrom;
                byField += from == adif::AreaFrom::Field, byPlace += from == adif::AreaFrom::Location, byCty += from == adif::AreaFrom::CountryFile;
            }
            static const char *const kField[] = {"", "", "STATE", "CNTY", "CQZ", "ITUZ"};
            std::string title = h.layer == kLayerCq    ? "CQ zone " + name
                                : h.layer == kLayerItu ? "ITU zone " + name
                                : h.layer == kLayerCounties && name.size() > 3 ? name.substr(3) + ", " + name.substr(0, 2)
                                                                                 : name;
            std::string from;
            auto part = [&](size_t n, const std::string &how) {
                if (n) from += (from.empty() ? "" : ", ") + std::to_string(n) + " " + how;
            };
            part(byField, std::string("by ") + kField[h.layer]);
            part(byPlace, "by where the QSO was");
            part(byCty, "by the country data");
            return title + ": " + plural(qsos.size(), "QSO") + (confirmed ? ", confirmed" : "") + " (" + callsOf(qsos) + ")" +
                   (from.empty() ? "" : "; " + from) + "." + where;
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
    else if (h.kind == ADIFMapHit::Area) {
        const adif::AreaIndex &index = adif::areaIndex(layerOverlay(h.layer));
        if (h.index < index.size()) qsos = [mw.view areaQsos:h.layer name:index.area(h.index).name];
    } else if (h.kind == ADIFMapHit::Iota && h.index < ADIFIotaGroups().size()) qsos = [mw.view iotaQsos:ADIFIotaGroups()[h.index].ref];
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
adif::MapFilter savedPlaceFilter();
void updateFilterButton();

// The Other programs list: the common programs, then any other SIG in the log, each with its count.
void fillPrograms() {
    NSMenu *menu = mw.programs.menu;
    menu.autoenablesItems = NO;
    [menu removeAllItems];
    [menu addItemWithTitle:@"Other programs" action:nil keyEquivalent:@""];  // the pull-down's own title
    std::map<std::string, std::set<std::string>> refs;
    for (const adif::MapPark &p : mw.data.parks)
        if (p.program != "POTA") refs[p.program].insert(p.reference);
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
            if (p.program != "POTA") all.insert(p.program);
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

// The view with this identifier inside v, or nil.
NSView *findView(NSView *v, NSString *ident) {
    if ([v.identifier isEqualToString:ident]) return v;
    for (NSView *sub in v.subviews)
        if (NSView *found = findView(sub, ident)) return found;
    return nil;
}

// Style Options: how the map looks, in sections; each choice applies at once and is kept.
struct StyleChoice {
    const char *key;
    NSString *ident;
    int fallback;
    NSArray<NSString *> *titles;  // a popup; nil: a checkbox
    NSString *title, *tip;
};
NSArray<NSString *> *const kPaletteTitles = @[ @"Standard", @"Colour-blind safe", @"High contrast", @"Light (for printing)", @"Night (red)" ];

void fillStyle() {
    if (!mw.styleWindow) return;
    ADIFMapStyle s = savedStyle();
    NSView *root = mw.styleWindow.contentView;
    for (NSString *ident in @[ @"map.style.line", @"map.style.width", @"map.style.strength", @"map.style.arcs" ])
        if (NSControl *c = (NSControl *)findView(root, ident)) c.enabled = s.paths;
    if (NSControl *c = (NSControl *)findView(root, @"map.style.rings")) c.enabled = !mw.home.empty();
    if (NSControl *c = (NSControl *)findView(root, @"map.style.sunTime")) c.enabled = s.dayNight || s.greyLine;
}

void showStyleOptions() {
    if (!mw.styleWindow) {
        NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 560)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        p.title = @"Style Options";
        p.releasedWhenClosed = NO;
        p.hidesOnDeactivate = NO;
        p.floatingPanel = YES;
        p.identifier = @"map.style";
        NSMutableArray *rows = [NSMutableArray array];
        auto section = [&](NSString *title) {
            NSTextField *t = ADIFLabel(title);
            t.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
            [rows addObject:@[ t, [NSGridCell emptyContentView] ]];
        };
        auto add = [&](const StyleChoice &c) {
            NSControl *control;
            if (c.titles) {
                NSPopUpButton *pop = ADIFPopup(c.titles);
                [pop selectItemAtIndex:std::clamp(number(c.key, c.fallback, (int)c.titles.count - 1), 0, (int)c.titles.count - 1)];
                std::string key = c.key;
                ADIFOnAction(pop, ^{
                    setSetting(key.c_str(), std::to_string(pop.indexOfSelectedItem));
                    applyStyle();
                    fillStyle();
                    fillPrograms();  // program swatches follow the palette
                });
                control = pop;
            } else {
                NSButton *box = ADIFCheckbox(c.title, flag(c.key, c.fallback));
                std::string key = c.key;
                ADIFOnAction(box, ^{
                    saveFlag(key.c_str(), box.state == NSControlStateValueOn);
                    applyStyle();
                    fillStyle();
                });
                control = box;
            }
            control.identifier = c.ident;
            control.toolTip = c.tip;
            [rows addObject:@[ c.titles ? ADIFLabel(c.title) : [NSGridCell emptyContentView], control ]];
        };
        section(@"Colours");
        add({"mapPalette", @"map.style.palette", 0, kPaletteTitles, @"Palette:",
             @"Colour-blind safe: colours that stay apart for red-green and blue-yellow colour blindness. Light: for printing. Night (red): red on "
             @"black, to keep your night vision"});
        section(@"Markers");
        add({"mapMarkerSize", @"map.style.size", 1, @[ @"Small", @"Medium", @"Large", @"Extra large" ], @"Size:", nil});
        add({"mapMarkerShape", @"map.style.shape", 0, @[ @"By layer: dots, triangles, diamonds", @"All circles", @"All squares" ], @"Shape:", nil});
        add({"mapContactMarker", @"map.style.contact", 0, @[ @"Pins", @"Dots", @"Crosshairs" ], @"Contacts:", nil});
        section(@"Worked areas");
        add({"mapSquareFill", @"map.style.fill", 0, @[ @"Solid", @"See-through", @"Outlines" ], @"Grid squares:", nil});
        add({"mapAreaShade", @"map.style.shade", 1, @[ @"Light", @"Medium", @"Strong" ], @"Other areas:",
             @"How strongly worked countries, states, counties and zones are shaded"});
        section(@"Lines to contacts");
        add({"mapLineStyle", @"map.style.line", 0, @[ @"Solid", @"Dashed", @"Dotted" ], @"Line:", nil});
        add({"mapLineWidth", @"map.style.width", 1, @[ @"Thin", @"Medium", @"Thick" ], @"Width:", nil});
        add({"mapLineOpacity", @"map.style.strength", 1, @[ @"Faint", @"Medium", @"Solid" ], @"Strength:",
             @"Each line is its contact's marker colour; this is how strongly it shows"});
        add({"mapArcs", @"map.style.arcs", 1, nil, @"Arch over the globe",
             @"On the globe, draw each line as an arch rising over it (for looks: the true path, and the beam heading, is the straight line "
             @"you get with this off)"});
        section(@"On the map");
        add({"mapLegend", @"map.style.legend", 1, nil, @"Legend", nil});
        add({"mapRings", @"map.style.rings", 0, nil, @"Distance rings from my grid", nil});
        add({"mapDayNight", @"map.style.dayNight", 0, nil, @"Day and night", @"The night side shaded, deeper as the sun goes further down, and the "
                                                                              @"line between day and night; the sun where it is overhead"});
        add({"mapGreyLine", @"map.style.greyLine", 0, nil, @"Grey line",
             @"The twilight band, where the sun has set but is less than 6 degrees down (civil twilight), tinted gold: a common time for "
             @"long-distance openings"});
        add({"mapSunTime", @"map.style.sunTime", 0, @[ @"Now", @"The selected QSO's time" ], @"Sun at:",
             @"Draw day and night for now (updated each minute), or for the time of the QSO you clicked"});
        NSButton *reset = [NSButton buttonWithTitle:@"Reset to Defaults" target:nil action:nil];
        reset.identifier = @"map.style.reset";
        ADIFOnAction(reset, ^{
            for (const char *key : {"mapPalette", "mapMarkerSize", "mapMarkerShape", "mapContactMarker", "mapSquareFill", "mapAreaShade", "mapLineStyle",
                                    "mapLineWidth", "mapLineOpacity", "mapArcs", "mapLegend", "mapRings", "mapDayNight", "mapGreyLine", "mapSunTime"})
                setSetting(key, "");
            [mw.styleWindow orderOut:nil];
            mw.styleWindow = nil;
            applyStyle();
            fillPrograms();
            showStyleOptions();
        });
        [rows addObject:@[ [NSGridCell emptyContentView], reset ]];
        NSGridView *grid = [NSGridView gridViewWithViews:rows];
        grid.rowSpacing = 6;
        grid.columnSpacing = 10;
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
        for (NSInteger r = 0; r < grid.numberOfRows; ++r) {  // section titles span both columns, with room above
            NSGridCell *first = [grid cellAtColumnIndex:0 rowIndex:r];
            if ([first.contentView isKindOfClass:NSTextField.class] && ((NSTextField *)first.contentView).font.pointSize >= NSFont.systemFontSize &&
                [((NSTextField *)first.contentView).font.fontDescriptor symbolicTraits] & NSFontDescriptorTraitBold) {
                [grid mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(r, 1)];
                first.xPlacement = NSGridCellPlacementLeading;
                if (r > 0) [grid rowAtIndex:r].topPadding = 8;
            }
        }
        grid.translatesAutoresizingMaskIntoConstraints = NO;
        [p.contentView addSubview:grid];
        [NSLayoutConstraint activateConstraints:@[
            [grid.topAnchor constraintEqualToAnchor:p.contentView.topAnchor constant:16],
            [grid.leadingAnchor constraintEqualToAnchor:p.contentView.leadingAnchor constant:16],
            [grid.trailingAnchor constraintLessThanOrEqualToAnchor:p.contentView.trailingAnchor constant:-16],
            [grid.bottomAnchor constraintEqualToAnchor:p.contentView.bottomAnchor constant:-16],
        ]];
        mw.styleWindow = p;
        NSRect frame = mw.window.frame;
        [p setFrameTopLeftPoint:NSMakePoint(NSMaxX(frame) - 20, NSMaxY(frame) - 60)];
    }
    fillStyle();
    [mw.styleWindow makeKeyAndOrderFront:nil];
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
        adif::MapFilter places = savedPlaceFilter();
        f.continents = places.continents, f.dxcc = places.dxcc, f.cq = places.cq, f.itu = places.itu, f.states = places.states,
        f.counties = places.counties, f.regions = places.regions, f.potaLocations = places.potaLocations;
        adif::MapContext context;
        context.countries = &ADIFCountries();
        context.parks = &ADIFPotaParks();
        mw.data = adif::mapData(text, r.model, f, context);
        [mw.view setParkFilter:places on:flag("mapFilterParks", false)];
        updateFilterButton();
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
        for (const adif::MapPark &p : mw.data.parks) (p.program == "POTA" ? parkRefs : otherRefs).insert(p.program + " " + p.reference);
        mw.summary = plural(mw.data.squares.size(), "grid square") + " (" + std::to_string(confirmedSquares) + " confirmed), " +
                     std::to_string(mw.dxcc.size()) + " DXCC (" + std::to_string(confirmedDxcc) + " confirmed), " +
                     plural(parkRefs.size(), "POTA park") + " where the QSO has a grid, " + plural(otherRefs.size(), "other reference") +
                     " (WWFF, IOTA, SOTA... under Other programs)" + (mw.home.empty() ? "" : "; home " + mw.home) + ". " +
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

// ── More Filters: places ──

const char *const kContinents[7] = {"AF", "AN", "AS", "EU", "NA", "OC", "SA"};

std::vector<std::string> splitSetting(const char *key, char sep) {
    std::string v = setting(key);
    std::vector<std::string> out;
    for (size_t b = 0; b <= v.size();) {
        size_t e = v.find(sep, b);
        if (e == std::string::npos) e = v.size();
        std::string item = v.substr(b, e - b);
        while (!item.empty() && item.front() == ' ') item.erase(item.begin());
        while (!item.empty() && item.back() == ' ') item.pop_back();
        if (!item.empty()) out.push_back(item);
        b = e + 1;
    }
    return out;
}

void saveSetting(const char *key, const std::vector<std::string> &items, char sep) {
    std::string v;
    for (const std::string &i : items) v += (v.empty() ? "" : std::string(1, sep)) + i;
    setSetting(key, v);
}

// The places the Filters keep, as saved: continents, DXCC (names or numbers), zones, states,
// counties, regions and POTA locations.
adif::MapFilter savedPlaceFilter() {
    adif::MapFilter f;
    for (const std::string &c : splitSetting("mapFilterContinents", ',')) f.continents.insert(c);
    for (const std::string &d : splitSetting("mapFilterDxcc", ';')) {
        if (std::all_of(d.begin(), d.end(), [](char c) { return c >= '0' && c <= '9'; })) {
            f.dxcc.insert(std::atoi(d.c_str()));
            continue;
        }
        for (const adif::CountryInfo &c : ADIFCountries().all())
            if (strcasecmp(c.name.c_str(), d.c_str()) == 0) f.dxcc.insert(c.dxcc);
        if (f.dxcc.empty()) f.dxcc.insert(-1);  // a name the country data doesn't know matches nothing
    }
    for (const std::string &z : splitSetting("mapFilterCq", ',')) f.cq.insert(std::atoi(z.c_str()));
    for (const std::string &z : splitSetting("mapFilterItu", ',')) f.itu.insert(std::atoi(z.c_str()));
    for (const std::string &st : splitSetting("mapFilterStates", ',')) f.states.insert(st);
    for (const std::string &c : splitSetting("mapFilterCounties", ';')) {
        const adif::AreaIndex &counties = adif::areaIndex(adif::Overlay::UsCounties);
        size_t i = counties.byCounty(c);
        f.counties.insert(i == adif::AreaIndex::npos ? c : counties.area(i).name);
    }
    for (const std::string &r : splitSetting("mapFilterRegions", ',')) f.regions.insert(r);
    for (const std::string &l : splitSetting("mapFilterPota", ',')) f.potaLocations.insert(l);
    return f;
}

size_t placeKinds(const adif::MapFilter &f) {
    return !f.continents.empty() + !f.dxcc.empty() + !f.cq.empty() + !f.itu.empty() + !f.states.empty() + !f.counties.empty() + !f.regions.empty() +
           !f.potaLocations.empty();
}

void updateFilterButton() {
    size_t n = placeKinds(savedPlaceFilter());
    mw.moreFilters.title = n ? [NSString stringWithFormat:@"More Filters (%zu)...", n] : @"More Filters...";
    mw.clearFilters.enabled = n > 0 || mw.band.indexOfSelectedItem > 0 || mw.mode.indexOfSelectedItem > 0 || mw.dates.indexOfSelectedItem > 0 ||
                              mw.confirmed.indexOfSelectedItem > 0;
}

std::vector<std::string> tokens(NSTokenField *t) {
    std::vector<std::string> out;
    for (id o in [t.objectValue isKindOfClass:NSArray.class] ? (NSArray *)t.objectValue : @[])
        if ([o isKindOfClass:NSString.class] && [(NSString *)o length]) out.push_back(ADIFStd(o));
    return out;
}

void refresh();

// The popover's controls changed: save them, filter again.
void placeFiltersChanged() {
    std::vector<std::string> conts;
    for (int i = 0; i < 7; ++i)
        if (mw.continent[i].state == NSControlStateValueOn) conts.push_back(kContinents[i]);
    saveSetting("mapFilterContinents", conts, ',');
    saveSetting("mapFilterDxcc", tokens(mw.dxccTokens), ';');
    auto numbers = [](NSTextField *f, int max) {
        std::vector<std::string> out;
        for (NSString *part in [f.stringValue componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]]) {
            int n = part.intValue;
            if (n >= 1 && n <= max) out.push_back(std::to_string(n));
        }
        return out;
    };
    saveSetting("mapFilterCq", numbers(mw.cqField, 40), ',');
    saveSetting("mapFilterItu", numbers(mw.ituField, 90), ',');
    std::vector<std::string> states;
    for (std::string st : tokens(mw.stateTokens)) {
        for (char &c : st) c = (char)toupper((unsigned char)c);
        states.push_back(st);
    }
    saveSetting("mapFilterStates", states, ',');
    saveSetting("mapFilterCounties", tokens(mw.countyTokens), ';');
    std::vector<std::string> pota;
    for (std::string l : tokens(mw.potaTokens)) {
        for (char &c : l) c = (char)toupper((unsigned char)c);
        pota.push_back(l);
    }
    saveSetting("mapFilterPota", pota, ',');
    saveFlag("mapFilterParks", mw.parksToo.state == NSControlStateValueOn);
    refresh();
}

void fillPlaceControls() {
    adif::MapFilter f = savedPlaceFilter();
    for (int i = 0; i < 7; ++i) mw.continent[i].state = f.continents.count(kContinents[i]) ? NSControlStateValueOn : NSControlStateValueOff;
    auto set = [](NSTokenField *t, const std::vector<std::string> &items) {
        NSMutableArray *a = [NSMutableArray array];
        for (const std::string &i : items) [a addObject:ADIFString(i)];
        t.objectValue = a;
    };
    set(mw.dxccTokens, splitSetting("mapFilterDxcc", ';'));
    set(mw.stateTokens, splitSetting("mapFilterStates", ','));
    set(mw.countyTokens, splitSetting("mapFilterCounties", ';'));
    set(mw.potaTokens, splitSetting("mapFilterPota", ','));
    auto join = [](const std::vector<std::string> &v) {
        std::string out;
        for (const std::string &s : v) out += (out.empty() ? "" : ", ") + s;
        return ADIFString(out);
    };
    mw.cqField.stringValue = join(splitSetting("mapFilterCq", ','));
    mw.ituField.stringValue = join(splitSetting("mapFilterItu", ','));
    mw.parksToo.state = flag("mapFilterParks", false) ? NSControlStateValueOn : NSControlStateValueOff;
    // Regions: a menu of checkable items, by kind.
    NSMenu *menu = mw.regions.menu;
    [menu removeAllItems];
    std::set<std::string> chosen = f.regions;
    [menu addItemWithTitle:chosen.empty() ? @"Any region" : [NSString stringWithFormat:@"%zu region%s", chosen.size(), chosen.size() == 1 ? "" : "s"]
                    action:nil
             keyEquivalent:@""];
    std::string kind;
    for (const adif::UsRegion &r : adif::usRegions()) {
        if (r.kind != kind) {
            kind = r.kind;
            [menu addItem:[NSMenuItem separatorItem]];
            NSMenuItem *head = [menu addItemWithTitle:ADIFString(kind) action:nil keyEquivalent:@""];
            head.enabled = NO;
        }
        NSMenuItem *item = [menu addItemWithTitle:ADIFString(r.name) action:nil keyEquivalent:@""];
        item.state = chosen.count(r.id) ? NSControlStateValueOn : NSControlStateValueOff;
        item.indentationLevel = 1;
        std::string id = r.id;
        ADIFBlockMenuItem(item, ^{
            std::vector<std::string> ids = splitSetting("mapFilterRegions", ',');
            auto it = std::find(ids.begin(), ids.end(), id);
            if (it == ids.end()) ids.push_back(id);
            else ids.erase(it);
            saveSetting("mapFilterRegions", ids, ',');
            fillPlaceControls();
            refresh();
        });
    }
}

// More Filters: a popover of places to keep. Changes apply as they're made.
void showMoreFilters() {
    if (!mw.filterPopover) {
        mw.completers = [NSMutableArray array];
        auto tokenField = [](NSString *ident, NSString *placeholder, NSArray<NSString *> *candidates, NSString *separators) {
            NSTokenField *t = [[NSTokenField alloc] initWithFrame:NSMakeRect(0, 0, 380, 24)];
            t.identifier = ident;
            t.placeholderString = placeholder;
            t.tokenizingCharacterSet = [NSCharacterSet characterSetWithCharactersInString:separators];
            ADIFTokenCompleter *c = [[ADIFTokenCompleter alloc] init];
            c.candidates = candidates;
            t.delegate = c;
            [mw.completers addObject:c];
            [t.widthAnchor constraintEqualToConstant:380].active = YES;
            ADIFOnAction(t, ^{ placeFiltersChanged(); });
            return t;
        };
        NSMutableArray *dxccNames = [NSMutableArray array];
        std::set<std::string> seen;
        for (const adif::CountryInfo &c : ADIFCountries().all())
            if (seen.insert(c.name).second) [dxccNames addObject:ADIFString(c.name)];
        NSMutableArray *states = [NSMutableArray array], *counties = [NSMutableArray array], *locations = [NSMutableArray array];
        const adif::AreaIndex &st = adif::areaIndex(adif::Overlay::UsStates), &co = adif::areaIndex(adif::Overlay::UsCounties);
        for (size_t i = 0; i < st.size(); ++i) [states addObject:ADIFString(st.area(i).name)];
        for (size_t i = 0; i < co.size(); ++i) [counties addObject:ADIFString(co.area(i).name)];
        std::set<std::string> locs;
        for (const adif::PotaPark &p : ADIFPotaParks().parks())
            for (size_t b = 0; b <= p.location.size();) {
                size_t e = p.location.find(',', b);
                if (e == std::string::npos) e = p.location.size();
                if (e > b) locs.insert(p.location.substr(b, e - b));
                b = e + 1;
            }
        for (const std::string &l : locs) [locations addObject:ADIFString(l)];
        mw.dxccTokens = tokenField(@"map.filter.dxcc", @"Countries (DXCC), e.g. Italy, Canada", dxccNames, @";");
        mw.stateTokens = tokenField(@"map.filter.states", @"US states, e.g. WI, IL", states, @", ");
        mw.countyTokens = tokenField(@"map.filter.counties", @"US counties, e.g. WI,Dane; WI,Milwaukee", counties, @";");
        mw.potaTokens = tokenField(@"map.filter.pota", @"POTA locations, e.g. US-WI, CA-ON", locations, @", ");
        NSMutableArray *conts = [NSMutableArray array];
        for (int i = 0; i < 7; ++i) {
            mw.continent[i] = ADIFCheckbox(@(kContinents[i]), false);
            mw.continent[i].identifier = [NSString stringWithFormat:@"map.filter.continent.%s", kContinents[i]];
            ADIFOnAction(mw.continent[i], ^{ placeFiltersChanged(); });
            [conts addObject:mw.continent[i]];
        }
        NSStackView *contRow = [NSStackView stackViewWithViews:conts];
        contRow.spacing = 8;
        auto zoneField = [](NSString *ident, NSString *placeholder) {
            NSTextField *f = ADIFTextField(placeholder, 140);
            f.identifier = ident;
            ADIFOnAction(f, ^{ placeFiltersChanged(); });
            return f;
        };
        mw.cqField = zoneField(@"map.filter.cq", @"e.g. 3, 4, 5");
        mw.ituField = zoneField(@"map.filter.itu", @"e.g. 6, 7, 8");
        NSStackView *zones = [NSStackView stackViewWithViews:@[ mw.cqField, ADIFLabel(@"ITU zones:"), mw.ituField ]];
        zones.spacing = 8;
        mw.regions = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
        mw.regions.identifier = @"map.filter.regions";
        mw.regions.toolTip = @"US call areas, Census regions and divisions, ARRL divisions (California, New York and New Jersey count for an ARRL "
                             @"division by the QSO's ARRL_SECT)";
        mw.parksToo = ADIFCheckbox(@"Also limit the POTA parks you haven't worked", false);
        mw.parksToo.identifier = @"map.filter.parks";
        mw.parksToo.toolTip = @"The POTA layer's Overlay shows only the parks in these places (their location, state, region, country and continent)";
        ADIFOnAction(mw.parksToo, ^{ placeFiltersChanged(); });
        NSButton *clear = [NSButton buttonWithTitle:@"Clear Places" target:nil action:nil];
        ADIFOnAction(clear, ^{
            for (const char *key : {"mapFilterContinents", "mapFilterDxcc", "mapFilterCq", "mapFilterItu", "mapFilterStates", "mapFilterCounties",
                                    "mapFilterRegions", "mapFilterPota"})
                setSetting(key, "");
            fillPlaceControls();
            refresh();
        });
        NSGridView *grid = [NSGridView gridViewWithViews:@[
            @[ ADIFLabel(@"Continents:"), contRow ], @[ ADIFLabel(@"DXCC:"), mw.dxccTokens ], @[ ADIFLabel(@"CQ zones:"), zones ],
            @[ ADIFLabel(@"US states:"), mw.stateTokens ], @[ ADIFLabel(@"US counties:"), mw.countyTokens ],
            @[ ADIFLabel(@"US regions:"), mw.regions ], @[ ADIFLabel(@"POTA locations:"), mw.potaTokens ],
            @[ [NSGridCell emptyContentView], mw.parksToo ], @[ [NSGridCell emptyContentView], clear ]
        ]];
        grid.rowSpacing = 8;
        grid.columnSpacing = 10;
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
        grid.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *help = [NSTextField wrappingLabelWithString:@"Keep only the QSOs in these places: within a line any of its values, "
                                                                 @"and every line that has values. Changes apply as you make them."];
        help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        help.textColor = NSColor.secondaryLabelColor;
        help.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
        content.identifier = @"map.filters";
        [content addSubview:help];
        [content addSubview:grid];
        [NSLayoutConstraint activateConstraints:@[
            [help.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
            [help.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [help.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [help.widthAnchor constraintEqualToConstant:500],
            [grid.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:10],
            [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [grid.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-14],
            [grid.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        ]];
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = content;
        mw.filterPopover = [[NSPopover alloc] init];
        mw.filterPopover.contentViewController = vc;
        mw.filterPopover.behavior = NSPopoverBehaviorTransient;
    }
    fillPlaceControls();
    [mw.filterPopover showRelativeToRect:mw.moreFilters.bounds ofView:mw.moreFilters preferredEdge:NSRectEdgeMaxY];
}

// A Labels box works while its layer shows (outlined, or its worked areas).
void labelsFollow() {
    for (const LayerUi &l : kLayerUi)
        mw.labels[l.id].enabled = mw.overlay[l.id].state == NSControlStateValueOn || (mw.show[l.id] && mw.show[l.id].state == NSControlStateValueOn);
}

// A layer's box changed (0 Show, 1 Overlay, 2 Labels). Ticking Show turns that layer's Overlay
// and Labels on too: the worked areas among all of them, named.
void layerChanged(MapLayerId id, int which) {
    if (which == 0 && mw.show[id].state == NSControlStateValueOn)
        mw.overlay[id].state = mw.labels[id].state = NSControlStateValueOn;
    for (const LayerUi &l : kLayerUi) {
        if (l.showKey) saveFlag(l.showKey, mw.show[l.id].state == NSControlStateValueOn);
        saveFlag(l.overlayKey, mw.overlay[l.id].state == NSControlStateValueOn);
        saveFlag(l.labelsKey, mw.labels[l.id].state == NSControlStateValueOn);
    }
    labelsFollow();
    applyStyle();
    fillStyle();
    bool on = which != 2 && (which == 0 ? mw.show[id] : mw.overlay[id]).state == NSControlStateValueOn;
    if (on && id == kLayerIota && ADIFIotaGroups().empty()) setStatus("IOTA: download IOTA's group list first, in Settings (IOTA Groups).");
    if (on && id == kLayerPota && !ADIFPotaParks().size())
        setStatus("POTA: download POTA's park list first, in Settings (POTA Parks). Until then, the parks you hunted show at the QSO's grid.");
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
        // The layers: a column each, with its Show, Overlay and Labels boxes.
        ADIFMapStyle saved = savedStyle();
        NSMutableArray *header = [NSMutableArray arrayWithObject:[NSGridCell emptyContentView]];
        NSMutableArray *showRow = [NSMutableArray arrayWithObject:ADIFLabel(@"Show:")];
        NSMutableArray *overlayRow = [NSMutableArray arrayWithObject:ADIFLabel(@"Overlay:")];
        NSMutableArray *labelsRow = [NSMutableArray arrayWithObject:ADIFLabel(@"Labels:")];
        auto box = [](bool on, NSString *kind, const LayerUi &l, NSString *tip, NSString *spoken) {
            NSButton *b = ADIFCheckbox(@"", on);
            b.identifier = [NSString stringWithFormat:@"map.%@.%@", kind, l.ident];
            b.toolTip = tip;
            b.accessibilityLabel = [NSString stringWithFormat:spoken, l.title];
            return b;
        };
        for (const LayerUi &l : kLayerUi) {
            NSTextField *title = ADIFLabel(l.title);
            title.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
            [header addObject:title];
            mw.show[l.id] = l.showKey ? box(saved[l.id].show, @"show", l, l.showTip, @"Show worked %@") : nil;
            mw.overlay[l.id] = box(saved[l.id].overlay, @"overlay", l, l.overlayTip, @"Overlay %@");
            mw.labels[l.id] = box(saved[l.id].labels, @"labels", l, l.labelsTip, @"Labels for %@");
            [showRow addObject:mw.show[l.id] ?: [NSGridCell emptyContentView]];
            [overlayRow addObject:mw.overlay[l.id]];
            [labelsRow addObject:mw.labels[l.id]];
        }
        NSGridView *layers = [NSGridView gridViewWithViews:@[ header, showRow, overlayRow, labelsRow ]];
        layers.rowSpacing = 4;
        layers.columnSpacing = 12;
        for (NSInteger c = 1; c < layers.numberOfColumns; ++c) [layers columnAtIndex:c].xPlacement = NSGridCellPlacementCenter;
        for (NSInteger r = 1; r < layers.numberOfRows; ++r) [layers rowAtIndex:r].yPlacement = NSGridCellPlacementCenter;
        layers.identifier = @"map.layers";
        labelsFollow();
        for (const LayerUi &l : kLayerUi) {
            MapLayerId id = l.id;
            if (mw.show[id]) ADIFOnAction(mw.show[id], ^{ layerChanged(id, 0); });
            ADIFOnAction(mw.overlay[id], ^{ layerChanged(id, 1); });
            ADIFOnAction(mw.labels[id], ^{ layerChanged(id, 2); });
        }
        // Markers, and how to colour them.
        mw.contacts = ADIFCheckbox(@"Contacts", flag("mapContacts", false));
        mw.contacts.toolTip = @"A marker at each contact's own place: its LAT and LON, else a GRIDSQUARE of 6 or 8 characters (a 4-character "
                              @"square is 100 km or more across: Show grid squares shows those). Style Options chooses pins, dots or crosshairs";
        mw.lines = ADIFCheckbox(@"Lines to contacts", flag("mapPaths", false));
        mw.lines.toolTip = @"A great-circle line from your station to each contact, in its marker's colour; Style Options chooses their look";
        mw.programs = pullDown(@"Other programs", @"Other programs' references, a colour each: WWFF parks, SOTA summits, IOTA islands, GMA, "
                                                  @"bunkers, castles... (IOTA starts hidden: callbooks fill it in for every island station)");
        mw.mine = ADIFCheckbox(@"My station", flag("mapMine", true));
        mw.mine.toolTip = @"A star at each MY_GRIDSQUARE in the log";
        mw.colorBy = ADIFPopup(@[ @"Colour by confirmation", @"Colour by band", @"Colour by mode", @"Colour by QSO count",
                                  @"Colour by year first worked" ]);
        [mw.colorBy selectItemAtIndex:number("mapColorBy", 0, 4)];
        // Filters: which QSOs.
        mw.band = ADIFPopup(@[ @"All bands" ]);
        mw.mode = ADIFPopup(@[ @"All modes" ]);
        mw.dates = ADIFPopup(@[ @"All dates", @"Last 30 days", @"Last 12 months", @"This year" ]);
        mw.confirmed = ADIFPopup(@[ @"All QSOs", @"Confirmed", @"Not confirmed" ]);
        // Zoom, projection, style.
        mw.projection = ADIFPopup(@[ @"Equirectangular", @"Mercator", @"Equal Earth", @"Globe" ]);
        mw.projection.autoenablesItems = NO;
        mw.projection.toolTip = @"Equirectangular: the grid as rectangles. Mercator: familiar shapes. Equal Earth: true sizes. Globe: the Earth "
                                @"as seen from space, centred on your grid; drag (or the arrow keys) to turn it any way, zoom in for detail, "
                                @"World to come home. Bearings from the centre are true (beam headings)";
        NSButton *styleButton = smallButton(@"Style Options...", @"Colours, markers, how worked areas are shaded, lines to contacts, the legend, "
                                                                 @"distance rings, day and night, the grey line",
                                            ^{ showStyleOptions(); });
        styleButton.identifier = @"map.style.open";
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
                Box rbox = b;
                ADIFBlockMenuItem(item, ^{ [mw.view showWest:rbox.w south:rbox.s east:rbox.e north:rbox.n]; });
            }
        }
        for (NSControl *c in @[ mw.contacts, mw.band, mw.mode, mw.dates, mw.confirmed ]) ADIFOnAction(c, ^{
            saveFlag("mapContacts", mw.contacts.state == NSControlStateValueOn);
            refresh();
        });
        for (NSButton *b in @[ mw.lines, mw.mine ]) ADIFOnAction(b, ^{
            saveFlag("mapPaths", mw.lines.state == NSControlStateValueOn);
            saveFlag("mapMine", mw.mine.state == NSControlStateValueOn);
            applyStyle();
            fillStyle();
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
        [mw.zoomLabel.widthAnchor constraintEqualToConstant:52].active = YES;  // up to "16384×" (Map Detail)
        NSButton *out = smallButton(@"−", @"Zoom out (−)", ^{ [mw.view zoomBy:1 / 1.5]; });
        NSButton *in = smallButton(@"+", @"Zoom in (+, or double-click the map)", ^{ [mw.view zoomBy:1.5]; });
        NSButton *fit = smallButton(@"Fit Log", @"Zoom to the log's QSOs", ^{ [mw.view fitLog]; });
        NSButton *world = smallButton(@"World", @"The whole world (0)", ^{ [mw.view showWorld]; });
        NSButton *save = smallButton(@"Export PNG...", @"Save the map as it is shown now, with its legend", ^{ exportPng(); });
        NSStackView *markers = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Markers:"), mw.contacts, mw.lines, mw.programs, mw.mine, mw.colorBy ]];
        markers.spacing = 10;
        [markers setCustomSpacing:24 afterView:mw.mine];
        mw.moreFilters = smallButton(@"More Filters...", @"Keep the QSOs in chosen places: continents, countries, zones, US states, counties and "
                                                          @"regions, POTA locations", ^{ showMoreFilters(); });
        mw.moreFilters.identifier = @"map.filter.more";
        mw.clearFilters = smallButton(@"Clear", @"Show every QSO again: all bands, modes, dates and places", ^{
            for (NSPopUpButton *p in @[ mw.band, mw.mode, mw.dates, mw.confirmed ]) [p selectItemAtIndex:0];
            for (const char *key : {"mapFilterContinents", "mapFilterDxcc", "mapFilterCq", "mapFilterItu", "mapFilterStates", "mapFilterCounties",
                                    "mapFilterRegions", "mapFilterPota"})
                setSetting(key, "");
            if (mw.filterPopover) fillPlaceControls();
            refresh();
        });
        mw.clearFilters.identifier = @"map.filter.clear";
        NSStackView *filters =
            [NSStackView stackViewWithViews:@[ ADIFLabel(@"Filters:"), mw.band, mw.mode, mw.dates, mw.confirmed, mw.moreFilters, mw.clearFilters ]];
        filters.spacing = 8;
        NSStackView *zoomRow =
            [NSStackView stackViewWithViews:@[ ADIFLabel(@"Zoom:"), out, mw.zoomLabel, in, fit, world, mw.region, mw.projection, styleButton, save ]];
        zoomRow.spacing = 8;
        [zoomRow setCustomSpacing:24 afterView:world];
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
        for (NSView *v in @[ mw.target, layers, markers, filters, zoomRow, mw.view, scroll, mw.status ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [root addSubview:v];
        }
        CGFloat m = 14;
        [NSLayoutConstraint activateConstraints:@[
            [mw.target.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
            [mw.target.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [layers.topAnchor constraintEqualToAnchor:mw.target.bottomAnchor constant:8],
            [layers.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [layers.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [markers.topAnchor constraintEqualToAnchor:layers.bottomAnchor constant:8],
            [markers.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [markers.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [filters.topAnchor constraintEqualToAnchor:markers.bottomAnchor constant:6],
            [filters.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [filters.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [zoomRow.topAnchor constraintEqualToAnchor:filters.bottomAnchor constant:6],
            [zoomRow.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [zoomRow.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [mw.view.topAnchor constraintEqualToAnchor:zoomRow.bottomAnchor constant:8],
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
    if (!mw.sunTimer)
        mw.sunTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      repeats:YES
                                                        block:^(NSTimer *) {
                                                            ADIFMapStyle st = mw.view.style;
                                                            if (mw.window.visible && (st.dayNight || st.greyLine) && st.sunTime == 0)
                                                                mw.view.needsDisplay = YES;
                                                        }];
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

bool shownArea(std::array<double, 4> *box) {
    if (!mw.window || !mw.window.visible || !mw.view) return false;
    double w, s, e, n;
    [mw.view visibleWest:&w south:&s east:&e north:&n];
    if (e - w >= 359 || n - s >= 170) return false;  // the whole world: not an area to download
    *box = {w, s, e, n};
    return true;
}

void detailChanged() {
    if (mw.view) [mw.view osmChanged];
}

void documentChanged() {
    if (mw.window && mw.window.visible) refresh();
}

}  // namespace worldmap

