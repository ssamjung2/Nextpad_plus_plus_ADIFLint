// Space weather for the Map from NOAA's Space Weather Prediction Center (services.swpc.noaa.gov,
// public domain): the solar flux, the K and A indices, X-rays and the NOAA scales for the solar
// tile, and the OVATION aurora for the Aurora layer. Asked only while the Map shows them and you
// turned space weather on there, every 15 minutes at most (SWPC asks clients to time requests to
// each product's refresh); never in offline mode. ADIFSolarChangedNotification says it changed.
// AppKit and Foundation.
#pragma once

#import <Cocoa/Cocoa.h>

#include "adif_solar.h"

#include <string>

extern NSString *const ADIFSolarChangedNotification;

namespace solar {

// What the Map shows now: the indices (the solar tile, Band Conditions), the aurora. Either
// starts the fetching; neither stops it.
void setWanted(bool indices, bool aurora);
const adif::SpaceWeather &weather();
const adif::AuroraGrid &aurora();
long long updated();   // when the indices last came (Unix seconds); 0 never
std::string status();  // "NOAA SWPC: updated 14:02 UTC (every 15 minutes)", or why not
// Asks again now, unless it asked in the last minute; says what it did.
std::string refreshNow();

}  // namespace solar
