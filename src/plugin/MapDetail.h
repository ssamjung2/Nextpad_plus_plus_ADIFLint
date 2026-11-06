// Map Detail: OpenStreetMap's streets, buildings, land use, water and place names on the Map
// when zoomed in, for the regions the user downloads in Settings → Map Detail. Each region is
// cut from Protomaps' newest daily planet build (build.protomaps.com, listed in
// build-metadata.protomaps.dev/builds.json, read 2026-10-18) by byte ranges, as `pmtiles
// extract` does it (adif_pmtiles.h), and kept on this Mac in <config>/maps/ as
// "<name> z<zoom> <build>.pmtiles". The Map draws only from those files: Protomaps asks that its
// builds not be hotlinked, so nothing is fetched while drawing. The data is © OpenStreetMap
// contributors under the ODbL; the Map credits it wherever it draws it.
#pragma once

#import <Foundation/Foundation.h>

#include "adif_pmtiles.h"

#include <array>
#include <memory>
#include <string>
#include <vector>

extern NSString *const ADIFMapDetailChangedNotification;  // a region was downloaded or removed
@class NSBezierPath;

namespace mapdetail {

// What can be downloaded: "view" (the area shown on the Map, when it is open), "state:WI",
// "country:Italy".
struct Choice {
    std::string id, name;
};
std::vector<Choice> choices(bool mapOpen);

// How much detail: the highest zoom kept. Its word is the Detail control's name for it; its name and what it holds are for a
// region's card and the Detail control's description; its title is its tooltip, with the zoom.
struct Level {
    int zoom;
    const char *word;
    const char *title;
    const char *name;
    const char *what;
};
const std::vector<Level> &levels();  // the most detail first
const Level *levelAt(int zoom);      // the level kept at that zoom; nil for none

struct Region {
    std::string path, name, build;  // build: YYYYMMDD
    int maxZoom = 0;
    uint64_t bytes = 0;
    std::shared_ptr<adif::pmtiles::Archive> archive;
    std::array<double, 4> bounds{};  // west, south, east, north
};
const std::vector<Region> &regions();  // the downloaded ones, open for drawing
// A downloaded region's outline for its Settings card: the state's or country's rings, north up, the longitude narrowed by
// the latitude; nil when it has none (the area shown on the Map).
NSBezierPath *outlinePath(const Region &region);
bool remove(const std::string &path, std::string *why);
NSString *status();  // what is downloaded, for Settings

// Check: the newest build, then the region's directories, and what the download would take.
void check(const std::string &choice, int zoom, void (^done)(BOOL ok, NSString *message));
bool checked(const std::string &choice, int zoom);  // check() succeeded for this, and nothing changed since
// Download what check() found: progress messages as it goes, then done.
void download(void (^progress)(NSString *message), void (^done)(BOOL ok, NSString *message));
void stop();
bool busy();

}  // namespace mapdetail
