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
#endif

namespace worldmap {

void cmdMap();
void cmdLiveMap();
bool mapShown();  // open: its window, or its frame in the Operating Console
void closeMap();
// Map Style (it was the Style Options card): a panel of its own, made with the Map.
bool mapStyleShown();
void openMapStyle();
void closeMapStyle();  // the Map showing the spots: Live, or DX Chase or POTA when it is in one
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
