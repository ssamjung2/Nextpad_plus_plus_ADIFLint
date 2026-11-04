// The Clocks panel: a clock for each time zone you choose (UTC, this Mac's, a city's), each as an
// operating position's status display, in rows as the panel's width allows. The panel's menu
// (Control-click between the clocks) adds and removes clocks; a clock's own menu sets how it
// looks (digital or one of three analog faces, colour, size, label size, 12- or 24-hour, seconds,
// date) and moves it, as dragging it does. The zones are kept in order as `clockZones` ("UTC",
// "local", or IANA names such as "America/Chicago"); each clock's look, where it isn't the first
// one, as `clockLooks` ("America/Chicago style=analog face=dial colour=red;UTC size=large").
// A panel of the console (Panels.h).
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
