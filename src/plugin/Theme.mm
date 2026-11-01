// The look every panel shares: see Theme.h.
#import "Theme.h"

#import "Night.h"
#include "adif_needs.h"

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
NSColor *fainter() { return NSColor.tertiaryLabelColor; }

NSColor *severity(int s) {
    switch (s) {
        case 3: return fine();
        case 2: return error();
        case 1: return warning();
        case 0: return NSColor.systemBlueColor;
        default: return NSColor.labelColor;
    }
}

NSString *interestSymbol(int kind) {
    using K = adif::InterestKind;
    switch ((K)kind) {
        case K::Watched: return @"star.fill";
        case K::Duplicate: return @"exclamationmark.triangle.fill";
        case K::NewForActivation: return @"checkmark.circle.fill";
        case K::NewDxcc: return @"star.circle.fill";
        case K::NewBand: return @"plus.circle.fill";
        case K::NewMode: return @"plus.circle";
        case K::Worked: return @"checkmark.circle";
        case K::Confirmed: return @"checkmark.circle.fill";
        case K::ParkToPark: return @"leaf.fill";
        case K::NewPark: return @"leaf";
        case K::Before: return @"person.crop.circle";
        case K::FirstQso: return @"person.crop.circle.badge.plus";
    }
    return @"circle";
}

NSColor *markColour(NSString *symbol) {
    if ([symbol isEqualToString:@"star.fill"]) return NSColor.systemYellowColor;
    if ([symbol hasPrefix:@"star"]) return NSColor.systemPinkColor;
    if ([symbol hasPrefix:@"plus"]) return NSColor.systemTealColor;
    if ([symbol hasPrefix:@"leaf"] || [symbol isEqualToString:@"checkmark.circle.fill"]) return fine();  // new for an activation, confirmed
    if ([symbol hasPrefix:@"exclamationmark"]) return error();
    return faint();
}

void host(NSWindow *window) { ADIFNightTrack(window); }

void hostPopover(NSPopover *popover) { ADIFNightTrackPopover(popover); }

void rehost(NSWindow *window) { ADIFNightRetint(window); }

}  // namespace theme
