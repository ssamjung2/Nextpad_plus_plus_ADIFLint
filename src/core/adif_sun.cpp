#include "adif_sun.h"

#include "adif_projection.h"

#include <cmath>

namespace adif {
namespace {

constexpr double kPi = 3.14159265358979323846;
double rad(double d) { return d * kPi / 180; }
double deg(double r) { return r * 180 / kPi; }
double wrap360(double d) { return d - 360 * std::floor(d / 360); }

}  // namespace

SunPosition sunAt(double unixSeconds) {
    double jd = unixSeconds / 86400.0 + 2440587.5;
    double t = (jd - 2451545.0) / 36525.0;  // Julian centuries since J2000.0
    double l0 = wrap360(280.46646 + t * (36000.76983 + t * 0.0003032));
    double m = 357.52911 + t * (35999.05029 - 0.0001537 * t);
    double e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);
    double c = std::sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t)) + std::sin(rad(2 * m)) * (0.019993 - 0.000101 * t) +
               std::sin(rad(3 * m)) * 0.000289;
    double omega = 125.04 - 1934.136 * t;
    double lambda = l0 + c - 0.00569 - 0.00478 * std::sin(rad(omega));
    double eps0 = 23.0 + (26.0 + (21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813))) / 60.0) / 60.0;
    double eps = eps0 + 0.00256 * std::cos(rad(omega));
    SunPosition s;
    s.declination = deg(std::asin(std::sin(rad(eps)) * std::sin(rad(lambda))));
    double y = std::tan(rad(eps) / 2);
    y *= y;
    double et = y * std::sin(2 * rad(l0)) - 2 * e * std::sin(rad(m)) + 4 * e * y * std::sin(rad(m)) * std::cos(2 * rad(l0)) -
                0.5 * y * y * std::sin(4 * rad(l0)) - 1.25 * e * e * std::sin(2 * rad(m));
    s.eqTime = 4 * deg(et);
    // Noon by the sun where true solar time is 720 minutes: UTC minutes + equation of time + 4 x longitude.
    double minutes = std::fmod(unixSeconds, 86400.0) / 60.0;
    if (minutes < 0) minutes += 1440;
    double lon = (720 - minutes - s.eqTime) / 4;
    s.subLat = s.declination;
    s.subLon = lon - 360 * std::floor((lon + 180) / 360);
    return s;
}

double solarElevation(const SunPosition &sun, double lat, double lon) {
    double cz = std::sin(rad(lat)) * std::sin(rad(sun.declination)) + std::cos(rad(lat)) * std::cos(rad(sun.declination)) * std::cos(rad(lon - sun.subLon));
    return deg(std::asin(std::fmax(-1.0, std::fmin(1.0, cz))));
}

std::vector<std::pair<double, double>> sunCircle(const SunPosition &sun, double elevation, double stepDeg) {
    std::vector<std::pair<double, double>> out;
    double km = rad(90 - elevation) * 6371.0;
    for (double b = 0; b < 360; b += stepDeg) {
        double la, lo;
        destinationPoint(sun.subLat, sun.subLon, b, km, &la, &lo);
        out.emplace_back(lo, la);
    }
    return out;
}

bool nextSunCrossing(double from, double lat, double lon, double elevation, double *at, bool *rising) {
    auto above = [&](double t) { return solarElevation(sunAt(t), lat, lon) - elevation; };
    double prev = above(from);
    for (double t = from + 300; t <= from + 86400 + 300; t += 300) {  // five-minute steps, then halve to the second
        double now = above(t);
        if ((prev < 0) != (now < 0)) {
            double lo = t - 300, hi = t;
            while (hi - lo > 1) {
                double mid = (lo + hi) / 2;
                ((above(mid) < 0) == (prev < 0) ? lo : hi) = mid;
            }
            *at = hi, *rising = prev < 0;
            return true;
        }
        prev = now;
    }
    return false;
}

}  // namespace adif
