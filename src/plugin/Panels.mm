// The panels: see Panels.h.
#import "Panels.h"

#import "Clocks.h"
#import "L10n.h"
#import "LogTools.h"
#import "Map.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#import "Workspace.h"
#include "adif_layout.h"

namespace {

// How each panel opens, closes and says whether it shows (its module's own calls).
struct Calls {
    bool (*shown)();
    void (*open)();
    void (*close)();
};

void closeNewQso() {
    if (adifhost::newQsoShown()) adifhost::toggleNewQso();
}
void closeLogTable() {
    if (logtools::logTableShown()) logtools::toggleLogTable();
}
void closeSpots() {
    if (logtools::spotsShown()) logtools::toggleSpots();
}
void closeContactMap() {
    if (workspace::contactMapShown()) workspace::toggleContactMap();
}
void closeQsoDetails() {
    if (workspace::qsoDetailsShown()) workspace::toggleQsoDetails();
}

const Calls *callsFor(const std::string &id) {
    static const std::pair<const char *, Calls> kCalls[] = {
        {adif::layout::kNewQso, {adifhost::newQsoShown, adifhost::openNewQso, closeNewQso}},
        {adif::layout::kLogTable, {logtools::logTableShown, logtools::cmdLogTable, closeLogTable}},
        {adif::layout::kMap, {worldmap::mapShown, worldmap::cmdMap, worldmap::closeMap}},
        {adif::layout::kSpots, {logtools::spotsShown, logtools::cmdPotaSpots, closeSpots}},
        {adif::layout::kContactMap, {workspace::contactMapShown, workspace::openContactMap, closeContactMap}},
        {adif::layout::kQsoDetails, {workspace::qsoDetailsShown, adifhost::openQsoDetails, closeQsoDetails}},
        {adif::layout::kMapStyle, {worldmap::mapStyleShown, worldmap::openMapStyle, worldmap::closeMapStyle}},
        {adif::layout::kAids, {adifhost::aidsPanelShown, adifhost::openAidsPanel, adifhost::closeAidsPanel}},
        {adif::layout::kSpotSources, {adifhost::spotSourcesShown, adifhost::openSpotSources, adifhost::closeSpotSources}},
        {adif::layout::kStation, {adifhost::stationShown, adifhost::openStation, adifhost::closeStation}},
        {adif::layout::kClocks, {clocks::shown, clocks::open, clocks::close}},
    };
    for (const auto &[pid, calls] : kCalls)
        if (id == pid) return &calls;
    return nullptr;
}

}  // namespace

// The Panels menu's target: its titles set as it opens (Show or Hide), a choice toggling that panel.
@interface ADIFPanelsMenu : NSObject <NSMenuDelegate>
@end

@implementation ADIFPanelsMenu
- (void)menuNeedsUpdate:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        const panels::Spec *spec = item.representedObject ? panels::find([item.representedObject UTF8String]) : nullptr;
        if (!spec) continue;
        item.title = TF(panels::shown(spec->id) ? @"Hide {panel}" : @"Show {panel}", @{@"panel" : T(spec->title)});  // HIG: the title says what it will do
    }
}
- (void)panelChosen:(NSMenuItem *)item {
    if (item.representedObject) panels::toggle([item.representedObject UTF8String]);
}
@end

namespace panels {

const std::vector<Spec> &all() {
    static const std::vector<Spec> specs = {
        {adif::layout::kNewQso, N(@"QSO"), @"square.and.pencil", N(@"QSO: log a contact (on while it shows; click again to close it)"), @"map.newqso",
         true},
        {adif::layout::kLogTable, N(@"Log Table"), @"tablecells",
         N(@"The log as a table: sort, search and edit its QSOs (on while it shows; click again to close it)"), @"map.logtable", true},
        {adif::layout::kMap, N(@"Interactive Map"), @"map", nil, nil, false},
        {adif::layout::kSpots, N(@"Activations & Spots"), @"antenna.radiowaves.left.and.right",
         N(@"Activations & Spots: the activators and stations spotted now, as a table (on while it shows; click again to close it)"), @"map.spotstable", true},
        {adif::layout::kContactMap, N(@"Static Map"), @"mappin.and.ellipse",
         N(@"Static Map: where the QSO panel's contact is, from your station (on while it shows; click again to close it)"), @"map.contactmap", true},
        {adif::layout::kQsoDetails, N(@"QSO Details"), @"person.text.rectangle",
         N(@"QSO Details: who the QSO panel's contact is, why it's worth having, and your QSOs with the call (on while it shows; click again to close it)"),
         @"map.qsodetails", true},
        {adif::layout::kMapStyle, N(@"Map Appearance"), @"paintpalette", nil, nil, false},  // the Interactive Map's own button opens it
        {adif::layout::kAids, N(@"Operating Aids"), @"text.bubble",
         N(@"Operating Aids: the operating style's facts and suggestions for the contact in the QSO panel (on while it shows; click again to close it)"),
         @"map.aids", true},
        {adif::layout::kClocks, N(@"Clocks"), @"clock",
         N(@"Clocks: UTC, your local time and the time zones you choose (on while it shows; click again to close it)"), @"map.clocks", true},
        {adif::layout::kSpotSources, N(@"Spot Configuration"), @"dot.radiowaves.left.and.right", nil, nil, false},  // Settings' sections
        {adif::layout::kStation, N(@"Your Station"), @"house", nil, nil, false},
    };
    return specs;
}

const Spec *find(const std::string &id) {
    for (const Spec &s : all())
        if (id == s.id) return &s;
    return nullptr;
}

bool shown(const std::string &id) {
    const Calls *c = callsFor(id);
    return c && c->shown();
}

void setShown(const std::string &id, bool on) {
    const Calls *c = callsFor(id);
    if (!c) return;
    if (on) c->open();  // opened, or brought forward
    else if (c->shown()) c->close();
    ADIFPanelShownChanged();
}

void toggle(const std::string &id) { setShown(id, !shown(id)); }

NSMenuItem *menuItem() {
    static NSMenuItem *item;
    static ADIFPanelsMenu *target;
    if (item) return item;
    target = [[ADIFPanelsMenu alloc] init];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:T(@"Panels")];
    menu.delegate = target;
    for (const Spec &s : all()) {
        NSMenuItem *mi = [menu addItemWithTitle:TF(@"Show {panel}", @{@"panel" : T(s.title)}) action:@selector(panelChosen:) keyEquivalent:@""];
        mi.target = target;
        mi.representedObject = @(s.id);
        mi.image = [NSImage imageWithSystemSymbolName:s.symbol accessibilityDescription:nil];
        mi.identifier = [@"org.nextpad.adiflint.panels." stringByAppendingString:@(s.id)];
    }
    item = [[NSMenuItem alloc] initWithTitle:T(@"Panels") action:nil keyEquivalent:@""];
    item.identifier = @"org.nextpad.adiflint.menu.panels";
    item.submenu = menu;
    return item;
}

}  // namespace panels
