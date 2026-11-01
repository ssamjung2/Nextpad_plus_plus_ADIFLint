// The Operating Console (Start Logging): New QSO, Log Table, Map, Spots, contact map and QSO details as frames of one window. Each is still
// the window it was (its code unchanged); while the layout is open its content is shown in a
// frame of the layout's window, and the window's own calls (show, close, visible, first
// responder, title) are answered for the frame.
#pragma once

#import <Cocoa/Cocoa.h>

#include <functional>
#include <string>
#include <utility>
#include <vector>

enum ADIFDockItem { kDockNone = 0, kDockMap, kDockLog, kDockNewQso, kDockSpots, kDockContactMap, kDockQsoInfo, kDockCount };
constexpr int kWorkspaceFrameCount = 5;

@protocol ADIFDockable <NSObject>
@property(nonatomic) int dockItem;                   // an ADIFDockItem; kDockNone: never docks
@property(nonatomic, weak) NSWindow *dockHost;       // the layout's window while docked
@end

namespace workspace {

bool active();  // the layout's window is open
// The menu command: open the layout, or close it. open() puts up the window and shows each item
// it holds (through setOpener); they dock themselves.
bool open();  // false when New QSO would not open (it says why) and the layout is not
bool openActivation();  // the activation preset: New QSO and its log, spots, contact map and details
bool openLogging();  // restore the focused New QSO, interactive Map and Log Table layout
void abandon();
void close();
NSMenuItem *optionsMenuItem();
void retitleMenu();
// How an item's window is created and shown (its menu command), for a frame's item choice.
void setOpener(int item, std::function<void()> open);
// Told when the layout opens or closes.
void setOnChange(std::function<void(bool active)> onChange);
// The status bar's text (the log, what was last done); the UTC time sits beside it.
void setStatus(const std::string &text);
void setQsoFields(const std::vector<std::pair<std::string, std::string>> &fields);
// What QSO Details shows of the contact being logged (ADIFLint.mm works it out from New QSO, its
// lookup and the log): who it is and where, why it is worth having (adif::contactInterest), the
// lookup's facts, this QSO, and your QSOs with the call.
struct QsoDetails {
    std::string call, who, where;                            // "K9ABC", "Ann Smith", "Madison, WI · United States"
    std::vector<std::pair<int, std::string>> why;            // an adif::InterestKind and its text
    std::vector<std::pair<std::string, std::string>> facts;  // the lookup's: label, value
    std::string qso;                                         // "20m · 14.062 MHz · CW · 599 sent, 579 received"
    std::vector<std::string> history;                        // your QSOs with the call, newest first
};
void setQsoDetails(const QsoDetails &details);
bool qsoDetailsShown();  // QSO Details is open, docked or not: worth working out
void openContactMap();
void openQsoInfo();
bool contactMapShown();  // the Contact Map is open, docked or not
void toggleContactMap();  // open it, or close it when it shows (the Map's toolbar button)
void toggleQsoDetails();  // QSO Details the same

// The docked windows' own calls (ADIF_DOCKABLE_WINDOW): true when the layout answered.
bool show(NSWindow<ADIFDockable> *window);
bool hide(NSWindow<ADIFDockable> *window, bool closing);
bool visible(NSWindow<ADIFDockable> *window);
void retitle(NSWindow<ADIFDockable> *window);
// What the window shows: while docked its content sits in a frame, not in the window.
NSView *content(NSWindow<ADIFDockable> *window);

}  // namespace workspace

// The panel the tool windows are.
@interface ADIFDockPanel : NSPanel <ADIFDockable>
@end

// A normal window that docks: New QSO (HIG: no typing in floating panels).
@interface ADIFDockWindow : NSWindow <ADIFDockable>
@end

// For an NSWindow or NSPanel subclass that docks: declare <ADIFDockable> and put this in its
// @implementation.
#define ADIF_DOCKABLE_WINDOW                                                                                    \
    @synthesize dockItem = _dockItem;                                                                          \
    @synthesize dockHost = _dockHost;                                                                          \
    -(NSView *)contentView {                                                                                   \
        NSView *docked = _dockHost ? workspace::content(self) : nil;                                           \
        return docked ?: [super contentView];                                                                  \
    }                                                                                                          \
    -(BOOL)isVisible { return _dockHost ? workspace::visible(self) : [super isVisible]; }                      \
    -(void)makeKeyAndOrderFront : (id)sender {                                                                 \
        if (!workspace::show(self)) [super makeKeyAndOrderFront:sender];                                       \
    }                                                                                                          \
    -(void)orderFront : (id)sender {                                                                           \
        if (!workspace::show(self)) [super orderFront:sender];                                                 \
    }                                                                                                          \
    -(void)orderOut : (id)sender {                                                                             \
        if (!workspace::hide(self, false)) [super orderOut:sender];                                            \
    }                                                                                                          \
    -(void)close {                                                                                             \
        if (!workspace::hide(self, true)) [super close];                                                       \
    }                                                                                                          \
    -(void)performClose : (id)sender {                                                                         \
        if (!workspace::hide(self, true)) [super performClose:sender];                                         \
    }                                                                                                          \
    -(BOOL)makeFirstResponder : (NSResponder *)responder {                                                     \
        return _dockHost ? [_dockHost makeFirstResponder:responder] : [super makeFirstResponder:responder];    \
    }                                                                                                          \
    -(NSScreen *)screen { return _dockHost ? _dockHost.screen : [super screen]; }                              \
    -(void)setTitle : (NSString *)title {                                                                      \
        [super setTitle:title];                                                                                \
        workspace::retitle(self);                                                                              \
    }
