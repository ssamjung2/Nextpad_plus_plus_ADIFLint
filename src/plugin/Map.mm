#import "Map.h"
#import "Night.h"
#import "ParkOutlines.h"
#import "L10n.h"
#import "MapView.h"

#import "Country.h"
#import "IotaGroups.h"
#import "LotwUsers.h"
#import "LogTools.h"
#import "Network.h"
#import "PotaParks.h"
#import "PluginHost.h"
#import "Solar.h"
#import "Spots.h"
#import "Uploads.h"
#import "ToolWindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "adif_detail.h"
#include "adif_beacons.h"
#include "adif_edit.h"
#include "adif_flags.h"
#include "adif_geo.h"
#include "adif_worked.h"
#include "adif_regions.h"
#include "adif_palette.h"
#include "adif_projection.h"
#include "adif_spec.h"
#include "adif_sun.h"
#include "adif_world.h"

#include <algorithm>
#include <cmath>
#include <dlfcn.h>
#include <functional>
#include <fstream>
#include <sstream>
#include <map>
#include <set>
#include <tuple>

using namespace adifhost;

using namespace mapkit;


// The list beside the map (the QSOs chosen; the contacts, parks or spots in view): a row each,
// what it is on the map, where, its colour; its texts come from `text`, by column. A click
// chooses it on the map, a double-click opens it (zooms to it, or goes to the QSO).
struct ADIFViewRow {
    ADIFMapHit hit;                 // what choosing it chooses on the map (None: nothing)
    size_t item = 0;                // into the list's data: a QSO, a park, a spot
    double lat = 0, lon = 0;        // where it is
    double km = -1, bearing = 0;    // from where the list measures; km < 0: not placed
    double span = 0.03;             // how far round it a double-click shows (degrees)
    NSColor *color = nil;
    bool tree = false;              // its mark POTA's tree (a POTA activator's spot), else a dot
};

// A list row's mark: POTA's tree in a colour, as text (an attachment), for a POTA activator's spot.
static NSAttributedString *treeMark(NSColor *color) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(11, 12)
                                    flipped:NO
                             drawingHandler:^BOOL(NSRect) {
                                 [color setFill];
                                 [ADIFTreePath(NSMakePoint(5.5, 6), 12) fill];
                                 return YES;
                             }];
    image.accessibilityDescription = T(@"POTA");
    NSTextAttachment *a = [[NSTextAttachment alloc] init];
    a.image = image;
    a.bounds = NSMakeRect(0, -2, 11, 12);
    return [NSAttributedString attributedStringWithAttachment:a];
}

@interface ADIFViewList : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
@property(nonatomic) std::vector<ADIFViewRow> rows;  // the page shown
@property(nonatomic) std::map<std::string, int> styles;  // a column's: 0 text, 1 digits, 2 digits on the right
@property(nonatomic) BOOL quiet;     // the map chose the row: don't tell it back
@property(nonatomic) BOOL building;  // the columns are being set: their moves and sizes aren't the user's
@property(nonatomic, copy) NSString * (^text)(const ADIFViewRow &row, const std::string &column);
@property(nonatomic, copy) void (^onChoose)(const ADIFViewRow &row);
@property(nonatomic, copy) void (^onOpen)(const ADIFViewRow &row);
@property(nonatomic, copy) void (^onSort)(void);
@property(nonatomic, copy) void (^onColumnsChanged)(void);
@property(nonatomic, copy) void (^fillMenu)(NSMenu *menu);  // the header's menu: which columns show
@end

@implementation ADIFViewList
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    return (NSInteger)_rows.size();
}
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSTextField *f = [t makeViewWithIdentifier:col.identifier owner:self];
    if (!f) {
        f = [NSTextField labelWithString:@""];
        f.identifier = col.identifier;
        f.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    std::string column = ADIFStd(col.identifier);
    bool mark = column == "mark";
    auto st = _styles.find(column);
    int style = mark || st == _styles.end() ? 0 : st->second;
    f.alignment = style == 2 ? NSTextAlignmentRight : NSTextAlignmentLeft;
    f.font = style ? [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular]
                   : [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    f.textColor = NSColor.labelColor;
    if (row < 0 || (size_t)row >= _rows.size()) return f;
    const ADIFViewRow &r = _rows[(size_t)row];
    if (mark && r.tree) {
        f.attributedStringValue = treeMark(r.color ?: NSColor.secondaryLabelColor);
    } else if (mark) {
        f.stringValue = r.color ? @"●" : @"";
        f.textColor = r.color ?: NSColor.secondaryLabelColor;
    } else {
        f.stringValue = self.text ? self.text(r, column) : @"";
    }
    return f;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSTableView *t = n.object;
    if (_quiet || t.selectedRow < 0 || (size_t)t.selectedRow >= _rows.size()) return;
    if (self.onChoose) self.onChoose(_rows[(size_t)t.selectedRow]);
}
- (void)tableView:(NSTableView *)t sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old {
    if (!_building && self.onSort) self.onSort();
}
- (void)tableViewColumnDidMove:(NSNotification *)n {
    if (!_building && self.onColumnsChanged) self.onColumnsChanged();
}
- (void)tableViewColumnDidResize:(NSNotification *)n {
    if (!_building && self.onColumnsChanged) self.onColumnsChanged();
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (self.fillMenu) self.fillMenu(menu);
}
- (void)opened:(id)sender {
    NSTableView *t = sender;
    NSInteger row = t.clickedRow >= 0 ? t.clickedRow : t.selectedRow;  // the row double-clicked, else the one chosen
    if (row >= 0 && (size_t)row < _rows.size() && self.onOpen) self.onOpen(_rows[(size_t)row]);
}
@end

// The Map's control groups: laid out left to right at their own sizes, a new line when the next
// doesn't fit, with a thin line between neighbours and between lines; as tall as its lines.
// A filter's popup that names what it filters while it filters ("Band: 20m"; "All bands" as it is).
@interface ADIFPrefixPopUpCell : NSPopUpButtonCell
@property(nonatomic, copy) NSString *prefix;
@end

@implementation ADIFPrefixPopUpCell
- (NSAttributedString *)shown:(NSAttributedString *)title {
    if (!self.prefix.length || self.indexOfSelectedItem <= 0 || !title.length) return title;
    NSMutableAttributedString *t = [title mutableCopy];
    [t insertAttributedString:[[NSAttributedString alloc] initWithString:[self.prefix stringByAppendingString:@" "]
                                                              attributes:[title attributesAtIndex:0 effectiveRange:nil]]
                      atIndex:0];
    return t;
}
- (NSRect)drawTitle:(NSAttributedString *)title withFrame:(NSRect)frame inView:(NSView *)view {
    // The frame is the item's own title's width: the prefix needs the room the popup has (less its arrows).
    if (self.prefix.length && self.indexOfSelectedItem > 0) frame.size.width = std::max(frame.size.width, NSWidth(view.bounds) - frame.origin.x - 18);
    return [super drawTitle:[self shown:title] withFrame:frame inView:view];
}
- (NSSize)cellSize {
    NSSize size = [super cellSize];
    if (self.prefix.length && self.indexOfSelectedItem > 0)
        size.width += std::ceil([[self.prefix stringByAppendingString:@" "] sizeWithAttributes:@{NSFontAttributeName : self.font ?: [NSFont systemFontOfSize:0]}].width);
    return size;
}
@end

@interface ADIFFlowView : NSView
@property(nonatomic) CGFloat gap;          // between neighbours; the line runs down its middle
@property(nonatomic) BOOL trailingLast;    // the last one at the right end of its line
@property(nonatomic) BOOL centred;         // each centred in its line's height (else at its top)
@property(nonatomic) BOOL plain;           // no lines between them
@end

@implementation ADIFFlowView {
    CGFloat _height;
    std::vector<NSRect> _rules;
}
- (BOOL)isFlipped {
    return YES;
}
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, _height);
}
- (void)layout {
    [super layout];
    CGFloat width = self.bounds.size.width, x = 0, y = 0, lineHeight = 0;
    std::vector<NSRect> rules;
    std::vector<CGFloat> lineStarts;  // the x of each line's vertical rules, to size them when the line ends
    std::vector<NSView *> lineViews;
    auto endLine = [&]() {
        for (CGFloat rx : lineStarts) rules.push_back(NSMakeRect(rx, y, 1, lineHeight));
        if (_centred)
            for (NSView *lv : lineViews) [lv setFrameOrigin:NSMakePoint(lv.frame.origin.x, std::round(y + (lineHeight - lv.frame.size.height) / 2))];
        lineStarts.clear();
        lineViews.clear();
    };
    NSView *last = self.subviews.lastObject;
    for (NSView *v in self.subviews) {
        if (v.hidden) continue;
        NSSize size = v.fittingSize;
        if (x > 0 && x + size.width > width) {
            endLine();
            y += lineHeight + _gap;
            rules.push_back(NSMakeRect(0, y - _gap / 2, width, 1));
            x = 0, lineHeight = 0;
        }
        if (_trailingLast && v == last && x > 0) x = std::max(x, width - size.width);  // pushed to the right, its rule with it
        if (x > 0) lineStarts.push_back(std::round(x - _gap / 2));
        v.frame = NSMakeRect(x, y, size.width, size.height);
        lineViews.push_back(v);
        x += size.width + _gap;
        lineHeight = std::max(lineHeight, size.height);
    }
    endLine();
    CGFloat height = y + lineHeight;
    _rules = rules;
    self.needsDisplay = YES;
    if (std::fabs(height - _height) > 0.5) {
        _height = height;
        [self invalidateIntrinsicContentSize];
    }
}
- (void)drawRect:(NSRect)dirty {
    if (_plain) return;
    [[NSColor.separatorColor colorWithAlphaComponent:0.9] setFill];
    for (const NSRect &r : _rules) NSRectFill(r);
}
@end

// The Map's window: its shortcuts before the app's menus see them.
@interface ADIFMapWindow : NSPanel
@property(nonatomic, copy) BOOL (^shortcut)(NSEvent *event);
@end

@implementation ADIFMapWindow
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.shortcut && self.shortcut(event)) return YES;
    return [super performKeyEquivalent:event];
}
@end

// A panel floating on the map (its bar, the cards under it, the zoom buttons): translucent and
// rounded, with a hairline edge, light or dark as the map is so that its controls read against
// it. Clicks, scrolls and pinches on it stay on it, off the map.
@interface ADIFMapPanel : NSView
@end

@implementation ADIFMapPanel
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [NSColor colorWithCalibratedWhite:0 alpha:0.28];
        shadow.shadowBlurRadius = 6;
        shadow.shadowOffset = NSMakeSize(0, -1);
        self.shadow = shadow;
    }
    return self;
}
- (void)drawRect:(NSRect)dirty {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:9 yRadius:9];
    [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.8] setFill];
    [p fill];
    [NSColor.separatorColor setStroke];
    [p stroke];
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}
- (BOOL)mouseDownCanMoveWindow {
    return NO;
}
- (void)mouseDown:(NSEvent *)event {
}
- (void)rightMouseDown:(NSEvent *)event {
}
- (void)scrollWheel:(NSEvent *)event {
}
- (void)magnifyWithEvent:(NSEvent *)event {
}
@end

// The Quick Views at the top of the Map's sidebar: a row each (a symbol, its name, how many of
// it there are), one chosen at a time.
struct ADIFQuickRow {
    std::string title, count, tip;
    NSString *symbol = nil;
    unsigned colour = 0;  // 0: the secondary label colour
};

@interface ADIFQuickViews : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic) std::vector<ADIFQuickRow> rows;
@property(nonatomic, copy) void (^onChoose)(NSInteger row);
@property(nonatomic) BOOL filling;  // the rows are being set: a selection then is not a choice
@end

@implementation ADIFQuickViews
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    return (NSInteger)_rows.size();
}
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTableCellView *cell = [t makeViewWithIdentifier:@"quick" owner:self];
    NSTextField *count = nil;
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"quick";
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        icon.imageScaling = NSImageScaleProportionallyDown;
        NSTextField *title = [NSTextField labelWithString:@""];
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        count = [NSTextField labelWithString:@""];
        count.identifier = @"count";
        count.alignment = NSTextAlignmentRight;
        count.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        count.textColor = NSColor.secondaryLabelColor;
        [count setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        for (NSView *v in @[ icon, title, count ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:v];
        }
        cell.imageView = icon;
        cell.textField = title;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:16],
            [icon.heightAnchor constraintEqualToConstant:16],
            [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:7],
            [title.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:count.leadingAnchor constant:-6],
            [count.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [count.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    for (NSView *v in cell.subviews)
        if ([v.identifier isEqualToString:@"count"]) count = (NSTextField *)v;
    if ((size_t)row >= _rows.size()) return cell;
    const ADIFQuickRow &r = _rows[(size_t)row];
    cell.imageView.image = r.symbol ? [NSImage imageWithSystemSymbolName:r.symbol accessibilityDescription:nil] : nil;
    cell.imageView.contentTintColor = r.colour ? [NSColor colorWithSRGBRed:((r.colour >> 16) & 255) / 255.0
                                                                     green:((r.colour >> 8) & 255) / 255.0
                                                                      blue:(r.colour & 255) / 255.0
                                                                     alpha:1]
                                               : NSColor.secondaryLabelColor;
    cell.textField.stringValue = ADIFString(r.title);
    count.stringValue = ADIFString(r.count);
    cell.toolTip = ADIFString(r.tip);
    return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSTableView *t = n.object;
    if (!_filling && self.onChoose && t.selectedRow >= 0) self.onChoose(t.selectedRow);
}
@end

// A view whose content starts at its top: the Map's sidebars scroll down from there.
@interface ADIFMapColumnView : NSView
@end

@implementation ADIFMapColumnView
- (BOOL)isFlipped {
    return YES;
}
@end

// Keeps the Map's split views sensible (the map never squeezed out, the sidebars and the list
// within reach of a drag) and remembers where their dividers were left.
@interface ADIFSplitKeeper : NSObject <NSSplitViewDelegate>
@property(nonatomic) CGFloat leastSidebar;  // as wide as its layers' grid and menus need, in the language shown
@property(nonatomic, copy) void (^onMoved)(NSSplitView *split);
@end

@implementation ADIFSplitKeeper
// The body: sidebar | map and list | selected (dividers 0 and 1); the middle: map over list.
- (CGFloat)splitView:(NSSplitView *)s constrainMinCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)i {
    if (!s.vertical) return std::max(proposed, (CGFloat)240);  // the map keeps this much height
    if (i == 0) return std::max(proposed, std::max(self.leastSidebar, (CGFloat)280));  // the sidebar as wide as its layers' grid
    NSView *left = s.arrangedSubviews.firstObject;
    return std::max(proposed, (left.hidden ? 0 : NSMaxX(left.frame)) + 420);  // the map at least 420 wide
}
- (CGFloat)splitView:(NSSplitView *)s constrainMaxCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)i {
    CGFloat whole = s.vertical ? s.bounds.size.width : s.bounds.size.height;
    if (!s.vertical) return std::min(proposed, whole - 110);  // the list keeps this much
    if (i == 1) return std::min(proposed, whole - 240);       // the selected panel at least this wide
    NSView *right = s.arrangedSubviews.lastObject;
    return std::min({proposed, (CGFloat)380, (right.hidden ? whole : NSMinX(right.frame)) - 420});
}
- (BOOL)splitView:(NSSplitView *)s canCollapseSubview:(NSView *)v {
    return NO;
}
// The window resized: the map (and its list) take the change, the sidebar and the selected panel
// keep their widths and the list its height (scaled with the rest, they went under their least).
- (BOOL)splitView:(NSSplitView *)s shouldAdjustSizeOfSubview:(NSView *)v {
    if (!s.vertical) return v != s.arrangedSubviews.lastObject;
    return v != s.arrangedSubviews.firstObject && v != s.arrangedSubviews.lastObject;
}
- (void)splitViewDidResizeSubviews:(NSNotification *)n {
    if (self.onMoved) self.onMoved(n.object);
}
@end

// Completions for a token field: the candidates that start with what was typed, then those that
// contain it.
@interface ADIFTokenCompleter : NSObject <NSTokenFieldDelegate>
@property(nonatomic, copy) NSArray<NSString *> *candidates;
@end

@implementation ADIFTokenCompleter
- (NSArray *)tokenField:(NSTokenField *)tokenField
    completionsForSubstring:(NSString *)substring
               indexOfToken:(NSInteger)tokenIndex
        indexOfSelectedItem:(NSInteger *)selectedIndex {
    NSMutableArray *starts = [NSMutableArray array], *contains = [NSMutableArray array];
    for (NSString *c in _candidates) {
        NSRange r = [c rangeOfString:substring options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
        if (r.location == 0) [starts addObject:c];
        else if (r.location != NSNotFound) [contains addObject:c];
        if (starts.count >= 40) break;
    }
    [starts addObjectsFromArray:[contains subarrayWithRange:NSMakeRange(0, std::min<NSUInteger>(contains.count, 40 - std::min<NSUInteger>(40, starts.count)))]];
    if (selectedIndex) *selectedIndex = starts.count ? 0 : -1;
    return starts;
}
@end

namespace worldmap {
namespace {

// What the list under the map lists.
enum ListKind { kListSelected, kListContacts, kListParks, kListSpots, kListRecent, kListIssues, kListDxcc };
const int kListKinds = 7;

// A problem Check Log finds in one of the QSOs the map shows (the list's Issues).
struct ADIFIssue {
    size_t qso = 0;     // into MapData::qsos
    bool error = true;  // else a warning
    std::string field, message;
    size_t start = 0;   // where it is in the log (bytes)
};

// A station on your watch list, spotted (the bell lists them).
struct ADIFWatchedSpot {
    std::string call, band, khz, mode, what;  // what: on the list for (adif::watchedFor)
    long long epoch = 0;
};

struct {
    NSPanel *window = nil;
    ADIFMapView *view = nil;
    NSButton *show[kLayerCount] = {}, *overlay[kLayerCount] = {}, *labels[kLayerCount] = {};  // the layers' boxes (no Show for cities)
    NSButton *contacts = nil, *lines = nil, *mine = nil;
    NSPopUpButton *programs = nil, *projection = nil, *colorBy = nil, *region = nil;
    NSPanel *styleWindow = nil;  // Style Options
    NSTimer *sunTimer = nil;     // day and night, while it shows now
    NSPopUpButton *band = nil, *mode = nil, *dates = nil, *confirmed = nil;
    NSTextField *status = nil, *zoomLabel = nil;
    NSTextField *situation = nil;  // the status bar's right side: the log and the spots, for the operator
    NSTextField *slots = nil;      // the contact's DXCC entity's band slots, under its description
    NSTextField *contactTitle = nil;  // what the contact panel is about, in bold, over its description
    NSTextField *today = nil, *air = nil, *wantedLabel = nil;
    NSStackView *wanted = nil;     // the spots most wanted, as links
    NSView *statHost = nil;        // the log at a glance (a table made afresh each time): a row a layer, worked and confirmed
    ADIFMapHit chosenHit;          // what was clicked last (the contact panel shows it when the pointer is on nothing)
    NSSplitView *bodySplit = nil, *middleSplit = nil;  // sidebar | map and list | selected; the map over the list
    ADIFSplitKeeper *splitKeeper = nil;
    bool splitsRestored = false;
    // The workflows (History: the log; Live: the spots), the sidebar with its Quick Views and
    // sections, the selected panel, the zoom buttons on the map, and the footer.
    NSSegmentedControl *workflow = nil;
    NSView *sidebar = nil, *selectedPanel = nil, *nav = nil, *spotsSection = nil;
    NSButton *paneToggle[3] = {};  // the sidebar, the list, the selected panel
    NSButton *focusButton = nil;    // the toolbar's Focus Map: the panes hidden, or back
    bool focusRestore[3] = {};      // the panes Focus Map hid, to show again
    NSMutableDictionary<NSString *, NSView *> *sections = nil;  // a section's body, by its name
    NSMutableDictionary<NSString *, NSButton *> *sectionTriangles = nil;
    NSMutableDictionary<NSString *, NSTextField *> *sectionTitles = nil;
    // The Layers section's groups (areas, programs, places, contacts, sun), each closed on its
    // own: its grid rows or views, and its triangle.
    NSMutableDictionary<NSString *, NSArray *> *layerGroups = nil;
    NSMutableDictionary<NSString *, NSButton *> *layerGroupTriangles = nil;
    NSButton *otherBox = nil;              // Other programs' row: any of them shown
    NSMutableArray<NSMenu *> *layerMenus = nil;  // each layer name's own (right-click)
    NSSegmentedControl *paletteBar = nil;  // the Map section's palettes, one click each
    NSTableView *quickTable = nil;
    ADIFQuickViews *quickRows = nil;
    NSLayoutConstraint *quickHeight = nil;
    NSMenu *viewsMenu = nil;          // a Quick View's own (right-click): remove one of yours
    NSPopover *saveViewPopover = nil;  // Save View...: its name
    NSTextField *saveViewName = nil;
    NSTextField *hover = nil, *summaryLabel = nil, *scopeLabel = nil;
    NSButton *liveLabel = nil;  // the footer's live status, a dot of its colour; clicked, the feeds' state
    NSPopUpButton *continentPopup = nil;  // the toolbar's continent (one of More Filters' continents)
    NSPopUpButton *spotAgeBar = nil, *spotSourceBar = nil;  // Live's: how new the spots, from which source (as Sources and Filters)
    NSPopUpButton *dxccBar = nil, *potaBar = nil;          // Live's: which DXCC needs (the Quick View), which program
    NSButton *synced = nil;                                 // the header's last QSL Sync download, a click opens it
    NSStackView *chips = nil;             // the filters on that the toolbar doesn't show, each a tag that removes it
    NSButton *centerButton = nil;
    NSButton *greyLineBox = nil, *dayNightBox = nil;  // the sidebar's Sun boxes (Style Options has them too)
    NSButton *auroraBox = nil, *beaconsBox = nil, *heatBox = nil;  // the sidebar's propagation layers
    NSButton *solarTile = nil;     // the header's space weather (NOAA SWPC)
    NSPopover *solarPopover = nil;
    NSTimer *beaconTimer = nil;    // redraws as the beacons take turns
    id solarObserver = nil;
    // The selected panel's parts: what kind of thing it is, a line under its name, its facts, and
    // for a spot why it's worth working.
    NSTextField *chosenBadge = nil, *chosenSubtitle = nil;
    NSGridView *chosenFacts = nil;
    NSButton *viewQso = nil;         // the one QSO chosen, in the log
    NSView *actions = nil;           // Center, View QSO, Watch: laid out again as they show and hide
    NSView *recentHost = nil;        // Live's newest spots, a row each (made afresh)
    NSView *recentSection = nil;     // their caption and View all spots
    NSView *bandHost = nil, *bandSection = nil;  // Band conditions (Live): a table a band (made afresh), its line, its caption
    NSView *awardsHost = nil, *awardsSection = nil;  // Awards (History): a row an award, made afresh
    NSTextField *bandLine = nil;
    NSView *whyBox = nil;
    NSStackView *whyList = nil;
    NSView *detailsSection = nil, *detailsBody = nil;  // a spot's Details: who heard it, your QSOs with it, its references, its entity
    NSTextField *detailsText = nil;
    NSView *bandBody = nil;  // Band conditions' body, opened by a reason's arrow
    int markedDxcc = 0;      // the entity a reason's arrow marked in the list's DXCC (what is chosen on the map stays)
    ADIFMapHit markedFor;    // while this stays chosen
    int spotLens = 0;          // Live's Quick View: which of the spots show
    size_t lensCounts[9] = {};  // how many stations each of Live's views has (kLiveViews)
    bool applyingView = false;  // a Quick View is setting the layers: not a change of the user's own
    bool viewSetConfirmed = false;  // History's Needs confirmation set the Confirmed menu (and puts it back)
    // The watch list: the selected panel's Watch, its editor (the Spots section), and the header's
    // bell, with the watched stations spotted (those not seen since it was last opened tint it).
    NSButton *watchButton = nil, *watchEdit = nil, *bell = nil;
    NSMenu *bellMenu = nil;
    NSMenu *homeMenu = nil;  // the Home button's own: set or forget the Home view
    NSSearchField *findField = nil;  // the header's search: a call, grid square, DXCC entity or park, found on the map
    NSMenu *findMenu = nil;          // what it found, when more than one
    NSPopover *watchPopover = nil;
    NSTokenField *watchTokens = nil;
    std::vector<ADIFWatchedSpot> watchedSpots;  // newest first, whichever Quick View is chosen
    std::set<std::string> bellSeen;             // "call|band" of those listed when the bell was last opened
    long long newestSpot = 0;                   // the newest spot of all, for whether the feeds went quiet
    // More Filters: places.
    NSButton *moreFilters = nil, *clearFilters = nil;
    NSPopover *filterPopover = nil;
    NSButton *continent[7] = {}, *parksToo = nil;
    NSTokenField *dxccTokens = nil, *stateTokens = nil, *countyTokens = nil, *potaTokens = nil;
    NSTextField *cqField = nil, *ituField = nil;
    NSTextField *withinField = nil, *withinUnits = nil;  // within so far of your station
    NSPopUpButton *recordsPopup = nil;                   // which records: all, without a square, duplicates, with problems
    NSPopover *datesPopover = nil;                       // the dates menu's Custom Range
    NSDatePicker *dateFrom = nil, *dateTo = nil;
    NSPopUpButton *regions = nil;
    NSMutableArray *completers = nil;
    // Spots: the popover of their own filters, Refresh, Use in New QSO, and what tells the Map of new ones.
    NSButton *spotsButton = nil, *refreshSpotsButton = nil, *useSpot = nil, *spotsOnly = nil;
    NSTextField *spotsOnlyCall = nil;
    NSPopover *spotsPopover = nil;
    NSPopUpButton *spotAge = nil, *spotProgram = nil;
    NSButton *spotSource[3] = {};
    NSTextField *spotStatus = nil;
    id spotsObserver = nil, closeObserver = nil;
    // The list beside the map: what it lists (the QSOs chosen; the contacts, parks or spots in
    // view), from where, sorted how, which page, and what places it.
    NSView *listPanel = nil;
    NSSegmentedControl *listKind = nil, *listUnits = nil;
    NSTextField *listTitle = nil, *listHint = nil, *listGrid = nil, *listPageLabel = nil;
    NSPopUpButton *listFrom = nil, *listPageSize = nil, *listColumnsMenu = nil, *listWithin = nil, *listSortMenu = nil;
    NSMenu *listRowMenu = nil;  // a row's own: New QSO, View QSO, Center, Zoom to It
    NSStackView *listTop = nil, *listFooter = nil;  // the list's bars: what gives way when narrow (fitListBars)
    NSButton *listBack = nil;  // after a click on the map switched the list to Selected: back to what it listed
    int listBackKind = -1;
    NSView *nearestTo = nil;
    NSSearchField *listSearch = nil;
    NSButton *listPrev = nil, *listNext = nil;
    NSTableView *listTable = nil;
    ADIFViewList *listRows = nil;
    bool listQueued = false;
    int listColumnsFor = -1;          // the kind the table's columns are for
    size_t listPage[kListKinds] = {};  // each kind's page
    std::vector<ADIFIssue> issues;     // Check Log's errors and warnings in the QSOs shown
    bool choosingFromList = false;    // a row chose it: the list stays as it is
    // POTA parks in: the park filter's button and popover.
    NSButton *parkPlacesButton = nil;
    NSPopover *parkPlacesPopover = nil;
    NSTokenField *parkLocations = nil, *parkCounties = nil;
    NSButton *parkHome = nil;
    ADIFTokenCompleter *countyCompleter = nil;
    void (^spotHandler)(const std::vector<std::pair<std::string, std::string>> &) = nil;
    adif::MapData data;
    std::vector<ADIFMapEntity> dxcc;
    std::vector<size_t> listed;   // the QSOs chosen (the list's Selected): indexes into data.qsos
    std::string summary, chosen;  // what the status line says when nothing is under the pointer
    std::string home;             // the grid the globe, rings and paths start from
    intptr_t buffer = 0;
} mw;

// Saved choices, in ADIFLint.ini.
void revealSection(NSString *name);
void fillRecentSpots();
void fillBandConditions();
void fillAwards();
void switchWorkflow(int to);
std::string grouped(size_t n);
int workflow();
bool live();
int quickView();
void fillQuickViews();
void showHover(const std::string &text);
bool inLens(int lens, const adif::Spot &sp, const adif::SpotStatus &st, bool watched);
std::vector<std::string> splitSetting(const char *key, char sep);
void applyViewFilters();
int historyViewOf(int layer);
std::vector<std::string> watchList();
std::string watchTokenFor(const ADIFMapHit &h);
bool onWatchList(const std::string &token);
void toggleWatch(const std::string &token);
void showWatchButton(const ADIFMapHit &h);
void showWatchList(NSView *anchor);
void fillBell();
void fillBellMenu(NSMenu *menu);
void fillHomeMenu(NSMenu *menu);
void fillViewsMenu(NSMenu *menu);
void fillSynced();
void fillDxccPotaBars();
void fillLayerMenu(NSMenu *menu);
bool mapShortcut(NSEvent *e);
bool stepList(int by);
void useSelectedSpot();
void layerChanged(MapLayerId id, int which);
int lensOfView(int view);
void showList(const std::vector<size_t> &qsos, ADIFMapHit::Kind kind);
void showListKind(int kind);
void chooseQuickView(NSInteger row);
void showDxccRow(int dxcc);
void revealBands();
void showPane(int pane, bool on);
void fillFindMenu(NSMenu *menu);
void goHomeView();

// Faint text, as faint as the system's Increase contrast (Accessibility) allows: secondary then.
bool moreContrast() { return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast; }
NSColor *faintInk() { return moreContrast() ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor; }

bool flag(const char *key, bool fallback) {
    std::string v = setting(key);
    return v.empty() ? fallback : v == "1";
}
int number(const char *key, int fallback, int max) {
    std::string v = setting(key);
    int n = v.empty() ? fallback : std::atoi(v.c_str());
    return std::clamp(n, 0, max);
}
void saveFlag(const char *key, bool on) { setSetting(key, on ? "1" : "0"); }

std::set<std::string> hiddenPrograms() {
    std::string v = setting("mapHiddenPrograms");
    if (v.empty() && setting("mapHiddenProgramsSet").empty()) return {"IOTA"};  // callbooks fill IOTA in for every island station
    std::set<std::string> out;
    for (size_t b = 0; b < v.size();) {
        size_t e = v.find(',', b);
        if (e == std::string::npos) e = v.size();
        if (e > b) out.insert(v.substr(b, e - b));
        b = e + 1;
    }
    return out;
}

void saveHidden(const std::set<std::string> &hidden) {
    std::string v;
    for (const std::string &p : hidden) v += (v.empty() ? "" : ",") + p;
    setSetting("mapHiddenPrograms", v);
    setSetting("mapHiddenProgramsSet", "1");
}

// The layers' boxes: each layer's identifier, column title, settings keys and defaults. The keys
// are the ones the earlier Show, Overlays and Labels rows saved, so choices carry over.
struct LayerUi {
    MapLayerId id;
    NSString *ident, *title;
    const char *showKey, *overlayKey, *labelsKey;
    bool showOn, overlayOn;
    NSString *showTip, *overlayTip, *labelsTip;
};
const LayerUi kLayerUi[] = {
    {kLayerSquares, @"grid", N(@"Grid squares"), "mapSquares", "mapGrid", "mapLabels", true, true, N(@"Each grid square worked, in the map's colours"),
     N(@"The Maidenhead grid: its fields (20 x 10 degrees), and its squares (2 x 1) when zoomed in"),
     N(@"Field names (FN, EM...), and square names (FN31) when zoomed in")},
    {kLayerCountries, @"countries", N(@"Countries"), "mapDxcc", "mapCountries", "mapCountryLabels", true, false,
     N(@"Each DXCC entity worked, its own land shaded (Alaska apart from the United States, Sardinia from Italy, Scotland from England); "
     @"a dot for one too small to shade"),
     N(@"Every country outlined, coasts and borders (Natural Earth, public domain)"), N(@"Each country's name, where it fits inside the country on screen")},
    {kLayerStates, @"states", N(@"US states"), "mapShowStates", "mapUsStates", "mapStateLabels", false, false,
     N(@"Each US state worked, shaded: from STATE, else where the QSO was"), N(@"State lines (Natural Earth, public domain)"),
     N(@"Each state's postal code, where it fits")},
    {kLayerCounties, @"counties", N(@"US counties"), "mapShowCounties", "mapCounties", "mapCountyLabels", false, false,
     N(@"Each US county worked, shaded: from CNTY, else where the QSO was (LAT/LON or a 6-character grid)"),
     N(@"County lines (Natural Earth, public domain), from 2.5x zoom"), N(@"Each county's name, where it fits")},
    {kLayerCq, @"cq", N(@"CQ zones"), "mapShowCq", "mapCqZones", "mapCqLabels", false, false,
     N(@"Each CQ zone worked, shaded: from CQZ, else where the QSO was, else the country data"),
     N(@"CQ zones 1-40 (HB9HIL's hamradio-zones-geojson, MIT); approximate"), N(@"The CQ zones' numbers")},
    {kLayerItu, @"itu", N(@"ITU zones"), "mapShowItu", "mapItuZones", "mapItuLabels", false, false,
     N(@"Each ITU zone worked, shaded: from ITUZ, else where the QSO was, else the country data"),
     N(@"ITU zones 1-90 (HB9HIL's hamradio-zones-geojson, MIT); approximate"), N(@"The ITU zones' numbers")},
    {kLayerPota, @"pota", N(@"POTA"), "mapShowPota", "mapPota", "mapPotaLabels", true, false,
     N(@"The POTA parks you hunted (a badge with a tree, in the map's colours) and activated (with a star), at the parks themselves with "
     @"POTA's park list (Settings, POTA Parks), else at the QSO's grid"),
     N(@"Every active POTA park you haven't worked, as a smaller badge (a dot where very many show; needs POTA's park list, from Settings)"),
     N(@"Each park's reference (US-1234) in a box by its badge: the parks you worked always, the others once zoomed in to a few hundred, and "
     @"names once zoomed in to fewer")},
    {kLayerIota, @"iota", N(@"IOTA"), "mapShowIota", "mapIota", "mapIotaLabels", false, false,
     N(@"The IOTA groups in your log, filled in (needs IOTA's group list, from Settings)"), N(@"Every IOTA group's box, dashed"),
     N(@"Each group's reference (EU-005), and its name where there is room")},
    {kLayerCities, @"cities", N(@"Cities"), nullptr, "mapCities", "mapCityLabels", false, false, nil,
     N(@"7,300 cities and towns (Natural Earth, public domain), more as you zoom in"), N(@"City names, where they don't run into each other")},
    {kLayerSpots, @"spots", N(@"Spots"), "mapShowSpots", "mapSpotLines", "mapSpotLabels", false, false,
     N(@"The stations spotted now, from the sources chosen in Spots... (Spothole, a DX cluster, PSKReporter), coloured as Colour by says "
     @"(by confirmation: a new DXCC, a new band or mode, worked, confirmed); older spots fade"),
     N(@"A line from each spotter to the station it heard (while Show is on)"), N(@"Each spotted station's call, where there's room")},
};

// Spotters before "Faint grey" was a choice (mapSpotters: 0 hidden, 1 markers, 2 with calls).
int spotterStyleFallback() {
    std::string old = setting("mapSpotters");
    if (old.empty()) return 2;
    static const int kWas[] = {0, 2, 3};
    return kWas[std::clamp(std::atoi(old.c_str()), 0, 2)];
}

ADIFMapStyle savedStyle() {
    ADIFMapStyle s;
    static const double kSizes[] = {0.75, 1.0, 1.4, 1.9};
    s.colorBy = number("mapColorBy", 0, 4);
    s.palette = ADIFNightMode() ? 4 : number("mapPalette", 0, 4);  // Night Mode: the Night (red) palette
    s.shape = number("mapMarkerShape", 0, 2);
    s.fill = number("mapSquareFill", 0, 2);
    s.marker = kSizes[number("mapMarkerSize", 1, 3)];
    s.contact = number("mapContactMarker", 0, 2);
    for (const LayerUi &l : kLayerUi) {
        LayerState &st = s.layer[l.id];
        // POTA's Show was the Parks box (mapParks).
        bool showOn = l.id == kLayerPota ? flag("mapParks", l.showOn) : l.showOn;
        st.show = l.showKey && flag(l.showKey, showOn);
        st.overlay = flag(l.overlayKey, l.overlayOn);
        st.labels = flag(l.labelsKey, true);
    }
    s.legend = number("mapLegend", 1, 2);
    s.textScale = number("mapTextSize", 0, 1) == 1 ? 1.25 : 1;
    s.hatch = flag("mapHatch", false);
    for (const std::string &id : splitSetting("mapLegendHidden", ',')) s.legendHidden.insert(id);
    s.rings = flag("mapRings", false);
    s.paths = flag("mapPaths", false);
    s.lineStyle = number("mapLineStyle", 0, 2);
    s.lineWidth = number("mapLineWidth", 1, 2);
    s.arcs = flag("mapArcs", true);
    s.lineOpacity = number("mapLineOpacity", 1, 2);
    s.areaShade = number("mapAreaShade", 1, 2);
    s.dayNight = flag("mapDayNight", false);
    s.greyLine = flag("mapGreyLine", false);
    s.sunTime = number("mapSunTime", 0, 1);
    s.mine = flag("mapMine", true);
    s.spotters = number("mapSpotterStyle", spotterStyleFallback(), 3);
    s.spotLines = number("mapSpotLineStyle", 0, 2);
    s.spotLabel.mode = flag("mapSpotLabelMode", true);
    s.spotLabel.khz = flag("mapSpotLabelFreq", false);
    s.spotLabel.age = flag("mapSpotLabelAge", true);
    s.spotLabel.snr = flag("mapSpotLabelSnr", true);
    s.spotFade = flag("mapSpotFade", true);
    s.parkOutlineOnly = number("mapParkOutlines", 0, 1) == 1;
    s.reference = number("mapReference", 1, 2);
    s.spotlight = flag("mapSpotlight", false);
    s.terrain = number("mapTerrain", 0, 2);
    s.flags = flag("mapFlags", true);
    s.aurora = flag("mapAurora", false);
    s.beacons = flag("mapBeacons", false);
    s.spotHeat = flag("mapSpotHeat", false);
    return s;
}

void setStatus(const std::string &text) { mw.hover.stringValue = ADIFString(tr(text)); }  // in the footer; a fixed text is translated

// A status with a coloured dot before it (green fresh, orange stale, grey off), as plain text otherwise.
NSAttributedString *dotted(const std::string &text, NSColor *dot, NSFont *font) {
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    if (dot) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\u25CF  " attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : dot}]];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:ADIFString(text)
                                                                attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : NSColor.labelColor}]];
    return out;
}

// A moment (Unix seconds) in UTC, as strftime writes it.
std::string utcAt(long long epoch, const char *format) {
    char out[40];
    time_t t = (time_t)epoch;
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(out, sizeof out, format, &tm);
    return out;
}

// The contact panel with nothing under the pointer or chosen: how to use the map.
std::string idleStatus() {
    return tr("Point at the map for what is there; click a square, dot, pin, park or spot for its QSOs and what it means for your log. Scroll or "
              "pinch to zoom, drag to move (on the globe, to turn it); the legend shows the colours.");
}

void showSituation();
std::string entityName(int dxcc, const std::string &call);

// The DXCC entity of a call (its DXCC field, else the country file's), 0 when unknown.
int entityOf(int dxcc, const std::string &call) {
    adif::CountryInfo info;
    if (dxcc > 0) return dxcc;
    const adif::CountryTable &countries = ADIFCountries();
    return !countries.empty() && countries.lookup(call, &info) ? info.dxcc : 0;
}

// A flag and a space before a DXCC entity's name or a call, when Style Options shows flags.
std::string flagged(int dxcc, const std::string &text) {
    std::string f = mw.view.style.flags ? adif::dxccFlag(dxcc) : "";
    return f.empty() || text.empty() ? text : f + " " + text;
}


// The contact panel's second line: the band slots of a DXCC entity (green confirmed, orange
// worked, grey not yet), its mode groups the same way, and your QSOs with the call.
void showSlots(int dxcc, const std::string &entity, const std::string &call) {
    if (!mw.slots) return;
    mw.slots.hidden = dxcc <= 0;
    if (dxcc <= 0) {
        mw.slots.stringValue = @"";
        return;
    }
    const MapPalette &pal = adif::mapPalette(mw.view.style.palette);
    const adif::WorkedIndex &w = mw.view.worked;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
    NSFont *bold = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightBold];
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    auto add = [&](const std::string &text, NSColor *colour, NSFont *f) {
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:ADIFString(text)
                                                                    attributes:@{NSFontAttributeName : f, NSForegroundColorAttributeName : colour}]];
    };
    auto colourOf = [&](adif::SlotState st) {
        return st == adif::SlotState::Confirmed ? rgb(pal.confirmed) : st == adif::SlotState::Worked ? rgb(pal.worked) : faintInk();
    };
    add(entity + ":  ", NSColor.secondaryLabelColor, [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold]);
    for (const auto &[band, st] : adif::bandSlots(w, dxcc)) {
        std::string b = band.size() > 1 && band.back() == 'm' && isdigit((unsigned char)band[band.size() - 2]) ? band.substr(0, band.size() - 1) : band;
        add(b + " ", colourOf(st), st == adif::SlotState::None ? font : bold);
    }
    auto entityIt = w.entities.find(dxcc);
    static const char *const kModes[] = {"CW", N_("Phone"), N_("Data")};
    add("  ", NSColor.labelColor, font);
    for (int m = 0; m < 3; ++m) {
        adif::SlotState st = entityIt == w.entities.end()                  ? adif::SlotState::None
                             : entityIt->second.confirmedModes.count(m) ? adif::SlotState::Confirmed
                             : entityIt->second.modes.count(m)          ? adif::SlotState::Worked
                                                                        : adif::SlotState::None;
        add(tr(kModes[m]) + " ", colourOf(st), st == adif::SlotState::None ? font : bold);
    }
    if (!call.empty()) {
        auto c = w.calls.find(adif::lookupCall(call));
        std::string worked = c == w.calls.end() ? trf("{call} not in this log", {{"call", call}})
                                                : trp("{call}: {n} QSO", "{call}: {n} QSOs", (long long)c->second.qsos, {{"call", call}}) +
                                                      (c->second.confirmed ? ", " + tr("confirmed") : "");
        add("  \u00B7  " + worked, NSColor.secondaryLabelColor, [NSFont systemFontOfSize:NSFont.smallSystemFontSize]);
    }
    mw.slots.attributedStringValue = out;
}

std::string callsOf(const std::vector<size_t> &qsos);

// What the contact panel is about, in a few words: a spot's call, frequency and mode; a park's
// reference and name; a square; a contact's calls; an entity, area or IOTA group's name.
std::string contactTitle(const ADIFMapHit &h) {
    switch (h.kind) {
        case ADIFMapHit::Spot: {
            if (h.index >= mw.view.spots.size()) return "";
            const adif::Spot &sp = mw.view.spots[h.index].spot;
            std::string t = sp.activator;
            if (!sp.khz.empty()) t += "  \u00B7  " + sp.khz + " kHz";
            if (!sp.mode.empty()) t += " " + sp.mode;
            if (!sp.reference.empty()) t += "  \u00B7  " + (sp.program.empty() ? "" : sp.program + " ") + sp.reference;
            return t;
        }
        case ADIFMapHit::Spotter: return h.index < mw.view.spotters.size() ? mw.view.spotters[h.index].call : "";
        case ADIFMapHit::Beacon: return h.index < adif::kBeaconCount ? adif::kBeacons[h.index].call : "";
        case ADIFMapHit::Pota: {
            const adif::PotaParks &list = ADIFPotaParks();
            return h.index < list.size() ? list.parks()[h.index].ref + "  " + list.parks()[h.index].name : "";
        }
        case ADIFMapHit::Contact: return h.index < mw.view.contacts.size() ? callsOf(mw.view.contacts[h.index].qsos) : "";
        case ADIFMapHit::Square:
        case ADIFMapHit::Empty: return h.square;
        case ADIFMapHit::Dxcc: return h.index < mw.dxcc.size() ? mw.dxcc[h.index].name : "";
        case ADIFMapHit::Area: {
            const adif::AreaIndex &index = adif::areaIndex(layerOverlay(h.layer));
            return h.index < index.size() ? index.area(h.index).name : "";
        }
        case ADIFMapHit::Iota: return h.index < ADIFIotaGroups().size() ? ADIFIotaGroups()[h.index].ref + "  " + ADIFIotaGroups()[h.index].name : "";
        case ADIFMapHit::Park: return h.index < mw.data.parks.size() ? mw.data.parks[h.index].program + " " + mw.data.parks[h.index].reference : "";
        default: return "";
    }
}

std::vector<ADIFInfoRow> spotInfo(const ADIFMapHit &h);

// "1,234 km" (or miles, as the list measures) from your station to a place; "" without a home.
std::string homeDistance(double lat, double lon) {
    double hlat, hlon;
    if (mw.home.empty() || !adif::gridToLatLon(mw.home, &hlat, &hlon)) return "";
    return adif::distanceText(adif::greatCircleKm(hlat, hlon, lat, lon), setting("mapListUnits") == "mi");
}

// When a beacon sends next on a band: "now", or the time ("12:03:20 UTC").
std::string beaconNext(size_t beacon, size_t band, double now) {
    for (double t = std::floor(now / 10) * 10; t < now + 200; t += 10)
        if (adif::beaconOn(band, t) == beacon) return t <= now ? tr("now") : utcAt((long long)t, "%H:%M:%S UTC");
    return "";
}

std::string beaconMHz(size_t band) {
    char m[16];
    snprintf(m, sizeof m, "%.3f", adif::kBeaconMHz[band % adif::kBeaconBands]);
    return m;
}

// The selected panel's badge, the line under the name, the facts (a label and a value a row), and
// for a spot the reasons to work it: what is chosen, at a glance; the description stays under them.
void showChosenFacts(const ADIFMapHit &h) {
    if (!mw.chosenBadge) return;
    struct Kind {
        const char *name;
        NSColor *colour;
    };
    Kind kind = {"", NSColor.clearColor};
    std::string subtitle;
    struct Fact {
        NSString *symbol;
        std::string label, value;  // an empty value: "Unavailable"
    };
    std::vector<Fact> facts;
    struct Reason {
        NSString *symbol;
        std::string text;
        std::string tip = "";      // what its arrow shows
        void (^go)(void) = nil;    // its arrow's action; nil: none
    };
    std::vector<Reason> why;
    std::string details;  // a spot's Details, a line each ("# " a heading)
    // The symbol for a fact from the map's information box, by its label.
    auto symbolFor = [](const std::string &label) -> NSString * {
        static const std::pair<const char *, NSString *> kSymbols[] = {
            {N_("Frequency"), @"waveform"}, {N_("Band"), @"waveform"},           {N_("Mode"), @"radio"},
            {N_("Spotted"), @"clock"},      {N_("Source"), @"tray.and.arrow.down"}, {N_("Position"), @"mappin"},
            {N_("Country"), @"globe"},      {N_("Continent"), @"map"},           {N_("Zones"), @"circle.grid.cross"},
            {N_("Distance"), @"ruler"},     {N_("Grid"), @"square.grid.3x3"},    {N_("Signal report"), @"antenna.radiowaves.left.and.right"},
            {N_("Reference"), @"leaf"},     {N_("Name"), @"tag"},                {N_("Location"), @"map"},
            {N_("Comment"), @"text.bubble"}};
        for (const auto &[l, sym] : kSymbols)
            if (label == tr(l)) return sym;
        return @"circle";
    };
    switch (h.kind) {
        case ADIFMapHit::Spot: {
            if (h.index >= mw.view.spots.size()) break;
            const ADIFMapSpot &ms = mw.view.spots[h.index];
            const adif::Spot &sp = ms.spot;
            const adif::SpotStatus &st = ms.status;
            kind = {sp.heardMe ? N_("Your signal") : N_("Live spot"), NSColor.systemGreenColor};
            std::string where = st.entity;
            if (!sp.grid.empty()) where += (where.empty() ? "" : "  \u00B7  ") + sp.grid;
            if (std::string d = homeDistance(ms.lat, ms.lon); !d.empty()) where += (where.empty() ? "" : "  \u00B7  ") + d;
            subtitle = where;
            // What an operator needs first, as the station's own facts; then the rest as the map's
            // information box has them.
            if (!sp.khz.empty()) {
                char mhz[32];
                snprintf(mhz, sizeof mhz, "%.3f MHz", std::atof(sp.khz.c_str()) / 1000);
                facts.push_back({@"waveform", tr("Frequency"), std::string(mhz) + (sp.band.empty() ? "" : " (" + sp.band + ")")});
            }
            facts.push_back({@"radio", tr("Mode"), sp.mode});
            std::string signal;
            if (sp.hasSnr)
                signal = trf("{snr} dB SNR", {{"snr", (sp.snr > 0 ? "+" : "") + std::to_string(sp.snr)}}) + "  \u00B7  " +
                         (sp.source == adif::SpotSource::PskReporter              ? tr("PSKReporter")
                          : sp.spotter.size() > 2 && sp.spotter.substr(sp.spotter.size() - 2) == "-#" ? tr("an RBN skimmer")
                                                                                                    : adif::spotSourceName(sp.source));
            facts.push_back({@"antenna.radiowaves.left.and.right", tr("Signal"), signal});
            if (!sp.spotter.empty()) {
                std::string by = sp.spotter + (sp.epoch > 0 ? "  \u00B7  " + adif::spotAge(sp.epoch, (long long)time(nullptr)) : "");
                if (ms.heard.size() > 1) by += "  " + trf("(+{n} more)", {{"n", std::to_string(ms.heard.size() - 1)}});
                facts.push_back({@"person", tr("Spotter"), by});
            }
            facts.push_back({@"globe", tr("DXCC"), st.entity.empty() ? "" : st.entity + (st.dxcc > 0 ? " (" + std::to_string(st.dxcc) + ")" : "")});
            facts.push_back({@"square.grid.3x3", tr("Grid"), sp.grid});
            if (!sp.reference.empty())
                facts.push_back({@"leaf", sp.program.empty() ? tr("Reference") : sp.program, sp.reference + (sp.park.empty() ? "" : "  \u00B7  " + sp.park)});
            facts.push_back({@"tray.and.arrow.down", tr("Source"), adif::spotSourceName(sp.source)});
            for (const ADIFInfoRow &r : spotInfo(h))
                if (!r.heading && (r.label == tr("Continent") || r.label == tr("Zones") || r.label == tr("Distance") || r.label == tr("Comment")))
                    facts.push_back({symbolFor(r.label), r.label, r.value});
            if (sp.heardMe) break;
            // Each reason that can show more has an arrow: the Quick View or list that has it.
            int dxcc = st.dxcc;
            auto inDxcc = [&](NSString *symbol, const std::string &text) {
                int entity = dxcc;  // a copy: a block would keep the lambda's reference to it
                why.push_back({symbol, text, tr("This entity's bands and modes in your log (the list's DXCC)"), ^{ showDxccRow(entity); }});
            };
            if (!ms.watched.empty())
                why.push_back({@"star.fill", trf("On your watch list ({what})", {{"what", ms.watched}}), tr("The watch list"), ^{ showWatchList(mw.whyBox); }});
            switch (st.need) {
                case adif::SpotNeed::NewDxcc:
                    why.push_back({@"star.circle.fill", trf("New DXCC entity ({entity})", {{"entity", st.entity}}), tr("Every spot of a new DXCC entity (New DXCC)"),
                                   ^{ chooseQuickView(2); }});
                    break;
                case adif::SpotNeed::NewBand: inDxcc(@"plus.circle.fill", trf("Needed on {band}: {entity} not worked there", {{"band", sp.band}, {"entity", st.entity}})); break;
                case adif::SpotNeed::NewMode: inDxcc(@"plus.circle", trf("A new mode for {entity} on {band}", {{"band", sp.band}, {"entity", st.entity}})); break;
                case adif::SpotNeed::Worked: inDxcc(@"checkmark.circle", trf("{entity} worked on {band}, not confirmed", {{"band", sp.band}, {"entity", st.entity}})); break;
                case adif::SpotNeed::Confirmed: inDxcc(@"checkmark.circle.fill", trf("{entity} confirmed on {band}", {{"band", sp.band}, {"entity", st.entity}})); break;
                default: break;
            }
            if (st.newPark && !sp.reference.empty())
                why.push_back({@"leaf.fill", trf("{program} {ref}: a park you haven't worked", {{"program", sp.program}, {"ref", sp.reference}}),
                               tr("Every POTA activator at a park you haven't worked (New POTA parks)"), ^{ chooseQuickView(5); }});
            if (std::string lotw = ADIFLotwNote(sp.activator); !lotw.empty()) why.push_back({@"checkmark.seal", lotw});
            double hlat, hlon;
            if (!mw.home.empty() && adif::gridToLatLon(mw.home, &hlat, &hlon)) {
                size_t near = 0;
                for (const ADIFSpotHeard &by : ms.heard) near += adif::greatCircleKm(hlat, hlon, by.lat, by.lon) <= 1500;
                if (near)
                    why.push_back({@"dot.radiowaves.left.and.right",
                                   trp("Heard by {n} station within 1,500 km of you", "Heard by {n} stations within 1,500 km of you", (long long)near),
                                   tr("How the bands are doing near you (Band conditions)"), ^{ revealBands(); }});
            }
            if (st.callQsos) {  // what you have with the station already, beside what it means now
                std::string bands;
                for (const std::string &b : st.callBands) bands += (bands.empty() ? "" : ", ") + b;
                std::string had = trp("{n} QSO with this call before", "{n} QSOs with this call before", (long long)st.callQsos);
                if (!bands.empty()) had += " (" + bands + ")";
                if (st.callFirstYear) had += ", " + trf("first in {year}", {{"year", std::to_string(st.callFirstYear)}});
                had += st.callConfirmed ? ", " + tr("confirmed") : ", " + tr("not confirmed");
                std::string key = adif::lookupCall(sp.activator);
                why.push_back({@"person.crop.circle", had, tr("Your QSOs with this call, in the list"), ^{
                                   std::vector<size_t> qsos;
                                   for (size_t i = 0; i < mw.data.qsos.size(); ++i)
                                       if (adif::lookupCall(mw.data.qsos[i].call) == key) qsos.push_back(i);
                                   if (mw.listPanel.hidden) showPane(1, true);
                                   showList(qsos, ADIFMapHit::None);
                                   showListKind(kListSelected);
                               }});
            } else {
                why.push_back({@"person.crop.circle", tr("No QSOs with this call yet")});
            }
            // Details: who heard it (when, how strong, how far from you); your QSOs with the call;
            // its references; its entity.
            {
                double hl = 0, ho = 0;
                bool home = !mw.home.empty() && adif::gridToLatLon(mw.home, &hl, &ho);
                long long now = (long long)time(nullptr);
                details += "# " + tr("Heard by") + "\n";
                for (const ADIFSpotHeard &by : ms.heard) {
                    std::string line = by.call;
                    if (by.epoch > 0) line += "  \u00B7  " + adif::spotAge(by.epoch, now);
                    if (by.hasSnr) line += "  \u00B7  " + std::string(by.snr > 0 ? "+" : "") + std::to_string(by.snr) + " dB";
                    if (home) line += "  \u00B7  " + trf("{distance} from you", {{"distance", adif::distanceText(adif::greatCircleKm(hl, ho, by.lat, by.lon), setting("mapListUnits") == "mi")}});
                    details += line + "\n";
                }
                if (ms.heard.empty() && !sp.spotter.empty())  // where the spotter is isn't known: the spot's own
                    details += sp.spotter + (sp.epoch > 0 ? "  \u00B7  " + adif::spotAge(sp.epoch, now) : "") +
                               (sp.hasSnr ? "  \u00B7  " + std::string(sp.snr > 0 ? "+" : "") + std::to_string(sp.snr) + " dB" : "") + "\n";
                std::string key = adif::lookupCall(sp.activator);
                std::vector<const adif::MapQso *> mine;
                for (const adif::MapQso &q : mw.data.qsos)
                    if (adif::lookupCall(q.call) == key) mine.push_back(&q);
                std::stable_sort(mine.begin(), mine.end(), [](const adif::MapQso *a, const adif::MapQso *b) { return a->date8 + a->time > b->date8 + b->time; });
                details += "# " + trf("Your QSOs with {call}", {{"call", key}}) + "\n";
                for (size_t i = 0; i < mine.size() && i < 6; ++i)
                    details += mine[i]->date + "  " + mine[i]->time + "  " + mine[i]->band + "  " + mine[i]->mode + (mine[i]->confirmed ? "  \u2713" : "") + "\n";
                if (mine.empty()) details += tr("none yet") + "\n";
                else if (mine.size() > 6) details += trf("and {n} more", {{"n", std::to_string(mine.size() - 6)}}) + "\n";
                if (!sp.refs.empty()) {
                    details += "# " + tr("References") + "\n";
                    for (const std::string &ref : sp.refs) {
                        const adif::PotaPark *p = mapkit::potaSpot(sp) ? ADIFPotaParks().find(ref) : nullptr;
                        details += ref + (p ? "  " + p->name + (p->location.empty() ? "" : " (" + p->location + ")") : "") + "\n";
                    }
                }
                adif::CountryInfo info;
                if (!ADIFCountries().empty() && ADIFCountries().lookup(sp.activator, &info)) {
                    details += "# " + tr("Entity") + "\n";
                    details += trf("{entity}, DXCC {dxcc}, {continent}, CQ {cq}, ITU {itu}",
                                   {{"entity", info.name}, {"dxcc", std::to_string(info.dxcc)}, {"continent", info.continent},
                                    {"cq", std::to_string(info.cq)}, {"itu", std::to_string(info.itu)}}) +
                               "\n";
                }
            }
            break;
        }
        case ADIFMapHit::Spotter:
            kind = {N_("Spotter"), NSColor.systemTealColor};
            for (const ADIFInfoRow &r : spotInfo(h))
                if (!r.heading) facts.push_back({symbolFor(r.label), r.label, r.value});
            break;
        case ADIFMapHit::Contact: {
            kind = {N_("QSO"), NSColor.systemBlueColor};
            if (h.index >= mw.view.contacts.size() || mw.view.contacts[h.index].qsos.empty()) break;
            const std::vector<size_t> &qsos = mw.view.contacts[h.index].qsos;
            if (std::string d = homeDistance(mw.view.contacts[h.index].lat, mw.view.contacts[h.index].lon); !d.empty()) subtitle = d;
            if (qsos.size() > 1) {
                subtitle = plural(qsos.size(), "QSO") + (subtitle.empty() ? "" : "  \u00B7  " + subtitle);
                break;
            }
            const adif::MapQso &q = mw.data.qsos[qsos[0]];
            std::string when = q.date + (q.time.size() >= 4 ? " " + q.time.substr(0, 2) + ":" + q.time.substr(2, 2) + " UTC" : "");
            facts.push_back({@"clock", tr("Date"), when});
            facts.push_back({@"waveform", tr("Band"), q.band});
            facts.push_back({@"radio", tr("Mode"), q.mode});
            facts.push_back({@"square.grid.3x3", tr("Grid"), q.grid});
            facts.push_back({@"globe", tr("DXCC"), entityName(q.dxcc, q.call)});
            facts.push_back({@"checkmark.seal", tr("Confirmed"), q.confirmed ? tr("yes") : tr("no")});
            facts.push_back({@"number", tr("Record"), std::to_string(q.record)});
            break;
        }
        case ADIFMapHit::Square:
        case ADIFMapHit::Empty:
            if (!h.square.empty()) kind = {h.kind == ADIFMapHit::Square ? N_("Grid square") : N_("Grid square, not worked"), NSColor.systemIndigoColor};
            break;
        case ADIFMapHit::Dxcc:
            kind = {N_("DXCC entity"), NSColor.systemPurpleColor};
            if (h.index < mw.dxcc.size())
                subtitle = trf("DXCC {n}", {{"n", std::to_string(mw.dxcc[h.index].dxcc)}}) + "  \u00B7  " + plural(mw.dxcc[h.index].qsos.size(), "QSO") +
                           (mw.dxcc[h.index].confirmed ? "  \u00B7  " + tr("confirmed") : "");
            break;
        case ADIFMapHit::Area: {
            static const char *const kAreaKinds[] = {N_("Grid square"), N_("DXCC entity"), N_("US state"), N_("US county"), N_("CQ zone"), N_("ITU zone")};
            kind = {h.layer >= 0 && h.layer < 6 ? kAreaKinds[h.layer] : N_("Area"), NSColor.systemPurpleColor};
            break;
        }
        case ADIFMapHit::Pota: kind = {N_("POTA park"), NSColor.systemGreenColor}; break;
        case ADIFMapHit::Beacon: {
            kind = {N_("NCDXF beacon"), NSColor.systemOrangeColor};
            if (h.index >= adif::kBeaconCount) break;
            const adif::Beacon &b = adif::kBeacons[h.index];
            double lat = 0, lon = 0, now = [[NSDate date] timeIntervalSince1970];
            subtitle = std::string(b.location) + "  \u00B7  " + b.grid;
            if (adif::gridToLatLon(b.grid, &lat, &lon))
                if (std::string d = homeDistance(lat, lon); !d.empty()) subtitle += "  \u00B7  " + d;
            for (size_t band = 0; band < adif::kBeaconBands; ++band)
                facts.push_back({@"dot.radiowaves.left.and.right", beaconMHz(band) + " MHz", beaconNext(h.index, band, now)});
            facts.push_back({@"waveform", tr("Sends"), tr("its call in CW, then dashes at 100 W to 0.1 W")});
            break;
        }
        case ADIFMapHit::Park: kind = {N_("Reference"), NSColor.systemBrownColor}; break;
        case ADIFMapHit::Iota: kind = {N_("IOTA group"), NSColor.systemTealColor}; break;
        default: break;
    }
    mw.chosenBadge.stringValue = [NSString stringWithFormat:@" %@ ", ADIFString(tr(kind.name)).localizedUppercaseString];
    mw.chosenBadge.layer.backgroundColor = kind.colour.CGColor;
    mw.chosenBadge.hidden = !*kind.name;
    mw.chosenSubtitle.stringValue = ADIFString(subtitle);
    mw.chosenSubtitle.hidden = subtitle.empty();
    for (NSView *v in [mw.chosenFacts.subviews copy]) [v removeFromSuperview];  // a row removed keeps its views
    while (mw.chosenFacts.numberOfRows > 0) [mw.chosenFacts removeRowAtIndex:0];
    for (const Fact &f : facts) {
        NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:f.symbol accessibilityDescription:nil] ?: [[NSImage alloc] init]];
        icon.contentTintColor = NSColor.secondaryLabelColor;
        icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        [icon.widthAnchor constraintEqualToConstant:16].active = YES;
        NSTextField *l = [NSTextField labelWithString:ADIFString(f.label)];
        l.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        l.textColor = NSColor.secondaryLabelColor;
        NSStackView *name = [NSStackView stackViewWithViews:@[ icon, l ]];
        name.spacing = 5;
        // A fact the source doesn't give says so, rather than being left out.
        NSTextField *v = [NSTextField labelWithString:f.value.empty() ? T(@"Unavailable") : ADIFString(f.value)];
        v.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1 weight:f.value.empty() ? NSFontWeightRegular : NSFontWeightMedium];
        v.textColor = f.value.empty() ? faintInk() : NSColor.labelColor;
        v.lineBreakMode = NSLineBreakByTruncatingTail;
        v.toolTip = v.stringValue;
        [v setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [mw.chosenFacts addRowWithViews:@[ name, v ]];
    }
    mw.chosenFacts.hidden = facts.empty();
    for (NSView *v in [mw.whyList.arrangedSubviews copy]) {
        [mw.whyList removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    size_t reasonAt = 0;
    for (const Reason &reason : why) {
        NSString *symbol = reason.symbol;
        const std::string &text = reason.text;
        NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] ?: [[NSImage alloc] init]];
        icon.contentTintColor = [symbol isEqualToString:@"star.fill"] ? NSColor.systemYellowColor : [symbol hasPrefix:@"star"] ? NSColor.systemPinkColor : [symbol hasPrefix:@"plus"] ? NSColor.systemTealColor
                                : [symbol hasPrefix:@"leaf"] ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
        [icon.widthAnchor constraintEqualToConstant:16].active = YES;
        NSTextField *t = [NSTextField wrappingLabelWithString:ADIFString(text)];
        t.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
        NSStackView *row = [NSStackView stackViewWithViews:@[ icon, t ]];
        if (reason.go) {  // an arrow to what shows more
            NSButton *go = [NSButton buttonWithTitle:@"" target:nil action:nil];
            go.bordered = NO;
            go.image = [NSImage imageWithSystemSymbolName:@"arrow.right.circle" accessibilityDescription:nil];
            go.imagePosition = NSImageOnly;
            go.contentTintColor = NSColor.linkColor;
            go.toolTip = ADIFString(reason.tip);
            go.accessibilityLabel = ADIFString(reason.tip);
            go.identifier = [NSString stringWithFormat:@"map.why.%zu", reasonAt];
            ADIFOnAction(go, reason.go);
            [go setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
            [row addArrangedSubview:go];
        }
        row.spacing = 6;
        row.alignment = NSLayoutAttributeFirstBaseline;
        [mw.whyList addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:mw.whyList.widthAnchor].active = YES;
        ++reasonAt;
    }
    mw.whyBox.hidden = why.empty();
    // Details, a heading a part.
    mw.detailsSection.hidden = details.empty();
    if (!details.empty()) {
        NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
        NSFont *plain = [NSFont systemFontOfSize:NSFont.smallSystemFontSize], *head = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold];
        std::string rest = details;
        while (!rest.empty()) {
            size_t nl = rest.find('\n');
            std::string line = rest.substr(0, nl);
            rest = nl == std::string::npos ? "" : rest.substr(nl + 1);
            bool heading = line.rfind("# ", 0) == 0;
            if (out.length) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
            [out appendAttributedString:[[NSAttributedString alloc]
                                            initWithString:ADIFString(heading ? line.substr(2) : line)
                                                attributes:@{NSFontAttributeName : heading ? head : plain,
                                                             NSForegroundColorAttributeName : heading ? NSColor.secondaryLabelColor : NSColor.labelColor}]];
        }
        mw.detailsText.attributedStringValue = out;
    }
}

// The contact panel for what's under the pointer, or chosen, or nothing: its description, and
// for a station (a spot, a contact, a DXCC entity) its entity's band slots.
void showContact(const ADIFMapHit &h, const std::string &text) {
    mw.status.stringValue = ADIFString(text);
    showChosenFacts(h);
    int dxcc = 0;
    std::string entity, call;
    const adif::CountryTable &countries = ADIFCountries();
    auto place = [&](const std::string &c, int fieldDxcc) {
        adif::CountryInfo info;
        call = c;
        if (fieldDxcc > 0) dxcc = fieldDxcc;
        else if (!countries.empty() && countries.lookup(c, &info)) dxcc = info.dxcc;
        entity = entityName(dxcc, c);
    };
    if (h.kind == ADIFMapHit::Spot && h.index < mw.view.spots.size()) {
        const ADIFMapSpot &ms = mw.view.spots[h.index];
        if (!ms.spot.heardMe) dxcc = ms.status.dxcc, entity = ms.status.entity, call = ms.spot.activator;
    } else if (h.kind == ADIFMapHit::Contact && h.index < mw.view.contacts.size() && !mw.view.contacts[h.index].qsos.empty()) {
        const adif::MapQso &q = mw.data.qsos[mw.view.contacts[h.index].qsos[0]];
        place(q.call, q.dxcc);
    } else if (h.kind == ADIFMapHit::Dxcc && h.index < mw.dxcc.size()) {
        dxcc = mw.dxcc[h.index].dxcc, entity = mw.dxcc[h.index].name;
    }
    if (mw.contactTitle) {  // the station's or the entity's flag before it
        std::string title = flagged(dxcc, contactTitle(h));
        mw.contactTitle.stringValue = ADIFString(title);
        mw.contactTitle.hidden = title.empty();
    }
    showSlots(dxcc, entity, call);
}

std::string callsOf(const std::vector<size_t> &qsos) {
    std::vector<std::string> calls;
    for (size_t i : qsos)
        if (i < mw.data.qsos.size() && std::find(calls.begin(), calls.end(), mw.data.qsos[i].call) == calls.end()) calls.push_back(mw.data.qsos[i].call);
    std::string out;
    for (size_t k = 0; k < calls.size() && k < 5; ++k) out += (out.empty() ? "" : ", ") + calls[k];
    if (calls.size() > 5) out += ", +" + std::to_string(calls.size() - 5);
    return out;
}

// "{km} km at {bearing}° from {home}." from home to a place, or "" without a home.
// A spotted station in this log: worked on its band, on others, or not at all.
std::string inLog(const adif::Spot &sp) {
    bool band = false, other = false;
    std::string call = adif::spotterCall(sp.activator);  // without a suffix after "-"
    for (const adif::MapQso &q : mw.data.qsos)
        if (adif::spotterCall(q.call) == call) (q.band == sp.band ? band : other) = true;
    return band ? trf("worked on {band}", {{"band", sp.band}}) : other ? tr("worked on other bands") : tr("not in this log");
}

std::string fromHome(double lat, double lon) {
    double hlat, hlon;
    if (mw.home.empty() || !adif::gridToLatLon(mw.home, &hlat, &hlon)) return "";
    char bearing[16];
    snprintf(bearing, sizeof bearing, "%.0f", adif::initialBearing(hlat, hlon, lat, lon));
    return " " + trf("{km} km at {bearing}° from {home}.", {{"km", std::to_string(std::lround(adif::greatCircleKm(hlat, hlon, lat, lon)))},
                                                              {"bearing", bearing}, {"home", mw.home}});
}

// "3 QSOs, confirmed (K1AB, W2CD)" or "3 QSOs (K1AB, W2CD)".
std::string worked(const std::vector<size_t> &qsos, bool confirmed) {
    return trf(confirmed ? "{qsos}, confirmed ({calls})" : "{qsos} ({calls})", {{"qsos", plural(qsos.size(), "QSO")}, {"calls", callsOf(qsos)}});
}

std::string describe(const ADIFMapHit &h) {
    std::string where;
    if (!mw.home.empty() && !h.square.empty()) {
        std::string d = adif::gridDistanceText(mw.home, h.square);
        if (!d.empty()) where = " " + trf("{distance} from {home}.", {{"distance", d}, {"home", mw.home}});
    }
    switch (h.kind) {
        case ADIFMapHit::Square: {
            const adif::MapSquare &sq = mw.data.squares[h.index];
            return sq.grid + ": " + worked(sq.qsoIndex, sq.confirmed) + "." + where;
        }
        case ADIFMapHit::Beacon: {
            if (h.index >= adif::kBeaconCount) break;
            const adif::Beacon &b = adif::kBeacons[h.index];
            double now = [[NSDate date] timeIntervalSince1970], lat = 0, lon = 0;
            size_t sending = adif::beaconBand(h.index, now), band = mw.view.beaconBand >= 0 ? (size_t)mw.view.beaconBand : sending < adif::kBeaconBands ? sending : 0;
            std::string when = beaconNext(h.index, band, now);
            std::string text = trf("NCDXF beacon {call}, {place} ({grid})", {{"call", b.call}, {"place", b.location}, {"grid", b.grid}}) + ": " +
                               (when == tr("now") ? trf("sending on {mhz} MHz now.", {{"mhz", beaconMHz(band)}})
                                                  : trf("next on {mhz} MHz at {time}.", {{"mhz", beaconMHz(band)}, {"time", when}}));
            return adif::gridToLatLon(b.grid, &lat, &lon) ? text + fromHome(lat, lon) : text;
        }
        case ADIFMapHit::Dxcc: {
            const ADIFMapEntity &e = mw.dxcc[h.index];
            return trf("{name} (DXCC {n})", {{"name", e.name}, {"n", std::to_string(e.dxcc)}}) + ": " + worked(e.qsos, e.confirmed);
        }
        case ADIFMapHit::Park: {
            const adif::MapPark &p = mw.data.parks[h.index];
            size_t n = 0;
            for (const adif::MapPark &o : mw.data.parks) n += o.reference == p.reference && o.program == p.program;
            const adif::MapQso &q = mw.data.qsos[p.qso];
            return trf("{program} {ref}: {qsos}, in {grid} ({call} {date})",
                       {{"program", p.program}, {"ref", p.reference}, {"qsos", plural(n, "QSO")}, {"grid", p.grid}, {"call", q.call}, {"date", q.date}});
        }
        case ADIFMapHit::Contact: {
            const ADIFMapContact &c = mw.view.contacts[h.index];
            const adif::MapQso &q = mw.data.qsos[c.qsos[0]];
            char at[64];
            snprintf(at, sizeof at, "%.4f %c, %.4f %c", std::fabs(c.lat), c.lat < 0 ? 'S' : 'N', std::fabs(c.lon), c.lon < 0 ? 'W' : 'E');
            return trf("{calls}: {qsos} at {place} (from {source}).",
                       {{"calls", callsOf(c.qsos)}, {"qsos", plural(c.qsos.size(), "QSO")}, {"place", at}, {"source", q.locatedBy}}) +
                   fromHome(c.lat, c.lon);
        }
        case ADIFMapHit::Pota: {
            if (h.index >= ADIFPotaParks().size()) break;
            const adif::PotaPark &p = ADIFPotaParks().parks()[h.index];
            ADIFParkWork w = [mw.view parkWork:p.ref];
            std::string what;
            if (!w.hunted.empty()) {
                bool confirmed = false;
                for (size_t qi : w.hunted) confirmed |= qi < mw.data.qsos.size() && mw.data.qsos[qi].confirmed;
                what = trf("hunted, {qsos}", {{"qsos", worked(w.hunted, confirmed)}});
            }
            if (!w.activated.empty())
                what += (what.empty() ? "" : "; ") + trf("activated by you, {qsos}", {{"qsos", plural(w.activated.size(), "QSO")}});
            if (what.empty()) what = tr("not worked");
            // Where its outline came from, and what a match by name took it to be.
            std::string outline;
            if (const adif::ParkOutline *o = parkoutlines::find(p.ref))
                outline = " " + (o->matched ? trf("Outline: {source}, matched by name: {name}.", {{"source", o->source}, {"name", o->name}})
                                            : trf("Outline: {source}.", {{"source", o->source}}));
            return trf(p.active ? "POTA {ref} {name} ({location}): {what}." : "POTA {ref} {name} ({location}, inactive): {what}.",
                       {{"ref", p.ref}, {"name", p.name}, {"location", p.location}, {"what", what}}) +
                   outline + fromHome(p.lat, p.lon);
        }
        case ADIFMapHit::Area: {
            const adif::AreaIndex &index = adif::areaIndex(layerOverlay(h.layer));
            if (h.index >= index.size()) break;
            std::string name = index.area(h.index).name;
            std::vector<size_t> qsos = [mw.view areaQsos:h.layer name:name];
            bool confirmed = false;
            size_t byField = 0, byPlace = 0, byCty = 0;
            for (size_t qi : qsos) {
                if (qi >= mw.data.qsos.size()) continue;
                const adif::QsoAreas &a = mw.data.qsos[qi].areas;
                confirmed |= mw.data.qsos[qi].confirmed;
                adif::AreaFrom from = h.layer == kLayerStates ? a.stateFrom : h.layer == kLayerCounties ? a.countyFrom : h.layer == kLayerCq ? a.cqFrom : a.ituFrom;
                byField += from == adif::AreaFrom::Field, byPlace += from == adif::AreaFrom::Location, byCty += from == adif::AreaFrom::CountryFile;
            }
            static const char *const kField[] = {"", "", "STATE", "CNTY", "CQZ", "ITUZ"};
            std::string title = h.layer == kLayerCq    ? trf("CQ zone {n}", {{"n", name}})
                                : h.layer == kLayerItu ? trf("ITU zone {n}", {{"n", name}})
                                : h.layer == kLayerCounties && name.size() > 3 ? name.substr(3) + ", " + name.substr(0, 2)
                                                                                 : name;
            std::string from;
            auto part = [&](size_t n, const std::string &how) {
                if (n) from += (from.empty() ? "" : ", ") + how;
            };
            part(byField, trf("{n} by {field}", {{"n", std::to_string(byField)}, {"field", kField[h.layer]}}));
            part(byPlace, trf("{n} by where the QSO was", {{"n", std::to_string(byPlace)}}));
            part(byCty, trf("{n} by the country data", {{"n", std::to_string(byCty)}}));
            return title + ": " + worked(qsos, confirmed) + (from.empty() ? "" : "; " + from) + "." + where;
        }
        case ADIFMapHit::Iota: {
            if (h.index >= ADIFIotaGroups().size()) break;
            const adif::IotaGroup &g = ADIFIotaGroups()[h.index];
            std::vector<size_t> qsos = [mw.view iotaQsos:g.ref];
            bool confirmed = false;
            for (size_t qi : qsos) confirmed |= qi < mw.data.qsos.size() && mw.data.qsos[qi].confirmed;
            return "IOTA " + g.ref + " " + g.name + ": " + (qsos.empty() ? tr("not worked") : worked(qsos, confirmed)) + "." + where;
        }
        case ADIFMapHit::Spot: {
            if (h.index >= mw.view.spots.size()) break;
            const ADIFMapSpot &ms = mw.view.spots[h.index];
            const adif::Spot &sp = ms.spot;
            std::string what = sp.khz + " kHz" + (sp.mode.empty() ? "" : " " + sp.mode);
            std::string ref = sp.reference.empty() ? "" : " " + trf("at {ref}", {{"ref", sp.program.empty() ? sp.reference : sp.program + " " + sp.reference}}) +
                                                        (sp.park.empty() ? "" : " (" + sp.park + ")");
            long long age = sp.epoch > 0 ? std::max<long long>(0, (long long)time(nullptr) - sp.epoch) / 60 : -1;
            std::string when = age < 0 ? "" : age == 0 ? tr("just now") : trp("{n} minute ago", "{n} minutes ago", age);
            std::string by = sp.spotter.empty() ? tr(adif::spotSourceName(sp.source))
                                                : trf("by {spotter} ({source})", {{"spotter", sp.spotter}, {"source", tr(adif::spotSourceName(sp.source))}});
            std::string log = inLog(sp);
            if (sp.heardMe)  // PSKReporter: your own signal, and the stations that heard it
                return trp("Your signal ({call}) on {what}, {when}: heard by {n} station (PSKReporter).",
                           "Your signal ({call}) on {what}, {when}: heard by {n} stations (PSKReporter).", (long long)ms.heard.size(),
                           {{"call", sp.activator}, {"what", what}, {"when", when}}) +
                       fromHome(ms.lat, ms.lon);
            std::string text = trf("{call} on {what}{ref}, spotted {when} {by}; {log}.",
                                   {{"call", sp.activator}, {"what", what}, {"ref", ref}, {"when", when}, {"by", by}, {"log", log}});
            if (sp.hasSnr) text += " " + trf("Signal report {snr}.", {{"snr", adif::spotSnr(sp)}});
            if (ms.heard.size() > 1)
                text += " " + trp("Heard by {n} spotter.", "Heard by {n} spotters.", (long long)ms.heard.size());
            if (!sp.comments.empty()) text += " \u201c" + sp.comments + "\u201d";
            return text + fromHome(ms.lat, ms.lon);
        }
        case ADIFMapHit::Spotter: {
            if (h.index >= mw.view.spotters.size()) break;
            const ADIFMapSpotter &st = mw.view.spotters[h.index];
            // The stations it heard, newest first.
            std::string list;
            for (size_t n = 0; n < st.spots.size() && n < 6; ++n) {
                const adif::Spot &sp = mw.view.spots[st.spots[n]].spot;
                list += (list.empty() ? "" : ", ") + sp.activator + " " + sp.band;
            }
            if (st.spots.size() > 6) list += ", +" + std::to_string(st.spots.size() - 6);
            std::string text = trp("{call}, a spotter: heard {n} station: {list}.", "{call}, a spotter: heard {n} stations: {list}.",
                                   (long long)st.spots.size(), {{"call", st.call}, {"list", list}});
            if (st.call.size() > 2 && st.call.compare(st.call.size() - 2, 2, "-#") == 0)
                text += " " + tr("A Reverse Beacon Network skimmer.");
            return text + fromHome(st.lat, st.lon);
        }
        case ADIFMapHit::Empty: return trf("{square}: no QSOs.", {{"square", h.square}}) + where;
        case ADIFMapHit::None: break;
    }
    return "";
}

void fillViewList();
void showListKind(int kind);

// The QSOs of what was chosen, for the list's Selected: shown there when a click on the map chose
// them, unless the list shows that kind of thing already (a park clicked while it lists parks,
// a spot while it lists spots, a contact or square while it lists contacts).
void showList(const std::vector<size_t> &qsos, ADIFMapHit::Kind kind = ADIFMapHit::None) {
    mw.listed = qsos;
    mw.listPage[0] = 0;
    NSInteger shown = mw.listKind.selectedSegment;
    bool same = (shown == 2 && kind == ADIFMapHit::Pota) || (shown == 3 && (kind == ADIFMapHit::Spot || kind == ADIFMapHit::Spotter)) ||
                (shown == 1 && (kind == ADIFMapHit::Contact || kind == ADIFMapHit::Square)) || (shown == kListDxcc && kind == ADIFMapHit::Dxcc);
    if (!qsos.empty() && !mw.choosingFromList && !same) {
        if (shown != kListSelected) mw.listBackKind = (int)shown;  // Back to it
        showListKind(0);
    } else {
        fillViewList();
    }
}

// What a spot means for the log, in words: "new DXCC: Japan", "new band for Germany (17m)",
// "Germany worked on 40m"; and "new park" for a POTA park not hunted.
std::string spotNeedLine(const adif::SpotStatus &st, const std::string &band) {
    std::string out;
    switch (st.need) {
        case adif::SpotNeed::NewDxcc: out = trf("new DXCC: {entity}", {{"entity", st.entity}}); break;
        case adif::SpotNeed::NewBand: out = trf("new band for {entity} ({band})", {{"entity", st.entity}, {"band", band}}); break;
        case adif::SpotNeed::NewMode: out = trf("new mode on {band} for {entity}", {{"entity", st.entity}, {"band", band}}); break;
        case adif::SpotNeed::Worked: out = trf("{entity} worked on {band}, not confirmed", {{"entity", st.entity}, {"band", band}}); break;
        case adif::SpotNeed::Confirmed: out = trf("{entity} confirmed on {band}", {{"entity", st.entity}, {"band", band}}); break;
        default: break;
    }
    if (st.newPark) out += (out.empty() ? "" : "; ") + tr("new park");
    return out;
}

// The information box for a clicked spot or spotter: everything known about the station.
std::vector<ADIFInfoRow> spotInfo(const ADIFMapHit &h);
std::vector<ADIFInfoRow> spotInfo(const ADIFMapHit &h) {
    std::vector<ADIFInfoRow> rows;
    auto row = [&](const char *label, const std::string &value) {
        if (!value.empty()) rows.push_back({tr(label), value, false});
    };
    long long now = (long long)time(nullptr);
    const adif::CountryTable *countries = &ADIFCountries();
    auto position = [&](double lat, double lon, const std::string &from) {
        char b[64];
        snprintf(b, sizeof b, "%.2f\u00B0 %c, %.2f\u00B0 %c", std::fabs(lat), lat >= 0 ? 'N' : 'S', std::fabs(lon), lon >= 0 ? 'E' : 'W');
        std::string how = from == "grid" ? tr("from its grid") : from == "country data" ? tr("the country's, from the country data") : from == "spot" ? tr("from the spot") : "";
        row(N_("Position"), std::string(b) + (how.empty() ? "" : " (" + how + ")"));
    };
    auto country = [&](const std::string &call) {
        adif::CountryInfo ci;
        if (!countries->lookup(adif::spotterCall(call), &ci)) return;
        row(N_("Country"), ci.name + " (DXCC " + std::to_string(ci.dxcc) + ")");
        row(N_("Continent"), ci.continent);
        row(N_("Zones"), trf("CQ {cq}, ITU {itu}", {{"cq", std::to_string(ci.cq)}, {"itu", std::to_string(ci.itu)}}));
    };
    auto distance = [&](double lat, double lon) {
        double hlat, hlon;
        if (mw.home.empty() || !adif::gridToLatLon(mw.home, &hlat, &hlon)) return;
        char bearing[16];
        snprintf(bearing, sizeof bearing, "%.0f", adif::initialBearing(hlat, hlon, lat, lon));
        row(N_("Distance"), trf("{km} km at {bearing}\u00B0 from {home}", {{"km", std::to_string(std::lround(adif::greatCircleKm(hlat, hlon, lat, lon)))},
                                                                       {"bearing", bearing}, {"home", mw.home}}));
    };
    auto heard = [&](const std::string &call, bool hasSnr, int snr, long long epoch) {
        std::string s = call;
        if (hasSnr) {
            char db[16];
            snprintf(db, sizeof db, "   %+d dB", snr);
            s += db;
        }
        std::string age = adif::spotAge(epoch, now);
        return age.empty() ? s : s + "   " + age;
    };
    // A list, the first row labelled, at most 15 rows and then how many more.
    auto list = [&](const char *label, const std::vector<std::string> &items) {
        for (size_t i = 0; i < items.size() && i < 15; ++i) rows.push_back({i ? "" : tr(label), items[i], false});
        if (items.size() > 15) rows.push_back({"", trf("and {n} more", {{"n", std::to_string(items.size() - 15)}}), false});
    };
    if (h.kind == ADIFMapHit::Spot && h.index < mw.view.spots.size()) {
        const ADIFMapSpot &ms = mw.view.spots[h.index];
        const adif::Spot &sp = ms.spot;
        rows.push_back({sp.heardMe ? trf("{call}: your signal", {{"call", sp.activator}}) : sp.activator, "", true});
        row(N_("Frequency"), sp.khz.empty() ? "" : sp.khz + " kHz");
        row(N_("Band"), sp.band);
        row(N_("Mode"), sp.mode);
        std::string age = adif::spotAge(sp.epoch, now);
        if (!sp.time.empty()) row(N_("Spotted"), sp.time + " UTC" + (age.empty() ? "" : " (" + age + ")"));
        // Spothole keeps where it had the spot from (Cluster, RBN, POTA...) where POTA keeps the location.
        bool via = sp.source == adif::SpotSource::Spothole && !sp.location.empty();
        row(N_("Source"), tr(adif::spotSourceName(sp.source)) + (via ? " (" + sp.location + ")" : ""));
        std::string refs;
        for (const std::string &r : sp.refs) refs += (refs.empty() ? "" : ", ") + r;
        if (refs.empty()) refs = sp.reference;
        if (!refs.empty()) row(N_("Reference"), sp.program.empty() ? refs : sp.program + " " + refs);
        row(N_("Name"), sp.park);
        if (!via && sp.location != sp.program) row(N_("Location"), sp.location);
        row(N_("Signal report"), adif::spotSnr(sp));
        row(N_("Grid"), sp.grid);
        position(ms.lat, ms.lon, adif::spotPlace(sp, countries).from);
        country(sp.activator);
        distance(ms.lat, ms.lon);
        if (!sp.heardMe) row(N_("In this log"), inLog(sp));
        if (!sp.heardMe) row(N_("For this log"), spotNeedLine(ms.status, sp.band));
        row(N_("Comment"), sp.comments);
        std::vector<std::string> by;
        for (const ADIFSpotHeard &hd : ms.heard) by.push_back(heard(hd.call, hd.hasSnr, hd.snr, hd.epoch));
        list(N_("Heard by"), by);
    } else if (h.kind == ADIFMapHit::Spotter && h.index < mw.view.spotters.size()) {
        const ADIFMapSpotter &st = mw.view.spotters[h.index];
        rows.push_back({st.call, "", true});
        if (st.call.size() > 2 && st.call.compare(st.call.size() - 2, 2, "-#") == 0) row(N_("Station"), tr("A Reverse Beacon Network skimmer."));
        std::string grid, from = "country data";
        std::vector<std::string> items;
        for (size_t k : st.spots) {
            const ADIFMapSpot &ms = mw.view.spots[k];
            for (const ADIFSpotHeard &hd : ms.heard) {
                if (adif::spotterCall(hd.call) != adif::spotterCall(st.call)) continue;
                std::string what = ms.spot.activator + " " + ms.spot.band + (ms.spot.mode.empty() ? "" : " " + ms.spot.mode);
                items.push_back(heard(what, hd.hasSnr, hd.snr, hd.epoch));
                break;
            }
            if (grid.empty() && adif::spotterCall(ms.spot.spotter) == adif::spotterCall(st.call)) {
                grid = ms.spot.spotterGrid;
                from = adif::spotterPlace(ms.spot, countries).from;
            }
        }
        row(N_("Grid"), grid);
        position(st.lat, st.lon, from);
        country(st.call);
        distance(st.lat, st.lon);
        list(N_("Heard"), items);
    }
    return rows;
}

void showListRow(const ADIFMapHit &h);

void selected(const ADIFMapHit &h) {
    if (h.kind != mw.markedFor.kind || h.index != mw.markedFor.index) mw.markedDxcc = 0;  // something else chosen: its own row
    std::vector<size_t> qsos;
    if (h.kind == ADIFMapHit::Square) qsos = mw.data.squares[h.index].qsoIndex;
    else if (h.kind == ADIFMapHit::Dxcc) qsos = mw.dxcc[h.index].qsos;
    else if (h.kind == ADIFMapHit::Contact) qsos = mw.view.contacts[h.index].qsos;
    else if (h.kind == ADIFMapHit::Area) {
        const adif::AreaIndex &index = adif::areaIndex(layerOverlay(h.layer));
        if (h.index < index.size()) qsos = [mw.view areaQsos:h.layer name:index.area(h.index).name];
    } else if (h.kind == ADIFMapHit::Iota && h.index < ADIFIotaGroups().size()) qsos = [mw.view iotaQsos:ADIFIotaGroups()[h.index].ref];
    else if (h.kind == ADIFMapHit::Pota && h.index < ADIFPotaParks().size()) {
        ADIFParkWork w = [mw.view parkWork:ADIFPotaParks().parks()[h.index].ref];
        qsos = w.hunted;
        for (size_t qi : w.activated)
            if (std::find(qsos.begin(), qsos.end(), qi) == qsos.end()) qsos.push_back(qi);
    }
    else if (h.kind == ADIFMapHit::Park)
        for (const adif::MapPark &p : mw.data.parks)
            if (p.reference == mw.data.parks[h.index].reference && p.program == mw.data.parks[h.index].program) qsos.push_back(p.qso);
    showList(qsos, h.kind);
    mw.useSpot.hidden = h.kind != ADIFMapHit::Spot;
    mw.viewQso.hidden = qsos.size() != 1;  // one QSO chosen: its record, a click away
    showWatchButton(h);
    fillBandConditions();  // the chosen spot's band
    mw.centerButton.enabled = h.kind != ADIFMapHit::None;
    mw.centerButton.hidden = h.kind == ADIFMapHit::None;
    mw.actions.needsLayout = YES;
    [mw.view setInfo:h.kind == ADIFMapHit::Spot || h.kind == ADIFMapHit::Spotter ? spotInfo(h) : std::vector<ADIFInfoRow>{}];
    mw.chosen = h.kind == ADIFMapHit::None ? "" : describe(h) + (qsos.empty() ? "" : " " + tr("Double-click a QSO to go to it in the log."));
    mw.chosenHit = h;
    showContact(h, mw.chosen.empty() ? idleStatus() : mw.chosen);
    showListRow(h);
}

void updateZoomLabel() {
    double z = mw.view.zoom;
    mw.zoomLabel.stringValue = z < 10 ? [NSString stringWithFormat:@"%.1f×", z] : [NSString stringWithFormat:@"%.0f×", z];
}

// The map's projection; the globe is centred on home, else on the log's squares.
void applyProjection() {
    double lat = 0, lon = 0;
    bool home = !mw.home.empty() && adif::gridToLatLon(mw.home, &lat, &lon);
    int p = number("mapProjection", 0, 3);
    static const adif::Projection kinds[] = {adif::Projection::Equirectangular, adif::Projection::Mercator, adif::Projection::EqualEarth,
                                             adif::Projection::Globe};
    double clat = lat, clon = lon;
    if (!home) {  // the middle of the squares worked (the mean of their directions from the Earth's centre)
        double x = 0, y = 0, z = 0;
        for (const adif::MapSquare &sq : mw.data.squares) {
            double a, o;
            if (!adif::gridToLatLon(sq.grid, &a, &o)) continue;
            a *= M_PI / 180, o *= M_PI / 180;
            x += std::cos(a) * std::cos(o), y += std::cos(a) * std::sin(o), z += std::sin(a);
        }
        if (std::hypot(x, y, z) > 1e-9) clat = std::atan2(z, std::hypot(x, y)) * 180 / M_PI, clon = std::atan2(y, x) * 180 / M_PI;
        else clat = 20, clon = 0;
    }
    adif::Projector pr(kinds[p], clat, clon);
    [mw.view setProjector:pr home:home ? ADIFString(mw.home) : @"" lat:lat lon:lon];
    [mw.projection itemAtIndex:3].title = home ? [NSString stringWithFormat:T(@"Globe from %@"), ADIFString(mw.home)] : T(@"Globe");
    [mw.projection selectItemAtIndex:p];
    [mw.projection invalidateIntrinsicContentSize];  // as wide as its widest item, renamed or not
}

void queueViewList();
void applyParkPlaces();
void showContact(const ADIFMapHit &h, const std::string &text);

// The zoom buttons on the map in the map's own light or dark.
void updatePanelLook() {
    mw.nav.appearance = [NSAppearance appearanceNamed:paletteAt(mw.view.style.palette).dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
}

void updatePropagation();

void applyStyle() {
    mw.view.style = savedStyle();
    mw.view.scaleInMiles = setting("mapListUnits") == "mi";
    updatePanelLook();
    mw.view.hiddenPrograms = hiddenPrograms();
    queueViewList();
    updatePropagation();
}

// ── Propagation: space weather (NOAA SWPC) and the NCDXF beacons ──

// "SFI 101 · K 2- · A 11", or "" before any.
std::string solarSummary() {
    const adif::SpaceWeather &w = solar::weather();
    std::string out;
    auto add = [&](const std::string &part) { out += (out.empty() ? "" : "  \u00B7  ") + part; };
    if (w.sfi > 0) add("SFI " + std::to_string(std::lround(w.sfi)));
    if (w.kp >= 0) add("K " + adif::kpText(w.kp));
    if (w.ap >= 0) add("A " + std::to_string(w.ap));
    return out;
}

void showSituation();
void fillBandConditions();

// The header's space weather: the indices, coloured by the NOAA geomagnetic storm scale; or the
// offer to turn it on.
void fillSolarTile() {
    if (!mw.solarTile) return;
    bool on = flag("mapSolar", false);
    std::string sum = solarSummary();
    const adif::SpaceWeather &w = solar::weather();
    mw.solarTile.title = on && !sum.empty() ? ADIFString(sum) : T(@"Space weather");
    mw.solarTile.contentTintColor = !on || sum.empty() ? NSColor.secondaryLabelColor
                                    : w.g >= 3 ? NSColor.systemRedColor
                                    : w.g >= 1 ? NSColor.systemOrangeColor
                                               : NSColor.labelColor;
    mw.solarTile.toolTip = ADIFString(on ? solar::status() + (w.g >= 0 ? "; " + trf("geomagnetic storms G{g} ({text})", {{"g", std::to_string(w.g)}, {"text", w.gText}}) : "") +
                                               ". " + tr("Click for more")
                                         : tr("Solar flux, the K and A indices, X-rays and the NOAA scales from NOAA SWPC: click to turn on"));
}

// "▁▂▃" for the last day's Kp, a bar each 3 hours.
std::string kpBars(const adif::SpaceWeather &w) {
    static const char *const kBars[] = {"\u2581", "\u2582", "\u2583", "\u2584", "\u2585", "\u2586", "\u2587", "\u2588"};
    std::string out;
    for (const auto &[at, kp] : w.kpRecent) out += kBars[std::clamp((int)std::lround(kp * 7 / 9), 0, 7)];
    return out;
}

void showSolarPopover();

// The popover's content, again as the data changes.
NSView *solarPopoverView() {
    const adif::SpaceWeather &w = solar::weather();
    bool on = flag("mapSolar", false);
    NSMutableArray<NSView *> *parts = [NSMutableArray array];
    NSTextField *title = [NSTextField labelWithString:T(@"Space weather")];
    title.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    [parts addObject:title];
    NSButton *box = ADIFCheckbox(@"Get space weather from NOAA SWPC", on);
    box.toolTip = T(@"Every 15 minutes while the Map is open, from services.swpc.noaa.gov; nothing in Offline mode");
    box.identifier = @"map.solar.on";
    __weak NSButton *weakBox = box;
    ADIFOnAction(box, ^{
        saveFlag("mapSolar", weakBox.state == NSControlStateValueOn);
        updatePropagation();
        fillSolarTile();
        showSolarPopover();
    });
    [parts addObject:box];
    if (on) {
        auto day = [](const std::string &iso) {  // "2026-10-23T20:00:00" as "Oct 23, 20:00 UTC"
            if (iso.size() < 16) return iso;
            struct tm tm{};
            tm.tm_year = std::atoi(iso.substr(0, 4).c_str()) - 1900, tm.tm_mon = std::atoi(iso.substr(5, 2).c_str()) - 1, tm.tm_mday = std::atoi(iso.substr(8, 2).c_str());
            tm.tm_hour = std::atoi(iso.substr(11, 2).c_str()), tm.tm_min = std::atoi(iso.substr(14, 2).c_str());
            return utcAt((long long)timegm(&tm), "%Y-%m-%d %H:%M UTC");
        };
        std::vector<std::pair<std::string, std::string>> rows;
        rows.push_back({tr("Solar flux (10.7 cm)"), w.sfi > 0 ? std::to_string(std::lround(w.sfi)) + " sfu  (" + day(w.sfiTime) + ")" : ""});
        rows.push_back({tr("Planetary K"), w.kp >= 0 ? adif::kpText(w.kp) + "  (" + day(w.kpTime) + ")" : ""});
        if (!w.kpRecent.empty()) rows.push_back({tr("K, the last 24 hours"), kpBars(w)});
        rows.push_back({tr("A index"), w.ap >= 0 ? std::to_string(w.ap) + "  (" + w.apDate + ")" : ""});
        rows.push_back({tr("X-rays"), w.xray > 0 ? adif::flareClass(w.xray) + "  (" + day(w.xrayTime) + ")" : ""});
        auto scale = [](const char *letter, int n, const std::string &text) { return n < 0 ? std::string() : letter + std::to_string(n) + " " + text; };
        std::string scales = scale("R", w.r, w.rText);
        for (const std::string &x : {scale("S", w.s, w.sText), scale("G", w.g, w.gText)})
            if (!x.empty()) scales += (scales.empty() ? "" : "  \u00B7  ") + x;
        rows.push_back({tr("NOAA scales"), scales});
        NSGridView *grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
        grid.rowSpacing = 4;
        grid.columnSpacing = 10;
        grid.identifier = @"map.solar.facts";
        for (const auto &[label, value] : rows) {
            NSTextField *l = [NSTextField labelWithString:ADIFString(label)], *v = [NSTextField labelWithString:ADIFString(value.empty() ? tr("Unavailable") : value)];
            l.textColor = NSColor.secondaryLabelColor;
            v.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
            [grid addRowWithViews:@[ l, v ]];
        }
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        [parts addObject:grid];
        NSTextField *status = [NSTextField wrappingLabelWithString:ADIFString(solar::status())];
        status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        status.textColor = NSColor.secondaryLabelColor;
        status.identifier = @"map.solar.status";
        [status.widthAnchor constraintLessThanOrEqualToConstant:340].active = YES;
        [parts addObject:status];
        NSButton *refreshButton = [NSButton buttonWithTitle:T(@"Refresh") target:nil action:nil];
        ADIFOnAction(refreshButton, ^{
            setStatus(solar::refreshNow());
            showSolarPopover();
        });
        NSButton *source = [NSButton buttonWithTitle:T(@"NOAA SWPC (public domain)") target:nil action:nil];
        source.bordered = NO;
        source.contentTintColor = NSColor.linkColor;
        source.toolTip = T(@"The Space Weather Prediction Center's site, in your browser");
        ADIFOnAction(source, ^{ ADIFOpenURL(@"https://www.swpc.noaa.gov/"); });
        NSStackView *buttons = [NSStackView stackViewWithViews:@[ refreshButton, source ]];
        [parts addObject:buttons];
    }
    NSStackView *stack = [NSStackView stackViewWithViews:parts];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);
    return stack;
}

void showSolarPopover() {
    if (!mw.solarTile) return;
    if (!mw.solarPopover) {
        mw.solarPopover = [[NSPopover alloc] init];
        mw.solarPopover.behavior = NSPopoverBehaviorTransient;
        mw.solarPopover.contentViewController = [[NSViewController alloc] init];
    }
    NSView *content = solarPopoverView();
    mw.solarPopover.contentViewController.view = content;
    mw.solarPopover.contentSize = content.fittingSize;
    if (!mw.solarPopover.shown) [mw.solarPopover showRelativeToRect:mw.solarTile.bounds ofView:mw.solarTile preferredEdge:NSRectEdgeMaxY];
}

// What propagation wants while the Map is open: space weather (the tile's switch, the Aurora layer)
// and the beacons' timer, which redraws them as they take turns.
void updatePropagation() {
    bool open = mw.window && mw.window.visible;
    solar::setWanted(open && flag("mapSolar", false), open && flag("mapAurora", false));
    if (open && flag("mapBeacons", false)) {
        if (!mw.beaconTimer)
            mw.beaconTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                             repeats:YES
                                                               block:^(NSTimer *) {
                                                                   static long long slot = -1;
                                                                   long long now = (long long)std::floor([[NSDate date] timeIntervalSince1970] / 10);
                                                                   if (now == slot) return;
                                                                   slot = now;
                                                                   mw.view.needsDisplay = YES;
                                                                   if (mw.view.selectedHit.kind == ADIFMapHit::Beacon) showChosenFacts(mw.view.selectedHit);
                                                               }];
    } else {
        [mw.beaconTimer invalidate];
        mw.beaconTimer = nil;
    }
}

NSImage *swatch(NSColor *color, bool diamond) {
    return [NSImage imageWithSize:NSMakeSize(12, 12)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect r) {
                       NSBezierPath *p = [NSBezierPath bezierPath];
                       if (diamond) {
                           [p moveToPoint:NSMakePoint(6, 11)];
                           [p lineToPoint:NSMakePoint(1, 6)];
                           [p lineToPoint:NSMakePoint(6, 1)];
                           [p lineToPoint:NSMakePoint(11, 6)];
                           [p closePath];
                       } else {
                           p = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 1, 1)];
                       }
                       [color setFill];
                       [p fill];
                       return YES;
                   }];
}

NSMenuItem *menuItem(NSMenu *menu, NSString *title, bool on, void (^action)(void)) {
    NSMenuItem *i = [menu addItemWithTitle:T(title) action:nil keyEquivalent:@""];
    i.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if (action) ADIFBlockMenuItem(i, action);
    else i.enabled = NO;
    return i;
}

void refresh();
void refreshSpots();
void fillPrograms();
void fillStyle();
adif::MapFilter savedPlaceFilter();
void updateFilterButton();

// Every other program: the common ones and any other SIG in the log.
std::set<std::string> allPrograms() {
    std::set<std::string> all;
    for (size_t i = 0; i < kProgramCount; ++i) all.insert(kPrograms[i].key);
    for (const adif::MapPark &p : mw.data.parks)
        if (p.program != "POTA") all.insert(p.program);
    return all;
}

// The Other programs list: the common programs, then any other SIG in the log, each with its count.
void fillPrograms() {
    NSMenu *menu = mw.programs.menu;
    menu.autoenablesItems = NO;
    [menu removeAllItems];
    [menu addItemWithTitle:T(@"Other programs") action:nil keyEquivalent:@""];  // the pull-down's own title
    std::map<std::string, std::set<std::string>> refs;
    for (const adif::MapPark &p : mw.data.parks)
        if (p.program != "POTA") refs[p.program].insert(p.reference);
    std::vector<std::pair<std::string, std::string>> list;  // key, label
    for (size_t i = 0; i < kProgramCount; ++i) list.emplace_back(kPrograms[i].key, kPrograms[i].label);
    for (const auto &kv : refs) {
        bool known = false;
        for (size_t i = 0; i < kProgramCount; ++i) known |= kv.first == kPrograms[i].key;
        if (!known) list.emplace_back(kv.first, kv.first);
    }
    std::set<std::string> hidden = hiddenPrograms();
    menuItem(menu, @"Show All", false, ^{
        saveHidden({});
        applyStyle();
        fillPrograms();
    });
    menuItem(menu, @"Hide All", false, ^{
        saveHidden(allPrograms());
        applyStyle();
        fillPrograms();
    });
    [menu addItem:[NSMenuItem separatorItem]];
    for (const auto &[key, label] : list) {
        size_t n = refs.count(key) ? refs[key].size() : 0;
        NSString *title = n ? [NSString stringWithFormat:@"%@: %zu", ADIFString(tr(label)), n]
                            : [NSString stringWithFormat:T(@"%@: none in this log"), ADIFString(tr(label))];
        std::string k = key;
        NSMenuItem *item = menuItem(menu, title, !hidden.count(key), ^{
            std::set<std::string> h = hiddenPrograms();
            if (!h.erase(k)) h.insert(k);
            saveHidden(h);
            applyStyle();
            fillPrograms();
        });
        item.image = swatch([mw.view programColor:key], true);
    }
    bool any = false;
    for (const std::string &k : allPrograms()) any |= !hidden.count(k);
    mw.otherBox.state = any ? NSControlStateValueOn : NSControlStateValueOff;
}

// Other programs' box: off hides them all; on brings back those shown before.
void otherProgramsChanged() {
    std::set<std::string> all = allPrograms();
    if (mw.otherBox.state == NSControlStateValueOn) {
        std::set<std::string> before;
        for (const std::string &k : splitSetting("mapHiddenProgramsBefore", ',')) before.insert(k);
        bool none = true;
        for (const std::string &k : all) none &= before.count(k) > 0;
        saveHidden(none ? std::set<std::string>() : before);
    } else {
        std::string v;
        for (const std::string &k : hiddenPrograms()) v += (v.empty() ? "" : ",") + k;
        setSetting("mapHiddenProgramsBefore", v);
        saveHidden(all);
    }
    applyStyle();
    fillPrograms();
}

// The view with this identifier inside v, or nil.
NSView *findView(NSView *v, NSString *ident) {
    if ([v.identifier isEqualToString:ident]) return v;
    for (NSView *sub in v.subviews)
        if (NSView *found = findView(sub, ident)) return found;
    return nil;
}

// Style Options: how the map looks, in sections; each choice applies at once and is kept.
struct StyleChoice {
    const char *key;
    NSString *ident;
    int fallback;
    NSArray<NSString *> *titles;  // a popup; nil: a checkbox
    NSString *title, *tip;
};
NSArray<NSString *> *const kPaletteTitles = @[ N(@"Standard"), N(@"Colour-blind safe"), N(@"High contrast"), N(@"Light (for printing)"), N(@"Night (red)") ];

void fillStyle() {
    ADIFMapStyle s = savedStyle();
    mw.greyLineBox.state = s.greyLine ? NSControlStateValueOn : NSControlStateValueOff;  // the sidebar's, as Style Options left them
    mw.dayNightBox.state = s.dayNight ? NSControlStateValueOn : NSControlStateValueOff;
    mw.paletteBar.selectedSegment = number("mapPalette", 0, 4);  // the sidebar's and Style Options' the same
    mw.paletteBar.enabled = !ADIFNightMode();
    if (!mw.styleWindow) return;
    NSView *root = mw.styleWindow.contentView;
    if (NSPopUpButton *p = (NSPopUpButton *)findView(root, @"map.style.palette")) [p selectItemAtIndex:number("mapPalette", 0, 4)];
    for (NSString *ident in @[ @"map.style.line", @"map.style.width", @"map.style.strength", @"map.style.arcs" ])
        if (NSControl *c = (NSControl *)findView(root, ident)) c.enabled = s.paths;
    if (NSControl *c = (NSControl *)findView(root, @"map.style.rings")) c.enabled = !mw.home.empty();
    if (NSControl *c = (NSControl *)findView(root, @"map.style.sunTime")) c.enabled = s.dayNight || s.greyLine;
    if (NSControl *c = (NSControl *)findView(root, @"map.style.palette")) c.enabled = !ADIFNightMode();  // Night Mode sets it
    if (NSControl *c = (NSControl *)findView(root, @"map.style.parkOutlines")) c.enabled = !parkoutlines::all().empty();
    for (NSString *ident in @[ @"map.style.spotters", @"map.style.spotLines", @"map.style.spotMode", @"map.style.spotFreq", @"map.style.spotAge", @"map.style.spotSnr",
                               @"map.style.spotFade" ])
        if (NSControl *c = (NSControl *)findView(root, ident)) c.enabled = s[kLayerSpots].show;
}

void showStyleOptions() {
    if (!mw.styleWindow) {
        NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 560)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        p.title = T(@"Style Options");
        p.releasedWhenClosed = NO;
        p.hidesOnDeactivate = NO;
        p.floatingPanel = YES;
        p.identifier = @"map.style";
        ADIFNightTrack(p);
        NSMutableArray *rows = [NSMutableArray array];
        auto section = [&](NSString *title) {
            NSTextField *t = ADIFLabel(title);
            t.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
            [rows addObject:@[ t, [NSGridCell emptyContentView] ]];
        };
        auto add = [&](const StyleChoice &c) {
            NSControl *control;
            if (c.titles) {
                NSPopUpButton *pop = ADIFPopup(c.titles);
                [pop selectItemAtIndex:std::clamp(number(c.key, c.fallback, (int)c.titles.count - 1), 0, (int)c.titles.count - 1)];
                std::string key = c.key;
                ADIFOnAction(pop, ^{
                    setSetting(key.c_str(), std::to_string(pop.indexOfSelectedItem));
                    applyStyle();
                    fillStyle();
                    fillPrograms();  // program swatches follow the palette
                });
                control = pop;
            } else {
                NSButton *box = ADIFCheckbox(c.title, flag(c.key, c.fallback));
                std::string key = c.key;
                ADIFOnAction(box, ^{
                    saveFlag(key.c_str(), box.state == NSControlStateValueOn);
                    applyStyle();
                    fillStyle();
                });
                control = box;
            }
            control.identifier = c.ident;
            control.toolTip = T(c.tip);
            [rows addObject:@[ c.titles ? ADIFLabel(c.title) : [NSGridCell emptyContentView], control ]];
        };
        section(N(@"Colours"));
        add({"mapPalette", @"map.style.palette", 0, kPaletteTitles, N(@"Palette:"),
             N(@"Colour-blind safe: colours that stay apart for red-green and blue-yellow colour blindness. Light: for printing. Night (red): red on "
             @"black, to keep your night vision")});
        section(N(@"Markers"));
        add({"mapMarkerSize", @"map.style.size", 1, @[ N(@"Small"), N(@"Medium##size"), N(@"Large"), N(@"Extra large") ], N(@"Size:"), nil});
        add({"mapMarkerShape", @"map.style.shape", 0, @[ N(@"By layer: dots, triangles, diamonds"), N(@"All circles"), N(@"All squares") ], N(@"Shape:"), nil});
        add({"mapContactMarker", @"map.style.contact", 0, @[ N(@"Pins"), N(@"Dots"), N(@"Crosshairs") ], N(@"Contacts:"), nil});
        section(N(@"Worked areas"));
        add({"mapSquareFill", @"map.style.fill", 0, @[ N(@"Solid##fill"), N(@"See-through"), N(@"Outlines") ], N(@"Grid squares:"), nil});
        add({"mapAreaShade", @"map.style.shade", 1, @[ N(@"Light##shade"), N(@"Medium##shade"), N(@"Strong##shade") ], N(@"Other areas:"),
             N(@"How strongly worked countries, states, counties and zones are shaded")});
        section(N(@"Lines to contacts"));
        add({"mapLineStyle", @"map.style.line", 0, @[ N(@"Solid##line"), N(@"Dashed"), N(@"Dotted") ], N(@"Line:"), nil});
        add({"mapLineWidth", @"map.style.width", 1, @[ N(@"Thin"), N(@"Medium##width"), N(@"Thick") ], N(@"Width:"), nil});
        add({"mapLineOpacity", @"map.style.strength", 1, @[ N(@"Faint"), N(@"Medium##strength"), N(@"Solid##strength") ], N(@"Strength:"),
             N(@"Each line is its contact's marker colour; this is how strongly it shows")});
        add({"mapArcs", @"map.style.arcs", 1, nil, N(@"Arch over the globe"),
             N(@"On the globe, draw each line as an arch rising over it (for looks: the true path, and the beam heading, is the straight line "
             @"you get with this off)")});
        NSUInteger secondColumn = rows.count;  // from here on, the right-hand column
        section(N(@"Spots"));
        add({"mapSpotterStyle", @"map.style.spotters", spotterStyleFallback(),
             @[ N(@"Hidden##spotters"), N(@"Faint grey"), N(@"Markers"), N(@"Markers and calls") ], N(@"Spotters:"),
             N(@"The stations that heard the spots (a cluster's spotters, RBN skimmers; for PSKReporter, you), each a triangle. Point at a "
             @"spot or a spotter for its lines")});
        add({"mapSpotLineStyle", @"map.style.spotLines", 0, @[ N(@"In the spot's colour"), N(@"Faint, in the spot's colour"), N(@"Faint grey") ],
             N(@"Lines:"),
             N(@"The lines from the spotters (the Spots layer's Overlay). The spot under the pointer always shows its lines in its own colour")});
        add({"mapSpotLabelMode", @"map.style.spotMode", 1, nil, N(@"Mode"), N(@"Under each spot's call (the Spots layer's Labels): its mode")});
        rows[rows.count - 1] = @[ ADIFLabel(N(@"Labels show:")), rows.lastObject[1] ];
        add({"mapSpotLabelFreq", @"map.style.spotFreq", 0, nil, N(@"Frequency"), N(@"Under each spot's call: its frequency in kHz")});
        add({"mapSpotLabelAge", @"map.style.spotAge", 1, nil, N(@"Time since spotted"), N(@"Under each spot's call: how long ago it was spotted")});
        add({"mapSpotLabelSnr", @"map.style.spotSnr", 1, nil, N(@"Signal report"),
             N(@"Under each spot's call: the signal report in dB, from an RBN skimmer or PSKReporter")});
        add({"mapSpotFade", @"map.style.spotFade", 1, nil, N(@"Fade older spots"),
             N(@"Spots older than 10 minutes fainter, down to half at the Spots filter's age")});
        section(N(@"POTA parks"));
        add({"mapParkOutlines", @"map.style.parkOutlines", 0, @[ N(@"Badge and outline"), N(@"Outline only") ], N(@"Parks with an outline:"),
             N(@"For the parks whose outlines you downloaded (Settings, POTA Parks, Park Outlines): a badge on the outline, or the outline "
             @"and the park's label alone once it is big enough to see (zoomed further out, the badge again)")});
        section(N(@"On the map"));
        add({"mapReference", @"map.style.reference", 1, @[ N(@"Strong##reference"), N(@"Subtle"), N(@"Faint##reference") ], N(@"Reference layers:"),
             N(@"How strongly the grid, the overlays' lines and names, and the distance rings show: subtle or faint, your QSOs, parks and "
             @"spots stand out from them")});
        add({"mapTerrain", @"map.style.terrain", 0, @[ N(@"Off##terrain"), N(@"Subtle##terrain"), N(@"Strong##terrain") ], N(@"Terrain:"),
             N(@"Mountains and valleys shaded on the land (Natural Earth's shaded relief), fading out as you zoom in past its detail")});
        add({"mapFlags", @"map.style.flags", 1, nil, N(@"Country flags"),
             N(@"A flag before each DXCC entity and station: in the list's Country and DXCC entity columns and the selected panel's title")});
        add({"mapSpotlight", @"map.style.spotlight", 0, nil, N(@"Spotlight what's chosen"),
             N(@"With something clicked on the map, dim the rest of it: the chosen marker, square, area, outline or box stays clear")});
        add({"mapLegend", @"map.style.legend", 1, @[ N(@"Off##legend"), N(@"Top right"), N(@"Bottom left") ], N(@"Legend:"),
             N(@"The key to the map's colours and markers; click a spot's kind or band, or another program, in it to hide or show those")});
        add({"mapTextSize", @"map.style.textSize", 0, @[ N(@"Standard##text"), N(@"Large##text") ], N(@"Map text:"),
             N(@"How big the map's labels, legend, tags and information box are")});
        add({"mapHatch", @"map.style.hatch", 0, nil, N(@"Hatch what isn't confirmed"),
             N(@"Worked squares, countries and areas not yet confirmed get diagonal lines, so confirmation shows without relying on colour")});
        add({"mapRings", @"map.style.rings", 0, nil, N(@"Distance rings from my grid"), nil});
        add({"mapDayNight", @"map.style.dayNight", 0, nil, N(@"Day and night"), N(@"The night side shaded, deeper as the sun goes further down, and the "
                                                                              @"line between day and night; the sun where it is overhead")});
        add({"mapGreyLine", @"map.style.greyLine", 0, nil, N(@"Grey line"),
             N(@"The twilight band, where the sun has set but is less than 6 degrees down (civil twilight), tinted gold: a common time for "
             @"long-distance openings")});
        add({"mapSunTime", @"map.style.sunTime", 0, @[ N(@"Now"), N(@"The selected QSO's time") ], N(@"Sun at:"),
             N(@"Draw day and night for now (updated each minute), or for the time of the QSO you clicked")});
        NSButton *reset = [NSButton buttonWithTitle:T(@"Reset to Defaults") target:nil action:nil];
        reset.identifier = @"map.style.reset";
        ADIFOnAction(reset, ^{
            for (const char *key : {"mapPalette", "mapMarkerSize", "mapMarkerShape", "mapContactMarker", "mapSquareFill", "mapAreaShade", "mapLineStyle",
                                    "mapLineWidth", "mapLineOpacity", "mapArcs", "mapLegend", "mapTextSize", "mapHatch", "mapRings", "mapDayNight", "mapGreyLine", "mapSunTime",
                                    "mapSpotters", "mapSpotterStyle", "mapSpotLineStyle", "mapSpotLabelMode", "mapSpotLabelFreq", "mapSpotLabelAge",
                                    "mapSpotLabelSnr", "mapSpotFade", "mapParkOutlines", "mapReference", "mapSpotlight", "mapTerrain", "mapFlags"})
                setSetting(key, "");
            [mw.styleWindow orderOut:nil];
            mw.styleWindow = nil;
            applyStyle();
            fillPrograms();
            showStyleOptions();
        });
        // Two columns side by side (markers, areas and lines; spots, parks and the map), Reset under them.
        auto makeGrid = [](NSArray *gridRows) {
            NSGridView *grid = [NSGridView gridViewWithViews:gridRows];
            grid.rowSpacing = 6;
            grid.columnSpacing = 10;
            [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
            grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
            for (NSInteger r = 0; r < grid.numberOfRows; ++r) {  // section titles span both columns, with room above
                NSGridCell *first = [grid cellAtColumnIndex:0 rowIndex:r];
                if ([first.contentView isKindOfClass:NSTextField.class] && ((NSTextField *)first.contentView).font.pointSize >= NSFont.systemFontSize &&
                    [((NSTextField *)first.contentView).font.fontDescriptor symbolicTraits] & NSFontDescriptorTraitBold) {
                    [grid mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(r, 1)];
                    first.xPlacement = NSGridCellPlacementLeading;
                    if (r > 0) [grid rowAtIndex:r].topPadding = 8;
                }
                // Fading isn't one of the label's details: a little room above it.
                if ([[grid cellAtColumnIndex:1 rowIndex:r].contentView.identifier isEqualToString:@"map.style.spotFade"])
                    [grid rowAtIndex:r].topPadding = 6;
            }
            return grid;
        };
        NSGridView *left = makeGrid([rows subarrayWithRange:NSMakeRange(0, secondColumn)]);
        NSGridView *right = makeGrid([rows subarrayWithRange:NSMakeRange(secondColumn, rows.count - secondColumn)]);
        NSBox *between = [[NSBox alloc] initWithFrame:NSZeroRect];
        between.boxType = NSBoxSeparator;
        for (NSView *v in @[ left, between, right, reset ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [p.contentView addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [left.topAnchor constraintEqualToAnchor:p.contentView.topAnchor constant:16],
            [left.leadingAnchor constraintEqualToAnchor:p.contentView.leadingAnchor constant:16],
            [between.topAnchor constraintEqualToAnchor:left.topAnchor],
            [between.bottomAnchor constraintEqualToAnchor:reset.topAnchor constant:-12],
            [between.leadingAnchor constraintEqualToAnchor:left.trailingAnchor constant:18],
            [between.widthAnchor constraintEqualToConstant:1],
            [right.topAnchor constraintEqualToAnchor:left.topAnchor],
            [right.leadingAnchor constraintEqualToAnchor:between.trailingAnchor constant:18],
            [right.trailingAnchor constraintLessThanOrEqualToAnchor:p.contentView.trailingAnchor constant:-16],
            [reset.topAnchor constraintGreaterThanOrEqualToAnchor:left.bottomAnchor constant:14],
            [reset.topAnchor constraintGreaterThanOrEqualToAnchor:right.bottomAnchor constant:14],
            [reset.trailingAnchor constraintEqualToAnchor:p.contentView.trailingAnchor constant:-16],
            [reset.bottomAnchor constraintEqualToAnchor:p.contentView.bottomAnchor constant:-16],
        ]];
        mw.styleWindow = p;
        NSRect frame = mw.window.frame;
        [p setFrameTopLeftPoint:NSMakePoint(NSMaxX(frame) - 20, NSMaxY(frame) - 60)];
    }
    fillStyle();
    [mw.styleWindow makeKeyAndOrderFront:nil];
}

// Home: Settings → Your Station's grid, else the log's most used MY_GRIDSQUARE (`myGrids`: the
// whole log's, so that the filters, the distance from home among them, can't move it).
std::string homeGrid(const std::map<std::string, size_t> &myGrids) {
    std::string g = setting("stationGrid");
    double lat, lon;
    if (!g.empty() && adif::gridToLatLon(g, &lat, &lon)) return g;
    const std::map<std::string, size_t> &n = myGrids;
    size_t most = 0;
    for (const auto &kv : n)
        if (kv.second > most) most = kv.second, g = kv.first;
    return most ? g : "";
}

void refresh() {
    if (!mw.window) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        mw.buffer = buffer();
        mw.window.title = TF(@"Map — {name}", @{@"name" : ADIFString(documentName())});
        // The bands, modes and years in the log, for the filters.
        std::set<std::string> bands, modes, years;
        std::map<std::string, size_t> qsosPerBand, myGrids;
        for (const adif::Record &rec : adif::records(text, r.model)) {
            std::string my;
            for (char c : rec.get("MY_GRIDSQUARE"))
                if (!isspace((unsigned char)c)) my += (char)toupper((unsigned char)c);
            if (my.size() >= 4 && !adif::isPlaceholderGrid(my) && adif::gridToLatLon(my, nullptr, nullptr)) ++myGrids[my];
            if (std::string b = adif::effectiveBand(rec); !b.empty()) bands.insert(b), ++qsosPerBand[b];
            if (std::string m = rec.get("MODE"); !m.empty()) modes.insert(m);
            if (std::string d = rec.get("QSO_DATE"); d.size() == 8) years.insert(d.substr(0, 4));
        }
        auto fill = [](NSPopUpButton *p, NSArray<NSString *> *first, const std::vector<std::string> &items) {
            NSString *keep = p.indexOfSelectedItem > 0 ? p.titleOfSelectedItem : nil;
            [p removeAllItems];
            for (NSString *f in first) [p addItemWithTitle:T(f)];
            for (const std::string &i : items) [p addItemWithTitle:ADIFString(i)];
            if (keep && [p itemWithTitle:keep]) [p selectItemWithTitle:keep];
        };
        for (const adif::Spot &sp : spotfeeds::spots().spots())  // the spots' bands too: the filter applies to them
            if (!sp.band.empty() && !sp.heardMe) {
                std::string b = sp.band;
                for (char &c : b) c = (char)tolower((unsigned char)c);
                if (!std::any_of(bands.begin(), bands.end(), [&](const std::string &x) { return strcasecmp(x.c_str(), b.c_str()) == 0; })) bands.insert(b);
            }
        fill(mw.band, @[ N(@"All bands") ], std::vector<std::string>(bands.begin(), bands.end()));
        fill(mw.mode, @[ N(@"All modes") ], std::vector<std::string>(modes.begin(), modes.end()));
        bool customDates = mw.dates.indexOfSelectedItem == 4;  // its title is the range: kept by place, not title
        if (customDates) [mw.dates selectItemAtIndex:0];
        fill(mw.dates, @[ N(@"All dates"), N(@"Last 30 days"), N(@"Last 12 months"), N(@"This year"), N(@"Custom Range...") ],
             std::vector<std::string>(years.rbegin(), years.rend()));
        if (customDates) {
            [mw.dates selectItemAtIndex:4];
            auto shown = [](const std::string &d) { return d.size() == 8 ? d.substr(0, 4) + "-" + d.substr(4, 2) + "-" + d.substr(6, 2) : d; };
            [mw.dates itemAtIndex:4].title = ADIFString(trf("{from} to {to}", {{"from", shown(setting("mapDateFrom"))}, {"to", shown(setting("mapDateTo"))}}));
        }
        adif::MapFilter f;
        f.band = mw.band.indexOfSelectedItem > 0 ? ADIFStd(mw.band.titleOfSelectedItem) : "";
        mw.view.beaconBand = -1;  // the beacons picked out: the band filter's, when they send on it
        for (size_t b = 0; b < adif::kBeaconBands; ++b)
            if (strcasecmp(f.band.c_str(), adif::kBeaconBandNames[b]) == 0) mw.view.beaconBand = (int)b;
        f.mode = mw.mode.indexOfSelectedItem > 0 ? ADIFStd(mw.mode.titleOfSelectedItem) : "";
        f.confirmed = (int)std::clamp<NSInteger>(mw.confirmed.indexOfSelectedItem, 0, 6);
        std::string today = utcNow("%Y%m%d");
        auto daysAgo = [](int days) {
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"yyyyMMdd";
            df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            return ADIFStd([df stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0 * days]]);
        };
        switch (mw.dates.indexOfSelectedItem) {
            case 1: f.from = daysAgo(30); break;
            case 2: f.from = daysAgo(365); break;
            case 3: f.from = today.substr(0, 4) + "0101"; break;
            case 4: f.from = setting("mapDateFrom"), f.to = setting("mapDateTo"); break;
            default:
                if (mw.dates.indexOfSelectedItem > 4) {
                    std::string y = ADIFStd(mw.dates.titleOfSelectedItem);
                    f.from = y + "0101", f.to = y + "1231";
                }
                break;
        }
        adif::MapFilter places = savedPlaceFilter();
        f.continents = places.continents, f.dxcc = places.dxcc, f.cq = places.cq, f.itu = places.itu, f.states = places.states,
        f.counties = places.counties, f.regions = places.regions, f.potaLocations = places.potaLocations;
        f.withinKm = places.withinKm, f.homeLat = places.homeLat, f.homeLon = places.homeLon;
        f.records = places.records;
        if (f.records == 3) f.problemGroups = adif::problemGroups(r);
        adif::MapContext context;
        context.countries = &ADIFCountries();
        context.parks = &ADIFPotaParks();
        mw.data = adif::mapData(text, r.model, f, context);
        // Check Log's errors and warnings in the QSOs shown, for the list's Issues.
        mw.issues.clear();
        {
            std::map<int, size_t> qsoOf;
            for (size_t i = 0; i < mw.data.qsos.size(); ++i) qsoOf[mw.data.qsos[i].group] = i;
            for (const adif::Diagnostic &d : r.diagnostics) {
                if (d.severity != adif::Severity::Error && d.severity != adif::Severity::Warning) continue;
                auto at = qsoOf.find(adif::groupAt(r.model, d.start));
                if (at == qsoOf.end()) continue;
                ADIFIssue issue;
                issue.qso = at->second, issue.error = d.severity == adif::Severity::Error, issue.field = d.field, issue.message = d.message,
                issue.start = d.start;
                mw.issues.push_back(issue);
            }
        }
        [mw.view setParkFilter:places on:flag("mapFilterParks", false)];
        for (NSPopUpButton *p in @[ mw.band, mw.mode ]) [p invalidateIntrinsicContentSize];  // "Band: 20m" is wider than "20m"
        for (NSView *v = mw.band.superview; v; v = v.superview)
            if ([v isKindOfClass:ADIFFlowView.class]) v.needsLayout = YES;
        updateFilterButton();
        // DXCC from the calls, by country data.
        std::map<int, ADIFMapEntity> byDxcc;
        const adif::CountryTable &countries = ADIFCountries();
        for (size_t i = 0; i < mw.data.qsos.size(); ++i) {
            adif::CountryInfo info;
            if (countries.empty() || !countries.lookup(mw.data.qsos[i].call, &info) || !info.dxcc) continue;
            ADIFMapEntity &e = byDxcc[info.dxcc];
            e.dxcc = info.dxcc, e.lat = info.lat, e.lon = info.lon, e.name = info.name;
            e.qsos.push_back(i);
            e.confirmed |= mw.data.qsos[i].confirmed;
        }
        // Each entity's land, worked out once from the country file's names and places.
        static std::map<int, std::vector<adif::RingRef>> land;
        static size_t landFor = 0;
        if (landFor != countries.entities()) {
            std::vector<adif::EntityPlace> places;
            for (const adif::CountryInfo &c : countries.all()) places.push_back({c.dxcc, c.lat, c.lon, c.name});
            land = adif::dxccRings(places);
            landFor = countries.entities();
        }
        for (auto &kv : byDxcc)
            if (auto it = land.find(kv.first); it != land.end()) kv.second.land = it->second;
        mw.dxcc.clear();
        size_t confirmedDxcc = 0, confirmedSquares = 0;
        for (auto &kv : byDxcc) {
            confirmedDxcc += kv.second.confirmed;
            mw.dxcc.push_back(kv.second);
        }
        for (const adif::MapSquare &sq : mw.data.squares) confirmedSquares += sq.confirmed;
        mw.view.showContacts = mw.contacts.state == NSControlStateValueOn;
        mw.view.qsosPerBand = qsosPerBand;
        mw.home = homeGrid(myGrids);
        applyStyle();
        applyProjection();
        [mw.view setData:mw.data entities:mw.dxcc];
        fillPrograms();
        fillStyle();
        showList({});
        size_t located = 0;
        for (const adif::MapQso &q : mw.data.qsos) located += q.located;
        std::set<std::string> parkRefs, otherRefs;
        for (const adif::MapPark &p : mw.data.parks) (p.program == "POTA" ? parkRefs : otherRefs).insert(p.program + " " + p.reference);
        mw.summary = trf("{squares} ({confirmed} confirmed), {dxcc} DXCC ({dxccConfirmed} confirmed), {parks} where the QSO has a grid, "
                         "{others} (WWFF, IOTA, SOTA... under Other programs)",
                         {{"squares", plural(mw.data.squares.size(), "grid square")}, {"confirmed", std::to_string(confirmedSquares)},
                          {"dxcc", std::to_string(mw.dxcc.size())}, {"dxccConfirmed", std::to_string(confirmedDxcc)},
                          {"parks", plural(parkRefs.size(), "POTA park")}, {"others", plural(otherRefs.size(), "other reference")}}) +
                     (mw.home.empty() ? "" : "; " + trf("home {grid}", {{"grid", mw.home}})) + ". ";
        if (mw.data.withoutGrid)
            mw.summary += trp("{n} QSO without GRIDSQUARE isn't on the squares.", "{n} QSOs without GRIDSQUARE aren't on the squares.",
                              (long long)mw.data.withoutGrid) +
                          " ";
        mw.summary += mw.data.unusedLatLon ? trf("{qsos} with an exact place (Contacts; {n} LAT/LON not used: a placeholder, or far from the QSO's grid).",
                                                 {{"qsos", plural(located, "QSO")}, {"n", std::to_string(mw.data.unusedLatLon)}})
                                           : trf("{qsos} with an exact place (Contacts).", {{"qsos", plural(located, "QSO")}});
        mw.chosen.clear();
        mw.chosenHit = ADIFMapHit();
        showContact(ADIFMapHit(), idleStatus());  // nothing chosen in the new data: the title and slots go too
        showSituation();
        mw.useSpot.hidden = YES;
        mw.centerButton.enabled = NO;
        mw.centerButton.hidden = YES;
        mw.viewQso.hidden = YES;
        showWatchButton(ADIFMapHit());
        mw.actions.needsLayout = YES;
        std::string call = setting("stationCall");
        {  // the title line: what this is, then the station, the log and its QSOs
            NSMutableAttributedString *line = [[NSMutableAttributedString alloc]
                initWithString:T(@"Operating Map")
                    attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.systemFontSize + 1 weight:NSFontWeightBold]}];
            [line appendAttributedString:[[NSAttributedString alloc]
                                             initWithString:ADIFString("   " + (call.empty() ? "" : call + "  \u00B7  ") + documentName() + "  \u00B7  " +
                                                                       plural(mw.data.qsos.size(), "QSO"))
                                                 attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium],
                                                              NSForegroundColorAttributeName : NSColor.secondaryLabelColor}]];
            mw.summaryLabel.attributedStringValue = line;
            mw.summaryLabel.toolTip = line.string;
        }
        fillSynced();
        if (!live()) {
            // History: the QSOs the map shows, and the dates they span.
            std::string first, last;
            for (const adif::MapQso &q : mw.data.qsos)
                if (q.date.size() == 8) {
                    if (first.empty() || q.date < first) first = q.date;
                    if (last.empty() || q.date > last) last = q.date;
                }
            auto day = [](const std::string &d) { return d.substr(0, 4) + "-" + d.substr(4, 2) + "-" + d.substr(6, 2); };
            std::string scope = trp("{n} QSO on the map", "{n} QSOs on the map", (long long)mw.data.qsos.size());
            if (!first.empty()) scope += "  \u00B7  " + (first == last ? day(first) : day(first) + " \u2013 " + day(last));
            mw.scopeLabel.stringValue = ADIFString(scope);
            mw.liveLabel.attributedTitle = dotted(tr("History") + "  \u00B7  " + documentName(), NSColor.secondaryLabelColor, mw.liveLabel.font);
            mw.liveLabel.toolTip = nil;
        }
        fillQuickViews();
        applyParkPlaces();  // home may have changed
        refreshSpots();  // the band, mode and place filters apply to spots too
    } catch (...) {
    }
}

// A QSO's record in the log (an index into data.qsos).
void goToQso(size_t qi) {
    if (qi >= mw.data.qsos.size()) return;
    const adif::MapQso &q = mw.data.qsos[qi];
    if (buffer() != mw.buffer) {
        setStatus("Switch back to the map's log to go to the record.");
        return;
    }
    NppHandle h = scintilla();
    const adif::LintResult &r = lint(h);
    if (q.group >= 0 && (size_t)q.group < r.model.groups.size()) goTo(h, adif::groupStart(r.model, r.model.groups[(size_t)q.group]), true);
}

// A problem in the list's Issues: the caret on it in the log.
void goToIssue(size_t i) {
    if (i >= mw.issues.size()) return;
    if (buffer() != mw.buffer) {
        setStatus("Switch back to the map's log to go to the record.");
        return;
    }
    NppHandle h = scintilla();
    if (mw.issues[i].start < adifhost::text(h).size()) goTo(h, mw.issues[i].start, true);
}

NSBitmapImageRep *mapImage();

void exportPng() {
    std::string base = documentName();
    if (size_t dot = base.rfind('.'); dot != std::string::npos) base.resize(dot);
    std::string path;
    if (const char *dir = getenv("ADIFLINT_TEST_SAVE_DIR")) {
        path = std::string(dir) + "/" + base + " map.png";
    } else {
        NSSavePanel *p = [NSSavePanel savePanel];
        p.nameFieldStringValue = ADIFString(base + " map.png");
        if (UTType *t = [UTType typeWithFilenameExtension:@"png"]) p.allowedContentTypes = @[ t ];
        if ([p runModal] != NSModalResponseOK || !p.URL) return;
        path = ADIFStd(p.URL.path);
    }
    NSData *png = [mapImage() representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:ADIFString(path) atomically:YES]) {
        setStatus("Could not save the map.");
        return;
    }
    setStatus("Saved " + ADIFStd(ADIFString(path).lastPathComponent) + ".");
}

// Copy Map: the picture Export PNG saves, on the clipboard (a test's own pasteboard in the tests).
void copyMap() {
    NSBitmapImageRep *rep = mapImage();
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    const char *name = getenv("ADIFLINT_TEST_PASTEBOARD");
    NSPasteboard *pb = name ? [NSPasteboard pasteboardWithName:@(name)] : NSPasteboard.generalPasteboard;
    [pb clearContents];
    if (!png || ![pb setData:png forType:NSPasteboardTypePNG]) return setStatus(tr("Could not copy the map."));
    [pb setData:rep.TIFFRepresentation forType:NSPasteboardTypeTIFF];  // for the apps that read only TIFF
    setStatus(tr("Copied the map, as Export PNG would save it."));
}

// Focus Map: the map alone (the sidebar, the list and the selected panel hidden); again, the
// panes it hid come back.
void focusMap() {
    bool any = false;
    for (int i = 0; i < 3; ++i) any = any || mw.paneToggle[i].state == NSControlStateValueOn;
    if (any) {
        for (int i = 0; i < 3; ++i) {
            mw.focusRestore[i] = mw.paneToggle[i].state == NSControlStateValueOn;
            if (mw.focusRestore[i]) showPane(i, false);
        }
    } else {
        bool some = mw.focusRestore[0] || mw.focusRestore[1] || mw.focusRestore[2];
        for (int i = 0; i < 3; ++i)
            if (mw.focusRestore[i] || !some) showPane(i, true);
    }
}

// What the map shows now, legend included, at twice the screen's size.
NSBitmapImageRep *mapImage() {
    NSRect r = mw.view.bounds;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                    pixelsWide:(NSInteger)(r.size.width * 2)
                                                                    pixelsHigh:(NSInteger)(r.size.height * 2)
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    rep.size = r.size;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [mw.view drawRect:r];
    [NSGraphicsContext restoreGraphicsState];
    return rep;
}

// ── More Filters: places ──

const char *const kContinents[7] = {"AF", "AN", "AS", "EU", "NA", "OC", "SA"};

std::vector<std::string> splitSetting(const char *key, char sep) {
    std::string v = setting(key);
    std::vector<std::string> out;
    for (size_t b = 0; b <= v.size();) {
        size_t e = v.find(sep, b);
        if (e == std::string::npos) e = v.size();
        std::string item = v.substr(b, e - b);
        while (!item.empty() && item.front() == ' ') item.erase(item.begin());
        while (!item.empty() && item.back() == ' ') item.pop_back();
        if (!item.empty()) out.push_back(item);
        b = e + 1;
    }
    return out;
}

void saveSetting(const char *key, const std::vector<std::string> &items, char sep) {
    std::string v;
    for (const std::string &i : items) v += (v.empty() ? "" : std::string(1, sep)) + i;
    setSetting(key, v);
}

// The places the Filters keep, as saved: continents, DXCC (names or numbers), zones, states,
// counties, regions and POTA locations.
adif::MapFilter savedPlaceFilter() {
    adif::MapFilter f;
    for (const std::string &c : splitSetting("mapFilterContinents", ',')) f.continents.insert(c);
    for (const std::string &d : splitSetting("mapFilterDxcc", ';')) {
        if (std::all_of(d.begin(), d.end(), [](char c) { return c >= '0' && c <= '9'; })) {
            f.dxcc.insert(std::atoi(d.c_str()));
            continue;
        }
        for (const adif::CountryInfo &c : ADIFCountries().all())
            if (strcasecmp(c.name.c_str(), d.c_str()) == 0) f.dxcc.insert(c.dxcc);
        if (f.dxcc.empty()) f.dxcc.insert(-1);  // a name the country data doesn't know matches nothing
    }
    for (const std::string &z : splitSetting("mapFilterCq", ',')) f.cq.insert(std::atoi(z.c_str()));
    for (const std::string &z : splitSetting("mapFilterItu", ',')) f.itu.insert(std::atoi(z.c_str()));
    for (const std::string &st : splitSetting("mapFilterStates", ',')) f.states.insert(st);
    for (const std::string &c : splitSetting("mapFilterCounties", ';')) {
        const adif::AreaIndex &counties = adif::areaIndex(adif::Overlay::UsCounties);
        size_t i = counties.byCounty(c);
        f.counties.insert(i == adif::AreaIndex::npos ? c : counties.area(i).name);
    }
    for (const std::string &r : splitSetting("mapFilterRegions", ',')) f.regions.insert(r);
    for (const std::string &l : splitSetting("mapFilterPota", ',')) f.potaLocations.insert(l);
    double km = std::atof(setting("mapFilterWithinKm").c_str()), lat, lon;  // only with a home to measure from
    if (km > 0 && !mw.home.empty() && adif::gridToLatLon(mw.home, &lat, &lon)) f.withinKm = km, f.homeLat = lat, f.homeLon = lon;
    f.records = number("mapFilterRecords", 0, 3);
    return f;
}

size_t placeKinds(const adif::MapFilter &f) {
    return !f.continents.empty() + !f.dxcc.empty() + !f.cq.empty() + !f.itu.empty() + !f.states.empty() + !f.counties.empty() + !f.regions.empty() +
           !f.potaLocations.empty() + (f.withinKm > 0) + (f.records > 0);
}

// More Filters' kinds of record.
const char *const kRecordKinds[4] = {N_("All records"), N_("Without a grid square"), N_("Possible duplicates"), N_("With problems (Check Log)")};

// "Within 1,500 km" (or miles, as the list measures).
std::string withinText(double km) {
    bool miles = setting("mapListUnits") == "mi";
    return ADIFStd(TF(miles ? @"Within {n} mi" : @"Within {n} km", @{@"n" : @(std::lround(miles ? km / 1.609344 : km))}));
}

const char *const kContinentNames[7] = {N_("Africa"), N_("Antarctica"), N_("Asia"), N_("Europe"), N_("North America"), N_("Oceania"), N_("South America")};

// The toolbar's continent: All, one of them, or "2 continents" when More Filters chose more.
void fillContinentPopup() {
    NSPopUpButton *p = mw.continentPopup;
    if (!p) return;
    std::vector<std::string> chosen = splitSetting("mapFilterContinents", ',');
    [p removeAllItems];
    [p addItemWithTitle:T(@"All continents")];
    for (int i = 0; i < 7; ++i) {
        [p addItemWithTitle:ADIFString(tr(kContinentNames[i]))];
        p.lastItem.representedObject = @(kContinents[i]);
    }
    if (chosen.size() > 1) {
        [p addItemWithTitle:TF(@"{n} continents", @{@"n" : @(chosen.size())})];
        [p selectItem:p.lastItem];
    } else if (chosen.size() == 1) {
        NSInteger at = [p indexOfItemWithRepresentedObject:ADIFString(chosen[0])];
        [p selectItemAtIndex:at > 0 ? at : 0];
    } else {
        [p selectItemAtIndex:0];
    }
}

void refresh();
void refreshSpots();
void fillPlaceControls();
void chooseQuickView(NSInteger row);
std::string entityName(int dxcc, const std::string &call);

// The filters on that the toolbar doesn't show (More Filters' places; in Live, the dates and
// confirmation, which the spots don't follow, and the Quick View), each a tag: click it to remove it.
void fillFilterChips() {
    if (!mw.chips) return;
    for (NSView *v in [mw.chips.arrangedSubviews copy]) {
        [mw.chips removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    auto chip = [&](const std::string &title, void (^clear)(void)) {
        NSButton *b = [NSButton buttonWithTitle:ADIFString(title + "  \u2715") target:nil action:nil];
        b.bezelStyle = NSBezelStyleInline;
        b.controlSize = NSControlSizeSmall;
        b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        b.toolTip = T(@"Remove this filter");
        b.accessibilityLabel = TF(@"Remove the filter {name}", @{@"name" : ADIFString(title)});
        b.identifier = @"map.chip";
        ADIFOnAction(b, clear);
        [mw.chips addArrangedSubview:b];
    };
    auto list = [](const std::vector<std::string> &items) {
        std::string out;
        for (size_t i = 0; i < items.size() && i < 2; ++i) out += (out.empty() ? "" : ", ") + items[i];
        if (items.size() > 2) out += ", +" + std::to_string(items.size() - 2);
        return out;
    };
    struct Place {
        const char *setting;
        char sep;
        const char *label;  // "" for none
    };
    static const Place kPlaces[] = {{"mapFilterDxcc", ';', N_("DXCC")},  {"mapFilterCq", ',', N_("CQ")},       {"mapFilterItu", ',', N_("ITU")},
                                    {"mapFilterStates", ',', ""},       {"mapFilterCounties", ';', ""},       {"mapFilterRegions", ',', ""},
                                    {"mapFilterPota", ',', N_("POTA")}};
    for (const Place &pl : kPlaces) {
        std::vector<std::string> items = splitSetting(pl.setting, pl.sep);
        if (items.empty()) continue;
        if (std::string(pl.setting) == "mapFilterDxcc")
            for (std::string &d : items)
                if (std::all_of(d.begin(), d.end(), [](char c) { return c >= '0' && c <= '9'; })) d = entityName(std::atoi(d.c_str()), "");
        std::string which = pl.setting;
        chip((*pl.label ? tr(pl.label) + " " : "") + list(items), ^{
            setSetting(which.c_str(), "");
            if (mw.filterPopover) fillPlaceControls();
            refresh();
        });
    }
    if (double km = std::atof(setting("mapFilterWithinKm").c_str()); km > 0 && !mw.home.empty())
        chip(withinText(km), ^{
            setSetting("mapFilterWithinKm", "");
            if (mw.filterPopover) fillPlaceControls();
            refresh();
        });
    if (int kind = number("mapFilterRecords", 0, 3); kind > 0)
        chip(tr(kRecordKinds[kind]), ^{
            setSetting("mapFilterRecords", "0");
            if (mw.filterPopover) fillPlaceControls();
            refresh();
        });
    if (live()) {
        for (NSPopUpButton *p : {mw.dates, mw.confirmed})
            if (p.indexOfSelectedItem > 0) {
                NSPopUpButton *popup = p;
                chip(ADIFStd(p.titleOfSelectedItem), ^{
                    [popup selectItemAtIndex:0];
                    refresh();
                });
            }
        if (mw.spotLens > 0 && mw.quickRows && (size_t)mw.spotLens < mw.quickRows.rows.size())
            chip(mw.quickRows.rows[(size_t)mw.spotLens].title, ^{ chooseQuickView(0); });
    }
    mw.chips.hidden = mw.chips.arrangedSubviews.count == 0;
}

void updateFilterButton() {
    size_t n = placeKinds(savedPlaceFilter());
    mw.moreFilters.title = n ? [NSString stringWithFormat:T(@"More Filters (%zu)..."), n] : T(@"More Filters...");
    // Clear says how many filters are on, and its tooltip which, in a line ("20m · FT8 · New band").
    std::vector<std::string> active;
    for (NSPopUpButton *p : {mw.band, mw.mode})
        if (p.indexOfSelectedItem > 0) active.push_back(ADIFStd(p.titleOfSelectedItem));
    if (!live()) {
        for (NSPopUpButton *p : {mw.dates, mw.confirmed})
            if (p.indexOfSelectedItem > 0) active.push_back(ADIFStd(p.titleOfSelectedItem));
    } else {
        if (mw.spotLens > 0 && mw.quickRows && (size_t)mw.spotLens < mw.quickRows.rows.size()) active.push_back(mw.quickRows.rows[(size_t)mw.spotLens].title);
        std::string program = setting("mapSpotsProgram");
        if (!program.empty()) active.push_back(program == "-" ? tr("Plain DX only") : program);
        if (!setting("mapSpotsHidden").empty() && mw.spotSourceBar.indexOfSelectedItem > 0) active.push_back(ADIFStd(mw.spotSourceBar.titleOfSelectedItem));
    }
    if (n) active.push_back(trp("{n} more filter", "{n} more filters", (long long)n));
    std::string list;
    for (const std::string &a : active) list += (list.empty() ? "" : "  \u00B7  ") + a;
    mw.clearFilters.enabled = !active.empty();
    mw.clearFilters.title = active.empty() ? T(@"Clear") : TF(@"Clear ({n})", @{@"n" : @(active.size())});
    mw.clearFilters.toolTip = active.empty() ? T(@"Show every QSO again: all bands, modes, dates and places (and in Live, every spot)")
                                             : ADIFString(trf("Clear: {filters}", {{"filters", list}}));
    fillContinentPopup();
    fillFilterChips();
}

std::vector<std::string> tokens(NSTokenField *t) {
    std::vector<std::string> out;
    for (id o in [t.objectValue isKindOfClass:NSArray.class] ? (NSArray *)t.objectValue : @[])
        if ([o isKindOfClass:NSString.class] && [(NSString *)o length]) out.push_back(ADIFStd(o));
    return out;
}

void refresh();

// The popover's controls changed: save them, filter again.
void placeFiltersChanged() {
    std::vector<std::string> conts;
    for (int i = 0; i < 7; ++i)
        if (mw.continent[i].state == NSControlStateValueOn) conts.push_back(kContinents[i]);
    saveSetting("mapFilterContinents", conts, ',');
    saveSetting("mapFilterDxcc", tokens(mw.dxccTokens), ';');
    auto numbers = [](NSTextField *f, int max) {
        std::vector<std::string> out;
        for (NSString *part in [f.stringValue componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@", "]]) {
            int n = part.intValue;
            if (n >= 1 && n <= max) out.push_back(std::to_string(n));
        }
        return out;
    };
    saveSetting("mapFilterCq", numbers(mw.cqField, 40), ',');
    saveSetting("mapFilterItu", numbers(mw.ituField, 90), ',');
    std::vector<std::string> states;
    for (std::string st : tokens(mw.stateTokens)) {
        for (char &c : st) c = (char)toupper((unsigned char)c);
        states.push_back(st);
    }
    saveSetting("mapFilterStates", states, ',');
    saveSetting("mapFilterCounties", tokens(mw.countyTokens), ';');
    std::vector<std::string> pota;
    for (std::string l : tokens(mw.potaTokens)) {
        for (char &c : l) c = (char)toupper((unsigned char)c);
        pota.push_back(l);
    }
    saveSetting("mapFilterPota", pota, ',');
    saveFlag("mapFilterParks", mw.parksToo.state == NSControlStateValueOn);
    double within = mw.withinField.doubleValue;
    if (setting("mapListUnits") == "mi") within *= 1.609344;
    setSetting("mapFilterWithinKm", within > 0 ? std::to_string(std::lround(within)) : "");
    setSetting("mapFilterRecords", std::to_string(std::max<NSInteger>(0, mw.recordsPopup.indexOfSelectedItem)));
    refresh();
}

void fillPlaceControls() {
    adif::MapFilter f = savedPlaceFilter();
    for (int i = 0; i < 7; ++i) mw.continent[i].state = f.continents.count(kContinents[i]) ? NSControlStateValueOn : NSControlStateValueOff;
    auto set = [](NSTokenField *t, const std::vector<std::string> &items) {
        NSMutableArray *a = [NSMutableArray array];
        for (const std::string &i : items) [a addObject:ADIFString(i)];
        t.objectValue = a;
    };
    set(mw.dxccTokens, splitSetting("mapFilterDxcc", ';'));
    set(mw.stateTokens, splitSetting("mapFilterStates", ','));
    set(mw.countyTokens, splitSetting("mapFilterCounties", ';'));
    set(mw.potaTokens, splitSetting("mapFilterPota", ','));
    auto join = [](const std::vector<std::string> &v) {
        std::string out;
        for (const std::string &s : v) out += (out.empty() ? "" : ", ") + s;
        return ADIFString(out);
    };
    mw.cqField.stringValue = join(splitSetting("mapFilterCq", ','));
    mw.ituField.stringValue = join(splitSetting("mapFilterItu", ','));
    mw.parksToo.state = flag("mapFilterParks", false) ? NSControlStateValueOn : NSControlStateValueOff;
    bool miles = setting("mapListUnits") == "mi";
    double km = std::atof(setting("mapFilterWithinKm").c_str());
    mw.withinField.stringValue = km > 0 ? [NSString stringWithFormat:@"%ld", std::lround(miles ? km / 1.609344 : km)] : @"";
    mw.withinField.enabled = !mw.home.empty();
    mw.withinField.placeholderString = mw.home.empty() ? T(@"your grid first (Settings)") : T(@"anywhere");
    mw.withinUnits.stringValue = miles ? T(@"mi of your station") : T(@"km of your station");
    [mw.recordsPopup selectItemAtIndex:number("mapFilterRecords", 0, 3)];
    // Regions: a menu of checkable items, by kind.
    NSMenu *menu = mw.regions.menu;
    [menu removeAllItems];
    std::set<std::string> chosen = f.regions;
    [menu addItemWithTitle:chosen.empty() ? T(@"Any region") : TP(@"{n} region", @"{n} regions", (long long)chosen.size())
                    action:nil
             keyEquivalent:@""];
    std::string kind;
    for (const adif::UsRegion &r : adif::usRegions()) {
        if (r.kind != kind) {
            kind = r.kind;
            [menu addItem:[NSMenuItem separatorItem]];
            NSMenuItem *head = [menu addItemWithTitle:ADIFString(tr(kind)) action:nil keyEquivalent:@""];
            head.enabled = NO;
        }
        NSMenuItem *item = [menu addItemWithTitle:ADIFString(tr(r.name)) action:nil keyEquivalent:@""];
        item.state = chosen.count(r.id) ? NSControlStateValueOn : NSControlStateValueOff;
        item.indentationLevel = 1;
        std::string id = r.id;
        ADIFBlockMenuItem(item, ^{
            std::vector<std::string> ids = splitSetting("mapFilterRegions", ',');
            auto it = std::find(ids.begin(), ids.end(), id);
            if (it == ids.end()) ids.push_back(id);
            else ids.erase(it);
            saveSetting("mapFilterRegions", ids, ',');
            fillPlaceControls();
            refresh();
        });
    }
}

// More Filters: a popover of places to keep. Changes apply as they're made.
void showMoreFilters() {
    if (!mw.filterPopover) {
        mw.completers = [NSMutableArray array];
        auto tokenField = [](NSString *ident, NSString *placeholder, NSArray<NSString *> *candidates, NSString *separators) {
            NSTokenField *t = [[NSTokenField alloc] initWithFrame:NSMakeRect(0, 0, 380, 24)];
            t.identifier = ident;
            t.placeholderString = T(placeholder);
            t.tokenizingCharacterSet = [NSCharacterSet characterSetWithCharactersInString:separators];
            ADIFTokenCompleter *c = [[ADIFTokenCompleter alloc] init];
            c.candidates = candidates;
            t.delegate = c;
            [mw.completers addObject:c];
            [t.widthAnchor constraintEqualToConstant:380].active = YES;
            ADIFOnAction(t, ^{ placeFiltersChanged(); });
            return t;
        };
        NSMutableArray *dxccNames = [NSMutableArray array];
        std::set<std::string> seen;
        for (const adif::CountryInfo &c : ADIFCountries().all())
            if (seen.insert(c.name).second) [dxccNames addObject:ADIFString(c.name)];
        NSMutableArray *states = [NSMutableArray array], *counties = [NSMutableArray array], *locations = [NSMutableArray array];
        const adif::AreaIndex &st = adif::areaIndex(adif::Overlay::UsStates), &co = adif::areaIndex(adif::Overlay::UsCounties);
        for (size_t i = 0; i < st.size(); ++i) [states addObject:ADIFString(st.area(i).name)];
        for (size_t i = 0; i < co.size(); ++i) [counties addObject:ADIFString(co.area(i).name)];
        std::set<std::string> locs;
        for (const adif::PotaPark &p : ADIFPotaParks().parks())
            for (size_t b = 0; b <= p.location.size();) {
                size_t e = p.location.find(',', b);
                if (e == std::string::npos) e = p.location.size();
                if (e > b) locs.insert(p.location.substr(b, e - b));
                b = e + 1;
            }
        for (const std::string &l : locs) [locations addObject:ADIFString(l)];
        mw.dxccTokens = tokenField(@"map.filter.dxcc", N(@"Countries (DXCC), e.g. Italy, Canada"), dxccNames, @";");
        mw.stateTokens = tokenField(@"map.filter.states", N(@"US states, e.g. WI, IL"), states, @", ");
        mw.countyTokens = tokenField(@"map.filter.counties", N(@"US counties, e.g. WI,Dane; WI,Milwaukee"), counties, @";");
        mw.potaTokens = tokenField(@"map.filter.pota", N(@"POTA locations, e.g. US-WI, CA-ON"), locations, @", ");
        NSMutableArray *conts = [NSMutableArray array];
        for (int i = 0; i < 7; ++i) {
            mw.continent[i] = ADIFCheckbox(@(kContinents[i]), false);
            mw.continent[i].identifier = [NSString stringWithFormat:@"map.filter.continent.%s", kContinents[i]];
            ADIFOnAction(mw.continent[i], ^{ placeFiltersChanged(); });
            [conts addObject:mw.continent[i]];
        }
        NSStackView *contRow = [NSStackView stackViewWithViews:conts];
        contRow.spacing = 8;
        auto zoneField = [](NSString *ident, NSString *placeholder) {
            NSTextField *f = ADIFTextField(placeholder, 140);
            f.identifier = ident;
            ADIFOnAction(f, ^{ placeFiltersChanged(); });
            return f;
        };
        mw.cqField = zoneField(@"map.filter.cq", N(@"e.g. 3, 4, 5"));
        mw.ituField = zoneField(@"map.filter.itu", N(@"e.g. 6, 7, 8"));
        NSStackView *zones = [NSStackView stackViewWithViews:@[ mw.cqField, ADIFLabel(@"ITU zones:"), mw.ituField ]];
        zones.spacing = 8;
        mw.regions = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
        mw.regions.identifier = @"map.filter.regions";
        mw.regions.toolTip = T(@"US call areas, Census regions and divisions, ARRL divisions (California, New York and New Jersey count for an ARRL "
                             @"division by the QSO's ARRL_SECT)");
        mw.withinField = ADIFTextField(@"anywhere", 80);
        mw.withinField.identifier = @"map.filter.within";
        mw.withinField.toolTip = T(@"Keep the QSOs (and spots) this close to your station: where each was, else its grid square, else its "
                                   @"country; measured from Settings' grid");
        ADIFOnAction(mw.withinField, ^{ placeFiltersChanged(); });
        mw.withinUnits = ADIFLabel(@"km of your station");
        NSStackView *within = [NSStackView stackViewWithViews:@[ mw.withinField, mw.withinUnits ]];
        within.spacing = 6;
        mw.recordsPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for (const char *k : kRecordKinds) [mw.recordsPopup addItemWithTitle:ADIFString(tr(k))];
        mw.recordsPopup.identifier = @"map.filter.records";
        mw.recordsPopup.toolTip = T(@"Which records: those without a grid square (to look up), a contact logged more than once (two minutes "
                                    @"apart, same band and mode), or those Check Log finds an error or warning in");
        ADIFOnAction(mw.recordsPopup, ^{ placeFiltersChanged(); });
        mw.parksToo = ADIFCheckbox(@"Also limit the POTA parks you haven't worked", false);
        mw.parksToo.identifier = @"map.filter.parks";
        mw.parksToo.toolTip = T(@"The POTA layer's Overlay shows only the parks in these places (their location, state, region, country and continent)");
        ADIFOnAction(mw.parksToo, ^{ placeFiltersChanged(); });
        NSButton *clear = [NSButton buttonWithTitle:T(@"Clear These Filters") target:nil action:nil];
        ADIFOnAction(clear, ^{
            for (const char *key : {"mapFilterContinents", "mapFilterDxcc", "mapFilterCq", "mapFilterItu", "mapFilterStates", "mapFilterCounties",
                                    "mapFilterRegions", "mapFilterPota", "mapFilterWithinKm", "mapFilterRecords"})
                setSetting(key, "");
            fillPlaceControls();
            refresh();
        });
        // In groups, each under its heading: where, how far, the programs, which records.
        auto group = [](NSString *title) {
            NSTextField *t = ADIFLabel(title);
            t.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold];
            t.textColor = NSColor.secondaryLabelColor;
            return t;
        };
        NSArray *rowsOfGrid = @[
            @[ group(N(@"Where")), [NSGridCell emptyContentView] ], @[ ADIFLabel(@"Continents:"), contRow ], @[ ADIFLabel(@"DXCC:"), mw.dxccTokens ],
            @[ ADIFLabel(@"CQ zones:"), zones ], @[ ADIFLabel(@"US states:"), mw.stateTokens ], @[ ADIFLabel(@"US counties:"), mw.countyTokens ],
            @[ ADIFLabel(@"US regions:"), mw.regions ], @[ group(N(@"How far")), [NSGridCell emptyContentView] ], @[ ADIFLabel(@"Within:"), within ],
            @[ group(N(@"Programs")), [NSGridCell emptyContentView] ], @[ ADIFLabel(@"POTA locations:"), mw.potaTokens ],
            @[ [NSGridCell emptyContentView], mw.parksToo ], @[ group(N(@"Which records")), [NSGridCell emptyContentView] ],
            @[ ADIFLabel(@"Records:"), mw.recordsPopup ], @[ [NSGridCell emptyContentView], clear ]
        ];
        NSGridView *grid = [NSGridView gridViewWithViews:rowsOfGrid];
        grid.rowSpacing = 8;
        grid.columnSpacing = 10;
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
        for (NSInteger r : {0, 7, 9, 12}) {  // the headings, across both columns, at the left
            [grid mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(r, 1)];
            [grid cellAtColumnIndex:0 rowIndex:r].xPlacement = NSGridCellPlacementLeading;
            [grid rowAtIndex:r].topPadding = r ? 6 : 0;
        }
        grid.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *help = [NSTextField wrappingLabelWithString:T(@"Keep only the QSOs in these places, this close to your station, and of "
                                                                 @"this kind: within a line any of its values, and every line that has "
                                                                 @"values. Changes apply as you make them. Band, mode, dates and "
                                                                 @"confirmation are in the toolbar (in Live, the spots' age and source too).")];
        help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        help.textColor = NSColor.secondaryLabelColor;
        help.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
        content.identifier = @"map.filters";
        [content addSubview:help];
        [content addSubview:grid];
        [NSLayoutConstraint activateConstraints:@[
            [help.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
            [help.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [help.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            // The grid sets the width (its labels are longer in some languages); the help wraps to it.
            [help.widthAnchor constraintEqualToAnchor:grid.widthAnchor],
            [grid.widthAnchor constraintGreaterThanOrEqualToConstant:500],
            [grid.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:10],
            [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [grid.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [grid.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        ]];
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = content;
        mw.filterPopover = [[NSPopover alloc] init];
        mw.filterPopover.contentViewController = vc;
        ADIFNightTrackPopover(mw.filterPopover);
        mw.filterPopover.behavior = NSPopoverBehaviorTransient;
    }
    fillPlaceControls();
    [mw.filterPopover showRelativeToRect:mw.moreFilters.bounds ofView:mw.moreFilters preferredEdge:NSRectEdgeMaxY];
}

// The dates menu's Custom Range: QSO_DATE from one day to another (UTC, both included), each
// change applied at once; remembered (mapDateFrom, mapDateTo).
NSDateFormatter *dayStamp() {
    static NSDateFormatter *df = [] {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"yyyyMMdd";
        f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        return f;
    }();
    return df;
}

void dateRangeChanged() {
    if ([mw.dateTo.dateValue compare:mw.dateFrom.dateValue] == NSOrderedAscending) mw.dateTo.dateValue = mw.dateFrom.dateValue;
    setSetting("mapDateFrom", ADIFStd([dayStamp() stringFromDate:mw.dateFrom.dateValue]));
    setSetting("mapDateTo", ADIFStd([dayStamp() stringFromDate:mw.dateTo.dateValue]));
    if (mw.dates.indexOfSelectedItem != 4) [mw.dates selectItemAtIndex:4];
    refresh();
}

void showDateRange() {
    if (!mw.datesPopover) {
        auto picker = [](NSString *ident) {
            NSDatePicker *p = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
            p.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
            p.datePickerElements = NSDatePickerElementFlagYearMonthDay;
            p.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            p.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
            p.identifier = ident;
            ADIFOnAction(p, ^{ dateRangeChanged(); });
            return p;
        };
        mw.dateFrom = picker(@"map.dates.from");
        mw.dateTo = picker(@"map.dates.to");
        NSStackView *row = [NSStackView stackViewWithViews:@[ ADIFLabel(@"From:"), mw.dateFrom, ADIFLabel(@"To:"), mw.dateTo ]];
        row.spacing = 8;
        NSTextField *help = [NSTextField wrappingLabelWithString:T(@"The QSOs from the first day to the last, both included (UTC, as QSO_DATE has them).")];
        help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        help.textColor = NSColor.secondaryLabelColor;
        NSStackView *stack = [NSStackView stackViewWithViews:@[ help, row ]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 10;
        stack.edgeInsets = NSEdgeInsetsMake(14, 14, 14, 14);
        stack.identifier = @"map.dates";
        [help.widthAnchor constraintEqualToAnchor:row.widthAnchor].active = YES;
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = stack;
        mw.datesPopover = [[NSPopover alloc] init];
        mw.datesPopover.contentViewController = vc;
        ADIFNightTrackPopover(mw.datesPopover);
        mw.datesPopover.behavior = NSPopoverBehaviorTransient;
    }
    // As last chosen; the first time, this year so far.
    NSDate *from = [dayStamp() dateFromString:ADIFString(setting("mapDateFrom"))], *to = [dayStamp() dateFromString:ADIFString(setting("mapDateTo"))];
    mw.dateFrom.dateValue = from ?: [dayStamp() dateFromString:ADIFString(utcNow("%Y") + "0101")];
    mw.dateTo.dateValue = to ?: [dayStamp() dateFromString:ADIFString(utcNow("%Y%m%d"))];
    if (!from || !to) {
        setSetting("mapDateFrom", ADIFStd([dayStamp() stringFromDate:mw.dateFrom.dateValue]));
        setSetting("mapDateTo", ADIFStd([dayStamp() stringFromDate:mw.dateTo.dateValue]));
    }
    [mw.datesPopover showRelativeToRect:mw.dates.bounds ofView:mw.dates preferredEdge:NSRectEdgeMaxY];
}

// ── Spots ──

const long long kSpotAges[] = {600, 1800, 3600};
const char *const kSpotAgeTitles[] = {N_("10 minutes"), N_("30 minutes"), N_("1 hour")};
const adif::SpotSource kSpotSources[] = {adif::SpotSource::Spothole, adif::SpotSource::Cluster, adif::SpotSource::PskReporter};

// The Spots filter: the Map's band, mode and places, and the popover's age, sources and program.
adif::SpotFilter spotFilter() {
    adif::SpotFilter f;
    adif::MapFilter places = savedPlaceFilter();
    f.map.continents = places.continents, f.map.dxcc = places.dxcc, f.map.cq = places.cq, f.map.itu = places.itu, f.map.states = places.states,
    f.map.counties = places.counties, f.map.regions = places.regions, f.map.potaLocations = places.potaLocations;
    f.map.withinKm = places.withinKm, f.map.homeLat = places.homeLat, f.map.homeLon = places.homeLon;
    f.map.band = mw.band.indexOfSelectedItem > 0 ? ADIFStd(mw.band.titleOfSelectedItem) : "";
    f.map.mode = mw.mode.indexOfSelectedItem > 0 ? ADIFStd(mw.mode.titleOfSelectedItem) : "";
    f.maxAge = kSpotAges[number("mapSpotsAge", 1, 2)];
    std::string hidden = setting("mapSpotsHidden");  // the sources unticked: "Cluster,PSKReporter"
    for (adif::SpotSource src : kSpotSources)
        if (hidden.find(adif::spotSourceName(src)) == std::string::npos) f.sources.insert(src);
    std::string program = setting("mapSpotsProgram");
    if (program == "-") f.programs = {""};
    else if (!program.empty()) f.programs = {program};
    if (flag("mapSpotsOnly", false)) {  // one station's spots: who heard it
        std::string call = setting("mapSpotsOnlyCall");
        f.onlyCall = call.empty() ? setting("stationCall") : call;
    }
    return f;
}

void fillSpotsPopover() {
    if (!mw.spotsPopover) return;
    spotfeeds::Config c = spotfeeds::config();
    bool on[] = {c.spothole, c.cluster, c.psk};
    std::string hidden = setting("mapSpotsHidden");
    for (size_t i = 0; i < 3; ++i) {
        mw.spotSource[i].enabled = on[i];
        mw.spotSource[i].state = on[i] && hidden.find(adif::spotSourceName(kSpotSources[i])) == std::string::npos ? NSControlStateValueOn
                                                                                                                   : NSControlStateValueOff;
    }
    [mw.spotAge selectItemAtIndex:number("mapSpotsAge", 1, 2)];
    // The programs in the spots now, after All and plain DX.
    std::set<std::string> programs;
    for (const adif::Spot &sp : spotfeeds::spots().spots())
        if (!sp.program.empty()) programs.insert(sp.program);
    std::string chosen = setting("mapSpotsProgram");
    if (!chosen.empty() && chosen != "-") programs.insert(chosen);
    [mw.spotProgram removeAllItems];
    [mw.spotProgram addItemWithTitle:T(@"All programs")];
    [mw.spotProgram addItemWithTitle:T(@"Plain DX spots")];
    for (const std::string &p : programs) [mw.spotProgram addItemWithTitle:ADIFString(p)];
    if (chosen == "-") [mw.spotProgram selectItemAtIndex:1];
    else if (!chosen.empty()) [mw.spotProgram selectItemWithTitle:ADIFString(chosen)];
    std::string st = spotfeeds::status();
    if (!c.spothole && !c.cluster && !c.psk) st = tr("No spot source is turned on: choose them in Settings (Spots).");
    else if (st.empty()) st = tr("Tick Show under Spots to fetch them.");
    else
        st = trp("{n} station on the map, from {all} spots.", "{n} stations on the map, from {all} spots.", (long long)mw.view.spots.size(),
                 {{"all", std::to_string(spotfeeds::spots().spots().size())}}) +
             "\n" + st;
    mw.spotStatus.stringValue = ADIFString(st);
}

// The spots to mark: the feeds' list through the filters, one per station and band, where each is.
void refreshSpots() {
    if (!mw.window) return;
    ADIFMapStyle st = mw.view.style;
    bool show = st[kLayerSpots].show;
    spotfeeds::setHomeGrid(mw.home);
    spotfeeds::setFocusCall(spotFilter().onlyCall);
    spotfeeds::setWanted(show && mw.window.visible);
    std::vector<ADIFMapSpot> marks;
    long long now = (long long)time(nullptr);
    adif::SpotFilter f = spotFilter();
    if (show) {
        const adif::CountryTable *countries = &ADIFCountries();
        const adif::PotaParks *parks = ADIFPotaParks().size() ? &ADIFPotaParks() : nullptr;
        std::vector<adif::Spot> keep;
        for (const adif::Spot &sp : spotfeeds::spots().spots())
            if (adif::spotMatches(f, sp, now, countries, parks)) keep.push_back(sp);
        // Every spot of a station on a band, newest first: who heard it.
        std::map<std::string, std::vector<const adif::Spot *>> byStation;
        for (const adif::Spot &sp : keep) byStation[adif::spotterCall(sp.activator) + "|" + sp.band].push_back(&sp);
        for (auto &kv : byStation)
            std::stable_sort(kv.second.begin(), kv.second.end(), [](const adif::Spot *a, const adif::Spot *b) { return a->epoch > b->epoch; });
        for (adif::Spot &sp : adif::latestPerStation(keep)) {
            adif::SpotPlace at = adif::spotPlace(sp, countries);
            if (!at.ok) continue;
            ADIFMapSpot m;
            m.lat = at.lat, m.lon = at.lon, m.exact = at.exact;
            std::set<std::string> seen;
            // Up to 12 spotters a station; your own signal (PSKReporter) keeps up to 100: who heard you.
            size_t most = sp.heardMe || !f.onlyCall.empty() ? 100 : 12;
            for (const adif::Spot *by : byStation[adif::spotterCall(sp.activator) + "|" + sp.band]) {
                if (m.heard.size() >= most) break;
                if (by->spotter.empty() || !seen.insert(adif::spotterCall(by->spotter)).second) continue;
                adif::SpotPlace from = adif::spotterPlace(*by, countries);
                if (!from.ok) continue;
                ADIFSpotHeard h;
                h.call = by->spotter, h.lat = from.lat, h.lon = from.lon, h.epoch = by->epoch, h.source = by->source;
                h.hasSnr = by->hasSnr, h.snr = by->snr;
                m.heard.push_back(h);
            }
            m.spot = std::move(sp);
            marks.push_back(std::move(m));
        }
    }
    // Live's Quick Views: how many stations each has, and only the chosen one's kept.
    for (size_t &n : mw.lensCounts) n = 0;
    std::vector<std::string> spotBands;  // before the legend hides any: its entries
    mw.watchedSpots.clear();
    mw.newestSpot = 0;
    if (show) {
        const adif::CountryTable *countries = &ADIFCountries();
        std::vector<ADIFMapSpot> kept;
        std::vector<std::string> watch = watchList();
        // The legend's entries clicked off: those spots hidden, while the legend shows the entry.
        ADIFMapStyle look = mw.view.style;
        auto legendHides = [&](const adif::Spot &sp, const adif::SpotStatus &st) {
            const std::set<std::string> &off = look.legendHidden;
            if (!look.legend || off.empty()) return false;
            if (mapkit::potaSpot(sp) && off.count("spot.pota")) return true;
            if (look.colorBy == 1) return off.count("band." + sp.band) > 0;
            if (look.colorBy != 0) return false;
            switch (st.need) {
                case adif::SpotNeed::NewDxcc: return off.count("need.newdxcc") > 0;
                case adif::SpotNeed::NewBand:
                case adif::SpotNeed::NewMode: return off.count("need.newband") > 0;
                case adif::SpotNeed::Worked: return off.count("need.worked") > 0;
                case adif::SpotNeed::Confirmed: return off.count("need.confirmed") > 0;
                default: return false;
            }
        };
        for (ADIFMapSpot &m : marks) {
            adif::SpotStatus st = adif::spotStatus(mw.view.worked, m.spot, countries);
            mw.newestSpot = std::max(mw.newestSpot, m.spot.epoch);
            if (!m.spot.heardMe) m.watched = adif::watchedFor(watch, m.spot, st.entity);
            if (!m.watched.empty()) mw.watchedSpots.push_back({m.spot.activator, m.spot.band, m.spot.khz, m.spot.mode, m.watched, m.spot.epoch});
            if (!m.spot.band.empty() && std::find(spotBands.begin(), spotBands.end(), m.spot.band) == spotBands.end()) spotBands.push_back(m.spot.band);
            if (legendHides(m.spot, st)) continue;
            for (int v = 0; v < (int)std::size(mw.lensCounts); ++v) mw.lensCounts[v] += inLens(v, m.spot, st, !m.watched.empty());
            if (inLens(mw.spotLens, m.spot, st, !m.watched.empty())) kept.push_back(std::move(m));
        }
        marks = std::move(kept);
        std::stable_sort(mw.watchedSpots.begin(), mw.watchedSpots.end(), [](const ADIFWatchedSpot &a, const ADIFWatchedSpot &b) { return a.epoch > b.epoch; });
    }
    fillBell();
    long long newest = 0;
    for (const ADIFMapSpot &m : marks) newest = std::max(newest, m.spot.epoch);
    if (live()) {
        std::string live = show ? trp("{n} station on the map", "{n} stations on the map", (long long)marks.size()) : tr("Spots off");
        if (show && (spotfeeds::lastUpdate() > 0 || newest > 0)) {  // when a feed last brought spots, else the newest spot's time
            char hhmm[8];
            time_t t = (time_t)(spotfeeds::lastUpdate() > 0 ? spotfeeds::lastUpdate() : newest);
            strftime(hhmm, sizeof hhmm, "%H:%M", gmtime(&t));
            live += "  \u00B7  " + (spotfeeds::lastUpdate() > 0 ? trf("updated {time} UTC", {{"time", hhmm}}) : trf("newest {time} UTC", {{"time", hhmm}}));
        }
        // The feeds' health as a dot: green with a spot in the last 15 minutes, orange when older, grey off.
        NSColor *dot = !show ? NSColor.tertiaryLabelColor : newest > 0 && now - newest < 900 ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
        mw.scopeLabel.attributedStringValue = dotted(live, dot, mw.scopeLabel.font);
        mw.liveLabel.attributedTitle = dotted(show ? tr("Live data") + (newest > 0 ? "  \u00B7  " + utcAt(newest, "%Y-%m-%d %H:%M UTC") : "") : tr("Live: spots off"), dot,
                                              mw.liveLabel.font);
        mw.liveLabel.toolTip = show ? ADIFString(spotfeeds::status()) : nil;  // each feed: what it did, and when
        [mw.spotAgeBar selectItemAtIndex:number("mapSpotsAge", 1, 2)];
        fillDxccPotaBars();
        {  // the source: all, one, or "2 sources"
            std::string hidden = setting("mapSpotsHidden");
            std::vector<NSInteger> shown;
            for (size_t k = 0; k < 3; ++k)
                if (hidden.find(adif::spotSourceName(kSpotSources[k])) == std::string::npos) shown.push_back((NSInteger)k + 1);
            while (mw.spotSourceBar.numberOfItems > 4) [mw.spotSourceBar removeItemAtIndex:4];
            if (shown.size() == 3) [mw.spotSourceBar selectItemAtIndex:0];
            else if (shown.size() == 1) [mw.spotSourceBar selectItemAtIndex:shown[0]];
            else {
                [mw.spotSourceBar addItemWithTitle:TP(@"{n} source", @"{n} sources", (long long)shown.size())];
                [mw.spotSourceBar selectItemAtIndex:4];
            }
        }
        fillQuickViews();
        updateFilterButton();  // Clear and the tags, as the spots' filters are
    }
    mw.view.legendSpotBands = spotBands;
    [mw.view setSpots:marks now:now maxAge:f.maxAge];
    fillRecentSpots();
    fillBandConditions();
    queueViewList();
    showSituation();
    mw.refreshSpotsButton.enabled = show;
    // The information box follows the chosen spot or spotter (its age, who else heard it), or goes with it.
    ADIFMapHit chosen = mw.view.selectedHit;
    if (chosen.kind == ADIFMapHit::Spot || chosen.kind == ADIFMapHit::Spotter) [mw.view setInfo:spotInfo(chosen)];
    else if (!mw.view.info.empty()) [mw.view setInfo:std::vector<ADIFInfoRow>()];
    fillSpotsPopover();
}

// History's Awards: how far the log (as the filters keep it) is toward the awards whose rules were
// read from their sponsors (2026-10-24): a goal where the rules say one, counting the confirmations
// they accept; else a count of what there is to work. A name shows its layer.
void fillAwards() {
    if (!mw.awardsHost) return;
    for (NSView *v in [mw.awardsHost.subviews copy]) [v removeFromSuperview];
    mw.awardsSection.hidden = live() || mw.data.qsos.empty();
    if (mw.awardsSection.hidden) return;
    const int kCardLotw = 1 | 2, kAny = 1 | 2 | 4;
    auto byAccepted = [](const adif::MapQso &q, int accept) { return ((accept & 1) && q.byCard) || ((accept & 2) && q.byLotw) || ((accept & 4) && q.byEqsl); };
    struct Award {
        std::string name;
        size_t have = 0, goal = 0, total = 0;  // goal 0: no award goal shown, only a count (of total, when known)
        std::string tip;
        int layer = -1;  // the Quick View its name shows
    };
    std::vector<Award> awards;
    // ARRL DXCC: 100 current entities, by LoTW or paper card (eQSL not accepted); 340 current entities.
    size_t dxcc = 0;
    for (const ADIFMapEntity &e : mw.dxcc)
        dxcc += std::any_of(e.qsos.begin(), e.qsos.end(), [&](size_t i) { return i < mw.data.qsos.size() && byAccepted(mw.data.qsos[i], kCardLotw); });
    awards.push_back({"DXCC", dxcc, 100, 340,
                      tr("ARRL DXCC: 100 current entities confirmed by LoTW or a QSL card (eQSL isn't accepted), of 340 (arrl.org/dxcc-rules, read "
                         "2026-10-24)"),
                      kLayerCountries});
    // ARRL WAS: all 50 states, by LoTW or an original card.
    awards.push_back({"WAS", [mw.view workedCount:kLayerStates accepting:kCardLotw].second, 50, 50,
                      tr("ARRL Worked All States: all 50 states confirmed by LoTW or a QSL card; DC counts for Maryland, 60m doesn't count "
                         "(arrl.org/was, read 2026-10-24)"),
                      kLayerStates});
    // WAZ: all 40 CQ zones (now managed by N4BAA).
    awards.push_back({"WAZ", [mw.view workedCount:kLayerCq accepting:kAny].second, 40, 40,
                      tr("Worked All Zones: all 40 CQ zones confirmed (managed by N4BAA since 2022; check its rules for the confirmations it "
                         "accepts: n4baa.com, read 2026-10-24)"),
                      kLayerCq});
    // ARRL VUCC: 100 grid squares on 6m, and on 2m, by LoTW or card (a VHF and up award).
    for (const char *band : {"6m", "2m"}) {
        std::set<std::string> worked, confirmed;
        for (const adif::MapQso &q : mw.data.qsos) {
            if (strcasecmp(q.band.c_str(), band) != 0 || q.grid.size() < 4 || adif::isPlaceholderGrid(q.grid)) continue;
            std::string g = q.grid.substr(0, 4);
            for (char &c : g) c = (char)toupper((unsigned char)c);
            worked.insert(g);
            if (byAccepted(q, kCardLotw)) confirmed.insert(g);
        }
        if (worked.empty()) continue;  // only for a band in the log
        awards.push_back({trf("VUCC {band}", {{"band", band}}), confirmed.size(), 100, 0,
                          trf("ARRL VUCC on {band}: 100 grid squares confirmed by LoTW or a QSL card, from within 200 km (arrl.org/vucc, read "
                              "2026-10-24)",
                              {{"band", band}}),
                          kLayerSquares});
    }
    // US counties: the MARAC USA-CA award (since 2024) counts worked counties, on its honor system.
    awards.push_back({tr("US counties"), [mw.view workedCount:kLayerCounties].first, 0, 3077,
                      tr("US counties worked, of 3,077; MARAC's USA-CA award (sponsor since November 2024) counts them on its honor system "
                         "(marac.org, read 2026-10-24)"),
                      kLayerCounties});
    std::set<std::string> continents;
    for (const adif::MapQso &q : mw.data.qsos)
        if (q.confirmed && !q.areas.cont.empty() && q.areas.cont != "AN") continents.insert(q.areas.cont);
    awards.push_back({tr("Continents"), continents.size(), 0, 6, tr("The continents (AF, AS, EU, NA, OC, SA) you have a confirmed QSO with"), -1});
    if (!ADIFIotaGroups().empty())
        awards.push_back({tr("IOTA groups"), [mw.view workedCount:kLayerIota].second, 0, ADIFIotaGroups().size(),
                          tr("IOTA groups confirmed, of those in IOTA's list"), kLayerIota});
    std::set<std::string> hunted;
    for (const adif::MapQso &q : mw.data.qsos) hunted.insert(q.potaHunted.begin(), q.potaHunted.end());
    if (!hunted.empty())
        awards.push_back({tr("POTA parks hunted"), hunted.size(), 0, ADIFPotaParks().size(), tr("The POTA parks you have QSOs with (hunted)"), kLayerPota});
    NSGridView *g = [NSGridView gridViewWithNumberOfColumns:3 rows:0];
    g.rowSpacing = 4;
    g.columnSpacing = 10;
    g.identifier = @"map.awards";
    for (const Award &a : awards) {
        NSButton *name = [NSButton buttonWithTitle:ADIFString(a.name) target:nil action:nil];
        name.bordered = NO;
        name.alignment = NSTextAlignmentLeft;
        name.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
        name.contentTintColor = a.layer >= 0 ? NSColor.linkColor : NSColor.labelColor;
        name.toolTip = ADIFString(a.tip);
        if (a.layer >= 0) {
            int view = historyViewOf(a.layer);
            ADIFOnAction(name, ^{ chooseQuickView(view); });
        } else {
            name.enabled = NO;
        }
        std::string count = grouped(a.have) + (a.goal ? " / " + grouped(a.goal) : a.total ? " " + trf("of {n}", {{"n", grouped(a.total)}}) : "");
        NSTextField *n = [NSTextField labelWithString:ADIFString(count)];
        n.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
        n.alignment = NSTextAlignmentRight;
        n.toolTip = name.toolTip;
        NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
        bar.style = NSProgressIndicatorStyleBar;
        bar.indeterminate = NO;
        bar.controlSize = NSControlSizeSmall;
        bar.minValue = 0;
        bar.maxValue = (double)std::max<size_t>(1, a.goal ? a.goal : a.total);
        bar.doubleValue = std::min<double>((double)a.have, bar.maxValue);
        bar.toolTip = name.toolTip;
        NSLayoutConstraint *wide = [bar.widthAnchor constraintEqualToConstant:70];  // narrower before the words are cut
        wide.priority = NSLayoutPriorityDefaultLow;
        wide.active = YES;
        [bar.widthAnchor constraintGreaterThanOrEqualToConstant:24].active = YES;
        for (NSView *v in @[ name, n ]) [v setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh + 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        bar.hidden = !a.goal && !a.total;
        [g addRowWithViews:@[ name, n, bar ]];
    }
    for (NSInteger r = 0; r < g.numberOfRows; ++r) [g rowAtIndex:r].yPlacement = NSGridCellPlacementCenter;
    g.translatesAutoresizingMaskIntoConstraints = NO;
    [mw.awardsHost addSubview:g];
    [NSLayoutConstraint activateConstraints:@[
        [g.topAnchor constraintEqualToAnchor:mw.awardsHost.topAnchor], [g.bottomAnchor constraintEqualToAnchor:mw.awardsHost.bottomAnchor],
        [g.leadingAnchor constraintEqualToAnchor:mw.awardsHost.leadingAnchor],
        [g.trailingAnchor constraintLessThanOrEqualToAnchor:mw.awardsHost.trailingAnchor]  // the bars give way first
    ]];
}

// Live's Band conditions, from the spots (as the Spots filters keep them, on every band): a row a
// band, its stations spotted and those heard within 1,500 km of you, with the best report; and a
// line for the band in focus (the band filter's, else the chosen spot's, else the one most heard
// near you). A band's name sets the band filter (or clears it).
void fillBandConditions() {
    if (!mw.bandHost) return;
    for (NSView *v in [mw.bandHost.subviews copy]) [v removeFromSuperview];
    bool show = live() && mw.view.style[kLayerSpots].show;
    std::vector<adif::BandActivity> act;
    double hlat = 0, hlon = 0;
    bool home = !mw.home.empty() && adif::gridToLatLon(mw.home, &hlat, &hlon);
    if (show) {
        adif::SpotFilter f = spotFilter();
        f.map.band.clear();  // every band, the filter's in focus
        long long now = (long long)time(nullptr);
        const adif::CountryTable *countries = &ADIFCountries();
        std::vector<adif::Spot> kept;
        for (const adif::Spot &sp : spotfeeds::spots().spots())
            if (adif::spotMatches(f, sp, now, countries, &ADIFPotaParks())) kept.push_back(sp);
        act = adif::bandActivity(kept, home, hlat, hlon, 1500, countries);
    }
    mw.bandSection.hidden = act.empty();
    if (act.empty()) return;
    std::string focus = mw.band.indexOfSelectedItem > 0 ? ADIFStd(mw.band.titleOfSelectedItem) : "";
    for (char &c : focus) c = (char)tolower((unsigned char)c);
    ADIFMapHit h = mw.view.selectedHit;
    if (focus.empty() && h.kind == ADIFMapHit::Spot && h.index < mw.view.spots.size()) {
        focus = mw.view.spots[h.index].spot.band;
        for (char &c : focus) c = (char)tolower((unsigned char)c);
    }
    const adif::BandActivity *in = nullptr;
    for (const adif::BandActivity &a : act)
        if (a.band == focus) in = &a;
    if (!in)
        for (const adif::BandActivity &a : act)
            if (!in || a.nearStations > in->nearStations || (a.nearStations == in->nearStations && a.stations > in->stations)) in = &a;
    // The band in focus, in words.
    std::string conts;
    for (size_t i = 0; i < in->continents.size() && i < 4; ++i)
        conts += (conts.empty() ? "" : ", ") + in->continents[i].first + " " + std::to_string(in->continents[i].second);
    std::string line = trp("{band}: {n} station spotted", "{band}: {n} stations spotted", (long long)in->stations, {{"band", in->band}});
    if (!conts.empty()) line += " (" + conts + ")";
    if (home && in->nearStations)
        line += "; " + trp("heard near you: {n} station", "heard near you: {n} stations", (long long)in->nearStations) + ", " +
                trp("by {n} spotter within 1,500 km", "by {n} spotters within 1,500 km", (long long)in->nearSpotters) +
                (in->nearSnr ? ", " + trf("best {snr} dB", {{"snr", (in->bestNearSnr > 0 ? "+" : "") + std::to_string(in->bestNearSnr)}}) : "");
    else if (home) line += "; " + tr("none heard within 1,500 km of you yet");
    if (in->newest > 0) line += "; " + trf("newest {age}", {{"age", adif::spotAge(in->newest, (long long)time(nullptr))}});
    line += ".";
    if (std::string sun = flag("mapSolar", false) ? solarSummary() : ""; !sun.empty()) line += " " + sun + " (NOAA SWPC).";
    mw.bandLine.stringValue = ADIFString(line);
    // A row a band.
    NSGridView *g = [NSGridView gridViewWithNumberOfColumns:4 rows:0];
    g.rowSpacing = 2;
    g.columnSpacing = 12;
    g.identifier = @"map.bands";
    auto cell = [](const std::string &text, bool head, bool bold) {
        NSTextField *f = [NSTextField labelWithString:ADIFString(text)];
        f.font = head ? [NSFont systemFontOfSize:NSFont.smallSystemFontSize - 1 weight:NSFontWeightMedium]
                      : [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
        f.textColor = head ? NSColor.secondaryLabelColor : NSColor.labelColor;
        f.alignment = NSTextAlignmentRight;
        return f;
    };
    [g addRowWithViews:@[ [NSGridCell emptyContentView], cell(tr("Stations##band"), true, false), cell(tr("Near you"), true, false), cell(tr("Best"), true, false) ]];
    for (const adif::BandActivity &a : act) {
        bool focused = &a == in;
        std::string band = a.band;
        NSButton *b = [NSButton buttonWithTitle:@"" target:nil action:nil];
        b.bordered = NO;
        b.alignment = NSTextAlignmentLeft;
        b.attributedTitle = [[NSAttributedString alloc]
            initWithString:ADIFString(band)
                attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:focused ? NSFontWeightSemibold : NSFontWeightRegular],
                             NSForegroundColorAttributeName : NSColor.linkColor}];
        b.toolTip = T(@"Show only this band (the band filter); again, every band");
        b.identifier = [@"map.band." stringByAppendingString:ADIFString(band)];
        ADIFOnAction(b, ^{
            NSInteger at = -1;
            for (NSInteger i = 1; i < mw.band.numberOfItems; ++i)
                if ([[mw.band itemAtIndex:i].title caseInsensitiveCompare:ADIFString(band)] == NSOrderedSame) at = i;
            if (at < 0) {  // a band spotted that the menu doesn't have yet
                [mw.band addItemWithTitle:ADIFString(band)];
                at = mw.band.numberOfItems - 1;
            }
            [mw.band selectItemAtIndex:mw.band.indexOfSelectedItem != at ? at : 0];
            [mw.band sendAction:mw.band.action to:mw.band.target];
        });
        std::string best = home && a.nearSnr ? (a.bestNearSnr > 0 ? "+" : "") + std::to_string(a.bestNearSnr) + " dB" : "";
        [g addRowWithViews:@[ b, cell(grouped(a.stations), false, focused), cell(home ? grouped(a.nearStations) : "", false, focused), cell(best, false, focused) ]];
    }
    for (NSInteger r = 0; r < g.numberOfRows; ++r) [g rowAtIndex:r].yPlacement = NSGridCellPlacementCenter;
    g.translatesAutoresizingMaskIntoConstraints = NO;
    [mw.bandHost addSubview:g];
    [NSLayoutConstraint activateConstraints:@[
        [g.topAnchor constraintEqualToAnchor:mw.bandHost.topAnchor], [g.bottomAnchor constraintEqualToAnchor:mw.bandHost.bottomAnchor],
        [g.leadingAnchor constraintEqualToAnchor:mw.bandHost.leadingAnchor],
        [g.trailingAnchor constraintLessThanOrEqualToAnchor:mw.bandHost.trailingAnchor]
    ]];
}

// Live's newest spots, a row each (fainter after 15 minutes), each call a link that chooses its
// spot; View all spots shows the list's Spots.
void fillRecentSpots() {
    if (!mw.recentHost) return;
    for (NSView *v in [mw.recentHost.subviews copy]) [v removeFromSuperview];
    const std::vector<ADIFMapSpot> &spots = mw.view.spots;
    bool show = live() && mw.view.style[kLayerSpots].show && !spots.empty();
    mw.recentSection.hidden = !show;
    if (!show) return;
    std::vector<size_t> order(spots.size());
    for (size_t i = 0; i < order.size(); ++i) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return spots[a].spot.epoch > spots[b].spot.epoch; });
    NSGridView *g = [NSGridView gridViewWithNumberOfColumns:5 rows:0];
    g.rowSpacing = 2;
    g.columnSpacing = 10;
    g.identifier = @"map.recent";
    long long now = (long long)time(nullptr);
    for (size_t i = 0; i < order.size() && i < 5; ++i) {
        const adif::Spot &sp = spots[order[i]].spot;
        bool old = sp.epoch > 0 && now - sp.epoch > 900;
        NSColor *ink = old ? faintInk() : NSColor.labelColor;
        std::string activator = sp.activator, band = sp.band;
        NSButton *call = [NSButton buttonWithTitle:@"" target:nil action:nil];
        call.bordered = NO;
        call.attributedTitle = [[NSAttributedString alloc]
            initWithString:ADIFString(activator)
                attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName : old ? faintInk() : NSColor.linkColor}];
        call.identifier = [NSString stringWithFormat:@"map.recent.%zu", i];
        ADIFOnAction(call, ^{  // the spot (found again: the spots may have changed), chosen on the map
            const std::vector<ADIFMapSpot> &now = mw.view.spots;
            for (size_t k = 0; k < now.size(); ++k)
                if (now[k].spot.activator == activator && now[k].spot.band == band) {
                    ADIFMapHit h;
                    h.kind = ADIFMapHit::Spot, h.index = k, h.square = adif::squareAt(now[k].lon, now[k].lat);
                    [mw.view selectHit:h];
                    return;
                }
        });
        auto cell = [&](const std::string &text, bool right) {
            NSTextField *f = [NSTextField labelWithString:ADIFString(text)];
            f.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
            f.textColor = ink;
            f.alignment = right ? NSTextAlignmentRight : NSTextAlignmentLeft;
            return f;
        };
        [g addRowWithViews:@[ call, cell(sp.khz, true), cell(sp.band, false), cell(sp.mode, false), cell(adif::spotAge(sp.epoch, now), true) ]];
    }
    for (NSInteger r = 0; r < g.numberOfRows; ++r) [g rowAtIndex:r].yPlacement = NSGridCellPlacementCenter;
    g.translatesAutoresizingMaskIntoConstraints = NO;
    [mw.recentHost addSubview:g];
    [NSLayoutConstraint activateConstraints:@[
        [g.topAnchor constraintEqualToAnchor:mw.recentHost.topAnchor], [g.bottomAnchor constraintEqualToAnchor:mw.recentHost.bottomAnchor],
        [g.leadingAnchor constraintEqualToAnchor:mw.recentHost.leadingAnchor], [g.trailingAnchor constraintLessThanOrEqualToAnchor:mw.recentHost.trailingAnchor]
    ]];
}

void useSelectedSpot() {
    ADIFMapHit h = mw.view.selectedHit;
    if (h.kind != ADIFMapHit::Spot || h.index >= mw.view.spots.size() || !mw.spotHandler) return;
    const adif::Spot &sp = mw.view.spots[h.index].spot;
    mw.spotHandler(adif::spotQsoFields(sp));
    setStatus(trf("Copied {call} ({khz} kHz {mode}) to New QSO.", {{"call", sp.activator}, {"khz", sp.khz}, {"mode", sp.mode}}));
}

void showSpotsPopover() {
    if (!mw.spotsPopover) {
        NSTextField *help = [NSTextField wrappingLabelWithString:T(@"The spots the Spots layer shows. Where they come from is set in Settings (Spots); "
                                                                 @"the Map's band, mode and place filters apply to them too.")];
        help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        help.textColor = NSColor.secondaryLabelColor;
        mw.spotAge = ADIFPopup(@[ @(kSpotAgeTitles[0]), @(kSpotAgeTitles[1]), @(kSpotAgeTitles[2]) ]);
        mw.spotAge.identifier = @"map.spots.age";
        ADIFOnAction(mw.spotAge, ^{
            setSetting("mapSpotsAge", std::to_string(mw.spotAge.indexOfSelectedItem));
            refreshSpots();
        });
        NSMutableArray *sources = [NSMutableArray array];
        for (size_t i = 0; i < 3; ++i) {
            mw.spotSource[i] = ADIFCheckbox(@(adif::spotSourceName(kSpotSources[i])), true);
            mw.spotSource[i].identifier = [NSString stringWithFormat:@"map.spots.source.%zu", i];
            ADIFOnAction(mw.spotSource[i], ^{
                std::string hidden;
                for (size_t k = 0; k < 3; ++k)
                    if (mw.spotSource[k].enabled && mw.spotSource[k].state != NSControlStateValueOn)
                        hidden += (hidden.empty() ? "" : ",") + std::string(adif::spotSourceName(kSpotSources[k]));
                setSetting("mapSpotsHidden", hidden);
                refreshSpots();
            });
            [sources addObject:mw.spotSource[i]];
        }
        NSStackView *sourceRow = [NSStackView stackViewWithViews:sources];
        sourceRow.spacing = 12;
        mw.spotProgram = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        mw.spotProgram.identifier = @"map.spots.program";
        ADIFOnAction(mw.spotProgram, ^{
            NSInteger i = mw.spotProgram.indexOfSelectedItem;
            setSetting("mapSpotsProgram", i <= 0 ? "" : i == 1 ? "-" : ADIFStd(mw.spotProgram.titleOfSelectedItem));
            refreshSpots();
        });
        mw.spotStatus = [NSTextField wrappingLabelWithString:@""];
        mw.spotStatus.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.spotStatus.textColor = NSColor.secondaryLabelColor;
        mw.spotStatus.identifier = @"map.spots.status";
        NSButton *settings = [NSButton buttonWithTitle:T(@"Settings...") target:nil action:nil];
        ADIFOnAction(settings, ^{ openSettings(-4); });
        NSGridView *grid = [NSGridView gridViewWithViews:@[
            @[ ADIFLabel(@"Newer than:"), mw.spotAge ], @[ ADIFLabel(@"From:"), sourceRow ], @[ ADIFLabel(@"Program:"), mw.spotProgram ],
            @[ [NSGridCell emptyContentView], settings ]
        ]];
        grid.rowSpacing = 8;
        grid.columnSpacing = 10;
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
        NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
        content.identifier = @"map.spots";
        for (NSView *v in @[ help, grid, mw.spotStatus ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [content addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [help.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
            [help.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [help.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [help.widthAnchor constraintEqualToAnchor:grid.widthAnchor],
            [grid.widthAnchor constraintGreaterThanOrEqualToConstant:420],
            [grid.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:10],
            [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [mw.spotStatus.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:10],
            [mw.spotStatus.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [mw.spotStatus.widthAnchor constraintEqualToAnchor:grid.widthAnchor],
            [mw.spotStatus.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        ]];
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = content;
        mw.spotsPopover = [[NSPopover alloc] init];
        mw.spotsPopover.contentViewController = vc;
        ADIFNightTrackPopover(mw.spotsPopover);
        mw.spotsPopover.behavior = NSPopoverBehaviorTransient;
    }
    fillSpotsPopover();
    revealSection(@"spots");  // beside its section, open
    [mw.spotsPopover showRelativeToRect:mw.spotsButton.bounds ofView:mw.spotsButton preferredEdge:NSRectEdgeMaxX];
}

// A Labels box works while its layer shows (outlined, or its worked areas); off, it is faded, so
// that it doesn't look like a box merely unticked.
void labelsFollow() {
    for (const LayerUi &l : kLayerUi) {
        NSButton *b = mw.labels[l.id];
        b.enabled = mw.overlay[l.id].state == NSControlStateValueOn || (mw.show[l.id] && mw.show[l.id].state == NSControlStateValueOn);
        if (l.id == kLayerSpots) continue;  // its title greys
        b.alphaValue = b.enabled ? 1 : moreContrast() ? 0.55 : 0.35;
        b.toolTip = b.enabled ? T(l.labelsTip) : [T(l.labelsTip) stringByAppendingFormat:@"\n%@", T(@"Labels work while the layer shows: tick Worked or All")];
    }
}

// A layer's box changed (0 Show, 1 Overlay, 2 Labels). Ticking Show turns that layer's Overlay
// and Labels on too: the worked areas among all of them, named.
void layerChanged(MapLayerId id, int which) {
    if (which == 0 && mw.show[id].state == NSControlStateValueOn) {
        if (id != kLayerSpots) mw.overlay[id].state = NSControlStateValueOn;  // spots: lines from the spotters only when asked
        mw.labels[id].state = NSControlStateValueOn;
    }
    for (const LayerUi &l : kLayerUi) {
        if (l.showKey) saveFlag(l.showKey, mw.show[l.id].state == NSControlStateValueOn);
        saveFlag(l.overlayKey, mw.overlay[l.id].state == NSControlStateValueOn);
        saveFlag(l.labelsKey, mw.labels[l.id].state == NSControlStateValueOn);
    }
    labelsFollow();
    applyStyle();
    fillStyle();
    if (id == kLayerSpots) refreshSpots();
    bool on = which != 2 && (which == 0 ? mw.show[id] : mw.overlay[id]).state == NSControlStateValueOn;
    if (on && id == kLayerIota && ADIFIotaGroups().empty()) setStatus("IOTA: download IOTA's group list first, in Settings (IOTA Groups).");
    if (on && id == kLayerPota && !ADIFPotaParks().size())
        setStatus("POTA: download POTA's park list first, in Settings (POTA Parks). Until then, the parks you hunted show at the QSO's grid.");
    if (!mw.applyingView && !live() && quickView() != -1) {  // History's layers as you set them: no Quick View
        setSetting("mapQuickView", "-1");
        fillQuickViews();
    }
}

// ── POTA parks in: the park filter ──

// The location of your station (home), for the filter to start at: its US state, else the
// nearest park's location; "" without home or the park list.
std::string homeParkLocation() {
    double lat, lon;
    if (mw.home.empty() || !adif::gridToLatLon(mw.home, &lat, &lon) || !ADIFPotaParks().size()) return "";
    return adif::parkLocationAt(ADIFPotaParks(), lat, lon);
}

// The places chosen (mapParkPlaces: unset, your station's location; "*" everywhere; else the
// locations) and their US counties (mapParkCounties).
adif::ParkPlaces parkPlaces() {
    adif::ParkPlaces places;
    std::string chosen = setting("mapParkPlaces");
    if (chosen.empty()) {
        if (std::string home = homeParkLocation(); !home.empty()) places.locations.insert(home);
    } else if (chosen != "*") {
        for (const std::string &l : splitSetting("mapParkPlaces", ',')) places.locations.insert(l);
    }
    for (const std::string &c : splitSetting("mapParkCounties", ';'))
        if (std::string key = adif::countyKey(c); !key.empty()) places.counties.insert(key);
    return places;
}

// "US-IL", "US-IL, US-WI", "4 locations", with "2 counties"; "everywhere".
std::string parkPlacesName(const adif::ParkPlaces &places) {
    std::string name;
    if (places.locations.size() > 2) name = plural(places.locations.size(), "location");
    else
        for (const std::string &l : places.locations) name += (name.empty() ? "" : ", ") + l;
    if (!places.counties.empty()) {
        std::string counties = trp("{n} county", "{n} counties", (long long)places.counties.size());
        name = name.empty() ? counties : name + ", " + counties;
    }
    return name.empty() ? tr("everywhere") : name;
}

void queueViewList();

// The filter applied: the map, its button, the list.
void applyParkPlaces() {
    if (!mw.view) return;
    adif::ParkPlaces places = parkPlaces();
    std::string name = parkPlacesName(places);
    [mw.view setParkPlaces:places named:places.any() ? name : ""];
    mw.parkPlacesButton.title = [ADIFString(name) stringByAppendingString:@"…"];
    queueViewList();
}

// The popover's fields from the settings; the counties offered are those of the US states chosen
// (all of them when none is).
void fillParkPlaces() {
    adif::ParkPlaces places = parkPlaces();
    NSMutableArray *locs = [NSMutableArray array], *counties = [NSMutableArray array];
    for (const std::string &l : places.locations) [locs addObject:ADIFString(l)];
    for (const std::string &c : splitSetting("mapParkCounties", ';')) [counties addObject:ADIFString(c)];
    mw.parkLocations.objectValue = locs;
    mw.parkCounties.objectValue = counties;
    std::set<std::string> states;
    for (const std::string &l : places.locations)
        if (l.size() == 5 && l.compare(0, 3, "US-") == 0) states.insert(l.substr(3) + ",");
    NSMutableArray *offer = [NSMutableArray array];
    const adif::AreaIndex &co = adif::areaIndex(adif::Overlay::UsCounties);
    for (size_t i = 0; i < co.size(); ++i) {
        const std::string &n = co.area(i).name;
        if (states.empty() || states.count(n.substr(0, n.find(',') + 1))) [offer addObject:ADIFString(n)];
    }
    mw.countyCompleter.candidates = offer;
    std::string home = homeParkLocation();
    mw.parkHome.title = home.empty() ? T(@"Your Station's") : TF(@"Your Station's ({location})", @{@"location" : ADIFString(home)});
    mw.parkHome.enabled = !home.empty();
}

// The fields changed: kept (no locations: everywhere), and applied.
void parkPlacesChanged() {
    std::vector<std::string> locs;
    for (std::string l : tokens(mw.parkLocations)) {
        for (char &c : l) c = (char)toupper((unsigned char)c);
        locs.push_back(l);
    }
    if (locs.empty()) setSetting("mapParkPlaces", "*");
    else saveSetting("mapParkPlaces", locs, ',');
    saveSetting("mapParkCounties", tokens(mw.parkCounties), ';');
    fillParkPlaces();
    applyParkPlaces();
}

void showParkPlaces() {
    if (!mw.parkPlacesPopover) {
        NSMutableArray *locations = [NSMutableArray array];
        for (const std::string &l : parkoutlines::locations()) [locations addObject:ADIFString(l)];
        auto field = [](NSString *ident, NSString *placeholder, NSString *separators, ADIFTokenCompleter *c) {
            NSTokenField *t = [[NSTokenField alloc] initWithFrame:NSMakeRect(0, 0, 340, 24)];
            t.identifier = ident;
            t.placeholderString = T(placeholder);
            t.tokenizingCharacterSet = [NSCharacterSet characterSetWithCharactersInString:separators];
            t.delegate = c;
            [t.widthAnchor constraintEqualToConstant:340].active = YES;
            ADIFOnAction(t, ^{ parkPlacesChanged(); });
            return t;
        };
        ADIFTokenCompleter *locs = [[ADIFTokenCompleter alloc] init];
        locs.candidates = locations;
        mw.countyCompleter = [[ADIFTokenCompleter alloc] init];
        if (!mw.completers) mw.completers = [NSMutableArray array];
        [mw.completers addObjectsFromArray:@[ locs, mw.countyCompleter ]];
        mw.parkLocations = field(@"map.parkplaces.locations", N(@"POTA locations, e.g. US-IL, CA-ON, VK-NSW"), @", ", locs);
        mw.parkCounties = field(@"map.parkplaces.counties", N(@"US counties, e.g. IL,Cook; IL,DuPage"), @";", mw.countyCompleter);
        mw.parkHome = [NSButton buttonWithTitle:T(@"Your Station's") target:nil action:nil];
        mw.parkHome.identifier = @"map.parkplaces.home";
        mw.parkHome.toolTip = T(@"Your station's location (Settings, Your Station's grid), and no counties; it follows your grid if it changes");
        ADIFOnAction(mw.parkHome, ^{
            setSetting("mapParkPlaces", "");
            setSetting("mapParkCounties", "");
            fillParkPlaces();
            applyParkPlaces();
        });
        NSButton *all = [NSButton buttonWithTitle:T(@"Everywhere") target:nil action:nil];
        all.identifier = @"map.parkplaces.all";
        ADIFOnAction(all, ^{
            setSetting("mapParkPlaces", "*");
            setSetting("mapParkCounties", "");
            fillParkPlaces();
            applyParkPlaces();
        });
        NSStackView *buttons = [NSStackView stackViewWithViews:@[ mw.parkHome, all ]];
        buttons.spacing = 8;
        NSGridView *grid = [NSGridView gridViewWithViews:@[
            @[ ADIFLabel(@"Locations:"), mw.parkLocations ], @[ ADIFLabel(@"US counties:"), mw.parkCounties ],
            @[ [NSGridCell emptyContentView], buttons ]
        ]];
        grid.rowSpacing = 8;
        grid.columnSpacing = 10;
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
        grid.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *help = [NSTextField
            wrappingLabelWithString:T(@"Fewer POTA parks you haven't worked, on the map and in the list beside it: only those in these POTA "
                                      @"locations (US states, Canadian provinces, other countries' regions, as POTA names them) and, in a US "
                                      @"state, these counties. It starts at your station's location; the parks you worked always show.")];
        help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        help.textColor = NSColor.secondaryLabelColor;
        help.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
        content.identifier = @"map.parkplaces";
        [content addSubview:help];
        [content addSubview:grid];
        [NSLayoutConstraint activateConstraints:@[
            [help.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
            [help.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [help.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [help.widthAnchor constraintEqualToAnchor:grid.widthAnchor],
            [grid.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:10],
            [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [grid.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [grid.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        ]];
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = content;
        mw.parkPlacesPopover = [[NSPopover alloc] init];
        mw.parkPlacesPopover.contentViewController = vc;
        ADIFNightTrackPopover(mw.parkPlacesPopover);
        mw.parkPlacesPopover.behavior = NSPopoverBehaviorTransient;
    }
    fillParkPlaces();
    revealSection(@"filters");  // beside its section, open
    [mw.parkPlacesPopover showRelativeToRect:mw.parkPlacesButton.bounds ofView:mw.parkPlacesButton preferredEdge:NSRectEdgeMaxX];
}

// How good a chance a spot is, by the workflow's goal (the lower the better): your watch list
// first; in POTA the parks you haven't hunted, then the other activators, then the rest as
// elsewhere: a new DXCC, a new band, a new mode, a new park; your own signal last.
int opportunity(const ADIFMapSpot &ms) {
    if (ms.spot.heardMe) return 99;
    if (!ms.watched.empty()) return -1;
    int need = adif::spotPriority(ms.status);
    if (workflow() != 3) return need;
    return ms.status.newPark ? 0 : mapkit::potaSpot(ms.spot) ? 1 : 2 + need;
}

// ── The list beside the map: the QSOs chosen; the contacts, parks or spots in view ──


bool qsoList(int kind) { return kind == kListSelected || kind == kListContacts || kind == kListRecent; }  // a QSO a row

// A column the list can show: its id, title, width, style (0 text, 1 digits, 2 digits on the
// right), whether it shows at first, and whether it sorts as a number.
struct ListColumn {
    const char *id, *title;
    CGFloat width;
    int style;
    bool on, number;
};

const std::vector<ListColumn> &listColumns(int kind) {
    static const std::vector<ListColumn> kSelected = {
        {"record", N_("Record"), 66, 2, true, true},      {"call", N_("Call"), 76, 0, true, false},     {"date", N_("Date"), 76, 1, true, false},
        {"time", "UTC", 44, 1, true, false},               {"band", N_("Band"), 42, 1, true, false},     {"mode", N_("Mode"), 46, 0, true, false},
        {"grid", N_("Grid"), 62, 0, true, false},          {"confirmed", N_("Confirmed"), 68, 0, true, false},
        {"country", N_("Country"), 120, 0, false, false},  {"state", N_("State"), 42, 0, false, false},  {"county", N_("County"), 100, 0, false, false},
        {"cq", "CQ", 32, 2, false, true},                  {"itu", "ITU", 32, 2, false, true},           {"park", N_("Park"), 76, 0, false, false},
        {"distance", N_("Distance"), 64, 2, false, true},  {"bearing", N_("Bearing"), 54, 2, false, true},
    };
    static const std::vector<ListColumn> kContacts = [] {
        std::vector<ListColumn> c = kSelected;
        for (ListColumn &col : c) {
            std::string id = col.id;
            col.on = id == "call" || id == "date" || id == "band" || id == "mode" || id == "distance" || id == "bearing";
        }
        return c;
    }();
    static const std::vector<ListColumn> kParks = {
        {"ref", N_("Reference"), 72, 1, true, false},     {"name", N_("Park"), 170, 0, true, false},     {"location", N_("Location"), 80, 0, false, false},
        {"worked", N_("Worked"), 110, 0, false, false},   {"outline", N_("Outline"), 70, 0, false, false}, {"grid", N_("Grid"), 62, 0, false, false},
        {"distance", N_("Distance"), 64, 2, true, true},  {"bearing", N_("Bearing"), 54, 2, true, true},
    };
    static const std::vector<ListColumn> kSpots = {
        {"watch", "\u2605", 24, 1, true, true},             // on your watch list
        {"call", N_("Call"), 76, 0, true, false},          {"country", N_("Country"), 120, 0, true, false}, {"grid", N_("Grid"), 62, 0, true, false},
        {"distance", N_("Distance"), 70, 2, true, true},   {"khz", "kHz", 60, 2, true, true},             {"band", N_("Band"), 42, 1, true, false},
        {"mode", N_("Mode"), 46, 0, true, false},          {"spotter", N_("Spotter"), 76, 0, true, false}, {"age", N_("Age"), 52, 2, true, true},
        {"need", N_("Why it matters"), 150, 0, true, true}, {"time", "UTC", 44, 1, false, false},        {"program", N_("Program"), 60, 0, false, false},
        {"ref", N_("Reference"), 76, 0, false, false},     {"park", N_("Park"), 140, 0, false, false},    {"source", N_("Source"), 80, 0, false, false},
        {"snr", "SNR", 44, 2, false, true},                {"comment", N_("Comment"), 160, 0, false, false}, {"bearing", N_("Bearing"), 54, 2, false, true},
    };
    static const std::vector<ListColumn> kRecent = [] {
        std::vector<ListColumn> c = kSelected;
        for (ListColumn &col : c) {
            std::string id = col.id;
            col.on = id == "call" || id == "date" || id == "time" || id == "band" || id == "mode" || id == "grid" || id == "country" || id == "confirmed";
        }
        return c;
    }();
    static const std::vector<ListColumn> kIssues = {
        {"record", N_("Record"), 66, 2, true, true},      {"call", N_("Call"), 76, 0, true, false},  {"date", N_("Date"), 76, 1, true, false},
        {"band", N_("Band"), 42, 1, false, false},         {"severity", N_("Kind"), 66, 0, true, false}, {"field", N_("Field"), 110, 0, true, false},
        {"problem", N_("Problem"), 420, 0, true, false},   {"distance", N_("Distance"), 64, 2, false, true},
    };
    // DXCC Progress: each entity worked, its bands from 160m to 6m and its modes, ● confirmed, ○ worked.
    static const std::vector<ListColumn> kDxcc = {
        {"entity", N_("DXCC entity"), 160, 0, true, false}, {"dxcc", "DXCC", 44, 2, false, true},        {"cont", N_("Continent"), 64, 1, false, false},
        {"qsos", N_("QSOs"), 48, 2, true, true},           {"bands", N_("Bands"), 48, 2, true, true},    {"confirmedBands", N_("Confirmed"), 70, 2, true, true},
        {"b160m", "160", 30, 1, true, true}, {"b80m", "80", 26, 1, true, true}, {"b60m", "60", 26, 1, false, true}, {"b40m", "40", 26, 1, true, true},
        {"b30m", "30", 26, 1, true, true},   {"b20m", "20", 26, 1, true, true}, {"b17m", "17", 26, 1, true, true},  {"b15m", "15", 26, 1, true, true},
        {"b12m", "12", 26, 1, true, true},   {"b10m", "10", 26, 1, true, true}, {"b6m", "6", 26, 1, true, true},    {"cw", "CW", 32, 1, true, true},
        {"phone", N_("Phone"), 48, 1, true, true},         {"data", N_("Data"), 42, 1, true, true},      {"distance", N_("Distance"), 64, 2, false, true},
        {"bearing", N_("Bearing"), 54, 2, false, true},
    };
    switch (kind) {
        case kListSelected: return kSelected;
        case kListContacts: return kContacts;
        case kListParks: return kParks;
        case kListRecent: return kRecent;
        case kListIssues: return kIssues;
        case kListDxcc: return kDxcc;
        default: return kSpots;
    }
}

const ListColumn *listColumn(int kind, const std::string &id) {
    for (const ListColumn &c : listColumns(kind))
        if (id == c.id) return &c;
    return nullptr;
}

std::string listKey(const char *what, int kind) { return std::string(what) + std::to_string(kind); }

// The columns shown, in order, with their widths: as last left (mapListColumns<kind>:
// "call:76,date:76"), else the kind's own.
std::vector<std::pair<std::string, CGFloat>> shownColumns(int kind) {
    std::vector<std::pair<std::string, CGFloat>> out;
    for (const std::string &item : splitSetting(listKey("mapListColumns", kind).c_str(), ',')) {
        std::string id = item.substr(0, item.find(':'));
        const ListColumn *c = listColumn(kind, id);
        if (!c) continue;
        CGFloat width = item.find(':') == std::string::npos ? c->width : std::atof(item.c_str() + item.find(':') + 1);
        out.emplace_back(id, std::clamp(width, (CGFloat)24, (CGFloat)600));
    }
    if (out.empty())
        for (const ListColumn &c : listColumns(kind))
            if (c.on) out.emplace_back(c.id, c.width);
    return out;
}

// The sort chosen (mapListSort<kind>: "distance", "-date"), else the kind's: log order for the
// QSOs chosen, nearest first for the rest.
std::pair<std::string, bool> listSort(int kind) {
    std::string v = setting(listKey("mapListSort", kind).c_str());
    bool ascending = v.empty() || v[0] != '-';
    std::string id = ascending ? v : v.substr(1);
    if (!listColumn(kind, id)) {  // the QSOs chosen in the log's order, the newest first, the best spots first, else the nearest
        id = kind == kListSelected || kind == kListIssues ? "record" : kind == kListRecent ? "date" : kind == kListSpots ? "need" : kind == kListDxcc ? "entity" : "distance";
        ascending = kind != kListRecent;
    }
    return {id, ascending};
}

// The list's Sort menu: the orders that matter for each kind (a column clicked can sort by any).
struct SortChoice {
    const char *title, *id;
    bool ascending;
};
const std::vector<SortChoice> &sortChoices(int kind) {
    static const std::vector<SortChoice> kSpots = {{N_("Best opportunity"), "need", true}, {N_("Newest"), "age", true},
                                                   {N_("Nearest"), "distance", true},      {N_("Strongest signal"), "snr", false},
                                                   {N_("Band"), "band", true},             {N_("Call"), "call", true}};
    static const std::vector<SortChoice> kQsos = {{N_("Newest"), "date", false}, {N_("Oldest"), "date", true},   {N_("Call"), "call", true},
                                                  {N_("Band"), "band", true},    {N_("Nearest"), "distance", true}, {N_("Log order"), "record", true}};
    static const std::vector<SortChoice> kParks = {{N_("Nearest"), "distance", true}, {N_("Reference"), "ref", true}, {N_("Name"), "name", true}};
    static const std::vector<SortChoice> kIssues = {{N_("Log order"), "record", true}, {N_("Errors first"), "severity", true}, {N_("Field"), "field", true},
                                                    {N_("Call"), "call", true}};
    static const std::vector<SortChoice> kDxcc = {{N_("Name"), "entity", true},           {N_("Most bands"), "bands", false},
                                                  {N_("Most confirmed"), "confirmedBands", false}, {N_("Fewest confirmed"), "confirmedBands", true},
                                                  {N_("Most QSOs"), "qsos", false},       {N_("Nearest"), "distance", true}};
    return kind == kListSpots ? kSpots : kind == kListParks ? kParks : kind == kListIssues ? kIssues : kind == kListDxcc ? kDxcc : kQsos;
}

// The Sort menu for the list shown, its sort chosen ("By a column" when a column's title chose another).
void fillSortMenu(int kind) {
    NSPopUpButton *p = mw.listSortMenu;
    if (!p) return;
    std::pair<std::string, bool> now = listSort(kind);
    [p removeAllItems];
    NSInteger chosen = -1;
    for (const SortChoice &c : sortChoices(kind)) {
        [p addItemWithTitle:TF(@"Sort: {how}", @{@"how" : ADIFString(tr(c.title))})];
        if (c.id == now.first && c.ascending == now.second) chosen = p.numberOfItems - 1;
    }
    if (chosen < 0) {
        [p addItemWithTitle:T(@"Sort: by a column")];
        chosen = p.numberOfItems - 1;
    }
    [p selectItemAtIndex:chosen];
}

// The table's columns for a kind: the colour mark, then those shown.
void setListColumns(int kind, bool force = false) {
    if (mw.listColumnsFor == kind && !force) return;
    mw.listColumnsFor = kind;
    mw.listRows.building = YES;
    while (mw.listTable.tableColumns.count) [mw.listTable removeTableColumn:mw.listTable.tableColumns.lastObject];
    NSTableColumn *mark = [[NSTableColumn alloc] initWithIdentifier:@"mark"];
    mark.title = @"";
    mark.width = mark.minWidth = 14;
    mark.resizingMask = NSTableColumnNoResizing;
    [mw.listTable addTableColumn:mark];
    std::map<std::string, int> styles;
    for (const auto &shown : shownColumns(kind)) {
        const std::string &id = shown.first;
        CGFloat width = shown.second;
        const ListColumn *c = listColumn(kind, id);
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ADIFString(id)];
        col.title = *c->title ? @(tr(c->title).c_str()) : @"";
        col.width = width;
        col.minWidth = 24;
        col.resizingMask = NSTableColumnUserResizingMask;
        col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:ADIFString(id) ascending:c->style != 2 || id == "distance"];
        if (c->style == 2) col.headerCell.alignment = NSTextAlignmentRight;
        [mw.listTable addTableColumn:col];
        styles[id] = c->style;
    }
    mw.listRows.styles = styles;
    auto [sortId, ascending] = listSort(kind);
    mw.listTable.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:ADIFString(sortId) ascending:ascending] ];
    mw.listRows.building = NO;
}

// The columns as the user left them (order and widths), kept for the kind.
void saveListColumns() {
    std::vector<std::string> items;
    for (NSTableColumn *col in mw.listTable.tableColumns)
        if (![col.identifier isEqualToString:@"mark"]) items.push_back(ADIFStd(col.identifier) + ":" + std::to_string((int)std::lround(col.width)));
    saveSetting(listKey("mapListColumns", mw.listColumnsFor).c_str(), items, ',');
}

// The columns menu (the header's, and the Columns button's): a column each, ticked when shown;
// choosing one shows or hides it; Reset Columns goes back to the kind's own.
void fillColumnsMenu(NSMenu *menu, bool pullDown) {
    [menu removeAllItems];
    if (pullDown) [menu addItemWithTitle:T(@"Columns") action:nil keyEquivalent:@""];  // the pull-down's own title
    int kind = mw.listColumnsFor < 0 ? 0 : mw.listColumnsFor;
    std::set<std::string> shown;
    for (const auto &c : shownColumns(kind)) shown.insert(c.first);
    for (const ListColumn &c : listColumns(kind)) {
        NSMenuItem *item = [menu addItemWithTitle:@(tr(c.title).c_str()) action:nil keyEquivalent:@""];
        item.state = shown.count(c.id) ? NSControlStateValueOn : NSControlStateValueOff;
        std::string id = c.id;
        ADIFBlockMenuItem(item, ^{
            std::vector<std::pair<std::string, CGFloat>> cols = shownColumns(kind);
            auto it = std::find_if(cols.begin(), cols.end(), [&](const auto &p) { return p.first == id; });
            if (it != cols.end()) {
                if (cols.size() > 1) cols.erase(it);  // the last one stays
            } else {
                cols.emplace_back(id, listColumn(kind, id)->width);
            }
            std::vector<std::string> items;
            for (const auto &[cid, w] : cols) items.push_back(cid + ":" + std::to_string((int)std::lround(w)));
            saveSetting(listKey("mapListColumns", kind).c_str(), items, ',');
            setListColumns(kind, true);
            fillViewList();
        });
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *reset = [menu addItemWithTitle:T(@"Reset Columns") action:nil keyEquivalent:@""];
    ADIFBlockMenuItem(reset, ^{
        setSetting(listKey("mapListColumns", kind).c_str(), "");
        setSetting(listKey("mapListSort", kind).c_str(), "");
        setListColumns(kind, true);
        fillViewList();
    });
}

// Where the list measures from: your station (home), the map's centre, or a grid square typed.
// False when there's no such place (no home, a grid that isn't one): then the map's centre.
bool listFromPlace(double *lat, double *lon, std::string *from) {
    NSInteger choice = mw.listFrom.indexOfSelectedItem;
    if (choice == 0 && !mw.home.empty() && adif::gridToLatLon(mw.home, lat, lon)) return *from = mw.home, true;
    std::string grid = ADIFStd([mw.listGrid.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
    if (choice == 2 && adif::gridToLatLon(grid, lat, lon)) return *from = grid, true;
    NSRect b = mw.view.bounds;
    double clon = 0, clat = 0;
    if (![mw.view lonLatAt:NSMakePoint(NSMidX(b), NSMidY(b)) lon:&clon lat:&clat]) clon = clat = 0;
    *lat = clat, *lon = clon, *from = adif::squareAt(clon, clat);
    return choice == 1;
}

bool inView(double lat, double lon) { return NSPointInRect([mw.view viewPointForLon:lon lat:lat], mw.view.bounds); }

// A QSO's place: LAT/LON, else its GRIDSQUARE.
bool qsoPlace(const adif::MapQso &q, double *lat, double *lon) {
    if (q.located) return *lat = q.lat, *lon = q.lon, true;
    return adif::gridToLatLon(q.grid, lat, lon);
}

// The rows for QSOs: the ones chosen (Selected: none of them chosen on the map by a row), or
// those whose place is in view (Contacts: a row chooses its marker, with Contacts, else its
// square). Each with its distance and bearing when it has a place.
std::vector<ADIFViewRow> qsoRows(int kind, double lat, double lon) {
    std::map<size_t, size_t> contactOf;  // QSO -> its marker in the view's contacts
    const std::vector<ADIFMapContact> &contacts = mw.view.contacts;
    for (size_t j = 0; j < contacts.size(); ++j)
        for (size_t qi : contacts[j].qsos) contactOf[qi] = j;
    std::map<std::string, size_t> squareOf;
    for (size_t s = 0; s < mw.data.squares.size(); ++s) squareOf[mw.data.squares[s].grid] = s;
    std::vector<size_t> qsos;
    if (kind == kListSelected) qsos = mw.listed;
    else if (kind == kListRecent)
        for (size_t i = 0; i < mw.data.qsos.size(); ++i) qsos.push_back(i);
    else
        for (size_t i = 0; i < mw.data.qsos.size(); ++i) {
            double a, o;
            if (qsoPlace(mw.data.qsos[i], &a, &o) && inView(a, o)) qsos.push_back(i);
        }
    std::vector<ADIFViewRow> rows;
    for (size_t i : qsos) {
        if (i >= mw.data.qsos.size()) continue;
        const adif::MapQso &q = mw.data.qsos[i];
        ADIFViewRow r;
        r.item = i;
        if (qsoPlace(q, &r.lat, &r.lon))
            r.km = adif::greatCircleKm(lat, lon, r.lat, r.lon), r.bearing = adif::initialBearing(lat, lon, r.lat, r.lon);
        std::string grid4 = q.grid.substr(0, std::min<size_t>(4, q.grid.size()));
        for (char &c : grid4) c = (char)toupper((unsigned char)c);
        if (kind == kListContacts || kind == kListRecent) {  // the row chooses its contact, else its square
            if (auto c = contactOf.find(i); q.located && c != contactOf.end() && mw.view.showContacts) {
                r.hit.kind = ADIFMapHit::Contact, r.hit.index = c->second, r.hit.square = adif::squareAt(r.lon, r.lat);
                r.span = 0.02;
            } else if (auto sq = squareOf.find(grid4); sq != squareOf.end()) {
                r.hit.kind = ADIFMapHit::Square, r.hit.index = sq->second, r.hit.square = grid4;
                r.span = q.grid.size() >= 6 ? 0.05 : 0.6;
            } else if (kind == kListContacts) {
                continue;
            }
        }
        r.color = [mw.view colorFor:[mw.view aggregate:std::vector<size_t>(1, i)] entity:NO];
        rows.push_back(r);
    }
    return rows;
}

// The rows for parks: those the map marks in the view.
std::vector<ADIFViewRow> parkRows(double lat, double lon) {
    const adif::PotaParks &list = ADIFPotaParks();
    std::map<size_t, ADIFParkSpot> byPark;
    std::vector<size_t> candidates;
    for (const ADIFParkSpot &sp : [mw.view parksInView])
        if (byPark.emplace(sp.park, sp).second) candidates.push_back(sp.park);
    std::vector<ADIFViewRow> rows;
    for (const adif::ParkDistance &d : adif::nearestParks(list.parks(), candidates, lat, lon, candidates.size())) {
        const adif::PotaPark &p = list.parks()[d.park];
        ADIFViewRow r;
        r.item = d.park;
        r.hit.kind = ADIFMapHit::Pota, r.hit.index = d.park, r.hit.square = adif::squareAt(p.lon, p.lat);
        r.lat = p.lat, r.lon = p.lon, r.km = d.km, r.bearing = d.bearing;
        r.color = [mw.view parkColor:byPark[d.park]];
        rows.push_back(r);
    }
    return rows;
}

// The rows for spots: the stations spotted in view (the Spots layer's).
std::vector<ADIFViewRow> spotRows(double lat, double lon) {
    const std::vector<ADIFMapSpot> &spots = mw.view.spots;
    std::vector<ADIFViewRow> rows;
    for (size_t k = 0; k < spots.size(); ++k) {
        const ADIFMapSpot &ms = spots[k];
        if (!inView(ms.lat, ms.lon)) continue;
        ADIFViewRow r;
        r.item = k;
        r.hit.kind = ADIFMapHit::Spot, r.hit.index = k, r.hit.square = adif::squareAt(ms.lon, ms.lat);
        r.lat = ms.lat, r.lon = ms.lon, r.span = ms.exact ? 0.1 : 1;
        r.km = adif::greatCircleKm(lat, lon, ms.lat, ms.lon), r.bearing = adif::initialBearing(lat, lon, ms.lat, ms.lon);
        r.color = [mw.view spotColor:ms];
        r.tree = potaSpot(ms.spot);
        rows.push_back(r);
    }
    return rows;
}

// The rows for Check Log's problems: one a problem, at its QSO's contact or square.
std::vector<ADIFViewRow> issueRows(double lat, double lon) {
    std::map<size_t, ADIFViewRow> byQso;
    for (const ADIFViewRow &r : qsoRows(kListRecent, lat, lon)) byQso[r.item] = r;
    std::vector<ADIFViewRow> rows;
    for (size_t i = 0; i < mw.issues.size(); ++i) {
        auto at = byQso.find(mw.issues[i].qso);
        ADIFViewRow r = at != byQso.end() ? at->second : ADIFViewRow();
        r.item = i;
        r.color = mw.issues[i].error ? NSColor.systemRedColor : NSColor.systemOrangeColor;
        rows.push_back(r);
    }
    return rows;
}

// The rows for DXCC Progress: each entity worked (as the filters keep the QSOs).
std::vector<ADIFViewRow> dxccRows(double lat, double lon) {
    std::vector<ADIFViewRow> rows;
    for (size_t i = 0; i < mw.dxcc.size(); ++i) {
        const ADIFMapEntity &e = mw.dxcc[i];
        ADIFViewRow r;
        r.item = i;
        r.hit.kind = ADIFMapHit::Dxcc, r.hit.index = i, r.hit.square = adif::squareAt(e.lon, e.lat);
        r.lat = e.lat, r.lon = e.lon, r.span = 8;
        r.km = adif::greatCircleKm(lat, lon, e.lat, e.lon), r.bearing = adif::initialBearing(lat, lon, e.lat, e.lon);
        r.color = [mw.view colorFor:[mw.view aggregate:e.qsos] entity:YES];
        rows.push_back(r);
    }
    return rows;
}

// A DXCC entity's state on a band ("20m") or in a mode group (0 CW, 1 phone, 2 data): 2
// confirmed, 1 worked, 0 not.
int entitySlot(int dxcc, const std::string &band, int mode) {
    const adif::WorkedIndex &w = mw.view.worked;
    auto it = w.entities.find(dxcc);
    if (it == w.entities.end()) return 0;
    const adif::WorkedIndex::Entity &e = it->second;
    if (!band.empty()) return e.confirmedBands.count(band) ? 2 : e.bands.count(band) ? 1 : 0;
    return e.confirmedModes.count(mode) ? 2 : e.modes.count(mode) ? 1 : 0;
}

// A DXCC entity's continent, from the country data.
std::string entityContinent(int dxcc) {
    static std::map<int, std::string> conts;
    static size_t contsFor = 0;
    const adif::CountryTable &countries = ADIFCountries();
    if (contsFor != countries.entities()) {
        conts.clear();
        for (const adif::CountryInfo &c : countries.all()) conts.emplace(c.dxcc, c.continent);
        contsFor = countries.entities();
    }
    auto it = conts.find(dxcc);
    return it == conts.end() ? "" : it->second;
}

// A DXCC entity's name, from the country data.
// The DXCC entity of a list row, for its flag: an entity's, a spot's, a QSO's; 0 for the others.
int cellDxcc(int kind, const ADIFViewRow &r) {
    if (kind == kListDxcc) return r.item < mw.dxcc.size() ? mw.dxcc[r.item].dxcc : 0;
    if (kind == kListSpots) return r.item < mw.view.spots.size() && !mw.view.spots[r.item].spot.heardMe ? mw.view.spots[r.item].status.dxcc : 0;
    size_t qso = r.item;
    if (kind == kListIssues) {
        if (r.item >= mw.issues.size()) return 0;
        qso = mw.issues[r.item].qso;
    } else if (!qsoList(kind)) return 0;
    return qso < mw.data.qsos.size() ? entityOf(mw.data.qsos[qso].dxcc, mw.data.qsos[qso].call) : 0;
}

std::string entityName(int dxcc, const std::string &call) {
    static std::map<int, std::string> names;
    static size_t namesFor = 0;
    const adif::CountryTable &countries = ADIFCountries();
    if (namesFor != countries.entities()) {
        names.clear();
        for (const adif::CountryInfo &c : countries.all()) names.emplace(c.dxcc, c.name);
        namesFor = countries.entities();
    }
    if (auto it = names.find(dxcc); dxcc > 0 && it != names.end()) return it->second;
    adif::CountryInfo info;
    return !countries.empty() && countries.lookup(call, &info) ? info.name : "";
}

// A row's text in a column.
int cellDxcc(int kind, const ADIFViewRow &r);

std::string cellText(int kind, const ADIFViewRow &r, const std::string &id) {
    if (id == "distance") return r.km < 0 ? "" : adif::distanceText(r.km, mw.listUnits.selectedSegment == 0);
    if (id == "bearing") {
        if (r.km < 0) return "";
        char deg[16];
        snprintf(deg, sizeof deg, "%.0f°", std::fmod(std::round(r.bearing) + 360, 360));
        return deg;
    }
    if (kind == kListIssues) {
        if (r.item >= mw.issues.size()) return "";
        const ADIFIssue &is = mw.issues[r.item];
        if (id == "severity") return is.error ? tr("Error") : tr("Warning");
        if (id == "field") return is.field;
        if (id == "problem") return is.message;
        ADIFViewRow q = r;
        q.item = is.qso;
        return cellText(kListRecent, q, id);
    }
    if (kind == kListDxcc) {
        if (r.item >= mw.dxcc.size()) return "";
        const ADIFMapEntity &e = mw.dxcc[r.item];
        auto mark = [](int slot) { return slot == 2 ? std::string("\u25CF") : slot == 1 ? std::string("\u25CB") : std::string(); };
        if (id == "entity") return e.name.empty() ? std::to_string(e.dxcc) : e.name;
        if (id == "dxcc") return std::to_string(e.dxcc);
        if (id == "cont") return entityContinent(e.dxcc);
        if (id == "qsos") return grouped(e.qsos.size());
        if (id.size() > 1 && id[0] == 'b' && id.back() == 'm') return mark(entitySlot(e.dxcc, id.substr(1), 0));
        if (id == "cw" || id == "phone" || id == "data") return mark(entitySlot(e.dxcc, "", id == "cw" ? 0 : id == "phone" ? 1 : 2));
        auto it = mw.view.worked.entities.find(e.dxcc);
        if (id == "bands") return it == mw.view.worked.entities.end() ? "" : std::to_string(it->second.bands.size());
        if (id == "confirmedBands") return it == mw.view.worked.entities.end() ? "" : std::to_string(it->second.confirmedBands.size());
        return "";
    }
    if (qsoList(kind)) {
        if (r.item >= mw.data.qsos.size()) return "";
        const adif::MapQso &q = mw.data.qsos[r.item];
        if (id == "record") return std::to_string(q.record);
        if (id == "call") return q.call;
        if (id == "date") return q.date;
        if (id == "time") return q.time;
        if (id == "band") return q.band;
        if (id == "mode") return q.mode;
        if (id == "grid") return q.grid;
        if (id == "confirmed") return q.confirmed ? tr("yes") : "";
        if (id == "country") return entityName(q.dxcc, q.call);
        if (id == "state") return q.areas.state;
        if (id == "county") return q.areas.county;
        if (id == "cq") return q.areas.cq ? std::to_string(q.areas.cq) : "";
        if (id == "itu") return q.areas.itu ? std::to_string(q.areas.itu) : "";
        if (id == "park") {
            std::string out;
            for (const std::string &p : q.potaHunted) out += (out.empty() ? "" : ", ") + p;
            return out;
        }
        return "";
    }
    if (kind == kListParks) {
        const adif::PotaParks &list = ADIFPotaParks();
        if (r.item >= list.size()) return "";
        const adif::PotaPark &p = list.parks()[r.item];
        if (id == "ref") return p.ref;
        if (id == "name") return p.name;
        if (id == "location") return p.location;
        if (id == "grid") return adif::squareAt(p.lon, p.lat);
        if (id == "worked") {
            ADIFParkWork w = [mw.view parkWork:p.ref];
            std::string out;
            if (!w.hunted.empty()) out = trp("hunted, {n} QSO", "hunted, {n} QSOs", (long long)w.hunted.size());
            if (!w.activated.empty()) out += (out.empty() ? "" : "; ") + trp("activated, {n} QSO", "activated, {n} QSOs", (long long)w.activated.size());
            return out;
        }
        if (id == "outline") {
            const adif::ParkOutline *o = parkoutlines::find(p.ref);
            return o ? o->source + (o->matched ? "*" : "") : "";
        }
        return "";
    }
    const std::vector<ADIFMapSpot> &spots = mw.view.spots;
    if (r.item >= spots.size()) return "";
    const ADIFMapSpot &ms = spots[r.item];
    const adif::Spot &sp = ms.spot;
    if (id == "call") return sp.activator;
    if (id == "khz") {
        char khz[24] = "";  // to 100 Hz: PSKReporter gives Hz
        if (double f = std::atof(sp.khz.c_str()); f > 0) snprintf(khz, sizeof khz, std::fmod(f, 1) == 0 ? "%.0f" : "%.1f", f);
        return khz;
    }
    if (id == "band") return sp.band;
    if (id == "mode") return sp.mode;
    if (id == "watch") return ms.watched.empty() ? "" : "\u2605";
    if (id == "need") {  // your watch list, what it means for the log, its program, whether stations near you hear it
        if (sp.heardMe) return "";
        std::string out = ms.watched.empty() ? "" : tr("Watched");
        auto plus = [&](const std::string &more) { out += (out.empty() ? "" : " + ") + more; };
        switch (ms.status.need) {
            case adif::SpotNeed::NewDxcc: plus(tr("New DXCC")); break;
            case adif::SpotNeed::NewBand: plus(trf("New on {band}", {{"band", sp.band}})); break;
            case adif::SpotNeed::NewMode: plus(tr("New mode")); break;
            case adif::SpotNeed::Worked: plus(tr("Worked, not confirmed")); break;
            case adif::SpotNeed::Confirmed: plus(tr("Confirmed")); break;
            default: break;
        }
        if (ms.status.newPark) plus(trf("new {program} park", {{"program", sp.program}}));
        else if (!sp.program.empty()) plus(sp.program);
        double hlat, hlon;
        if (!mw.home.empty() && adif::gridToLatLon(mw.home, &hlat, &hlon))
            for (const ADIFSpotHeard &by : ms.heard)
                if (adif::greatCircleKm(hlat, hlon, by.lat, by.lon) <= 1500) {
                    plus(tr("heard near you"));
                    break;
                }
        return out;
    }
    if (id == "age") return adif::spotAge(sp.epoch, (long long)time(nullptr));
    if (id == "time") return sp.time;
    if (id == "program") return sp.program;
    if (id == "ref") return sp.reference;
    if (id == "park") return sp.park;
    if (id == "spotter") return sp.spotter;
    if (id == "source") return tr(adif::spotSourceName(sp.source));
    if (id == "snr") return adif::spotSnr(sp);
    if (id == "grid") return sp.grid;
    if (id == "country") return ms.status.entity;
    if (id == "comment") return sp.comments;
    return "";
}

// A row's value in a column, for sorting: a number for the numeric columns (age as seconds
// since; a QSO's date with its time), else its text.
double cellNumber(int kind, const ADIFViewRow &r, const std::string &id) {
    if (id == "distance") return r.km < 0 ? 1e12 : r.km;
    if (id == "bearing") return r.km < 0 ? 1e12 : std::fmod(r.bearing + 360, 360);
    if (kind == kListIssues && id == "record" && r.item < mw.issues.size() && mw.issues[r.item].qso < mw.data.qsos.size())
        return mw.data.qsos[mw.issues[r.item].qso].record;
    if (kind == kListDxcc && r.item < mw.dxcc.size()) {
        const ADIFMapEntity &e = mw.dxcc[r.item];
        if (id == "dxcc") return e.dxcc;
        if (id == "qsos") return e.qsos.size();
        if (id.size() > 1 && id[0] == 'b' && id.back() == 'm') return entitySlot(e.dxcc, id.substr(1), 0);
        if (id == "cw" || id == "phone" || id == "data") return entitySlot(e.dxcc, "", id == "cw" ? 0 : id == "phone" ? 1 : 2);
        auto it = mw.view.worked.entities.find(e.dxcc);
        if (it == mw.view.worked.entities.end()) return 0;
        if (id == "bands") return it->second.bands.size();
        if (id == "confirmedBands") return it->second.confirmedBands.size();
        return 0;
    }
    if (kind == kListSpots && r.item < mw.view.spots.size()) {
        const adif::Spot &sp = mw.view.spots[r.item].spot;
        if (id == "khz") return std::atof(sp.khz.c_str());
        if (id == "age") return sp.epoch > 0 ? (double)((long long)time(nullptr) - sp.epoch) : 1e12;
        if (id == "snr") return sp.hasSnr ? sp.snr : -1e12;
    }
    if (id == "need" && kind == kListSpots && r.item < mw.view.spots.size()) {  // the most wanted first, those you watch before them
        const ADIFMapSpot &ms = mw.view.spots[r.item];
        return opportunity(ms);
    }
    if (id == "watch" && kind == kListSpots && r.item < mw.view.spots.size()) return mw.view.spots[r.item].watched.empty();
    if (qsoList(kind) && r.item < mw.data.qsos.size()) {
        const adif::MapQso &q = mw.data.qsos[r.item];
        if (id == "record") return q.record;
        if (id == "cq") return q.areas.cq;
        if (id == "itu") return q.areas.itu;
    }
    return 0;
}

std::string sortText(int kind, const ADIFViewRow &r, const std::string &id) {
    if (kind == kListIssues && id == "date" && r.item < mw.issues.size() && mw.issues[r.item].qso < mw.data.qsos.size())
        return mw.data.qsos[mw.issues[r.item].qso].date8 + mw.data.qsos[mw.issues[r.item].qso].time;
    if (qsoList(kind) && id == "date" && r.item < mw.data.qsos.size())
        return mw.data.qsos[r.item].date8 + mw.data.qsos[r.item].time;
    std::string t = cellText(kind, r, id);
    for (char &c : t) c = (char)tolower((unsigned char)c);
    return t;
}

void showListRow(const ADIFMapHit &h);

// The list's bars in the room the list has: narrow, the page size goes first, then Columns (a
// column title's right-click has them), "Nearest to:", the distance; above, Sort (a column's title
// sorts too). The tabs shorten rather than squeeze the map.
void fitListBars() {
    if (!mw.listPanel || !mw.listFooter) return;
    CGFloat room = NSWidth(mw.listPanel.bounds) - 20;
    auto need = [](NSStackView *bar, NSView *skip) {
        CGFloat w = 0;
        NSInteger n = 0;
        for (NSView *v in bar.views)
            if (!v.hidden && v != skip) w += v.fittingSize.width, ++n;
        return w + bar.spacing * std::max<NSInteger>(0, n - 1) + 20;  // and the wider gaps
    };
    NSArray<NSView *> *optional = @[ mw.listPageSize, mw.listColumnsMenu, mw.nearestTo, mw.listWithin ];
    for (NSView *v in optional) v.hidden = NO;
    for (NSView *v in optional)
        if (need(mw.listFooter, mw.listHint) > room && !(v == mw.listWithin && mw.listWithin.selectedTag > 0)) v.hidden = YES;  // a distance chosen stays
    mw.listSortMenu.hidden = NO;
    mw.listSortMenu.hidden = need(mw.listTop, nil) - mw.listSearch.fittingSize.width + 120 > room;  // the search field at its least
}

// The list again, for the kind chosen: its rows, sorted, the page shown, the title, the pager.
void fillViewList() {
    mw.listQueued = false;
    if (!mw.listPanel || mw.listPanel.hidden) return;
    int kind = (int)std::clamp<NSInteger>(mw.listKind.selectedSegment, 0, kListKinds - 1);
    setListColumns(kind);
    std::string home = mw.home.empty() ? tr("no grid set") : mw.home;
    [mw.listFrom itemAtIndex:0].title = TF(@"Your station ({grid})", @{@"grid" : ADIFString(home)});
    [mw.listFrom itemAtIndex:0].enabled = !mw.home.empty();
    mw.listGrid.hidden = mw.listFrom.indexOfSelectedItem != 2;
    double lat = 0, lon = 0;
    std::string from;
    bool chosenPlace = listFromPlace(&lat, &lon, &from);
    std::vector<ADIFViewRow> rows = kind == kListParks    ? parkRows(lat, lon)
                                    : kind == kListSpots  ? spotRows(lat, lon)
                                    : kind == kListIssues ? issueRows(lat, lon)
                                    : kind == kListDxcc   ? dxccRows(lat, lon)
                                                          : qsoRows(kind, lat, lon);
    // Narrowed by the search (a call, reference, name... in any column shown, or the list's own
    // key columns) and the distance limit (in the units chosen).
    bool miles = mw.listUnits.selectedSegment == 0;
    for (NSMenuItem *item in mw.listWithin.itemArray)
        if (item.tag > 0) item.title = TF(miles ? @"Within {n} mi" : @"Within {n} km", @{@"n" : @(item.tag)});
    double limitKm = mw.listWithin.selectedTag * (miles ? 1.609344 : 1.0);
    std::string query = ADIFStd([[mw.listSearch.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString]);
    size_t found = rows.size();
    if (limitKm > 0 || !query.empty()) {
        std::set<std::string> searched = {"call", "ref", "name", "park", "country", "grid"};
        for (const auto &c : shownColumns(kind)) searched.insert(c.first);
        std::vector<ADIFViewRow> kept;
        for (const ADIFViewRow &r : rows) {
            if (limitKm > 0 && (r.km < 0 || r.km > limitKm)) continue;
            bool match = query.empty();
            for (const std::string &id : searched) {
                if (match) break;
                if (!listColumn(kind, id)) continue;
                std::string t = cellText(kind, r, id);
                for (char &c : t) c = (char)tolower((unsigned char)c);
                match = t.find(query) != std::string::npos;
            }
            if (match) kept.push_back(r);
        }
        rows.swap(kept);
    }
    // Sorted by the column chosen (its values worked out once), ties in the order they came.
    std::pair<std::string, bool> sort = listSort(kind);
    const std::string sortId = sort.first;
    const bool ascending = sort.second;
    const ListColumn *sortCol = listColumn(kind, sortId);
    std::vector<size_t> order(rows.size());
    for (size_t i = 0; i < order.size(); ++i) order[i] = i;
    if (sortCol && sortCol->number) {
        std::vector<double> keys(rows.size());
        for (size_t i = 0; i < rows.size(); ++i) keys[i] = cellNumber(kind, rows[i], sortId);
        std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return ascending ? keys[a] < keys[b] : keys[a] > keys[b]; });
    } else if (sortCol) {
        std::vector<std::string> keys(rows.size());
        for (size_t i = 0; i < rows.size(); ++i) keys[i] = sortText(kind, rows[i], sortId);
        std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
            if (keys[a].empty() != keys[b].empty()) return keys[b].empty();  // the empty ones last, either way
            return ascending ? ADIFNaturalCompare(keys[a], keys[b]) < 0 : ADIFNaturalCompare(keys[a], keys[b]) > 0;
        });
    }
    // The page.
    size_t pageSize = (size_t)std::max<NSInteger>(10, mw.listPageSize.selectedTag);
    size_t pages = std::max<size_t>(1, (rows.size() + pageSize - 1) / pageSize);
    size_t page = std::min(mw.listPage[kind], pages - 1);
    mw.listPage[kind] = page;
    std::vector<ADIFViewRow> shown;
    for (size_t i = page * pageSize; i < rows.size() && i < (page + 1) * pageSize; ++i) shown.push_back(rows[order[i]]);
    mw.listRows.rows = shown;
    fillSortMenu(kind);
    mw.listRows.quiet = YES;
    [mw.listTable reloadData];
    showListRow(mw.view.selectedHit);
    mw.listRows.quiet = NO;
    mw.listPageLabel.stringValue = rows.empty() ? T(@"none")
                                                : TF(@"Showing {from}–{to} of {total}", @{@"from" : @(page * pageSize + 1), @"to" : @(page * pageSize + shown.size()),
                                                                                                @"total" : @(rows.size())});
    mw.listPrev.enabled = page > 0;
    mw.listNext.enabled = page + 1 < pages;
    NSDictionary *counts = @{@"n" : @(rows.size())};
    switch (kind) {
        case kListSelected: mw.listTitle.stringValue = TF(@"Selected ({n})", counts); break;
        case kListContacts: mw.listTitle.stringValue = TF(@"Contacts in View ({n})", counts); break;
        case kListParks: mw.listTitle.stringValue = TF(@"Parks in View ({n})", counts); break;
        case kListRecent: mw.listTitle.stringValue = TF(@"Recent QSOs ({n})", counts); break;
        case kListIssues: mw.listTitle.stringValue = TF(@"Log Issues ({n})", counts); break;
        case kListDxcc: mw.listTitle.stringValue = TF(@"DXCC Progress ({n})", counts); break;
        default: mw.listTitle.stringValue = TF(@"Spots in View ({n})", counts); break;
    }
    // Each tab says how many it has: the QSOs chosen, the contacts, parks and spots in view, the log.
    size_t tabCounts[kListKinds] = {mw.listed.size(), 0, 0, mw.view.spots.size(), mw.data.qsos.size(), mw.issues.size(), mw.dxcc.size()};
    tabCounts[kListContacts] = kind == kListContacts ? found : qsoRows(kListContacts, lat, lon).size();
    tabCounts[kListParks] = kind == kListParks ? found : parkRows(lat, lon).size();
    NSString *const tabTitles[kListKinds] = {N(@"Selected ({n})"), N(@"Contacts ({n})"), N(@"Parks ({n})"), N(@"Spots ({n})"),
                                             N(@"Recent ({n})"),   N(@"Issues ({n})"),   N(@"DXCC ({n})")};
    for (int k = 0; k < kListKinds; ++k) {
        NSString *label = TF(tabTitles[k], @{@"n" : @(tabCounts[k])});
        [mw.listKind setLabel:label forSegment:k];
        [mw.listKind setToolTip:label forSegment:k];  // whole, when the tabs are shortened
    }
    const ADIFMapStyle &st = mw.view.style;
    std::string hint;
    if (kind == kListRecent) hint = tr("The log's QSOs (as the filters keep them), the newest first. Click one to find it on the map; double-click to go "
                                       "to it in the log.");
    else if (kind == kListIssues)
        hint = rows.empty() ? tr("No errors or warnings from Check Log in the QSOs shown.")
                            : tr("Check Log's errors and warnings in the QSOs shown. Click one to find its QSO on the map; double-click to go to the "
                                 "problem in the log.");
    else if (kind == kListDxcc)
        hint = tr("The DXCC entities worked: \u25CF confirmed, \u25CB worked, on each band and in each mode (CW, phone, data). Click one to show it "
                  "on the map.");
    else if (kind == kListSelected)
        hint = rows.empty() ? tr("Click a square, contact, park or area on the map for its QSOs.")
                            : tr("The QSOs of what you clicked on the map. Double-click one to go to it in the log.");
    else if (kind == kListParks && !ADIFPotaParks().size()) hint = tr("Download POTA's park list first: Settings, POTA Parks.");
    else if (kind == kListParks && !st[kLayerPota].show && !st[kLayerPota].overlay)
        hint = tr("Tick the POTA layer's Show (the parks you worked) or Overlay (the others) to list its parks.");
    else if (kind == kListSpots && !st[kLayerSpots].show) hint = tr("Tick the Spots layer's Show to list the stations spotted.");
    else if (rows.empty())
        hint = kind == kListParks    ? (st[kLayerPota].overlay ? trf("No POTA parks in view (POTA parks in: {places}).", {{"places", parkPlacesName(parkPlaces())}})
                                                               : tr("No parks you worked in view; tick POTA's Overlay for the others."))
               : kind == kListContacts ? tr("No QSOs with a grid or a place in view.")
                                       : tr("No spots in view.");
    else if (!chosenPlace && mw.listFrom.indexOfSelectedItem != 1)
        hint = mw.listFrom.indexOfSelectedItem == 2 ? trf("Not a grid square; from the map's centre ({grid}).", {{"grid", from}})
                                                    : trf("No grid for your station (Settings, Your Station); from the map's centre ({grid}).", {{"grid", from}});
    else hint = trf("Distances from {grid}. Click a row to choose it on the map; double-click to zoom to it. Click a column's title to sort by it.",
                    {{"grid", from}});
    if (rows.size() < found)  // the search or the distance limit left some out: say how many
        hint = trp("{n} of {total} matches the search and distance.", "{n} of {total} match the search and distance.", (long long)rows.size(),
                   {{"total", std::to_string(found)}}) +
               " " + hint;
    mw.listHint.stringValue = ADIFString(hint);
    mw.listHint.toolTip = mw.listHint.stringValue;
    // A click on the map switched the list to Selected: back to what it listed.
    static NSString *const kTabNames[kListKinds] = {N(@"Selected"), N(@"Contacts"), N(@"Parks"), N(@"Spots"), N(@"Recent"), N(@"Issues"), N(@"DXCC")};
    bool back = kind == kListSelected && mw.listBackKind > 0 && mw.listBackKind < kListKinds;
    mw.listBack.hidden = !back;
    if (back) mw.listBack.title = TF(@"\u2190 Back to {list}", @{@"list" : T(kTabNames[mw.listBackKind])});
    fitListBars();
}

// The situation panel: the log as the map shows it; today's QSOs; the spots you most want now (a
// link each); the busiest bands; the sun at your station.
void showSituation() {
    if (!mw.situation) return;
    mw.situation.stringValue = ADIFString(mw.summary);  // the whole of it, as the rows' tooltip
    std::string today = utcNow("%Y%m%d");
    adif::LogGlance g = adif::logGlance(mw.data.qsos, mw.view.worked, today);
    // The log at a glance: a row a layer, how many you worked and confirmed; its name shows that
    // layer in History. Then today's QSOs, and those the map can't place.
    for (NSView *v in [mw.statHost.subviews copy]) [v removeFromSuperview];
    NSGridView *stats = [NSGridView gridViewWithNumberOfColumns:3 rows:0];  // afresh: a row with merged cells can't be removed
    stats.rowSpacing = 3;
    stats.columnSpacing = 14;
    stats.identifier = @"map.stats";
    auto number = [](const std::string &text, bool head) {
        NSTextField *f = [NSTextField labelWithString:ADIFString(text)];
        f.font = head ? [NSFont systemFontOfSize:NSFont.smallSystemFontSize - 1 weight:NSFontWeightMedium]
                      : [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize + 1 weight:NSFontWeightMedium];
        f.textColor = head ? NSColor.secondaryLabelColor : NSColor.labelColor;
        f.alignment = NSTextAlignmentRight;
        return f;
    };
    [stats addRowWithViews:@[ [NSGridCell emptyContentView], number(tr("Worked"), true), number(tr("Confirmed"), true) ]];
    auto statRow = [&](const std::string &label, NSView *worked, NSView *confirmed, NSInteger view) {
        NSButton *b = [NSButton buttonWithTitle:ADIFString(label) target:nil action:nil];
        b.bordered = NO;
        b.alignment = NSTextAlignmentLeft;
        b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
        b.contentTintColor = view >= 0 ? NSColor.linkColor : NSColor.secondaryLabelColor;
        b.identifier = [NSString stringWithFormat:@"map.stat.%ld", (long)stats.numberOfRows - 1];
        b.toolTip = view >= 0 ? T(@"Show this layer in History") : mw.situation.stringValue;
        if (view >= 0) ADIFOnAction(b, ^{
            if (live()) switchWorkflow(0);
            chooseQuickView(view);
        });
        else b.enabled = NO;
        [stats addRowWithViews:@[ b, worked ?: [NSGridCell emptyContentView], confirmed ?: [NSGridCell emptyContentView] ]];
    };
    size_t squaresConfirmed = 0, dxccConfirmed = 0;
    for (const adif::MapSquare &sq : mw.data.squares) squaresConfirmed += sq.confirmed;
    for (const ADIFMapEntity &e : mw.dxcc) dxccConfirmed += e.confirmed;
    std::pair<size_t, size_t> states = [mw.view workedCount:kLayerStates], parks = [mw.view workedCount:kLayerPota];
    statRow(tr("Grid squares"), number(grouped(mw.data.squares.size()), false), number(grouped(squaresConfirmed), false), historyViewOf(kLayerSquares));
    statRow(tr("DXCC entities"), number(grouped(mw.dxcc.size()), false), number(grouped(dxccConfirmed), false), historyViewOf(kLayerCountries));
    statRow(tr("US states"), number(grouped(states.first), false), number(grouped(states.second), false), historyViewOf(kLayerStates));
    statRow(tr("POTA parks"), number(grouped(parks.first), false), number(grouped(parks.second), false), historyViewOf(kLayerPota));
    auto spanning = [&](const std::string &text) {  // across both columns
        NSTextField *f = number(text, false);
        f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
        f.textColor = NSColor.secondaryLabelColor;
        return f;
    };
    statRow(tr("Today"), spanning(g.today ? plural(g.today, "QSO") : tr("no QSOs yet")), nil, -1);
    [stats mergeCellsInHorizontalRange:NSMakeRange(1, 2) verticalRange:NSMakeRange(stats.numberOfRows - 1, 1)];
    if (mw.data.withoutGrid) {
        statRow(tr("No grid"), spanning(plural(mw.data.withoutGrid, "QSO")), nil, -1);
        [stats mergeCellsInHorizontalRange:NSMakeRange(1, 2) verticalRange:NSMakeRange(stats.numberOfRows - 1, 1)];
    }
    for (NSInteger r = 0; r < stats.numberOfRows; ++r) [stats rowAtIndex:r].yPlacement = NSGridCellPlacementCenter;
    stats.translatesAutoresizingMaskIntoConstraints = NO;
    [mw.statHost addSubview:stats];
    [NSLayoutConstraint activateConstraints:@[
        [stats.topAnchor constraintEqualToAnchor:mw.statHost.topAnchor], [stats.bottomAnchor constraintEqualToAnchor:mw.statHost.bottomAnchor],
        [stats.leadingAnchor constraintEqualToAnchor:mw.statHost.leadingAnchor],
        [stats.trailingAnchor constraintLessThanOrEqualToAnchor:mw.statHost.trailingAnchor]
    ]];
    std::string line;
    if (!g.today) line = tr("Today (UTC): no QSOs yet.");
    else {
        std::string bands;
        for (const std::string &b : g.todayBands) bands += (bands.empty() ? "" : ", ") + b;
        std::string time = g.lastTime.size() >= 4 ? g.lastTime.substr(0, 2) + ":" + g.lastTime.substr(2, 2) : g.lastTime;
        line = trp("Today (UTC): {n} QSO (CW {cw}, phone {phone}, data {data}) on {bands}; the last at {time}, {call}.",
                   "Today (UTC): {n} QSOs (CW {cw}, phone {phone}, data {data}) on {bands}; the last at {time}, {call}.", (long long)g.today,
                   {{"cw", std::to_string(g.todayModes[0])}, {"phone", std::to_string(g.todayModes[1])}, {"data", std::to_string(g.todayModes[2])},
                    {"bands", bands}, {"time", time}, {"call", g.lastCall}});
    }
    if (g.states) line += " " + trp("{n} US state worked.", "{n} US states worked.", (long long)g.states);
    mw.today.stringValue = ADIFString(line);
    // The spots most wanted: a new DXCC first, then a new band, mode or park; the newest first.
    for (NSView *v in [mw.wanted.arrangedSubviews copy])
        if (v != mw.wantedLabel) [mw.wanted removeView:v];
    const std::vector<ADIFMapSpot> &spots = mw.view.spots;
    std::vector<size_t> wanted;
    for (size_t k = 0; k < spots.size(); ++k)
        if (!spots[k].spot.heardMe && adif::spotWanted(spots[k].status)) wanted.push_back(k);
    std::stable_sort(wanted.begin(), wanted.end(), [&](size_t a, size_t b) {
        int pa = opportunity(spots[a]), pb = opportunity(spots[b]);
        return pa != pb ? pa < pb : spots[a].spot.epoch > spots[b].spot.epoch;
    });
    if (!mw.view.style[kLayerSpots].show)
        mw.wantedLabel.stringValue = !live() ? T(@"Spots: Live shows who is on the air now, and which of them you need.")
                                                     : T(@"Spots: tick the Spots layer's Show for who is on the air, and which you need.");
    else if (wanted.empty())
        mw.wantedLabel.stringValue = TP(@"Wanted now: none of the {n} station spotted.", @"Wanted now: none of the {n} stations spotted.", (long long)spots.size());
    else mw.wantedLabel.stringValue = T(@"Wanted now:");
    for (size_t i = 0; i < wanted.size() && i < 6; ++i) {
        const ADIFMapSpot &ms = spots[wanted[i]];
        std::string need = ms.status.need == adif::SpotNeed::NewDxcc || ms.status.need == adif::SpotNeed::NewBand || ms.status.need == adif::SpotNeed::NewMode
                               ? adif::spotNeedText(ms.status.need)
                               : tr("new park");
        std::string activator = ms.spot.activator, band = ms.spot.band;
        NSButton *b = [NSButton buttonWithTitle:@"" target:nil action:nil];
        b.bordered = NO;
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc]
            initWithString:ADIFString(activator)
                attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName : NSColor.linkColor}];
        [t appendAttributedString:[[NSAttributedString alloc] initWithString:ADIFString(" " + band + " " + need)
                                                                  attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.smallSystemFontSize],
                                                                               NSForegroundColorAttributeName : [mw.view spotColor:ms]}]];
        b.attributedTitle = t;
        b.identifier = [NSString stringWithFormat:@"map.wanted.%zu", i];
        b.toolTip = ADIFString(spotNeedLine(ms.status, band));
        ADIFOnAction(b, ^{  // the spot (found again: the list may have changed), chosen on the map
            const std::vector<ADIFMapSpot> &now = mw.view.spots;
            for (size_t k = 0; k < now.size(); ++k)
                if (now[k].spot.activator == activator && now[k].spot.band == band) {
                    ADIFMapHit h;
                    h.kind = ADIFMapHit::Spot, h.index = k, h.square = adif::squareAt(now[k].lon, now[k].lat);
                    mw.choosingFromList = true;
                    [mw.view selectHit:h];
                    mw.choosingFromList = false;
                    return;
                }
        });
        [mw.wanted addArrangedSubview:b];
    }
    if (wanted.size() > 6) {
        NSTextField *more = [NSTextField labelWithString:TF(@"and {n} more", @{@"n" : @(wanted.size() - 6)})];
        more.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        more.textColor = NSColor.secondaryLabelColor;
        [mw.wanted addArrangedSubview:more];
    }
    // The busiest bands (stations spotted on each), and the sun where you are.
    std::string air;
    if (mw.view.style[kLayerSpots].show && !spots.empty() && !live()) {  // Live has Band conditions
        std::map<std::string, std::set<std::string>> byBand;
        for (const ADIFMapSpot &ms : spots)
            if (!ms.spot.band.empty()) byBand[ms.spot.band].insert(ms.spot.activator);
        std::vector<std::pair<std::string, size_t>> busy;
        for (const auto &kv : byBand) busy.emplace_back(kv.first, kv.second.size());
        std::stable_sort(busy.begin(), busy.end(), [](const auto &a, const auto &b) { return a.second > b.second; });
        std::string list;
        for (size_t i = 0; i < busy.size() && i < 6; ++i) list += (list.empty() ? "" : ", ") + busy[i].first + " " + std::to_string(busy[i].second);
        air = trf("On the air: {bands} (stations spotted).", {{"bands", list}});
    }
    double lat, lon;
    if (!mw.home.empty() && adif::gridToLatLon(mw.home, &lat, &lon)) {
        double now = (double)time(nullptr), at = 0;
        bool rising = false;
        double up = adif::solarElevation(adif::sunAt(now), lat, lon);
        std::string next;
        if (adif::nextSunCrossing(now, lat, lon, 0, &at, &rising)) {
            time_t t = (time_t)at;
            struct tm tm{};
            gmtime_r(&t, &tm);
            char hm[16];
            strftime(hm, sizeof hm, "%H:%M", &tm);
            next = rising ? trf("rises at {time} UTC", {{"time", hm}}) : trf("sets at {time} UTC", {{"time", hm}});
        }
        char deg[16];
        snprintf(deg, sizeof deg, "%.0f", std::fabs(up));
        std::string sun = up >= 0 ? trf("Sun at {grid}: up {deg}\u00B0", {{"grid", mw.home}, {"deg", deg}})
                                  : trf("Sun at {grid}: down {deg}\u00B0", {{"grid", mw.home}, {"deg", deg}});
        if (!next.empty()) sun += ", " + next;
        if (up > -6 && up < 0.8) sun += " " + tr("(the grey line is here)");
        air += (air.empty() ? "" : "  ") + sun + ".";
    }
    mw.air.stringValue = ADIFString(air);
    fillAwards();
}

void queueViewList() {
    if (mw.listQueued || !mw.listPanel || mw.listPanel.hidden) return;
    mw.listQueued = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 6)), dispatch_get_main_queue(), ^{ fillViewList(); });
}

void showListKind(int kind) {
    if (!mw.listKind) return;
    mw.listKind.selectedSegment = kind;
    setSetting("mapListKind", std::to_string(kind));
    fillViewList();
}

// The list's DXCC with an entity's row in sight and marked (what is chosen on the map stays).
void showDxccRow(int dxcc) {
    if (mw.listPanel.hidden) showPane(1, true);
    mw.markedDxcc = dxcc, mw.markedFor = mw.view.selectedHit;
    showListKind(kListDxcc);  // its row marked as the list is filled (showListRow)
}

// Band conditions open and in sight.
void revealBands() {
    if (!mw.bandSection || mw.bandSection.hidden) return;
    if (mw.bandBody.hidden) {
        mw.bandBody.hidden = NO;
        saveFlag("mapBandsClosed", false);
        for (NSView *v in mw.bandSection.subviews)
            for (NSView *b in v.subviews)
                if ([b.identifier isEqualToString:@"map.bands.toggle"]) ((NSButton *)b).state = NSControlStateValueOn;
    }
    [mw.selectedPanel layoutSubtreeIfNeeded];
    [mw.bandSection scrollRectToVisible:mw.bandSection.bounds];
}

// What was chosen on the map, chosen in the list too (its first row on the page; none else).
void showListRow(const ADIFMapHit &h) {
    if (!mw.listTable) return;
    BOOL was = mw.listRows.quiet;
    mw.listRows.quiet = YES;
    NSInteger at = -1;
    for (size_t i = 0; i < mw.listRows.rows.size() && at < 0; ++i)
        if (mw.listRows.rows[i].hit.kind == h.kind && mw.listRows.rows[i].hit.index == h.index && h.kind != ADIFMapHit::None) at = (NSInteger)i;
    if (at < 0 && mw.listKind.selectedSegment == kListDxcc && mw.markedDxcc)  // a reason's arrow marked this entity
        for (size_t i = 0; i < mw.listRows.rows.size() && at < 0; ++i)
            if (size_t item = mw.listRows.rows[i].item; item < mw.dxcc.size() && mw.dxcc[item].dxcc == mw.markedDxcc) at = (NSInteger)i;
    if (at >= 0) {
        [mw.listTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)at] byExtendingSelection:NO];
        [mw.listTable scrollRowToVisible:at];
    } else if (mw.listKind.selectedSegment != kListSelected) {
        [mw.listTable deselectAll:nil];
    }
    mw.listRows.quiet = was;
}

void useSelectedSpot();
void centerChosen();
void openRow(const ADIFViewRow &r);

// A row's own menu (right-click): for a spot New QSO, for a QSO View QSO; Center and Zoom to It.
void fillRowMenu(NSMenu *menu) {
    [menu removeAllItems];
    NSInteger row = mw.listTable.clickedRow >= 0 ? mw.listTable.clickedRow : mw.listTable.selectedRow;  // the row clicked, else the one chosen
    if (row < 0 || (size_t)row >= mw.listRows.rows.size()) return;
    ADIFViewRow r = mw.listRows.rows[(size_t)row];
    int kind = (int)mw.listKind.selectedSegment;
    auto add = [&](NSString *title, void (^action)(void)) {
        NSMenuItem *item = [menu addItemWithTitle:T(title) action:nil keyEquivalent:@""];
        ADIFBlockMenuItem(item, action);
    };
    auto choose = [](const ADIFViewRow &x) {
        mw.choosingFromList = true;
        [mw.view selectHit:x.hit];
        mw.choosingFromList = false;
    };
    if (kind == kListSpots && r.hit.kind == ADIFMapHit::Spot)
        add(@"New QSO", ^{
            choose(r);
            useSelectedSpot();
        });
    if (qsoList(kind) && r.item < mw.data.qsos.size()) add(@"View QSO", ^{ goToQso(r.item); });
    if (kind == kListIssues && r.item < mw.issues.size()) {
        add(@"Go to Problem", ^{ goToIssue(r.item); });
        size_t qso = mw.issues[r.item].qso;
        add(@"View QSO", ^{ goToQso(qso); });
    }
    if (r.hit.kind != ADIFMapHit::None) {
        add(@"Center", ^{
            choose(r);
            centerChosen();
        });
        add(@"Zoom to It", ^{ openRow(r); });
    }
    if (std::string token = watchTokenFor(r.hit); !token.empty()) {
        NSMenuItem *item = [menu addItemWithTitle:ADIFString(onWatchList(token) ? trf("Stop Watching {what}", {{"what", token}})
                                                                                 : trf("Watch {what}", {{"what", token}}))
                                           action:nil
                                    keyEquivalent:@""];
        ADIFBlockMenuItem(item, ^{ toggleWatch(token); });
    }
}

// Double-click: a QSO chosen goes to its record; anything else fills the map (a park's outline
// where downloaded, a square, else a little round it), chosen.
void openRow(const ADIFViewRow &r) {
    if (mw.listKind.selectedSegment == kListSelected || mw.listKind.selectedSegment == kListRecent) return goToQso(r.item);
    if (mw.listKind.selectedSegment == kListIssues) return goToIssue(r.item);
    double w, s, e, n;
    const adif::PotaParks &list = ADIFPotaParks();
    const adif::ParkOutline *o = r.hit.kind == ADIFMapHit::Pota && r.hit.index < list.size() ? parkoutlines::find(list.parks()[r.hit.index].ref) : nullptr;
    bool square = !o && r.hit.kind == ADIFMapHit::Square && r.span > 0.5 && adif::squareBounds(r.hit.square, &w, &s, &e, &n);  // a 4-character grid
    if (o) w = o->west, s = o->south, e = o->east, n = o->north;
    else if (!square) w = r.lon - r.span, e = r.lon + r.span, s = r.lat - r.span * 0.67, n = r.lat + r.span * 0.67;
    [mw.view showPlaceWest:w south:s east:e north:n];
    mw.choosingFromList = true;
    [mw.view selectHit:r.hit];
    mw.choosingFromList = false;
}

// ── The panes: the sidebar, the list under the map, the selected panel ──

const char *const kPaneKeys[3] = {"mapSidebar", "mapList", "mapSelected"};

// A pane at the size it was left, else its first size; the sidebar's and the selected panel's
// together, so that neither squeezes the other. Not saved again as it moves.
void restorePane(int pane) {
    bool restored = mw.splitsRestored;
    mw.splitsRestored = false;
    if (pane == 1) {
        CGFloat h = std::clamp((CGFloat)std::atof(setting("mapListHeight").c_str()), (CGFloat)0, (CGFloat)600);
        [mw.middleSplit setPosition:mw.middleSplit.bounds.size.height - (h >= 110 ? h : 230) - mw.middleSplit.dividerThickness ofDividerAtIndex:0];
    } else {
        CGFloat side = std::clamp((CGFloat)std::atof(setting("mapSidebarWidth").c_str()), (CGFloat)0, (CGFloat)380);
        CGFloat chosen = std::clamp((CGFloat)std::atof(setting("mapSelectedWidth").c_str()), (CGFloat)0, (CGFloat)480);
        CGFloat whole = mw.bodySplit.bounds.size.width, divider = mw.bodySplit.dividerThickness;
        for (int pass = 0; pass < 2; ++pass) {  // each divider set, then the right one again once the left one moved
            if (!mw.selectedPanel.hidden) [mw.bodySplit setPosition:whole - (chosen >= 240 ? chosen : 300) - divider ofDividerAtIndex:1];
            CGFloat least = std::max(mw.splitKeeper.leastSidebar, (CGFloat)280);
            if (!mw.sidebar.hidden && pass == 0) [mw.bodySplit setPosition:side >= least ? side : std::max(least, (CGFloat)284) ofDividerAtIndex:0];
        }
    }
    mw.splitsRestored = restored;
}

// A pane shown or hidden (its button at the right of the header): hidden, the map takes its room.
void showPane(int pane, bool on) {
    saveFlag(kPaneKeys[pane], on);
    mw.paneToggle[pane].state = on ? NSControlStateValueOn : NSControlStateValueOff;
    NSView *v = pane == 0 ? mw.sidebar : pane == 1 ? mw.listPanel : mw.selectedPanel;
    bool restored = mw.splitsRestored;
    mw.splitsRestored = false;  // the dividers moving now aren't the user's: their sizes stay as they were left
    v.hidden = !on;
    if (pane == 2) mw.view.infoHidden = on;  // the selected panel has what the map's information box would
    [pane == 1 ? mw.middleSplit : mw.bodySplit adjustSubviews];
    mw.splitsRestored = restored;
    if (on && restored) restorePane(pane);
    if (pane == 1 && on) queueViewList();
    if (mw.focusButton) {  // on while the map is alone
        bool alone = true;
        for (int i = 0; i < 3; ++i) alone = alone && mw.paneToggle[i].state != NSControlStateValueOn;
        mw.focusButton.state = alone ? NSControlStateValueOn : NSControlStateValueOff;
        mw.focusButton.image = [NSImage imageWithSystemSymbolName:alone ? @"arrow.down.right.and.arrow.up.left" : @"arrow.up.left.and.arrow.down.right"
                                         accessibilityDescription:nil];
    }
}

// A section of the sidebar open or closed (its triangle); remembered.
void setSectionOpen(NSString *name, bool open) {
    NSView *body = mw.sections[name];
    if (!body) return;
    body.hidden = !open;
    mw.sectionTriangles[name].state = open ? NSControlStateValueOn : NSControlStateValueOff;
    std::set<std::string> closed;
    for (const std::string &n : splitSetting("mapSectionsClosed", ',')) closed.insert(n);
    if (open) closed.erase(ADIFStd(name));
    else closed.insert(ADIFStd(name));
    std::string v;
    for (const std::string &n : closed) v += (v.empty() ? "" : ",") + n;
    setSetting("mapSectionsClosed", v);
}

// A group of the Layers section open or closed (its triangle): its rows hide; remembered.
void setLayerGroupOpen(NSString *name, bool open) {
    for (id part in mw.layerGroups[name]) [part setHidden:!open];  // grid rows and views alike
    mw.layerGroupTriangles[name].state = open ? NSControlStateValueOn : NSControlStateValueOff;
    std::set<std::string> closed;
    for (const std::string &n : splitSetting("mapLayerGroupsClosed", ',')) closed.insert(n);
    if (open) closed.erase(ADIFStd(name));
    else closed.insert(ADIFStd(name));
    std::string v;
    for (const std::string &n : closed) v += (v.empty() ? "" : ",") + n;
    setSetting("mapLayerGroupsClosed", v);
}

void switchWorkflow(int to);

// A section's control asked for (its popover; or a test): the sidebar shown and the section open;
// the Spots section is Live's.
void revealSection(NSString *name) {
    if ([name isEqualToString:@"spots"] && !live()) switchWorkflow(1);
    if (mw.sidebar.hidden) showPane(0, true);
    if (mw.sections[name].hidden) setSectionOpen(name, true);
    [mw.window layoutIfNeeded];
    [mw.sections[name] scrollRectToVisible:mw.sections[name].bounds];  // its button in sight, for the popover
}

// ── The workflows: History (the log, what it reached on each layer) and Live (the spots, and
// which of them to work), with Live's two presets, DX Chase and POTA ──

int workflow() { return number("mapWorkflow", 0, 3); }
bool live() { return workflow() >= 1; }  // Live, DX Chase or POTA: the spots

// The Quick View chosen; -1 when the layers were changed since (History).
int quickView() {
    std::string v = setting("mapQuickView");
    return v.empty() ? 0 : std::clamp(std::atoi(v.c_str()), -1, 99);
}

// What each workflow keeps for itself: its layers, contacts and lines, colours, list, Quick
// View, and the sun's shading.
std::vector<std::string> workflowKeys() {
    std::vector<std::string> keys = {"mapContacts", "mapPaths", "mapMine", "mapColorBy", "mapListKind", "mapQuickView", "mapGreyLine", "mapDayNight",
                                     "mapSpotsProgram"};
    for (const LayerUi &l : kLayerUi) {
        if (l.showKey) keys.push_back(l.showKey);
        keys.push_back(l.overlayKey);
        keys.push_back(l.labelsKey);
    }
    return keys;
}

// Live, the first time: the spots, with their calls; the countries and parks you worked shaded;
// the grey line; the list of spots.
std::string liveDefault(const std::string &key) {
    static const std::map<std::string, std::string> kLive = {
        {"mapShowSpots", "1"},    {"mapSpotLines", "0"},  {"mapSpotLabels", "1"}, {"mapSquares", "0"},  {"mapGrid", "0"},       {"mapLabels", "0"},
        {"mapDxcc", "1"},         {"mapCountries", "0"},  {"mapShowPota", "1"},   {"mapPota", "0"},     {"mapShowStates", "0"}, {"mapUsStates", "0"},
        {"mapShowCounties", "0"}, {"mapCounties", "0"},   {"mapShowCq", "0"},     {"mapCqZones", "0"},  {"mapShowItu", "0"},    {"mapItuZones", "0"},
        {"mapShowIota", "0"},     {"mapIota", "0"},       {"mapCities", "0"},     {"mapContacts", "0"}, {"mapPaths", "0"},      {"mapMine", "1"},
        {"mapColorBy", "0"},      {"mapListKind", "3"},   {"mapQuickView", "0"},  {"mapGreyLine", "1"}, {"mapDayNight", "0"}};
    auto it = kLive.find(key);
    return it == kLive.end() ? "" : it->second;
}

// A workflow's first time: History as the settings were; Live as above; DX Chase, Live for the
// DXCC entities and bands you need (Needed on its band, plain DX spots, no parks, the grey line);
// POTA, Live for the parks (POTA activators, every park, no DXCC shading).
std::string workflowDefault(const std::string &key, int wf) {
    static const std::map<std::string, std::string> kDxChase = {{"mapQuickView", "1"}, {"mapShowPota", "0"}, {"mapSpotsProgram", "-"}};
    static const std::map<std::string, std::string> kPota = {{"mapQuickView", "6"}, {"mapShowPota", "1"}, {"mapPota", "1"}, {"mapPotaLabels", "1"},
                                                             {"mapDxcc", "0"},       {"mapGreyLine", "0"}, {"mapSpotsProgram", "POTA"}};
    if (wf <= 0) return "";
    if (wf >= 2)
        if (auto it = (wf == 2 ? kDxChase : kPota).find(key); it != (wf == 2 ? kDxChase : kPota).end()) return it->second;
    return liveDefault(key);
}

void syncControls();

// To the other workflow: this one's settings kept, the other's back (Live's first time, its own).
void switchWorkflow(int to) {
    int from = workflow();
    if (to == from) return;
    std::string fromKey = "mapWf" + std::to_string(from), toKey = "mapWf" + std::to_string(to);
    for (const std::string &k : workflowKeys()) setSetting((fromKey + k).c_str(), setting(k.c_str()));
    setSetting((fromKey + "Saved").c_str(), "1");
    bool saved = setting((toKey + "Saved").c_str()) == "1";
    for (const std::string &k : workflowKeys()) setSetting(k.c_str(), saved ? setting((toKey + k).c_str()) : workflowDefault(k, to));
    setSetting("mapWorkflow", std::to_string(to));
    syncControls();
}

// The controls as the settings now say (a workflow or a Quick View set them), then the map.
// The toolbar's menus for a workflow: History's dates and confirmation, Live's spot age, sources,
// DXCC and program.
void workflowBars(int wf) {
    mw.dates.hidden = mw.confirmed.hidden = wf >= 1;  // the spots don't follow them (a tag says when they're on)
    mw.spotAgeBar.hidden = mw.spotSourceBar.hidden = mw.dxccBar.hidden = mw.potaBar.hidden = wf < 1;
}

void syncControls() {
    ADIFMapStyle saved = savedStyle();
    auto state = [](bool on) { return on ? NSControlStateValueOn : NSControlStateValueOff; };
    for (const LayerUi &l : kLayerUi) {
        if (mw.show[l.id]) mw.show[l.id].state = state(saved[l.id].show);
        mw.overlay[l.id].state = state(saved[l.id].overlay);
        mw.labels[l.id].state = state(saved[l.id].labels);
    }
    labelsFollow();
    mw.contacts.state = state(flag("mapContacts", false));
    mw.lines.state = state(flag("mapPaths", false));
    mw.mine.state = state(flag("mapMine", true));
    [mw.colorBy selectItemAtIndex:number("mapColorBy", 0, 4)];
    mw.listKind.selectedSegment = number("mapListKind", 0, kListKinds - 1);
    int wf = workflow();
    mw.workflow.selectedSegment = wf;
    mw.spotsSection.hidden = wf < 1;
    workflowBars(wf);

    mw.spotLens = wf >= 1 ? lensOfView(quickView()) : 0;
    applyViewFilters();
    refresh();       // the data and the style, the Quick Views' counts
    refreshSpots();  // the feeds start or stop with the Spots layer
}

// ── Quick Views ──

// History's: the whole log, or one layer: what you worked on it, among all of it.
struct HistoryView {
    const char *title;
    NSString *symbol;
    int layer;  // -1 the whole log, -2 the contacts at their places, -3 the QSOs not confirmed
    const char *tip;
};
const HistoryView kHistoryViews[] = {
    {N_("All QSOs"), @"list.bullet", -1, N_("The log as it first shows: worked grid squares, DXCC entities and POTA parks")},
    {N_("Needs confirmation"), @"envelope.badge", -3,
     N_("The QSOs not yet confirmed (by card, LoTW or eQSL), with the grid squares, DXCC entities and POTA parks they reached")},
    {N_("Grid squares"), @"square.grid.3x3", kLayerSquares, N_("The grid squares you worked, in the grid")},
    {N_("DXCC entities"), @"globe", kLayerCountries, N_("The DXCC entities you worked, among every country")},
    {N_("US states"), @"map", kLayerStates, N_("The US states you worked, among all 50")},
    {N_("US counties"), @"map", kLayerCounties, N_("The US counties you worked, among them all")},
    {N_("CQ zones"), @"circle.grid.cross", kLayerCq, N_("The CQ zones you worked, among all 40")},
    {N_("ITU zones"), @"circle.grid.cross", kLayerItu, N_("The ITU zones you worked, among all 90")},
    {N_("POTA parks"), @"leaf", kLayerPota, N_("The POTA parks you hunted and activated, among the others")},
    {N_("IOTA groups"), @"drop", kLayerIota, N_("The IOTA groups you worked, among them all")},
    {N_("Contacts"), @"mappin.and.ellipse", -2, N_("Each contact at its own place, with a line to it")},
};

// Live's: which of the spots show, by what they mean for the log.
struct LiveView {
    const char *title;
    NSString *symbol;
    const char *tip;
};
const LiveView kLiveViews[] = {
    {N_("All spots"), @"antenna.radiowaves.left.and.right", N_("Every station spotted now, as the spots' own filters allow")},
    {N_("Needed on its band"), @"sparkles", N_("Stations in a DXCC entity you haven't worked on their band: a new DXCC or a new band")},
    {N_("New DXCC"), @"star.circle", N_("Stations in a DXCC entity you haven't worked")},
    {N_("New band"), @"plus.circle", N_("Stations in an entity you worked, but not on this band")},
    {N_("New mode"), @"plus.circle", N_("Stations in an entity you worked on this band, but not in this mode (CW, phone or data)")},
    {N_("New POTA parks"), @"leaf", N_("POTA activators at parks you haven't worked")},
    {N_("POTA activators"), @"leaf", N_("Every POTA activator spotted")},
    {N_("My watch list"), @"star", N_("The calls, references and DXCC entities you watch, when spotted (Watch List... in Spots)")},
    {N_("Worked before"), @"checkmark.circle", N_("Stations whose entity you worked on this band and mode already")},
};
const size_t kLiveViewCount = sizeof kLiveViews / sizeof kLiveViews[0];
static_assert(kLiveViewCount == sizeof mw.lensCounts / sizeof mw.lensCounts[0], "a count for each of Live's views");
const int kWatchView = 7;  // My watch list

// Whether a spotted station belongs in one of Live's views.
bool inLens(int lens, const adif::Spot &sp, const adif::SpotStatus &st, bool watched) {
    switch (lens) {
        case 1: return !sp.heardMe && (st.need == adif::SpotNeed::NewDxcc || st.need == adif::SpotNeed::NewBand);
        case 2: return !sp.heardMe && st.need == adif::SpotNeed::NewDxcc;
        case 3: return !sp.heardMe && st.need == adif::SpotNeed::NewBand;
        case 4: return !sp.heardMe && st.need == adif::SpotNeed::NewMode;
        case 5: return mapkit::potaSpot(sp) && st.newPark;
        case 6: return mapkit::potaSpot(sp);
        case kWatchView: return watched;
        case 8: return !sp.heardMe && (st.need == adif::SpotNeed::Worked || st.need == adif::SpotNeed::Confirmed);
        default: return true;
    }
}

// History's Quick View for a layer (its row), -1 when none.
int historyViewOf(int layer) {
    for (size_t i = 0; i < std::size(kHistoryViews); ++i)
        if (kHistoryViews[i].layer == layer) return (int)i;
    return -1;
}

// History's Needs confirmation sets the Confirmed menu to Not confirmed; another view, or Live,
// puts it back as it was.
void applyViewFilters() {
    int v = quickView();
    bool needs = !live() && v >= 0 && (size_t)v < std::size(kHistoryViews) && kHistoryViews[v].layer == -3;
    if (needs && !mw.viewSetConfirmed) {
        [mw.confirmed selectItemAtIndex:2];
        mw.viewSetConfirmed = true;
    } else if (!needs && mw.viewSetConfirmed) {
        [mw.confirmed selectItemAtIndex:0];
        mw.viewSetConfirmed = false;
    }
}

std::string grouped(size_t n) { return ADIFStd([NSNumberFormatter localizedStringFromNumber:@(n) numberStyle:NSNumberFormatterDecimalStyle]); }

// ── Your own Quick Views (Save View...): a workflow's layers, colours and filters as they were,
// and in Live which spots; kept in mapUserViews (JSON: name, wf, lens, values by setting, and the
// toolbar's band, mode, dates and confirmation) ──

// The settings a view keeps besides the workflow's own (workflowKeys): More Filters' and the dates'.
const char *const kViewFilterKeys[] = {"mapFilterContinents", "mapFilterDxcc",     "mapFilterCq",       "mapFilterItu",
                                       "mapFilterStates",     "mapFilterCounties", "mapFilterRegions",  "mapFilterPota",
                                       "mapFilterWithinKm",   "mapFilterRecords",  "mapFilterParks",    "mapDateFrom",
                                       "mapDateTo"};

NSArray<NSDictionary *> *userViews() {
    NSData *d = [ADIFString(setting("mapUserViews")) dataUsingEncoding:NSUTF8StringEncoding];
    id v = d.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id item in [v isKindOfClass:NSArray.class] ? (NSArray *)v : @[])
        if ([item isKindOfClass:NSDictionary.class] && [item[@"name"] isKindOfClass:NSString.class] && [item[@"values"] isKindOfClass:NSDictionary.class])
            [out addObject:item];
    return out;
}

void saveUserViews(NSArray *views) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:views options:0 error:nil];
    setSetting("mapUserViews", d ? ADIFStd([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]) : "");
}

size_t builtinViews() { return live() ? kLiveViewCount : std::size(kHistoryViews); }

// This workflow's own views, each with its place in mapUserViews.
std::vector<std::pair<NSUInteger, NSDictionary *>> viewsHere() {
    std::vector<std::pair<NSUInteger, NSDictionary *>> out;
    NSArray<NSDictionary *> *all = userViews();
    for (NSUInteger i = 0; i < all.count; ++i)
        if ([all[i][@"wf"] respondsToSelector:@selector(intValue)] && [all[i][@"wf"] intValue] == workflow()) out.emplace_back(i, all[i]);
    return out;
}

// Which spots a Quick View shows (Live): its own, or the one your view was saved with.
int lensOfView(int view) {
    int most = (int)kLiveViewCount - 1;
    if (view < 0) return 0;
    if (view <= most) return view;
    std::vector<std::pair<NSUInteger, NSDictionary *>> mine = viewsHere();
    size_t at = (size_t)view - kLiveViewCount;
    if (at >= mine.size()) return 0;
    id lens = mine[at].second[@"lens"];
    return [lens respondsToSelector:@selector(intValue)] ? std::clamp([lens intValue], 0, most) : 0;
}

// The view as it is now, kept under `name`; chosen.
void saveViewAs(NSString *name) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (const std::string &k : workflowKeys())
        if (k != "mapQuickView") values[ADIFString(k)] = ADIFString(setting(k.c_str()));
    for (const char *k : kViewFilterKeys) values[@(k)] = ADIFString(setting(k));
    NSDictionary *view = @{
        @"name" : name, @"wf" : @(workflow()), @"lens" : @(mw.spotLens), @"values" : values,
        @"band" : mw.band.indexOfSelectedItem > 0 ? mw.band.titleOfSelectedItem : @"",
        @"mode" : mw.mode.indexOfSelectedItem > 0 ? mw.mode.titleOfSelectedItem : @"",
        @"dates" : @(std::min<NSInteger>(mw.dates.indexOfSelectedItem, 4)),
        @"year" : mw.dates.indexOfSelectedItem > 4 ? mw.dates.titleOfSelectedItem : @"",
        @"confirmed" : @(mw.confirmed.indexOfSelectedItem)
    };
    NSMutableArray *all = [userViews() mutableCopy];
    [all addObject:view];
    saveUserViews(all);
    setSetting("mapQuickView", std::to_string(builtinViews() + viewsHere().size() - 1));
    mw.viewSetConfirmed = false;
    fillQuickViews();
}

// One of yours chosen: its settings back, then the controls and the map.
void applyUserView(NSDictionary *v) {
    NSDictionary *values = v[@"values"];
    for (id k in values)
        if ([k isKindOfClass:NSString.class] && [values[k] isKindOfClass:NSString.class]) setSetting(ADIFStd(k), ADIFStd(values[k]));
    auto pick = [](NSPopUpButton *p, id title) {
        NSString *t = [title isKindOfClass:NSString.class] ? title : @"";
        if (t.length && ![p itemWithTitle:t]) [p addItemWithTitle:t];
        if (t.length) [p selectItemWithTitle:t];
        else [p selectItemAtIndex:0];
    };
    pick(mw.band, v[@"band"]);
    pick(mw.mode, v[@"mode"]);
    if ([v[@"year"] isKindOfClass:NSString.class] && [(NSString *)v[@"year"] length] && [mw.dates itemWithTitle:v[@"year"]]) [mw.dates selectItemWithTitle:v[@"year"]];
    else [mw.dates selectItemAtIndex:std::clamp([v[@"dates"] respondsToSelector:@selector(intValue)] ? [v[@"dates"] intValue] : 0, 0, 4)];
    [mw.confirmed selectItemAtIndex:std::clamp([v[@"confirmed"] respondsToSelector:@selector(intValue)] ? [v[@"confirmed"] intValue] : 0, 0, 6)];
    mw.viewSetConfirmed = false;
    if (mw.filterPopover) fillPlaceControls();
    mw.applyingView = true;
    syncControls();
    mw.applyingView = false;
}

// Save View...: a name for the view as it is.
void showSaveView(NSView *anchor) {
    if (!mw.saveViewPopover) {
        mw.saveViewName = ADIFTextField(@"Name, e.g. Evening on 40m", 220);
        mw.saveViewName.identifier = @"map.views.name";
        NSButton *save = [NSButton buttonWithTitle:T(@"Save") target:nil action:nil];
        save.identifier = @"map.views.saveok";
        save.keyEquivalent = @"\r";
        ADIFOnAction(save, ^{
            NSString *name = [mw.saveViewName.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!name.length) return;
            saveViewAs(name);
            [mw.saveViewPopover close];
        });
        NSTextField *help = [NSTextField wrappingLabelWithString:T(@"A Quick View of your own, in this workflow: the layers, colours and filters as "
                                                                   @"they are now, and in Live which spots show.")];
        help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        help.textColor = NSColor.secondaryLabelColor;
        NSStackView *line = [NSStackView stackViewWithViews:@[ mw.saveViewName, save ]];
        line.spacing = 8;
        NSStackView *stack = [NSStackView stackViewWithViews:@[ help, line ]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 10;
        stack.edgeInsets = NSEdgeInsetsMake(14, 14, 14, 14);
        stack.identifier = @"map.views.saving";
        [help.widthAnchor constraintEqualToAnchor:line.widthAnchor].active = YES;
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = stack;
        mw.saveViewPopover = [[NSPopover alloc] init];
        mw.saveViewPopover.contentViewController = vc;
        ADIFNightTrackPopover(mw.saveViewPopover);
        mw.saveViewPopover.behavior = NSPopoverBehaviorTransient;
    }
    mw.saveViewName.stringValue = @"";
    [mw.saveViewPopover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMaxX];
}

// A Quick View's own menu (right-click): one of yours can be removed.
void fillViewsMenu(NSMenu *menu) {
    [menu removeAllItems];
    NSInteger row = mw.quickTable.clickedRow >= 0 ? mw.quickTable.clickedRow : mw.quickTable.selectedRow;
    std::vector<std::pair<NSUInteger, NSDictionary *>> mine = viewsHere();
    if (row < (NSInteger)builtinViews() || (size_t)(row - (NSInteger)builtinViews()) >= mine.size()) {
        [menu addItemWithTitle:T(@"Save View... keeps yours here") action:nil keyEquivalent:@""].enabled = NO;
        return;
    }
    NSUInteger at = mine[(size_t)(row - (NSInteger)builtinViews())].first;
    NSString *name = mine[(size_t)(row - (NSInteger)builtinViews())].second[@"name"];
    NSMenuItem *remove = [menu addItemWithTitle:TF(@"Remove \u201C{name}\u201D", @{@"name" : name}) action:nil keyEquivalent:@""];
    NSInteger removed = row;
    ADIFBlockMenuItem(remove, ^{
        NSMutableArray *all = [userViews() mutableCopy];
        if (at < all.count) [all removeObjectAtIndex:at];
        saveUserViews(all);
        int chosen = quickView();
        if (chosen == removed) setSetting("mapQuickView", live() ? "0" : "-1");
        else if (chosen > removed) setSetting("mapQuickView", std::to_string(chosen - 1));
        mw.spotLens = live() ? lensOfView(quickView()) : 0;
        fillQuickViews();
        if (live()) refreshSpots();
    });
}

// The workflow's Quick Views, with their counts, the chosen one selected.
void fillQuickViews() {
    if (!mw.quickTable) return;
    std::vector<ADIFQuickRow> rows;
    const MapPalette &pal = paletteAt(mw.view.style.palette);
    if (!live()) {
        for (const HistoryView &v : kHistoryViews) {
            ADIFQuickRow r;
            r.title = tr(v.title), r.symbol = v.symbol;
            size_t worked = 0, confirmed = 0;
            if (v.layer == -1) {
                worked = mw.data.qsos.size();
                for (const adif::MapQso &q : mw.data.qsos) confirmed += q.confirmed;
            } else if (v.layer == -3) {
                for (const adif::MapQso &q : mw.data.qsos) worked += !q.confirmed;
            } else if (v.layer == -2) {
                worked = mw.view.contacts.size();
            } else if (v.layer == kLayerSquares) {
                worked = mw.data.squares.size();
                for (const adif::MapSquare &sq : mw.data.squares) confirmed += sq.confirmed;
            } else if (v.layer == kLayerCountries) {
                worked = mw.dxcc.size();
                for (const ADIFMapEntity &e : mw.dxcc) confirmed += e.confirmed;
            } else {
                std::pair<size_t, size_t> c = [mw.view workedCount:v.layer];
                worked = c.first, confirmed = c.second;
            }
            r.count = grouped(worked);
            r.tip = tr(v.tip) + (v.layer == -2 || v.layer == -3 ? "" : "\n" + trf("{worked} worked, {confirmed} confirmed", {{"worked", grouped(worked)}, {"confirmed", grouped(confirmed)}}));
            rows.push_back(r);
        }
    } else {
        for (size_t i = 0; i < kLiveViewCount; ++i) {
            ADIFQuickRow r;
            r.title = tr(kLiveViews[i].title), r.symbol = kLiveViews[i].symbol, r.tip = tr(kLiveViews[i].tip);
            r.count = mw.view.style[kLayerSpots].show ? grouped(mw.lensCounts[i]) : "";
            r.colour = i == 1 || i == 2 ? pal.needDxcc : i == 3 || i == 4 ? pal.needBand : i == 5 || i == 6 ? pal.park : i == kWatchView ? 0xD99A00 : i == 8 ? pal.worked : 0;
            rows.push_back(r);
        }
    }
    for (const auto &[index, v] : viewsHere()) {  // yours, after them
        ADIFQuickRow r;
        r.title = ADIFStd(v[@"name"]), r.symbol = @"bookmark";
        r.tip = tr("Your own view: the layers, colours and filters as you saved them (right-click to remove it)");
        if (live() && mw.view.style[kLayerSpots].show) {
            int lens = [v[@"lens"] respondsToSelector:@selector(intValue)] ? std::clamp([v[@"lens"] intValue], 0, (int)kLiveViewCount - 1) : 0;
            r.count = grouped(mw.lensCounts[lens]);
        }
        rows.push_back(r);
    }
    mw.quickRows.filling = YES;
    mw.quickRows.rows = rows;
    [mw.quickTable reloadData];
    int chosen = quickView();
    if (chosen >= 0 && (size_t)chosen < rows.size()) [mw.quickTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)chosen] byExtendingSelection:NO];
    else [mw.quickTable deselectAll:nil];
    mw.quickHeight.constant = rows.size() * (mw.quickTable.rowHeight + mw.quickTable.intercellSpacing.height) + 12;  // and the list's own margins
    mw.quickRows.filling = NO;
}

// A Quick View chosen. Live: only those spots. History: the layer's worked areas among all of it,
// named, the other layers' worked shading off; All QSOs: squares, countries and parks as at first.
void chooseQuickView(NSInteger row) {
    setSetting("mapQuickView", std::to_string(row));
    if (row >= (NSInteger)builtinViews()) {  // one of yours
        std::vector<std::pair<NSUInteger, NSDictionary *>> mine = viewsHere();
        if ((size_t)(row - (NSInteger)builtinViews()) < mine.size()) applyUserView(mine[(size_t)(row - (NSInteger)builtinViews())].second);
        return;
    }
    if (live()) {
        mw.spotLens = (int)std::min<NSInteger>(row, (NSInteger)kLiveViewCount - 1);
        refreshSpots();
        return;
    }
    if (row < 0 || (size_t)row >= sizeof kHistoryViews / sizeof kHistoryViews[0]) return;
    const HistoryView &v = kHistoryViews[row];
    for (const LayerUi &l : kLayerUi) {
        if (l.id == kLayerSpots || l.id == kLayerCities) continue;
        bool focus = v.layer == -1 || v.layer == -3 ? l.id == kLayerSquares || l.id == kLayerCountries || l.id == kLayerPota : l.id == v.layer;
        if (l.showKey) saveFlag(l.showKey, focus);
        saveFlag(l.overlayKey, focus && v.layer >= 0 ? true : l.overlayOn);
        if (focus) saveFlag(l.labelsKey, true);
    }
    saveFlag("mapContacts", v.layer == -2);
    saveFlag("mapPaths", v.layer == -2);
    mw.applyingView = true;
    syncControls();
    mw.applyingView = false;
}

// ── The watch list: the calls, references and DXCC entities you want to know are on the air ──

std::vector<std::string> watchList() { return adif::watchList(setting("mapWatch")); }

bool onWatchList(const std::string &token) {
    std::vector<std::string> list = watchList();
    return !token.empty() && std::find(list.begin(), list.end(), token) != list.end();
}

// What Watch watches for what is chosen: a spotted station's or a contact's call, a park's or an
// IOTA group's reference, a DXCC entity; "" for anything else (a place with several stations).
std::string watchTokenFor(const ADIFMapHit &h) {
    std::string t;
    if (h.kind == ADIFMapHit::Spot && h.index < mw.view.spots.size()) {
        if (!mw.view.spots[h.index].spot.heardMe) t = adif::lookupCall(mw.view.spots[h.index].spot.activator);
    } else if (h.kind == ADIFMapHit::Contact && h.index < mw.view.contacts.size()) {
        for (size_t qi : mw.view.contacts[h.index].qsos) {
            if (qi >= mw.data.qsos.size()) continue;
            std::string c = adif::lookupCall(mw.data.qsos[qi].call);
            if (!t.empty() && c != t) return "";
            t = c;
        }
    } else if (h.kind == ADIFMapHit::Dxcc && h.index < mw.dxcc.size()) {
        t = entityName(mw.dxcc[h.index].dxcc, "");
    } else if (h.kind == ADIFMapHit::Pota && h.index < ADIFPotaParks().size()) {
        t = ADIFPotaParks().parks()[h.index].ref;
    } else if (h.kind == ADIFMapHit::Iota && h.index < ADIFIotaGroups().size()) {
        t = ADIFIotaGroups()[h.index].ref;
    } else if (h.kind == ADIFMapHit::Park && h.index < mw.data.parks.size()) {
        t = mw.data.parks[h.index].reference;
    }
    std::vector<std::string> one = adif::watchList(t);  // as the list keeps it
    return one.size() == 1 ? one[0] : "";
}

// The selected panel's Watch: whether what is chosen is on the list.
void showWatchButton(const ADIFMapHit &h) {
    if (!mw.watchButton) return;
    std::string token = watchTokenFor(h);
    mw.watchButton.hidden = token.empty();
    mw.actions.needsLayout = YES;
    if (token.empty()) return;
    bool on = onWatchList(token);
    mw.watchButton.title = on ? T(@"Watching") : T(@"Watch");
    mw.watchButton.image = [NSImage imageWithSystemSymbolName:on ? @"star.fill" : @"star" accessibilityDescription:nil];
    mw.watchButton.contentTintColor = on ? NSColor.systemYellowColor : nil;
    mw.actions.needsLayout = YES;  // its title's width too
    mw.watchButton.toolTip = [ADIFString(on ? trf("{what} is on your watch list; click to stop watching it", {{"what", token}})
                                            : trf("Watch {what}: when it is spotted, it shows in My watch list, first among the spots, and under the bell",
                                                  {{"what", token}})) stringByAppendingString:@"  (\u2318D)"];
}

// The editor's tokens, as the list has them.
void fillWatchList() {
    if (!mw.watchTokens) return;
    NSMutableArray *tokens = [NSMutableArray array];
    for (const std::string &w : watchList()) [tokens addObject:ADIFString(w)];
    mw.watchTokens.objectValue = tokens;
}

// The list changed: saved; the spots, the panel and the editor follow it.
void saveWatchList(const std::vector<std::string> &list) {
    setSetting("mapWatch", adif::watchListText(list));
    refreshSpots();
    ADIFMapHit h = mw.view.selectedHit;
    if (h.kind != ADIFMapHit::None) showChosenFacts(h);
    showWatchButton(h);
    fillWatchList();
}

void toggleWatch(const std::string &token) {
    if (token.empty()) return;
    std::vector<std::string> list = watchList();
    auto it = std::find(list.begin(), list.end(), token);
    if (it != list.end()) list.erase(it);
    else list.push_back(token);
    saveWatchList(list);
}

// The watch list's editor, beside `anchor` (Watch List... in Spots, or the bell).
void showWatchList(NSView *anchor) {
    if (!mw.watchPopover) {
        ADIFTokenCompleter *names = [[ADIFTokenCompleter alloc] init];  // the DXCC entities, by name
        NSMutableArray *entities = [NSMutableArray array];
        for (const adif::CountryInfo &c : ADIFCountries().all()) [entities addObject:ADIFString(c.name)];
        names.candidates = entities;
        if (!mw.completers) mw.completers = [NSMutableArray array];
        [mw.completers addObject:names];
        mw.watchTokens = [[NSTokenField alloc] initWithFrame:NSMakeRect(0, 0, 340, 48)];
        mw.watchTokens.identifier = @"map.watch.tokens";
        mw.watchTokens.placeholderString = T(@"e.g. K1ABC, US-1234, EU-005, Bhutan");
        mw.watchTokens.tokenizingCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@",\n"];
        mw.watchTokens.delegate = names;
        mw.watchTokens.translatesAutoresizingMaskIntoConstraints = NO;
        [mw.watchTokens.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
        ADIFOnAction(mw.watchTokens, ^{
            NSMutableArray *parts = [NSMutableArray array];
            for (id t in (NSArray *)mw.watchTokens.objectValue) [parts addObject:[t description]];
            saveWatchList(adif::watchList(ADIFStd([parts componentsJoinedByString:@","])));
        });
        NSTextField *help = [NSTextField
            wrappingLabelWithString:T(@"Calls, references (a POTA park, an IOTA group...) and DXCC entities to watch for. When one is spotted, it "
                                      @"shows in My watch list (Live's Quick Views), first among the spots with a star, and under the bell at "
                                      @"the top. Watch in the selected panel adds what you chose.")];
        help.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        help.textColor = NSColor.secondaryLabelColor;
        help.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
        content.identifier = @"map.watch";
        [content addSubview:help];
        [content addSubview:mw.watchTokens];
        [NSLayoutConstraint activateConstraints:@[
            [help.topAnchor constraintEqualToAnchor:content.topAnchor constant:14],
            [help.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
            [help.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
            [help.widthAnchor constraintEqualToConstant:340],
            [mw.watchTokens.topAnchor constraintEqualToAnchor:help.bottomAnchor constant:10],
            [mw.watchTokens.leadingAnchor constraintEqualToAnchor:help.leadingAnchor],
            [mw.watchTokens.trailingAnchor constraintEqualToAnchor:help.trailingAnchor],
            [mw.watchTokens.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        ]];
        NSViewController *vc = [[NSViewController alloc] init];
        vc.view = content;
        mw.watchPopover = [[NSPopover alloc] init];
        mw.watchPopover.contentViewController = vc;
        ADIFNightTrackPopover(mw.watchPopover);
        mw.watchPopover.behavior = NSPopoverBehaviorTransient;
    }
    fillWatchList();
    [mw.watchPopover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMaxY];
}

// A spotted station chosen on the map, in Live (My watch list, when the Quick View hides it).
void chooseSpot(const std::string &call, const std::string &band) {
    if (!live()) switchWorkflow(1);
    for (int pass = 0; pass < 2; ++pass) {
        const std::vector<ADIFMapSpot> &spots = mw.view.spots;
        for (size_t k = 0; k < spots.size(); ++k)
            if (spots[k].spot.activator == call && spots[k].spot.band == band) {
                ADIFMapHit h;
                h.kind = ADIFMapHit::Spot, h.index = k, h.square = adif::squareAt(spots[k].lon, spots[k].lat);
                [mw.view selectHit:h];
                centerChosen();
                return;
            }
        if (pass == 0) chooseQuickView(kWatchView);
    }
}

// The header's bell: how many stations on your watch list are spotted; orange when one came since
// it was last opened, or when the feeds have sent nothing for 15 minutes.
void fillBell() {
    if (!mw.bell) return;
    size_t n = mw.watchedSpots.size();
    bool unseen = false;
    for (const ADIFWatchedSpot &w : mw.watchedSpots) unseen |= !mw.bellSeen.count(w.call + "|" + w.band);
    long long now = (long long)time(nullptr);
    bool stale = mw.view.style[kLayerSpots].show && mw.newestSpot > 0 && now - mw.newestSpot >= 900;
    mw.bell.image = [NSImage imageWithSystemSymbolName:unseen ? @"bell.badge.fill" : n ? @"bell.fill" : @"bell" accessibilityDescription:nil];
    mw.bell.title = n ? ADIFString(grouped(n)) : @"";
    mw.bell.imagePosition = n ? NSImageLeading : NSImageOnly;
    mw.bell.contentTintColor = unseen || stale ? NSColor.systemOrangeColor : nil;
    std::string tip = n ? trp("{n} station on your watch list is spotted now", "{n} stations on your watch list are spotted now", (long long)n)
                        : tr("None of your watch list is spotted now");
    if (stale) tip += "\n" + tr("No new spots for 15 minutes or more: the feeds may have stopped");
    mw.bell.toolTip = ADIFString(tip + "\n" + tr("Click for them, and to edit the watch list"));
}

// The bell's menu: the watched stations spotted (each chooses its spot, in Live), whether the
// feeds have gone quiet, and the watch list's editor.
void fillBellMenu(NSMenu *menu) {
    [menu removeAllItems];
    auto heading = [&](const std::string &text) { [menu addItemWithTitle:ADIFString(text) action:nil keyEquivalent:@""].enabled = NO; };
    long long now = (long long)time(nullptr);
    bool show = mw.view.style[kLayerSpots].show;
    if (watchList().empty()) heading(tr("Your watch list is empty"));
    else if (!show) heading(tr("Spots are off: Live shows them"));
    else if (mw.watchedSpots.empty()) heading(tr("None of your watch list is spotted now"));
    else heading(trp("{n} watched station spotted", "{n} watched stations spotted", (long long)mw.watchedSpots.size()));
    for (const ADIFWatchedSpot &w : mw.watchedSpots) {
        std::string title = w.call;
        if (!w.khz.empty()) {
            char mhz[32];
            snprintf(mhz, sizeof mhz, "%.3f", std::atof(w.khz.c_str()) / 1000);
            title += "  " + std::string(mhz);
        }
        if (!w.mode.empty()) title += " " + w.mode;
        if (w.epoch > 0) title += "  ·  " + adif::spotAge(w.epoch, now);
        if (w.what != adif::lookupCall(w.call)) title += "  (" + w.what + ")";
        NSMenuItem *item = [menu addItemWithTitle:ADIFString(title) action:nil keyEquivalent:@""];
        item.image = [NSImage imageWithSystemSymbolName:mw.bellSeen.count(w.call + "|" + w.band) ? @"star" : @"star.fill" accessibilityDescription:nil];
        std::string call = w.call, band = w.band;
        ADIFBlockMenuItem(item, ^{ chooseSpot(call, band); });
    }
    if (show && mw.newestSpot > 0 && now - mw.newestSpot >= 900) {
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *quiet = [menu addItemWithTitle:ADIFString(trf("No new spots for {age}: the feeds' state...", {{"age", adif::spotAge(mw.newestSpot, now)}}))
                                            action:nil
                                     keyEquivalent:@""];
        quiet.image = [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle" accessibilityDescription:nil];
        ADIFBlockMenuItem(quiet, ^{ showSpotsPopover(); });
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *edit = [menu addItemWithTitle:T(@"Edit Watch List...") action:nil keyEquivalent:@""];
    ADIFBlockMenuItem(edit, ^{ showWatchList(mw.bell); });
    for (const ADIFWatchedSpot &w : mw.watchedSpots) mw.bellSeen.insert(w.call + "|" + w.band);  // seen now
    fillBell();
}

// ── Home: your station in the middle, or the view you set as Home (mapHomeView: lon, lat, zoom) ──

void goHomeView() {
    std::vector<std::string> v = splitSetting("mapHomeView", ',');
    if (v.size() == 3) [mw.view showLon:std::atof(v[0].c_str()) lat:std::atof(v[1].c_str()) zoom:std::atof(v[2].c_str())];
    else [mw.view goHome];
}

void fillHomeMenu(NSMenu *menu) {
    [menu removeAllItems];
    menu.autoenablesItems = NO;
    NSMenuItem *set = [menu addItemWithTitle:T(@"Set Home View to This") action:nil keyEquivalent:@""];
    ADIFBlockMenuItem(set, ^{
        double lon, lat, zoom;
        if (![mw.view viewLon:&lon lat:&lat zoom:&zoom]) return;
        char v[64];
        snprintf(v, sizeof v, "%.5f,%.5f,%.4f", lon, lat, zoom);
        setSetting("mapHomeView", v);
    });
    NSMenuItem *reset = [menu addItemWithTitle:T(@"Forget Home View (Your Station)") action:nil keyEquivalent:@""];
    reset.enabled = !setting("mapHomeView").empty();
    ADIFBlockMenuItem(reset, ^{ setSetting("mapHomeView", ""); });
}

// ── Search: a call (your QSOs, a spot), a grid square, a DXCC entity, a POTA park ──

struct ADIFFound {
    std::string title;
    NSString *symbol;
    void (^choose)(void);
};

// What the map has for the search, the most exact first: a grid square typed; the calls in the
// log, then spotted; the DXCC entities worked; POTA's parks (by reference or name). At most 20.
std::vector<ADIFFound> findOnMap(const std::string &typed) {
    std::string q;
    for (char c : typed)
        if (!isspace((unsigned char)c)) q += (char)toupper((unsigned char)c);
    std::vector<ADIFFound> out;
    if (q.empty()) return out;
    auto contains = [&](const std::string &text) {
        std::string t = text;
        for (char &c : t) c = (char)toupper((unsigned char)c);
        return t.find(q) != std::string::npos;
    };
    double lat, lon;
    if ((q.size() == 4 || q.size() == 6 || q.size() == 8) && isalpha((unsigned char)q[0]) && adif::gridToLatLon(q, &lat, &lon)) {
        std::string grid = q.substr(0, 4);
        out.push_back({trf("Grid square {grid}", {{"grid", q}}), @"square.grid.3x3", ^{
                           double w, s, e, n;
                           if (adif::squareBounds(grid, &w, &s, &e, &n)) [mw.view showPlaceWest:w south:s east:e north:n];
                           ADIFMapHit h;
                           h.kind = ADIFMapHit::Empty, h.square = grid;
                           for (size_t i = 0; i < mw.data.squares.size(); ++i)
                               if (mw.data.squares[i].grid == grid) h.kind = ADIFMapHit::Square, h.index = i;
                           [mw.view selectHit:h];
                       }});
    }
    std::map<std::string, std::vector<size_t>> calls;  // the log's, as the filters keep them
    for (size_t i = 0; i < mw.data.qsos.size(); ++i)
        if (contains(mw.data.qsos[i].call)) calls[mw.data.qsos[i].call].push_back(i);
    std::vector<std::pair<std::string, std::vector<size_t>>> byCall(calls.begin(), calls.end());
    std::stable_sort(byCall.begin(), byCall.end(), [&](const auto &a, const auto &b) { return (a.first == q) > (b.first == q); });  // the very call first
    for (size_t k = 0; k < byCall.size() && k < 8; ++k) {
        std::vector<size_t> qsos = byCall[k].second;
        out.push_back({trp("{call}: {n} QSO", "{call}: {n} QSOs", (long long)qsos.size(), {{"call", byCall[k].first}}), @"person.crop.circle", ^{
                           // Chosen on the map at its square, else its entity; its QSOs in the list.
                           const adif::MapQso &first = mw.data.qsos[qsos[0]];
                           std::string grid4 = first.grid.substr(0, std::min<size_t>(4, first.grid.size()));
                           for (char &c : grid4) c = (char)toupper((unsigned char)c);
                           ADIFMapHit h;
                           for (size_t i = 0; i < mw.data.squares.size() && h.kind == ADIFMapHit::None; ++i)
                               if (mw.data.squares[i].grid == grid4) h.kind = ADIFMapHit::Square, h.index = i, h.square = grid4;
                           for (size_t i = 0; i < mw.dxcc.size() && h.kind == ADIFMapHit::None; ++i)
                               if (std::find(mw.dxcc[i].qsos.begin(), mw.dxcc[i].qsos.end(), qsos[0]) != mw.dxcc[i].qsos.end())
                                   h.kind = ADIFMapHit::Dxcc, h.index = i, h.square = adif::squareAt(mw.dxcc[i].lon, mw.dxcc[i].lat);
                           if (h.kind != ADIFMapHit::None) {
                               [mw.view selectHit:h];
                               centerChosen();
                           }
                           showList(qsos);
                       }});
    }
    std::set<std::string> spotted;
    for (const ADIFMapSpot &ms : mw.view.spots)
        if (out.size() < 20 && contains(ms.spot.activator) && spotted.insert(ms.spot.activator + "|" + ms.spot.band).second) {
            std::string call = ms.spot.activator, band = ms.spot.band;
            out.push_back({trf("{call}: spotted on {band} {mode}", {{"call", call}, {"band", band}, {"mode", ms.spot.mode}}),
                           @"antenna.radiowaves.left.and.right", ^{ chooseSpot(call, band); }});
        }
    for (size_t i = 0; i < mw.dxcc.size() && out.size() < 20; ++i)
        if (q.size() >= 3 && contains(mw.dxcc[i].name)) {
            size_t at = i;
            out.push_back({trp("{entity}: DXCC entity, {n} QSO", "{entity}: DXCC entity, {n} QSOs", (long long)mw.dxcc[i].qsos.size(),
                               {{"entity", mw.dxcc[i].name}}),
                           @"globe", ^{
                               ADIFMapHit h;
                               h.kind = ADIFMapHit::Dxcc, h.index = at, h.square = adif::squareAt(mw.dxcc[at].lon, mw.dxcc[at].lat);
                               [mw.view selectHit:h];
                               centerChosen();
                           }});
        }
    const adif::PotaParks &parks = ADIFPotaParks();
    for (size_t i = 0; i < parks.size() && out.size() < 20 && q.size() >= 3; ++i) {
        const adif::PotaPark &p = parks.parks()[i];
        if (!p.placed || (!contains(p.ref) && !contains(p.name))) continue;
        size_t at = i;
        out.push_back({p.ref + "  " + p.name, @"leaf", ^{
                           const adif::PotaPark &park = ADIFPotaParks().parks()[at];
                           [mw.view showPlaceWest:park.lon - 0.3 south:park.lat - 0.2 east:park.lon + 0.3 north:park.lat + 0.2];
                           ADIFMapHit h;
                           h.kind = ADIFMapHit::Pota, h.index = at, h.square = adif::squareAt(park.lon, park.lat);
                           [mw.view selectHit:h];
                       }});
    }
    return out;
}

// The search's results, as a menu: each chooses its thing on the map.
void fillFindMenu(NSMenu *menu) {
    [menu removeAllItems];
    std::vector<ADIFFound> found = findOnMap(ADIFStd(mw.findField.stringValue));
    if (found.empty()) {
        [menu addItemWithTitle:T(@"Nothing on the map matches") action:nil keyEquivalent:@""].enabled = NO;
        return;
    }
    for (const ADIFFound &f : found) {
        NSMenuItem *item = [menu addItemWithTitle:ADIFString(f.title) action:nil keyEquivalent:@""];
        item.image = [NSImage imageWithSystemSymbolName:f.symbol accessibilityDescription:nil];
        ADIFBlockMenuItem(item, f.choose);
    }
}

// Return in the search: one thing found, it is chosen; more, a menu of them.
void findTyped() {
    std::vector<ADIFFound> found = findOnMap(ADIFStd(mw.findField.stringValue));
    if (found.empty()) {
        if (mw.findField.stringValue.length) setStatus(trf("Nothing on the map matches “{text}”.", {{"text", ADIFStd(mw.findField.stringValue)}}));
        return;
    }
    if (found.size() == 1) return found[0].choose();
    [mw.findMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(mw.findField.bounds) + 4) inView:mw.findField];
}

// The header's QSL Sync: when confirmations were last downloaded (the latest of the services),
// a click opening QSL Sync.
void fillSynced() {
    if (!mw.synced) return;
    std::string latest, tip;
    for (const auto &[key, name] : std::vector<std::pair<const char *, const char *>>{
             {"lastDownloadLoTW", "LoTW"}, {"lastDownloadQRZ", "QRZ.com"}, {"lastDownloadEQSL", "eQSL"}}) {
        std::string at = setting(key);  // "YYYY-MM-DD HH:MM UTC"
        latest = std::max(latest, at);
        tip += std::string(tip.empty() ? "" : "\n") + name + ": " + (at.empty() ? tr("never") : at);
    }
    mw.synced.title = latest.empty() ? T(@"QSL: never synced") : TF(@"QSL synced {when}", @{@"when" : ADIFString(latest.substr(0, 10))});
    mw.synced.toolTip = ADIFString(tr("Confirmations last downloaded (QSL Sync); click to open it") + "\n" + tip);
}

// Live's DXCC and POTA menus, as the Quick View and the spots' program are.
void fillDxccPotaBars() {
    if (!mw.dxccBar) return;
    static const int kDxccLens[] = {0, 1, 2, 3, 4, 8};  // the menu's items: the Quick View each chooses
    NSInteger at = 0;
    for (NSInteger i = 0; i < (NSInteger)std::size(kDxccLens); ++i)
        if (kDxccLens[i] == mw.spotLens) at = i;
    [mw.dxccBar selectItemAtIndex:at];
    std::string program = setting("mapSpotsProgram");
    [mw.potaBar selectItemAtIndex:program == "-" ? 3 : program == "POTA" ? (mw.spotLens == 5 ? 2 : 1) : 0];
    for (NSPopUpButton *p in @[ mw.dxccBar, mw.potaBar ]) [p invalidateIntrinsicContentSize];  // "DXCC: New band" is wider than "New band"
    for (NSView *v = mw.dxccBar.superview; v; v = v.superview)
        if ([v isKindOfClass:ADIFFlowView.class]) v.needsLayout = YES;
}

// ── Shortcuts: ⌘] and ⌘[ the list's next and previous row (chosen on the map); ⌘↩ New QSO with
// the spot chosen; ⌘L the map centred on what is chosen; ⌘D watch it, or stop; ⌘F the search ──

// The list's next or previous row (the first when none is), chosen on the map as a click on it would.
bool stepList(int by) {
    NSInteger n = mw.listTable.numberOfRows;
    if (!n || mw.listPanel.hidden) return false;
    NSInteger r = mw.listTable.selectedRow;
    NSInteger to = r < 0 ? 0 : std::clamp<NSInteger>(r + by, 0, n - 1);
    [mw.listTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)to] byExtendingSelection:NO];
    [mw.listTable scrollRowToVisible:to];
    return true;
}

bool mapShortcut(NSEvent *e) {
    NSEventModifierFlags mods = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask & ~(NSEventModifierFlagNumericPad | NSEventModifierFlagFunction);
    if (mods != NSEventModifierFlagCommand) return false;
    NSString *k = e.charactersIgnoringModifiers.lowercaseString;
    ADIFMapHit h = mw.view.selectedHit;
    if ([k isEqualToString:@"]"] || [k isEqualToString:@"["]) return stepList([k isEqualToString:@"]"] ? 1 : -1);
    if ([k isEqualToString:@"\r"]) {
        if (h.kind != ADIFMapHit::Spot) return false;
        useSelectedSpot();
        return true;
    }
    if ([k isEqualToString:@"l"]) {
        if (h.kind == ADIFMapHit::None) return false;
        centerChosen();
        return true;
    }
    if ([k isEqualToString:@"d"]) {
        std::string token = watchTokenFor(h);
        if (token.empty()) return false;
        toggleWatch(token);
        return true;
    }
    if ([k isEqualToString:@"f"]) {
        [mw.window makeFirstResponder:mw.findField];
        return true;
    }
    return false;
}

// A layer's own menu (right-click its name): its boxes; this layer only; how strongly worked
// areas are shaded.
void fillLayerMenu(NSMenu *menu) {
    [menu removeAllItems];
    std::string ident = ADIFStd(menu.title).substr(6);  // "layer:grid"
    const LayerUi *layer = nullptr;
    for (const LayerUi &l : kLayerUi)
        if (ADIFStd(l.ident) == ident) layer = &l;
    if (!layer) return;
    MapLayerId id = layer->id;
    auto toggle = [&](NSString *title, NSButton *b) {
        if (!b) return;
        NSMenuItem *item = [menu addItemWithTitle:T(title) action:nil keyEquivalent:@""];
        item.state = b.state;
        item.enabled = b.enabled;
        ADIFBlockMenuItem(item, ^{
            b.state = b.state == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
            [b sendAction:b.action to:b.target];
        });
    };
    menu.autoenablesItems = NO;
    toggle(N(@"Worked"), mw.show[id]);
    toggle(N(@"All"), mw.overlay[id]);
    toggle(N(@"Labels"), mw.labels[id]);
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *only = [menu addItemWithTitle:T(@"Only This Layer") action:nil keyEquivalent:@""];
    ADIFBlockMenuItem(only, ^{  // this one shown, with its labels; the other layers (not the spots) off
        for (const LayerUi &l : kLayerUi) {
            if (l.id == kLayerSpots) continue;
            bool me = l.id == id;
            if (mw.show[l.id]) mw.show[l.id].state = me ? NSControlStateValueOn : NSControlStateValueOff;
            mw.overlay[l.id].state = me ? NSControlStateValueOn : NSControlStateValueOff;
            if (me) mw.labels[l.id].state = NSControlStateValueOn;
        }
        layerChanged(id, 1);
    });
    if (layer->showKey && id != kLayerPota && id != kLayerIota) {
        NSMenuItem *shade = [menu addItemWithTitle:T(@"Worked Areas' Shading") action:nil keyEquivalent:@""];
        NSMenu *sub = [[NSMenu alloc] init];
        int now = number("mapAreaShade", 1, 2);
        NSArray<NSString *> *names = @[ N(@"Light##shade"), N(@"Medium##shade"), N(@"Strong##shade") ];
        for (int i = 0; i < 3; ++i) {
            NSMenuItem *it = [sub addItemWithTitle:T(names[i]) action:nil keyEquivalent:@""];
            it.state = i == now ? NSControlStateValueOn : NSControlStateValueOff;
            ADIFBlockMenuItem(it, ^{
                setSetting("mapAreaShade", std::to_string(i));
                applyStyle();
                fillStyle();
            });
        }
        shade.submenu = sub;
    }
}

// ── The footer: what is under the pointer, and the workflow's state ──

void showHover(const std::string &text) {
    mw.hover.stringValue = ADIFString(text);
    mw.hover.toolTip = mw.hover.stringValue;
}

// The map centred on what was chosen, at the zoom it has.
void centerChosen() {
    ADIFMapHit h = mw.view.selectedHit;
    double lat = 0, lon = 0;
    std::string name;
    if (h.kind == ADIFMapHit::Spot && h.index < mw.view.spots.size()) lat = mw.view.spots[h.index].lat, lon = mw.view.spots[h.index].lon;
    else if (h.kind == ADIFMapHit::Spotter && h.index < mw.view.spotters.size()) lat = mw.view.spotters[h.index].lat, lon = mw.view.spotters[h.index].lon;
    else [mw.view selectedPlace:&lat lon:&lon name:&name];
    [mw.view centerOnLon:lon lat:lat];
}

NSButton *smallButton(NSString *title, NSString *tip, void (^action)(void)) {
    NSButton *b = [NSButton buttonWithTitle:T(title) target:nil action:nil];
    b.toolTip = T(tip);
    ADIFOnAction(b, action);
    return b;
}

NSPopUpButton *pullDown(NSString *title, NSString *tip) {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [p addItemWithTitle:T(title)];
    p.toolTip = T(tip);
    return p;
}

}  // namespace

void cmdMap() {
    if (!mw.window) {
        mw.window = [[ADIFMapWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1460, 900)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                         NSWindowStyleMaskUtilityWindow
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
        mw.window.title = T(@"Map");
        mw.window.identifier = @"map.window";  // its title names the log
        ADIFNightTrack(mw.window);
        mw.window.releasedWhenClosed = NO;
        mw.window.hidesOnDeactivate = NO;
        mw.window.contentMinSize = NSMakeSize(1100, 700);
        NSView *root = mw.window.contentView;
        // The layers: a row each, in sections (areas, programs, places), with its Show, Overlay and
        // Labels boxes under their titles. The Spots layer's boxes go in the Spots card.
        ADIFMapStyle saved = savedStyle();
        auto box = [](bool on, NSString *kind, const LayerUi &l, NSString *tip, NSString *spoken) {
            NSButton *b = ADIFCheckbox(@"", on);
            b.identifier = [NSString stringWithFormat:@"map.%@.%@", kind, l.ident];
            b.toolTip = T(tip);
            b.accessibilityLabel = [NSString stringWithFormat:T(spoken), T(l.title)];
            return b;
        };
        auto heading = [](NSString *text, NSFontWeight weight) {  // a column's or a section's title
            NSTextField *t = ADIFLabel(text);
            t.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:weight];
            t.textColor = NSColor.secondaryLabelColor;
            return t;
        };
        // A group's title with its triangle: closed, its rows hide (remembered).
        mw.layerGroups = [NSMutableDictionary dictionary];
        mw.layerMenus = [NSMutableArray array];
        mw.layerGroupTriangles = [NSMutableDictionary dictionary];
        auto groupHead = [&](NSString *name, NSString *title) -> NSView * {
            NSButton *triangle = [NSButton buttonWithTitle:@"" target:nil action:nil];
            triangle.bezelStyle = NSBezelStyleDisclosure;
            [triangle setButtonType:NSButtonTypePushOnPushOff];
            triangle.controlSize = NSControlSizeSmall;
            triangle.identifier = [@"map.layergroup." stringByAppendingString:name];
            triangle.accessibilityLabel = T(title);
            triangle.state = NSControlStateValueOn;
            __weak NSButton *weak = triangle;
            ADIFOnAction(triangle, ^{ setLayerGroupOpen(name, weak.state == NSControlStateValueOn); });
            mw.layerGroupTriangles[name] = triangle;
            NSStackView *h = [NSStackView stackViewWithViews:@[ triangle, heading(title, NSFontWeightSemibold) ]];
            h.spacing = 1;
            return h;
        };
        // Other programs (WWFF, SOTA, IOTA's references in the log...): a box for them all, the name a
        // menu of which.
        mw.programs = pullDown(@"Other programs", @"Other programs' references, a colour each: WWFF parks, SOTA summits, IOTA islands, GMA, "
                                                  @"bunkers, castles... (IOTA starts hidden: callbooks fill it in for every island station)");
        mw.programs.bordered = NO;
        ((NSPopUpButtonCell *)mw.programs.cell).arrowPosition = NSPopUpArrowAtBottom;
        mw.programs.identifier = @"map.programs";
        {  // as wide as its title, not its longest item (which would widen the sidebar's least width)
            CGFloat w = std::ceil([T(@"Other programs") sizeWithAttributes:@{NSFontAttributeName : mw.programs.font}].width) + 24;
            [mw.programs.widthAnchor constraintEqualToConstant:w].active = YES;
        }
        mw.otherBox = ADIFCheckbox(@"", true);
        mw.otherBox.identifier = @"map.show.others";
        mw.otherBox.toolTip = T(@"The references of other programs you worked (WWFF, SOTA, IOTA...), a colour each; the name chooses which");
        mw.otherBox.accessibilityLabel = T(@"Show other programs");
        ADIFOnAction(mw.otherBox, ^{ otherProgramsChanged(); });
        NSMutableArray *layerRows = [NSMutableArray arrayWithObject:@[
            groupHead(@"areas", N(@"Worked areas")), heading(N(@"Worked"), NSFontWeightMedium), heading(N(@"All"), NSFontWeightMedium),
            heading(N(@"Labels"), NSFontWeightMedium)
        ]];
        std::vector<NSInteger> sections;
        std::map<std::string, std::vector<NSInteger>> groupRows;  // a group's rows in the grid
        std::string group = "areas";
        for (const LayerUi &l : kLayerUi) {
            mw.show[l.id] = l.showKey ? box(saved[l.id].show, @"show", l, l.showTip, l.id == kLayerSpots ? N(@"Show %@") : N(@"Show worked %@")) : nil;
            mw.overlay[l.id] = box(saved[l.id].overlay, @"overlay", l, l.overlayTip, N(@"Overlay %@"));
            mw.labels[l.id] = box(saved[l.id].labels, @"labels", l, l.labelsTip, N(@"Labels for %@"));
            if (l.id == kLayerSpots) continue;
            if (l.id == kLayerPota || l.id == kLayerCities) {
                if (l.id == kLayerCities)  // the programs' last row: the others
                    groupRows[group].push_back((NSInteger)layerRows.count),
                        [layerRows addObject:@[ mw.programs, mw.otherBox, [NSGridCell emptyContentView], [NSGridCell emptyContentView] ]];
                group = l.id == kLayerPota ? "programs" : "places";
                sections.push_back((NSInteger)layerRows.count);
                [layerRows addObject:@[
                    groupHead(ADIFString(group), l.id == kLayerPota ? N(@"Programs") : N(@"Places")), [NSGridCell emptyContentView],
                    [NSGridCell emptyContentView], [NSGridCell emptyContentView]
                ]];
            }
            groupRows[group].push_back((NSInteger)layerRows.count);
            NSTextField *name = ADIFLabel(l.title);
            name.menu = [[NSMenu alloc] initWithTitle:[@"layer:" stringByAppendingString:l.ident]];  // filled by the list's menu delegate
            name.toolTip = T(@"Right-click for this layer's menu: its boxes, this layer only, the shading");
            name.identifier = [@"map.layername." stringByAppendingString:l.ident];
            [mw.layerMenus addObject:name.menu];
            [layerRows addObject:@[ name, mw.show[l.id] ?: [NSGridCell emptyContentView], mw.overlay[l.id], mw.labels[l.id] ]];
        }
        NSGridView *layers = [NSGridView gridViewWithViews:layerRows];
        for (const auto &[name, rowsOf] : groupRows) {
            NSMutableArray *parts = [NSMutableArray array];
            for (NSInteger r : rowsOf) [parts addObject:[layers rowAtIndex:r]];
            mw.layerGroups[ADIFString(name)] = parts;
        }
        layers.rowSpacing = 3;
        layers.columnSpacing = 12;
        for (NSInteger c = 1; c < layers.numberOfColumns; ++c) [layers columnAtIndex:c].xPlacement = NSGridCellPlacementCenter;
        for (NSInteger r = 0; r < layers.numberOfRows; ++r) [layers rowAtIndex:r].yPlacement = NSGridCellPlacementCenter;
        [layers rowAtIndex:0].bottomPadding = 2;
        for (NSInteger r : sections) {
            [layers mergeCellsInHorizontalRange:NSMakeRange(0, 4) verticalRange:NSMakeRange(r, 1)];
            [layers rowAtIndex:r].topPadding = 7;
            [layers rowAtIndex:r].bottomPadding = 2;
        }
        layers.identifier = @"map.layers";
        mw.show[kLayerSpots].title = T(@"Show");
        mw.overlay[kLayerSpots].title = T(@"Spotter lines");
        mw.labels[kLayerSpots].title = T(@"Labels");
        labelsFollow();
        for (const LayerUi &l : kLayerUi) {
            MapLayerId id = l.id;
            if (mw.show[id]) ADIFOnAction(mw.show[id], ^{ layerChanged(id, 0); });
            ADIFOnAction(mw.overlay[id], ^{ layerChanged(id, 1); });
            ADIFOnAction(mw.labels[id], ^{ layerChanged(id, 2); });
        }
        // Markers, and how to colour them.
        mw.contacts = ADIFCheckbox(@"QSO markers", flag("mapContacts", false));
        mw.contacts.identifier = @"map.contacts";
        mw.contacts.toolTip = T(@"A marker at each contact's own place: its LAT and LON, else a GRIDSQUARE of 6 or 8 characters (a 4-character "
                              @"square is 100 km or more across: Show grid squares shows those). Style Options chooses pins, dots or crosshairs");
        mw.lines = ADIFCheckbox(@"Contact paths", flag("mapPaths", false));
        mw.lines.identifier = @"map.lines";
        mw.lines.toolTip = T(@"A great-circle line from your station to each contact, in its marker's colour; Style Options chooses their look");
        mw.mine = ADIFCheckbox(@"Home station", flag("mapMine", true));
        mw.mine.identifier = @"map.mine";
        mw.mine.toolTip = T(@"A star at each MY_GRIDSQUARE in the log");
        mw.colorBy = ADIFPopup(@[ @"Colour by confirmation", @"Colour by band", @"Colour by mode", @"Colour by QSO count",
                                  @"Colour by year first worked" ]);
        [mw.colorBy selectItemAtIndex:number("mapColorBy", 0, 4)];
        mw.colorBy.toolTip = T(@"How the map colours what you worked (squares, countries, areas, parks), the contacts and the spots");
        // Filters: which QSOs.
        mw.band = ADIFPopup(@[ @"All bands" ]);
        mw.mode = ADIFPopup(@[ @"All modes" ]);
        for (NSPopUpButton *p in @[ mw.band, mw.mode ]) {  // "Band: 20m" while it filters
            NSMenu *items = p.menu;
            ADIFPrefixPopUpCell *c = [[ADIFPrefixPopUpCell alloc] initTextCell:@"" pullsDown:NO];
            p.cell = c;
            c.menu = items;
            c.prefix = p == mw.band ? T(@"Band:") : T(@"Mode:");
            [c selectItemAtIndex:0];
        }
        // Live's spot filters, in the toolbar too: how new, from which source.
        mw.spotAgeBar = ADIFPopup(@[ @"Last 10 minutes", @"Last 30 minutes", @"Last hour" ]);
        mw.spotAgeBar.identifier = @"map.filter.age";
        mw.spotAgeBar.toolTip = T(@"How new the spots are (as in Sources and Filters)");
        ADIFOnAction(mw.spotAgeBar, ^{
            setSetting("mapSpotsAge", std::to_string(mw.spotAgeBar.indexOfSelectedItem));
            if (mw.spotAge) [mw.spotAge selectItemAtIndex:mw.spotAgeBar.indexOfSelectedItem];
            refreshSpots();
        });
        mw.dxccBar = ADIFPopup(@[ @"Any DXCC", @"Needed on its band", @"New DXCC", @"New band", @"New mode", @"Worked before" ]);
        mw.potaBar = ADIFPopup(@[ @"Any program", @"POTA only", @"New POTA parks", @"Plain DX only" ]);
        for (NSPopUpButton *p in @[ mw.dxccBar, mw.potaBar ]) {  // "DXCC: New band", "Spots: POTA only" while they filter (before
                                                                  // their actions: a control's action is its cell's)
            NSMenu *items = p.menu;
            ADIFPrefixPopUpCell *c = [[ADIFPrefixPopUpCell alloc] initTextCell:@"" pullsDown:NO];
            p.cell = c;
            c.menu = items;
            c.prefix = p == mw.dxccBar ? T(@"DXCC:") : T(@"Spots:");
            [c selectItemAtIndex:0];
        }
        mw.dxccBar.identifier = @"map.filter.dxccNeed";
        mw.dxccBar.toolTip = T(@"The spots by what they mean for your DXCC (the Quick Views have them too)");
        ADIFOnAction(mw.dxccBar, ^{
            static const int kLens[] = {0, 1, 2, 3, 4, 8};
            NSInteger i = std::clamp<NSInteger>(mw.dxccBar.indexOfSelectedItem, 0, 5);
            chooseQuickView(kLens[i]);
        });
        mw.potaBar.identifier = @"map.filter.pota";
        mw.potaBar.toolTip = T(@"POTA's spots: all of them with the rest, only POTA's, only parks you haven't worked, or none (plain DX spots, "
                               @"no program); as Sources and Filters' program");
        ADIFOnAction(mw.potaBar, ^{
            NSInteger i = mw.potaBar.indexOfSelectedItem;
            setSetting("mapSpotsProgram", i == 1 || i == 2 ? "POTA" : i == 3 ? "-" : "");
            fillSpotsPopover();
            if (i == 2) chooseQuickView(5);  // New POTA parks
            else if (mw.spotLens == 5 || mw.spotLens == 6) chooseQuickView(0);
            else refreshSpots();
        });
        mw.spotSourceBar = ADIFPopup(@[ @"All sources" ]);
        for (adif::SpotSource src : kSpotSources) [mw.spotSourceBar addItemWithTitle:ADIFString(tr(adif::spotSourceName(src)))];
        mw.spotSourceBar.identifier = @"map.filter.source";
        mw.spotSourceBar.toolTip = T(@"Which source's spots show: all, or one of them (Sources and Filters can choose two)");
        ADIFOnAction(mw.spotSourceBar, ^{
            NSInteger i = mw.spotSourceBar.indexOfSelectedItem;
            if (i < 0 || i > 3) return;  // "2 sources": as Sources and Filters left them
            std::string hidden;
            for (size_t k = 0; k < 3 && i > 0; ++k)
                if ((NSInteger)k != i - 1) hidden += std::string(hidden.empty() ? "" : ",") + adif::spotSourceName(kSpotSources[k]);
            setSetting("mapSpotsHidden", hidden);
            fillSpotsPopover();
            refreshSpots();
        });
        mw.dates = ADIFPopup(@[ @"All dates", @"Last 30 days", @"Last 12 months", @"This year" ]);
        mw.confirmed = ADIFPopup(@[ @"All QSOs", @"Confirmed", @"Not confirmed", @"Confirmed on LoTW", @"Confirmed by eQSL", @"Confirmed by card",
                                    @"Not confirmed on LoTW" ]);
        mw.confirmed.toolTip = T(@"Confirmed by any of card (QSL_RCVD), LoTW or eQSL, or by one of them; or not");
        mw.confirmed.identifier = @"map.filter.confirmed";
        // Zoom, projection, style.
        mw.projection = ADIFPopup(@[ @"Equirectangular", @"Mercator", @"Equal Earth", @"Globe" ]);
        mw.projection.autoenablesItems = NO;
        mw.projection.toolTip = T(@"Equirectangular: the grid as rectangles. Mercator: familiar shapes. Equal Earth: true sizes. Globe: the Earth "
                                @"as seen from space, centred on your grid; drag (or the arrow keys) to turn it any way, zoom in for detail, "
                                @"World to come home. Bearings from the centre are true (beam headings)");
        NSButton *styleButton = smallButton(@"Style Options...", @"Colours, markers, how worked areas are shaded, lines to contacts, the legend, "
                                                                 @"distance rings, day and night, the grey line",
                                            ^{ showStyleOptions(); });
        styleButton.identifier = @"map.style.open";
        mw.region = pullDown(@"Region", @"Zoom to a continent (on the globe, turn to face it)");
        mw.region.identifier = @"map.region";
        {
            // Continents as ADIF's CONT names them, each a box of longitude and latitude to show.
            struct Box {
                NSString *name;
                double w, s, e, n;
            };
            static const Box kRegions[] = {{N(@"Africa"), -20, -36, 53, 38},           {N(@"Antarctica"), -180, -90, 180, -60},
                                           {N(@"Asia"), 25, -11, 180, 78},             {N(@"Europe"), -25, 34, 45, 72},
                                           {N(@"North America"), -170, 5, -50, 75},    {N(@"Oceania"), 110, -48, 180, 0},
                                           {N(@"South America"), -82, -56, -34, 13}};
            for (const Box &b : kRegions) {
                NSMenuItem *item = [mw.region.menu addItemWithTitle:T(b.name) action:nil keyEquivalent:@""];
                Box rbox = b;
                ADIFBlockMenuItem(item, ^{ [mw.view showWest:rbox.w south:rbox.s east:rbox.e north:rbox.n]; });
            }
        }
        for (NSControl *c in @[ mw.contacts, mw.band, mw.mode, mw.dates, mw.confirmed ]) ADIFOnAction(c, ^{
            saveFlag("mapContacts", mw.contacts.state == NSControlStateValueOn);
            if (c == mw.dates && mw.dates.indexOfSelectedItem == 4) showDateRange();
            if (c == mw.confirmed && mw.viewSetConfirmed) {  // your own choice now, not Needs confirmation's
                mw.viewSetConfirmed = false;
                setSetting("mapQuickView", "-1");
            }
            refresh();
        });
        for (NSButton *b in @[ mw.lines, mw.mine ]) ADIFOnAction(b, ^{
            saveFlag("mapPaths", mw.lines.state == NSControlStateValueOn);
            saveFlag("mapMine", mw.mine.state == NSControlStateValueOn);
            applyStyle();
            fillStyle();
        });
        ADIFOnAction(mw.colorBy, ^{
            setSetting("mapColorBy", std::to_string(mw.colorBy.indexOfSelectedItem));
            applyStyle();
        });
        ADIFOnAction(mw.projection, ^{
            setSetting("mapProjection", std::to_string(mw.projection.indexOfSelectedItem));
            applyProjection();
        });
        mw.zoomLabel = ADIFLabel(@"1.0×");
        [mw.zoomLabel.widthAnchor constraintEqualToConstant:42].active = YES;  // up to "16384×" (Map Detail)
        NSButton *out = smallButton(@"−", @"Zoom out (−)", ^{ [mw.view zoomBy:1 / 1.5]; });
        NSButton *in = smallButton(@"+", @"Zoom in (+, or double-click the map)", ^{ [mw.view zoomBy:1.5]; });
        NSButton *fit = smallButton(@"Fit Log", @"Zoom to the log's QSOs (in Live, to the spots shown)", ^{
            if (live()) [mw.view fitSpots];
            else [mw.view fitLog];
        });
        NSButton *home = smallButton(@"Home", @"Your station in the middle of the map, at the zoom it has (Settings, Your Station's grid); or "
                                              @"the Home view you set (right-click: Set Home View)",
                                     ^{ goHomeView(); });
        home.identifier = @"map.home";
        mw.homeMenu = [[NSMenu alloc] init];  // filled by the list's menu delegate, made below
        home.menu = mw.homeMenu;
        NSButton *world = smallButton(@"World", @"The whole world (0)", ^{ [mw.view showWorld]; });
        NSButton *save = smallButton(@"Export PNG...", @"Save the map as it is shown now, with its legend", ^{ exportPng(); });
        mw.spotsButton = smallButton(@"Sources and Filters...", @"The spots the Spots layer shows: how new, from which sources, which program; and what the "
                                                  @"sources are doing", ^{ showSpotsPopover(); });
        mw.spotsButton.identifier = @"map.spots.open";
        // Refresh: the feeds asked again now, within their limits; what each did goes to the status line.
        mw.refreshSpotsButton = smallButton(@"Refresh Spots", @"Refresh the spots now: Spothole is asked again (at most once a minute), PSKReporter once its "
                                                 @"5 minutes have passed, and a DX cluster waiting to reconnect connects",
                                            ^{
                                                setStatus(spotfeeds::refreshNow());
                                                refreshSpots();
                                            });
        mw.refreshSpotsButton.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:T(@"Refresh Spots")];
        mw.refreshSpotsButton.title = @"";  // the icon only; its name for VoiceOver below
        mw.refreshSpotsButton.imagePosition = NSImageOnly;
        mw.refreshSpotsButton.accessibilityLabel = T(@"Refresh Spots");
        mw.refreshSpotsButton.identifier = @"map.spots.refresh";
        mw.refreshSpotsButton.enabled = NO;
        mw.watchEdit = smallButton(@"Watch List...", @"The calls, references and DXCC entities you watch for: when one is spotted, it shows in My "
                                                     @"watch list, first among the spots, and under the bell",
                                   ^{ showWatchList(mw.watchEdit); });
        mw.watchEdit.image = [NSImage imageWithSystemSymbolName:@"star" accessibilityDescription:nil];
        mw.watchEdit.imagePosition = NSImageLeading;
        mw.watchEdit.identifier = @"map.watch.edit";
        // Spots: their filters, Refresh, and one station's spots only (who heard it, as on PSKReporter's map).
        mw.spotsOnly = ADIFCheckbox(@"Only spots of", flag("mapSpotsOnly", false));
        mw.spotsOnly.toolTip = T(@"Show only this station's spots, each with every station that heard it: who is hearing you, as on PSKReporter's "
                                 @"map. PSKReporter is asked about this callsign while it is ticked");
        mw.spotsOnly.identifier = @"map.spots.only";
        mw.spotsOnlyCall = [NSTextField textFieldWithString:ADIFString(setting("mapSpotsOnlyCall"))];
        mw.spotsOnlyCall.placeholderString = setting("stationCall").empty() ? T(@"callsign") : ADIFString(setting("stationCall"));
        mw.spotsOnlyCall.toolTip = T(@"The station whose spots to show; empty: your callsign (Your Station)");
        mw.spotsOnlyCall.identifier = @"map.spots.onlyCall";
        ((NSTextFieldCell *)mw.spotsOnlyCall.cell).sendsActionOnEndEditing = YES;
        [mw.spotsOnlyCall.widthAnchor constraintEqualToConstant:110].active = YES;
        ADIFOnAction(mw.spotsOnly, ^{
            saveFlag("mapSpotsOnly", mw.spotsOnly.state == NSControlStateValueOn);
            refreshSpots();
        });
        ADIFOnAction(mw.spotsOnlyCall, ^{
            NSString *call = [[mw.spotsOnlyCall.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString];
            mw.spotsOnlyCall.stringValue = call;
            setSetting("mapSpotsOnlyCall", ADIFStd(call));
            if (call.length && mw.spotsOnly.state != NSControlStateValueOn) {  // a callsign typed: ticked too
                mw.spotsOnly.state = NSControlStateValueOn;
                saveFlag("mapSpotsOnly", true);
            }
            refreshSpots();
        });
        // POTA parks in: the park filter (which parks you haven't worked show), beside the spots.
        mw.parkPlacesButton = smallButton(@"everywhere", @"Which POTA parks you haven't worked show, on the map and in the list beside it: "
                                                         @"those in the POTA locations and US counties you choose (at first, your station's)",
                                          ^{ showParkPlaces(); });
        mw.parkPlacesButton.identifier = @"map.parkplaces.open";
        NSTextField *parksIn = ADIFLabel(@"POTA parks in:");
        mw.moreFilters = smallButton(@"More Filters...", @"Keep the QSOs in chosen places: continents, countries, zones, US states, counties and "
                                                          @"regions, POTA locations", ^{ showMoreFilters(); });
        mw.moreFilters.identifier = @"map.filter.more";
        mw.clearFilters = smallButton(@"Clear", @"Show every QSO again: all bands, modes, dates and places (and in Live, every spot)", ^{
            for (NSPopUpButton *p in @[ mw.band, mw.mode, mw.dates, mw.confirmed ]) [p selectItemAtIndex:0];
            if (live()) {  // every spot again: any program and source too
                setSetting("mapSpotsProgram", "");
                setSetting("mapSpotsHidden", "");
                fillSpotsPopover();
                if (mw.spotLens > 0) chooseQuickView(0);
                else refreshSpots();
            }
            if (mw.viewSetConfirmed) {  // Needs confirmation's filter gone: All QSOs
                mw.viewSetConfirmed = false;
                setSetting("mapQuickView", "0");
            }
            for (const char *key : {"mapFilterContinents", "mapFilterDxcc", "mapFilterCq", "mapFilterItu", "mapFilterStates", "mapFilterCounties",
                                    "mapFilterRegions", "mapFilterPota", "mapFilterWithinKm", "mapFilterRecords"})
                setSetting(key, "");
            if (mw.filterPopover) fillPlaceControls();
            refresh();
        });
        mw.clearFilters.identifier = @"map.filter.clear";
        // The list under the map: the QSOs of what you click, or the contacts, parks or spots in view.
        mw.listPanel = [[NSView alloc] initWithFrame:NSZeroRect];
        mw.listPanel.identifier = @"map.list";
        mw.listKind = [NSSegmentedControl segmentedControlWithLabels:@[ T(@"Selected"), T(@"Contacts"), T(@"Parks"), T(@"Spots"), T(@"Recent"), T(@"Issues"), T(@"DXCC") ]
                                                         trackingMode:NSSegmentSwitchTrackingSelectOne
                                                               target:nil
                                                               action:nil];
        mw.listKind.selectedSegment = number("mapListKind", 0, kListKinds - 1);
        mw.listKind.toolTip = T(@"What the list shows: the QSOs of what you clicked on the map; the contacts (QSOs with a grid or a place), the POTA "
                                @"parks or the spots in view; the log's QSOs, the newest first; Check Log's problems in them; or the DXCC "
                                @"entities worked, by band and mode");
        mw.listKind.identifier = @"map.list.kind";
        ADIFOnAction(mw.listKind, ^{
            mw.markedDxcc = 0;
            mw.listBackKind = -1;
            setSetting("mapListKind", std::to_string(mw.listKind.selectedSegment));
            fillViewList();
        });
        mw.listTitle = ADIFLabel(@"Parks in View");
        mw.listTitle.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
        mw.listTitle.lineBreakMode = NSLineBreakByTruncatingTail;
        mw.listTitle.identifier = @"map.list.title";
        mw.listTitle.hidden = YES;  // the tabs say what they list, and how many
        [mw.listTitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        mw.listUnits = [NSSegmentedControl segmentedControlWithLabels:@[ @"mi", @"km" ] trackingMode:NSSegmentSwitchTrackingSelectOne target:nil
                                                               action:nil];
        mw.listUnits.controlSize = NSControlSizeSmall;
        mw.listUnits.selectedSegment = setting("mapListUnits") == "mi" ? 0 : 1;
        mw.listUnits.toolTip = T(@"Distances in miles or kilometres");
        mw.listUnits.identifier = @"map.list.units";
        ADIFOnAction(mw.listUnits, ^{
            setSetting("mapListUnits", mw.listUnits.selectedSegment == 0 ? "mi" : "km");
            mw.view.scaleInMiles = mw.listUnits.selectedSegment == 0;  // the map's distance scale too
            mw.view.needsDisplay = YES;
            fillViewList();
        });
        mw.listFrom = ADIFPopup(@[ @"Your station", @"Map centre", @"Grid square:" ]);
        mw.listFrom.controlSize = NSControlSizeSmall;
        mw.listFrom.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.listFrom.autoenablesItems = NO;
        [mw.listFrom selectItemAtIndex:number("mapListFrom", 0, 2)];
        mw.listFrom.toolTip = T(@"Where the distances and bearings are from, and so what comes first: your station's grid (Settings, Your "
                                @"Station), the middle of the map, or a grid square you type");
        mw.listFrom.identifier = @"map.list.from";
        mw.listGrid = [NSTextField textFieldWithString:ADIFString(setting("mapListGrid"))];
        mw.listGrid.placeholderString = @"EN50";
        mw.listGrid.toolTip = T(@"A grid square of 4, 6 or 8 characters");
        mw.listGrid.identifier = @"map.list.grid";
        ((NSTextFieldCell *)mw.listGrid.cell).sendsActionOnEndEditing = YES;
        [mw.listGrid.widthAnchor constraintEqualToConstant:76].active = YES;
        ADIFOnAction(mw.listFrom, ^{
            setSetting("mapListFrom", std::to_string(mw.listFrom.indexOfSelectedItem));
            fillViewList();
            if (mw.listFrom.indexOfSelectedItem == 2 && !mw.listGrid.stringValue.length) [mw.window makeFirstResponder:mw.listGrid];
        });
        ADIFOnAction(mw.listGrid, ^{
            mw.listGrid.stringValue = [mw.listGrid.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            setSetting("mapListGrid", ADIFStd(mw.listGrid.stringValue));
            fillViewList();
        });
        mw.listRows = [[ADIFViewList alloc] init];
        mw.listRows.onChoose = ^(const ADIFViewRow &r) {
            if (r.hit.kind == ADIFMapHit::None) return;  // a QSO chosen: double-click goes to it
            mw.choosingFromList = true;
            [mw.view selectHit:r.hit];
            mw.choosingFromList = false;
        };
        mw.listRows.text = ^NSString *(const ADIFViewRow &r, const std::string &column) {
            int kind = (int)mw.listKind.selectedSegment;
            std::string text = cellText(kind, r, column);
            if (column == "country" || column == "entity") text = flagged(cellDxcc(kind, r), text);  // shown, not sorted or searched by
            return ADIFString(text);
        };
        mw.listRows.onSort = ^{
            NSSortDescriptor *d = mw.listTable.sortDescriptors.firstObject;
            if (!d) return;
            int kind = (int)mw.listKind.selectedSegment;
            setSetting(listKey("mapListSort", kind).c_str(), std::string(d.ascending ? "" : "-") + ADIFStd(d.key));
            mw.listPage[kind] = 0;
            fillViewList();
        };
        mw.listRows.onColumnsChanged = ^{ saveListColumns(); };
        mw.listRows.onOpen = ^(const ADIFViewRow &r) { openRow(r); };
        mw.listTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
        mw.listTable.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;  // each column as wide as it was left; scroll for more
        mw.listTable.style = NSTableViewStylePlain;
        mw.listTable.allowsColumnReordering = YES;
        mw.listTable.headerView.menu = [[NSMenu alloc] init];  // right-click a title: which columns show
        mw.listTable.headerView.menu.delegate = mw.listRows;
        mw.listTable.intercellSpacing = NSMakeSize(4, 2);
        mw.listTable.dataSource = mw.listRows;
        mw.listTable.delegate = mw.listRows;
        mw.listTable.target = mw.listRows;
        mw.listTable.doubleAction = @selector(opened:);
        mw.listTable.usesAlternatingRowBackgroundColors = YES;
        mw.listTable.allowsEmptySelection = YES;
        mw.listTable.identifier = @"map.list.table";
        mw.listTable.accessibilityLabel = T(@"List");
        NSScrollView *listScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        listScroll.documentView = mw.listTable;
        listScroll.hasVerticalScroller = YES;
        listScroll.hasHorizontalScroller = YES;
        listScroll.autohidesScrollers = YES;
        listScroll.borderType = NSBezelBorder;
        mw.listHint = [NSTextField labelWithString:@""];  // one line in the list's footer; all of it as its tooltip
        mw.listHint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.listHint.textColor = NSColor.secondaryLabelColor;
        mw.listHint.lineBreakMode = NSLineBreakByTruncatingTail;
        [mw.listHint setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        mw.listHint.identifier = @"map.list.hint";
        mw.view = [[ADIFMapView alloc] initWithFrame:NSZeroRect];
        mw.view.onHover = ^(const ADIFMapHit &h) {  // what's under the pointer, in the footer; else how to use the map
            std::string d = describe(h);
            showHover(d.empty() ? idleStatus() : d);
        };
        mw.view.onSelect = ^(const ADIFMapHit &h) { selected(h); };
        ((ADIFMapWindow *)mw.window).shortcut = ^BOOL(NSEvent *e) { return mapShortcut(e); };
        mw.view.onStep = ^(int by) { stepList(by); };
        mw.view.onReturn = ^{  // a spot: New QSO; one QSO: its record
            ADIFMapHit h = mw.view.selectedHit;
            if (h.kind == ADIFMapHit::Spot) useSelectedSpot();
            else if (mw.listed.size() == 1) goToQso(mw.listed[0]);
        };
        [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                                                                    object:nil
                                                                     queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(NSNotification *) {  // Increase contrast: the faint text again
                                                                    labelsFollow();
                                                                    refresh();
                                                                }];
        // A legend entry clicked: another program's references (as Other programs' menu), or a kind
        // or band of spots, off or on.
        mw.view.onLegendToggle = ^(const std::string &id) {
            if (id.rfind("program.", 0) == 0) {
                std::set<std::string> h = hiddenPrograms();
                if (!h.erase(id.substr(8))) h.insert(id.substr(8));
                saveHidden(h);
                applyStyle();
                fillPrograms();
                return;
            }
            std::vector<std::string> off = splitSetting("mapLegendHidden", ',');
            auto at = std::find(off.begin(), off.end(), id);
            if (at != off.end()) off.erase(at);
            else off.push_back(id);
            std::string v;
            for (const std::string &o : off) v += (v.empty() ? "" : ",") + o;
            setSetting("mapLegendHidden", v);
            applyStyle();
            refreshSpots();
        };
        mw.view.onViewChanged = ^{
            updateZoomLabel();
            queueViewList();
        };
        mw.status = [NSTextField wrappingLabelWithString:@""];
        mw.status.identifier = @"map.status";
        mw.status.maximumNumberOfLines = 16;
        mw.status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.useSpot = smallButton(@"New QSO", @"Fill New QSO with the spot chosen on the map: its call, frequency, band, mode and reference",
                                 ^{ useSelectedSpot(); });
        mw.useSpot.image = [NSImage imageWithSystemSymbolName:@"plus.circle" accessibilityDescription:nil];
        mw.useSpot.imagePosition = NSImageLeading;
        mw.useSpot.bezelColor = NSColor.systemGreenColor;
        mw.useSpot.keyEquivalent = @"";
        mw.useSpot.identifier = @"map.spots.use";
        mw.useSpot.toolTip = [mw.useSpot.toolTip stringByAppendingString:@"  (\u2318\u21A9)"];
        mw.useSpot.hidden = YES;
        // The list's footer: the page (with the previous and next), how many a page, the columns.
        mw.listPrev = smallButton(@"", @"The previous page", ^{
            int kind = (int)mw.listKind.selectedSegment;
            if (mw.listPage[kind] > 0) --mw.listPage[kind];
            fillViewList();
        });
        mw.listPrev.image = [NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:T(@"Previous Page")];
        mw.listPrev.imagePosition = NSImageOnly;
        mw.listPrev.identifier = @"map.list.prev";
        mw.listNext = smallButton(@"", @"The next page", ^{
            ++mw.listPage[mw.listKind.selectedSegment];
            fillViewList();
        });
        mw.listNext.image = [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:T(@"Next Page")];
        mw.listNext.imagePosition = NSImageOnly;
        mw.listNext.identifier = @"map.list.next";
        mw.listPageLabel = ADIFLabel(@"");
        mw.listPageLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        mw.listPageLabel.identifier = @"map.list.page";
        mw.listPageSize = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for (int n : {25, 50, 100, 250, 500}) [mw.listPageSize.menu addItemWithTitle:TF(@"{n} a page", @{@"n" : @(n)}) action:nil keyEquivalent:@""].tag = n;
        if (![mw.listPageSize selectItemWithTag:std::atoi(setting("mapListPageSize").c_str())]) [mw.listPageSize selectItemWithTag:50];
        mw.listPageSize.controlSize = NSControlSizeSmall;
        mw.listPageSize.toolTip = T(@"How many rows a page shows");
        mw.listPageSize.identifier = @"map.list.pagesize";
        ADIFOnAction(mw.listPageSize, ^{
            setSetting("mapListPageSize", std::to_string(mw.listPageSize.selectedTag));
            for (size_t &page : mw.listPage) page = 0;
            fillViewList();
        });
        mw.listColumnsMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
        [mw.listColumnsMenu addItemWithTitle:T(@"Columns")];
        mw.listColumnsMenu.controlSize = NSControlSizeSmall;
        mw.listColumnsMenu.toolTip = T(@"Which columns show (also: right-click a column's title); drag a title to move its column, its edge to size it");
        mw.listColumnsMenu.identifier = @"map.list.columns";
        mw.listColumnsMenu.menu.delegate = mw.listRows;
        {
            // Both menus fill themselves as they open: the Columns button's under its own title.
            NSMenu *columnsMenu = mw.listColumnsMenu.menu;
            mw.listRowMenu = [[NSMenu alloc] init];
            mw.listRowMenu.delegate = mw.listRows;
            mw.listTable.menu = mw.listRowMenu;
            mw.listRows.fillMenu = ^(NSMenu *menu) {
                if (menu == mw.listRowMenu) fillRowMenu(menu);
                else if (menu == mw.bellMenu) fillBellMenu(menu);
                else if (menu == mw.homeMenu) fillHomeMenu(menu);
                else if (menu == mw.findMenu) fillFindMenu(menu);
                else if (menu == mw.viewsMenu) fillViewsMenu(menu);
                else if ([menu.title hasPrefix:@"layer:"]) fillLayerMenu(menu);
                else fillColumnsMenu(menu, menu == columnsMenu);
            };
            mw.homeMenu.delegate = mw.listRows;
            for (NSMenu *m in mw.layerMenus) m.delegate = mw.listRows;
        }
        mw.listSearch = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        mw.listSearch.placeholderString = T(@"Search: a call, reference, name...");
        mw.listSearch.toolTip = T(@"Keep the rows with this in any column shown (or in the call, reference, name, park, country or grid)");
        mw.listSearch.identifier = @"map.list.search";
        mw.listSearch.controlSize = NSControlSizeSmall;
        mw.listSearch.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        [mw.listSearch setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        ADIFOnAction(mw.listSearch, ^{
            mw.listPage[mw.listKind.selectedSegment] = 0;
            fillViewList();
        });
        mw.listWithin = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [mw.listWithin addItemWithTitle:T(@"Any distance")];
        for (int n : {10, 25, 50, 100, 250, 500, 1000}) [mw.listWithin.menu addItemWithTitle:@"" action:nil keyEquivalent:@""].tag = n;
        if (![mw.listWithin selectItemWithTag:std::atoi(setting("mapListWithin").c_str())]) [mw.listWithin selectItemAtIndex:0];
        mw.listWithin.controlSize = NSControlSizeSmall;
        mw.listWithin.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.listWithin.toolTip = T(@"Keep the rows within this distance of where the list measures from (Nearest to)");
        mw.listWithin.identifier = @"map.list.within";
        for (NSMenuItem *item in mw.listWithin.itemArray)  // titled now; again by the list, as the units change
            if (item.tag > 0) item.title = TF(setting("mapListUnits") == "mi" ? @"Within {n} mi" : @"Within {n} km", @{@"n" : @(item.tag)});
        ADIFOnAction(mw.listWithin, ^{
            setSetting("mapListWithin", std::to_string(mw.listWithin.selectedTag));
            for (size_t &page : mw.listPage) page = 0;
            fillViewList();
        });
        // Across its top: what it lists and its title, then the search and the distance; under the
        // table: the pages, where it measures from, the hint, how many a page and the columns.
        NSStackView *listTop = [[NSStackView alloc] initWithFrame:NSZeroRect];
        listTop.spacing = 8;
        listTop.identifier = @"map.list.top";
        for (NSView *v in @[ mw.listKind, mw.listTitle ]) [listTop addView:v inGravity:NSStackViewGravityLeading];
        mw.listSortMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        mw.listSortMenu.controlSize = NSControlSizeSmall;
        mw.listSortMenu.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.listSortMenu.toolTip = T(@"How the list is sorted (click a column's title to sort by it)");
        mw.listSortMenu.identifier = @"map.list.sort";
        ADIFOnAction(mw.listSortMenu, ^{
            int kind = (int)mw.listKind.selectedSegment;
            NSInteger i = mw.listSortMenu.indexOfSelectedItem;
            const std::vector<SortChoice> &choices = sortChoices(kind);
            if (i < 0 || (size_t)i >= choices.size()) return;
            setSetting(listKey("mapListSort", kind).c_str(), std::string(choices[(size_t)i].ascending ? "" : "-") + choices[(size_t)i].id);
            mw.listRows.building = YES;  // the column titles show it too; not a click on one
            mw.listTable.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:ADIFString(choices[(size_t)i].id) ascending:choices[(size_t)i].ascending] ];
            mw.listRows.building = NO;
            mw.listPage[kind] = 0;
            fillViewList();
        });
        [mw.listSortMenu setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh + 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        for (NSView *v in @[ mw.listSortMenu, mw.listSearch ]) [listTop addView:v inGravity:NSStackViewGravityTrailing];
        mw.listTop = listTop;
        listTop.detachesHiddenViews = YES;
        mw.listBack = [NSButton buttonWithTitle:@"" target:nil action:nil];
        mw.listBack.bordered = NO;
        mw.listBack.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.listBack.contentTintColor = NSColor.linkColor;
        mw.listBack.toolTip = T(@"A click on the map showed its QSOs here; back to what the list showed");
        mw.listBack.identifier = @"map.list.back";
        mw.listBack.hidden = YES;
        ADIFOnAction(mw.listBack, ^{
            int kind = mw.listBackKind;
            mw.listBackKind = -1;
            if (kind > 0 && kind < kListKinds) showListKind(kind);
        });
        [listTop insertView:mw.listBack atIndex:1 inGravity:NSStackViewGravityLeading];
        mw.listKind.controlSize = NSControlSizeSmall;
        mw.listKind.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        [mw.listKind setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSLayoutConstraint *searchWidth = [mw.listSearch.widthAnchor constraintEqualToConstant:220];
        searchWidth.priority = NSLayoutPriorityDefaultLow - 1;  // the tabs whole first
        searchWidth.active = YES;
        [mw.listSearch.widthAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;
        [mw.listWithin setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh + 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *listFooter = [[NSStackView alloc] initWithFrame:NSZeroRect];
        listFooter.spacing = 6;
        listFooter.identifier = @"map.list.footer";
        NSTextField *nearestTo = ADIFLabel(@"Nearest to:");
        nearestTo.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        for (NSView *v in @[ mw.listPrev, mw.listPageLabel, mw.listNext, nearestTo, mw.listFrom, mw.listGrid, mw.listUnits, mw.listWithin, mw.listHint ])
            [listFooter addView:v inGravity:NSStackViewGravityLeading];  // how far: beside where from and the units
        [listFooter setCustomSpacing:14 afterView:mw.listNext];
        // In a narrow window "Nearest to" gives way before the page size and the columns.
        [mw.listFrom setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        for (NSView *v in @[ mw.listPageSize, mw.listColumnsMenu ])
            [v setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh + 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [listFooter setCustomSpacing:14 afterView:mw.listUnits];
        for (NSView *v in @[ mw.listPageSize, mw.listColumnsMenu ]) [listFooter addView:v inGravity:NSStackViewGravityTrailing];
        mw.listFooter = listFooter;
        mw.nearestTo = nearestTo;
        listFooter.detachesHiddenViews = YES;
        for (NSView *v in @[ listTop, listScroll, listFooter ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [mw.listPanel addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [listTop.topAnchor constraintEqualToAnchor:mw.listPanel.topAnchor constant:8],
            [listTop.leadingAnchor constraintEqualToAnchor:mw.listPanel.leadingAnchor constant:10],
            [listTop.trailingAnchor constraintEqualToAnchor:mw.listPanel.trailingAnchor constant:-10],
            [listScroll.topAnchor constraintEqualToAnchor:listTop.bottomAnchor constant:6],
            [listScroll.leadingAnchor constraintEqualToAnchor:mw.listPanel.leadingAnchor constant:10],
            [listScroll.trailingAnchor constraintEqualToAnchor:mw.listPanel.trailingAnchor constant:-10],
            [listFooter.topAnchor constraintEqualToAnchor:listScroll.bottomAnchor constant:6],
            [listFooter.leadingAnchor constraintEqualToAnchor:mw.listPanel.leadingAnchor constant:10],
            [listFooter.trailingAnchor constraintEqualToAnchor:mw.listPanel.trailingAnchor constant:-10],
            [listFooter.bottomAnchor constraintEqualToAnchor:mw.listPanel.bottomAnchor constant:-6],
        ]];

        // ── The window: a header (History or Live, the log, Style Options and Export, the panes'
        // buttons); the sidebar (Quick Views, Spots, Layers, Map, Filters); the map over its list;
        // the panel of what was chosen; a footer for what is under the pointer ──
        auto line = [](NSArray<NSView *> *views) {
            NSStackView *r = [NSStackView stackViewWithViews:views];
            r.spacing = 8;
            return r;
        };
        auto rows = [](NSArray<NSView *> *views, CGFloat spacing) {  // one under another, at their own widths
            NSStackView *c = [NSStackView stackViewWithViews:views];
            c.orientation = NSUserInterfaceLayoutOrientationVertical;
            c.alignment = NSLayoutAttributeLeading;
            c.spacing = spacing;
            return c;
        };
        auto caption = [](NSString *text) {
            NSTextField *t = [NSTextField labelWithString:T(text).localizedUppercaseString];
            t.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize - 1 weight:NSFontWeightSemibold];
            t.textColor = NSColor.secondaryLabelColor;
            return t;
        };
        auto iconOnly = [](NSButton *b, NSString *symbol) {  // the title stays, for VoiceOver (and the tests)
            b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
            if (b.image) b.imagePosition = NSImageOnly;
        };
        // The workflows: History, the log; Live, the spots.
        mw.workflow = [NSSegmentedControl segmentedControlWithLabels:@[ T(@"History"), T(@"Live"), T(@"DX Chase"), T(@"POTA") ]
                                                         trackingMode:NSSegmentSwitchTrackingSelectOne
                                                               target:nil
                                                               action:nil];
        [mw.workflow setImage:[NSImage imageWithSystemSymbolName:@"clock.arrow.circlepath" accessibilityDescription:nil] forSegment:0];
        [mw.workflow setImage:[NSImage imageWithSystemSymbolName:@"antenna.radiowaves.left.and.right" accessibilityDescription:nil] forSegment:1];
        [mw.workflow setToolTip:T(@"History: your log on the map, and what it reached on each layer (squares, countries, states, zones, parks), "
                                  @"to look back and plan")
                     forSegment:0];
        [mw.workflow setToolTip:T(@"Live: the stations spotted now, and which of them your log needs (a new DXCC, band, mode or park)")
                     forSegment:1];
        [mw.workflow setImage:[NSImage imageWithSystemSymbolName:@"scope" accessibilityDescription:nil] forSegment:2];
        [mw.workflow setImage:[NSImage imageWithSystemSymbolName:@"leaf" accessibilityDescription:nil] forSegment:3];
        [mw.workflow setToolTip:T(@"DX Chase: Live for the DXCC entities and bands you need: their spots first (Needed on its band), plain DX "
                                  @"spots, the grey line. It keeps its own settings")
                     forSegment:2];
        [mw.workflow setToolTip:T(@"POTA: Live for the parks: the POTA activators spotted, every park with those you worked, no DXCC shading. "
                                  @"It keeps its own settings")
                     forSegment:3];
        mw.workflow.selectedSegment = workflow();
        mw.workflow.identifier = @"map.workflow";
        ADIFOnAction(mw.workflow, ^{ switchWorkflow((int)mw.workflow.selectedSegment); });
        mw.summaryLabel = [NSTextField labelWithString:@""];
        mw.summaryLabel.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
        mw.summaryLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [mw.summaryLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        mw.summaryLabel.identifier = @"map.summary";
        // The panes' buttons: the sidebar, the list, the selected panel.
        NSString *const paneTitles[3] = {N(@"Sidebar"), N(@"List"), N(@"Selected")};
        NSString *const paneSymbols[3] = {@"sidebar.left", @"rectangle.bottomthird.inset.fill", @"sidebar.right"};
        NSString *const paneIds[3] = {@"map.sidebar.toggle", @"map.list.toggle", @"map.selected.toggle"};
        NSString *const paneTips[3] = {
            N(@"Show or hide the sidebar: the Quick Views, the spots, the layers, the map's colours and the filters"),
            N(@"Show or hide the list under the map: the QSOs of what you click, or the contacts, POTA parks or spots in view, with their "
              @"distance and bearing from your station, the map's centre or a grid square"),
            N(@"Show or hide the panel of what you chose on the map (its QSOs, what it means for your log, New QSO), and the situation")};
        for (int i = 0; i < 3; ++i) {
            NSButton *b = [NSButton buttonWithTitle:T(paneTitles[i]) target:nil action:nil];
            [b setButtonType:NSButtonTypePushOnPushOff];
            iconOnly(b, paneSymbols[i]);
            b.toolTip = T(paneTips[i]);
            b.identifier = paneIds[i];
            int pane = i;
            ADIFOnAction(b, ^{ showPane(pane, mw.paneToggle[pane].state == NSControlStateValueOn); });
            mw.paneToggle[i] = b;
        }
        iconOnly(styleButton, @"paintpalette");
        iconOnly(save, @"square.and.arrow.up");
        NSStackView *header = [[NSStackView alloc] initWithFrame:NSZeroRect];
        header.spacing = 12;
        header.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 12);
        header.identifier = @"map.header";
        [header addView:mw.summaryLabel inGravity:NSStackViewGravityLeading];
        NSButton *logTable = smallButton(@"Log Table", @"The log as a table: sort, search and edit its QSOs", ^{ logtools::cmdLogTable(); });
        iconOnly(logTable, @"tablecells");
        logTable.identifier = @"map.logtable";
        NSButton *settings = smallButton(@"Settings", @"ADIF Lint's Settings: your station, the spot sources, park and map data", ^{ openSettings(-1); });
        iconOnly(settings, @"gearshape");
        settings.identifier = @"map.settings";
        NSButton *help = smallButton(@"Help", @"The user guide's Map section, in your browser", ^{
            ADIFOpenURL(@"https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/blob/main/docs/USER_GUIDE.md#map");
        });
        iconOnly(help, @"questionmark.circle");
        help.identifier = @"map.help";
        // The bell: the stations on your watch list spotted now, in a menu.
        mw.bell = [NSButton buttonWithTitle:@"" target:nil action:nil];
        mw.bell.identifier = @"map.bell";
        mw.bell.accessibilityLabel = T(@"Watch list alerts");
        mw.bellMenu = [[NSMenu alloc] init];
        mw.bellMenu.delegate = mw.listRows;
        mw.bell.menu = mw.bellMenu;  // right-click too
        ADIFOnAction(mw.bell, ^{ [mw.bellMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(mw.bell.bounds) + 4) inView:mw.bell]; });
        fillBell();
        mw.synced = [NSButton buttonWithTitle:@"" target:nil action:nil];
        mw.synced.bordered = NO;
        mw.synced.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.synced.contentTintColor = NSColor.secondaryLabelColor;
        mw.synced.image = [NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath" accessibilityDescription:nil];
        mw.synced.imagePosition = NSImageLeading;
        mw.synced.identifier = @"map.synced";
        ADIFOnAction(mw.synced, ^{ uploads::cmdQslSync(); });
        [mw.synced setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        mw.findField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        mw.findField.placeholderString = T(@"Find a call, grid, DXCC entity or park");
        mw.findField.toolTip = T(@"Find on the map: a call (your QSOs with it, or its spot), a grid square, a DXCC entity you worked, a POTA park "
                                 @"(by reference or name). Return chooses it; more than one, a menu of them");
        mw.findField.identifier = @"map.find";
        mw.findField.toolTip = [mw.findField.toolTip stringByAppendingString:@"  (\u2318F)"];
        mw.findField.sendsWholeSearchString = YES;
        mw.findField.controlSize = NSControlSizeSmall;
        NSLayoutConstraint *findWidth = [mw.findField.widthAnchor constraintEqualToConstant:230];
        findWidth.priority = NSLayoutPriorityDefaultLow;
        findWidth.active = YES;
        [mw.findField.widthAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;
        mw.findMenu = [[NSMenu alloc] init];
        mw.findMenu.delegate = mw.listRows;
        mw.findField.menu = mw.findMenu;  // right-click: the results too
        ADIFOnAction(mw.findField, ^{ findTyped(); });
        // Space weather: the indices from NOAA SWPC, once turned on in its popover.
        mw.solarTile = [NSButton buttonWithTitle:@"" target:nil action:nil];
        mw.solarTile.bordered = NO;
        mw.solarTile.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
        mw.solarTile.image = [NSImage imageWithSystemSymbolName:@"sun.max" accessibilityDescription:nil];
        mw.solarTile.imagePosition = NSImageLeading;
        mw.solarTile.identifier = @"map.solar";
        mw.solarTile.accessibilityLabel = T(@"Space weather");
        ADIFOnAction(mw.solarTile, ^{ showSolarPopover(); });
        [mw.solarTile setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        fillSolarTile();
        for (NSView *v in @[ mw.solarTile, mw.synced, mw.findField, mw.bell, logTable, styleButton, save, settings, help, mw.paneToggle[0], mw.paneToggle[1],
                             mw.paneToggle[2] ])
            [header addView:v inGravity:NSStackViewGravityTrailing];
        [header setVisibilityPriority:NSStackViewVisibilityPriorityDetachOnlyIfNecessary forView:mw.synced];  // the first to go when narrow
        [header setVisibilityPriority:NSStackViewVisibilityPriorityDetachOnlyIfNecessary - 1 forView:mw.solarTile];
        [header setCustomSpacing:14 afterView:mw.solarTile];
        fillSynced();
        [header setCustomSpacing:14 afterView:mw.findField];
        [header setCustomSpacing:20 afterView:mw.bell];
        [header setCustomSpacing:6 afterView:logTable];
        [header setCustomSpacing:6 afterView:styleButton];
        [header setCustomSpacing:20 afterView:save];
        [header setCustomSpacing:6 afterView:settings];
        [header setCustomSpacing:20 afterView:help];
        [header setCustomSpacing:4 afterView:mw.paneToggle[0]];
        [header setCustomSpacing:4 afterView:mw.paneToggle[1]];

        // The toolbar under the header: History or Live; what the map shows now (the QSOs and their
        // dates, or the stations spotted); the filters, the ones it can't show as tags; Clear.
        mw.scopeLabel = [NSTextField labelWithString:@""];
        mw.scopeLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
        mw.scopeLabel.identifier = @"map.scope";
        mw.continentPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        mw.continentPopup.toolTip = T(@"Keep the QSOs and spots on one continent (More Filters can choose several)");
        mw.continentPopup.identifier = @"map.filter.continent";
        ADIFOnAction(mw.continentPopup, ^{
            NSString *code = mw.continentPopup.selectedItem.representedObject;
            if (mw.continentPopup.indexOfSelectedItem == 0) setSetting("mapFilterContinents", "");
            else if (code) setSetting("mapFilterContinents", ADIFStd(code));
            else return;  // "2 continents": as More Filters left them
            if (mw.filterPopover) fillPlaceControls();
            refresh();
        });
        mw.chips = [[NSStackView alloc] initWithFrame:NSZeroRect];
        mw.chips.spacing = 4;
        mw.chips.identifier = @"map.chips";
        for (NSControl *c in @[ mw.band, mw.mode, mw.dates, mw.confirmed, mw.dxccBar, mw.potaBar, mw.spotAgeBar, mw.spotSourceBar, mw.continentPopup, mw.moreFilters,
                                mw.clearFilters ]) {
            c.controlSize = NSControlSizeSmall;
            c.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        }
        auto cluster = [](NSArray<NSView *> *views) {
            NSStackView *c = [NSStackView stackViewWithViews:views];
            c.spacing = 6;
            c.detachesHiddenViews = YES;
            return c;
        };
        workflowBars(workflow());
        ADIFFlowView *toolbar = [[ADIFFlowView alloc] initWithFrame:NSZeroRect];  // wraps in a narrow window
        toolbar.gap = 15;
        toolbar.centred = YES;
        toolbar.identifier = @"map.toolbar";
        // Its own actions, at its end: the view kept as a Quick View, the map copied, the map alone.
        NSButton *keepView = smallButton(@"Save View...", @"Keep the layers, colours and filters as they are now as a Quick View of your own, in "
                                                          @"this workflow (right-click one of yours to remove it)",
                                         ^{});
        __weak NSButton *weakKeep = keepView;
        ADIFOnAction(keepView, ^{ showSaveView(weakKeep); });
        iconOnly(keepView, @"bookmark");
        keepView.identifier = @"map.toolbar.saveview";
        NSButton *copyButton = smallButton(@"Copy Map", @"Copy the map as it is shown now, with its legend, to paste into a message or document "
                                                        @"(Export PNG... saves it)",
                                           ^{ copyMap(); });
        iconOnly(copyButton, @"doc.on.doc");
        copyButton.identifier = @"map.toolbar.copy";
        mw.focusButton = smallButton(@"Focus Map", @"The map alone: hide the sidebar, the list and the selected panel (again to bring them back)",
                                     ^{ focusMap(); });
        [mw.focusButton setButtonType:NSButtonTypePushOnPushOff];
        iconOnly(mw.focusButton, @"arrow.up.left.and.arrow.down.right");
        mw.focusButton.identifier = @"map.toolbar.focus";
        for (NSButton *b in @[ keepView, copyButton, mw.focusButton ]) {
            b.controlSize = NSControlSizeSmall;
        }
        for (NSView *v in @[ mw.workflow, mw.scopeLabel, cluster(@[ mw.band, mw.mode, mw.dates, mw.confirmed, mw.dxccBar, mw.potaBar, mw.spotAgeBar, mw.spotSourceBar, mw.continentPopup, mw.moreFilters ]),
                             cluster(@[ mw.chips, mw.clearFilters ]), cluster(@[ keepView, copyButton, mw.focusButton ]) ])
            [toolbar addSubview:v];

        // The sidebar: sections, each with a triangle to close it.
        mw.sections = [NSMutableDictionary dictionary];
        mw.sectionTriangles = [NSMutableDictionary dictionary];
        mw.sectionTitles = [NSMutableDictionary dictionary];
        std::set<std::string> closedSections;
        for (const std::string &n : splitSetting("mapSectionsClosed", ',')) closedSections.insert(n);
        auto section = [&](NSString *name, NSString *title, NSView *body) -> NSView * {
            NSButton *triangle = [NSButton buttonWithTitle:@"" target:nil action:nil];
            triangle.bezelStyle = NSBezelStyleDisclosure;
            [triangle setButtonType:NSButtonTypePushOnPushOff];
            triangle.identifier = [@"map.section." stringByAppendingString:name];
            triangle.accessibilityLabel = T(title);
            NSTextField *head = caption(title);
            head.identifier = [NSString stringWithFormat:@"map.section.%@.title", name];
            NSStackView *heading = [NSStackView stackViewWithViews:@[ triangle, head ]];
            heading.spacing = 2;
            NSStackView *sec = rows(@[ heading, body ], 8);
            sec.identifier = [@"map.group." stringByAppendingString:name];
            [body.widthAnchor constraintEqualToAnchor:sec.widthAnchor].active = YES;
            mw.sections[name] = body, mw.sectionTriangles[name] = triangle, mw.sectionTitles[name] = head;
            bool open = !closedSections.count(ADIFStd(name));
            triangle.state = open ? NSControlStateValueOn : NSControlStateValueOff;
            body.hidden = !open;
            __weak NSButton *weak = triangle;
            ADIFOnAction(triangle, ^{ setSectionOpen(name, weak.state == NSControlStateValueOn); });
            return sec;
        };
        auto fullWidth = [](NSStackView *stack, NSArray<NSView *> *views) {  // these as wide as the stack
            for (NSView *v in views) [v.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
        };
        // Quick Views: History's layers, Live's kinds of spots, with their counts.
        mw.quickRows = [[ADIFQuickViews alloc] init];
        mw.quickRows.onChoose = ^(NSInteger row) { chooseQuickView(row); };
        mw.quickTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
        NSTableColumn *quickColumn = [[NSTableColumn alloc] initWithIdentifier:@"quick"];
        quickColumn.resizingMask = NSTableColumnAutoresizingMask;
        [mw.quickTable addTableColumn:quickColumn];
        mw.quickTable.headerView = nil;
        mw.quickTable.style = NSTableViewStyleSourceList;
        mw.quickTable.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
        mw.quickTable.rowHeight = 22;
        mw.quickTable.intercellSpacing = NSMakeSize(0, 2);
        mw.quickTable.backgroundColor = NSColor.clearColor;
        mw.quickTable.dataSource = mw.quickRows;
        mw.quickTable.delegate = mw.quickRows;
        mw.quickTable.identifier = @"map.views";
        mw.quickTable.accessibilityLabel = T(@"Quick Views");
        NSScrollView *quickScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        quickScroll.documentView = mw.quickTable;
        quickScroll.drawsBackground = NO;
        quickScroll.borderType = NSNoBorder;
        quickScroll.hasVerticalScroller = NO;
        mw.quickHeight = [quickScroll.heightAnchor constraintEqualToConstant:240];
        mw.quickHeight.active = YES;
        NSButton *saveView = smallButton(@"Save View...", @"Keep the layers, colours and filters as they are now as a Quick View of your own, in "
                                                          @"this workflow (right-click one of yours to remove it)",
                                         ^{});
        __weak NSButton *weakSave = saveView;
        ADIFOnAction(saveView, ^{ showSaveView(weakSave); });
        saveView.image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil];
        saveView.imagePosition = NSImageLeading;
        saveView.bordered = NO;
        saveView.contentTintColor = NSColor.linkColor;
        saveView.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        saveView.identifier = @"map.views.save";
        mw.viewsMenu = [[NSMenu alloc] init];
        mw.viewsMenu.delegate = mw.listRows;  // which fills it (fillViewsMenu)
        mw.quickTable.menu = mw.viewsMenu;
        NSStackView *viewsBody = rows(@[ quickScroll, saveView ], 4);
        [quickScroll.widthAnchor constraintEqualToAnchor:viewsBody.widthAnchor].active = YES;
        // Spots (Live's): the layer's boxes, their sources and filters, one station's spots.
        NSStackView *spotsLine = line(@[ mw.spotsButton, mw.refreshSpotsButton ]);
        [spotsLine setCustomSpacing:4 afterView:mw.spotsButton];
        NSStackView *onlyLine = line(@[ mw.spotsOnly, mw.spotsOnlyCall ]);
        [onlyLine setCustomSpacing:4 afterView:mw.spotsOnly];
        NSStackView *spotLayer = line(@[ mw.show[kLayerSpots], mw.overlay[kLayerSpots], mw.labels[kLayerSpots] ]);
        spotLayer.spacing = 12;
        // Map: its palette (a swatch each: its sea, land, confirmed and worked), colours, projection and region.
        NSMutableArray *swatches = [NSMutableArray array];
        for (NSUInteger i = 0; i < kPaletteTitles.count; ++i) {
            const MapPalette &pal = paletteAt((int)i);
            bool night = pal.night;
            unsigned ocean = pal.ocean, land = pal.land, confirmed = pal.confirmed, worked = pal.worked;
            auto ink = [night](unsigned c) {  // the night palette as it shows: reds of each colour's brightness
                if (!night) return rgb(c);
                double l = (0.2126 * ((c >> 16) & 255) + 0.7152 * ((c >> 8) & 255) + 0.0722 * (c & 255)) / 255;
                return [NSColor colorWithSRGBRed:l green:0 blue:0 alpha:1];
            };
            NSImage *img = [NSImage imageWithSize:NSMakeSize(30, 16)
                                          flipped:NO
                                   drawingHandler:^BOOL(NSRect r) {
                                       NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5) xRadius:3 yRadius:3];
                                       [ink(ocean) setFill];
                                       [frame fill];
                                       [NSGraphicsContext saveGraphicsState];
                                       [frame addClip];
                                       [ink(land) setFill];
                                       [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-6, -8, 26, 20)] fill];
                                       [ink(confirmed) setFill];
                                       [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(7, 5, 6, 6)] fill];
                                       [ink(worked) setFill];
                                       [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(19, 6, 6, 6)] fill];
                                       [NSGraphicsContext restoreGraphicsState];
                                       [[NSColor colorWithWhite:0.5 alpha:0.6] setStroke];
                                       [frame stroke];
                                       return YES;
                                   }];
            img.accessibilityDescription = T(kPaletteTitles[i]);
            [swatches addObject:img];
        }
        mw.paletteBar = [NSSegmentedControl segmentedControlWithImages:swatches trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
        for (NSUInteger i = 0; i < kPaletteTitles.count; ++i) [mw.paletteBar setToolTip:T(kPaletteTitles[i]) forSegment:(NSInteger)i];
        mw.paletteBar.segmentDistribution = NSSegmentDistributionFillEqually;
        mw.paletteBar.identifier = @"map.palette";
        mw.paletteBar.accessibilityLabel = T(@"Palette");
        mw.paletteBar.selectedSegment = number("mapPalette", 0, 4);
        mw.paletteBar.enabled = !ADIFNightMode();  // Night Mode sets it
        ADIFOnAction(mw.paletteBar, ^{
            setSetting("mapPalette", std::to_string(mw.paletteBar.selectedSegment));
            applyStyle();
            fillStyle();
        });
        NSStackView *mapRows = rows(@[ mw.paletteBar, mw.colorBy, mw.projection, mw.region ], 6);
        fullWidth(mapRows, @[ mw.paletteBar, mw.colorBy, mw.projection, mw.region ]);
        // Filters (the QSOs' and spots' are in the toolbar): which parks you haven't worked show.
        NSStackView *filterRows = rows(@[ line(@[ parksIn, mw.parkPlacesButton ]) ], 6);
        NSView *contactsHead = groupHead(@"contacts", N(@"Contacts")), *sunHead = groupHead(@"sun", N(@"Sun and propagation"));
        // The sun: the grey line and day and night (Style Options says how, and when).
        auto sunBox = [](NSString *title, const char *setting, NSString *tip) {
            NSButton *b = ADIFCheckbox(title, flag(setting, false));
            b.toolTip = T(tip);
            std::string which = setting;
            __weak NSButton *weak = b;
            ADIFOnAction(b, ^{
                saveFlag(which.c_str(), weak.state == NSControlStateValueOn);
                applyStyle();
                if (mw.styleWindow)
                    if (NSButton *other = (NSButton *)findView(mw.styleWindow.contentView, [@"map.style." stringByAppendingString:which == "mapGreyLine" ? @"greyLine" : @"dayNight"]))
                        other.state = weak.state;
                fillStyle();
            });
            return b;
        };
        mw.greyLineBox = sunBox(@"Grey line", "mapGreyLine", N(@"The band of dawn and dusk round the Earth, where low-band paths open (Style Options: when)"));
        mw.greyLineBox.identifier = @"map.greyline";
        mw.dayNightBox = sunBox(@"Day and night", "mapDayNight", N(@"Night shaded on the map (Style Options: now or at the QSO chosen)"));
        mw.dayNightBox.identifier = @"map.daynight";
        auto layerBox = [](NSString *title, const char *setting, NSString *tip, NSString *ident) {
            NSButton *b = ADIFCheckbox(title, flag(setting, false));
            b.toolTip = T(tip);
            b.identifier = ident;
            std::string which = setting;
            __weak NSButton *weak = b;
            ADIFOnAction(b, ^{
                saveFlag(which.c_str(), weak.state == NSControlStateValueOn);
                applyStyle();
            });
            return b;
        };
        mw.auroraBox = layerBox(N(@"Aurora"), "mapAurora",
                                N(@"The aurora now, from NOAA SWPC's OVATION forecast (30 to 90 minutes ahead; fetched every 15 minutes while it shows): "
                                  @"green where there is a chance of seeing it overhead, red where it is likely"),
                                @"map.aurora");
        mw.beaconsBox = layerBox(N(@"NCDXF beacons"), "mapBeacons",
                                 N(@"The 18 NCDXF/IARU beacons, taking turns on 14.100, 18.110, 21.150, 24.930 and 28.200 MHz: the ones sending now are "
                                   @"ringed in their band's colour (only the band filter's band, when it is one of them)"),
                                 @"map.beacons");
        mw.heatBox = layerBox(N(@"Heat map"), "mapSpotHeat",
                              N(@"The spots shown as a heat map: warmer where more stations are spotted now (the band, mode and Quick View apply)"),
                              @"map.spotheat");
        NSStackView *layerSection =
            rows(@[ layers, contactsHead, mw.contacts, mw.lines, mw.mine, sunHead, mw.greyLineBox, mw.dayNightBox, mw.auroraBox, mw.beaconsBox ], 5);
        [layerSection setCustomSpacing:12 afterView:layers];
        [layerSection setCustomSpacing:12 afterView:mw.mine];
        mw.layerGroups[@"contacts"] = @[ mw.contacts, mw.lines, mw.mine ];
        mw.layerGroups[@"sun"] = @[ mw.greyLineBox, mw.dayNightBox, mw.auroraBox, mw.beaconsBox ];
        for (const std::string &n : splitSetting("mapLayerGroupsClosed", ','))
            if (mw.layerGroups[ADIFString(n)]) setLayerGroupOpen(ADIFString(n), false);
        NSArray<NSView *> *sectionViews = @[
            section(@"views", N(@"Quick Views"), viewsBody), mw.spotsSection = section(@"spots", N(@"Spots"), rows(@[ spotLayer, mw.heatBox, spotsLine, onlyLine, mw.watchEdit ], 8)),
            section(@"layers", N(@"Layers"), layerSection), section(@"map", N(@"Map"), mapRows), section(@"filters", N(@"Filters"), filterRows)
        ];
        mw.spotsSection.hidden = !live();
        NSStackView *sideColumn = rows(sectionViews, 18);
        sideColumn.edgeInsets = NSEdgeInsetsMake(12, 12, 16, 12);
        for (NSView *v in sectionViews) [v.widthAnchor constraintEqualToAnchor:sideColumn.widthAnchor constant:-24].active = YES;
        // A view that scrolls, in the window's sidebar material; its content from the top.
        auto scrolling = [](NSView *content, NSString *ident, BOOL sidebar) {
            ADIFMapColumnView *doc = [[ADIFMapColumnView alloc] initWithFrame:NSZeroRect];
            content.translatesAutoresizingMaskIntoConstraints = NO;
            [doc addSubview:content];
            NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
            scroll.drawsBackground = NO;
            scroll.borderType = NSNoBorder;
            scroll.hasVerticalScroller = YES;
            scroll.autohidesScrollers = YES;
            scroll.documentView = doc;
            doc.translatesAutoresizingMaskIntoConstraints = NO;
            NSVisualEffectView *pane = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 280, 400)];
            pane.material = sidebar ? NSVisualEffectMaterialSidebar : NSVisualEffectMaterialContentBackground;
            pane.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            pane.identifier = ident;
            scroll.translatesAutoresizingMaskIntoConstraints = NO;
            [pane addSubview:scroll];
            [NSLayoutConstraint activateConstraints:@[
                [content.topAnchor constraintEqualToAnchor:doc.topAnchor],
                [content.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
                [content.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
                [content.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
                [doc.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
                [doc.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
                [doc.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
                [scroll.topAnchor constraintEqualToAnchor:pane.topAnchor],
                [scroll.bottomAnchor constraintEqualToAnchor:pane.bottomAnchor],
                [scroll.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
                [scroll.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
            ]];
            return pane;
        };
        mw.sidebar = scrolling(sideColumn, @"map.sidebar", YES);

        // The panel of what was chosen: its name, what it is, its entity's bands and modes, New QSO
        // and Center; then the situation.
        mw.slots = [NSTextField wrappingLabelWithString:@""];
        mw.slots.identifier = @"map.contact.slots";
        mw.slots.maximumNumberOfLines = 4;
        mw.slots.toolTip = T(@"This station's DXCC entity in your log: its bands and modes, green confirmed, orange worked, grey not yet; and "
                             @"your QSOs with the call");
        auto small = [](NSString *ident, NSInteger lines) {
            NSTextField *f = [NSTextField wrappingLabelWithString:@""];
            f.identifier = ident;
            f.maximumNumberOfLines = lines;
            f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            return f;
        };
        mw.situation = small(@"map.situation", 8);
        mw.situation.hidden = YES;  // the rows say it (and it is their tooltip)
        mw.today = small(@"map.today", 4);
        mw.today.hidden = YES;      // a row says it
        mw.statHost = [[NSView alloc] initWithFrame:NSZeroRect];
        mw.air = small(@"map.air", 4);
        mw.wantedLabel = [NSTextField wrappingLabelWithString:@""];
        mw.wantedLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.wanted = [NSStackView stackViewWithViews:@[ mw.wantedLabel ]];
        mw.wanted.orientation = NSUserInterfaceLayoutOrientationVertical;
        mw.wanted.alignment = NSLayoutAttributeLeading;
        mw.wanted.spacing = 2;
        mw.wanted.identifier = @"map.wanted";
        mw.wanted.detachesHiddenViews = YES;
        [mw.wantedLabel.widthAnchor constraintEqualToAnchor:mw.wanted.widthAnchor].active = YES;
        mw.contactTitle = [NSTextField labelWithString:@""];
        mw.contactTitle.identifier = @"map.contact.title";
        mw.contactTitle.font = [NSFont systemFontOfSize:NSFont.systemFontSize + 3 weight:NSFontWeightSemibold];
        mw.contactTitle.lineBreakMode = NSLineBreakByTruncatingTail;
        mw.contactTitle.allowsDefaultTighteningForTruncation = YES;
        mw.centerButton = smallButton(@"Center", @"Centre the map on what you chose, at the zoom it has", ^{ centerChosen(); });
        mw.centerButton.image = [NSImage imageWithSystemSymbolName:@"scope" accessibilityDescription:nil];
        mw.centerButton.imagePosition = NSImageLeading;
        mw.centerButton.identifier = @"map.center";
        mw.centerButton.toolTip = [mw.centerButton.toolTip stringByAppendingString:@"  (\u2318L)"];
        mw.centerButton.enabled = NO;
        mw.centerButton.hidden = YES;
        mw.viewQso = smallButton(@"View QSO", @"This QSO's record in the log", ^{
            if (mw.listed.size() == 1) goToQso(mw.listed[0]);
        });
        mw.viewQso.image = [NSImage imageWithSystemSymbolName:@"doc.text.magnifyingglass" accessibilityDescription:nil];
        mw.viewQso.imagePosition = NSImageLeading;
        mw.viewQso.identifier = @"map.viewqso";
        mw.viewQso.hidden = YES;
        mw.watchButton = smallButton(@"Watch", @"Watch this station", ^{ toggleWatch(watchTokenFor(mw.view.selectedHit)); });
        mw.watchButton.image = [NSImage imageWithSystemSymbolName:@"star" accessibilityDescription:nil];
        mw.watchButton.imagePosition = NSImageLeading;
        mw.watchButton.identifier = @"map.watch";
        mw.watchButton.hidden = YES;
        ADIFFlowView *actions = [[ADIFFlowView alloc] initWithFrame:NSZeroRect];  // a second line when the panel is narrow
        actions.gap = 8;
        actions.plain = YES;
        actions.centred = YES;
        actions.identifier = @"map.actions";
        for (NSView *v in @[ mw.centerButton, mw.viewQso, mw.watchButton ]) [actions addSubview:v];
        mw.actions = actions;
        mw.useSpot.bordered = NO;  // green, the panel's one main action
        mw.useSpot.wantsLayer = YES;
        mw.useSpot.layer.backgroundColor = NSColor.systemGreenColor.CGColor;
        mw.useSpot.layer.cornerRadius = 7;
        mw.useSpot.contentTintColor = NSColor.whiteColor;
        mw.useSpot.attributedTitle = [[NSAttributedString alloc]
            initWithString:T(@"New QSO")
                attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.systemFontSize + 1 weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName : NSColor.whiteColor}];
        [mw.useSpot.heightAnchor constraintEqualToConstant:32].active = YES;
        // What kind of thing is chosen, beside its name; a line under it; its facts; why it's worth working.
        mw.chosenBadge = [NSTextField labelWithString:@""];
        mw.chosenBadge.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize - 1 weight:NSFontWeightBold];
        mw.chosenBadge.textColor = NSColor.whiteColor;
        mw.chosenBadge.wantsLayer = YES;
        mw.chosenBadge.layer.cornerRadius = 4;
        mw.chosenBadge.identifier = @"map.chosen.kind";
        mw.chosenBadge.hidden = YES;
        [mw.chosenBadge setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *titleRow = line(@[ mw.contactTitle, mw.chosenBadge ]);
        titleRow.detachesHiddenViews = YES;
        mw.chosenSubtitle = [NSTextField labelWithString:@""];
        mw.chosenSubtitle.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize + 1];
        mw.chosenSubtitle.textColor = NSColor.secondaryLabelColor;
        mw.chosenSubtitle.lineBreakMode = NSLineBreakByTruncatingTail;
        mw.chosenSubtitle.identifier = @"map.chosen.subtitle";
        mw.chosenFacts = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
        mw.chosenFacts.rowSpacing = 5;
        mw.chosenFacts.columnSpacing = 12;
        mw.chosenFacts.identifier = @"map.chosen.facts";
        mw.chosenFacts.hidden = YES;
        mw.whyList = rows(@[], 5);
        NSTextField *whyCaption = caption(N(@"Why it's interesting"));
        NSStackView *whyStack = rows(@[ whyCaption, mw.whyList ], 6);
        [mw.whyList.widthAnchor constraintEqualToAnchor:whyStack.widthAnchor].active = YES;
        mw.whyBox = [[NSView alloc] initWithFrame:NSZeroRect];  // a hairline round the reasons
        mw.whyBox.wantsLayer = YES;
        mw.whyBox.layer.borderWidth = 1;
        mw.whyBox.layer.cornerRadius = 6;
        mw.whyBox.layer.borderColor = [NSColor.systemGreenColor colorWithAlphaComponent:0.55].CGColor;
        mw.whyBox.identifier = @"map.chosen.why";
        mw.whyBox.hidden = YES;
        whyStack.translatesAutoresizingMaskIntoConstraints = NO;
        [mw.whyBox addSubview:whyStack];
        [NSLayoutConstraint activateConstraints:@[
            [whyStack.topAnchor constraintEqualToAnchor:mw.whyBox.topAnchor constant:8],
            [whyStack.bottomAnchor constraintEqualToAnchor:mw.whyBox.bottomAnchor constant:-8],
            [whyStack.leadingAnchor constraintEqualToAnchor:mw.whyBox.leadingAnchor constant:10],
            [whyStack.trailingAnchor constraintEqualToAnchor:mw.whyBox.trailingAnchor constant:-10],
        ]];
        // A spot's Details, closed at first (remembered).
        NSButton *detailsTriangle = [NSButton buttonWithTitle:@"" target:nil action:nil];
        detailsTriangle.bezelStyle = NSBezelStyleDisclosure;
        [detailsTriangle setButtonType:NSButtonTypePushOnPushOff];
        detailsTriangle.identifier = @"map.details.toggle";
        detailsTriangle.accessibilityLabel = T(@"Details");
        mw.detailsText = [NSTextField wrappingLabelWithString:@""];
        mw.detailsText.selectable = YES;
        mw.detailsText.identifier = @"map.details";
        mw.detailsBody = mw.detailsText;
        NSStackView *detailsHead = [NSStackView stackViewWithViews:@[ detailsTriangle, caption(N(@"Details")) ]];
        detailsHead.spacing = 2;
        NSStackView *detailsSection = rows(@[ detailsHead, mw.detailsText ], 6);
        [mw.detailsText.widthAnchor constraintEqualToAnchor:detailsSection.widthAnchor].active = YES;
        detailsSection.identifier = @"map.details.section";
        detailsSection.hidden = YES;
        mw.detailsSection = detailsSection;
        bool detailsOpen = flag("mapDetailsOpen", false);
        detailsTriangle.state = detailsOpen ? NSControlStateValueOn : NSControlStateValueOff;
        mw.detailsText.hidden = !detailsOpen;
        __weak NSButton *weakDetails = detailsTriangle;
        ADIFOnAction(detailsTriangle, ^{
            bool open = weakDetails.state == NSControlStateValueOn;
            mw.detailsText.hidden = !open;
            saveFlag("mapDetailsOpen", open);
        });
        mw.status.textColor = NSColor.secondaryLabelColor;  // the description, under the facts
        NSBox *between = [[NSBox alloc] initWithFrame:NSZeroRect];
        between.boxType = NSBoxSeparator;
        NSTextField *chosenCaption = caption(N(@"Selected")), *situationCaption = caption(N(@"Situation"));
        NSButton *closeChosen = smallButton(@"Hide", @"Hide this panel (the button at the right of the header shows it again)", ^{ showPane(2, false); });
        iconOnly(closeChosen, @"xmark");
        closeChosen.bordered = NO;
        closeChosen.accessibilityLabel = T(@"Hide the selected panel");
        closeChosen.identifier = @"map.selected.close";
        NSStackView *chosenHead = [[NSStackView alloc] initWithFrame:NSZeroRect];
        [chosenHead addView:chosenCaption inGravity:NSStackViewGravityLeading];
        [chosenHead addView:closeChosen inGravity:NSStackViewGravityTrailing];
        // Live's newest spots, and View all spots.
        NSButton *allSpots = smallButton(@"View all spots \u2192", @"The list's Spots: every station spotted in view", ^{
            mw.listKind.selectedSegment = kListSpots;
            setSetting("mapListKind", std::to_string(kListSpots));
            if (mw.listPanel.hidden) showPane(1, true);
            fillViewList();
        });
        allSpots.bordered = NO;
        allSpots.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        allSpots.contentTintColor = NSColor.linkColor;
        allSpots.identifier = @"map.recent.all";
        NSStackView *recentHead = [[NSStackView alloc] initWithFrame:NSZeroRect];
        [recentHead addView:caption(N(@"Recent spots")) inGravity:NSStackViewGravityLeading];
        [recentHead addView:allSpots inGravity:NSStackViewGravityTrailing];
        mw.recentHost = [[NSView alloc] initWithFrame:NSZeroRect];
        NSStackView *recentSection = rows(@[ recentHead, mw.recentHost ], 6);
        [recentHead.widthAnchor constraintEqualToAnchor:recentSection.widthAnchor].active = YES;
        recentSection.identifier = @"map.recent.section";
        recentSection.hidden = YES;
        mw.recentSection = recentSection;
        // Live's Band conditions: closed with its triangle (remembered).
        NSButton *bandTriangle = [NSButton buttonWithTitle:@"" target:nil action:nil];
        bandTriangle.bezelStyle = NSBezelStyleDisclosure;
        [bandTriangle setButtonType:NSButtonTypePushOnPushOff];
        bandTriangle.identifier = @"map.bands.toggle";
        bandTriangle.accessibilityLabel = T(@"Band conditions");
        mw.bandLine = [NSTextField wrappingLabelWithString:@""];
        mw.bandLine.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.bandLine.identifier = @"map.bands.line";
        mw.bandHost = [[NSView alloc] initWithFrame:NSZeroRect];
        NSStackView *bandBody = rows(@[ mw.bandLine, mw.bandHost ], 6);
        mw.bandBody = bandBody;
        bandBody.identifier = @"map.bands.body";
        [mw.bandLine.widthAnchor constraintEqualToAnchor:bandBody.widthAnchor].active = YES;
        [mw.bandHost.widthAnchor constraintEqualToAnchor:bandBody.widthAnchor].active = YES;
        NSStackView *bandHead = [NSStackView stackViewWithViews:@[ bandTriangle, caption(N(@"Band conditions")) ]];
        bandHead.spacing = 2;
        NSStackView *bandSection = rows(@[ bandHead, bandBody ], 6);
        [bandBody.widthAnchor constraintEqualToAnchor:bandSection.widthAnchor].active = YES;
        bandSection.identifier = @"map.bands.section";
        bandSection.hidden = YES;
        bandSection.toolTip = T(@"How the bands are doing, from the spots: the stations spotted on each, those heard by spotters within 1,500 km of "
                                @"your station, and the best report they gave");
        mw.bandSection = bandSection;
        bool bandsOpen = !flag("mapBandsClosed", false);
        bandTriangle.state = bandsOpen ? NSControlStateValueOn : NSControlStateValueOff;
        bandBody.hidden = !bandsOpen;
        __weak NSButton *weakBands = bandTriangle;
        ADIFOnAction(bandTriangle, ^{
            bool open = weakBands.state == NSControlStateValueOn;
            bandBody.hidden = !open;
            saveFlag("mapBandsClosed", !open);
        });
        // History's Awards: closed with its triangle (remembered).
        NSButton *awardsTriangle = [NSButton buttonWithTitle:@"" target:nil action:nil];
        awardsTriangle.bezelStyle = NSBezelStyleDisclosure;
        [awardsTriangle setButtonType:NSButtonTypePushOnPushOff];
        awardsTriangle.identifier = @"map.awards.toggle";
        awardsTriangle.accessibilityLabel = T(@"Awards");
        mw.awardsHost = [[NSView alloc] initWithFrame:NSZeroRect];
        NSStackView *awardsHead = [NSStackView stackViewWithViews:@[ awardsTriangle, caption(N(@"Awards")) ]];
        awardsHead.spacing = 2;
        NSStackView *awardsSection = rows(@[ awardsHead, mw.awardsHost ], 6);
        [mw.awardsHost.widthAnchor constraintEqualToAnchor:awardsSection.widthAnchor].active = YES;
        awardsSection.identifier = @"map.awards.section";
        awardsSection.hidden = YES;
        mw.awardsSection = awardsSection;
        bool awardsOpen = !flag("mapAwardsClosed", false);
        awardsTriangle.state = awardsOpen ? NSControlStateValueOn : NSControlStateValueOff;
        mw.awardsHost.hidden = !awardsOpen;
        __weak NSButton *weakAwards = awardsTriangle;
        ADIFOnAction(awardsTriangle, ^{
            bool open = weakAwards.state == NSControlStateValueOn;
            mw.awardsHost.hidden = !open;
            saveFlag("mapAwardsClosed", !open);
        });
        NSStackView *selectedColumn = rows(@[ chosenHead, titleRow, mw.chosenSubtitle, mw.chosenFacts, mw.whyBox, detailsSection, mw.useSpot, actions, mw.status, mw.slots,
                                              between, situationCaption, mw.statHost, mw.situation, mw.today, mw.wanted, mw.air, awardsSection, bandSection, recentSection ],
                                           6);
        selectedColumn.edgeInsets = NSEdgeInsetsMake(12, 12, 16, 12);
        for (NSView *v in @[ chosenHead, titleRow, mw.chosenSubtitle, mw.chosenFacts, mw.whyBox, detailsSection, mw.useSpot, actions, mw.status, mw.slots, between, mw.statHost, awardsSection, bandSection,
                             mw.situation, mw.today, mw.wanted, mw.air, recentSection ])
            [v.widthAnchor constraintEqualToAnchor:selectedColumn.widthAnchor constant:-24].active = YES;
        [selectedColumn setCustomSpacing:2 afterView:titleRow];
        [selectedColumn setCustomSpacing:10 afterView:mw.chosenSubtitle];
        [selectedColumn setCustomSpacing:10 afterView:mw.chosenFacts];
        [selectedColumn setCustomSpacing:10 afterView:mw.whyBox];
        [selectedColumn setCustomSpacing:10 afterView:detailsSection];
        [selectedColumn setCustomSpacing:10 afterView:actions];
        [selectedColumn setCustomSpacing:12 afterView:mw.slots];
        [selectedColumn setCustomSpacing:12 afterView:between];
        [selectedColumn setCustomSpacing:16 afterView:mw.air];
        mw.selectedPanel = scrolling(selectedColumn, @"map.selected", NO);

        // The zoom buttons on the map, as on other maps: in, the zoom, out; then the log and the world.
        auto mapButton = [&](NSButton *b, NSString *symbol, NSString *spoken) {
            iconOnly(b, symbol);
            b.bordered = NO;
            b.accessibilityLabel = T(spoken);
            [b.widthAnchor constraintEqualToConstant:30].active = YES;
            [b.heightAnchor constraintEqualToConstant:22].active = YES;
        };
        mapButton(in, @"plus", N(@"Zoom In"));
        mapButton(out, @"minus", N(@"Zoom Out"));
        mapButton(fit, @"viewfinder", N(@"Fit Log"));
        mapButton(world, @"globe", N(@"World"));
        mapButton(home, @"house", N(@"Home"));
        mw.zoomLabel.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium];
        mw.zoomLabel.alignment = NSTextAlignmentCenter;
        mw.zoomLabel.textColor = NSColor.secondaryLabelColor;
        NSBox *navRule = [[NSBox alloc] initWithFrame:NSZeroRect];
        navRule.boxType = NSBoxSeparator;
        [navRule.widthAnchor constraintEqualToConstant:24].active = YES;
        NSStackView *navStack = rows(@[ in, mw.zoomLabel, out, navRule, home, fit, world ], 6);  // the buttons' frames reach 3 points past their faces
        navStack.alignment = NSLayoutAttributeCenterX;
        mw.nav = [[ADIFMapPanel alloc] initWithFrame:NSZeroRect];
        mw.nav.identifier = @"map.nav";
        navStack.translatesAutoresizingMaskIntoConstraints = NO;
        [mw.nav addSubview:navStack];
        NSView *mapHost = [[NSView alloc] initWithFrame:NSZeroRect];  // the map, the zoom buttons on it
        mapHost.identifier = @"map.host";
        for (NSView *v in @[ mw.view, mw.nav ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [mapHost addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [navStack.topAnchor constraintEqualToAnchor:mw.nav.topAnchor constant:5],
            [navStack.bottomAnchor constraintEqualToAnchor:mw.nav.bottomAnchor constant:-5],
            [navStack.leadingAnchor constraintEqualToAnchor:mw.nav.leadingAnchor constant:4],
            [navStack.trailingAnchor constraintEqualToAnchor:mw.nav.trailingAnchor constant:-4],
            [mw.view.topAnchor constraintEqualToAnchor:mapHost.topAnchor],
            [mw.view.bottomAnchor constraintEqualToAnchor:mapHost.bottomAnchor],
            [mw.view.leadingAnchor constraintEqualToAnchor:mapHost.leadingAnchor],
            [mw.view.trailingAnchor constraintEqualToAnchor:mapHost.trailingAnchor],
            [mw.nav.topAnchor constraintEqualToAnchor:mapHost.topAnchor constant:10],
            [mw.nav.leadingAnchor constraintEqualToAnchor:mapHost.leadingAnchor constant:10],
        ]];
        mw.view.clearInsets = NSEdgeInsetsMake(0, mw.nav.fittingSize.width + 20, 0, 0);  // Fit Log and the rest keep clear of the buttons

        // The footer: the workflow's state, then what is under the pointer.
        mw.liveLabel = smallButton(@"", @"", ^{  // in Live, what each feed is doing (Sources and Filters)
            if (live()) showSpotsPopover();
        });
        mw.liveLabel.bordered = NO;
        mw.liveLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
        mw.liveLabel.identifier = @"map.live";
        mw.hover = [NSTextField labelWithString:@""];
        mw.hover.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        mw.hover.textColor = NSColor.secondaryLabelColor;
        mw.hover.lineBreakMode = NSLineBreakByTruncatingTail;
        [mw.hover setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        mw.hover.identifier = @"map.hover";
        NSStackView *footer = line(@[ mw.liveLabel, mw.hover ]);
        footer.spacing = 18;
        footer.edgeInsets = NSEdgeInsetsMake(4, 12, 5, 12);
        footer.identifier = @"map.footer";
        showHover(idleStatus());

        // The panes: the sidebar | the map over its list | the selected panel; dividers to drag.
        mw.splitKeeper = [[ADIFSplitKeeper alloc] init];
        {  // the sidebar's least width: its layers' grid and its menus whole, in this language
            CGFloat least = 280;
            for (NSView *v in @[ layers, mw.colorBy, mw.projection, mw.region ]) least = std::max(least, std::ceil(v.fittingSize.width) + 24 + 16);
            mw.splitKeeper.leastSidebar = least;

        }
        auto split = [](NSString *ident, BOOL vertical, NSArray<NSView *> *views) {
            NSSplitView *sv = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 1200, 700)];
            sv.identifier = ident;
            sv.vertical = vertical;
            sv.dividerStyle = NSSplitViewDividerStyleThin;
            sv.arrangesAllSubviews = YES;
            for (NSView *v in views) [sv addArrangedSubview:v];
            sv.delegate = mw.splitKeeper;
            return sv;
        };
        mw.middleSplit = split(@"map.middle.split", NO, @[ mapHost, mw.listPanel ]);
        [mw.middleSplit setHoldingPriority:NSLayoutPriorityDefaultLow - 10 forSubviewAtIndex:0];  // the map takes a window's growth
        [mw.middleSplit setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:1];
        mw.bodySplit = split(@"map.body.split", YES, @[ mw.sidebar, mw.middleSplit, mw.selectedPanel ]);
        [mw.bodySplit setHoldingPriority:NSLayoutPriorityDefaultLow + 20 forSubviewAtIndex:0];
        [mw.bodySplit setHoldingPriority:NSLayoutPriorityDefaultLow - 10 forSubviewAtIndex:1];
        [mw.bodySplit setHoldingPriority:NSLayoutPriorityDefaultLow + 20 forSubviewAtIndex:2];
        mw.splitKeeper.onMoved = ^(NSSplitView *sv) {
            fitListBars();
            if (!mw.splitsRestored) return;
            if (sv == mw.bodySplit && !mw.sidebar.hidden) setSetting("mapSidebarWidth", std::to_string(std::lround(mw.sidebar.frame.size.width)));
            if (sv == mw.bodySplit && !mw.selectedPanel.hidden) setSetting("mapSelectedWidth", std::to_string(std::lround(mw.selectedPanel.frame.size.width)));
            if (sv == mw.middleSplit && !mw.listPanel.hidden) setSetting("mapListHeight", std::to_string(std::lround(mw.listPanel.frame.size.height)));
        };
        NSBox *underHeader = [[NSBox alloc] initWithFrame:NSZeroRect], *overFooter = [[NSBox alloc] initWithFrame:NSZeroRect];
        NSBox *underToolbar = [[NSBox alloc] initWithFrame:NSZeroRect];
        underHeader.boxType = overFooter.boxType = underToolbar.boxType = NSBoxSeparator;
        for (NSView *v in @[ header, underHeader, toolbar, underToolbar, mw.bodySplit, overFooter, footer ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [root addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [header.topAnchor constraintEqualToAnchor:root.topAnchor],
            [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [underHeader.topAnchor constraintEqualToAnchor:header.bottomAnchor],
            [underHeader.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [underHeader.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [toolbar.topAnchor constraintEqualToAnchor:underHeader.bottomAnchor constant:6],
            [toolbar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:12],
            [toolbar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-12],
            [underToolbar.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:6],
            [underToolbar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [underToolbar.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [mw.bodySplit.topAnchor constraintEqualToAnchor:underToolbar.bottomAnchor],
            [mw.bodySplit.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [mw.bodySplit.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [overFooter.topAnchor constraintEqualToAnchor:mw.bodySplit.bottomAnchor],
            [overFooter.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [overFooter.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [footer.topAnchor constraintEqualToAnchor:overFooter.bottomAnchor],
            [footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
            [mw.view.widthAnchor constraintGreaterThanOrEqualToConstant:420],
            [mw.view.heightAnchor constraintGreaterThanOrEqualToConstant:240],
            [mw.listPanel.heightAnchor constraintGreaterThanOrEqualToConstant:110],
            [mw.sidebar.widthAnchor constraintGreaterThanOrEqualToConstant:mw.splitKeeper.leastSidebar],
            [mw.selectedPanel.widthAnchor constraintGreaterThanOrEqualToConstant:240],
        ]];
        for (int i = 0; i < 3; ++i) showPane(i, flag(kPaneKeys[i], true));
        mw.spotLens = live() ? lensOfView(quickView()) : 0;
        [mw.window center];
        // New spots redraw the layer; closing the window stops the feeds.
        [[NSNotificationCenter defaultCenter] addObserverForName:ADIFParkOutlinesChangedNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *) {
                                                          mw.view.needsDisplay = YES;
                                                          fillStyle();  // outline only needs outlines
                                                          queueViewList();
                                                      }];
        [[NSNotificationCenter defaultCenter] addObserverForName:ADIFNightModeChangedNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *) {
                                                          applyStyle();
                                                          fillStyle();
                                                          fillPrograms();
                                                      }];
        mw.spotsObserver = [[NSNotificationCenter defaultCenter] addObserverForName:ADIFSpotsChangedNotification
                                                                             object:nil
                                                                              queue:nil
                                                                         usingBlock:^(NSNotification *) { refreshSpots(); }];
        mw.closeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
                                                                             object:mw.window
                                                                              queue:nil
                                                                         usingBlock:^(NSNotification *) {
                                                                             spotfeeds::setWanted(false);
                                                                             solar::setWanted(false, false);
                                                                             [mw.beaconTimer invalidate];
                                                                             mw.beaconTimer = nil;
                                                                         }];
        mw.solarObserver = [[NSNotificationCenter defaultCenter] addObserverForName:ADIFSolarChangedNotification
                                                                             object:nil
                                                                              queue:NSOperationQueue.mainQueue
                                                                         usingBlock:^(NSNotification *) {
                                                                             fillSolarTile();
                                                                             fillBandConditions();
                                                                             if (mw.solarPopover.shown) showSolarPopover();
                                                                             mw.view.needsDisplay = YES;  // the aurora, its legend
                                                                         }];
    }
    if (!mw.sunTimer)
        mw.sunTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      repeats:YES
                                                        block:^(NSTimer *) {
                                                            ADIFMapStyle st = mw.view.style;
                                                            if (mw.window.visible && (st.dayNight || st.greyLine) && st.sunTime == 0)
                                                                mw.view.needsDisplay = YES;
                                                            // Spots age: their filter, fading and labels follow.
                                                            if (mw.window.visible && st[kLayerSpots].show) refreshSpots();
                                                            else if (mw.window.visible) showSituation();  // the sun moves on
                                                        }];
    refresh();
    [mw.window makeKeyAndOrderFront:nil];
    if (!mw.splitsRestored) {  // the dividers where they were left: the sidebar's and the selected panel's widths, the list's height
        [mw.window layoutIfNeeded];
        for (int i = 0; i < 3; ++i)
            if (flag(kPaneKeys[i], true)) restorePane(i);
        mw.splitsRestored = true;
    }
    [mw.window makeFirstResponder:mw.view];
    refreshSpots();  // the feeds start once the window shows
    updatePropagation();
}

void setSpotHandler(void (^handler)(const std::vector<std::pair<std::string, std::string>> &fields)) { mw.spotHandler = handler; }

void iotaGroupsChanged() {
    if (mw.view) mw.view.needsDisplay = YES;
}

void parkListChanged() {
    if (mw.view) mw.view.needsDisplay = YES;
    applyParkPlaces();  // its locations, and home's
}

bool shownArea(std::array<double, 4> *box) {
    if (!mw.window || !mw.window.visible || !mw.view) return false;
    double w, s, e, n;
    [mw.view visibleWest:&w south:&s east:&e north:&n];
    if (e - w >= 359 || n - s >= 170) return false;  // the whole world: not an area to download
    *box = {w, s, e, n};
    return true;
}

void detailChanged() {
    if (mw.view) [mw.view osmChanged];
}

void documentChanged() {
    if (mw.window && mw.window.visible) refresh();
}

}  // namespace worldmap

