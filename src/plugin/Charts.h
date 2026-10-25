// Log Summary's charts: QSOs by band, by mode and by continent (bars), over time (a line), by
// UTC hour and weekday (a heat grid), and the DXCC entities, US states and grid squares reached
// (three small lines, each on its own scale).
//
// After the data-visualization guidance this project follows: every chart is one series, so one
// hue (blue, its light and dark steps checked against this window's own background in each
// mode) and no legend, its title saying what it shows; bars at most 24 points thick with 4-point
// rounded ends, square at the baseline; 2-point lines; hairline grid lines in the separator
// colour; values in the text colours, never the series colour; each mark's value in its tooltip;
// the Text view is the table behind them.
// AppKit only.
#pragma once

#import <Cocoa/Cocoa.h>

#include "adif_stats.h"

@interface ADIFChartsView : NSView
- (void)setStats:(const adif::SummaryStats &)stats;
- (NSData *)pngData;  // the charts as they are drawn, for Export PNG
@end
