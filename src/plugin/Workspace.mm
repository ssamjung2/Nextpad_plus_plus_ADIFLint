// The Operating Console: see Workspace.h.
#import "Workspace.h"

#import "L10n.h"
#import "Map.h"
#import "Night.h"
#import "Panels.h"
#import "ToolWindow.h"
#import "PluginHost.h"
#import "Country.h"
#include "adif_geo.h"
#include "adif_layout.h"
#include "adif_needs.h"
#include "adif_parks.h"
#include "adif_world.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <map>
#include <vector>

namespace {

const CGFloat kStatusHeight = 22;
const CGFloat kHeaderHeight = 24;
std::string gStatus;

namespace layout = adif::layout;

// ── The panels: the console's dock items by the ids its layouts use (adif_layout.h) ──

const char *panelOf(int item) {
    switch (item) {
        case kDockMap: return layout::kMap;
        case kDockLog: return layout::kLogTable;
        case kDockNewQso: return layout::kNewQso;
        case kDockSpots: return layout::kSpots;
        case kDockContactMap: return layout::kContactMap;
        case kDockQsoInfo: return layout::kQsoDetails;
        default: return "";
    }
}

int itemOf(const std::string &panel) {
    for (int item = 1; item < kDockCount; ++item)
        if (panel == panelOf(item)) return item;
    return kDockNone;
}

// Each stack of a tree, in order (left to right, top to bottom).
void stacksOf(const layout::Node &n, std::vector<const layout::Node *> &out) {
    if (n.kind == layout::Node::Kind::Stack) {
        if (!n.panels.empty()) out.push_back(&n);
        return;
    }
    for (const layout::Node &c : n.children) stacksOf(c, out);
}

// A tree's shape: its splits and stacks, without shares or which tab is in front (rebuilt only when it changes).
std::string shapeOf(const layout::Node &n) {
    if (n.kind == layout::Node::Kind::Stack) {
        std::string out = "[";
        for (const std::string &p : n.panels) out += p + ",";
        return out + "]";
    }
    std::string out = n.kind == layout::Node::Kind::Row ? "R(" : "C(";
    for (const layout::Node &c : n.children) out += shapeOf(c);
    return out + ")";
}

// The node at a path of child indexes ("0.2.1"), or nullptr.
layout::Node *nodeAt(layout::Node &root, NSString *path) {
    layout::Node *n = &root;
    for (NSString *part in [path componentsSeparatedByString:@"."]) {
        if (!part.length) continue;
        NSInteger i = part.integerValue;
        if (n->kind == layout::Node::Kind::Stack || i < 0 || (size_t)i >= n->children.size()) return nullptr;
        n = &n->children[(size_t)i];
    }
    return n;
}

// A panel's name, as the Panels menu has it (Panels.mm).
// Where a style's own layout is kept (its Save): "consoleStyleLayoutSocial".
std::string styleLayoutKey(const std::string &style) {
    std::string key = "consoleStyleLayout" + style;
    if (key.size() > 18) key[18] = (char)std::toupper((unsigned char)key[18]);
    return key;
}

NSString *itemName(int item) {
    const panels::Spec *s = item != kDockNone ? panels::find(panelOf(item)) : nullptr;
    return s ? T(s->title) : T(@"Empty");
}

// Shown, as the Panels menu shows it: opened (it docks itself when the console holds it), or brought forward.
void openItem(int item) {
    if (item != kDockNone) panels::setShown(panelOf(item), true);
}

bool gMapListShows = false;  // the Map in the console shows its own list (no table of the same records beside it)

// Keep each frame large enough to use; longer content scrolls inside its frame.
NSSize itemMinimum(int item) {
    switch (item) {
        // Room under its toolbar (its groups wrap below this width), header and footer for the zoom
        // buttons; and for its list under the map when that shows.
        case kDockMap: return NSMakeSize(720, gMapListShows ? 600 : 460);
        case kDockLog: return NSMakeSize(380, 240);
        case kDockSpots: return NSMakeSize(400, 220);
        case kDockContactMap: return NSMakeSize(240, 200);
        case kDockQsoInfo: return NSMakeSize(320, 200);
        default: return NSMakeSize(420, 300);
    }
}

NSSize contentMinimum(int item) { return itemMinimum(item); }

}  // namespace

// ── A frame: its header (title, what it shows, close) over the item's content ──

@interface ADIFDockFrame : NSView <NSMenuDelegate>
@property(nonatomic) int index;                              // its stack's place among the console's (left to right, top to bottom)
@property(nonatomic, readonly) int item;                     // the panel in front
@property(nonatomic, readonly) NSArray<NSNumber *> *items;   // its panels, as tabs
@property(nonatomic, copy) void (^onChoose)(int index, int item);  // the header's menu: what it shows
@property(nonatomic, copy) void (^onSwap)(int from, int to);       // a frame dropped on this one's body: the two swap
@property(nonatomic, copy) void (^onStack)(int from, int to);      // a frame dropped on this one's header: a tab here
@property(nonatomic, copy) void (^onTab)(int index, int item);     // a tab chosen
@property(nonatomic, copy) void (^onAddTab)(int index, int item);  // its actions menu: a panel as a tab here
@property(nonatomic, copy) void (^onSplit)(int index);             // its actions menu: the tab in front to a frame of its own
@property(nonatomic, copy) void (^onClose)(int index);             // its front panel closed
- (void)showItems:(NSArray<NSNumber *> *)items front:(int)item title:(NSString *)title content:(NSView *)content;
- (NSSize)leastSize;  // its panels' largest least size, with its header
@end

// A frame's header: its menu (or its tabs), title and close button, and a handle to drag the frame
// by: onto another frame's body the two swap; onto its header the frame becomes a tab there (the
// menu does the first from the keyboard and VoiceOver).
static NSPasteboardType const kFramePasteboardType = @"org.nextpad.adiflint.frame";

@interface ADIFDockHeader : NSView <NSDraggingSource>
@property(nonatomic) int index;
@end

@implementation ADIFDockHeader {
    NSPoint _down;
}
- (void)mouseDown:(NSEvent *)event {
    _down = [self convertPoint:event.locationInWindow fromView:nil];
}
- (void)mouseDragged:(NSEvent *)event {
    NSPoint at = [self convertPoint:event.locationInWindow fromView:nil];
    if (std::hypot(at.x - _down.x, at.y - _down.y) < 4) return;
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:[NSString stringWithFormat:@"%d", self.index] forType:kFramePasteboardType];
    NSDraggingItem *drag = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
    [self cacheDisplayInRect:self.bounds toBitmapImageRep:rep];
    NSImage *image = [[NSImage alloc] initWithSize:self.bounds.size];
    [image addRepresentation:rep];
    [drag setDraggingFrame:self.bounds contents:image];
    [self beginDraggingSessionWithItems:@[ drag ] event:event source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return context == NSDraggingContextWithinApplication ? NSDragOperationMove : NSDragOperationNone;
}
- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor];
}
@end

@interface ADIFDockBody : NSView
@end
@implementation ADIFDockBody
- (BOOL)isFlipped { return YES; }
@end
@interface ADIFDockClip : NSClipView
@end
@implementation ADIFDockClip
- (BOOL)isFlipped { return YES; }
@end

@implementation ADIFDockFrame {
    NSTextField *_title;
    NSPopUpButton *_choice;
    NSSegmentedControl *_tabs;
    NSButton *_close;
    NSPopUpButton *_more;  // the frame's actions: Add Tab, Move to Its Own Frame, Close
    NSScrollView *_scroll;
    ADIFDockHeader *_header;
    NSView *_body;  // the scroll view's document: as big as the frame, or the content's least size when that is more
    NSView *_content;
    NSLayoutConstraint *_titleAfterChoice, *_titleAfterTabs;
    NSView *_dropMark;  // over the header while a frame dropped there would become a tab
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _item = kDockNone;
    _items = @[];
    ADIFDockHeader *header = [[ADIFDockHeader alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.toolTip = T(@"Drag a frame by its header onto another frame to swap them, or onto its header to make it a tab there");
    _header = header;
    [self registerForDraggedTypes:@[ kFramePasteboardType ]];
    _title = [NSTextField labelWithString:@""];
    _title.font = theme::small(NSFontWeightSemibold);
    _title.textColor = NSColor.secondaryLabelColor;
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    _title.translatesAutoresizingMaskIntoConstraints = NO;
    [_title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _choice = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _choice.controlSize = NSControlSizeSmall;
    _choice.font = theme::small();
    _choice.bordered = NO;
    _choice.translatesAutoresizingMaskIntoConstraints = NO;
    _choice.toolTip = T(@"What this frame shows: choosing one that is in another frame swaps them");
    _choice.accessibilityLabel = T(@"Frame contents");
    for (const panels::Spec &s : panels::all()) {  // the Panels menu's order, then none
        if (itemOf(s.id) == kDockNone) continue;
        [_choice addItemWithTitle:itemName(itemOf(s.id))];
        _choice.lastItem.tag = itemOf(s.id);
    }
    [_choice addItemWithTitle:itemName(kDockNone)];
    _choice.lastItem.tag = kDockNone;
    _choice.target = self;
    _choice.action = @selector(chosen:);
    // Tabs, when the frame holds more than one panel: a click brings that one to the front.
    _tabs = [NSSegmentedControl segmentedControlWithLabels:@[] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(tabChosen:)];
    _tabs.controlSize = NSControlSizeSmall;
    _tabs.font = theme::small();
    _tabs.segmentStyle = NSSegmentStyleSeparated;
    _tabs.identifier = @"frame.tabs";
    _tabs.accessibilityLabel = T(@"Tabs");
    _tabs.translatesAutoresizingMaskIntoConstraints = NO;
    _tabs.hidden = YES;
    // A circled x drawn at the size it shows (a 16-point target, as the header's other controls).
    NSImage *x = [[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]];
    _close = [NSButton buttonWithImage:x ?: [NSImage imageNamed:NSImageNameStopProgressFreestandingTemplate] target:self action:@selector(closePressed:)];
    _close.bordered = NO;
    _close.imagePosition = NSImageOnly;
    _close.imageScaling = NSImageScaleProportionallyDown;
    _close.contentTintColor = NSColor.secondaryLabelColor;
    _close.toolTip = T(@"Close this frame");
    _close.accessibilityLabel = T(@"Close this frame");
    _close.translatesAutoresizingMaskIntoConstraints = NO;
    // What a drag does, from the keyboard and VoiceOver as well (HIG: a menu command for each drag).
    _more = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    _more.bordered = NO;
    _more.imagePosition = NSImageOnly;
    ((NSPopUpButtonCell *)_more.cell).arrowPosition = NSPopUpNoArrow;
    NSMenuItem *face = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    face.image = [[NSImage imageWithSystemSymbolName:@"ellipsis.circle" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular]];
    [_more.menu addItem:face];
    _more.menu.delegate = self;
    _more.contentTintColor = NSColor.secondaryLabelColor;
    _more.toolTip = T(@"Frame actions: a panel as a tab here, the tab in front to a frame of its own, close");
    _more.accessibilityLabel = T(@"Frame actions");
    _more.identifier = @"frame.actions";
    _more.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *rule = [[NSBox alloc] initWithFrame:NSZeroRect];
    rule.boxType = NSBoxSeparator;
    rule.translatesAutoresizingMaskIntoConstraints = NO;
    _dropMark = [[NSView alloc] initWithFrame:NSZeroRect];
    _dropMark.wantsLayer = YES;
    _dropMark.layer.backgroundColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.25].CGColor;
    _dropMark.translatesAutoresizingMaskIntoConstraints = NO;
    _dropMark.hidden = YES;
    for (NSView *v in @[ _dropMark, _title, _choice, _tabs, _more, _close, rule ]) [header addSubview:v];
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.hasVerticalScroller = _scroll.hasHorizontalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.borderType = NSNoBorder;
    _scroll.drawsBackground = NO;
    _scroll.contentView = [[ADIFDockClip alloc] initWithFrame:NSZeroRect];
    _body = [[ADIFDockBody alloc] initWithFrame:NSZeroRect];
    _body.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.documentView = _body;
    NSClipView *clip = _scroll.contentView;
    NSLayoutConstraint *fitW = [_body.widthAnchor constraintEqualToAnchor:clip.widthAnchor];
    NSLayoutConstraint *fitH = [_body.heightAnchor constraintEqualToAnchor:clip.heightAnchor];
    fitW.priority = fitH.priority = NSLayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [_body.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor], [_body.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [_body.widthAnchor constraintGreaterThanOrEqualToAnchor:clip.widthAnchor],
        [_body.heightAnchor constraintGreaterThanOrEqualToAnchor:clip.heightAnchor], fitW, fitH
    ]];
    [self addSubview:header];
    [self addSubview:_scroll];
    _titleAfterChoice = [_title.leadingAnchor constraintEqualToAnchor:_choice.trailingAnchor constant:4];
    _titleAfterTabs = [_title.leadingAnchor constraintEqualToAnchor:_tabs.trailingAnchor constant:6];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:kHeaderHeight],
        // The menu names the frame (what it shows); the title beside it, only what the window adds ("test.adi").
        [_choice.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:4],
        [_choice.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_tabs.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:4],
        [_tabs.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        _titleAfterChoice,
        [_title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_more.leadingAnchor constraintGreaterThanOrEqualToAnchor:_title.trailingAnchor constant:6],
        [_more.trailingAnchor constraintEqualToAnchor:_close.leadingAnchor constant:-4],
        [_more.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_more.widthAnchor constraintEqualToConstant:20],
        [_more.heightAnchor constraintEqualToConstant:16],
        [_close.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-4],
        [_close.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_close.widthAnchor constraintEqualToConstant:16],
        [_close.heightAnchor constraintEqualToConstant:16],
        [rule.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [rule.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [rule.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
        [_dropMark.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [_dropMark.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [_dropMark.topAnchor constraintEqualToAnchor:header.topAnchor],
        [_dropMark.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    return self;
}

- (void)setIndex:(int)index {
    _index = index;
    _header.index = index;
}

- (NSSize)leastSize {
    NSSize m = NSZeroSize;
    for (NSNumber *item in _items) {
        NSSize c = itemMinimum(item.intValue);
        m.width = std::max(m.width, c.width), m.height = std::max(m.height, c.height);
    }
    if (!_items.count) m = itemMinimum(_item);
    return NSMakeSize(m.width, m.height + kHeaderHeight);
}

- (void)showItems:(NSArray<NSNumber *> *)items front:(int)item title:(NSString *)title content:(NSView *)content {
    _items = [items copy] ?: @[];
    _item = item;
    // The window's title less the frame's name: "Map — test.adi" shows "— test.adi" beside the menu.
    NSString *name = itemName(item), *extra = title ?: @"";
    if ([extra hasPrefix:name]) extra = [[extra substringFromIndex:name.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    _title.stringValue = extra;
    [_choice selectItemWithTag:item];
    // One panel: its menu; more: a tab each.
    BOOL tabbed = _items.count > 1;
    _choice.hidden = tabbed;
    _tabs.hidden = !tabbed;
    _titleAfterChoice.active = !tabbed;
    _titleAfterTabs.active = tabbed;
    if (tabbed) {
        _tabs.segmentCount = (NSInteger)_items.count;
        for (NSUInteger i = 0; i < _items.count; ++i) {
            [_tabs setLabel:itemName(_items[i].intValue) forSegment:(NSInteger)i];
            [_tabs setTag:_items[i].intValue forSegment:(NSInteger)i];
            if (_items[i].intValue == item) _tabs.selectedSegment = (NSInteger)i;
        }
    }
    _close.toolTip = tabbed ? TF(@"Close {panel}", @{@"panel" : name}) : T(@"Close this frame");
    if (content && content == _content && content.superview == _body) return;
    if (_content.superview == _body) [_content removeFromSuperview];  // not when another frame has taken it
    _content = content;
    if (!content) return;
    // Filling the frame, but never smaller than what the content needs: the frame scrolls instead of hiding it.
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [_body addSubview:content];
    NSSize least = contentMinimum(_item);
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:_body.leadingAnchor], [content.topAnchor constraintEqualToAnchor:_body.topAnchor],
        [content.trailingAnchor constraintEqualToAnchor:_body.trailingAnchor], [content.bottomAnchor constraintEqualToAnchor:_body.bottomAnchor],
        [content.widthAnchor constraintGreaterThanOrEqualToConstant:least.width], [content.heightAnchor constraintGreaterThanOrEqualToConstant:least.height]
    ]];
}

- (void)chosen:(NSPopUpButton *)sender {
    int item = (int)sender.selectedItem.tag;
    [_choice selectItemWithTag:_item];  // the layout puts it right
    if (self.onChoose) self.onChoose(self.index, item);
}

- (void)tabChosen:(NSSegmentedControl *)sender {
    int item = (int)[sender tagForSegment:sender.selectedSegment];
    if (item != _item && self.onTab) self.onTab(self.index, item);
}

- (void)closePressed:(id)sender {
    if (self.onClose) self.onClose(self.index);
}

// The actions menu, as the frame is now: each panel not here to add as a tab; the tab in front
// to a frame of its own (with more than one); close the one in front.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != _more.menu) return;
    while (menu.numberOfItems > 1) [menu removeItemAtIndex:1];
    NSString *front = itemName(_item);
    NSMenu *add = [[NSMenu alloc] initWithTitle:T(@"Add Tab")];
    for (const panels::Spec &s : panels::all()) {
        int item = itemOf(s.id);
        if (item == kDockNone || [_items containsObject:@(item)] || item == _item) continue;
        NSMenuItem *mi = [add addItemWithTitle:itemName(item) action:@selector(addTabChosen:) keyEquivalent:@""];
        mi.target = self;
        mi.tag = item;
        mi.image = [NSImage imageWithSystemSymbolName:s.symbol accessibilityDescription:nil];
    }
    NSMenuItem *addItem = [menu addItemWithTitle:T(@"Add Tab") action:nil keyEquivalent:@""];
    addItem.submenu = add;
    addItem.identifier = @"frame.actions.addTab";
    NSMenuItem *split = [menu addItemWithTitle:TF(@"Move {panel} to Its Own Frame", @{@"panel" : front}) action:@selector(splitChosen:) keyEquivalent:@""];
    split.target = self;
    split.identifier = @"frame.actions.split";
    split.enabled = _items.count > 1;
    menu.autoenablesItems = NO;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *close = [menu addItemWithTitle:TF(@"Close {panel}", @{@"panel" : front}) action:@selector(closePressed:) keyEquivalent:@""];
    close.target = self;
    close.identifier = @"frame.actions.close";
}

- (void)addTabChosen:(NSMenuItem *)sender {
    if (self.onAddTab) self.onAddTab(self.index, (int)sender.tag);
}

- (void)splitChosen:(id)sender {
    if (self.onSplit) self.onSplit(self.index);
}

// Another frame dragged here by its header: over this one's header it would become a tab here;
// over its body the two would swap. Marked while it is over, then done on the drop.
- (int)draggedFrom:(id<NSDraggingInfo>)info {
    NSString *v = [info.draggingPasteboard stringForType:kFramePasteboardType];
    return v ? v.intValue : -1;
}
- (BOOL)overHeader:(id<NSDraggingInfo>)info {
    return NSPointInRect([_header convertPoint:info.draggingLocation fromView:nil], _header.bounds);
}
- (void)markDrop:(int)kind {  // 0 none, 1 swap (the frame), 2 a tab (the header)
    self.wantsLayer = YES;
    self.layer.borderWidth = kind == 1 ? 2 : 0;
    self.layer.borderColor = NSColor.controlAccentColor.CGColor;
    _dropMark.hidden = kind != 2;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    int from = [self draggedFrom:info];
    BOOL ok = from >= 0 && from != self.index;
    [self markDrop:ok ? ([self overHeader:info] ? 2 : 1) : 0];
    return ok ? NSDragOperationMove : NSDragOperationNone;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    return [self draggingUpdated:info];
}
- (void)draggingExited:(id<NSDraggingInfo>)info {
    [self markDrop:0];
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    [self markDrop:0];
    int from = [self draggedFrom:info];
    if (from < 0 || from == self.index) return NO;
    if ([self overHeader:info]) {
        if (!self.onStack) return NO;
        self.onStack(from, self.index);
    } else {
        if (!self.onSwap) return NO;
        self.onSwap(from, self.index);
    }
    return YES;
}
@end

@implementation ADIFDockPanel
ADIF_DOCKABLE_WINDOW
@end

@implementation ADIFDockWindow
ADIF_DOCKABLE_WINDOW
@end

namespace {
std::vector<std::pair<std::string, std::string>> gQsoFields;
ADIFDockPanel *gContactMapWindow;
ADIFDockPanel *gQsoInfoWindow;
workspace::QsoDetails gQsoDetails;  // what QSO Details shows, kept for when it opens

std::string fieldValue(const char *name) {
    for (const auto &field : gQsoFields)
        if (field.first == name) return field.second;
    return {};
}

bool countryBounds(const std::string &call, double *west, double *south, double *east, double *north) {
    const adif::CountryTable &countries = ADIFCountries();
    adif::CountryInfo entity;
    if (countries.empty() || !countries.lookup(call, &entity) || !entity.dxcc) return false;
    static size_t cachedEntities = 0;
    static std::map<int, std::vector<adif::RingRef>> ringsByEntity;
    if (cachedEntities != countries.entities()) {
        std::vector<adif::EntityPlace> places;
        for (const adif::CountryInfo &country : countries.all())
            places.push_back({country.dxcc, country.lat, country.lon, country.name});
        ringsByEntity = adif::dxccRings(places);
        cachedEntities = countries.entities();
    }
    auto found = ringsByEntity.find(entity.dxcc);
    if (found == ringsByEntity.end() || found->second.empty()) return false;
    *west = 999; *south = 999; *east = -999; *north = -999;
    bool foundAny = false;
    for (const adif::RingRef &ref : found->second) {
        adif::OverlayArea area = adif::overlayArea(adif::Overlay::Subunits, ref.area);
        if (ref.ring >= area.rings.size()) continue;
        const auto &ring = area.rings[ref.ring];
        double w = 999, s = 999, e = -999, n = -999;
        for (const auto &point : ring) {
            w = std::min(w, point.first); s = std::min(s, point.second);
            e = std::max(e, point.first); n = std::max(n, point.second);
        }
        *west = std::min(*west, w); *south = std::min(*south, s);
        *east = std::max(*east, e); *north = std::max(*north, n);
        foundAny = true;
    }
    return foundAny;
}
}  // namespace

@interface ADIFContactMapView : NSView
@end
@implementation ADIFContactMapView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    [[NSColor.controlBackgroundColor colorWithAlphaComponent:0.98] setFill];
    NSRectFill(bounds);

    double lat = 0, lon = 0;
    std::string grid = fieldValue("GRIDSQUARE");
    bool located = adif::gridToLatLon(grid, &lat, &lon);
    bool approximate = false;
    if (!located)
        located = adif::locationToDegrees(fieldValue("LAT"), true, &lat) &&
                  adif::locationToDegrees(fieldValue("LON"), false, &lon);
    adif::CountryInfo entity;
    bool hasEntity = !ADIFCountries().empty() && ADIFCountries().lookup(fieldValue("CALL"), &entity);
    if (!located && hasEntity) {
        lat = entity.lat;
        lon = entity.lon;
        located = approximate = true;
    }

    NSRect map = NSInsetRect(bounds, 12, 12);
    map.origin.y += 22;
    map.size.height -= 22;
    double west = -180, south = -82, east = 180, north = 85;
    bool countryZoom = located && countryBounds(fieldValue("CALL"), &west, &south, &east, &north);
    if (countryZoom) {
        // Show all mapped territory plus its surrounding region, while keeping the contact in view.
        west = std::min(west, lon); east = std::max(east, lon);
        south = std::min(south, lat); north = std::max(north, lat);
        double dx = std::max(30.0, east - west) * 0.14;
        double dy = std::max(20.0, north - south) * 0.14;
        west -= dx; east += dx; south -= dy; north += dy;
    } else if (located) {
        west = lon - 12; east = lon + 12; south = lat - 9; north = lat + 9;
    }
    south = std::max(-85.0, south); north = std::min(85.0, north);
    double centerLat = (south + north) / 2;
    double centerLon = (west + east) / 2;
    double cosLat = std::max(0.2, std::cos(centerLat * 3.14159265358979323846 / 180.0));
    double aspect = NSWidth(map) / std::max<CGFloat>(1, NSHeight(map));
    double lonSpan = std::max(1.0, east - west), latSpan = std::max(1.0, north - south);
    if (lonSpan * cosLat / latSpan > aspect)
        latSpan = lonSpan * cosLat / aspect;
    else
        lonSpan = latSpan * aspect / cosLat;
    west = centerLon - lonSpan / 2; east = centerLon + lonSpan / 2;
    south = std::max(-85.0, centerLat - latSpan / 2); north = std::min(85.0, centerLat + latSpan / 2);

    auto mapPoint = [&](double x, double y) {
        while (x - centerLon > 180) x -= 360;
        while (x - centerLon < -180) x += 360;
        return NSMakePoint(NSMinX(map) + (x - west) / std::max(1.0, east - west) * NSWidth(map),
                            NSMinY(map) + (north - y) / std::max(1.0, north - south) * NSHeight(map));
    };
    [[NSColor.tertiaryLabelColor colorWithAlphaComponent:0.25] setStroke];
    for (int i = 1; i < 6; ++i) {
        CGFloat x = NSMinX(map) + NSWidth(map) * i / 6.0;
        CGFloat y = NSMinY(map) + NSHeight(map) * i / 6.0;
        NSBezierPath *grid = [NSBezierPath bezierPath];
        [grid moveToPoint:NSMakePoint(x, NSMinY(map))]; [grid lineToPoint:NSMakePoint(x, NSMaxY(map))];
        [grid moveToPoint:NSMakePoint(NSMinX(map), y)]; [grid lineToPoint:NSMakePoint(NSMaxX(map), y)];
        [grid stroke];
    }
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(map);
    [[NSColor.systemGreenColor colorWithAlphaComponent:0.28] setFill];
    for (size_t i = 0; i < adif::layerShapeCount(adif::MapLayer::Land110); ++i) {
        auto points = adif::layerShape(adif::MapLayer::Land110, i);
        // Antarctica only when the contact is there: its outline runs round the date line, and closed
        // across the map it drew a band over the southern ocean.
        if (!(located && lat < -60) &&
            std::all_of(points.begin(), points.end(), [](const std::pair<double, double> &pt) { return pt.second < -60; }))
            continue;
        NSBezierPath *land = [NSBezierPath bezierPath];
        bool started = false;
        double previous = 0;
        for (const auto &point : points) {
            if (started && std::abs(point.first - previous) > 180) {
                [land closePath]; started = false;
            }
            NSPoint p = mapPoint(point.first, point.second);
            if (!started) [land moveToPoint:p], started = true;
            else [land lineToPoint:p];
            previous = point.first;
        }
        if (started) [land closePath];
        [land fill];
        [[NSColor.separatorColor colorWithAlphaComponent:0.35] setStroke];
        [land stroke];
    }
    double hlat = 0, hlon = 0;
    bool home = adif::gridToLatLon(fieldValue("MY_GRIDSQUARE"), &hlat, &hlon) ||
                adif::gridToLatLon(adifhost::setting("stationGrid"), &hlat, &hlon);
    if (home) {  // your station, and the way to the contact when both are in sight
        NSPoint h = mapPoint(hlon, hlat), p = located ? mapPoint(lon, lat) : h;
        if (NSPointInRect(h, map) && located) {
            NSBezierPath *line = [NSBezierPath bezierPath];
            [line moveToPoint:h];
            [line lineToPoint:p];
            line.lineWidth = 1.5;
            CGFloat dash[] = {4, 3};
            [line setLineDash:dash count:2 phase:0];
            [[NSColor.systemOrangeColor colorWithAlphaComponent:0.85] setStroke];
            [line stroke];
        }
        if (NSPointInRect(h, map)) {
            [NSColor.systemOrangeColor setFill];
            [[NSBezierPath bezierPathWithRect:NSMakeRect(h.x - 3.5, h.y - 3.5, 7, 7)] fill];
        }
    }
    if (located) {
        NSPoint p = mapPoint(lon, lat);
        [[NSColor.whiteColor colorWithAlphaComponent:0.95] setStroke];
        NSBezierPath *halo = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - 8, p.y - 8, 16, 16)];
        halo.lineWidth = 3; [halo stroke];
        [[NSColor.systemBlueColor colorWithAlphaComponent:0.95] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - 5.5, p.y - 5.5, 11, 11)] fill];
        NSBezierPath *marker = [NSBezierPath bezierPath];
        marker.lineWidth = 1.5;
        [marker appendBezierPathWithOvalInRect:NSMakeRect(p.x - 5.5, p.y - 5.5, 11, 11)];
        [NSColor.whiteColor setStroke]; [marker stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
    NSString *caption = approximate ? [NSString stringWithFormat:T(@"Approximate home location: %@"), ADIFString(entity.name)]
                       : located ? [NSString stringWithFormat:@"%@  ·  %.2f°, %.2f°", ADIFString(fieldValue("CALL")), lat, lon]
                                : T(@"A grid square (or LAT and LON) places the contact");
    if (located && home) {
        double km = adif::greatCircleKm(hlat, hlon, lat, lon);
        long bearing = std::lround(adif::initialBearing(hlat, hlon, lat, lon)) % 360;
        caption = [caption stringByAppendingFormat:@"  ·  %@",
                                                   ADIFString(trf("{distance} at {bearing}°", {{"distance", adif::distanceText(km, adifhost::setting("mapListUnits") == "mi")},
                                                                                               {"bearing", std::to_string(bearing)}}))];
    }
    NSMutableParagraphStyle *cut = [[NSMutableParagraphStyle alloc] init];
    cut.lineBreakMode = NSLineBreakByTruncatingTail;  // one line, ended with "..." in a narrow frame (its tooltip has it all)
    [caption drawInRect:NSMakeRect(kADIFMargin, 4, NSWidth(bounds) - 2 * kADIFMargin, 18)
         withAttributes:@{NSFontAttributeName : theme::small(),
                          NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
                          NSParagraphStyleAttributeName : cut}];
    self.toolTip = caption;
}
@end

// QSO Details: who you are working, and why it is worth having, as the Map's selected panel says it
// for a spot. A column of sections that wrap at the frame's width: the call and who it is; the
// reasons, each with its mark; the lookup's facts; this QSO; your QSOs with the call.
@interface ADIFQsoDetailsView : NSView
- (void)show:(const workspace::QsoDetails &)d;
@end

@implementation ADIFQsoDetailsView {
    NSStackView *_stack;
}

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _stack.alignment = NSLayoutAttributeLeading;
    _stack.spacing = 6;
    _stack.edgeInsets = NSEdgeInsetsMake(10, kADIFMargin, 12, kADIFMargin);
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.identifier = @"qsodetails.stack";
    [self addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:self.topAnchor], [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor],
    ]];
    [self show:workspace::QsoDetails()];
    return self;
}

// A view the column's width (less its margins), so text in it wraps there.
- (void)addFull:(NSView *)v {
    [_stack addArrangedSubview:v];
    [v.widthAnchor constraintEqualToAnchor:_stack.widthAnchor constant:-2 * kADIFMargin].active = YES;
}

- (NSTextField *)text:(const std::string &)text font:(NSFont *)font colour:(NSColor *)colour {
    NSTextField *t = ADIFWrappingLabel();
    t.stringValue = ADIFString(text);
    t.font = font;
    t.textColor = colour;
    t.selectable = YES;
    return t;
}

- (void)heading:(NSString *)title {
    NSTextField *h = [NSTextField labelWithString:[T(title) uppercaseString]];
    h.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize - 1 weight:NSFontWeightSemibold];
    h.textColor = NSColor.secondaryLabelColor;
    [_stack addArrangedSubview:h];
    [_stack setCustomSpacing:3 afterView:h];
    if (_stack.arrangedSubviews.count > 1) [_stack setCustomSpacing:12 afterView:_stack.arrangedSubviews[_stack.arrangedSubviews.count - 2]];
}

// Each reason's mark and colour: what the Map's selected panel uses for the same reason.
static NSString *reasonSymbol(int kind, NSColor **colour) {
    using K = adif::InterestKind;
    switch ((K)kind) {
        case K::Watched: *colour = NSColor.systemYellowColor; return @"star.fill";
        case K::Duplicate: *colour = NSColor.systemRedColor; return @"exclamationmark.triangle.fill";
        case K::NewForActivation: *colour = NSColor.systemGreenColor; return @"checkmark.circle.fill";
        case K::NewDxcc: *colour = NSColor.systemOrangeColor; return @"star.circle.fill";
        case K::NewBand: *colour = NSColor.systemBlueColor; return @"plus.circle.fill";
        case K::NewMode: *colour = NSColor.systemBlueColor; return @"plus.circle";
        case K::Worked: *colour = NSColor.secondaryLabelColor; return @"checkmark.circle";
        case K::Confirmed: *colour = NSColor.systemGreenColor; return @"checkmark.circle.fill";
        case K::ParkToPark: *colour = NSColor.systemGreenColor; return @"leaf.fill";
        case K::NewPark: *colour = NSColor.systemGreenColor; return @"leaf";
        case K::Before: *colour = NSColor.secondaryLabelColor; return @"person.crop.circle";
        case K::FirstQso: *colour = NSColor.secondaryLabelColor; return @"person.crop.circle.badge.plus";
    }
    *colour = NSColor.secondaryLabelColor;
    return @"circle";
}

- (void)show:(const workspace::QsoDetails &)d {
    for (NSView *v in [_stack.arrangedSubviews copy]) [v removeFromSuperview];
    NSFont *small = theme::small();
    if (d.call.empty()) {
        NSTextField *hint = [self text:tr("Type a call in New QSO: who it is, where, and why the contact is worth having show here, "
                                          "with your QSOs with it.")
                                  font:small
                                colour:NSColor.secondaryLabelColor];
        hint.identifier = @"qsodetails.hint";
        [self addFull:hint];
        return;
    }
    // Who: the call large, the operator beside it; where under them.
    NSTextField *call = [NSTextField labelWithString:ADIFString(d.call)];
    call.font = [NSFont monospacedSystemFontOfSize:20 weight:NSFontWeightSemibold];
    call.identifier = @"qsodetails.call";
    [call setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *who = [self text:d.who font:[NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium] colour:NSColor.labelColor];
    NSStackView *top = [NSStackView stackViewWithViews:@[ call, who ]];
    top.alignment = NSLayoutAttributeFirstBaseline;
    top.spacing = 10;
    [self addFull:top];
    if (!d.where.empty()) [self addFull:[self text:d.where font:small colour:NSColor.secondaryLabelColor]];

    if (!d.why.empty()) {
        [self heading:N(@"Why this contact")];
        for (const auto &[kind, text] : d.why) {
            NSColor *colour = nil;
            NSString *symbol = reasonSymbol(kind, &colour);
            NSImageView *mark = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] ?: [NSImage new]];
            mark.contentTintColor = colour;
            mark.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
            [mark setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
            [mark.widthAnchor constraintEqualToConstant:16].active = YES;
            NSTextField *line = [self text:text font:small colour:NSColor.labelColor];
            NSStackView *row = [NSStackView stackViewWithViews:@[ mark, line ]];
            row.alignment = NSLayoutAttributeFirstBaseline;
            row.spacing = 6;
            row.identifier = [NSString stringWithFormat:@"qsodetails.why.%d", kind];
            [self addFull:row];
        }
    }
    if (!d.facts.empty()) {
        [self heading:N(@"Lookup")];
        NSGridView *grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
        grid.rowSpacing = 3;
        grid.columnSpacing = 8;
        grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
        for (const auto &[label, value] : d.facts) {
            NSTextField *l = [NSTextField labelWithString:ADIFString(label)];
            l.font = small;
            l.textColor = NSColor.secondaryLabelColor;
            [grid addRowWithViews:@[ l, [self text:value font:small colour:NSColor.labelColor] ]];
        }
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        grid.identifier = @"qsodetails.facts";
        [self addFull:grid];
    }
    if (!d.qso.empty()) {
        [self heading:N(@"This QSO")];
        [self addFull:[self text:d.qso font:small colour:NSColor.labelColor]];
    }
    if (!d.history.empty()) {
        [self heading:N(@"Your QSOs with this call")];
        std::string lines;
        for (const std::string &h : d.history) lines += (lines.empty() ? "" : "\n") + h;
        NSTextField *list = [self text:lines font:theme::digits(NSFont.smallSystemFontSize, NSFontWeightRegular)
                                colour:NSColor.labelColor];
        list.identifier = @"qsodetails.history";
        [self addFull:list];
    }
}
@end

namespace {
void openAuxWindow(int item) {
    ADIFDockPanel *window = item == kDockContactMap ? gContactMapWindow : gQsoInfoWindow;
    if (!window) {
        window = [[ADIFDockPanel alloc] initWithContentRect:NSMakeRect(0, 0, 360, 250)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                   backing:NSBackingStoreBuffered defer:YES];
        window.releasedWhenClosed = NO;
        window.contentMinSize = NSMakeSize(240, 160);
        window.dockItem = item;
        window.title = item == kDockContactMap ? T(@"Contact Map") : T(@"QSO Details");
        window.contentView = item == kDockContactMap ? [[ADIFContactMapView alloc] initWithFrame:NSMakeRect(0, 0, 360, 250)]
                                                     : [[ADIFQsoDetailsView alloc] initWithFrame:NSMakeRect(0, 0, 360, 250)];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification  // closed (or its frame): the Map's button follows
                                                          object:window
                                                           queue:nil
                                                      usingBlock:^(NSNotification *) { ADIFPanelShownChanged(); }];
        if (item == kDockContactMap) gContactMapWindow = window;
        else gQsoInfoWindow = window;
    }
    if (item == kDockQsoInfo) [(ADIFQsoDetailsView *)window.contentView show:gQsoDetails];
    else [window.contentView setNeedsDisplay:YES];
    [window makeKeyAndOrderFront:nil];
    ADIFPanelShownChanged();
}
}  // namespace

// ── The layout's window ──

@interface ADIFWorkspaceWindow : NSWindow
@property(nonatomic, copy) BOOL (^keyEquivalent)(NSEvent *event);
@end

@implementation ADIFWorkspaceWindow
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.keyEquivalent && self.keyEquivalent(event)) return YES;
    return [super performKeyEquivalent:event];
}
@end

@interface ADIFWorkspace : NSObject <NSWindowDelegate, NSSplitViewDelegate, NSMenuDelegate>
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) NSWindow *host;
@property(nonatomic, copy) void (^onChange)(BOOL active);
+ (instancetype)shared;
- (BOOL)open;
- (BOOL)openActivation;
- (BOOL)openLogging;
- (NSMenuItem *)optionsMenuItem;
- (void)retitleMenu;
- (void)abandon;
- (void)closeLayout;
- (void)presetChosen:(NSMenuItem *)sender;
- (BOOL)shows:(int)item;
- (BOOL)dock:(NSWindow<ADIFDockable> *)window;
- (NSView *)contentOf:(int)item;
- (void)setStatus:(NSString *)text;
- (BOOL)hide:(NSWindow<ADIFDockable> *)window closing:(BOOL)closing;
- (void)retitle:(NSWindow<ADIFDockable> *)window;
@end

// The console: its arrangement (adif::layout; saved as `consoleLayout`, and the preset it came from
// as `consoleLayoutPreset`), shown as a tree of split views whose leaves are frames, one per stack
// of panels. Each panel is still the window it was: docked, its content sits in its frame (the
// front one of a stack shows; the others wait behind their tabs), and the window's own calls
// (show, close, visible, title) are answered for it. Only what has docked is shown; a panel in the
// arrangement that hasn't opened yet (New QSO before an activation's log exists) takes its place
// when it docks. A panel not in the arrangement opens as a window of its own.
@implementation ADIFWorkspace {
    ADIFWorkspaceWindow *_host;
    NSView *_treeHolder;
    NSTextField *_statusText, *_statusClock;
    NSTimer *_clock;
    layout::Arrangement _layout;
    std::string _presetId;  // the layout it started from, built in or yours ("mine:" and its name); Console Layout Options ticks it
    std::vector<layout::Named> _mine;  // your own layouts (Save Layout As...), kept as `consoleLayouts`
    std::map<std::string, layout::Arrangement> _styleLayouts;  // a style's own (its Save), by the style's id
    layout::Arrangement _beforeStyle;  // the console before a style last arranged it (Restore Previous Layout)
    std::string _beforeStyleId;
    BOOL _beforeStyleActive, _hasBeforeStyle;
    BOOL _builtListShows;  // the frames were sized with the Map's list showing
    BOOL _rebuilding;
    BOOL _loaded;
    BOOL _active, _batching, _closing, _sizing, _saveQueued;
    std::string _builtShape;  // the tree the frames were built for
    NSView *_root;            // the frames' tree
    NSMutableArray<ADIFDockFrame *> *_frames;               // one per stack shown, in order
    NSMutableDictionary<NSNumber *, NSValue *> *_window;   // by item (not retained: each is owned by its own module)
    NSMutableDictionary<NSNumber *, NSView *> *_content;   // the docked windows' content, while docked
    NSMapTable<NSView *, NSNumber *> *_shares;             // each frame's or split's share of its split
    NSMenu *_optionsMenu;
    NSMenuItem *_optionsMenuItem;
}

+ (instancetype)shared {
    static ADIFWorkspace *ws;
    if (!ws) ws = [[ADIFWorkspace alloc] init];
    return ws;
}

- (BOOL)active { return _active; }
- (NSWindow *)host { return _host; }

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _window = [NSMutableDictionary dictionary];
    _content = [NSMutableDictionary dictionary];
    _shares = [NSMapTable weakToStrongObjectsMapTable];
    _frames = [NSMutableArray array];
    return self;
}

- (NSWindow<ADIFDockable> *)windowOf:(int)item {
    return (NSWindow<ADIFDockable> *)_window[@(item)].nonretainedObjectValue;
}

// In the arrangement, and docked: showing (in front, or behind a tab).
- (BOOL)shows:(int)item {
    return item != kDockNone && _content[@(item)] && layout::inConsole(_layout, panelOf(item));
}

// What has docked, of what the arrangement holds: the tree shown.
- (layout::Arrangement)shownLayout {
    std::vector<std::string> docked;
    for (int item = 1; item < kDockCount; ++item)
        if (_content[@(item)]) docked.push_back(panelOf(item));
    return layout::tidy(_layout, docked);
}

- (const layout::Preset *)presetOf:(NSInteger)index {
    return index >= 0 && (size_t)index < layout::presets().size() ? &layout::presets()[(size_t)index] : nullptr;
}

// ── Settings ──

// Once: the saved arrangement, else the one the console's settings before it describe.
- (void)loadSettings {
    if (_loaded) return;
    _loaded = YES;
    std::string saved = adifhost::setting("consoleLayout");
    std::optional<layout::Arrangement> a = saved.empty() ? std::nullopt : layout::read(saved);
    _layout = a ? *a : layout::migrate([](const std::string &key) { return adifhost::setting(key); });
    _mine = layout::readNamed(adifhost::setting("consoleLayouts"));
    _presetId = adifhost::setting("consoleLayoutPreset");
    if (!saved.empty() && ![self arrangementFor:_presetId]) _presetId.clear();  // yours, since deleted: none ticked
    if (saved.empty() && !layout::preset(_presetId)) {
        std::string index = adifhost::setting("layoutPreset");
        int i = index.empty() ? 0 : std::clamp(atoi(index.c_str()), 0, (int)layout::presets().size() - 1);
        _presetId = layout::presets()[(size_t)i].id;
    }
    // The Map's panes, kept on their own before they were part of the arrangement: moved in, once.
    static const std::pair<const char *, const char *> kOldPanes[] = {{"mapSidebar", "sidebar"}, {"mapList", "list"}, {"mapSelected", "selected"}};
    bool moved = false;
    for (const auto &[key, pane] : kOldPanes) {
        std::string v = adifhost::setting(key);
        if (v != "0" && v != "1") continue;
        _layout = layout::setPane(_layout, layout::kMap, pane, v == "1");
        adifhost::setSetting(key, "");
        moved = true;
    }
    if (moved) [self saveSettings];
}

// A layout by its id: built in, yours ("mine:" and its name), or a style's own ("style:" and its id).
- (const layout::Arrangement *)arrangementFor:(const std::string &)id {
    if (const layout::Preset *p = layout::preset(id)) return &p->arrangement;
    if (id.rfind("style:", 0) == 0) {
        std::string style = id.substr(6);
        if (!_styleLayouts.count(style))
            if (std::optional<layout::Arrangement> a = layout::read(adifhost::setting(styleLayoutKey(style)))) _styleLayouts[style] = *a;
        auto it = _styleLayouts.find(style);
        return it == _styleLayouts.end() ? nullptr : &it->second;
    }
    if (id.rfind("mine:", 0) != 0) return nullptr;
    const layout::Named *n = layout::findNamed(_mine, id.substr(5));
    return n ? &n->arrangement : nullptr;
}

- (void)saveSettings {
    adifhost::setSetting("consoleLayout", layout::write(_layout));
    adifhost::setSetting("consoleLayoutPreset", _presetId);
}

// While a divider is dragged: saved once it rests.
- (void)queueSave {
    if (_saveQueued) return;
    _saveQueued = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_saveQueued = NO;
        [self saveSettings];
    });
}

// ── The window ──

- (void)makeHost {
    if (_host) return;
    _host = [[ADIFWorkspaceWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 800)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    _host.title = T(@"Operating Console");
    _host.identifier = @"loggingLayout.window";
    _host.releasedWhenClosed = NO;
    _host.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    _host.autorecalculatesKeyViewLoop = YES;
    _host.delegate = self;
    theme::host(_host);  // the console themes its frames, once
    __weak ADIFWorkspace *me = self;
    _host.keyEquivalent = ^BOOL(NSEvent *e) { return [me keyEquivalent:e]; };
    if (![_host setFrameUsingName:@"ADIFLoggingLayout"]) [_host setFrame:(_host.screen ?: NSScreen.mainScreen).visibleFrame display:NO];
    [_host setFrameAutosaveName:@"ADIFLoggingLayout"];

    NSView *root = _host.contentView;
    _treeHolder = [[NSView alloc] initWithFrame:NSZeroRect];
    _treeHolder.translatesAutoresizingMaskIntoConstraints = NO;
    // The status bar: the log and what was last done on the left, the UTC time on the right.
    NSView *status = [[NSView alloc] initWithFrame:NSZeroRect];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *statusRule = [[NSBox alloc] initWithFrame:NSZeroRect];
    statusRule.boxType = NSBoxSeparator;
    statusRule.translatesAutoresizingMaskIntoConstraints = NO;
    _statusText = [NSTextField labelWithString:gStatus.empty() ? @"" : ADIFString(gStatus)];
    _statusText.font = theme::small();
    _statusText.textColor = NSColor.secondaryLabelColor;
    _statusText.lineBreakMode = NSLineBreakByTruncatingTail;
    _statusText.identifier = @"loggingLayout.status";
    _statusText.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusText setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _statusClock = [NSTextField labelWithString:@""];
    _statusClock.font = theme::digits(NSFont.smallSystemFontSize, NSFontWeightRegular);
    _statusClock.textColor = NSColor.secondaryLabelColor;
    _statusClock.identifier = @"loggingLayout.clock";
    _statusClock.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusClock setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_statusClock setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSView *v in @[ statusRule, _statusText, _statusClock ]) [status addSubview:v];
    [root addSubview:_treeHolder];
    [root addSubview:status];
    [NSLayoutConstraint activateConstraints:@[
        [_treeHolder.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_treeHolder.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_treeHolder.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_treeHolder.bottomAnchor constraintEqualToAnchor:status.topAnchor constant:-kADIFMargin],
        [status.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [status.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [status.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [status.heightAnchor constraintEqualToConstant:kStatusHeight],
        [statusRule.topAnchor constraintEqualToAnchor:status.topAnchor],
        [statusRule.leadingAnchor constraintEqualToAnchor:status.leadingAnchor],
        [statusRule.trailingAnchor constraintEqualToAnchor:status.trailingAnchor],
        [_statusText.leadingAnchor constraintEqualToAnchor:status.leadingAnchor constant:kADIFMargin],
        [_statusText.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
        [_statusClock.leadingAnchor constraintEqualToAnchor:_statusText.trailingAnchor constant:kADIFSpacing],
        [_statusClock.trailingAnchor constraintEqualToAnchor:status.trailingAnchor constant:-kADIFMargin],
        [_statusClock.centerYAnchor constraintEqualToAnchor:status.centerYAnchor],
    ]];
}

- (BOOL)keyEquivalent:(NSEvent *)event {
    NSView *responder = [_host.firstResponder isKindOfClass:NSView.class] ? (NSView *)_host.firstResponder : nil;
    for (NSNumber *key in _content) {
        if (!responder || ![responder isDescendantOf:_content[key]]) continue;
        NSWindow *w = [self windowOf:key.intValue];
        if (w && [w performKeyEquivalent:event]) return YES;  // the Map's shortcuts
        if ([_content[key] performKeyEquivalent:event]) return YES;
        // Return and Escape belong to the frame with the focus, not to another frame's buttons.
        NSString *k = event.charactersIgnoringModifiers;
        return k.length == 1 && ([k characterAtIndex:0] == '\r' || [k characterAtIndex:0] == 27);
    }
    return NO;
}

// ── Opening and closing ──

- (BOOL)open {
    return [self openPreset:"" allowEmptyQso:NO];
}

// Start Logging, Start Activation and Start Contest: each its layout and its own set-up (the
// architecture's profiles; ADIFLint.mm and Contest.mm do the set-up). The console opened in the
// layout, or put in it when it is open. An activation's log may be made after it opens.
- (BOOL)openProfile:(const std::string &)layoutId allowEmptyQso:(BOOL)allowEmptyQso {
    if (_active) return [self applyPreset:layoutId], YES;
    return [self openPreset:layoutId allowEmptyQso:allowEmptyQso];
}

- (BOOL)openActivation {
    return [self openProfile:"activation" allowEmptyQso:YES];
}

- (BOOL)openLogging {
    return [self openProfile:"logging" allowEmptyQso:NO];
}

// A layout's arrangement: a built-in one keeps the panes as they are; yours brings its own.
- (void)takePreset:(const std::string &)id {
    const layout::Arrangement *a = [self arrangementFor:id];
    if (!a) return;
    bool mine = !layout::preset(id);
    auto panes = _layout.panes;
    _layout = *a;
    if (!mine) _layout.panes = panes;
    _presetId = id;
    if (mine) worldmap::applyPanes();
}

- (BOOL)openPreset:(const std::string &)presetId allowEmptyQso:(BOOL)allowEmptyQso {
    _closing = NO;
    [self loadSettings];
    if (!presetId.empty()) [self takePreset:presetId];
    if (!layout::inConsole(_layout, layout::kNewQso) && layout::shown(_layout).empty())  // nothing left: its layout again
        [self takePreset:[self arrangementFor:_presetId] ? _presetId : layout::presets()[0].id];
    [self saveSettings];
    [self makeHost];
    _active = YES;
    [self startClock];
    _batching = YES;
    _builtShape.clear();
    [_host makeKeyAndOrderFront:nil];
    BOOL ok = YES;
    for (int item = 1; item < kDockCount; ++item) {
        if (!layout::inConsole(_layout, panelOf(item))) continue;
        openItem(item);
        // New QSO must open, unless an activation's log is still to be made (it takes its place when it opens).
        if (![self windowOf:item].dockHost && item == kDockNewQso && !allowEmptyQso) {
            ok = NO;
            break;
        }
    }
    _batching = NO;
    if (!ok) {
        [self abandon];
        return NO;
    }
    [self rebuild];
    if (self.onChange) self.onChange(YES);
    return YES;
}

- (void)tickClock {
    static NSDateFormatter *f;
    if (!f) {
        f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"yyyy-MM-dd HH:mm:ss 'UTC'";
        f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    }
    _statusClock.stringValue = [f stringFromDate:NSDate.date];
}

- (void)startClock {
    [self tickClock];
    if (_clock) return;
    __weak ADIFWorkspace *me = self;
    _clock = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *) { [me tickClock]; }];
}

- (void)stopClock {
    [_clock invalidate];
    _clock = nil;
}

- (void)setStatus:(NSString *)text {
    _statusText.stringValue = text ?: @"";
}

- (void)abandon {
    [self undockAll:NO];
    [self stopClock];
    _active = NO;
    [_host orderOut:nil];
}

- (void)closeLayout {
    if (!_active) return;
    [self undockAll:YES];
    [self stopClock];
    _active = NO;
    [_host orderOut:nil];
    if (self.onChange) self.onChange(NO);
}

// A window's own content back in it, no longer docked.
- (void)undock:(int)item {
    NSWindow<ADIFDockable> *w = [self windowOf:item];
    NSView *content = _content[@(item)];
    if (w && content) {
        w.dockHost = nil;
        [content removeFromSuperview];
        content.translatesAutoresizingMaskIntoConstraints = YES;
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        w.contentView = content;
        theme::rehost(w);  // its own look again
    }
    [_content removeObjectForKey:@(item)];
    [_window removeObjectForKey:@(item)];
}

// Each window gets its own content back; those that were showing are told they closed.
- (void)undockAll:(BOOL)closed {
    _closing = YES;
    for (int item = 1; item < kDockCount; ++item) {
        NSWindow<ADIFDockable> *w = [self windowOf:item];
        if (!w || !_content[@(item)]) continue;
        BOOL shown = [self shows:item];
        [self undock:item];
        if (shown && closed) [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:w];
    }
    for (ADIFDockFrame *f in _frames) [f showItems:@[] front:kDockNone title:@"" content:nil];
    [_frames removeAllObjects];
    [_root removeFromSuperview];
    _root = nil;
    _builtShape.clear();
    worldmap::setListSuppressed(false);
    _closing = NO;
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == _host && _active && !_closing) [self closeLayout];
}

// ── Docking ──

- (BOOL)dock:(NSWindow<ADIFDockable> *)w {
    if (!_active || _closing || w.dockItem == kDockNone) return NO;
    int item = w.dockItem;
    // Its place in the arrangement; with none it stays a window of its own, rather than put out
    // what is in a frame (New QSO, in the middle of an activation).
    if (!layout::inConsole(_layout, panelOf(item))) return NO;
    if (!_content[@(item)]) {
        [w orderOut:nil];
        NSView *content = w.contentView;
        w.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
        _content[@(item)] = content;
        _window[@(item)] = [NSValue valueWithNonretainedObject:w];
        w.dockHost = _host;
        theme::rehost(w);  // the console's look: its content tinted once, by the console
    }
    if (!_batching) {  // shown: its tab to the front
        _layout = layout::bringToFront(_layout, panelOf(item));
        [self saveSettings];
    }
    [self rebuild];
    if (!_batching) [_host makeKeyAndOrderFront:nil];
    ADIFPanelShownChanged();
    return YES;
}

- (NSView *)contentOf:(int)item {
    return _content[@(item)];
}

- (BOOL)hide:(NSWindow<ADIFDockable> *)w closing:(BOOL)closing {
    if (!w.dockHost || _closing) return w.dockHost != nil;
    [self closeItem:w.dockItem];
    return YES;
}

// A panel out of the console: told it closed, its content back in its window.
- (void)closeItem:(int)item {
    if (item == kDockNone || !layout::inConsole(_layout, panelOf(item))) return;
    _layout = layout::hide(_layout, panelOf(item));
    [self saveSettings];
    NSWindow<ADIFDockable> *w = [self windowOf:item];
    if (w) [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:w];
    [self undock:item];
    ADIFPanelShownChanged();
    if (layout::shown([self shownLayout]).empty()) {
        [self closeLayout];
        return;
    }
    [self rebuild];
}

- (void)retitle:(NSWindow<ADIFDockable> *)w {
    for (ADIFDockFrame *f in _frames)
        if (f.item == w.dockItem && w.dockHost) [f showItems:f.items front:f.item title:w.title content:_content[@(w.dockItem)]];
}

- (int)frontOf:(int)index {
    return index >= 0 && (NSUInteger)index < _frames.count ? _frames[(NSUInteger)index].item : kDockNone;
}

// A frame dragged onto another's body: the two swap what they show.
- (void)swap:(int)from with:(int)to {
    int a = [self frontOf:from], b = [self frontOf:to];
    if (a == kDockNone || b == kDockNone || a == b) return;
    _layout = layout::swap(_layout, panelOf(a), panelOf(b));
    [self saveSettings];
    [self rebuild];
}

// A frame dragged onto another's header: its front panel a tab there.
- (void)stack:(int)from onto:(int)to {
    int a = [self frontOf:from], b = [self frontOf:to];
    if (a == kDockNone || b == kDockNone || a == b) return;
    _layout = layout::moveToTab(_layout, panelOf(a), panelOf(b));
    [self saveSettings];
    [self rebuild];
}

// A frame's Add Tab: the panel a tab there, from another frame, or opened into it.
- (void)addTab:(int)item to:(int)index {
    int here = [self frontOf:index];
    if (item == kDockNone || here == kDockNone || item == here) return;
    BOOL docked = layout::inConsole(_layout, panelOf(item));
    _layout = docked ? layout::moveToTab(_layout, panelOf(item), panelOf(here)) : layout::showInConsole(_layout, panelOf(item), panelOf(here));
    [self saveSettings];
    if (!docked) openItem(item);  // it docks into its place
    [self rebuild];
    ADIFPanelShownChanged();
}

// A frame's Move to Its Own Frame: its tab in front at the end of the console's top row.
- (void)splitOut:(int)index {
    int item = [self frontOf:index];
    if (item == kDockNone || _frames[(NSUInteger)index].items.count < 2) return;
    _layout = layout::showInConsole(layout::hide(_layout, panelOf(item)), panelOf(item));
    [self saveSettings];
    [self rebuild];
}

- (void)tab:(int)index item:(int)item {
    _layout = layout::bringToFront(_layout, panelOf(item));
    [self saveSettings];
    [self rebuild];
}

// A frame's menu: that item here. One already in the console swaps places with this frame's.
- (void)assign:(int)item to:(int)index {
    int old = [self frontOf:index];
    if (item == old || old == kDockNone) return;
    if (item == kDockNone) return [self closeItem:old];
    if (layout::inConsole(_layout, panelOf(item))) {
        _layout = layout::swap(_layout, panelOf(old), panelOf(item));
        [self saveSettings];
        [self rebuild];
        return;
    }
    _layout = layout::hide(layout::showInConsole(_layout, panelOf(item), panelOf(old)), panelOf(old));  // in its place
    [self saveSettings];
    NSWindow<ADIFDockable> *oldWindow = [self windowOf:old];
    if (oldWindow) [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:oldWindow];
    [self undock:old];
    openItem(item);
    [self rebuild];
    ADIFPanelShownChanged();
}

// A built-in layout: the panels it doesn't hold closed, those it does opened into their places.
- (void)applyPreset:(const std::string &)id {
    [self loadSettings];
    const layout::Arrangement *a = [self arrangementFor:id];
    if (!a) return;
    layout::Arrangement next = *a;
    if (layout::preset(id)) next.panes = _layout.panes;  // a built-in layout keeps the panes as they are; yours brings its own
    [self applyArrangement:next id:id];
}

// An arrangement, as the console's now: what it no longer holds closed, what it holds opened into its place.
- (void)applyArrangement:(const layout::Arrangement &)next id:(const std::string &)id {
    [self loadSettings];
    bool was[kDockCount] = {};
    for (int item = 1; item < kDockCount; ++item) was[item] = [self shows:item];
    bool panes = next.panes != _layout.panes;
    _layout = next;
    _presetId = id;
    [self saveSettings];
    if (panes) worldmap::applyPanes();
    if (!_active) return;
    _batching = YES;
    for (int item = 1; item < kDockCount; ++item) {
        bool in = layout::inConsole(_layout, panelOf(item));
        if (was[item] && !in) {
            NSWindow<ADIFDockable> *w = [self windowOf:item];
            if (w) [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:w];
            [self undock:item];
        } else if (!was[item] && in) {
            openItem(item);
        }
    }
    _batching = NO;
    _builtShape.clear();
    [self rebuild];
    ADIFPanelShownChanged();
}

// A layout chosen, the one ticked too: its panels back where it puts them (after tabs, swaps or closes).
- (void)presetChosen:(NSMenuItem *)sender {
    if (const layout::Preset *p = [self presetOf:sender.tag]) [self applyPreset:p->id];
}

// Console Layout Options' frames: in the console (at the end of its top row), or out of it.
- (void)frameToggled:(NSMenuItem *)sender {
    int item = (int)sender.tag;
    [self loadSettings];
    if (layout::inConsole(_layout, panelOf(item))) {
        if (_active) return [self closeItem:item];
        _layout = layout::hide(_layout, panelOf(item));
        [self saveSettings];
        return;
    }
    _layout = layout::showInConsole(_layout, panelOf(item));
    [self saveSettings];
    if (!_active) return;
    if (_content[@(item)]) {  // already docked (behind nothing: it was out of the arrangement)
        [self rebuild];
        return;
    }
    NSWindow<ADIFDockable> *w = [self windowOf:item];
    if (w.visible && !w.dockHost) [w orderOut:nil];  // its own window: into the console
    openItem(item);
}

// The frames back to their first sizes: the built-in layout's shares when the console is still its
// shape, else by what each needs.
- (void)resetSizes:(id)sender {
    [self loadSettings];
    const layout::Arrangement *p = [self arrangementFor:_presetId];
    if (p && shapeOf(p->console) == shapeOf(_layout.console)) {
        auto panes = _layout.panes;
        auto fronts = _layout;
        _layout = *p;
        _layout.panes = panes;
        for (const std::string &id : layout::shown(fronts))  // which tab is in front, as it was
            if (layout::inConsole(fronts, id)) {
                std::vector<const layout::Node *> stacks;
                stacksOf(fronts.console, stacks);
                for (const layout::Node *st : stacks)
                    if (st->front < st->panels.size() && st->panels[st->front] == id) _layout = layout::bringToFront(_layout, id);
            }
    } else {
        std::function<void(layout::Node &)> clear = [&](layout::Node &n) {
            n.share = 0;
            for (layout::Node &c : n.children) clear(c);
        };
        clear(_layout.console);
    }
    [self saveSettings];
    _builtShape.clear();
    [self rebuild];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self loadSettings];
    if (menu == _optionsMenu) [self fillMine];
    for (NSMenuItem *mi in menu.itemArray) {
        if (mi.action == @selector(presetChosen:)) {
            const layout::Preset *p = [self presetOf:mi.tag];
            mi.state = p && p->id == _presetId ? NSControlStateValueOn : NSControlStateValueOff;
        } else if (mi.action == @selector(frameToggled:)) {
            mi.state = layout::inConsole(_layout, panelOf((int)mi.tag)) ? NSControlStateValueOn : NSControlStateValueOff;
        } else if (mi.action == @selector(mineChosen:)) {
            mi.state = _presetId == "mine:" + std::string([mi.representedObject UTF8String]) ? NSControlStateValueOn : NSControlStateValueOff;
        } else if (mi.action == @selector(saveLayoutAs:)) {
            mi.enabled = _active;  // the console as it is
        } else if ([mi.identifier isEqualToString:@"org.nextpad.adiflint.layouts.delete"]) {
            mi.enabled = !_mine.empty();
        }
    }
}

// Your layouts in the menu: after the built-in ones, and in Delete Layout.
- (void)fillMine {
    for (NSMenuItem *mi in [_optionsMenu.itemArray copy])
        if ([mi.identifier hasPrefix:@"org.nextpad.adiflint.layouts.mine"]) [_optionsMenu removeItem:mi];
    NSInteger at = (NSInteger)layout::presets().size();
    if (!_mine.empty()) {
        NSMenuItem *rule = NSMenuItem.separatorItem;
        rule.identifier = @"org.nextpad.adiflint.layouts.mine.rule";
        [_optionsMenu insertItem:rule atIndex:at++];
    }
    NSMenu *remove = [[NSMenu alloc] initWithTitle:T(@"Delete Layout")];
    for (const layout::Named &n : _mine) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:ADIFString(n.name) action:@selector(mineChosen:) keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = ADIFString(n.name);
        mi.identifier = [@"org.nextpad.adiflint.layouts.mine." stringByAppendingString:ADIFString(n.name)];
        [_optionsMenu insertItem:mi atIndex:at++];
        NSMenuItem *gone = [remove addItemWithTitle:ADIFString(n.name) action:@selector(deleteChosen:) keyEquivalent:@""];
        gone.target = self;
        gone.representedObject = ADIFString(n.name);
    }
    for (NSMenuItem *mi in _optionsMenu.itemArray)
        if ([mi.identifier isEqualToString:@"org.nextpad.adiflint.layouts.delete"]) mi.submenu = remove;
}

- (void)mineChosen:(NSMenuItem *)sender {
    if (sender.representedObject) [self applyPreset:"mine:" + std::string([sender.representedObject UTF8String])];
}

- (void)deleteChosen:(NSMenuItem *)sender {
    std::string name = [sender.representedObject UTF8String] ?: "";
    _mine = layout::removeNamed(_mine, name);
    adifhost::setSetting("consoleLayouts", layout::writeNamed(_mine));
    if (layout::sameName(_presetId, "mine:" + name)) _presetId.clear();  // none ticked: the console stays as it is
    [self saveSettings];
}

// The frames' sizes now, as shares of their splits (saved with a layout; a divider dragged records its own).
- (void)recordShares:(NSView *)v {
    if (![v isKindOfClass:NSSplitView.class]) return;
    NSSplitView *s = (NSSplitView *)v;
    layout::Node *n = nodeAt(_layout.console, s.identifier ?: @"");
    double total = 0;
    for (NSView *k in s.subviews) total += s.isVertical ? NSWidth(k.frame) : NSHeight(k.frame);
    if (n && n->children.size() == s.subviews.count && total > 0)
        for (NSUInteger i = 0; i < s.subviews.count; ++i)
            n->children[i].share = (s.isVertical ? NSWidth(s.subviews[i].frame) : NSHeight(s.subviews[i].frame)) / total;
    for (NSView *k in s.subviews) [self recordShares:k];
}

// Save Layout As...: a name for the console as it is, on a sheet; a name you have used replaces that layout.
- (void)saveLayoutAs:(id)sender {
    if (!_active || _host.attachedSheet) return;
    NSWindow *sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 160) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSTextField *title = [NSTextField labelWithString:T(@"Save Layout As")];
    title.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    NSTextField *help = [NSTextField wrappingLabelWithString:T(@"A layout of your own: the console's panels, tabs and frame sizes as they are "
                                                               @"now, and the Map's panes. Console Layout Options lists it with the others.")];
    help.font = theme::small();
    help.textColor = NSColor.secondaryLabelColor;
    NSTextField *name = ADIFTextField(@"Name, e.g. Evening on 40m", 300);
    name.identifier = @"layouts.name";
    if (_presetId.rfind("mine:", 0) == 0) name.stringValue = ADIFString(_presetId.substr(5));  // yours, to save again
    NSButton *cancel = [NSButton buttonWithTitle:T(@"Cancel") target:nil action:nil];
    cancel.keyEquivalent = @"\033";
    cancel.identifier = @"layouts.cancel";
    NSButton *save = [NSButton buttonWithTitle:T(@"Save") target:nil action:nil];
    save.keyEquivalent = @"\r";
    save.identifier = @"layouts.save";
    __weak ADIFWorkspace *me = self;
    __weak NSWindow *weakSheet = sheet;
    auto retitle = [=] {  // Replace when the name is one of yours
        ADIFWorkspace *ws = me;
        save.title = ws && layout::findNamed(ws->_mine, layout::cleanName(name.stringValue.UTF8String ?: "")) ? T(@"Replace") : T(@"Save");
    };
    retitle();
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:NSControlTextDidChangeNotification
                                                                  object:name
                                                                   queue:nil
                                                              usingBlock:^(NSNotification *) { retitle(); }];
    ADIFOnAction(cancel, ^{ [weakSheet.sheetParent endSheet:weakSheet returnCode:NSModalResponseCancel]; });
    ADIFOnAction(save, ^{
        ADIFWorkspace *ws = me;
        std::string clean = layout::cleanName(name.stringValue.UTF8String ?: "");
        if (!ws || clean.empty()) return NSBeep();
        [ws keepLayoutAs:clean];
        [weakSheet.sheetParent endSheet:weakSheet returnCode:NSModalResponseOK];
    });
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ cancel, save ]];
    buttons.spacing = kADIFSpacing;
    NSStackView *stack = [NSStackView stackViewWithViews:@[ title, help, name, buttons ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(16, 18, 16, 18);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [sheet.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:sheet.contentView.topAnchor], [stack.leadingAnchor constraintEqualToAnchor:sheet.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:sheet.contentView.trailingAnchor], [stack.bottomAnchor constraintEqualToAnchor:sheet.contentView.bottomAnchor],
        [help.widthAnchor constraintEqualToConstant:384], [name.widthAnchor constraintEqualToAnchor:help.widthAnchor],
    ]];
    [stack setCustomSpacing:14 afterView:name];
    [buttons.trailingAnchor constraintEqualToAnchor:help.trailingAnchor].active = YES;
    sheet.initialFirstResponder = name;
    theme::host(sheet);
    [_host beginSheet:sheet completionHandler:^(NSModalResponse) { [NSNotificationCenter.defaultCenter removeObserver:observer]; }];
}

// The console as it is, sizes included, kept as your layout of that name (and ticked).
- (void)keepLayoutAs:(const std::string &)name {
    if (_root && layout::shown([self shownLayout]) == layout::shown(_layout)) [self recordShares:_root];
    _mine = layout::saveNamed(_mine, name, _layout);
    adifhost::setSetting("consoleLayouts", layout::writeNamed(_mine));
    _presetId = "mine:" + layout::findNamed(_mine, name)->name;
    [self saveSettings];
}

// ── Operating styles arrange the panels (the Map's style menu) ──

- (std::string)styleLayoutId:(const std::string &)style {
    std::string own = "style:" + style;
    return [self arrangementFor:own] ? own : style;  // its own (Save), else its built-in layout
}

// The text field being typed in, if any: it keeps the keyboard when a style moves the panels.
- (NSView *)typingField {
    NSResponder *r = NSApp.keyWindow.firstResponder;
    if (![r isKindOfClass:NSTextView.class] || !((NSTextView *)r).isFieldEditor) return nil;
    id field = ((NSTextView *)r).delegate;
    return [field isKindOfClass:NSView.class] ? field : nil;
}

- (void)arrangeForStyle:(const std::string &)style {
    [self loadSettings];
    std::string id = [self styleLayoutId:style];
    if (![self arrangementFor:id]) return;
    _beforeStyle = _layout, _beforeStyleId = _presetId, _beforeStyleActive = _active, _hasBeforeStyle = YES;
    NSView *typing = [self typingField];
    if (_active) [self applyPreset:id];
    else [self openPreset:id allowEmptyQso:YES];  // no log yet: New QSO's place waits for one
    if (typing.window) [typing.window makeFirstResponder:typing];
}

- (void)keepStyleLayout:(const std::string &)style {
    [self loadSettings];
    if (!_active) return;
    if (_root && layout::shown([self shownLayout]) == layout::shown(_layout)) [self recordShares:_root];
    adifhost::setSetting(styleLayoutKey(style), layout::write(_layout));
    _styleLayouts[style] = _layout;
    _presetId = "style:" + style;
    [self saveSettings];
}

- (void)forgetStyleLayout:(const std::string &)style {
    adifhost::setSetting(styleLayoutKey(style), "");
    _styleLayouts.erase(style);
}

- (BOOL)styleLayoutDiffers:(const std::string &)style {
    [self loadSettings];
    const layout::Arrangement *a = [self arrangementFor:[self styleLayoutId:style]];
    return _active && a && shapeOf(a->console) != shapeOf(_layout.console);
}

- (BOOL)styleLayoutIsOwn:(const std::string &)style {
    [self loadSettings];
    return [self arrangementFor:"style:" + style] != nullptr;
}

// Restore Previous Layout: the console as it was before the style arranged it (when it was open;
// opened by the style, it stays open: closing it puts each panel back in its window).
- (void)restoreBeforeStyle {
    if (!_hasBeforeStyle) return;
    _hasBeforeStyle = NO;
    if (_beforeStyleActive && _active) [self applyArrangement:_beforeStyle id:_beforeStyleId];
}

// The panes of a panel (the Map's sidebar, list and selected panel), as the arrangement has them.
- (BOOL)paneShown:(const char *)panel pane:(const char *)pane {
    [self loadSettings];
    return layout::paneShown(_layout, panel, pane);
}

- (void)setPane:(const char *)panel pane:(const char *)pane shown:(BOOL)on {
    [self loadSettings];
    if (layout::paneShown(_layout, panel, pane) == (bool)on && _layout.panes.count(panel) && _layout.panes[panel].count(pane)) return;
    _layout = layout::setPane(_layout, panel, pane, on);
    [self saveSettings];
    if (!strcmp(panel, layout::kMap) && !strcmp(pane, "list")) [self rebuild];  // the Map's least size follows its list
}

- (NSMenuItem *)optionsMenuItem {
    if (_optionsMenuItem) return _optionsMenuItem;
    [self loadSettings];
    _optionsMenu = [[NSMenu alloc] initWithTitle:T(@"Console Layout Options")];
    _optionsMenu.delegate = self;
    for (size_t i = 0; i < layout::presets().size(); ++i) {
        NSMenuItem *mi = [_optionsMenu addItemWithTitle:T(@(layout::presets()[i].name)) action:@selector(presetChosen:) keyEquivalent:@""];
        mi.target = self;
        mi.tag = (NSInteger)i;
    }
    [_optionsMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *saveAs = [_optionsMenu addItemWithTitle:T(@"Save Layout As...") action:@selector(saveLayoutAs:) keyEquivalent:@""];
    saveAs.target = self;
    saveAs.identifier = @"org.nextpad.adiflint.layouts.save";
    NSMenuItem *remove = [_optionsMenu addItemWithTitle:T(@"Delete Layout") action:nil keyEquivalent:@""];
    remove.identifier = @"org.nextpad.adiflint.layouts.delete";
    remove.submenu = [[NSMenu alloc] initWithTitle:T(@"Delete Layout")];
    _optionsMenu.autoenablesItems = NO;  // Save Layout As... and Delete Layout as menuNeedsUpdate sets them
    [_optionsMenu addItem:NSMenuItem.separatorItem];
    for (int item : {kDockNewQso, kDockLog, kDockSpots, kDockContactMap, kDockQsoInfo, kDockMap}) {
        NSMenuItem *mi = [_optionsMenu addItemWithTitle:itemName(item) action:@selector(frameToggled:) keyEquivalent:@""];
        mi.target = self;
        mi.tag = item;
    }
    [_optionsMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *reset = [_optionsMenu addItemWithTitle:T(@"Reset Frame Sizes") action:@selector(resetSizes:) keyEquivalent:@""];
    reset.target = self;
    _optionsMenuItem = [[NSMenuItem alloc] initWithTitle:T(@"Console Layout Options") action:nil keyEquivalent:@""];
    _optionsMenuItem.submenu = _optionsMenu;
    return _optionsMenuItem;
}

- (void)retitleMenu {
    if (_host) _host.title = T(@"Operating Console");
    if (gContactMapWindow) gContactMapWindow.title = T(@"Contact Map");
    if (gQsoInfoWindow) gQsoInfoWindow.title = T(@"QSO Details");
    if (!_optionsMenuItem) return;
    _optionsMenuItem.title = T(@"Console Layout Options");
    _optionsMenu.title = _optionsMenuItem.title;
    for (NSMenuItem *mi in _optionsMenu.itemArray) {
        if (mi.action == @selector(presetChosen:) && [self presetOf:mi.tag])
            mi.title = T(@([self presetOf:mi.tag]->name));
        else if (mi.action == @selector(frameToggled:))
            mi.title = itemName((int)mi.tag);
        else if (mi.action == @selector(resetSizes:))
            mi.title = T(@"Reset Frame Sizes");
        else if (mi.action == @selector(saveLayoutAs:))
            mi.title = T(@"Save Layout As...");
        else if ([mi.identifier isEqualToString:@"org.nextpad.adiflint.layouts.delete"])
            mi.title = T(@"Delete Layout");
    }
}

// ── The frames' tree ──

static NSSize minimumOf(NSView *v) {
    if ([v isKindOfClass:ADIFDockFrame.class]) return [(ADIFDockFrame *)v leastSize];
    if (![v isKindOfClass:NSSplitView.class]) return NSZeroSize;
    NSSplitView *s = (NSSplitView *)v;
    NSSize m = NSZeroSize;
    for (NSView *k in s.subviews) {
        NSSize c = minimumOf(k);
        if (s.isVertical) m.width += c.width + s.dividerThickness, m.height = std::max(m.height, c.height);
        else m.height += c.height + s.dividerThickness, m.width = std::max(m.width, c.width);
    }
    if (s.isVertical) m.width -= s.dividerThickness;
    else m.height -= s.dividerThickness;
    return m;
}

// What a frame or split needs, as its share of the room: at the window's least size each gets its least.
static double weightOf(NSView *v, bool width) {
    NSSize m = minimumOf(v);
    return std::max<CGFloat>(width ? m.width : m.height, 1);
}

- (ADIFDockFrame *)newFrame:(int)index {
    __weak ADIFWorkspace *me = self;
    ADIFDockFrame *f = [[ADIFDockFrame alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
    f.index = index;
    f.onChoose = ^(int at, int item) { [me assign:item to:at]; };
    f.onClose = ^(int at) {
        ADIFWorkspace *ws = me;
        [ws closeItem:[ws frontOf:at]];
    };
    f.onSwap = ^(int from, int to) { [me swap:from with:to]; };
    f.onStack = ^(int from, int to) { [me stack:from onto:to]; };
    f.onTab = ^(int at, int item) { [me tab:at item:item]; };
    f.onAddTab = ^(int at, int item) { [me addTab:item to:at]; };
    f.onSplit = ^(int at) { [me splitOut:at]; };
    return f;
}

// A node as views: a stack its frame; a row or column a split view (named by its path, for its shares).
- (NSView *)buildNode:(const layout::Node &)n path:(NSString *)path {
    if (n.kind == layout::Node::Kind::Stack) {
        ADIFDockFrame *f = [self newFrame:(int)_frames.count];
        [_frames addObject:f];
        if (n.share > 0) [_shares setObject:@(n.share) forKey:f];
        return f;
    }
    NSSplitView *s = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    s.vertical = n.kind == layout::Node::Kind::Row;
    s.dividerStyle = NSSplitViewDividerStyleThin;
    s.delegate = self;
    s.arrangesAllSubviews = YES;
    s.identifier = path;
    for (size_t i = 0; i < n.children.size(); ++i)
        [s addSubview:[self buildNode:n.children[i] path:[NSString stringWithFormat:@"%@%@%zu", path, path.length ? @"." : @"", i]]];
    if (n.share > 0) [_shares setObject:@(n.share) forKey:s];
    return s;
}

// Each split's first sizes: its children's shares when each has one, else what each needs.
- (void)defaultSizes:(NSView *)v {
    if (![v isKindOfClass:NSSplitView.class]) return;
    NSSplitView *s = (NSSplitView *)v;
    bool width = s.isVertical;
    bool shared = true;
    for (NSView *k in s.subviews) shared &= [_shares objectForKey:k] != nil;
    auto weight = [&](NSView *k) { return shared ? [_shares objectForKey:k].doubleValue : weightOf(k, width); };
    double total = 0;
    for (NSView *k in s.subviews) total += weight(k);
    CGFloat room = (width ? NSWidth(s.bounds) : NSHeight(s.bounds)) - s.dividerThickness * (s.subviews.count - 1);
    double sofar = 0;
    for (NSUInteger i = 0; i + 1 < s.subviews.count && total > 0; ++i) {
        sofar += weight(s.subviews[i]);
        [s setPosition:std::round(room * sofar / total) + s.dividerThickness * i ofDividerAtIndex:(NSInteger)i];
    }
    [s layoutSubtreeIfNeeded];
    for (NSView *k in s.subviews) [self defaultSizes:k];
}

- (void)rebuild {
    if (!_active || _batching || _closing || _rebuilding) return;
    _rebuilding = YES;
    layout::Arrangement shown = [self shownLayout];
    // The Map's own list hidden while a table of the same records (the Log Table, or the spots) is beside it.
    bool listBeside = layout::inConsole(shown, layout::kMap) && (layout::inConsole(shown, layout::kLogTable) || layout::inConsole(shown, layout::kSpots));
    gMapListShows = layout::inConsole(shown, layout::kMap) && !listBeside && layout::paneShown(_layout, layout::kMap, "list");
    if (gMapListShows != _builtListShows) _builtShape.clear();  // the Map's least size changed: sized afresh
    _builtListShows = gMapListShows;
    std::vector<const layout::Node *> stacks;
    stacksOf(shown.console, stacks);
    std::string shape = shapeOf(shown.console);
    if (shape != _builtShape) {
        _builtShape = shape;
        for (ADIFDockFrame *f in _frames) [f showItems:@[] front:kDockNone title:@"" content:nil];
        [_frames removeAllObjects];
        [_root removeFromSuperview];
        _root = nil;
        if (!stacks.empty()) {
            _sizing = YES;
            _root = [self buildNode:shown.console path:@""];
            _root.translatesAutoresizingMaskIntoConstraints = NO;
            [_treeHolder addSubview:_root];
            [NSLayoutConstraint activateConstraints:@[
                [_root.topAnchor constraintEqualToAnchor:_treeHolder.topAnchor],
                [_root.leadingAnchor constraintEqualToAnchor:_treeHolder.leadingAnchor],
                [_root.trailingAnchor constraintEqualToAnchor:_treeHolder.trailingAnchor],
                [_root.bottomAnchor constraintEqualToAnchor:_treeHolder.bottomAnchor],
            ]];
            // The window at least as big as the new tree needs before its frames are sized, so none starts below its least.
            NSSize least = minimumOf(_root);
            _host.contentMinSize = NSMakeSize(std::max<CGFloat>(least.width, 480), least.height + kStatusHeight + kADIFMargin);
            NSSize now = _host.contentView.frame.size;
            if (now.width < _host.contentMinSize.width || now.height < _host.contentMinSize.height)
                [_host setContentSize:NSMakeSize(std::max(now.width, _host.contentMinSize.width), std::max(now.height, _host.contentMinSize.height))];
            [_host.contentView layoutSubtreeIfNeeded];
            [self defaultSizes:_root];
            _sizing = NO;
        }
    }
    // Each stack's panels in its frame, the front one's content showing.
    for (size_t i = 0; i < stacks.size() && i < _frames.count; ++i) {
        NSMutableArray<NSNumber *> *items = [NSMutableArray array];
        for (const std::string &id : stacks[i]->panels) [items addObject:@(itemOf(id))];
        int front = itemOf(stacks[i]->panels[std::min(stacks[i]->front, stacks[i]->panels.size() - 1)]);
        NSWindow<ADIFDockable> *w = [self windowOf:front];
        [_frames[i] showItems:items front:front title:w ? w.title : @"" content:_content[@(front)]];
    }
    NSSize m = _root ? minimumOf(_root) : NSZeroSize;
    _host.contentMinSize = NSMakeSize(std::max<CGFloat>(m.width, 480), m.height + kStatusHeight + kADIFMargin);
    // Keep the standalone Map's list in its normal state; the static contact map has no log list.
    worldmap::setListSuppressed(listBeside);
    _rebuilding = NO;
}

// ── Split delegate: no frame below its least size; a divider dragged keeps its shares ──

- (CGFloat)splitView:(NSSplitView *)s constrainMinCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)i {
    NSView *v = s.subviews[(NSUInteger)i];
    NSSize m = minimumOf(v);
    return (s.isVertical ? NSMinX(v.frame) + m.width : NSMinY(v.frame) + m.height);
}

- (CGFloat)splitView:(NSSplitView *)s constrainMaxCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)i {
    NSView *next = s.subviews[(NSUInteger)i + 1];
    NSSize m = minimumOf(next);
    return (s.isVertical ? NSMaxX(next.frame) - m.width : NSMaxY(next.frame) - m.height) - s.dividerThickness;
}

- (void)splitViewDidResizeSubviews:(NSNotification *)notification {
    NSSplitView *s = notification.object;
    // Only a divider dragged (not the window resized, nor the frames' first sizes), and only while
    // the tree shown is the whole arrangement (its paths then name the same nodes).
    if (_sizing || _batching || !_active || _host.inLiveResize || NSApp.currentEvent.type != NSEventTypeLeftMouseDragged) return;
    if (layout::shown([self shownLayout]) != layout::shown(_layout)) return;
    layout::Node *n = nodeAt(_layout.console, s.identifier ?: @"");
    if (!n || n->children.size() != s.subviews.count) return;
    double total = 0;
    for (NSView *k in s.subviews) total += s.isVertical ? NSWidth(k.frame) : NSHeight(k.frame);
    if (total <= 0) return;
    for (NSUInteger i = 0; i < s.subviews.count; ++i)
        n->children[i].share = (s.isVertical ? NSWidth(s.subviews[i].frame) : NSHeight(s.subviews[i].frame)) / total;
    [self queueSave];
}

@end

// ── What the docked windows and the menu call ──

namespace workspace {

static std::function<void(bool)> gOnChange;

bool active() { return ADIFWorkspace.shared.active; }

bool open() {
    if (ADIFWorkspace.shared.active) return true;
    ADIFWorkspace *ws = ADIFWorkspace.shared;
    ws.onChange = ^(BOOL on) {
        if (gOnChange) gOnChange(on);
    };
    return [ws open];
}

bool openActivation() {
    ADIFWorkspace *ws = ADIFWorkspace.shared;
    ws.onChange = ^(BOOL on) {
        if (gOnChange) gOnChange(on);
    };
    return [ws openActivation];
}

bool openContest() {
    ADIFWorkspace *ws = ADIFWorkspace.shared;
    ws.onChange = ^(BOOL on) {
        if (gOnChange) gOnChange(on);
    };
    return [ws openProfile:"contest" allowEmptyQso:NO];
}

bool openLogging() {
    ADIFWorkspace *ws = ADIFWorkspace.shared;
    ws.onChange = ^(BOOL on) {
        if (gOnChange) gOnChange(on);
    };
    return [ws openLogging];
}

void abandon() { [ADIFWorkspace.shared abandon]; }

void close() { [ADIFWorkspace.shared closeLayout]; }

NSMenuItem *optionsMenuItem() { return [ADIFWorkspace.shared optionsMenuItem]; }

void retitleMenu() { [ADIFWorkspace.shared retitleMenu]; }

void setStatus(const std::string &text) {
    gStatus = text;
    [ADIFWorkspace.shared setStatus:ADIFString(text)];
}

void setQsoFields(const std::vector<std::pair<std::string, std::string>> &fields) {
    gQsoFields = fields;
    [gContactMapWindow.contentView setNeedsDisplay:YES];
}

void setQsoDetails(const QsoDetails &details) {
    gQsoDetails = details;
    if (gQsoInfoWindow) [(ADIFQsoDetailsView *)gQsoInfoWindow.contentView show:details];
}

bool qsoDetailsShown() { return gQsoInfoWindow && gQsoInfoWindow.visible; }

void openContactMap() { openAuxWindow(kDockContactMap); }

void openQsoInfo() { openAuxWindow(kDockQsoInfo); }

bool contactMapShown() { return gContactMapWindow && gContactMapWindow.visible; }

void toggleContactMap() {
    if (!contactMapShown()) return openContactMap();
    [gContactMapWindow performClose:nil];  // docked: its frame closes
    ADIFPanelShownChanged();
}

void toggleQsoDetails() {
    if (!qsoDetailsShown()) return openQsoInfo();
    [gQsoInfoWindow performClose:nil];
    ADIFPanelShownChanged();
}

void setOnChange(std::function<void(bool)> onChange) { gOnChange = std::move(onChange); }

bool show(NSWindow<ADIFDockable> *window) { return [ADIFWorkspace.shared dock:window]; }

bool hide(NSWindow<ADIFDockable> *window, bool closing) { return [ADIFWorkspace.shared hide:window closing:closing]; }

bool paneShown(const char *panel, const char *pane) { return [ADIFWorkspace.shared paneShown:panel pane:pane]; }

bool stylesArrange() { return adifhost::setting("stylesArrangePanels") != "0"; }

void setStylesArrange(bool on) { adifhost::setSetting("stylesArrangePanels", on ? "1" : "0"); }

void styleChosen(const std::string &style) {
    if (!style.empty() && stylesArrange()) [ADIFWorkspace.shared arrangeForStyle:style];
}

void keepStyleLayout(const std::string &style) {
    if (stylesArrange()) [ADIFWorkspace.shared keepStyleLayout:style];
}

void forgetStyleLayout(const std::string &style) { [ADIFWorkspace.shared forgetStyleLayout:style]; }

bool styleLayoutDiffers(const std::string &style) { return stylesArrange() && [ADIFWorkspace.shared styleLayoutDiffers:style]; }

void restoreBeforeStyle() { [ADIFWorkspace.shared restoreBeforeStyle]; }

std::string styleLayoutName(const std::string &style) {
    if (!stylesArrange()) return tr("Not arranged: Arrange Panels is off");
    if ([ADIFWorkspace.shared styleLayoutIsOwn:style]) return tr("Yours, kept with Save");
    const adif::layout::Preset *p = adif::layout::preset(style);
    return p ? tr(p->name) : std::string();
}

void setPane(const char *panel, const char *pane, bool shown) { [ADIFWorkspace.shared setPane:panel pane:pane shown:shown]; }

bool visible(NSWindow<ADIFDockable> *window) {
    ADIFWorkspace *ws = ADIFWorkspace.shared;
    return ws.active && ws.host.isVisible && [ws shows:window.dockItem];
}

NSView *content(NSWindow<ADIFDockable> *window) { return [ADIFWorkspace.shared contentOf:window.dockItem]; }

void retitle(NSWindow<ADIFDockable> *window) {
    if (window.dockHost) [ADIFWorkspace.shared retitle:window];
}

}  // namespace workspace
