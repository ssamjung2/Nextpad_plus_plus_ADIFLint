// Map... : the log on a world map, offline. Worked grid squares (green when
// confirmed), DXCC from country data, the parks you hunted and your
// own grid, over Natural Earth's land outline (adif_world.h); PNG export.
#pragma once

#include <array>

namespace worldmap {

void cmdMap();
void documentChanged();  // the log changed or another became active
void iotaGroupsChanged();  // IOTA's group list was downloaded (Settings)
void parkListChanged();   // POTA's park list was downloaded (Settings)
// The longitudes and latitudes the Map shows (west, south, east, north), when it is open and
// not showing the whole world: Settings → Map Detail's "the area shown on the Map".
bool shownArea(std::array<double, 4> *box);
void detailChanged();  // Map Detail regions were downloaded or removed

}  // namespace worldmap
