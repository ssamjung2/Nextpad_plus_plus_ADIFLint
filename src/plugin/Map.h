// Map... : the log on a world map, offline. Worked grid squares (green when
// confirmed), DXCC from country data, the parks you hunted and your
// own grid, over Natural Earth's land outline (adif_world.h); PNG export.
#pragma once

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#endif

#include <array>
#include <string>
#include <utility>
#include <vector>

#ifdef __OBJC__
// Posted when the Map's operating style changes (or a change is undone): New QSO's Operating Aids follow.
extern NSString *const ADIFOperatingStyleChangedNotification;
extern NSString *const ADIFOpportunitiesChangedNotification;  // Chasing's opportunities ranked afresh (the spots, or Next)
#endif

namespace worldmap {

void cmdMap();
void cmdLiveMap();
bool mapShown();  // open: its window, or its frame in the Operating Console
void closeMap();
// Map Style (it was the Style Options card): a panel of its own, made with the Map.
bool mapStyleShown();
void openMapStyle();
void closeMapStyle();
// Chasing (OPERATING_STYLES_PLAN.md, Stage 4): the spots ranked as opportunities (adif_chase.h).
// Next Opportunity: the one after the spot chosen (the best when none is; step -1 the one before),
// chosen on the map; false when there is none. A QSO logged in New QSO with a station spotted: in
// the Chasing style, the next opportunity (the logged one no longer is).
bool nextOpportunity(int step);
void qsoLogged(const std::string &call);
// What Operating Aids say in the Chasing style for New QSO's call (empty: the next opportunity).
struct ChaseLine {
    std::string text;
    int severity = 0;    // 0 a fact, 1 a note, 2 a warning
    std::string symbol;  // an SF Symbol's name
    bool next = false;   // the next opportunity: its Next chooses it
};
std::vector<ChaseLine> chaseLines(const std::string &call, const std::string &freqMHz, const std::string &mode);
// The newest spot of a call on the map, in short: its first rows of the spot's information (what
// to tune, why it's worth having, its park, how fresh), as label and value; none when it isn't spotted.
std::vector<std::pair<std::string, std::string>> spotInfoFor(const std::string &call, size_t most);
// Where the newest spot of a call places it (and its grid, "" when the spot gives none); false when it isn't spotted.
bool spotPlaceFor(const std::string &call, double *lat, double *lon, std::string *grid);
// Your station's grid as the Map has it: Your Station's, else the log's most used MY_GRIDSQUARE ("" none).
std::string stationHome();
  // the Map showing the spots: Live, or DX Chase or POTA when it is in one
// Start Logging: the Map, once it is open, as an operating map: Live's spots of the last five
// minutes, plain DX (no POTA parks or activators), at 2.5×.
void showForLogging();
void documentChanged();  // the log changed or another became active
void iotaGroupsChanged();  // IOTA's group list was downloaded (Settings)
void parkListChanged();   // POTA's park list was downloaded (Settings)
// The longitudes and latitudes the Map shows (west, south, east, north), when it is open and
// not showing the whole world: Settings → Map Detail's "the area shown on the Map".
bool shownArea(std::array<double, 4> *box);
void detailChanged();  // Map Detail regions were downloaded or removed
// Where a spot's Use in New QSO sends its fields (New QSO, set up by ADIFLint.mm).
void setSpotHandler(void (^handler)(const std::vector<std::pair<std::string, std::string>> &fields));
// The Map's own list hidden (true) while the Log Table shows the same records beside it, shown again after.
void setListSuppressed(bool on);
// The panes as the console's arrangement has them now (one of your layouts chosen).
void applyPanes();
#ifdef __OBJC__
NSWindow *mapWindow();  // nil before the Map opens
#endif
// The QSO with this record number shown on the Map, when it is open (after New QSO logs it):
// listed in Selected, its square chosen.
void showRecord(int record);

}  // namespace worldmap
