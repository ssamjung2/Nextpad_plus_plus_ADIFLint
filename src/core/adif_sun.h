// Where the sun is, for the Map's day and night and grey line: the equations of NOAA's solar
// calculator (gml.noaa.gov/grad/solcalc, its main.js, read 2026-10-17), which follow Meeus,
// Astronomical Algorithms. Good to about a minute of time and 0.01 degree for 1901-2099. No
// refraction: the Map's twilight bands are wide enough not to need it.
#pragma once

#include <vector>
#include <utility>

namespace adif {

struct SunPosition {
    double declination = 0;  // degrees: the latitude where the sun is overhead
    double eqTime = 0;       // equation of time, minutes (sundial ahead of the clock when positive)
    double subLat = 0, subLon = 0;  // where the sun is overhead now
};

// At a time in seconds since 1970-01-01 00:00 UTC.
SunPosition sunAt(double unixSeconds);
// The sun's elevation above the horizon at a place, in degrees (negative below it).
double solarElevation(const SunPosition &sun, double lat, double lon);
// The places where the sun is `elevation` degrees up (0: the terminator; -6: the end of civil
// twilight), as (lon, lat) every `stepDeg` degrees round the circle.
std::vector<std::pair<double, double>> sunCircle(const SunPosition &sun, double elevation, double stepDeg = 2);

}  // namespace adif
