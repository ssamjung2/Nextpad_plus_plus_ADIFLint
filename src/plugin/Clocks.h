// The Clocks panel: a clock for each time zone you choose (UTC, this Mac's, a city's), each as an
// operating position's status display, in rows as the panel's width allows. Add Clock chooses
// another; a clock's own menu moves or removes it. The zones are kept as `clockZones` ("UTC",
// "local", or IANA names such as "America/Chicago"). A panel of the console (Panels.h).
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>

namespace clocks {
bool shown();
void open();
void close();
std::vector<std::string> zones();  // in order; UTC and local time when none are chosen
}  // namespace clocks
