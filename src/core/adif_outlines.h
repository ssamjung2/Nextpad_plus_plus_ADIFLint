// POTA park outlines for the Map: each park's boundary as rings of (lon, lat), from
// - OpenStreetMap: areas whose communication:amateur_radio:pota tag names the park (Overpass
//   "out geom" JSON; multipolygon members joined into rings), ODbL;
// - pota-map.info: DK5UR's GeoJSON for AT, CH, CZ, DE, DK and LU (feature property "id" is the
//   reference; read 2026-10-20), MIT over government open data;
// - PAD-US 4.1 (USGS Protected Areas Database, ArcGIS query JSON) for US parks, which it knows
//   only by name: matched by name and by POTA's own place for the park, and marked so.
// Rings are kept alike, outer and holes, and drawn and tested even-odd.
#pragma once

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

using OutlinePoint = std::pair<double, double>;  // lon, lat
using OutlineRing = std::vector<OutlinePoint>;   // closed: the last point is the first

struct ParkOutline {
    std::string ref;     // "US-1234"
    std::string source;  // "OSM", "pota-map.info", "PAD-US"
    std::string name;    // the source's name for it
    bool matched = false;  // found by name and place (PAD-US), not by its reference
    std::vector<OutlineRing> rings;
    double west = 180, south = 90, east = -180, north = -90;
    void bound();  // west..north from the rings
};

// A POTA reference's shape: "US-1234", "DE-0001", "VK-12345" (1 to 4 letters or digits, a dash,
// 4 or 5 digits).
bool potaRefShaped(std::string_view ref);

// Way segments joined end to end into closed rings (ends within 1e-7 degrees, either way
// round); what can't close is dropped.
std::vector<OutlineRing> joinRings(std::vector<OutlineRing> segments);

// A ring with points closer than `tolerance` degrees to the line through their neighbours
// dropped (Douglas-Peucker), still closed; empty when fewer than 4 points would be left.
OutlineRing simplifyRing(const OutlineRing &ring, double tolerance);

// Overpass "out geom" JSON: every way (closed) and relation (its way members' geometry joined)
// whose tag names one or more references ("US-1234", or several split by ";" or ","): an outline
// each. False, with why, when it isn't Overpass's JSON.
bool overpassOutlines(std::string_view json, std::vector<ParkOutline> *out, std::string *why);

// A GeoJSON FeatureCollection's Polygon and MultiPolygon features whose "id" (or "reference")
// property is a reference; trails (lines) are skipped.
bool geojsonOutlines(std::string_view json, std::string_view source, std::vector<ParkOutline> *out, std::string *why);

// PAD-US: a unit (a parcel) from an ArcGIS query answer (f=json, outSR=4326): its name
// (Unit_Nm), designation type (Des_Tp: SP state park, NF national forest...) and rings. `more`
// when the answer says more records wait (exceededTransferLimit).
struct PadUnit {
    std::string name, designation;
    std::vector<OutlineRing> rings;
    double west = 180, south = 90, east = -180, north = -90;
};
bool arcgisUnits(std::string_view json, std::vector<PadUnit> *out, bool *more, std::string *why);

// A park's name without its designation, as words to match: lower case, letters and digits,
// "and" for "&", a plural "s" dropped, and words like state, park, national, forest, wildlife,
// area, preserve dropped: "Campbell's Island State Park" is "campbell island".
std::vector<std::string> parkNameWords(std::string_view name);
// The PAD-US query for some parks of a state: State_Nm='IL' AND (UPPER(Unit_Nm) LIKE '%BEALL%WOOD%'
// OR ...), each name's words in order, cut to 6 letters (so "Campbells" still finds "Campbell").
std::string padUsWhere(std::string_view state, const std::vector<std::vector<std::string>> &names);

// POTA's parks of a state matched to PAD-US units: a unit whose name holds the park's words (or
// the park's name holds the unit's, two or more of them) within 5 km of POTA's place for the
// park; not land "south of" the park, nor a local or private unit for a park whose name says state
// or national. One whose
// designation fits the name wins ("State Park" and SP, "National Forest" and NF...), then the
// closer name, then the nearer. Every parcel of the chosen name within 25 km makes the outline.
struct ParkSite {
    std::string ref, name;
    double lat = 0, lon = 0;
};
std::vector<ParkOutline> matchPadUnits(const std::vector<ParkSite> &parks, const std::vector<PadUnit> &units);

// Whether a point is in the outline (even-odd over its rings), and how far it is from it in km
// (0 inside).
bool inOutline(const ParkOutline &o, double lon, double lat);
double outlineDistanceKm(const std::vector<OutlineRing> &rings, double lat, double lon);

// The outlines' cache file: a header line, then "P", ref, source, matched and name between tabs,
// each ring an "R" line of lon,lat pairs in whole units of 1e-5 degree (about a metre).
std::string writeOutlines(const std::vector<ParkOutline> &outlines);
bool readOutlines(std::string_view text, std::vector<ParkOutline> *out, std::string *why);

}  // namespace adif
