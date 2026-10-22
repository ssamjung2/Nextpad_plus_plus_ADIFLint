#import "Map.h"
#import "Night.h"
#import "ParkOutlines.h"
#import "L10n.h"
#import "MapView.h"

#import "Country.h"
#import "IotaGroups.h"
#import "PotaParks.h"
#import "PluginHost.h"
#import "Spots.h"
#import "ToolWindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "adif_detail.h"
#include "adif_geo.h"
#include "adif_worked.h"
#include "adif_regions.h"
#include "adif_palette.h"
#include "adif_projection.h"
#include "adif_spec.h"
#include "adif_sun.h"
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


// The list beside the map (the QSOs chosen; the contacts, parks or spots in view): a row each,
// what it is on the map, where, its colour; its texts come from `text`, by column. A click
// chooses it on the map, a double-click opens it (zooms to it, or goes to the QSO).
struct ADIFViewRow {
    ADIFMapHit hit;                 // what choosing it chooses on the map (None: nothing)
    size_t item = 0;                // into the list's data: a QSO, a park, a spot
    double lat = 0, lon = 0;        // where it is
    double km = -1, bearing = 0;    // from where the list measures; km < 0: not placed
    double span = 0.03;             // how far round it a double-click shows (degrees)
    NSColor *color = nil;
    bool tree = false;              // its mark POTA's tree (a POTA activator's spot), else a dot
};

// A list row's mark: POTA's tree in a colour, as text (an attachment), for a POTA activator's spot.
static NSAttributedString *treeMark(NSColor *color) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(11, 12)
                                    flipped:NO
                             drawingHandler:^BOOL(NSRect) {
                                 [color setFill];
                                 [ADIFTreePath(NSMakePoint(5.5, 6), 12) fill];
                                 return YES;
                             }];
    image.accessibilityDescription = T(@"POTA");
    NSTextAttachment *a = [[NSTextAttachment alloc] init];
    a.image = image;
    a.bounds = NSMakeRect(0, -2, 11, 12);
    return [NSAttributedString attributedStringWithAttachment:a];
}

@interface ADIFViewList : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
@property(nonatomic) std::vector<ADIFViewRow> rows;  // the page shown
@property(nonatomic) std::map<std::string, int> styles;  // a column's: 0 text, 1 digits, 2 digits on the right
@property(nonatomic) BOOL quiet;     // the map chose the row: don't tell it back
@property(nonatomic) BOOL building;  // the columns are being set: their moves and sizes aren't the user's
@property(nonatomic, copy) NSString * (^text)(const ADIFViewRow &row, const std::string &column);
@property(nonatomic, copy) void (^onChoose)(const ADIFViewRow &row);
@property(nonatomic, copy) void (^onOpen)(const ADIFViewRow &row);
@property(nonatomic, copy) void (^onSort)(void);
@property(nonatomic, copy) void (^onColumnsChanged)(void);
@property(nonatomic, copy) void (^fillMenu)(NSMenu *menu);  // the header's menu: which columns show
@end

@implementation ADIFViewList
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    return (NSInteger)_rows.size();
}
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSTextField *f = [t makeViewWithIdentifier:col.identifier owner:self];
    if (!f) {
        f = [NSTextField labelWithString:@""];
        f.identifier = col.identifier;
        f.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    std::string column = ADIFStd(col.identifier);
    bool mark = column == "mark";
    auto st = _styles.find(column);
    int style = mark || st == _styles.end() ? 0 : st->second;
    f.alignment = style == 2 ? NSTextAlignmentRight : NSTextAlignmentLeft;
    f.font = style ? [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular]
                   : [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    f.textColor = NSColor.labelColor;
    if (row < 0 || (size_t)row >= _rows.size()) return f;
    const ADIFViewRow &r = _rows[(size_t)row];
    if (mark && r.tree) {
        f.attributedStringValue = treeMark(r.color ?: NSColor.secondaryLabelColor);
    } else if (mark) {
        f.stringValue = r.color ? @"●" : @"";
        f.textColor = r.color ?: NSColor.secondaryLabelColor;
    } else {
        f.stringValue = self.text ? self.text(r, column) : @"";
    }
    return f;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSTableView *t = n.object;
    if (_quiet || t.selectedRow < 0 || (size_t)t.selectedRow >= _rows.size()) return;
    if (self.onChoose) self.onChoose(_rows[(size_t)t.selectedRow]);
}
- (void)tableView:(NSTableView *)t sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old {
    if (!_building && self.onSort) self.onSort();
}
- (void)tableViewColumnDidMove:(NSNotification *)n {
    if (!_building && self.onColumnsChanged) self.onColumnsChanged();
}
- (void)tableViewColumnDidResize:(NSNotification *)n {
    if (!_building && self.onColumnsChanged) self.onColumnsChanged();
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (self.fillMenu) self.fillMenu(menu);
}
- (void)opened:(id)sender {
    NSTableView *t = sender;
    NSInteger row = t.clickedRow >= 0 ? t.clickedRow : t.selectedRow;  // the row double-clicked, else the one chosen
    if (row >= 0 && (size_t)row < _rows.size() && self.onOpen) self.onOpen(_rows[(size_t)row]);
}
@end

// The Map's control groups: laid out left to right at their own sizes, a new line when the next
// doesn't fit, with a thin line between neighbours and between lines; as tall as its lines.
@interface ADIFFlowView : NSView
@property(nonatomic) CGFloat gap;          // between neighbours; the line runs down its middle
@property(nonatomic) BOOL trailingLast;    // the last one at the right end of its line
@property(nonatomic) BOOL centred;         // each centred in its line's height (else at its top)
@end

@implementation ADIFFlowView {
    CGFloat _height;
    std::vector<NSRect> _rules;
}
- (BOOL)isFlipped {
    return YES;
}
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, _height);
}
- (void)layout {
    [super layout];
    CGFloat width = self.bounds.size.width, x = 0, y = 0, lineHeight = 0;
    std::vector<NSRect> rules;
    std::vector<CGFloat> lineStarts;  // the x of each line's vertical rules, to size them when the line ends
    std::vector<NSView *> lineViews;
    auto endLine = [&]() {
        for (CGFloat rx : lineStarts) rules.push_back(NSMakeRect(rx, y, 1, lineHeight));
        if (_centred)
            for (NSView *lv : lineViews) [lv setFrameOrigin:NSMakePoint(lv.frame.origin.x, std::round(y + (lineHeight - lv.frame.size.height) / 2))];
        lineStarts.clear();
        lineViews.clear();
    };
    NSView *last = self.subviews.lastObject;
    for (NSView *v in self.subviews) {
        if (v.hidden) continue;
        NSSize size = v.fittingSize;
        if (x > 0 && x + size.width > width) {
            endLine();
            y += lineHeight + _gap;
            rules.push_back(NSMakeRect(0, y - _gap / 2, width, 1));
            x = 0, lineHeight = 0;
        }
        if (_trailingLast && v == last && x > 0) x = std::max(x, width - size.width);  // pushed to the right, its rule with it
        if (x > 0) lineStarts.push_back(std::round(x - _gap / 2));
        v.frame = NSMakeRect(x, y, size.width, size.height);
        lineViews.push_back(v);
        x += size.width + _gap;
        lineHeight = std::max(lineHeight, size.height);
    }
    endLine();
    CGFloat height = y + lineHeight;
    _rules = rules;
    self.needsDisplay = YES;
    if (std::fabs(height - _height) > 0.5) {
        _height = height;
        [self invalidateIntrinsicContentSize];
    }
}
- (void)drawRect:(NSRect)dirty {
    [[NSColor.separatorColor colorWithAlphaComponent:0.9] setFill];
    for (const NSRect &r : _rules) NSRectFill(r);
}
@end

// Keeps the Map's split views sensible (the map never squeezed out, the list and the status bar
// within reach of a drag) and remembers where their dividers were left.
@interface ADIFSplitKeeper : NSObject <NSSplitViewDelegate>
@property(nonatomic, copy) void (^onMoved)(NSSplitView *split);
@end

@implementation ADIFSplitKeeper
- (CGFloat)splitView:(NSSplitView *)s constrainMinCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)i {
    return std::max(proposed, (CGFloat)(s.vertical ? 360 : 260));  // the map (or the contact panel) keeps this much
}
- (CGFloat)splitView:(NSSplitView *)s constrainMaxCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)i {
    CGFloat whole = s.vertical ? s.bounds.size.width : s.bounds.size.height;
    if ([s.identifier isEqualToString:@"map.status.split"]) return std::min(proposed, whole - 260);  // the situation panel keeps this much
    return std::min(proposed, whole - (s.vertical ? 280 : 70));  // the list, or the status bar, keeps this much
}
- (BOOL)splitView:(NSSplitView *)s canCollapseSubview:(NSView *)v {
    return NO;
}
- (void)splitViewDidResizeSubviews:(NSNotification *)n {
    if (self.onMoved) self.onMoved(n.object);
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
    NSButton *show[kLayerCount] = {}, *overlay[kLayerCount] = {}, *labels[kLayerCount] = {};  // the layers' boxes (no Show for cities)
    NSButton *contacts = nil, *lines = nil, *mine = nil;
    NSPopUpButton *programs = nil, *projection = nil, *colorBy = nil, *region = nil;
    NSPanel *styleWindow = nil;  // Style Options
    NSTimer *sunTimer = nil;     // day and night, while it shows now
    NSPopUpButton *band = nil, *mode = nil, *dates = nil, *confirmed = nil;
    NSTextField *target = nil, *status = nil, *zoomLabel = nil;
    NSTextField *situation = nil;  // the status bar's right side: the log and the spots, for the operator
    NSTextField *slots = nil;      // the contact's DXCC entity's band slots, under its description
    NSTextField *contactTitle = nil;  // what the contact panel is about, in bold, over its description
    NSTextField *today = nil, *air = nil, *wantedLabel = nil;
    NSStackView *wanted = nil;     // the spots most wanted, as links
    ADIFMapHit chosenHit;          // what was clicked last (the contact panel shows it when the pointer is on nothing)
    NSSplitView *mainSplit = nil, *outerSplit = nil, *statusSplit = nil;  // map | list; map and list | status bar; contact | situation
    ADIFSplitKeeper *splitKeeper = nil;
    bool splitsRestored = false;
    // The control groups under the toolbar, which Controls shows or hides.
    NSView *controlsView = nil;
    NSButton *controlsToggle = nil;
    NSLayoutConstraint *controlsGap = nil, *controlsGone = nil, *underGap = nil;
    // More Filters: places.
    NSButton *moreFilters = nil, *clearFilters = nil;
    NSPopover *filterPopover = nil;
    NSButton *continent[7] = {}, *parksToo = nil;
    NSTokenField *dxccTokens = nil, *stateTokens = nil, *countyTokens = nil, *potaTokens = nil;
    NSTextField *cqField = nil, *ituField = nil;
    NSPopUpButton *regions = nil;
    NSMutableArray *completers = nil;
    // Spots: the popover of their own filters, Refresh, Use in New QSO, and what tells the Map of new ones.
    NSButton *spotsButton = nil, *refreshSpotsButton = nil, *useSpot = nil, *spotsOnly = nil;
    NSTextField *spotsOnlyCall = nil;
    NSPopover *spotsPopover = nil;
    NSPopUpButton *spotAge = nil, *spotProgram = nil;
    NSButton *spotSource[3] = {};
    NSTextField *spotStatus = nil;
    id spotsObserver = nil, closeObserver = nil;
    // The list beside the map: what it lists (the QSOs chosen; the contacts, parks or spots in
    // view), from where, sorted how, which page, and what places it.
    NSView *listPanel = nil;
    NSButton *listToggle = nil;
    NSSegmentedControl *listKind = nil, *listUnits = nil;
    NSTextField *listTitle = nil, *listHint = nil, *listGrid = nil, *listPageLabel = nil;
    NSPopUpButton *listFrom = nil, *listPageSize = nil, *listColumnsMenu = nil, *listWithin = nil;
    NSSearchField *listSearch = nil;
    NSButton *listPrev = nil, *listNext = nil;
    NSTableView *listTable = nil;
    ADIFViewList *listRows = nil;
    bool listQueued = false;
    int listColumnsFor = -1;          // the kind the table's columns are for
    size_t listPage[4] = {};          // each kind's page
    bool choosingFromList = false;    // a row chose it: the list stays as it is
    // POTA parks in: the park filter's button and popover.
    NSButton *parkPlacesButton = nil;
    NSPopover *parkPlacesPopover = nil;
    NSTokenField *parkLocations = nil, *parkCounties = nil;
    NSButton *parkHome = nil;
    ADIFTokenCompleter *countyCompleter = nil;
    void (^spotHandler)(const std::vector<std::pair<std::string, std::string>> &) = nil;
    adif::MapData data;
    std::vector<ADIFMapEntity> dxcc;
    std::vector<size_t> listed;   // the QSOs chosen (the list's Selected): indexes into data.qsos
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
    {kLayerSquares, @"grid", N(@"Grid squares"), "mapSquares", "mapGrid", "mapLabels", true, true, N(@"Each grid square worked, in the map's colours"),
     N(@"The Maidenhead grid: its fields (20 x 10 degrees), and its squares (2 x 1) when zoomed in"),
     N(@"Field names (FN, EM...), and square names (FN31) when zoomed in")},
    {kLayerCountries, @"countries", N(@"Countries"), "mapDxcc", "mapCountries", "mapCountryLabels", true, false,
     N(@"Each DXCC entity worked, its own land shaded (Alaska apart from the United States, Sardinia from Italy, Scotland from England); "
     @"a dot for one too small to shade"),
     N(@"Every country outlined, coasts and borders (Natural Earth, public domain)"), N(@"Each country's name, where it fits inside the country on screen")},
    {kLayerStates, @"states", N(@"US states"), "mapShowStates", "mapUsStates", "mapStateLabels", false, false,
     N(@"Each US state worked, shaded: from STATE, else where the QSO was"), N(@"State lines (Natural Earth, public domain)"),
     N(@"Each state's postal code, where it fits")},
    {kLayerCounties, @"counties", N(@"US counties"), "mapShowCounties", "mapCounties", "mapCountyLabels", false, false,
     N(@"Each US county worked, shaded: from CNTY, else where the QSO was (LAT/LON or a 6-character grid)"),
     N(@"County lines (Natural Earth, public domain), from 2.5x zoom"), N(@"Each county's name, where it fits")},
    {kLayerCq, @"cq", N(@"CQ zones"), "mapShowCq", "mapCqZones", "mapCqLabels", false, false,
     N(@"Each CQ zone worked, shaded: from CQZ, else where the QSO was, else the country data"),
     N(@"CQ zones 1-40 (HB9HIL's hamradio-zones-geojson, MIT); approximate"), N(@"The CQ zones' numbers")},
    {kLayerItu, @"itu", N(@"ITU zones"), "mapShowItu", "mapItuZones", "mapItuLabels", false, false,
     N(@"Each ITU zone worked, shaded: from ITUZ, else where the QSO was, else the country data"),
     N(@"ITU zones 1-90 (HB9HIL's hamradio-zones-geojson, MIT); approximate"), N(@"The ITU zones' numbers")},
    {kLayerPota, @"pota", N(@"POTA"), "mapShowPota", "mapPota", "mapPotaLabels", true, false,
     N(@"The POTA parks you hunted (a badge with a tree, in the map's colours) and activated (with a star), at the parks themselves with "
     @"POTA's park list (Settings, POTA Parks), else at the QSO's grid"),
     N(@"Every active POTA park you haven't worked, as a smaller badge (a dot where very many show; needs POTA's park list, from Settings)"),
     N(@"Each park's reference (US-1234) in a box by its badge: the parks you worked always, the others once zoomed in to a few hundred, and "
     @"names once zoomed in to fewer")},
    {kLayerIota, @"iota", N(@"IOTA"), "mapShowIota", "mapIota", "mapIotaLabels", false, false,
     N(@"The IOTA groups in your log, filled in (needs IOTA's group list, from Settings)"), N(@"Every IOTA group's box, dashed"),
     N(@"Each group's reference (EU-005), and its name where there is room")},
    {kLayerCities, @"cities", N(@"Cities"), nullptr, "mapCities", "mapCityLabels", false, false, nil,
     N(@"7,300 cities and towns (Natural Earth, public domain), more as you zoom in"), N(@"City names, where they don't run into each other")},
    {kLayerSpots, @"spots", N(@"Spots"), "mapShowSpots", "mapSpotLines", "mapSpotLabels", false, false,
     N(@"The stations spotted now, from the sources chosen in Spots... (Spothole, a DX cluster, PSKReporter), coloured as Colour by says "
     @"(by confirmation: a new DXCC, a new band or mode, worked, confirmed); older spots fade"),
     N(@"A line from each spotter to the station it heard (while Show is on)"), N(@"Each spotted station's call, where there's room")},
};

// Spotters before "Faint grey" was a choice (mapSpotters: 0 hidden, 1 markers, 2 with calls).
int spotterStyleFallback() {
    std::string old = setting("mapSpotters");
    if (old.empty()) return 2;
    static const int kWas[] = {0, 2, 3};
    return kWas[std::clamp(std::atoi(old.c_str()), 0, 2)];
}

ADIFMapStyle savedStyle() {
    ADIFMapStyle s;
    static const double kSizes[] = {0.75, 1.0, 1.4, 1.9};
    s.colorBy = number("mapColorBy", 0, 4);
    s.palette = ADIFNightMode() ? 4 : number("mapPalette", 0, 4);  // Night Mode: the Night (red) palette
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
    s.spotters = number("mapSpotterStyle", spotterStyleFallback(), 3);
    s.spotLines = number("mapSpotLineStyle", 0, 2);
    s.spotLabel.mode = flag("mapSpotLabelMode", true);
    s.spotLabel.khz = flag("mapSpotLabelFreq", false);
    s.spotLabel.age = flag("mapSpotLabelAge", true);
    s.spotLabel.snr = flag("mapSpotLabelSnr", true);
    s.spotFade = flag("mapSpotFade", true);
    s.parkOutlineOnly = number("mapParkOutlines", 0, 1) == 1;
    s.reference = number("mapReference", 1, 2);
    s.spotlight = flag("mapSpotlight", false);
    return s;
}

void setStatus(const std::string &text) { mw.status.stringValue = ADIFString(tr(text)); }  // a fixed text is translated

// The contact panel with nothing under the pointer or chosen: how to use the map.
std::string idleStatus() {
    return tr("Point at the map for what is there; click a square, dot, pin, park or spot for its QSOs and what it means for your log. Scroll or "
              "pinch to zoom, drag to move (on the globe, to turn it); the legend shows the colours.");
}

void showSituation();
std::string entityName(int dxcc, const std::string &call);

// The contact panel's second line: the band slots of a DXCC entity (green confirmed, orange
// worked, grey not yet), its mode groups the same way, and your QSOs with the call.
void showSlots(int dxcc, const std::string &entity, const std::string &call) {
    if (!mw.slots) return;
    mw.slots.hidden = dxcc <= 0;
    if (dxcc <= 0) {
        mw.slots.stringValue = @"";
        return;
    }
    const MapPalette &pal = adif::mapPalette(mw.view.style.palette);
    const adif::WorkedIndex &w = mw.view.worked;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
    NSFont *bold = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightBold];
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    auto add = [&](const std::string &text, NSColor *colour, NSFont *f) {
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:ADIFString(text)
                                                                    attributes:@{NSFontAttributeName : f, NSForegroundColorAttributeName : colour}]];
    };
    auto colourOf = [&](adif::SlotState st) {
        return st == adif::SlotState::Confirmed ? rgb(pal.confirmed) : st == adif::SlotState::Worked ? rgb(pal.worked) : NSColor.tertiaryLabelColor;
    };
    add(entity + ":  ", NSColor.secondaryLabelColor, [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold]);
    for (const auto &[band, st] : adif::bandSlots(w, dxcc)) {
        std::string b = band.size() > 1 && band.back() == 'm' && isdigit((unsigned char)band[band.size() - 2]) ? band.substr(0, band.size() - 1) : band;
        add(b + " ", colourOf(st), st == adif::SlotState::None ? font : bold);
    }
    auto entityIt = w.entities.find(dxcc);
    static const char *const kModes[] = {"CW", N_("Phone"), N_("Data")};
    add("  ", NSColor.labelColor, font);
    for (int m = 0; m < 3; ++m) {
        adif::SlotState st = entityIt == w.entities.end()                  ? adif::SlotState::None
                             : entityIt->second.confirmedModes.count(m) ? adif::SlotState::Confirmed
                             : entityIt->second.modes.count(m)          ? adif::SlotState::Worked
                                                                        : adif::SlotState::None;
        add(tr(kModes[m]) + " ", colourOf(st), st == adif::SlotState::None ? font : bold);
    }
    if (!call.empty()) {
        auto c = w.calls.find(adif::lookupCall(call));
        std::string worked = c == w.calls.end() ? trf("{call} not in this log", {{"call", call}})
                                                : trp("{call}: {n} QSO", "{call}: {n} QSOs", (long long)c->second.qsos, {{"call", call}}) +
                                                      (c->second.confirmed ? ", " + tr("confirmed") : "");
        add("  \u00B7  " + worked, NSColor.secondaryLabelColor, [NSFont systemFontOfSize:NSFont.smallSystemFontSize]);
    }
    mw.slots.attributedStringValue = out;
}

std::string callsOf(const std::vector<size_t> &qsos);

// What the contact panel is about, in a few words: a spot's call, frequency and mode; a park's
// reference and name; a square; a contact's calls; an entity, area or IOTA group's name.
std::string contactTitle(const ADIFMapHit &h) {
    switch (h.kind) {
        case ADIFMapHit::Spot: {
            if (h.index >= mw.view.spots.size()) return "";
            const adif::Spot &sp = mw.view.spots[h.index].spot;
            std::string t = sp.activator;
            if (!sp.khz.empty()) t += "  \u00B7  " + sp.khz + " kHz";
            if (!sp.mode.empty()) t += " " + sp.mode;
            if (!sp.reference.empty()) t += "  \u00B7  " + (sp.program.empty() ? "" : sp.program + " ") + sp.reference;
            return t;
        }
        case ADIFMapHit::Spotter: return h.index < mw.view.spotters.size() ? mw.view.spotters[h.index].call : "";
        case ADIFMapHit::Pota: {
            const adif::PotaParks &list = ADIFPotaParks();
            return h.index < list.size() ? list.parks()[h.index].ref + "  " + list.parks()[h.index].name : "";
        }
        case ADIFMapHit::Contact: return h.index < mw.view.contacts.size() ? callsOf(mw.view.contacts[h.index].qsos) : "";
        case ADIFMapHit::Square:
        case ADIFMapHit::Empty: return h.square;
        case ADIFMapHit::Dxcc: return h.index < mw.dxcc.size() ? mw.dxcc[h.index].name : "";
        case ADIFMapHit::Area: {
            const adif::AreaIndex &index = adif::areaIndex(layerOverlay(h.layer));
            return h.index < index.size() ? index.area(h.index).name : "";
        }
        case ADIFMapHit::Iota: return h.index < ADIFIotaGroups().size() ? ADIFIotaGroups()[h.index].ref + "  " + ADIFIotaGroups()[h.index].name : "";
        case ADIFMapHit::Park: return h.index < mw.data.parks.size() ? mw.data.parks[h.index].program + " " + mw.data.parks[h.index].reference : "";
        default: return "";
    }
}

// The contact panel for what's under the pointer, or chosen, or nothing: its description, and
// for a station (a spot, a contact, a DXCC entity) its entity's band slots.
void showContact(const ADIFMapHit &h, const std::string &text) {
    setStatus(text);
    int dxcc = 0;
    std::string entity, call;
    const adif::CountryTable &countries = ADIFCountries();
    auto place = [&](const std::string &c, int fieldDxcc) {
        adif::CountryInfo info;
        call = c;
        if (fieldDxcc > 0) dxcc = fieldDxcc;
        else if (!countries.empty() && countries.lookup(c, &info)) dxcc = info.dxcc;
        entity = entityName(dxcc, c);
    };
    if (mw.contactTitle) {
        std::string title = contactTitle(h);
        mw.contactTitle.stringValue = ADIFString(title);
        mw.contactTitle.hidden = title.empty();
    }
    if (h.kind == ADIFMapHit::Spot && h.index < mw.view.spots.size()) {
        const ADIFMapSpot &ms = mw.view.spots[h.index];
        if (!ms.spot.heardMe) dxcc = ms.status.dxcc, entity = ms.status.entity, call = ms.spot.activator;
    } else if (h.kind == ADIFMapHit::Contact && h.index < mw.view.contacts.size() && !mw.view.contacts[h.index].qsos.empty()) {
        const adif::MapQso &q = mw.data.qsos[mw.view.contacts[h.index].qsos[0]];
        place(q.call, q.dxcc);
    } else if (h.kind == ADIFMapHit::Dxcc && h.index < mw.dxcc.size()) {
        dxcc = mw.dxcc[h.index].dxcc, entity = mw.dxcc[h.index].name;
    }
    showSlots(dxcc, entity, call);
}

std::string callsOf(const std::vector<size_t> &qsos) {
    std::vector<std::string> calls;
    for (size_t i : qsos)
        if (i < mw.data.qsos.size() && std::find(calls.begin(), calls.end(), mw.data.qsos[i].call) == calls.end()) calls.push_back(mw.data.qsos[i].call);
    std::string out;
    for (size_t k = 0; k < calls.size() && k < 5; ++k) out += (out.empty() ? "" : ", ") + calls[k];
    if (calls.size() > 5) out += ", +" + std::to_string(calls.size() - 5);
    return out;
}

// "{km} km at {bearing}° from {home}." from home to a place, or "" without a home.
// A spotted station in this log: worked on its band, on others, or not at all.
std::string inLog(const adif::Spot &sp) {
    bool band = false, other = false;
    std::string call = adif::spotterCall(sp.activator);  // without a suffix after "-"
    for (const adif::MapQso &q : mw.data.qsos)
        if (adif::spotterCall(q.call) == call) (q.band == sp.band ? band : other) = true;
    return band ? trf("worked on {band}", {{"band", sp.band}}) : other ? tr("worked on other bands") : tr("not in this log");
}

std::string fromHome(double lat, double lon) {
    double hlat, hlon;
    if (mw.home.empty() || !adif::gridToLatLon(mw.home, &hlat, &hlon)) return "";
    char bearing[16];
    snprintf(bearing, sizeof bearing, "%.0f", adif::initialBearing(hlat, hlon, lat, lon));
    return " " + trf("{km} km at {bearing}° from {home}.", {{"km", std::to_string(std::lround(adif::greatCircleKm(hlat, hlon, lat, lon)))},
                                                              {"bearing", bearing}, {"home", mw.home}});
}

// "3 QSOs, confirmed (K1AB, W2CD)" or "3 QSOs (K1AB, W2CD)".
std::string worked(const std::vector<size_t> &qsos, bool confirmed) {
    return trf(confirmed ? "{qsos}, confirmed ({calls})" : "{qsos} ({calls})", {{"qsos", plural(qsos.size(), "QSO")}, {"calls", callsOf(qsos)}});
}

std::string describe(const ADIFMapHit &h) {
    std::string where;
    if (!mw.home.empty() && !h.square.empty()) {
        std::string d = adif::gridDistanceText(mw.home, h.square);
        if (!d.empty()) where = " " + trf("{distance} from {home}.", {{"distance", d}, {"home", mw.home}});
    }
    switch (h.kind) {
        case ADIFMapHit::Square: {
            const adif::MapSquare &sq = mw.data.squares[h.index];
            return sq.grid + ": " + worked(sq.qsoIndex, sq.confirmed) + "." + where;
        }
        case ADIFMapHit::Dxcc: {
            const ADIFMapEntity &e = mw.dxcc[h.index];
            return trf("{name} (DXCC {n})", {{"name", e.name}, {"n", std::to_string(e.dxcc)}}) + ": " + worked(e.qsos, e.confirmed);
        }
        case ADIFMapHit::Park: {
            const adif::MapPark &p = mw.data.parks[h.index];
            size_t n = 0;
            for (const adif::MapPark &o : mw.data.parks) n += o.reference == p.reference && o.program == p.program;
            const adif::MapQso &q = mw.data.qsos[p.qso];
            return trf("{program} {ref}: {qsos}, in {grid} ({call} {date})",
                       {{"program", p.program}, {"ref", p.reference}, {"qsos", plural(n, "QSO")}, {"grid", p.grid}, {"call", q.call}, {"date", q.date}});
        }
        case ADIFMapHit::Contact: {
            const ADIFMapContact &c = mw.view.contacts[h.index];
            const adif::MapQso &q = mw.data.qsos[c.qsos[0]];
            char at[64];
            snprintf(at, sizeof at, "%.4f %c, %.4f %c", std::fabs(c.lat), c.lat < 0 ? 'S' : 'N', std::fabs(c.lon), c.lon < 0 ? 'W' : 'E');
            return trf("{calls}: {qsos} at {place} (from {source}).",
                       {{"calls", callsOf(c.qsos)}, {"qsos", plural(c.qsos.size(), "QSO")}, {"place", at}, {"source", q.locatedBy}}) +
                   fromHome(c.lat, c.lon);
        }
        case ADIFMapHit::Pota: {
            if (h.index >= ADIFPotaParks().size()) break;
            const adif::PotaPark &p = ADIFPotaParks().parks()[h.index];
            ADIFParkWork w = [mw.view parkWork:p.ref];
            std::string what;
            if (!w.hunted.empty()) {
                bool confirmed = false;
                for (size_t qi : w.hunted) confirmed |= qi < mw.data.qsos.size() && mw.data.qsos[qi].confirmed;
                what = trf("hunted, {qsos}", {{"qsos", worked(w.hunted, confirmed)}});
            }
            if (!w.activated.empty())
                what += (what.empty() ? "" : "; ") + trf("activated by you, {qsos}", {{"qsos", plural(w.activated.size(), "QSO")}});
            if (what.empty()) what = tr("not worked");
            // Where its outline came from, and what a match by name took it to be.
            std::string outline;
            if (const adif::ParkOutline *o = parkoutlines::find(p.ref))
                outline = " " + (o->matched ? trf("Outline: {source}, matched by name: {name}.", {{"source", o->source}, {"name", o->name}})
                                            : trf("Outline: {source}.", {{"source", o->source}}));
            return trf(p.active ? "POTA {ref} {name} ({location}): {what}." : "POTA {ref} {name} ({location}, inactive): {what}.",
                       {{"ref", p.ref}, {"name", p.name}, {"location", p.location}, {"what", what}}) +
                   outline + fromHome(p.lat, p.lon);
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
            std::string title = h.layer == kLayerCq    ? trf("CQ zone {n}", {{"n", name}})
                                : h.layer == kLayerItu ? trf("ITU zone {n}", {{"n", name}})
                                : h.layer == kLayerCounties && name.size() > 3 ? name.substr(3) + ", " + name.substr(0, 2)
                                                                                 : name;
            std::string from;
            auto part = [&](size_t n, const std::string &how) {
                if (n) from += (from.empty() ? "" : ", ") + how;
            };
            part(byField, trf("{n} by {field}", {{"n", std::to_string(byField)}, {"field", kField[h.layer]}}));
            part(byPlace, trf("{n} by where the QSO was", {{"n", std::to_string(byPlace)}}));
            part(byCty, trf("{n} by the country data", {{"n", std::to_string(byCty)}}));
            return title + ": " + worked(qsos, confirmed) + (from.empty() ? "" : "; " + from) + "." + where;
        }
        case ADIFMapHit::Iota: {
            if (h.index >= ADIFIotaGroups().size()) break;
            const adif::IotaGroup &g = ADIFIotaGroups()[h.index];
            std::vector<size_t> qsos = [mw.view iotaQsos:g.ref];
            bool confirmed = false;
            for (size_t qi : qsos) confirmed |= qi < mw.data.qsos.size() && mw.data.qsos[qi].confirmed;
            return "IOTA " + g.ref + " " + g.name + ": " + (qsos.empty() ? tr("not worked") : worked(qsos, confirmed)) + "." + where;
        }
        case ADIFMapHit::Spot: {
            if (h.index >= mw.view.spots.size()) break;
            const ADIFMapSpot &ms = mw.view.spots[h.index];
            const adif::Spot &sp = ms.spot;
            std::string what = sp.khz + " kHz" + (sp.mode.empty() ? "" : " " + sp.mode);
            std::string ref = sp.reference.empty() ? "" : " " + trf("at {ref}", {{"ref", sp.program.empty() ? sp.reference : sp.program + " " + sp.reference}}) +
                                                        (sp.park.empty() ? "" : " (" + sp.park + ")");
            long long age = sp.epoch > 0 ? std::max<long long>(0, (long long)time(nullptr) - sp.epoch) / 60 : -1;
            std::string when = age < 0 ? "" : age == 0 ? tr("just now") : trp("{n} minute ago", "{n} minutes ago", age);
            std::string by = sp.spotter.empty() ? tr(adif::spotSourceName(sp.source))
                                                : trf("by {spotter} ({source})", {{"spotter", sp.spotter}, {"source", tr(adif::spotSourceName(sp.source))}});
            std::string log = inLog(sp);
            if (sp.heardMe)  // PSKReporter: your own signal, and the stations that heard it
                return trp("Your signal ({call}) on {what}, {when}: heard by {n} station (PSKReporter).",
                           "Your signal ({call}) on {what}, {when}: heard by {n} stations (PSKReporter).", (long long)ms.heard.size(),
                           {{"call", sp.activator}, {"what", what}, {"when", when}}) +
                       fromHome(ms.lat, ms.lon);
            std::string text = trf("{call} on {what}{ref}, spotted {when} {by}; {log}.",
                                   {{"call", sp.activator}, {"what", what}, {"ref", ref}, {"when", when}, {"by", by}, {"log", log}});
            if (sp.hasSnr) text += " " + trf("Signal report {snr}.", {{"snr", adif::spotSnr(sp)}});
            if (ms.heard.size() > 1)
                text += " " + trp("Heard by {n} spotter.", "Heard by {n} spotters.", (long long)ms.heard.size());
            if (!sp.comments.empty()) text += " \u201c" + sp.comments + "\u201d";
            return text + fromHome(ms.lat, ms.lon);
        }
        case ADIFMapHit::Spotter: {
            if (h.index >= mw.view.spotters.size()) break;
            const ADIFMapSpotter &st = mw.view.spotters[h.index];
            // The stations it heard, newest first.
            std::string list;
            for (size_t n = 0; n < st.spots.size() && n < 6; ++n) {
                const adif::Spot &sp = mw.view.spots[st.spots[n]].spot;
                list += (list.empty() ? "" : ", ") + sp.activator + " " + sp.band;
            }
            if (st.spots.size() > 6) list += ", +" + std::to_string(st.spots.size() - 6);
            std::string text = trp("{call}, a spotter: heard {n} station: {list}.", "{call}, a spotter: heard {n} stations: {list}.",
                                   (long long)st.spots.size(), {{"call", st.call}, {"list", list}});
            if (st.call.size() > 2 && st.call.compare(st.call.size() - 2, 2, "-#") == 0)
                text += " " + tr("A Reverse Beacon Network skimmer.");
            return text + fromHome(st.lat, st.lon);
        }
        case ADIFMapHit::Empty: return trf("{square}: no QSOs.", {{"square", h.square}}) + where;
        case ADIFMapHit::None: break;
    }
    return "";
}

void fillViewList();
void showListKind(int kind);

// The QSOs of what was chosen, for the list's Selected: shown there when a click on the map chose
// them, unless the list shows that kind of thing already (a park clicked while it lists parks,
// a spot while it lists spots, a contact or square while it lists contacts).
void showList(const std::vector<size_t> &qsos, ADIFMapHit::Kind kind = ADIFMapHit::None) {
    mw.listed = qsos;
    mw.listPage[0] = 0;
    NSInteger shown = mw.listKind.selectedSegment;
    bool same = (shown == 2 && kind == ADIFMapHit::Pota) || (shown == 3 && (kind == ADIFMapHit::Spot || kind == ADIFMapHit::Spotter)) ||
                (shown == 1 && (kind == ADIFMapHit::Contact || kind == ADIFMapHit::Square));
    if (!qsos.empty() && !mw.choosingFromList && !same) showListKind(0);
    else fillViewList();
}

// What a spot means for the log, in words: "new DXCC: Japan", "new band for Germany (17m)",
// "Germany worked on 40m"; and "new park" for a POTA park not hunted.
std::string spotNeedLine(const adif::SpotStatus &st, const std::string &band) {
    std::string out;
    switch (st.need) {
        case adif::SpotNeed::NewDxcc: out = trf("new DXCC: {entity}", {{"entity", st.entity}}); break;
        case adif::SpotNeed::NewBand: out = trf("new band for {entity} ({band})", {{"entity", st.entity}, {"band", band}}); break;
        case adif::SpotNeed::NewMode: out = trf("new mode on {band} for {entity}", {{"entity", st.entity}, {"band", band}}); break;
        case adif::SpotNeed::Worked: out = trf("{entity} worked on {band}, not confirmed", {{"entity", st.entity}, {"band", band}}); break;
        case adif::SpotNeed::Confirmed: out = trf("{entity} confirmed on {band}", {{"entity", st.entity}, {"band", band}}); break;
        default: break;
    }
    if (st.newPark) out += (out.empty() ? "" : "; ") + tr("new park");
    return out;
}

// The information box for a clicked spot or spotter: everything known about the station.
std::vector<ADIFInfoRow> spotInfo(const ADIFMapHit &h) {
    std::vector<ADIFInfoRow> rows;
    auto row = [&](const char *label, const std::string &value) {
        if (!value.empty()) rows.push_back({tr(label), value, false});
    };
    long long now = (long long)time(nullptr);
    const adif::CountryTable *countries = &ADIFCountries();
    auto position = [&](double lat, double lon, const std::string &from) {
        char b[64];
        snprintf(b, sizeof b, "%.2f\u00B0 %c, %.2f\u00B0 %c", std::fabs(lat), lat >= 0 ? 'N' : 'S', std::fabs(lon), lon >= 0 ? 'E' : 'W');
        std::string how = from == "grid" ? tr("from its grid") : from == "country data" ? tr("the country's, from the country data") : from == "spot" ? tr("from the spot") : "";
        row(N_("Position"), std::string(b) + (how.empty() ? "" : " (" + how + ")"));
    };
    auto country = [&](const std::string &call) {
        adif::CountryInfo ci;
        if (!countries->lookup(adif::spotterCall(call), &ci)) return;
        row(N_("Country"), ci.name + " (DXCC " + std::to_string(ci.dxcc) + ")");
        row(N_("Continent"), ci.continent);
        row(N_("Zones"), trf("CQ {cq}, ITU {itu}", {{"cq", std::to_string(ci.cq)}, {"itu", std::to_string(ci.itu)}}));
    };
    auto distance = [&](double lat, double lon) {
        double hlat, hlon;
        if (mw.home.empty() || !adif::gridToLatLon(mw.home, &hlat, &hlon)) return;
        char bearing[16];
        snprintf(bearing, sizeof bearing, "%.0f", adif::initialBearing(hlat, hlon, lat, lon));
        row(N_("Distance"), trf("{km} km at {bearing}\u00B0 from {home}", {{"km", std::to_string(std::lround(adif::greatCircleKm(hlat, hlon, lat, lon)))},
                                                                       {"bearing", bearing}, {"home", mw.home}}));
    };
    auto heard = [&](const std::string &call, bool hasSnr, int snr, long long epoch) {
        std::string s = call;
        if (hasSnr) {
            char db[16];
            snprintf(db, sizeof db, "   %+d dB", snr);
            s += db;
        }
        std::string age = adif::spotAge(epoch, now);
        return age.empty() ? s : s + "   " + age;
    };
    // A list, the first row labelled, at most 15 rows and then how many more.
    auto list = [&](const char *label, const std::vector<std::string> &items) {
        for (size_t i = 0; i < items.size() && i < 15; ++i) rows.push_back({i ? "" : tr(label), items[i], false});
        if (items.size() > 15) rows.push_back({"", trf("and {n} more", {{"n", std::to_string(items.size() - 15)}}), false});
    };
    if (h.kind == ADIFMapHit::Spot && h.index < mw.view.spots.size()) {
        const ADIFMapSpot &ms = mw.view.spots[h.index];
        const adif::Spot &sp = ms.spot;
        rows.push_back({sp.heardMe ? trf("{call}: your signal", {{"call", sp.activator}}) : sp.activator, "", true});
        row(N_("Frequency"), sp.khz.empty() ? "" : sp.khz + " kHz");
        row(N_("Band"), sp.band);
        row(N_("Mode"), sp.mode);
        std::string age = adif::spotAge(sp.epoch, now);
        if (!sp.time.empty()) row(N_("Spotted"), sp.time + " UTC" + (age.empty() ? "" : " (" + age + ")"));
        // Spothole keeps where it had the spot from (Cluster, RBN, POTA...) where POTA keeps the location.
        bool via = sp.source == adif::SpotSource::Spothole && !sp.location.empty();
        row(N_("Source"), tr(adif::spotSourceName(sp.source)) + (via ? " (" + sp.location + ")" : ""));
        std::string refs;
        for (const std::string &r : sp.refs) refs += (refs.empty() ? "" : ", ") + r;
        if (refs.empty()) refs = sp.reference;
        if (!refs.empty()) row(N_("Reference"), sp.program.empty() ? refs : sp.program + " " + refs);
        row(N_("Name"), sp.park);
        if (!via && sp.location != sp.program) row(N_("Location"), sp.location);
        row(N_("Signal report"), adif::spotSnr(sp));
        row(N_("Grid"), sp.grid);
        position(ms.lat, ms.lon, adif::spotPlace(sp, countries).from);
        country(sp.activator);
        distance(ms.lat, ms.lon);
        if (!sp.heardMe) row(N_("In this log"), inLog(sp));
        if (!sp.heardMe) row(N_("For this log"), spotNeedLine(ms.status, sp.band));
        row(N_("Comment"), sp.comments);
        std::vector<std::string> by;
        for (const ADIFSpotHeard &hd : ms.heard) by.push_back(heard(hd.call, hd.hasSnr, hd.snr, hd.epoch));
        list(N_("Heard by"), by);
    } else if (h.kind == ADIFMapHit::Spotter && h.index < mw.view.spotters.size()) {
        const ADIFMapSpotter &st = mw.view.spotters[h.index];
        rows.push_back({st.call, "", true});
        if (st.call.size() > 2 && st.call.compare(st.call.size() - 2, 2, "-#") == 0) row(N_("Station"), tr("A Reverse Beacon Network skimmer."));
        std::string grid, from = "country data";
        std::vector<std::string> items;
        for (size_t k : st.spots) {
            const ADIFMapSpot &ms = mw.view.spots[k];
            for (const ADIFSpotHeard &hd : ms.heard) {
                if (adif::spotterCall(hd.call) != adif::spotterCall(st.call)) continue;
                std::string what = ms.spot.activator + " " + ms.spot.band + (ms.spot.mode.empty() ? "" : " " + ms.spot.mode);
                items.push_back(heard(what, hd.hasSnr, hd.snr, hd.epoch));
                break;
            }
            if (grid.empty() && adif::spotterCall(ms.spot.spotter) == adif::spotterCall(st.call)) {
                grid = ms.spot.spotterGrid;
                from = adif::spotterPlace(ms.spot, countries).from;
            }
        }
        row(N_("Grid"), grid);
        position(st.lat, st.lon, from);
        country(st.call);
        distance(st.lat, st.lon);
        list(N_("Heard"), items);
    }
    return rows;
}

void showListRow(const ADIFMapHit &h);

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
    showList(qsos, h.kind);
    mw.useSpot.hidden = h.kind != ADIFMapHit::Spot;
    [mw.view setInfo:h.kind == ADIFMapHit::Spot || h.kind == ADIFMapHit::Spotter ? spotInfo(h) : std::vector<ADIFInfoRow>{}];
    mw.chosen = h.kind == ADIFMapHit::None ? "" : describe(h) + (qsos.empty() ? "" : " " + tr("Double-click a QSO to go to it in the log."));
    mw.chosenHit = h;
    showContact(h, mw.chosen.empty() ? idleStatus() : mw.chosen);
    showListRow(h);
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
    [mw.projection itemAtIndex:3].title = home ? [NSString stringWithFormat:T(@"Globe from %@"), ADIFString(mw.home)] : T(@"Globe");
    [mw.projection selectItemAtIndex:p];
    [mw.projection invalidateIntrinsicContentSize];  // as wide as its widest item, renamed or not
}

void queueViewList();
void applyParkPlaces();
void showContact(const ADIFMapHit &h, const std::string &text);

void applyStyle() {
    mw.view.style = savedStyle();
    mw.view.hiddenPrograms = hiddenPrograms();
    queueViewList();
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
    NSMenuItem *i = [menu addItemWithTitle:T(title) action:nil keyEquivalent:@""];
    i.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if (action) ADIFBlockMenuItem(i, action);
    else i.enabled = NO;
    return i;
}

void refresh();
void refreshSpots();
void fillPrograms();
void fillStyle();
adif::MapFilter savedPlaceFilter();
void updateFilterButton();

// The Other programs list: the common programs, then any other SIG in the log, each with its count.
void fillPrograms() {
    NSMenu *menu = mw.programs.menu;
    menu.autoenablesItems = NO;
    [menu removeAllItems];
    [menu addItemWithTitle:T(@"Other programs") action:nil keyEquivalent:@""];  // the pull-down's own title
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
        NSString *title = n ? [NSString stringWithFormat:@"%@: %zu", ADIFString(tr(label)), n]
                            : [NSString stringWithFormat:T(@"%@: none in this log"), ADIFString(tr(label))];
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
NSArray<NSString *> *const kPaletteTitles = @[ N(@"Standard"), N(@"Colour-blind safe"), N(@"High contrast"), N(@"Light (for printing)"), N(@"Night (red)") ];

void fillStyle() {
    if (!mw.styleWindow) return;
    ADIFMapStyle s = savedStyle();
    NSView *root = mw.styleWindow.contentView;
    for (NSString *ident in @[ @"map.style.line", @"map.style.width", @"map.style.strength", @"map.style.arcs" ])
        if (NSControl *c = (NSControl *)findView(root, ident)) c.enabled = s.paths;
    if (NSControl *c = (NSControl *)findView(root, @"map.style.rings")) c.enabled = !mw.home.empty();
    if (NSControl *c = (NSControl *)findView(root, @"map.style.sunTime")) c.enabled = s.dayNight || s.greyLine;
    if (NSControl *c = (NSControl *)findView(root, @"map.style.palette")) c.enabled = !ADIFNightMode();  // Night Mode sets it
    if (NSControl *c = (NSControl *)findView(root, @"map.style.parkOutlines")) c.enabled = !parkoutlines::all().empty();
    for (NSString *ident in @[ @"map.style.spotters", @"map.style.spotLines", @"map.style.spotMode", @"map.style.spotFreq", @"map.style.spotAge", @"map.style.spotSnr",
                               @"map.style.spotFade" ])
        if (NSControl *c = (NSControl *)findView(root, ident)) c.enabled = s[kLayerSpots].show;
}

void showStyleOptions() {
    if (!mw.styleWindow) {
        NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 560)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        p.title = T(@"Style Options");
        p.releasedWhenClosed = NO;
        p.hidesOnDeactivate = NO;
        p.floatingPanel = YES;
        p.identifier = @"map.style";
        ADIFNightTrack(p);
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
            control.toolTip = T(c.tip);
            [rows addObject:@[ c.titles ? ADIFLabel(c.title) : [NSGridCell emptyContentView], control ]];
        };
        section(N(@"Colours"));
        add({"mapPalette", @"map.style.palette", 0, kPaletteTitles, N(@"Palette:"),
             N(@"Colour-blind safe: colours that stay apart for red-green and blue-yellow colour blindness. Light: for printing. Night (red): red on "
             @"black, to keep your night vision")});
        section(N(@"Markers"));
        add({"mapMarkerSize", @"map.style.size", 1, @[ N(@"Small"), N(@"Medium##size"), N(@"Large"), N(@"Extra large") ], N(@"Size:"), nil});
        add({"mapMarkerShape", @"map.style.shape", 0, @[ N(@"By layer: dots, triangles, diamonds"), N(@"All circles"), N(@"All squares") ], N(@"Shape:"), nil});
        add({"mapContactMarker", @"map.style.contact", 0, @[ N(@"Pins"), N(@"Dots"), N(@"Crosshairs") ], N(@"Contacts:"), nil});
        section(N(@"Worked areas"));
        add({"mapSquareFill", @"map.style.fill", 0, @[ N(@"Solid##fill"), N(@"See-through"), N(@"Outlines") ], N(@"Grid squares:"), nil});
        add({"mapAreaShade", @"map.style.shade", 1, @[ N(@"Light##shade"), N(@"Medium##shade"), N(@"Strong##shade") ], N(@"Other areas:"),
             N(@"How strongly worked countries, states, counties and zones are shaded")});
        section(N(@"Lines to contacts"));
        add({"mapLineStyle", @"map.style.line", 0, @[ N(@"Solid##line"), N(@"Dashed"), N(@"Dotted") ], N(@"Line:"), nil});
        add({"mapLineWidth", @"map.style.width", 1, @[ N(@"Thin"), N(@"Medium##width"), N(@"Thick") ], N(@"Width:"), nil});
        add({"mapLineOpacity", @"map.style.strength", 1, @[ N(@"Faint"), N(@"Medium##strength"), N(@"Solid##strength") ], N(@"Strength:"),
             N(@"Each line is its contact's marker colour; this is how strongly it shows")});
        add({"mapArcs", @"map.style.arcs", 1, nil, N(@"Arch over the globe"),
             N(@"On the globe, draw each line as an arch rising over it (for looks: the true path, and the beam heading, is the straight line "
             @"you get with this off)")});
        NSUInteger secondColumn = rows.count;  // from here on, the right-hand column
        section(N(@"Spots"));
        add({"mapSpotterStyle", @"map.style.spotters", spotterStyleFallback(),
             @[ N(@"Hidden##spotters"), N(@"Faint grey"), N(@"Markers"), N(@"Markers and calls") ], N(@"Spotters:"),
             N(@"The stations that heard the spots (a cluster's spotters, RBN skimmers; for PSKReporter, you), each a triangle. Point at a "
             @"spot or a spotter for its lines")});
        add({"mapSpotLineStyle", @"map.style.spotLines", 0, @[ N(@"In the spot's colour"), N(@"Faint, in the spot's colour"), N(@"Faint grey") ],
             N(@"Lines:"),
             N(@"The lines from the spotters (the Spots layer's Overlay). The spot under the pointer always shows its lines in its own colour")});
        add({"mapSpotLabelMode", @"map.style.spotMode", 1, nil, N(@"Mode"), N(@"Under each spot's call (the Spots layer's Labels): its mode")});
        rows[rows.count - 1] = @[ ADIFLabel(N(@"Labels show:")), rows.lastObject[1] ];
        add({"mapSpotLabelFreq", @"map.style.spotFreq", 0, nil, N(@"Frequency"), N(@"Under each spot's call: its frequency in kHz")});
        add({"mapSpotLabelAge", @"map.style.spotAge", 1, nil, N(@"Time since spotted"), N(@"Under each spot's call: how long ago it was spotted")});
        add({"mapSpotLabelSnr", @"map.style.spotSnr", 1, nil, N(@"Signal report"),
             N(@"Under each spot's call: the signal report in dB, from an RBN skimmer or PSKReporter")});
        add({"mapSpotFade", @"map.style.spotFade", 1, nil, N(@"Fade older spots"),
             N(@"Spots older than 10 minutes fainter, down to half at the Spots filter's age")});
        section(N(@"POTA parks"));
        add({"mapParkOutlines", @"map.style.parkOutlines", 0, @[ N(@"Badge and outline"), N(@"Outline only") ], N(@"Parks with an outline:"),
             N(@"For the parks whose outlines you downloaded (Settings, POTA Parks, Park Outlines): a badge on the outline, or the outline "
             @"and the park's label alone once it is big enough to see (zoomed further out, the badge again)")});
        section(N(@"On the map"));
        add({"mapReference", @"map.style.reference", 1, @[ N(@"Strong##reference"), N(@"Subtle"), N(@"Faint##reference") ], N(@"Reference layers:"),
             N(@"How strongly the grid, the overlays' lines and names, and the distance rings show: subtle or faint, your QSOs, parks and "
             @"spots stand out from them")});
        add({"mapSpotlight", @"map.style.spotlight", 0, nil, N(@"Spotlight what's chosen"),
             N(@"With something clicked on the map, dim the rest of it: the chosen marker, square, area, outline or box stays clear")});
        add({"mapLegend", @"map.style.legend", 1, nil, N(@"Legend"), nil});
        add({"mapRings", @"map.style.rings", 0, nil, N(@"Distance rings from my grid"), nil});
        add({"mapDayNight", @"map.style.dayNight", 0, nil, N(@"Day and night"), N(@"The night side shaded, deeper as the sun goes further down, and the "
                                                                              @"line between day and night; the sun where it is overhead")});
        add({"mapGreyLine", @"map.style.greyLine", 0, nil, N(@"Grey line"),
             N(@"The twilight band, where the sun has set but is less than 6 degrees down (civil twilight), tinted gold: a common time for "
             @"long-distance openings")});
        add({"mapSunTime", @"map.style.sunTime", 0, @[ N(@"Now"), N(@"The selected QSO's time") ], N(@"Sun at:"),
             N(@"Draw day and night for now (updated each minute), or for the time of the QSO you clicked")});
        NSButton *reset = [NSButton buttonWithTitle:T(@"Reset to Defaults") target:nil action:nil];
        reset.identifier = @"map.style.reset";
        ADIFOnAction(reset, ^{
            for (const char *key : {"mapPalette", "mapMarkerSize", "mapMarkerShape", "mapContactMarker", "mapSquareFill", "mapAreaShade", "mapLineStyle",
                                    "mapLineWidth", "mapLineOpacity", "mapArcs", "mapLegend", "mapRings", "mapDayNight", "mapGreyLine", "mapSunTime",
                                    "mapSpotters", "mapSpotterStyle", "mapSpotLineStyle", "mapSpotLabelMode", "mapSpotLabelFreq", "mapSpotLabelAge",
                                    "mapSpotLabelSnr", "mapSpotFade", "mapParkOutlines", "mapReference", "mapSpotlight"})
                setSetting(key, "");
            [mw.styleWindow orderOut:nil];
            mw.styleWindow = nil;
            applyStyle();
            fillPrograms();
            showStyleOptions();
        });
        // Two columns side by side (markers, areas and lines; spots, parks and the map), Reset under them.
        auto makeGrid = [](NSArray *gridRows) {
            NSGridView *grid = [NSGridView gridViewWithViews:gridRows];
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
                // Fading isn't one of the label's details: a little room above it.
                if ([[grid cellAtColumnIndex:1 rowIndex:r].contentView.identifier isEqualToString:@"map.style.spotFade"])
                    [grid rowAtIndex:r].topPadding = 6;
            }
            return grid;
        };
        NSGridView *left = makeGrid([rows subarrayWithRange:NSMakeRange(0, secondColumn)]);
        NSGridView *right = makeGrid([rows subarrayWithRange:NSMakeRange(secondColumn, rows.count - secondColumn)]);
        NSBox *between = [[NSBox alloc] initWithFrame:NSZeroRect];
        between.boxType = NSBoxSeparator;
        for (NSView *v in @[ left, between, right, reset ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [p.contentView addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [left.topAnchor constraintEqualToAnchor:p.contentView.topAnchor constant:16],
            [left.leadingAnchor constraintEqualToAnchor:p.contentView.leadingAnchor constant:16],
            [between.topAnchor constraintEqualToAnchor:left.topAnchor],
            [between.bottomAnchor constraintEqualToAnchor:reset.topAnchor constant:-12],
            [between.leadingAnchor constraintEqualToAnchor:left.trailingAnchor constant:18],
            [between.widthAnchor constraintEqualToConstant:1],
            [right.topAnchor constraintEqualToAnchor:left.topAnchor],
            [right.leadingAnchor constraintEqualToAnchor:between.trailingAnchor constant:18],
            [right.trailingAnchor constraintLessThanOrEqualToAnchor:p.contentView.trailingAnchor constant:-16],
            [reset.topAnchor constraintGreaterThanOrEqualToAnchor:left.bottomAnchor constant:14],
            [reset.topAnchor constraintGreaterThanOrEqualToAnchor:right.bottomAnchor constant:14],
            [reset.trailingAnchor constraintEqualToAnchor:p.contentView.trailingAnchor constant:-16],
            [reset.bottomAnchor constraintEqualToAnchor:p.contentView.bottomAnchor constant:-16],
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
        mw.target.stringValue = TF(T(@"Log: {name}"), @{@"name" : ADIFString(documentName())});
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
            for (NSString *f in first) [p addItemWithTitle:T(f)];
            for (const std::string &i : items) [p addItemWithTitle:ADIFString(i)];
            if (keep && [p itemWithTitle:keep]) [p selectItemWithTitle:keep];
        };
        fill(mw.band, @[ N(@"All bands") ], std::vector<std::string>(bands.begin(), bands.end()));
        fill(mw.mode, @[ N(@"All modes") ], std::vector<std::string>(modes.begin(), modes.end()));
        fill(mw.dates, @[ N(@"All dates"), N(@"Last 30 days"), N(@"Last 12 months"), N(@"This year") ], std::vector<std::string>(years.rbegin(), years.rend()));
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
        mw.summary = trf("{squares} ({confirmed} confirmed), {dxcc} DXCC ({dxccConfirmed} confirmed), {parks} where the QSO has a grid, "
                         "{others} (WWFF, IOTA, SOTA... under Other programs)",
                         {{"squares", plural(mw.data.squares.size(), "grid square")}, {"confirmed", std::to_string(confirmedSquares)},
                          {"dxcc", std::to_string(mw.dxcc.size())}, {"dxccConfirmed", std::to_string(confirmedDxcc)},
                          {"parks", plural(parkRefs.size(), "POTA park")}, {"others", plural(otherRefs.size(), "other reference")}}) +
                     (mw.home.empty() ? "" : "; " + trf("home {grid}", {{"grid", mw.home}})) + ". ";
        if (mw.data.withoutGrid)
            mw.summary += trp("{n} QSO without GRIDSQUARE isn't on the squares.", "{n} QSOs without GRIDSQUARE aren't on the squares.",
                              (long long)mw.data.withoutGrid) +
                          " ";
        mw.summary += mw.data.unusedLatLon ? trf("{qsos} with an exact place (Contacts; {n} LAT/LON not used: a placeholder, or far from the QSO's grid).",
                                                 {{"qsos", plural(located, "QSO")}, {"n", std::to_string(mw.data.unusedLatLon)}})
                                           : trf("{qsos} with an exact place (Contacts).", {{"qsos", plural(located, "QSO")}});
        mw.chosen.clear();
        mw.chosenHit = ADIFMapHit();
        showContact(ADIFMapHit(), idleStatus());  // nothing chosen in the new data: the title and slots go too
        showSituation();
        mw.useSpot.hidden = YES;
        applyParkPlaces();  // home may have changed
        refreshSpots();  // the band, mode and place filters apply to spots too
    } catch (...) {
    }
}

// A QSO's record in the log (an index into data.qsos).
void goToQso(size_t qi) {
    if (qi >= mw.data.qsos.size()) return;
    const adif::MapQso &q = mw.data.qsos[qi];
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
    setStatus("Saved " + ADIFStd(ADIFString(path).lastPathComponent) + ".");
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
    mw.moreFilters.title = n ? [NSString stringWithFormat:T(@"More Filters (%zu)..."), n] : T(@"More Filters...");
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
    [menu addItemWithTitle:chosen.empty() ? T(@"Any region") : TP(@"{n} region", @"{n} regions", (long long)chosen.size())
                    action:nil
             keyEquivalent:@""];
    std::string kind;
    for (const adif::UsRegion &r : adif::usRegions()) {
        if (r.kind != kind) {
            kind = r.kind;
            [menu addItem:[NSMenuItem separatorItem]];
            NSMenuItem *head = [menu addItemWithTitle:ADIFString(tr(kind)) action:nil keyEquivalent:@""];
            head.enabled = NO;
        }
        NSMenuItem *item = [menu addItemWithTitle:ADIFString(tr(r.name)) action:nil keyEquivalent:@""];
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
            t.placeholderString = T(placeholder);
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
        mw.dxccTokens = tokenField(@"map.filter.dxcc", N(@"Countries (DXCC), e.g. Italy, Canada"), dxccNames, @";");
        mw.stateTokens = tokenField(@"map.filter.states", N(@"US states, e.g. WI, IL"), states, @", ");
        mw.countyTokens = tokenField(@"map.filter.counties", N(@"US counties, e.g. WI,Dane; WI,Milwaukee"), counties, @";");
        mw.potaTokens = tokenField(@"map.filter.pota", N(@"POTA locations, e.g. US-WI, CA-ON"), locations, @", ");
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
        mw.cqField = zoneField(@"map.filter.cq", N(@"e.g. 3, 4, 5"));
        mw.ituField = zoneField(@"map.filter.itu", N(@"e.g. 6, 7, 8"));
        NSStackView *zones = [NSStackView stackViewWithViews:@[ mw.cqField, ADIFLabel(@"ITU zones:"), mw.ituField ]];
        zones.spacing = 8;
        mw.regions = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
        mw.regions.identifier = @"map.filter.regions";
        mw.regions.toolTip = T(@"US call areas, Census regions and divisions, ARRL divisions (California, New York and New Jersey count for an ARRL "
                             @"division by the QSO's ARRL_SECT)");
        mw.parksToo = ADIFCheckbox(@"Also limit the POTA parks you haven't worked", false);
        mw.parksToo.identifier = @"map.filter.parks";
        mw.parksToo.toolTip = T(@"The POTA layer's Overlay shows only the parks in these places (their location, state, region, country and continent)");
        ADIFOnAction(mw.parksToo, ^{ placeFiltersChanged(); });
        NSButton *clear = [NSButton buttonWithTitle:T(@"Clear Places") target:nil action:nil];
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
        NSTextField *help = [NSTextField wrappingLabelWithString:T(@"Keep only the QSOs in these places: within a line any of its values, "
                                                                 @"and every line that has values. Changes apply as you make them.")];
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
            // The grid sets the width (its labels are longer in some languages); the help wraps to it.
            [help.widthAnchor constraintEqualToAnchor:grid.widthAnchor],
            [grid.widthAnchor constraintGreaterThanOrEqualToConstant:500],
            [grid.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:10],
            [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [grid.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [grid.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        ]];
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = content;
        mw.filterPopover = [[NSPopover alloc] init];
        mw.filterPopover.contentViewController = vc;
        ADIFNightTrackPopover(mw.filterPopover);
        mw.filterPopover.behavior = NSPopoverBehaviorTransient;
    }
    fillPlaceControls();
    [mw.filterPopover showRelativeToRect:mw.moreFilters.bounds ofView:mw.moreFilters preferredEdge:NSRectEdgeMaxY];
}

// ── Spots ──

const long long kSpotAges[] = {600, 1800, 3600};
const char *const kSpotAgeTitles[] = {N_("10 minutes"), N_("30 minutes"), N_("1 hour")};
const adif::SpotSource kSpotSources[] = {adif::SpotSource::Spothole, adif::SpotSource::Cluster, adif::SpotSource::PskReporter};

// The Spots filter: the Map's band, mode and places, and the popover's age, sources and program.
adif::SpotFilter spotFilter() {
    adif::SpotFilter f;
    adif::MapFilter places = savedPlaceFilter();
    f.map.continents = places.continents, f.map.dxcc = places.dxcc, f.map.cq = places.cq, f.map.itu = places.itu, f.map.states = places.states,
    f.map.counties = places.counties, f.map.regions = places.regions, f.map.potaLocations = places.potaLocations;
    f.map.band = mw.band.indexOfSelectedItem > 0 ? ADIFStd(mw.band.titleOfSelectedItem) : "";
    f.map.mode = mw.mode.indexOfSelectedItem > 0 ? ADIFStd(mw.mode.titleOfSelectedItem) : "";
    f.maxAge = kSpotAges[number("mapSpotsAge", 1, 2)];
    std::string hidden = setting("mapSpotsHidden");  // the sources unticked: "Cluster,PSKReporter"
    for (adif::SpotSource src : kSpotSources)
        if (hidden.find(adif::spotSourceName(src)) == std::string::npos) f.sources.insert(src);
    std::string program = setting("mapSpotsProgram");
    if (program == "-") f.programs = {""};
    else if (!program.empty()) f.programs = {program};
    if (flag("mapSpotsOnly", false)) {  // one station's spots: who heard it
        std::string call = setting("mapSpotsOnlyCall");
        f.onlyCall = call.empty() ? setting("stationCall") : call;
    }
    return f;
}

void fillSpotsPopover() {
    if (!mw.spotsPopover) return;
    spotfeeds::Config c = spotfeeds::config();
    bool on[] = {c.spothole, c.cluster, c.psk};
    std::string hidden = setting("mapSpotsHidden");
    for (size_t i = 0; i < 3; ++i) {
        mw.spotSource[i].enabled = on[i];
        mw.spotSource[i].state = on[i] && hidden.find(adif::spotSourceName(kSpotSources[i])) == std::string::npos ? NSControlStateValueOn
                                                                                                                   : NSControlStateValueOff;
    }
    [mw.spotAge selectItemAtIndex:number("mapSpotsAge", 1, 2)];
    // The programs in the spots now, after All and plain DX.
    std::set<std::string> programs;
    for (const adif::Spot &sp : spotfeeds::spots().spots())
        if (!sp.program.empty()) programs.insert(sp.program);
    std::string chosen = setting("mapSpotsProgram");
    if (!chosen.empty() && chosen != "-") programs.insert(chosen);
    [mw.spotProgram removeAllItems];
    [mw.spotProgram addItemWithTitle:T(@"All programs")];
    [mw.spotProgram addItemWithTitle:T(@"Plain DX spots")];
    for (const std::string &p : programs) [mw.spotProgram addItemWithTitle:ADIFString(p)];
    if (chosen == "-") [mw.spotProgram selectItemAtIndex:1];
    else if (!chosen.empty()) [mw.spotProgram selectItemWithTitle:ADIFString(chosen)];
    std::string st = spotfeeds::status();
    if (!c.spothole && !c.cluster && !c.psk) st = tr("No spot source is turned on: choose them in Settings (Spots).");
    else if (st.empty()) st = tr("Tick Show under Spots to fetch them.");
    else
        st = trp("{n} station on the map, from {all} spots.", "{n} stations on the map, from {all} spots.", (long long)mw.view.spots.size(),
                 {{"all", std::to_string(spotfeeds::spots().spots().size())}}) +
             "\n" + st;
    mw.spotStatus.stringValue = ADIFString(st);
}

// The spots to mark: the feeds' list through the filters, one per station and band, where each is.
void refreshSpots() {
    if (!mw.window) return;
    ADIFMapStyle st = mw.view.style;
    bool show = st[kLayerSpots].show;
    spotfeeds::setHomeGrid(mw.home);
    spotfeeds::setFocusCall(spotFilter().onlyCall);
    spotfeeds::setWanted(show && mw.window.visible);
    std::vector<ADIFMapSpot> marks;
    long long now = (long long)time(nullptr);
    adif::SpotFilter f = spotFilter();
    if (show) {
        const adif::CountryTable *countries = &ADIFCountries();
        const adif::PotaParks *parks = ADIFPotaParks().size() ? &ADIFPotaParks() : nullptr;
        std::vector<adif::Spot> keep;
        for (const adif::Spot &sp : spotfeeds::spots().spots())
            if (adif::spotMatches(f, sp, now, countries, parks)) keep.push_back(sp);
        // Every spot of a station on a band, newest first: who heard it.
        std::map<std::string, std::vector<const adif::Spot *>> byStation;
        for (const adif::Spot &sp : keep) byStation[adif::spotterCall(sp.activator) + "|" + sp.band].push_back(&sp);
        for (auto &kv : byStation)
            std::stable_sort(kv.second.begin(), kv.second.end(), [](const adif::Spot *a, const adif::Spot *b) { return a->epoch > b->epoch; });
        for (adif::Spot &sp : adif::latestPerStation(keep)) {
            adif::SpotPlace at = adif::spotPlace(sp, countries);
            if (!at.ok) continue;
            ADIFMapSpot m;
            m.lat = at.lat, m.lon = at.lon, m.exact = at.exact;
            std::set<std::string> seen;
            // Up to 12 spotters a station; your own signal (PSKReporter) keeps up to 100: who heard you.
            size_t most = sp.heardMe || !f.onlyCall.empty() ? 100 : 12;
            for (const adif::Spot *by : byStation[adif::spotterCall(sp.activator) + "|" + sp.band]) {
                if (m.heard.size() >= most) break;
                if (by->spotter.empty() || !seen.insert(adif::spotterCall(by->spotter)).second) continue;
                adif::SpotPlace from = adif::spotterPlace(*by, countries);
                if (!from.ok) continue;
                ADIFSpotHeard h;
                h.call = by->spotter, h.lat = from.lat, h.lon = from.lon, h.epoch = by->epoch, h.source = by->source;
                h.hasSnr = by->hasSnr, h.snr = by->snr;
                m.heard.push_back(h);
            }
            m.spot = std::move(sp);
            marks.push_back(std::move(m));
        }
    }
    [mw.view setSpots:marks now:now maxAge:f.maxAge];
    queueViewList();
    showSituation();
    mw.refreshSpotsButton.enabled = show;
    // The information box follows the chosen spot or spotter (its age, who else heard it), or goes with it.
    ADIFMapHit chosen = mw.view.selectedHit;
    if (chosen.kind == ADIFMapHit::Spot || chosen.kind == ADIFMapHit::Spotter) [mw.view setInfo:spotInfo(chosen)];
    else if (!mw.view.info.empty()) [mw.view setInfo:std::vector<ADIFInfoRow>()];
    fillSpotsPopover();
}

void useSelectedSpot() {
    ADIFMapHit h = mw.view.selectedHit;
    if (h.kind != ADIFMapHit::Spot || h.index >= mw.view.spots.size() || !mw.spotHandler) return;
    const adif::Spot &sp = mw.view.spots[h.index].spot;
    mw.spotHandler(adif::spotQsoFields(sp));
    setStatus(trf("Copied {call} ({khz} kHz {mode}) to New QSO.", {{"call", sp.activator}, {"khz", sp.khz}, {"mode", sp.mode}}));
}

void showSpotsPopover() {
    if (!mw.spotsPopover) {
        NSTextField *help = [NSTextField wrappingLabelWithString:T(@"The spots the Spots layer shows. Where they come from is set in Settings (Spots); "
                                                                 @"the Map's band, mode and place filters apply to them too.")];
        help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        help.textColor = NSColor.secondaryLabelColor;
        mw.spotAge = ADIFPopup(@[ @(kSpotAgeTitles[0]), @(kSpotAgeTitles[1]), @(kSpotAgeTitles[2]) ]);
        mw.spotAge.identifier = @"map.spots.age";
        ADIFOnAction(mw.spotAge, ^{
            setSetting("mapSpotsAge", std::to_string(mw.spotAge.indexOfSelectedItem));
            refreshSpots();
        });
        NSMutableArray *sources = [NSMutableArray array];
        for (size_t i = 0; i < 3; ++i) {
            mw.spotSource[i] = ADIFCheckbox(@(adif::spotSourceName(kSpotSources[i])), true);
            mw.spotSource[i].identifier = [NSString stringWithFormat:@"map.spots.source.%zu", i];
            ADIFOnAction(mw.spotSource[i], ^{
                std::string hidden;
                for (size_t k = 0; k < 3; ++k)
                    if (mw.spotSource[k].enabled && mw.spotSource[k].state != NSControlStateValueOn)
                        hidden += (hidden.empty() ? "" : ",") + std::string(adif::spotSourceName(kSpotSources[k]));
                setSetting("mapSpotsHidden", hidden);
                refreshSpots();
            });
            [sources addObject:mw.spotSource[i]];
        }
        NSStackView *sourceRow = [NSStackView stackViewWithViews:sources];
        sourceRow.spacing = 12;
        mw.spotProgram = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        mw.spotProgram.identifier = @"map.spots.program";
        ADIFOnAction(mw.spotProgram, ^{
            NSInteger i = mw.spotProgram.indexOfSelectedItem;
            setSetting("mapSpotsProgram", i <= 0 ? "" : i == 1 ? "-" : ADIFStd(mw.spotProgram.titleOfSelectedItem));
            refreshSpots();
        });
        mw.spotStatus = [NSTextField wrappingLabelWithString:@""];
        mw.spotStatus.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.spotStatus.textColor = NSColor.secondaryLabelColor;
        mw.spotStatus.identifier = @"map.spots.status";
        NSButton *settings = [NSButton buttonWithTitle:T(@"Settings...") target:nil action:nil];
        ADIFOnAction(settings, ^{ openSettings(-4); });
        NSGridView *grid = [NSGridView gridViewWithViews:@[
            @[ ADIFLabel(@"Newer than:"), mw.spotAge ], @[ ADIFLabel(@"From:"), sourceRow ], @[ ADIFLabel(@"Program:"), mw.spotProgram ],
            @[ [NSGridCell emptyContentView], settings ]
        ]];
        grid.rowSpacing = 8;
        grid.columnSpacing = 10;
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
        NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
        content.identifier = @"map.spots";
        for (NSView *v in @[ help, grid, mw.spotStatus ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [content addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [help.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
            [help.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [help.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [help.widthAnchor constraintEqualToAnchor:grid.widthAnchor],
            [grid.widthAnchor constraintGreaterThanOrEqualToConstant:420],
            [grid.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:10],
            [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [mw.spotStatus.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:10],
            [mw.spotStatus.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [mw.spotStatus.widthAnchor constraintEqualToAnchor:grid.widthAnchor],
            [mw.spotStatus.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        ]];
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = content;
        mw.spotsPopover = [[NSPopover alloc] init];
        mw.spotsPopover.contentViewController = vc;
        ADIFNightTrackPopover(mw.spotsPopover);
        mw.spotsPopover.behavior = NSPopoverBehaviorTransient;
    }
    fillSpotsPopover();
    [mw.spotsPopover showRelativeToRect:mw.spotsButton.bounds ofView:mw.spotsButton preferredEdge:NSRectEdgeMaxY];
}

// A Labels box works while its layer shows (outlined, or its worked areas).
void labelsFollow() {
    for (const LayerUi &l : kLayerUi)
        mw.labels[l.id].enabled = mw.overlay[l.id].state == NSControlStateValueOn || (mw.show[l.id] && mw.show[l.id].state == NSControlStateValueOn);
}

// A layer's box changed (0 Show, 1 Overlay, 2 Labels). Ticking Show turns that layer's Overlay
// and Labels on too: the worked areas among all of them, named.
void layerChanged(MapLayerId id, int which) {
    if (which == 0 && mw.show[id].state == NSControlStateValueOn) {
        if (id != kLayerSpots) mw.overlay[id].state = NSControlStateValueOn;  // spots: lines from the spotters only when asked
        mw.labels[id].state = NSControlStateValueOn;
    }
    for (const LayerUi &l : kLayerUi) {
        if (l.showKey) saveFlag(l.showKey, mw.show[l.id].state == NSControlStateValueOn);
        saveFlag(l.overlayKey, mw.overlay[l.id].state == NSControlStateValueOn);
        saveFlag(l.labelsKey, mw.labels[l.id].state == NSControlStateValueOn);
    }
    labelsFollow();
    applyStyle();
    fillStyle();
    if (id == kLayerSpots) refreshSpots();
    bool on = which != 2 && (which == 0 ? mw.show[id] : mw.overlay[id]).state == NSControlStateValueOn;
    if (on && id == kLayerIota && ADIFIotaGroups().empty()) setStatus("IOTA: download IOTA's group list first, in Settings (IOTA Groups).");
    if (on && id == kLayerPota && !ADIFPotaParks().size())
        setStatus("POTA: download POTA's park list first, in Settings (POTA Parks). Until then, the parks you hunted show at the QSO's grid.");
}

// ── POTA parks in: the park filter ──

// The location of your station (home), for the filter to start at: its US state, else the
// nearest park's location; "" without home or the park list.
std::string homeParkLocation() {
    double lat, lon;
    if (mw.home.empty() || !adif::gridToLatLon(mw.home, &lat, &lon) || !ADIFPotaParks().size()) return "";
    return adif::parkLocationAt(ADIFPotaParks(), lat, lon);
}

// The places chosen (mapParkPlaces: unset, your station's location; "*" everywhere; else the
// locations) and their US counties (mapParkCounties).
adif::ParkPlaces parkPlaces() {
    adif::ParkPlaces places;
    std::string chosen = setting("mapParkPlaces");
    if (chosen.empty()) {
        if (std::string home = homeParkLocation(); !home.empty()) places.locations.insert(home);
    } else if (chosen != "*") {
        for (const std::string &l : splitSetting("mapParkPlaces", ',')) places.locations.insert(l);
    }
    for (const std::string &c : splitSetting("mapParkCounties", ';'))
        if (std::string key = adif::countyKey(c); !key.empty()) places.counties.insert(key);
    return places;
}

// "US-IL", "US-IL, US-WI", "4 locations", with "2 counties"; "everywhere".
std::string parkPlacesName(const adif::ParkPlaces &places) {
    std::string name;
    if (places.locations.size() > 2) name = plural(places.locations.size(), "location");
    else
        for (const std::string &l : places.locations) name += (name.empty() ? "" : ", ") + l;
    if (!places.counties.empty()) {
        std::string counties = trp("{n} county", "{n} counties", (long long)places.counties.size());
        name = name.empty() ? counties : name + ", " + counties;
    }
    return name.empty() ? tr("everywhere") : name;
}

void queueViewList();

// The filter applied: the map, its button, the list.
void applyParkPlaces() {
    if (!mw.view) return;
    adif::ParkPlaces places = parkPlaces();
    std::string name = parkPlacesName(places);
    [mw.view setParkPlaces:places named:places.any() ? name : ""];
    mw.parkPlacesButton.title = [ADIFString(name) stringByAppendingString:@"…"];
    queueViewList();
}

// The popover's fields from the settings; the counties offered are those of the US states chosen
// (all of them when none is).
void fillParkPlaces() {
    adif::ParkPlaces places = parkPlaces();
    NSMutableArray *locs = [NSMutableArray array], *counties = [NSMutableArray array];
    for (const std::string &l : places.locations) [locs addObject:ADIFString(l)];
    for (const std::string &c : splitSetting("mapParkCounties", ';')) [counties addObject:ADIFString(c)];
    mw.parkLocations.objectValue = locs;
    mw.parkCounties.objectValue = counties;
    std::set<std::string> states;
    for (const std::string &l : places.locations)
        if (l.size() == 5 && l.compare(0, 3, "US-") == 0) states.insert(l.substr(3) + ",");
    NSMutableArray *offer = [NSMutableArray array];
    const adif::AreaIndex &co = adif::areaIndex(adif::Overlay::UsCounties);
    for (size_t i = 0; i < co.size(); ++i) {
        const std::string &n = co.area(i).name;
        if (states.empty() || states.count(n.substr(0, n.find(',') + 1))) [offer addObject:ADIFString(n)];
    }
    mw.countyCompleter.candidates = offer;
    std::string home = homeParkLocation();
    mw.parkHome.title = home.empty() ? T(@"Your Station's") : TF(@"Your Station's ({location})", @{@"location" : ADIFString(home)});
    mw.parkHome.enabled = !home.empty();
}

// The fields changed: kept (no locations: everywhere), and applied.
void parkPlacesChanged() {
    std::vector<std::string> locs;
    for (std::string l : tokens(mw.parkLocations)) {
        for (char &c : l) c = (char)toupper((unsigned char)c);
        locs.push_back(l);
    }
    if (locs.empty()) setSetting("mapParkPlaces", "*");
    else saveSetting("mapParkPlaces", locs, ',');
    saveSetting("mapParkCounties", tokens(mw.parkCounties), ';');
    fillParkPlaces();
    applyParkPlaces();
}

void showParkPlaces() {
    if (!mw.parkPlacesPopover) {
        NSMutableArray *locations = [NSMutableArray array];
        for (const std::string &l : parkoutlines::locations()) [locations addObject:ADIFString(l)];
        auto field = [](NSString *ident, NSString *placeholder, NSString *separators, ADIFTokenCompleter *c) {
            NSTokenField *t = [[NSTokenField alloc] initWithFrame:NSMakeRect(0, 0, 340, 24)];
            t.identifier = ident;
            t.placeholderString = T(placeholder);
            t.tokenizingCharacterSet = [NSCharacterSet characterSetWithCharactersInString:separators];
            t.delegate = c;
            [t.widthAnchor constraintEqualToConstant:340].active = YES;
            ADIFOnAction(t, ^{ parkPlacesChanged(); });
            return t;
        };
        ADIFTokenCompleter *locs = [[ADIFTokenCompleter alloc] init];
        locs.candidates = locations;
        mw.countyCompleter = [[ADIFTokenCompleter alloc] init];
        if (!mw.completers) mw.completers = [NSMutableArray array];
        [mw.completers addObjectsFromArray:@[ locs, mw.countyCompleter ]];
        mw.parkLocations = field(@"map.parkplaces.locations", N(@"POTA locations, e.g. US-IL, CA-ON, VK-NSW"), @", ", locs);
        mw.parkCounties = field(@"map.parkplaces.counties", N(@"US counties, e.g. IL,Cook; IL,DuPage"), @";", mw.countyCompleter);
        mw.parkHome = [NSButton buttonWithTitle:T(@"Your Station's") target:nil action:nil];
        mw.parkHome.identifier = @"map.parkplaces.home";
        mw.parkHome.toolTip = T(@"Your station's location (Settings, Your Station's grid), and no counties; it follows your grid if it changes");
        ADIFOnAction(mw.parkHome, ^{
            setSetting("mapParkPlaces", "");
            setSetting("mapParkCounties", "");
            fillParkPlaces();
            applyParkPlaces();
        });
        NSButton *all = [NSButton buttonWithTitle:T(@"Everywhere") target:nil action:nil];
        all.identifier = @"map.parkplaces.all";
        ADIFOnAction(all, ^{
            setSetting("mapParkPlaces", "*");
            setSetting("mapParkCounties", "");
            fillParkPlaces();
            applyParkPlaces();
        });
        NSStackView *buttons = [NSStackView stackViewWithViews:@[ mw.parkHome, all ]];
        buttons.spacing = 8;
        NSGridView *grid = [NSGridView gridViewWithViews:@[
            @[ ADIFLabel(@"Locations:"), mw.parkLocations ], @[ ADIFLabel(@"US counties:"), mw.parkCounties ],
            @[ [NSGridCell emptyContentView], buttons ]
        ]];
        grid.rowSpacing = 8;
        grid.columnSpacing = 10;
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
        grid.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *help = [NSTextField
            wrappingLabelWithString:T(@"Fewer POTA parks you haven't worked, on the map and in the list beside it: only those in these POTA "
                                      @"locations (US states, Canadian provinces, other countries' regions, as POTA names them) and, in a US "
                                      @"state, these counties. It starts at your station's location; the parks you worked always show.")];
        help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        help.textColor = NSColor.secondaryLabelColor;
        help.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
        content.identifier = @"map.parkplaces";
        [content addSubview:help];
        [content addSubview:grid];
        [NSLayoutConstraint activateConstraints:@[
            [help.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
            [help.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [help.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [help.widthAnchor constraintEqualToAnchor:grid.widthAnchor],
            [grid.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:10],
            [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [grid.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [grid.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        ]];
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = content;
        mw.parkPlacesPopover = [[NSPopover alloc] init];
        mw.parkPlacesPopover.contentViewController = vc;
        ADIFNightTrackPopover(mw.parkPlacesPopover);
        mw.parkPlacesPopover.behavior = NSPopoverBehaviorTransient;
    }
    fillParkPlaces();
    [mw.parkPlacesPopover showRelativeToRect:mw.parkPlacesButton.bounds ofView:mw.parkPlacesButton preferredEdge:NSRectEdgeMaxY];
}

// ── The list beside the map: the QSOs chosen; the contacts, parks or spots in view ──

enum ListKind { kListSelected, kListContacts, kListParks, kListSpots };

// A column the list can show: its id, title, width, style (0 text, 1 digits, 2 digits on the
// right), whether it shows at first, and whether it sorts as a number.
struct ListColumn {
    const char *id, *title;
    CGFloat width;
    int style;
    bool on, number;
};

const std::vector<ListColumn> &listColumns(int kind) {
    static const std::vector<ListColumn> kSelected = {
        {"record", N_("Record"), 66, 2, true, true},      {"call", N_("Call"), 76, 0, true, false},     {"date", N_("Date"), 76, 1, true, false},
        {"time", "UTC", 44, 1, true, false},               {"band", N_("Band"), 42, 1, true, false},     {"mode", N_("Mode"), 46, 0, true, false},
        {"grid", N_("Grid"), 62, 0, true, false},          {"confirmed", N_("Confirmed"), 68, 0, true, false},
        {"country", N_("Country"), 120, 0, false, false},  {"state", N_("State"), 42, 0, false, false},  {"county", N_("County"), 100, 0, false, false},
        {"cq", "CQ", 32, 2, false, true},                  {"itu", "ITU", 32, 2, false, true},           {"park", N_("Park"), 76, 0, false, false},
        {"distance", N_("Distance"), 64, 2, false, true},  {"bearing", N_("Bearing"), 54, 2, false, true},
    };
    static const std::vector<ListColumn> kContacts = [] {
        std::vector<ListColumn> c = kSelected;
        for (ListColumn &col : c) {
            std::string id = col.id;
            col.on = id == "call" || id == "date" || id == "band" || id == "mode" || id == "distance" || id == "bearing";
        }
        return c;
    }();
    static const std::vector<ListColumn> kParks = {
        {"ref", N_("Reference"), 72, 1, true, false},     {"name", N_("Park"), 170, 0, true, false},     {"location", N_("Location"), 80, 0, false, false},
        {"worked", N_("Worked"), 110, 0, false, false},   {"outline", N_("Outline"), 70, 0, false, false}, {"grid", N_("Grid"), 62, 0, false, false},
        {"distance", N_("Distance"), 64, 2, true, true},  {"bearing", N_("Bearing"), 54, 2, true, true},
    };
    static const std::vector<ListColumn> kSpots = {
        {"call", N_("Call"), 76, 0, true, false},          {"khz", "kHz", 60, 2, true, true},             {"band", N_("Band"), 42, 1, false, false},
        {"mode", N_("Mode"), 46, 0, true, false},          {"need", N_("For this log"), 90, 0, true, false}, {"age", N_("Age"), 52, 2, true, true},
        {"time", "UTC", 44, 1, false, false},              {"program", N_("Program"), 60, 0, false, false}, {"ref", N_("Reference"), 76, 0, false, false},
        {"park", N_("Park"), 140, 0, false, false},        {"spotter", N_("Spotter"), 76, 0, false, false}, {"source", N_("Source"), 80, 0, false, false},
        {"snr", "SNR", 44, 2, false, true},                {"grid", N_("Grid"), 62, 0, false, false},     {"country", N_("Country"), 120, 0, false, false},
        {"comment", N_("Comment"), 160, 0, false, false},  {"distance", N_("Distance"), 64, 2, true, true}, {"bearing", N_("Bearing"), 54, 2, false, true},
    };
    switch (kind) {
        case kListSelected: return kSelected;
        case kListContacts: return kContacts;
        case kListParks: return kParks;
        default: return kSpots;
    }
}

const ListColumn *listColumn(int kind, const std::string &id) {
    for (const ListColumn &c : listColumns(kind))
        if (id == c.id) return &c;
    return nullptr;
}

std::string listKey(const char *what, int kind) { return std::string(what) + std::to_string(kind); }

// The columns shown, in order, with their widths: as last left (mapListColumns<kind>:
// "call:76,date:76"), else the kind's own.
std::vector<std::pair<std::string, CGFloat>> shownColumns(int kind) {
    std::vector<std::pair<std::string, CGFloat>> out;
    for (const std::string &item : splitSetting(listKey("mapListColumns", kind).c_str(), ',')) {
        std::string id = item.substr(0, item.find(':'));
        const ListColumn *c = listColumn(kind, id);
        if (!c) continue;
        CGFloat width = item.find(':') == std::string::npos ? c->width : std::atof(item.c_str() + item.find(':') + 1);
        out.emplace_back(id, std::clamp(width, (CGFloat)24, (CGFloat)600));
    }
    if (out.empty())
        for (const ListColumn &c : listColumns(kind))
            if (c.on) out.emplace_back(c.id, c.width);
    return out;
}

// The sort chosen (mapListSort<kind>: "distance", "-date"), else the kind's: log order for the
// QSOs chosen, nearest first for the rest.
std::pair<std::string, bool> listSort(int kind) {
    std::string v = setting(listKey("mapListSort", kind).c_str());
    bool ascending = v.empty() || v[0] != '-';
    std::string id = ascending ? v : v.substr(1);
    if (!listColumn(kind, id)) id = kind == kListSelected ? "record" : "distance", ascending = true;
    return {id, ascending};
}

// The table's columns for a kind: the colour mark, then those shown.
void setListColumns(int kind, bool force = false) {
    if (mw.listColumnsFor == kind && !force) return;
    mw.listColumnsFor = kind;
    mw.listRows.building = YES;
    while (mw.listTable.tableColumns.count) [mw.listTable removeTableColumn:mw.listTable.tableColumns.lastObject];
    NSTableColumn *mark = [[NSTableColumn alloc] initWithIdentifier:@"mark"];
    mark.title = @"";
    mark.width = mark.minWidth = 14;
    mark.resizingMask = NSTableColumnNoResizing;
    [mw.listTable addTableColumn:mark];
    std::map<std::string, int> styles;
    for (const auto &shown : shownColumns(kind)) {
        const std::string &id = shown.first;
        CGFloat width = shown.second;
        const ListColumn *c = listColumn(kind, id);
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ADIFString(id)];
        col.title = *c->title ? @(tr(c->title).c_str()) : @"";
        col.width = width;
        col.minWidth = 24;
        col.resizingMask = NSTableColumnUserResizingMask;
        col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:ADIFString(id) ascending:c->style != 2 || id == "distance"];
        if (c->style == 2) col.headerCell.alignment = NSTextAlignmentRight;
        [mw.listTable addTableColumn:col];
        styles[id] = c->style;
    }
    mw.listRows.styles = styles;
    auto [sortId, ascending] = listSort(kind);
    mw.listTable.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:ADIFString(sortId) ascending:ascending] ];
    mw.listRows.building = NO;
}

// The columns as the user left them (order and widths), kept for the kind.
void saveListColumns() {
    std::vector<std::string> items;
    for (NSTableColumn *col in mw.listTable.tableColumns)
        if (![col.identifier isEqualToString:@"mark"]) items.push_back(ADIFStd(col.identifier) + ":" + std::to_string((int)std::lround(col.width)));
    saveSetting(listKey("mapListColumns", mw.listColumnsFor).c_str(), items, ',');
}

// The columns menu (the header's, and the Columns button's): a column each, ticked when shown;
// choosing one shows or hides it; Reset Columns goes back to the kind's own.
void fillColumnsMenu(NSMenu *menu, bool pullDown) {
    [menu removeAllItems];
    if (pullDown) [menu addItemWithTitle:T(@"Columns") action:nil keyEquivalent:@""];  // the pull-down's own title
    int kind = mw.listColumnsFor < 0 ? 0 : mw.listColumnsFor;
    std::set<std::string> shown;
    for (const auto &c : shownColumns(kind)) shown.insert(c.first);
    for (const ListColumn &c : listColumns(kind)) {
        NSMenuItem *item = [menu addItemWithTitle:@(tr(c.title).c_str()) action:nil keyEquivalent:@""];
        item.state = shown.count(c.id) ? NSControlStateValueOn : NSControlStateValueOff;
        std::string id = c.id;
        ADIFBlockMenuItem(item, ^{
            std::vector<std::pair<std::string, CGFloat>> cols = shownColumns(kind);
            auto it = std::find_if(cols.begin(), cols.end(), [&](const auto &p) { return p.first == id; });
            if (it != cols.end()) {
                if (cols.size() > 1) cols.erase(it);  // the last one stays
            } else {
                cols.emplace_back(id, listColumn(kind, id)->width);
            }
            std::vector<std::string> items;
            for (const auto &[cid, w] : cols) items.push_back(cid + ":" + std::to_string((int)std::lround(w)));
            saveSetting(listKey("mapListColumns", kind).c_str(), items, ',');
            setListColumns(kind, true);
            fillViewList();
        });
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *reset = [menu addItemWithTitle:T(@"Reset Columns") action:nil keyEquivalent:@""];
    ADIFBlockMenuItem(reset, ^{
        setSetting(listKey("mapListColumns", kind).c_str(), "");
        setSetting(listKey("mapListSort", kind).c_str(), "");
        setListColumns(kind, true);
        fillViewList();
    });
}

// Where the list measures from: your station (home), the map's centre, or a grid square typed.
// False when there's no such place (no home, a grid that isn't one): then the map's centre.
bool listFromPlace(double *lat, double *lon, std::string *from) {
    NSInteger choice = mw.listFrom.indexOfSelectedItem;
    if (choice == 0 && !mw.home.empty() && adif::gridToLatLon(mw.home, lat, lon)) return *from = mw.home, true;
    std::string grid = ADIFStd([mw.listGrid.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
    if (choice == 2 && adif::gridToLatLon(grid, lat, lon)) return *from = grid, true;
    NSRect b = mw.view.bounds;
    double clon = 0, clat = 0;
    if (![mw.view lonLatAt:NSMakePoint(NSMidX(b), NSMidY(b)) lon:&clon lat:&clat]) clon = clat = 0;
    *lat = clat, *lon = clon, *from = adif::squareAt(clon, clat);
    return choice == 1;
}

bool inView(double lat, double lon) { return NSPointInRect([mw.view viewPointForLon:lon lat:lat], mw.view.bounds); }

// A QSO's place: LAT/LON, else its GRIDSQUARE.
bool qsoPlace(const adif::MapQso &q, double *lat, double *lon) {
    if (q.located) return *lat = q.lat, *lon = q.lon, true;
    return adif::gridToLatLon(q.grid, lat, lon);
}

// The rows for QSOs: the ones chosen (Selected: none of them chosen on the map by a row), or
// those whose place is in view (Contacts: a row chooses its marker, with Contacts, else its
// square). Each with its distance and bearing when it has a place.
std::vector<ADIFViewRow> qsoRows(int kind, double lat, double lon) {
    std::map<size_t, size_t> contactOf;  // QSO -> its marker in the view's contacts
    const std::vector<ADIFMapContact> &contacts = mw.view.contacts;
    for (size_t j = 0; j < contacts.size(); ++j)
        for (size_t qi : contacts[j].qsos) contactOf[qi] = j;
    std::map<std::string, size_t> squareOf;
    for (size_t s = 0; s < mw.data.squares.size(); ++s) squareOf[mw.data.squares[s].grid] = s;
    std::vector<size_t> qsos;
    if (kind == kListSelected) qsos = mw.listed;
    else
        for (size_t i = 0; i < mw.data.qsos.size(); ++i) {
            double a, o;
            if (qsoPlace(mw.data.qsos[i], &a, &o) && inView(a, o)) qsos.push_back(i);
        }
    std::vector<ADIFViewRow> rows;
    for (size_t i : qsos) {
        if (i >= mw.data.qsos.size()) continue;
        const adif::MapQso &q = mw.data.qsos[i];
        ADIFViewRow r;
        r.item = i;
        if (qsoPlace(q, &r.lat, &r.lon))
            r.km = adif::greatCircleKm(lat, lon, r.lat, r.lon), r.bearing = adif::initialBearing(lat, lon, r.lat, r.lon);
        std::string grid4 = q.grid.substr(0, std::min<size_t>(4, q.grid.size()));
        for (char &c : grid4) c = (char)toupper((unsigned char)c);
        if (kind == kListContacts) {
            if (auto c = contactOf.find(i); q.located && c != contactOf.end() && mw.view.showContacts) {
                r.hit.kind = ADIFMapHit::Contact, r.hit.index = c->second, r.hit.square = adif::squareAt(r.lon, r.lat);
                r.span = 0.02;
            } else if (auto sq = squareOf.find(grid4); sq != squareOf.end()) {
                r.hit.kind = ADIFMapHit::Square, r.hit.index = sq->second, r.hit.square = grid4;
                r.span = q.grid.size() >= 6 ? 0.05 : 0.6;
            } else {
                continue;
            }
        }
        r.color = [mw.view colorFor:[mw.view aggregate:std::vector<size_t>(1, i)] entity:NO];
        rows.push_back(r);
    }
    return rows;
}

// The rows for parks: those the map marks in the view.
std::vector<ADIFViewRow> parkRows(double lat, double lon) {
    const adif::PotaParks &list = ADIFPotaParks();
    std::map<size_t, ADIFParkSpot> byPark;
    std::vector<size_t> candidates;
    for (const ADIFParkSpot &sp : [mw.view parksInView])
        if (byPark.emplace(sp.park, sp).second) candidates.push_back(sp.park);
    std::vector<ADIFViewRow> rows;
    for (const adif::ParkDistance &d : adif::nearestParks(list.parks(), candidates, lat, lon, candidates.size())) {
        const adif::PotaPark &p = list.parks()[d.park];
        ADIFViewRow r;
        r.item = d.park;
        r.hit.kind = ADIFMapHit::Pota, r.hit.index = d.park, r.hit.square = adif::squareAt(p.lon, p.lat);
        r.lat = p.lat, r.lon = p.lon, r.km = d.km, r.bearing = d.bearing;
        r.color = [mw.view parkColor:byPark[d.park]];
        rows.push_back(r);
    }
    return rows;
}

// The rows for spots: the stations spotted in view (the Spots layer's).
std::vector<ADIFViewRow> spotRows(double lat, double lon) {
    const std::vector<ADIFMapSpot> &spots = mw.view.spots;
    std::vector<ADIFViewRow> rows;
    for (size_t k = 0; k < spots.size(); ++k) {
        const ADIFMapSpot &ms = spots[k];
        if (!inView(ms.lat, ms.lon)) continue;
        ADIFViewRow r;
        r.item = k;
        r.hit.kind = ADIFMapHit::Spot, r.hit.index = k, r.hit.square = adif::squareAt(ms.lon, ms.lat);
        r.lat = ms.lat, r.lon = ms.lon, r.span = ms.exact ? 0.1 : 1;
        r.km = adif::greatCircleKm(lat, lon, ms.lat, ms.lon), r.bearing = adif::initialBearing(lat, lon, ms.lat, ms.lon);
        r.color = [mw.view spotColor:ms];
        r.tree = potaSpot(ms.spot);
        rows.push_back(r);
    }
    return rows;
}

// A DXCC entity's name, from the country data.
std::string entityName(int dxcc, const std::string &call) {
    static std::map<int, std::string> names;
    static size_t namesFor = 0;
    const adif::CountryTable &countries = ADIFCountries();
    if (namesFor != countries.entities()) {
        names.clear();
        for (const adif::CountryInfo &c : countries.all()) names.emplace(c.dxcc, c.name);
        namesFor = countries.entities();
    }
    if (auto it = names.find(dxcc); dxcc > 0 && it != names.end()) return it->second;
    adif::CountryInfo info;
    return !countries.empty() && countries.lookup(call, &info) ? info.name : "";
}

// A row's text in a column.
std::string cellText(int kind, const ADIFViewRow &r, const std::string &id) {
    if (id == "distance") return r.km < 0 ? "" : adif::distanceText(r.km, mw.listUnits.selectedSegment == 0);
    if (id == "bearing") {
        if (r.km < 0) return "";
        char deg[16];
        snprintf(deg, sizeof deg, "%.0f°", std::fmod(std::round(r.bearing) + 360, 360));
        return deg;
    }
    if (kind == kListSelected || kind == kListContacts) {
        if (r.item >= mw.data.qsos.size()) return "";
        const adif::MapQso &q = mw.data.qsos[r.item];
        if (id == "record") return std::to_string(q.record);
        if (id == "call") return q.call;
        if (id == "date") return q.date;
        if (id == "time") return q.time;
        if (id == "band") return q.band;
        if (id == "mode") return q.mode;
        if (id == "grid") return q.grid;
        if (id == "confirmed") return q.confirmed ? tr("yes") : "";
        if (id == "country") return entityName(q.dxcc, q.call);
        if (id == "state") return q.areas.state;
        if (id == "county") return q.areas.county;
        if (id == "cq") return q.areas.cq ? std::to_string(q.areas.cq) : "";
        if (id == "itu") return q.areas.itu ? std::to_string(q.areas.itu) : "";
        if (id == "park") {
            std::string out;
            for (const std::string &p : q.potaHunted) out += (out.empty() ? "" : ", ") + p;
            return out;
        }
        return "";
    }
    if (kind == kListParks) {
        const adif::PotaParks &list = ADIFPotaParks();
        if (r.item >= list.size()) return "";
        const adif::PotaPark &p = list.parks()[r.item];
        if (id == "ref") return p.ref;
        if (id == "name") return p.name;
        if (id == "location") return p.location;
        if (id == "grid") return adif::squareAt(p.lon, p.lat);
        if (id == "worked") {
            ADIFParkWork w = [mw.view parkWork:p.ref];
            std::string out;
            if (!w.hunted.empty()) out = trp("hunted, {n} QSO", "hunted, {n} QSOs", (long long)w.hunted.size());
            if (!w.activated.empty()) out += (out.empty() ? "" : "; ") + trp("activated, {n} QSO", "activated, {n} QSOs", (long long)w.activated.size());
            return out;
        }
        if (id == "outline") {
            const adif::ParkOutline *o = parkoutlines::find(p.ref);
            return o ? o->source + (o->matched ? "*" : "") : "";
        }
        return "";
    }
    const std::vector<ADIFMapSpot> &spots = mw.view.spots;
    if (r.item >= spots.size()) return "";
    const ADIFMapSpot &ms = spots[r.item];
    const adif::Spot &sp = ms.spot;
    if (id == "call") return sp.activator;
    if (id == "khz") {
        char khz[24] = "";  // to 100 Hz: PSKReporter gives Hz
        if (double f = std::atof(sp.khz.c_str()); f > 0) snprintf(khz, sizeof khz, std::fmod(f, 1) == 0 ? "%.0f" : "%.1f", f);
        return khz;
    }
    if (id == "band") return sp.band;
    if (id == "mode") return sp.mode;
    if (id == "need") {
        std::string out = adif::spotNeedText(ms.status.need);
        if (ms.status.newPark) out += (out.empty() ? "" : ", ") + tr("new park");
        return sp.heardMe ? "" : out;
    }
    if (id == "age") return adif::spotAge(sp.epoch, (long long)time(nullptr));
    if (id == "time") return sp.time;
    if (id == "program") return sp.program;
    if (id == "ref") return sp.reference;
    if (id == "park") return sp.park;
    if (id == "spotter") return sp.spotter;
    if (id == "source") return tr(adif::spotSourceName(sp.source));
    if (id == "snr") return adif::spotSnr(sp);
    if (id == "grid") return sp.grid;
    if (id == "country") return ms.status.entity;
    if (id == "comment") return sp.comments;
    return "";
}

// A row's value in a column, for sorting: a number for the numeric columns (age as seconds
// since; a QSO's date with its time), else its text.
double cellNumber(int kind, const ADIFViewRow &r, const std::string &id) {
    if (id == "distance") return r.km < 0 ? 1e12 : r.km;
    if (id == "bearing") return r.km < 0 ? 1e12 : std::fmod(r.bearing + 360, 360);
    if (kind == kListSpots && r.item < mw.view.spots.size()) {
        const adif::Spot &sp = mw.view.spots[r.item].spot;
        if (id == "khz") return std::atof(sp.khz.c_str());
        if (id == "age") return sp.epoch > 0 ? (double)((long long)time(nullptr) - sp.epoch) : 1e12;
        if (id == "snr") return sp.hasSnr ? sp.snr : -1e12;
    }
    if ((kind == kListSelected || kind == kListContacts) && r.item < mw.data.qsos.size()) {
        const adif::MapQso &q = mw.data.qsos[r.item];
        if (id == "record") return q.record;
        if (id == "cq") return q.areas.cq;
        if (id == "itu") return q.areas.itu;
    }
    return 0;
}

std::string sortText(int kind, const ADIFViewRow &r, const std::string &id) {
    if ((kind == kListSelected || kind == kListContacts) && id == "date" && r.item < mw.data.qsos.size())
        return mw.data.qsos[r.item].date8 + mw.data.qsos[r.item].time;
    std::string t = cellText(kind, r, id);
    for (char &c : t) c = (char)tolower((unsigned char)c);
    return t;
}

void showListRow(const ADIFMapHit &h);

// The list again, for the kind chosen: its rows, sorted, the page shown, the title, the pager.
void fillViewList() {
    mw.listQueued = false;
    if (!mw.listPanel || mw.listPanel.hidden) return;
    int kind = (int)std::clamp<NSInteger>(mw.listKind.selectedSegment, 0, 3);
    setListColumns(kind);
    std::string home = mw.home.empty() ? tr("no grid set") : mw.home;
    [mw.listFrom itemAtIndex:0].title = TF(@"Your station ({grid})", @{@"grid" : ADIFString(home)});
    [mw.listFrom itemAtIndex:0].enabled = !mw.home.empty();
    mw.listGrid.hidden = mw.listFrom.indexOfSelectedItem != 2;
    double lat = 0, lon = 0;
    std::string from;
    bool chosenPlace = listFromPlace(&lat, &lon, &from);
    std::vector<ADIFViewRow> rows = kind == kListParks ? parkRows(lat, lon) : kind == kListSpots ? spotRows(lat, lon) : qsoRows(kind, lat, lon);
    // Narrowed by the search (a call, reference, name... in any column shown, or the list's own
    // key columns) and the distance limit (in the units chosen).
    bool miles = mw.listUnits.selectedSegment == 0;
    for (NSMenuItem *item in mw.listWithin.itemArray)
        if (item.tag > 0) item.title = TF(miles ? @"Within {n} mi" : @"Within {n} km", @{@"n" : @(item.tag)});
    double limitKm = mw.listWithin.selectedTag * (miles ? 1.609344 : 1.0);
    std::string query = ADIFStd([[mw.listSearch.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString]);
    size_t found = rows.size();
    if (limitKm > 0 || !query.empty()) {
        std::set<std::string> searched = {"call", "ref", "name", "park", "country", "grid"};
        for (const auto &c : shownColumns(kind)) searched.insert(c.first);
        std::vector<ADIFViewRow> kept;
        for (const ADIFViewRow &r : rows) {
            if (limitKm > 0 && (r.km < 0 || r.km > limitKm)) continue;
            bool match = query.empty();
            for (const std::string &id : searched) {
                if (match) break;
                if (!listColumn(kind, id)) continue;
                std::string t = cellText(kind, r, id);
                for (char &c : t) c = (char)tolower((unsigned char)c);
                match = t.find(query) != std::string::npos;
            }
            if (match) kept.push_back(r);
        }
        rows.swap(kept);
    }
    // Sorted by the column chosen (its values worked out once), ties in the order they came.
    std::pair<std::string, bool> sort = listSort(kind);
    const std::string sortId = sort.first;
    const bool ascending = sort.second;
    const ListColumn *sortCol = listColumn(kind, sortId);
    std::vector<size_t> order(rows.size());
    for (size_t i = 0; i < order.size(); ++i) order[i] = i;
    if (sortCol && sortCol->number) {
        std::vector<double> keys(rows.size());
        for (size_t i = 0; i < rows.size(); ++i) keys[i] = cellNumber(kind, rows[i], sortId);
        std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return ascending ? keys[a] < keys[b] : keys[a] > keys[b]; });
    } else if (sortCol) {
        std::vector<std::string> keys(rows.size());
        for (size_t i = 0; i < rows.size(); ++i) keys[i] = sortText(kind, rows[i], sortId);
        std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
            if (keys[a].empty() != keys[b].empty()) return keys[b].empty();  // the empty ones last, either way
            return ascending ? ADIFNaturalCompare(keys[a], keys[b]) < 0 : ADIFNaturalCompare(keys[a], keys[b]) > 0;
        });
    }
    // The page.
    size_t pageSize = (size_t)std::max<NSInteger>(10, mw.listPageSize.selectedTag);
    size_t pages = std::max<size_t>(1, (rows.size() + pageSize - 1) / pageSize);
    size_t page = std::min(mw.listPage[kind], pages - 1);
    mw.listPage[kind] = page;
    std::vector<ADIFViewRow> shown;
    for (size_t i = page * pageSize; i < rows.size() && i < (page + 1) * pageSize; ++i) shown.push_back(rows[order[i]]);
    mw.listRows.rows = shown;
    mw.listRows.quiet = YES;
    [mw.listTable reloadData];
    showListRow(mw.view.selectedHit);
    mw.listRows.quiet = NO;
    mw.listPageLabel.stringValue = rows.empty() ? T(@"none")
                                                : TF(@"{from}–{to} of {total}", @{@"from" : @(page * pageSize + 1), @"to" : @(page * pageSize + shown.size()),
                                                                                        @"total" : @(rows.size())});
    mw.listPrev.enabled = page > 0;
    mw.listNext.enabled = page + 1 < pages;
    NSDictionary *counts = @{@"n" : @(rows.size())};
    switch (kind) {
        case kListSelected: mw.listTitle.stringValue = TF(@"Selected ({n})", counts); break;
        case kListContacts: mw.listTitle.stringValue = TF(@"Contacts in View ({n})", counts); break;
        case kListParks: mw.listTitle.stringValue = TF(@"Parks in View ({n})", counts); break;
        default: mw.listTitle.stringValue = TF(@"Spots in View ({n})", counts); break;
    }
    const ADIFMapStyle &st = mw.view.style;
    std::string hint;
    if (kind == kListSelected)
        hint = rows.empty() ? tr("Click a square, contact, park or area on the map for its QSOs.")
                            : tr("The QSOs of what you clicked on the map. Double-click one to go to it in the log.");
    else if (kind == kListParks && !ADIFPotaParks().size()) hint = tr("Download POTA's park list first: Settings, POTA Parks.");
    else if (kind == kListParks && !st[kLayerPota].show && !st[kLayerPota].overlay)
        hint = tr("Tick the POTA layer's Show (the parks you worked) or Overlay (the others) to list its parks.");
    else if (kind == kListSpots && !st[kLayerSpots].show) hint = tr("Tick the Spots layer's Show to list the stations spotted.");
    else if (rows.empty())
        hint = kind == kListParks    ? (st[kLayerPota].overlay ? trf("No POTA parks in view (POTA parks in: {places}).", {{"places", parkPlacesName(parkPlaces())}})
                                                               : tr("No parks you worked in view; tick POTA's Overlay for the others."))
               : kind == kListContacts ? tr("No QSOs with a grid or a place in view.")
                                       : tr("No spots in view.");
    else if (!chosenPlace && mw.listFrom.indexOfSelectedItem != 1)
        hint = mw.listFrom.indexOfSelectedItem == 2 ? trf("Not a grid square; from the map's centre ({grid}).", {{"grid", from}})
                                                    : trf("No grid for your station (Settings, Your Station); from the map's centre ({grid}).", {{"grid", from}});
    else hint = trf("Distances from {grid}. Click a row to choose it on the map; double-click to zoom to it. Click a column's title to sort by it.",
                    {{"grid", from}});
    if (rows.size() < found)  // the search or the distance limit left some out: say how many
        hint = trp("{n} of {total} matches the search and distance.", "{n} of {total} match the search and distance.", (long long)rows.size(),
                   {{"total", std::to_string(found)}}) +
               " " + hint;
    mw.listHint.stringValue = ADIFString(hint);
}

// The situation panel: the log as the map shows it; today's QSOs; the spots you most want now (a
// link each); the busiest bands; the sun at your station.
void showSituation() {
    if (!mw.situation) return;
    mw.situation.stringValue = ADIFString(mw.summary);
    std::string today = utcNow("%Y%m%d");
    adif::LogGlance g = adif::logGlance(mw.data.qsos, mw.view.worked, today);
    std::string line;
    if (!g.today) line = tr("Today (UTC): no QSOs yet.");
    else {
        std::string bands;
        for (const std::string &b : g.todayBands) bands += (bands.empty() ? "" : ", ") + b;
        std::string time = g.lastTime.size() >= 4 ? g.lastTime.substr(0, 2) + ":" + g.lastTime.substr(2, 2) : g.lastTime;
        line = trp("Today (UTC): {n} QSO (CW {cw}, phone {phone}, data {data}) on {bands}; the last at {time}, {call}.",
                   "Today (UTC): {n} QSOs (CW {cw}, phone {phone}, data {data}) on {bands}; the last at {time}, {call}.", (long long)g.today,
                   {{"cw", std::to_string(g.todayModes[0])}, {"phone", std::to_string(g.todayModes[1])}, {"data", std::to_string(g.todayModes[2])},
                    {"bands", bands}, {"time", time}, {"call", g.lastCall}});
    }
    if (g.states) line += " " + trp("{n} US state worked.", "{n} US states worked.", (long long)g.states);
    mw.today.stringValue = ADIFString(line);
    // The spots most wanted: a new DXCC first, then a new band, mode or park; the newest first.
    for (NSView *v in [mw.wanted.arrangedSubviews copy])
        if (v != mw.wantedLabel) [mw.wanted removeView:v];
    const std::vector<ADIFMapSpot> &spots = mw.view.spots;
    std::vector<size_t> wanted;
    for (size_t k = 0; k < spots.size(); ++k)
        if (!spots[k].spot.heardMe && adif::spotWanted(spots[k].status)) wanted.push_back(k);
    std::stable_sort(wanted.begin(), wanted.end(), [&](size_t a, size_t b) {
        int pa = adif::spotPriority(spots[a].status), pb = adif::spotPriority(spots[b].status);
        return pa != pb ? pa < pb : spots[a].spot.epoch > spots[b].spot.epoch;
    });
    if (!mw.view.style[kLayerSpots].show) mw.wantedLabel.stringValue = T(@"Spots: tick the Spots layer's Show for who is on the air, and which you need.");
    else if (wanted.empty())
        mw.wantedLabel.stringValue = TP(@"Wanted now: none of the {n} station spotted.", @"Wanted now: none of the {n} stations spotted.", (long long)spots.size());
    else mw.wantedLabel.stringValue = T(@"Wanted now:");
    for (size_t i = 0; i < wanted.size() && i < 6; ++i) {
        const ADIFMapSpot &ms = spots[wanted[i]];
        std::string need = ms.status.need == adif::SpotNeed::NewDxcc || ms.status.need == adif::SpotNeed::NewBand || ms.status.need == adif::SpotNeed::NewMode
                               ? adif::spotNeedText(ms.status.need)
                               : tr("new park");
        std::string activator = ms.spot.activator, band = ms.spot.band;
        NSButton *b = [NSButton buttonWithTitle:@"" target:nil action:nil];
        b.bordered = NO;
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc]
            initWithString:ADIFString(activator)
                attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName : NSColor.linkColor}];
        [t appendAttributedString:[[NSAttributedString alloc] initWithString:ADIFString(" " + band + " " + need)
                                                                  attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.smallSystemFontSize],
                                                                               NSForegroundColorAttributeName : [mw.view spotColor:ms]}]];
        b.attributedTitle = t;
        b.identifier = [NSString stringWithFormat:@"map.wanted.%zu", i];
        b.toolTip = ADIFString(spotNeedLine(ms.status, band));
        ADIFOnAction(b, ^{  // the spot (found again: the list may have changed), chosen on the map
            const std::vector<ADIFMapSpot> &now = mw.view.spots;
            for (size_t k = 0; k < now.size(); ++k)
                if (now[k].spot.activator == activator && now[k].spot.band == band) {
                    ADIFMapHit h;
                    h.kind = ADIFMapHit::Spot, h.index = k, h.square = adif::squareAt(now[k].lon, now[k].lat);
                    mw.choosingFromList = true;
                    [mw.view selectHit:h];
                    mw.choosingFromList = false;
                    return;
                }
        });
        [mw.wanted addArrangedSubview:b];
    }
    if (wanted.size() > 6) {
        NSTextField *more = [NSTextField labelWithString:TF(@"and {n} more", @{@"n" : @(wanted.size() - 6)})];
        more.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        more.textColor = NSColor.secondaryLabelColor;
        [mw.wanted addArrangedSubview:more];
    }
    // The busiest bands (stations spotted on each), and the sun where you are.
    std::string air;
    if (mw.view.style[kLayerSpots].show && !spots.empty()) {
        std::map<std::string, std::set<std::string>> byBand;
        for (const ADIFMapSpot &ms : spots)
            if (!ms.spot.band.empty()) byBand[ms.spot.band].insert(ms.spot.activator);
        std::vector<std::pair<std::string, size_t>> busy;
        for (const auto &kv : byBand) busy.emplace_back(kv.first, kv.second.size());
        std::stable_sort(busy.begin(), busy.end(), [](const auto &a, const auto &b) { return a.second > b.second; });
        std::string list;
        for (size_t i = 0; i < busy.size() && i < 6; ++i) list += (list.empty() ? "" : ", ") + busy[i].first + " " + std::to_string(busy[i].second);
        air = trf("On the air: {bands} (stations spotted).", {{"bands", list}});
    }
    double lat, lon;
    if (!mw.home.empty() && adif::gridToLatLon(mw.home, &lat, &lon)) {
        double now = (double)time(nullptr), at = 0;
        bool rising = false;
        double up = adif::solarElevation(adif::sunAt(now), lat, lon);
        std::string next;
        if (adif::nextSunCrossing(now, lat, lon, 0, &at, &rising)) {
            time_t t = (time_t)at;
            struct tm tm{};
            gmtime_r(&t, &tm);
            char hm[16];
            strftime(hm, sizeof hm, "%H:%M", &tm);
            next = rising ? trf("rises at {time} UTC", {{"time", hm}}) : trf("sets at {time} UTC", {{"time", hm}});
        }
        char deg[16];
        snprintf(deg, sizeof deg, "%.0f", std::fabs(up));
        std::string sun = up >= 0 ? trf("Sun at {grid}: up {deg}\u00B0", {{"grid", mw.home}, {"deg", deg}})
                                  : trf("Sun at {grid}: down {deg}\u00B0", {{"grid", mw.home}, {"deg", deg}});
        if (!next.empty()) sun += ", " + next;
        if (up > -6 && up < 0.8) sun += " " + tr("(the grey line is here)");
        air += (air.empty() ? "" : "  ") + sun + ".";
    }
    mw.air.stringValue = ADIFString(air);
}

void queueViewList() {
    if (mw.listQueued || !mw.listPanel || mw.listPanel.hidden) return;
    mw.listQueued = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 6)), dispatch_get_main_queue(), ^{ fillViewList(); });
}

void showListKind(int kind) {
    if (!mw.listKind) return;
    mw.listKind.selectedSegment = kind;
    setSetting("mapListKind", std::to_string(kind));
    fillViewList();
}

// What was chosen on the map, chosen in the list too (its first row on the page; none else).
void showListRow(const ADIFMapHit &h) {
    if (!mw.listTable) return;
    BOOL was = mw.listRows.quiet;
    mw.listRows.quiet = YES;
    NSInteger at = -1;
    for (size_t i = 0; i < mw.listRows.rows.size() && at < 0; ++i)
        if (mw.listRows.rows[i].hit.kind == h.kind && mw.listRows.rows[i].hit.index == h.index && h.kind != ADIFMapHit::None) at = (NSInteger)i;
    if (at >= 0) {
        [mw.listTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)at] byExtendingSelection:NO];
        [mw.listTable scrollRowToVisible:at];
    } else if (mw.listKind.selectedSegment != kListSelected) {
        [mw.listTable deselectAll:nil];
    }
    mw.listRows.quiet = was;
}

// Double-click: a QSO chosen goes to its record; anything else fills the map (a park's outline
// where downloaded, a square, else a little round it), chosen.
void openRow(const ADIFViewRow &r) {
    if (mw.listKind.selectedSegment == kListSelected) return goToQso(r.item);
    double w, s, e, n;
    const adif::PotaParks &list = ADIFPotaParks();
    const adif::ParkOutline *o = r.hit.kind == ADIFMapHit::Pota && r.hit.index < list.size() ? parkoutlines::find(list.parks()[r.hit.index].ref) : nullptr;
    bool square = !o && r.hit.kind == ADIFMapHit::Square && r.span > 0.5 && adif::squareBounds(r.hit.square, &w, &s, &e, &n);  // a 4-character grid
    if (o) w = o->west, s = o->south, e = o->east, n = o->north;
    else if (!square) w = r.lon - r.span, e = r.lon + r.span, s = r.lat - r.span * 0.67, n = r.lat + r.span * 0.67;
    [mw.view showPlaceWest:w south:s east:e north:n];
    mw.choosingFromList = true;
    [mw.view selectHit:r.hit];
    mw.choosingFromList = false;
}

// The control groups shown or not (Controls, in the toolbar): hidden, the map takes their room.
void showControls(bool on) {
    saveFlag("mapControls", on);
    mw.controlsToggle.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    mw.controlsView.hidden = !on;
    mw.controlsGone.active = !on;
    mw.controlsGap.constant = on ? 10 : 0;
    mw.underGap.constant = on ? 8 : 6;
    if (mw.styleWindow && !on) [mw.styleWindow orderOut:nil];  // its button stays in the toolbar; nothing else depends on it
}

// The panel shown or not: the map takes the room.
void showListPanel(bool on) {
    saveFlag("mapList", on);
    mw.listToggle.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    mw.listPanel.hidden = !on;
    [mw.mainSplit adjustSubviews];
    if (on) {
        CGFloat width = std::clamp((CGFloat)std::atof(setting("mapListWidth").c_str()), (CGFloat)280, (CGFloat)900);
        if (width < 281) width = 470;
        [mw.mainSplit setPosition:mw.mainSplit.bounds.size.width - width - mw.mainSplit.dividerThickness ofDividerAtIndex:0];
        queueViewList();
    }
}

NSButton *smallButton(NSString *title, NSString *tip, void (^action)(void)) {
    NSButton *b = [NSButton buttonWithTitle:T(title) target:nil action:nil];
    b.toolTip = T(tip);
    ADIFOnAction(b, action);
    return b;
}

NSPopUpButton *pullDown(NSString *title, NSString *tip) {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [p addItemWithTitle:T(title)];
    p.toolTip = T(tip);
    return p;
}

}  // namespace

void cmdMap() {
    if (!mw.window) {
        mw.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 1460, 900)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                         NSWindowStyleMaskUtilityWindow
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
        mw.window.title = T(@"Map");
        ADIFNightTrack(mw.window);
        mw.window.releasedWhenClosed = NO;
        mw.window.hidesOnDeactivate = NO;
        mw.window.contentMinSize = NSMakeSize(960, 640);
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
            b.toolTip = T(tip);
            b.accessibilityLabel = [NSString stringWithFormat:T(spoken), T(l.title)];
            return b;
        };
        for (const LayerUi &l : kLayerUi) {
            NSTextField *title = ADIFLabel(l.title);
            title.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
            [header addObject:title];
            mw.show[l.id] = l.showKey ? box(saved[l.id].show, @"show", l, l.showTip, l.id == kLayerSpots ? N(@"Show %@") : N(@"Show worked %@")) : nil;
            mw.overlay[l.id] = box(saved[l.id].overlay, @"overlay", l, l.overlayTip, N(@"Overlay %@"));
            mw.labels[l.id] = box(saved[l.id].labels, @"labels", l, l.labelsTip, N(@"Labels for %@"));
            [showRow addObject:mw.show[l.id] ?: [NSGridCell emptyContentView]];
            [overlayRow addObject:mw.overlay[l.id]];
            [labelsRow addObject:mw.labels[l.id]];
        }
        NSGridView *layers = [NSGridView gridViewWithViews:@[ header, showRow, overlayRow, labelsRow ]];
        layers.rowSpacing = 4;
        layers.columnSpacing = 8;
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
        mw.contacts.toolTip = T(@"A marker at each contact's own place: its LAT and LON, else a GRIDSQUARE of 6 or 8 characters (a 4-character "
                              @"square is 100 km or more across: Show grid squares shows those). Style Options chooses pins, dots or crosshairs");
        mw.lines = ADIFCheckbox(@"Lines to contacts", flag("mapPaths", false));
        mw.lines.toolTip = T(@"A great-circle line from your station to each contact, in its marker's colour; Style Options chooses their look");
        mw.programs = pullDown(@"Other programs", @"Other programs' references, a colour each: WWFF parks, SOTA summits, IOTA islands, GMA, "
                                                  @"bunkers, castles... (IOTA starts hidden: callbooks fill it in for every island station)");
        mw.mine = ADIFCheckbox(@"My station", flag("mapMine", true));
        mw.mine.toolTip = T(@"A star at each MY_GRIDSQUARE in the log");
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
        mw.projection.toolTip = T(@"Equirectangular: the grid as rectangles. Mercator: familiar shapes. Equal Earth: true sizes. Globe: the Earth "
                                @"as seen from space, centred on your grid; drag (or the arrow keys) to turn it any way, zoom in for detail, "
                                @"World to come home. Bearings from the centre are true (beam headings)");
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
            static const Box kRegions[] = {{N(@"Africa"), -20, -36, 53, 38},           {N(@"Antarctica"), -180, -90, 180, -60},
                                           {N(@"Asia"), 25, -11, 180, 78},             {N(@"Europe"), -25, 34, 45, 72},
                                           {N(@"North America"), -170, 5, -50, 75},    {N(@"Oceania"), 110, -48, 180, 0},
                                           {N(@"South America"), -82, -56, -34, 13}};
            for (const Box &b : kRegions) {
                NSMenuItem *item = [mw.region.menu addItemWithTitle:T(b.name) action:nil keyEquivalent:@""];
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
        mw.spotsButton = smallButton(@"Spots...", @"The spots the Spots layer shows: how new, from which sources, which program; and what the "
                                                  @"sources are doing", ^{ showSpotsPopover(); });
        mw.spotsButton.identifier = @"map.spots.open";
        // Refresh: the feeds asked again now, within their limits; what each did goes to the status line.
        mw.refreshSpotsButton = smallButton(@"Refresh Spots", @"Refresh the spots now: Spothole is asked again (at most once a minute), PSKReporter once its "
                                                 @"5 minutes have passed, and a DX cluster waiting to reconnect connects",
                                            ^{
                                                setStatus(spotfeeds::refreshNow());
                                                refreshSpots();
                                            });
        mw.refreshSpotsButton.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:T(@"Refresh Spots")];
        mw.refreshSpotsButton.title = @"";  // the icon only; its name for VoiceOver below
        mw.refreshSpotsButton.imagePosition = NSImageOnly;
        mw.refreshSpotsButton.accessibilityLabel = T(@"Refresh Spots");
        mw.refreshSpotsButton.identifier = @"map.spots.refresh";
        mw.refreshSpotsButton.enabled = NO;
        // Spots: their filters, Refresh, and one station's spots only (who heard it, as on PSKReporter's map).
        mw.spotsOnly = ADIFCheckbox(@"Only spots of", flag("mapSpotsOnly", false));
        mw.spotsOnly.toolTip = T(@"Show only this station's spots, each with every station that heard it: who is hearing you, as on PSKReporter's "
                                 @"map. PSKReporter is asked about this callsign while it is ticked");
        mw.spotsOnly.identifier = @"map.spots.only";
        mw.spotsOnlyCall = [NSTextField textFieldWithString:ADIFString(setting("mapSpotsOnlyCall"))];
        mw.spotsOnlyCall.placeholderString = setting("stationCall").empty() ? T(@"callsign") : ADIFString(setting("stationCall"));
        mw.spotsOnlyCall.toolTip = T(@"The station whose spots to show; empty: your callsign (Your Station)");
        mw.spotsOnlyCall.identifier = @"map.spots.onlyCall";
        ((NSTextFieldCell *)mw.spotsOnlyCall.cell).sendsActionOnEndEditing = YES;
        [mw.spotsOnlyCall.widthAnchor constraintEqualToConstant:110].active = YES;
        ADIFOnAction(mw.spotsOnly, ^{
            saveFlag("mapSpotsOnly", mw.spotsOnly.state == NSControlStateValueOn);
            refreshSpots();
        });
        ADIFOnAction(mw.spotsOnlyCall, ^{
            NSString *call = [[mw.spotsOnlyCall.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString];
            mw.spotsOnlyCall.stringValue = call;
            setSetting("mapSpotsOnlyCall", ADIFStd(call));
            if (call.length && mw.spotsOnly.state != NSControlStateValueOn) {  // a callsign typed: ticked too
                mw.spotsOnly.state = NSControlStateValueOn;
                saveFlag("mapSpotsOnly", true);
            }
            refreshSpots();
        });
        // POTA parks in: the park filter (which parks you haven't worked show), beside the spots.
        mw.parkPlacesButton = smallButton(@"everywhere", @"Which POTA parks you haven't worked show, on the map and in the list beside it: "
                                                         @"those in the POTA locations and US counties you choose (at first, your station's)",
                                          ^{ showParkPlaces(); });
        mw.parkPlacesButton.identifier = @"map.parkplaces.open";
        NSTextField *parksIn = ADIFLabel(@"POTA parks in:");
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
        // The list beside the map (its button shows or hides it): the parks, contacts or spots in view.
        mw.listToggle = [NSButton buttonWithTitle:T(@"List") target:nil action:nil];
        [mw.listToggle setButtonType:NSButtonTypePushOnPushOff];
        mw.listToggle.image = [NSImage imageWithSystemSymbolName:@"sidebar.right" accessibilityDescription:nil];
        mw.listToggle.imagePosition = NSImageLeading;
        mw.listToggle.toolTip = T(@"The list beside the map: the QSOs of what you click, or the contacts, POTA parks or spots in view, with "
                                  @"their distance and bearing from your station, the map's centre or a grid square");
        mw.listToggle.identifier = @"map.list.toggle";
        ADIFOnAction(mw.listToggle, ^{ showListPanel(mw.listToggle.state == NSControlStateValueOn); });
        mw.listPanel = [[NSView alloc] initWithFrame:NSZeroRect];
        mw.listPanel.identifier = @"map.list";
        mw.listKind = [NSSegmentedControl segmentedControlWithLabels:@[ T(@"Selected"), T(@"Contacts"), T(@"Parks"), T(@"Spots") ]
                                                         trackingMode:NSSegmentSwitchTrackingSelectOne
                                                               target:nil
                                                               action:nil];
        mw.listKind.selectedSegment = number("mapListKind", 0, 3);
        mw.listKind.toolTip = T(@"What the list shows: the QSOs of what you clicked on the map, or the contacts (QSOs with a grid or a place), "
                                @"the POTA parks or the spots in view");
        mw.listKind.identifier = @"map.list.kind";
        ADIFOnAction(mw.listKind, ^{
            setSetting("mapListKind", std::to_string(mw.listKind.selectedSegment));
            fillViewList();
        });
        mw.listTitle = ADIFLabel(@"Parks in View");
        mw.listTitle.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
        mw.listTitle.lineBreakMode = NSLineBreakByTruncatingTail;
        mw.listTitle.identifier = @"map.list.title";
        [mw.listTitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        mw.listUnits = [NSSegmentedControl segmentedControlWithLabels:@[ @"mi", @"km" ] trackingMode:NSSegmentSwitchTrackingSelectOne target:nil
                                                               action:nil];
        mw.listUnits.controlSize = NSControlSizeSmall;
        mw.listUnits.selectedSegment = setting("mapListUnits") == "mi" ? 0 : 1;
        mw.listUnits.toolTip = T(@"Distances in miles or kilometres");
        mw.listUnits.identifier = @"map.list.units";
        ADIFOnAction(mw.listUnits, ^{
            setSetting("mapListUnits", mw.listUnits.selectedSegment == 0 ? "mi" : "km");
            fillViewList();
        });
        mw.listFrom = ADIFPopup(@[ @"Your station", @"Map centre", @"Grid square:" ]);
        mw.listFrom.autoenablesItems = NO;
        [mw.listFrom selectItemAtIndex:number("mapListFrom", 0, 2)];
        mw.listFrom.toolTip = T(@"Where the distances and bearings are from, and so what comes first: your station's grid (Settings, Your "
                                @"Station), the middle of the map, or a grid square you type");
        mw.listFrom.identifier = @"map.list.from";
        mw.listGrid = [NSTextField textFieldWithString:ADIFString(setting("mapListGrid"))];
        mw.listGrid.placeholderString = @"EN50";
        mw.listGrid.toolTip = T(@"A grid square of 4, 6 or 8 characters");
        mw.listGrid.identifier = @"map.list.grid";
        ((NSTextFieldCell *)mw.listGrid.cell).sendsActionOnEndEditing = YES;
        [mw.listGrid.widthAnchor constraintEqualToConstant:76].active = YES;
        ADIFOnAction(mw.listFrom, ^{
            setSetting("mapListFrom", std::to_string(mw.listFrom.indexOfSelectedItem));
            fillViewList();
            if (mw.listFrom.indexOfSelectedItem == 2 && !mw.listGrid.stringValue.length) [mw.window makeFirstResponder:mw.listGrid];
        });
        ADIFOnAction(mw.listGrid, ^{
            mw.listGrid.stringValue = [mw.listGrid.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            setSetting("mapListGrid", ADIFStd(mw.listGrid.stringValue));
            fillViewList();
        });
        mw.listRows = [[ADIFViewList alloc] init];
        mw.listRows.onChoose = ^(const ADIFViewRow &r) {
            if (r.hit.kind == ADIFMapHit::None) return;  // a QSO chosen: double-click goes to it
            mw.choosingFromList = true;
            [mw.view selectHit:r.hit];
            mw.choosingFromList = false;
        };
        mw.listRows.text = ^NSString *(const ADIFViewRow &r, const std::string &column) {
            return ADIFString(cellText((int)mw.listKind.selectedSegment, r, column));
        };
        mw.listRows.onSort = ^{
            NSSortDescriptor *d = mw.listTable.sortDescriptors.firstObject;
            if (!d) return;
            int kind = (int)mw.listKind.selectedSegment;
            setSetting(listKey("mapListSort", kind).c_str(), std::string(d.ascending ? "" : "-") + ADIFStd(d.key));
            mw.listPage[kind] = 0;
            fillViewList();
        };
        mw.listRows.onColumnsChanged = ^{ saveListColumns(); };
        mw.listRows.onOpen = ^(const ADIFViewRow &r) { openRow(r); };
        mw.listTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
        mw.listTable.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;  // each column as wide as it was left; scroll for more
        mw.listTable.style = NSTableViewStylePlain;
        mw.listTable.allowsColumnReordering = YES;
        mw.listTable.headerView.menu = [[NSMenu alloc] init];  // right-click a title: which columns show
        mw.listTable.headerView.menu.delegate = mw.listRows;
        mw.listTable.intercellSpacing = NSMakeSize(4, 2);
        mw.listTable.dataSource = mw.listRows;
        mw.listTable.delegate = mw.listRows;
        mw.listTable.target = mw.listRows;
        mw.listTable.doubleAction = @selector(opened:);
        mw.listTable.usesAlternatingRowBackgroundColors = YES;
        mw.listTable.allowsEmptySelection = YES;
        mw.listTable.identifier = @"map.list.table";
        mw.listTable.accessibilityLabel = T(@"List");
        NSScrollView *listScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        listScroll.documentView = mw.listTable;
        listScroll.hasVerticalScroller = YES;
        listScroll.hasHorizontalScroller = YES;
        listScroll.autohidesScrollers = YES;
        listScroll.borderType = NSBezelBorder;
        mw.listHint = [NSTextField wrappingLabelWithString:@""];
        mw.listHint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.listHint.textColor = NSColor.secondaryLabelColor;
        mw.listHint.maximumNumberOfLines = 4;
        mw.listHint.identifier = @"map.list.hint";
        mw.view = [[ADIFMapView alloc] initWithFrame:NSZeroRect];
        mw.view.onHover = ^(const ADIFMapHit &h) {  // what's under the pointer, else what was chosen, else how to use the map
            std::string d = describe(h);
            if (!d.empty()) showContact(h, d);
            else showContact(mw.chosen.empty() ? ADIFMapHit() : mw.chosenHit, !mw.chosen.empty() ? mw.chosen : idleStatus());
        };
        mw.view.onSelect = ^(const ADIFMapHit &h) { selected(h); };
        mw.view.onViewChanged = ^{
            updateZoomLabel();
            queueViewList();
        };
        mw.status = [NSTextField wrappingLabelWithString:@""];
        mw.status.identifier = @"map.status";
        mw.status.maximumNumberOfLines = 5;
        mw.status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.useSpot = smallButton(@"Use in New QSO", @"Fill New QSO with the spot chosen on the map: its call, frequency, band, mode and reference",
                                 ^{ useSelectedSpot(); });
        mw.useSpot.identifier = @"map.spots.use";
        mw.useSpot.hidden = YES;
        // The list's footer: the page (with the previous and next), how many a page, the columns.
        mw.listPrev = smallButton(@"", @"The previous page", ^{
            int kind = (int)mw.listKind.selectedSegment;
            if (mw.listPage[kind] > 0) --mw.listPage[kind];
            fillViewList();
        });
        mw.listPrev.image = [NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:T(@"Previous Page")];
        mw.listPrev.imagePosition = NSImageOnly;
        mw.listPrev.identifier = @"map.list.prev";
        mw.listNext = smallButton(@"", @"The next page", ^{
            ++mw.listPage[mw.listKind.selectedSegment];
            fillViewList();
        });
        mw.listNext.image = [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:T(@"Next Page")];
        mw.listNext.imagePosition = NSImageOnly;
        mw.listNext.identifier = @"map.list.next";
        mw.listPageLabel = ADIFLabel(@"");
        mw.listPageLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        mw.listPageLabel.identifier = @"map.list.page";
        mw.listPageSize = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for (int n : {25, 50, 100, 250, 500}) [mw.listPageSize.menu addItemWithTitle:TF(@"{n} a page", @{@"n" : @(n)}) action:nil keyEquivalent:@""].tag = n;
        if (![mw.listPageSize selectItemWithTag:std::atoi(setting("mapListPageSize").c_str())]) [mw.listPageSize selectItemWithTag:50];
        mw.listPageSize.controlSize = NSControlSizeSmall;
        mw.listPageSize.toolTip = T(@"How many rows a page shows");
        mw.listPageSize.identifier = @"map.list.pagesize";
        ADIFOnAction(mw.listPageSize, ^{
            setSetting("mapListPageSize", std::to_string(mw.listPageSize.selectedTag));
            for (size_t &page : mw.listPage) page = 0;
            fillViewList();
        });
        mw.listColumnsMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
        [mw.listColumnsMenu addItemWithTitle:T(@"Columns")];
        mw.listColumnsMenu.controlSize = NSControlSizeSmall;
        mw.listColumnsMenu.toolTip = T(@"Which columns show (also: right-click a column's title); drag a title to move its column, its edge to size it");
        mw.listColumnsMenu.identifier = @"map.list.columns";
        mw.listColumnsMenu.menu.delegate = mw.listRows;
        {
            // Both menus fill themselves as they open: the Columns button's under its own title.
            NSMenu *columnsMenu = mw.listColumnsMenu.menu;
            mw.listRows.fillMenu = ^(NSMenu *menu) { fillColumnsMenu(menu, menu == columnsMenu); };
        }
        mw.listSearch = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        mw.listSearch.placeholderString = T(@"Search: a call, reference, name...");
        mw.listSearch.toolTip = T(@"Keep the rows with this in any column shown (or in the call, reference, name, park, country or grid)");
        mw.listSearch.identifier = @"map.list.search";
        mw.listSearch.controlSize = NSControlSizeSmall;
        mw.listSearch.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        [mw.listSearch setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        ADIFOnAction(mw.listSearch, ^{
            mw.listPage[mw.listKind.selectedSegment] = 0;
            fillViewList();
        });
        mw.listWithin = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [mw.listWithin addItemWithTitle:T(@"Any distance")];
        for (int n : {10, 25, 50, 100, 250, 500, 1000}) [mw.listWithin.menu addItemWithTitle:@"" action:nil keyEquivalent:@""].tag = n;
        if (![mw.listWithin selectItemWithTag:std::atoi(setting("mapListWithin").c_str())]) [mw.listWithin selectItemAtIndex:0];
        mw.listWithin.controlSize = NSControlSizeSmall;
        mw.listWithin.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.listWithin.toolTip = T(@"Keep the rows within this distance of where the list measures from (Nearest to)");
        mw.listWithin.identifier = @"map.list.within";
        for (NSMenuItem *item in mw.listWithin.itemArray)  // titled now; again by the list, as the units change
            if (item.tag > 0) item.title = TF(setting("mapListUnits") == "mi" ? @"Within {n} mi" : @"Within {n} km", @{@"n" : @(item.tag)});
        ADIFOnAction(mw.listWithin, ^{
            setSetting("mapListWithin", std::to_string(mw.listWithin.selectedTag));
            for (size_t &page : mw.listPage) page = 0;
            fillViewList();
        });
        NSStackView *listFromRow = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Nearest to:"), mw.listFrom, mw.listGrid ]];
        NSStackView *listSearchRow = [NSStackView stackViewWithViews:@[ mw.listSearch, mw.listWithin ]];
        listSearchRow.spacing = 6;
        listFromRow.spacing = 6;
        NSStackView *listFooter = [[NSStackView alloc] initWithFrame:NSZeroRect];
        listFooter.spacing = 4;
        for (NSView *v in @[ mw.listPrev, mw.listPageLabel, mw.listNext ]) [listFooter addView:v inGravity:NSStackViewGravityLeading];
        [listFooter addView:mw.listPageSize inGravity:NSStackViewGravityTrailing];
        [listFooter addView:mw.listColumnsMenu inGravity:NSStackViewGravityTrailing];
        for (NSView *v in @[ mw.listKind, mw.listTitle, mw.listUnits, listFromRow, listSearchRow, listScroll, listFooter, mw.listHint ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [mw.listPanel addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [mw.listKind.topAnchor constraintEqualToAnchor:mw.listPanel.topAnchor],
            [mw.listKind.leadingAnchor constraintEqualToAnchor:mw.listPanel.leadingAnchor constant:8],
            [mw.listKind.trailingAnchor constraintLessThanOrEqualToAnchor:mw.listPanel.trailingAnchor],
            [mw.listTitle.topAnchor constraintEqualToAnchor:mw.listKind.bottomAnchor constant:10],
            [mw.listTitle.leadingAnchor constraintEqualToAnchor:mw.listPanel.leadingAnchor constant:8],
            [mw.listTitle.trailingAnchor constraintLessThanOrEqualToAnchor:mw.listUnits.leadingAnchor constant:-8],
            [mw.listUnits.centerYAnchor constraintEqualToAnchor:mw.listTitle.centerYAnchor],
            [mw.listUnits.trailingAnchor constraintEqualToAnchor:mw.listPanel.trailingAnchor],
            [listFromRow.topAnchor constraintEqualToAnchor:mw.listTitle.bottomAnchor constant:8],
            [listFromRow.leadingAnchor constraintEqualToAnchor:mw.listPanel.leadingAnchor constant:8],
            [listFromRow.trailingAnchor constraintLessThanOrEqualToAnchor:mw.listPanel.trailingAnchor],
            [listSearchRow.topAnchor constraintEqualToAnchor:listFromRow.bottomAnchor constant:6],
            [listSearchRow.leadingAnchor constraintEqualToAnchor:mw.listPanel.leadingAnchor constant:8],
            [listSearchRow.trailingAnchor constraintEqualToAnchor:mw.listPanel.trailingAnchor],
            [listScroll.topAnchor constraintEqualToAnchor:listSearchRow.bottomAnchor constant:6],
            [listScroll.leadingAnchor constraintEqualToAnchor:mw.listPanel.leadingAnchor constant:8],
            [listScroll.trailingAnchor constraintEqualToAnchor:mw.listPanel.trailingAnchor],
            [listFooter.topAnchor constraintEqualToAnchor:listScroll.bottomAnchor constant:6],
            [listFooter.leadingAnchor constraintEqualToAnchor:mw.listPanel.leadingAnchor constant:8],
            [listFooter.trailingAnchor constraintEqualToAnchor:mw.listPanel.trailingAnchor],
            [mw.listHint.topAnchor constraintEqualToAnchor:listFooter.bottomAnchor constant:6],
            [mw.listHint.leadingAnchor constraintEqualToAnchor:mw.listPanel.leadingAnchor constant:8],
            [mw.listHint.trailingAnchor constraintEqualToAnchor:mw.listPanel.trailingAnchor],
            [mw.listHint.bottomAnchor constraintEqualToAnchor:mw.listPanel.bottomAnchor],
            [mw.listHint.heightAnchor constraintGreaterThanOrEqualToConstant:28],
        ]];

        // ── The controls: a toolbar across the top, then the groups (Layers, Markers, Filters,
        // Spots) side by side, as many to a line as fit, with lines between them ──
        mw.target.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
        mw.target.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [mw.target setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        auto cluster = [](NSArray<NSView *> *views) {
            NSStackView *c = [NSStackView stackViewWithViews:views];
            c.spacing = 8;
            return c;
        };
        ADIFFlowView *toolbar = [[ADIFFlowView alloc] initWithFrame:NSZeroRect];  // wraps, like the groups, in a narrow window
        toolbar.gap = 17;
        toolbar.trailingLast = YES;
        toolbar.centred = YES;
        toolbar.identifier = @"map.toolbar";
        NSStackView *zoomCluster = cluster(@[ ADIFLabel(@"Zoom:"), out, mw.zoomLabel, in, fit, world ]);
        [zoomCluster setCustomSpacing:4 afterView:out];
        [zoomCluster setCustomSpacing:4 afterView:mw.zoomLabel];
        // Controls: the groups under the toolbar shown or hidden, for the map's room.
        mw.controlsToggle = [NSButton buttonWithTitle:T(@"Controls") target:nil action:nil];
        [mw.controlsToggle setButtonType:NSButtonTypePushOnPushOff];
        mw.controlsToggle.image = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:nil];
        mw.controlsToggle.imagePosition = NSImageLeading;
        mw.controlsToggle.toolTip = T(@"Show or hide the controls under the toolbar (layers, markers, filters, spots); hidden, the map takes their room "
                                      @"and every choice stays as it is");
        mw.controlsToggle.identifier = @"map.controls.toggle";
        ADIFOnAction(mw.controlsToggle, ^{ showControls(mw.controlsToggle.state == NSControlStateValueOn); });
        for (NSView *v in @[ cluster(@[ mw.target ]), zoomCluster, cluster(@[ mw.region, mw.projection ]), cluster(@[ styleButton, save ]),
                             cluster(@[ mw.controlsToggle, mw.listToggle ]) ])
            [toolbar addSubview:v];
        auto group = [](NSString *caption, NSString *ident, NSArray<NSView *> *rows) {
            NSTextField *title = [NSTextField labelWithString:T(caption).localizedUppercaseString];
            title.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize - 1 weight:NSFontWeightSemibold];
            title.textColor = NSColor.secondaryLabelColor;
            NSMutableArray *views = [NSMutableArray arrayWithObject:title];
            [views addObjectsFromArray:rows];
            NSStackView *g = [NSStackView stackViewWithViews:views];
            g.orientation = NSUserInterfaceLayoutOrientationVertical;
            g.alignment = NSLayoutAttributeLeading;
            g.spacing = 6;
            [g setCustomSpacing:5 afterView:title];
            g.identifier = ident;
            return g;
        };
        auto line = [](NSArray<NSView *> *views) {
            NSStackView *r = [NSStackView stackViewWithViews:views];
            r.spacing = 8;
            return r;
        };
        NSStackView *spotsLine = line(@[ mw.spotsButton, mw.refreshSpotsButton ]);
        [spotsLine setCustomSpacing:4 afterView:mw.spotsButton];
        NSStackView *onlyLine = line(@[ mw.spotsOnly, mw.spotsOnlyCall ]);
        [onlyLine setCustomSpacing:4 afterView:mw.spotsOnly];
        ADIFFlowView *controls = [[ADIFFlowView alloc] initWithFrame:NSZeroRect];
        controls.gap = 25;
        controls.identifier = @"map.controls";
        for (NSView *g in @[
                 group(N(@"Layers"), @"map.group.layers", @[ layers ]),
                 group(N(@"Markers"), @"map.group.markers", @[ line(@[ mw.contacts, mw.lines ]), line(@[ mw.mine, mw.programs ]), mw.colorBy ]),
                 group(N(@"Filters"), @"map.group.filters",
                       @[ line(@[ mw.band, mw.mode ]), line(@[ mw.dates, mw.confirmed ]), line(@[ mw.moreFilters, mw.clearFilters ]),
                          line(@[ parksIn, mw.parkPlacesButton ]) ]),
                 group(N(@"Spots"), @"map.group.spots", @[ spotsLine, onlyLine ]),
             ])
            [controls addSubview:g];
        NSBox *underControls = [[NSBox alloc] initWithFrame:NSZeroRect];
        underControls.boxType = NSBoxSeparator;

        // ── The body: the map and the list (a divider between them), over the status bar (the
        // contact on the left, the situation on the right) ──
        auto panel = [](NSString *caption, NSString *ident, NSView *content, NSView *corner) {
            NSView *p = [[NSView alloc] initWithFrame:NSZeroRect];
            p.identifier = ident;
            NSTextField *title = [NSTextField labelWithString:T(caption).localizedUppercaseString];
            title.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize - 1 weight:NSFontWeightSemibold];
            title.textColor = NSColor.secondaryLabelColor;
            for (NSView *v in corner ? @[ title, content, corner ] : @[ title, content ]) {
                v.translatesAutoresizingMaskIntoConstraints = NO;
                [p addSubview:v];
            }
            [NSLayoutConstraint activateConstraints:@[
                [title.topAnchor constraintEqualToAnchor:p.topAnchor constant:6],
                [title.leadingAnchor constraintEqualToAnchor:p.leadingAnchor constant:8],
                [content.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3],
                [content.leadingAnchor constraintEqualToAnchor:p.leadingAnchor constant:8],
                [content.trailingAnchor constraintEqualToAnchor:corner ? corner.leadingAnchor : p.trailingAnchor constant:-8],
                [content.bottomAnchor constraintLessThanOrEqualToAnchor:p.bottomAnchor constant:-4],
            ]];
            if (corner)
                [NSLayoutConstraint activateConstraints:@[
                    [corner.topAnchor constraintEqualToAnchor:p.topAnchor constant:4],
                    [corner.trailingAnchor constraintEqualToAnchor:p.trailingAnchor constant:-8],
                ]];
            [content setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
            return p;
        };
        auto small = [](NSString *ident, NSInteger lines) {
            NSTextField *f = [NSTextField wrappingLabelWithString:@""];
            f.identifier = ident;
            f.maximumNumberOfLines = lines;
            f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            return f;
        };
        auto column = [](NSArray<NSView *> *views) {  // views one under another, each as wide as the column
            NSStackView *c = [NSStackView stackViewWithViews:views];
            c.orientation = NSUserInterfaceLayoutOrientationVertical;
            c.alignment = NSLayoutAttributeLeading;
            c.spacing = 3;
            for (NSView *v in views) [v.widthAnchor constraintEqualToAnchor:c.widthAnchor].active = YES;
            return c;
        };
        mw.slots = [NSTextField labelWithString:@""];
        mw.slots.identifier = @"map.contact.slots";
        mw.slots.lineBreakMode = NSLineBreakByTruncatingTail;
        mw.slots.toolTip = T(@"This station's DXCC entity in your log: its bands and modes, green confirmed, orange worked, grey not yet; and "
                             @"your QSOs with the call");
        mw.situation = small(@"map.situation", 3);
        mw.today = small(@"map.today", 2);
        mw.air = small(@"map.air", 2);
        mw.wantedLabel = [NSTextField labelWithString:@""];
        mw.wantedLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.wanted = [NSStackView stackViewWithViews:@[ mw.wantedLabel ]];
        mw.wanted.spacing = 6;
        mw.wanted.identifier = @"map.wanted";
        [mw.wanted setClippingResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        mw.wanted.detachesHiddenViews = YES;
        NSStackView *spotActions = [[NSStackView alloc] initWithFrame:NSZeroRect];  // Use in New QSO, under a spot's description
        [spotActions addView:mw.useSpot inGravity:NSStackViewGravityLeading];
        spotActions.detachesHiddenViews = YES;
        mw.useSpot.controlSize = NSControlSizeSmall;
        mw.contactTitle = [NSTextField labelWithString:@""];
        mw.contactTitle.identifier = @"map.contact.title";
        mw.contactTitle.font = [NSFont systemFontOfSize:NSFont.systemFontSize + 1 weight:NSFontWeightSemibold];
        mw.contactTitle.lineBreakMode = NSLineBreakByTruncatingTail;
        NSView *contactPanel = panel(N(@"Contact"), @"map.contact", column(@[ mw.contactTitle, mw.status, mw.slots, spotActions ]), nil);
        NSView *situationPanel = panel(N(@"Situation"), @"map.situationPanel", column(@[ mw.situation, mw.today, mw.wanted, mw.air ]), nil);
        mw.splitKeeper = [[ADIFSplitKeeper alloc] init];
        auto split = [](NSString *ident, BOOL vertical, NSArray<NSView *> *views) {
            NSSplitView *sv = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
            sv.identifier = ident;
            sv.vertical = vertical;
            sv.dividerStyle = NSSplitViewDividerStyleThin;
            sv.arrangesAllSubviews = YES;
            for (NSView *v in views) [sv addArrangedSubview:v];
            sv.delegate = mw.splitKeeper;
            return sv;
        };
        mw.mainSplit = split(@"map.main.split", YES, @[ mw.view, mw.listPanel ]);
        [mw.mainSplit setHoldingPriority:NSLayoutPriorityDefaultLow - 10 forSubviewAtIndex:0];  // the map takes a window's growth
        [mw.mainSplit setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:1];
        mw.statusSplit = split(@"map.status.split", YES, @[ contactPanel, situationPanel ]);
        mw.outerSplit = split(@"map.outer.split", NO, @[ mw.mainSplit, mw.statusSplit ]);
        [mw.outerSplit setHoldingPriority:NSLayoutPriorityDefaultLow - 10 forSubviewAtIndex:0];
        [mw.outerSplit setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:1];
        mw.splitKeeper.onMoved = ^(NSSplitView *sv) {
            if (!mw.splitsRestored) return;
            if (sv == mw.mainSplit && !mw.listPanel.hidden) setSetting("mapListWidth", std::to_string((int)mw.listPanel.frame.size.width));
            if (sv == mw.outerSplit) setSetting("mapStatusHeight", std::to_string((int)mw.statusSplit.frame.size.height));
            if (sv == mw.statusSplit && sv.bounds.size.width > 0)
                setSetting("mapContactShare", std::to_string((int)std::lround(100 * contactPanel.frame.size.width / sv.bounds.size.width)));
        };
        for (NSView *v in @[ toolbar, controls, underControls, mw.outerSplit ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [root addSubview:v];
        }
        CGFloat m = 14;
        [NSLayoutConstraint activateConstraints:@[
            [toolbar.topAnchor constraintEqualToAnchor:root.topAnchor constant:10],
            [toolbar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [toolbar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            mw.controlsGap = [controls.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:10],
            [controls.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [controls.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            mw.underGap = [underControls.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:8],
            [underControls.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [underControls.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [mw.outerSplit.topAnchor constraintEqualToAnchor:underControls.bottomAnchor constant:6],
            [mw.outerSplit.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [mw.outerSplit.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [mw.outerSplit.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-8],
            [mw.view.widthAnchor constraintGreaterThanOrEqualToConstant:360],
            [mw.view.heightAnchor constraintGreaterThanOrEqualToConstant:240],
            [mw.statusSplit.heightAnchor constraintGreaterThanOrEqualToConstant:70],
        ]];
        mw.controlsView = controls;
        mw.controlsGone = [controls.heightAnchor constraintEqualToConstant:0];
        showControls(flag("mapControls", true));
        showListPanel(flag("mapList", true));
        [mw.window center];
        // New spots redraw the layer; closing the window stops the feeds.
        [[NSNotificationCenter defaultCenter] addObserverForName:ADIFParkOutlinesChangedNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *) {
                                                          mw.view.needsDisplay = YES;
                                                          fillStyle();  // outline only needs outlines
                                                          queueViewList();
                                                      }];
        [[NSNotificationCenter defaultCenter] addObserverForName:ADIFNightModeChangedNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *) {
                                                          applyStyle();
                                                          fillStyle();
                                                          fillPrograms();
                                                      }];
        mw.spotsObserver = [[NSNotificationCenter defaultCenter] addObserverForName:ADIFSpotsChangedNotification
                                                                             object:nil
                                                                              queue:nil
                                                                         usingBlock:^(NSNotification *) { refreshSpots(); }];
        mw.closeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
                                                                             object:mw.window
                                                                              queue:nil
                                                                         usingBlock:^(NSNotification *) { spotfeeds::setWanted(false); }];
    }
    if (!mw.sunTimer)
        mw.sunTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      repeats:YES
                                                        block:^(NSTimer *) {
                                                            ADIFMapStyle st = mw.view.style;
                                                            if (mw.window.visible && (st.dayNight || st.greyLine) && st.sunTime == 0)
                                                                mw.view.needsDisplay = YES;
                                                            // Spots age: their filter, fading and labels follow.
                                                            if (mw.window.visible && st[kLayerSpots].show) refreshSpots();
                                                            else if (mw.window.visible) showSituation();  // the sun moves on
                                                        }];
    refresh();
    [mw.window makeKeyAndOrderFront:nil];
    if (!mw.splitsRestored) {  // the dividers where they were left: the list's width, the status bar's height and split
        [mw.window layoutIfNeeded];
        CGFloat statusHeight = std::clamp((CGFloat)std::atof(setting("mapStatusHeight").c_str()), (CGFloat)0, (CGFloat)400);
        if (statusHeight < 70) statusHeight = 132;
        [mw.outerSplit setPosition:mw.outerSplit.bounds.size.height - statusHeight - mw.outerSplit.dividerThickness ofDividerAtIndex:0];
        int share = std::atoi(setting("mapContactShare").c_str());
        [mw.statusSplit setPosition:mw.statusSplit.bounds.size.width * (share >= 20 && share <= 80 ? share : 50) / 100.0 ofDividerAtIndex:0];
        showListPanel(!mw.listPanel.hidden);
        mw.splitsRestored = true;
    }
    [mw.window makeFirstResponder:mw.view];
    refreshSpots();  // the feeds start once the window shows
}

void setSpotHandler(void (^handler)(const std::vector<std::pair<std::string, std::string>> &fields)) { mw.spotHandler = handler; }

void iotaGroupsChanged() {
    if (mw.view) mw.view.needsDisplay = YES;
}

void parkListChanged() {
    if (mw.view) mw.view.needsDisplay = YES;
    applyParkPlaces();  // its locations, and home's
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

