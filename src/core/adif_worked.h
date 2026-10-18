// Where a QSO counts on the Map's area layers: its US state and county, CQ zone and ITU zone.
// Each comes from the record's own field, else from where the QSO was (its place inside the
// area's outline: LAT/LON or a 6-character grid, or for a state a 4-character square wholly
// inside it), else from the country data for its call. The Map shades the areas worked and
// says where each one's QSOs came from.
#pragma once

#include "adif_country.h"
#include "adif_world.h"

#include <array>
#include <cstddef>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace adif {

// Even-odd: inside an odd number of the rings (a ring inside another is a hole). Rings are
// (lon, lat) and not closed.
bool pointInRings(const std::vector<std::vector<std::pair<double, double>>> &rings, double lon, double lat);

// An overlay's areas with their bounding boxes, for finding the area at a point.
class AreaIndex {
public:
    static constexpr size_t npos = (size_t)-1;
    explicit AreaIndex(Overlay o);
    size_t size() const { return areas_.size(); }
    const OverlayArea &area(size_t i) const { return areas_[i]; }
    // The area holding the point, or npos. `prefix` keeps to areas whose name starts with it
    // ("WI," for Wisconsin's counties).
    size_t at(double lon, double lat, std::string_view prefix = {}) const;
    size_t byName(std::string_view name) const;  // exact, else npos
    size_t byCounty(std::string_view cnty) const;  // counties: by countyKey(), else npos

private:
    std::vector<OverlayArea> areas_;
    std::vector<std::array<double, 4>> boxes_;  // west, south, east, north
    std::unordered_map<std::string, size_t> names_, counties_;
};
// The index of an overlay, built on first use.
const AreaIndex &areaIndex(Overlay o);

// A US county as CNTY writes it ("MO,St. Louis", "IL,LaSalle", "wi,dane") reduced to a key the
// Map's counties ("MO,Saint Louis", "IL,La Salle") reduce to as well: upper case, accents and
// punctuation dropped, "Saint" as "ST", a trailing "County"/"Parish"/"Borough" dropped, spaces
// and hyphens removed ("MO,STLOUIS"). "" when it isn't "state,county".
std::string countyKey(std::string_view cnty);

// What a QSO says about where it was.
struct QsoPlaceFacts {
    int dxcc = 0;      // the record's DXCC, else the country data's for its call
    std::string cont;  // the record's CONT, else the country data's
    std::string state, cnty;
    int cqz = 0, ituz = 0;      // the record's
    int ctyCq = 0, ctyItu = 0;  // the country data's for its call
    bool exact = false;         // lat and lon say where it was (LAT/LON or a 6-character grid)
    double lat = 0, lon = 0;
    std::string grid4;  // its 4-character square, when it has one
};
QsoAreas resolveAreas(const QsoPlaceFacts &q);

// DXCC entities whose STATE is a US state: the United States, Alaska, Hawaii.
bool isUsEntity(int dxcc);
// The facts of one of the map's QSOs; `countries` may be null or empty.
QsoPlaceFacts placeFacts(const MapQso &m, const CountryTable *countries);

}  // namespace adif
