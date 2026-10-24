// Space weather for the Map, from NOAA's Space Weather Prediction Center (services.swpc.noaa.gov,
// public domain): the 10.7 cm solar flux, the planetary K and A indices, GOES X-rays, the NOAA
// scales and the OVATION aurora nowcast. The parsers take the files as SWPC serves them since its
// format change of 31 March 2026 (SCN 26-21: arrays of objects with named fields), read
// 2026-10-24, and are bounded against broken or hostile input; a file that doesn't parse leaves
// what it would have set alone.
#pragma once

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

struct SpaceWeather {
    double sfi = -1;      // 10.7 cm flux, solar flux units (Penticton's noon reading)
    std::string sfiTime;  // its time, "2026-10-23T20:00:00" (UTC)
    double kp = -1;       // the latest 3-hour planetary K index, in thirds (1.67 is 2-)
    std::string kpTime;   // the start of its 3 hours (UTC)
    std::vector<std::pair<std::string, double>> kpRecent;  // the last 24 hours' (8), oldest first
    int ap = -1;          // the latest daily planetary A index (SWPC's estimate)
    std::string apDate;   // its day, "2026 10 23"
    double xray = -1;     // GOES 0.1-0.8 nm X-ray flux, W/m2, the latest minute
    std::string xrayTime;
    // The NOAA scales now: radio blackouts (R), solar radiation storms (S), geomagnetic storms (G),
    // each 0-5 (-1 unknown), and SWPC's word for it ("none", "minor"...).
    int r = -1, s = -1, g = -1;
    std::string rText, sText, gText;
};

// /products/summary/10cm-flux.json: [{"flux":101,"time_tag":"..."}].
bool parseSolarFlux(std::string_view json, SpaceWeather &w);
// /products/noaa-planetary-k-index.json: [{"time_tag":"...","Kp":1.67,"a_running":6,"station_count":8}...], oldest first.
bool parsePlanetaryK(std::string_view json, SpaceWeather &w);
// /text/daily-geomagnetic-indices.txt: the Estimated Planetary A of the last day with all 8 Kp
// (today's is still partial).
bool parseDailyIndices(std::string_view text, SpaceWeather &w);
// /json/goes/primary/xrays-6-hour.json: the last "0.1-0.8nm" flux.
bool parseXrays(std::string_view json, SpaceWeather &w);
// /products/noaa-scales.json: the "0" (now) entry's R, S and G.
bool parseNoaaScales(std::string_view json, SpaceWeather &w);

// An X-ray flux (W/m2) as a flare class: A, B, C, M or X (1e-8 to 1e-4) and the multiple, "C2.3"
// (SWPC, Solar Flares (Radio Blackouts)); "" for none.
std::string flareClass(double wattsPerSquareMetre);
// The Kp index as written, from its thirds: "2-", "2", "2+" (1.67, 2.00, 2.33).
std::string kpText(double kp);

// The OVATION aurora nowcast, /json/ovation_aurora_latest.json: a value for each whole degree,
// longitude 0-359 east and latitude -90 to 90, from SWPC's [longitude, latitude, aurora]
// triples. SWPC gives no unit; it is read as the chance of seeing aurora overhead, in percent.
struct AuroraGrid {
    std::vector<unsigned char> value;  // 360 x 181, latitude -90 first; empty before any
    std::string observed, forecast;    // "Observation Time" and "Forecast Time" (UTC)
    // At a place (longitude -180..180 or 0..360), between the four degrees round it; 0 without data.
    double at(double lon, double lat) const;
};
bool parseOvation(std::string_view json, AuroraGrid &g);

}  // namespace adif
