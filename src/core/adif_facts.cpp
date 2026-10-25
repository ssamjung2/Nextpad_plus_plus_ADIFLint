#include "adif_facts.h"

#include "adif_geo.h"
#include "adif_i18n.h"
#include "adif_parks.h"

#include <cmath>
#include <cstdio>

namespace adif {

using i18n::tr;
using i18n::trf;

std::string localTimeText(long long now, double utcOffsetHours) {
    if (now <= 0) return "";
    long long minutes = std::llround(utcOffsetHours * 60);
    long long local = ((now / 60 + minutes) % 1440 + 1440) % 1440;
    char clock[8];
    std::snprintf(clock, sizeof clock, "%02lld:%02lld", local / 60, local % 60);
    long long whole = std::llabs(minutes) / 60, rest = std::llabs(minutes) % 60;
    char zone[24];
    if (minutes == 0) std::snprintf(zone, sizeof zone, "UTC");
    else if (rest) std::snprintf(zone, sizeof zone, "UTC%c%lld:%02lld", minutes < 0 ? '-' : '+', whole, rest);
    else std::snprintf(zone, sizeof zone, "UTC%c%lld", minutes < 0 ? '-' : '+', whole);
    return std::string(clock) + " (" + zone + ")";
}

std::vector<LookupFact> lookupFacts(const LookupSubject &s) {
    std::vector<LookupFact> out;
    std::string place = s.qth;
    if (!s.state.empty()) place += (place.empty() ? "" : ", ") + s.state;
    if (!s.name.empty() || !place.empty()) {
        std::string value = s.name;
        if (!place.empty()) value += (value.empty() ? "" : " · ") + place;
        out.push_back({tr("Operator"), value,
                       s.away && !place.empty() ? tr("The callbook's address is the station's home; it is away now (a portable call, or a park)") : ""});
    }
    if (!s.country.empty() || s.entity) {
        std::string value = !s.country.empty() ? s.country : s.entity->name;
        if (s.entity) {
            value += " · " + s.entity->continent + " · " +
                     trf("CQ {cq} · ITU {itu} · DXCC {dxcc}",
                         {{"cq", std::to_string(s.entity->cq)}, {"itu", std::to_string(s.entity->itu)}, {"dxcc", std::to_string(s.entity->dxcc)}});
        }
        out.push_back({tr("Country"), value, ""});
    }
    if (!s.grid.empty())
        out.push_back({tr("Grid"), s.grid + (s.gridFromCallbook ? " " + tr("(from the callbook)") : ""), ""});
    double a, b, c, d;
    if (gridToLatLon(s.myGrid, &a, &b) && gridToLatLon(s.grid, &c, &d)) {
        double km = greatCircleKm(a, b, c, d);
        long sp = std::lround(initialBearing(a, b, c, d)) % 360, lp = (sp + 180) % 360;
        const double kAround = 40030;  // the great circle round the Earth, km (6,371 km radius)
        out.push_back({tr("Distance"),
                       trf("{distance} at {short}° (long path {long}°)",
                           {{"distance", distanceText(km, s.miles)}, {"short", std::to_string(sp)}, {"long", std::to_string(lp)}}),
                       trf("Short path {short}°, {distance}; long path {long}°, {far}. From {mine} to {theirs}.",
                           {{"short", std::to_string(sp)},
                            {"distance", distanceText(km, s.miles)},
                            {"long", std::to_string(lp)},
                            {"far", distanceText(kAround - km, s.miles)},
                            {"mine", s.myGrid},
                            {"theirs", s.grid}})});
    }
    if (s.entity && s.entity->hasUtcOffset && s.now > 0)
        out.push_back({tr("Local time"), localTimeText(s.now, s.entity->utcOffset),
                       tr("The entity's standard time from the country file: no daylight saving time, and a large country spans "
                          "several zones")});
    return out;
}

}  // namespace adif
