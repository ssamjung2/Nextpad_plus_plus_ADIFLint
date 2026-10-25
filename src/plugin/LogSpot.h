// Spotting as New QSO logs a QSO, for each of its two boxes that is ticked (they stay as you
// leave them):
// - the station you worked, on the DX cluster connection (a dx command; never your own callsign:
//   DXSpider's manual asks for the station "you have worked or heard, (ie not your own callsign!)"),
//   when the cluster is connected;
// - yourself, during a POTA activation, on pota.app in your browser (POTA lets activators spot
//   themselves there, and documents no way for programs to post spots).
// Never during a contest (contests limit spotting) or in offline mode; never a station already
// spotted on that band in the last 10 minutes, nor pota.app again for the same park, band and mode
// within 10 minutes.
// AppKit and Foundation.
#pragma once

#import <Cocoa/Cocoa.h>

#include "adif_profiles.h"

#include <string>

namespace logspot {

// What each box can do now, for a QSO with these fields (the window's, then the station's and
// those carried from the last record): whether it can spot, and its tooltip (what it does, or
// why it can't).
struct Ready {
    bool cluster = false, pota = false;
    std::string clusterTip, potaTip;
};
Ready ready(const adif::FieldList &fields, bool contest);

// After logging a QSO with these fields: spots what is ticked and can be. `said` gets what was
// done (nothing ticked or nothing possible: not called), then again when the cluster answers.
void afterLog(const adif::FieldList &fields, bool contest, bool cluster, bool pota, void (^said)(const std::string &text));

// The boxes, saved in ADIFLint.ini ("spotClusterOnLog", "spotPotaOnLog"): off at first.
bool clusterWanted();
bool potaWanted();
void setWanted(bool cluster, bool pota);

}  // namespace logspot
