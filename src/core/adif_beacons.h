// The NCDXF/IARU International Beacon Project: 18 beacons taking turns on five bands, each
// sending 10 seconds on a band (its call in CW at 22 WPM, then four 1-second dashes at 100 W,
// 10 W, 1 W and 0.1 W) and then moving up a band, so each band hears all 18 every 3 minutes.
// The roster, frequencies and timing are ncdxf.org's (beacon/index.html and
// beaconlocations.html, read 2026-10-24); the grids are written there with a slashed zero.
#pragma once

#include <cstddef>

namespace adif {

struct Beacon {
    const char *call;
    const char *location;
    const char *grid;  // 6-character Maidenhead locator
};

constexpr size_t kBeaconCount = 18;
constexpr size_t kBeaconBands = 5;
extern const Beacon kBeacons[kBeaconCount];          // in the order they send
extern const double kBeaconMHz[kBeaconBands];         // 14.100, 18.110, 21.150, 24.930, 28.200
extern const char *const kBeaconBandNames[kBeaconBands];  // "20m" ... "10m"

// The beacon sending on band `band` (0 is 14.100 MHz) at a time in seconds since 1970 UTC: the
// 3-minute cycle starts on the hour, 4U1UN on 14.100 MHz first; on each higher band it is the
// beacon before.
size_t beaconOn(size_t band, double unixSeconds);
// The seconds left in the 10-second slot at that time.
double beaconSlotLeft(double unixSeconds);
// The band (0-4) a beacon sends on at that time; kBeaconBands while it is silent (it sends 50
// seconds of every 180).
size_t beaconBand(size_t beacon, double unixSeconds);

}  // namespace adif
