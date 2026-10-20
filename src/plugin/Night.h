// Night Mode (the ADIF Lint menu): the Map in its Night (red) palette and every ADIF Lint window
// and popover red on black, to keep night vision. Each window's content is drawn dark and through
// a red colour matrix (NSView contentFilters, Core Image's built-in CIColorMatrix); title bars,
// menus and Nextpad++'s own windows are outside a plugin's reach: macOS's Color Filters (Color
// Tint, red) cover the whole screen. Kept in the settings as "nightMode".
// AppKit, Foundation and Core Image.
#pragma once

#import <Cocoa/Cocoa.h>

BOOL ADIFNightMode(void);
void ADIFSetNightMode(BOOL on);  // saved, every tracked window tinted or not, then the notification
extern NSString *const ADIFNightModeChangedNotification;

// An ADIF Lint window, or popover: red now if Night Mode is on, and whenever it changes. Held
// weakly; a window or popover that goes away is forgotten.
void ADIFNightTrack(NSWindow *window);
void ADIFNightTrackPopover(NSPopover *popover);
