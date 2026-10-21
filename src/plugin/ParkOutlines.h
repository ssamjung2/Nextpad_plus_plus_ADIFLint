// POTA park outlines for the Map (Settings → POTA Parks → Park Outlines). For one POTA location
// at a time (US-IL, DE-HE, VK-NSW...), downloaded only when asked, from
// - OpenStreetMap through Overpass: areas tagged with the park's reference (ODbL);
// - pota-map.info, for AT, CH, CZ, DE, DK and LU (its own files per location);
// - PAD-US, for US parks: units matched by name and by POTA's place for the park;
// then kept in the plugin config folder (parks/<location>.outlines) for the Map. An exact
// reference wins over a match by name; OSM's over pota-map.info's.
#pragma once

#import <Foundation/Foundation.h>

#include "adif_outlines.h"

#include <string>
#include <vector>

extern NSString *const ADIFParkOutlinesChangedNotification;

namespace parkoutlines {

// The POTA locations in the park list, sorted ("US-IL"); empty before it is downloaded.
std::vector<std::string> locations();
// The locations downloaded: their outlines and parks, and the file's size.
struct Downloaded {
    std::string location;
    size_t outlines = 0, parks = 0;
    long long bytes = 0;
};
std::vector<Downloaded> downloaded();

// Every outline downloaded (read once, again after a change), and one park's.
const std::vector<adif::ParkOutline> &all();
const adif::ParkOutline *find(const std::string &ref);

// Downloads a location's outlines, replacing what it had. `progress` says what it is doing;
// `done` how many of its parks have one, or why there are none. One download at a time.
void download(const std::string &location, void (^progress)(NSString *what), void (^done)(BOOL ok, NSString *message));
bool busy();
void remove(const std::string &location);

}  // namespace parkoutlines
