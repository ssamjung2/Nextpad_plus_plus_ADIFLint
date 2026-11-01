// The look every panel shares: see Theme.h.
#import "Theme.h"

#import "Night.h"

namespace theme {

NSFont *small(NSFontWeight weight) { return [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:weight]; }

NSFont *body(NSFontWeight weight) { return [NSFont systemFontOfSize:NSFont.systemFontSize weight:weight]; }

NSFont *digits(CGFloat size, NSFontWeight weight) { return [NSFont monospacedDigitSystemFontOfSize:size weight:weight]; }

NSColor *styleAccent(int style) {
    switch (style) {
        case 0: return NSColor.systemPurpleColor;
        case 1: return NSColor.systemOrangeColor;
        case 2: return NSColor.systemRedColor;
        default: return NSColor.systemGreenColor;
    }
}

NSColor *fine() { return NSColor.systemGreenColor; }
NSColor *warning() { return NSColor.systemOrangeColor; }
NSColor *error() { return NSColor.systemRedColor; }
NSColor *faint() { return NSColor.secondaryLabelColor; }

void host(NSWindow *window) { ADIFNightTrack(window); }

void hostPopover(NSPopover *popover) { ADIFNightTrackPopover(popover); }

void rehost(NSWindow *window) { ADIFNightRetint(window); }

}  // namespace theme
