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
// The locations downloaded: how many of their parks have an outline, from which source, of how
// many parks in POTA's list; the file's size and when it was downloaded.
struct Downloaded {
    std::string location;
    size_t outlines = 0, parks = 0;
    size_t osm = 0, potaMap = 0, padUs = 0;
    long long bytes = 0;
    std::string date;  // "2026-10-20", local time
};
std::vector<Downloaded> downloaded();
size_t parksIn(const std::string &location);  // its active parks with a place, in POTA's list
// Over them all: "3 locations, 2.4 MB: 412 of 590 parks have an outline (70%)."; nothing
// downloaded: "None downloaded.". One location's line, for the Downloaded menu ("US-IL: 154 of
// 219 parks, 1.2 MB, 2026-10-20"), and where its outlines came from ("OSM 12, PAD-US 142").
std::string summary(const std::vector<Downloaded> &all);
std::string describe(const Downloaded &d);
std::string sources(const Downloaded &d);

// Every outline downloaded (read once, again after a change), and one park's.
const std::vector<adif::ParkOutline> &all();
const adif::ParkOutline *find(const std::string &ref);
size_t generation();  // counts the changes: a download or a removal

// Downloads a location's outlines, replacing what it had. `progress` says what it is doing;
// `done` how many of its parks have one, or why there are none. One download at a time.
void download(const std::string &location, void (^progress)(NSString *what), void (^done)(BOOL ok, NSString *message));
bool busy();
void remove(const std::string &location);

}  // namespace parkoutlines
