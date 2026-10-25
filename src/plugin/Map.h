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

namespace worldmap {

void cmdMap();
void documentChanged();  // the log changed or another became active
void iotaGroupsChanged();  // IOTA's group list was downloaded (Settings)
void parkListChanged();   // POTA's park list was downloaded (Settings)
// The longitudes and latitudes the Map shows (west, south, east, north), when it is open and
// not showing the whole world: Settings → Map Detail's "the area shown on the Map".
bool shownArea(std::array<double, 4> *box);
void detailChanged();  // Map Detail regions were downloaded or removed
// Where a spot's Use in New QSO sends its fields (New QSO, set up by ADIFLint.mm).
void setSpotHandler(void (^handler)(const std::vector<std::pair<std::string, std::string>> &fields));
#ifdef __OBJC__
// What the Map's Settings card holds (ADIF Lint's settings, set up by ADIFLint.mm).
void setSettingsProvider(NSView * (^provider)(void));
#endif
// The Map open, its selected panel shown and its Settings card open and in sight (the menu's
// Settings..., and every "add it in Settings").
void revealSettings();
#ifdef __OBJC__
NSWindow *mapWindow();  // nil before the Map opens
#endif
// The QSO with this record number shown on the Map, when it is open (after New QSO logs it):
// listed in Selected, its square chosen.
void showRecord(int record);

}  // namespace worldmap
