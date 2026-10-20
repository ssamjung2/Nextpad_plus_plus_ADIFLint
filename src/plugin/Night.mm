#import "Night.h"

#import <CoreImage/CoreImage.h>

#include "PluginHost.h"

NSString *const ADIFNightModeChangedNotification = @"ADIFNightModeChanged";

namespace {

NSHashTable<NSWindow *> *gWindows;
NSHashTable<NSPopover *> *gPopovers;

// Each colour to red at its brightness (Rec. 601 weights, a little dimmed); green and blue none.
CIFilter *redMatrix() {
    CIFilter *m = [CIFilter filterWithName:@"CIColorMatrix"];
    [m setDefaults];
    [m setValue:[CIVector vectorWithX:0.27 Y:0.53 Z:0.10 W:0] forKey:@"inputRVector"];
    [m setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0] forKey:@"inputGVector"];
    [m setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0] forKey:@"inputBVector"];
    return m;
}

// Dark, so the backgrounds stay black, and through the red matrix; or back to the system's look.
void tint(NSView *v, BOOL on) {
    if (!v) return;
    if (on) {
        v.wantsLayer = YES;
        v.layerUsesCoreImageFilters = YES;
        v.contentFilters = @[ redMatrix() ];
    } else {
        v.contentFilters = @[];
    }
}

void tintWindow(NSWindow *w, BOOL on) {
    w.appearance = on ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] : nil;
    tint(w.contentView, on);
}

void tintPopover(NSPopover *p, BOOL on) {
    p.appearance = on ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] : nil;
    tint(p.contentViewController.view, on);
}

}  // namespace

BOOL ADIFNightMode(void) { return adifhost::setting("nightMode") == "1"; }

void ADIFSetNightMode(BOOL on) {
    adifhost::setSetting("nightMode", on ? "1" : "0");
    for (NSWindow *w in gWindows) tintWindow(w, on);
    for (NSPopover *p in gPopovers) tintPopover(p, on);
    [[NSNotificationCenter defaultCenter] postNotificationName:ADIFNightModeChangedNotification object:nil];
}

void ADIFNightTrack(NSWindow *window) {
    if (!window) return;
    if (!gWindows) gWindows = [NSHashTable weakObjectsHashTable];
    [gWindows addObject:window];
    if (ADIFNightMode()) tintWindow(window, YES);
}

void ADIFNightTrackPopover(NSPopover *popover) {
    if (!popover) return;
    if (!gPopovers) gPopovers = [NSHashTable weakObjectsHashTable];
    [gPopovers addObject:popover];
    if (ADIFNightMode()) tintPopover(popover, YES);
}
