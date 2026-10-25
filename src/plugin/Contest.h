// Contests in New QSO: ARRL Field Day, Winter Field Day, serial numbers, or a contest known by its
// rules (CQ WW, WPX, ARRL DX, IARU, Sweepstakes, NAQP, Sprint, 10 and 160 m, a QSO party). The
// Contest window chooses one and your exchange; New QSO then asks for the other
// station's exchange, writes the contest's fields and warns of duplicates by its
// rule (adif_contest.h).
#pragma once

#import <Cocoa/Cocoa.h>

#include "adif_contest.h"

#include <string>

namespace contest {

void cmdContest();           // the Contest window
adif::ContestSetup setup();  // the running contest (preset None when there is none)
std::string label();         // "ARRL Field Day, sending 1D IL", or ""
void documentChanged();      // the log changed: the window's counts follow

}  // namespace contest
