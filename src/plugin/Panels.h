// The panels (docs/WINDOWING_ARCHITECTURE.md): each operating panel once, by the stable id the
// layouts use (adif_layout.h), with how to open it, close it and ask whether it shows, as a
// window of its own or a frame of the Operating Console. Every control that shows or hides a
// panel goes through here, so none keeps a state of its own: the Map's toolbar buttons, the
// Panels menu (Show and Hide), and next the console's frames and layouts.
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>

namespace panels {

struct Spec {
    const char *id;        // adif::layout's
    NSString *title;       // English, for T()
    NSString *symbol;      // its SF Symbol, in the menu and the toolbar
    NSString *tip;         // English, for T(): its toolbar button's tooltip
    NSString *identifier;  // its toolbar button's
    bool mapToolbar;       // a button in the Map's toolbar (not the Map's own)
};
const std::vector<Spec> &all();  // in the Panels menu's order
const Spec *find(const std::string &id);

bool shown(const std::string &id);
// Show it (opened, or brought forward when it shows) or close it.
void setShown(const std::string &id, bool on);
void toggle(const std::string &id);

// The Panels menu, for the plugin's menu: Show <Panel> or Hide <Panel>, as each is now.
NSMenuItem *menuItem();

}  // namespace panels
