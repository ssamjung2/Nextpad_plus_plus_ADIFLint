// One look for every panel (docs/WINDOWING_ARCHITECTURE.md, "Theming"): the spacing, type and
// colour tokens panels draw with, and the appearance (the system's light or dark, Night Mode's
// red) applied by whatever hosts a panel. A window that docks (ADIF_DOCKABLE_WINDOW) is hosted
// when it shows, with no call of its own; docked in the Operating Console it takes the
// console's look, so its content is themed once, by the console.
#pragma once

#import <Cocoa/Cocoa.h>

namespace theme {

// Spacing.
inline constexpr CGFloat kMargin = 14;  // a window's edge to its content; between groups
inline constexpr CGFloat kSpacing = 8;  // between the controls of a row

// Type: the system font at the system's sizes.
NSFont *small(NSFontWeight weight = NSFontWeightRegular);  // secondary text, frame headers, status bars, tables' notes
NSFont *body(NSFontWeight weight = NSFontWeightRegular);
NSFont *digits(CGFloat size, NSFontWeight weight = NSFontWeightRegular);  // monospaced digits: clocks, frequencies, counts

// Semantic colours (the system's, so they follow light, dark and Increase Contrast).
NSColor *styleAccent(int style);  // an operating style's own, by adif::styles order: Social purple, Chasing orange, Contest red, Portable green
NSColor *fine();                  // done: worked, confirmed, saved
NSColor *warning();
NSColor *error();
NSColor *faint();  // hints and status lines

// Hosting: each window and popover the plugin shows, themed now and whenever Night Mode changes
// (held weakly). Hosting again does nothing more.
void host(NSWindow *window);
void hostPopover(NSPopover *popover);
// A window just docked in the console, or given its content back: the console's look, or its own.
void rehost(NSWindow *window);

}  // namespace theme
