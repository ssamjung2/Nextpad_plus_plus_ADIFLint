// The Operating Console: see Workspace.h.
#import "Workspace.h"

#import "L10n.h"
#import "Map.h"
#import "Night.h"
#import "ToolWindow.h"
#import "PluginHost.h"
#import "Country.h"
#include "adif_geo.h"
#include "adif_needs.h"
#include "adif_parks.h"
#include "adif_world.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <vector>

namespace {

const CGFloat kStatusHeight = 22;
constexpr NSInteger kActivationPreset = 7;
constexpr NSInteger kLoggingPreset = 8;
std::string gStatus;

// ── The layouts ──

// A layout is a tree of frames: positions (0 to 4) in rows ('H', side by side) or columns ('V',
// stacked). Each position shows an item; a position with none is left out.
// A node's share is how much of its split it takes to begin with, beside its siblings' shares
// (when every one of them has one); else the split goes by what each needs (itemWeight).
struct Node {
    char kind = 'P';
    int position = 0;
    std::vector<Node> kids;
    double share = 0;
};
Node P(int position, double share = 0) {
    Node n;
    n.position = position;
    n.share = share;
    return n;
}
Node H(std::vector<Node> kids, double share = 0) {
    Node n;
    n.kind = 'H';
    n.kids = std::move(kids);
    n.share = share;
    return n;
}
Node V(std::vector<Node> kids, double share = 0) {
    Node n;
    n.kind = 'V';
    n.kids = std::move(kids);
    n.share = share;
    return n;
}

struct Preset {
    NSString *name;
    Node tree;
    int items[kWorkspaceFrameCount];  // what each position shows to begin with
};

const std::vector<Preset> &presets() {
    static const std::vector<Preset> all = {
        {N(@"QSO, log and spots with map and details below"), H({V({P(0), P(1)}), V({P(2), H({P(3), P(4)})})}),
         {kDockNewQso, kDockLog, kDockSpots, kDockContactMap, kDockQsoInfo}},
        {N(@"QSO on the left, operating panels on the right"), H({P(0), V({P(1), H({P(2), P(3), P(4)})})}),
         {kDockNewQso, kDockLog, kDockSpots, kDockContactMap, kDockQsoInfo}},
        {N(@"Log and QSO across the top, operating panels below"), V({H({P(0), P(1)}), H({P(2), P(3), P(4)})}),
         {kDockLog, kDockNewQso, kDockSpots, kDockContactMap, kDockQsoInfo}},
        {N(@"Map and details on the right"), H({V({P(0), P(1)}), V({P(2), H({P(3), P(4)})})}),
         {kDockNewQso, kDockLog, kDockSpots, kDockContactMap, kDockQsoInfo}},
        {N(@"Spots on the left, QSO and log on the right"), H({P(0), V({P(1), H({P(2), P(3), P(4)})})}),
         {kDockSpots, kDockNewQso, kDockLog, kDockContactMap, kDockQsoInfo}},
        {N(@"QSO and log only"), H({P(0), P(1), P(2), P(3), P(4)}),
         {kDockNewQso, kDockLog, kDockNone, kDockNone, kDockNone}},
        {N(@"QSO, spots and details"), H({P(0), P(1), P(2), P(3), P(4)}),
         {kDockNewQso, kDockSpots, kDockQsoInfo, kDockNone, kDockNone}},
        // An activation: New QSO the whole height on the left (Log QSO always in sight); on the right, who
        // you are working (QSO Details, the contact on its map) over this activation's log and the spots.
        {N(@"Activation: QSO on the left, details, log and spots on the right"),
         H({P(0, 0.34), V({H({P(1, 0.6), P(2, 0.4)}, 0.29), P(3, 0.27), P(4, 0.44)}, 0.66)}),
         {kDockNewQso, kDockQsoInfo, kDockContactMap, kDockLog, kDockSpots}},
        {N(@"Map over the log, QSO on the right"), H({V({P(0), P(1)}), P(2)}),
         {kDockMap, kDockLog, kDockNewQso, kDockNone, kDockNone}},
    };
    return all;
}

NSString *itemName(int item) {
    switch (item) {
        case kDockMap: return T(@"Map");
        case kDockLog: return T(@"Log Table");
        case kDockNewQso: return T(@"New QSO");
        case kDockSpots: return T(@"Activations & Spots");
        case kDockContactMap: return T(@"Contact Map");
        case kDockQsoInfo: return T(@"QSO Details");
        default: return T(@"Empty");
    }
}

// Keep each frame large enough to use; longer content scrolls inside its frame.
NSSize itemMinimum(int item) {
    switch (item) {
        case kDockMap: return NSMakeSize(640, 460);  // room under its toolbar, header and footer for the zoom buttons
        case kDockLog: return NSMakeSize(380, 240);
        case kDockSpots: return NSMakeSize(400, 220);
        case kDockContactMap: return NSMakeSize(240, 200);
        case kDockQsoInfo: return NSMakeSize(320, 200);
        default: return NSMakeSize(420, 300);
    }
}

NSSize contentMinimum(int item) { return itemMinimum(item); }

// How much of a split an item takes to begin with: in proportion to what it needs along the split.
double itemWeight(int item, bool width) {
    NSSize m = contentMinimum(item);
    return width ? m.width : m.height;
}

}  // namespace

// ── A frame: its header (title, what it shows, close) over the item's content ──

@interface ADIFDockFrame : NSView
@property(nonatomic) int position;
@property(nonatomic) int item;
@property(nonatomic, copy) void (^onChoose)(int position, int item);
@property(nonatomic, copy) void (^onSwap)(int from, int to);  // a frame dragged by its header onto this one
@property(nonatomic, copy) void (^onClose)(int position);
- (void)showItem:(int)item title:(NSString *)title content:(NSView *)content;
@end

// A frame's header: its menu, title and close button, and a handle to drag the frame by onto another
// frame, which swaps the two (the menu does the same from the keyboard and VoiceOver).
static NSPasteboardType const kFramePasteboardType = @"org.nextpad.adiflint.frame";

@interface ADIFDockHeader : NSView <NSDraggingSource>
@property(nonatomic) int position;
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
    [item setString:[NSString stringWithFormat:@"%d", self.position] forType:kFramePasteboardType];
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
    NSButton *_close;
    NSScrollView *_scroll;
    ADIFDockHeader *_header;
    NSView *_body;  // the scroll view's document: as big as the frame, or the content's least size when that is more
    NSView *_content;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    ADIFDockHeader *header = [[ADIFDockHeader alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.toolTip = T(@"Drag a frame by its header onto another to swap them");
    _header = header;
    [self registerForDraggedTypes:@[ kFramePasteboardType ]];
    _title = [NSTextField labelWithString:@""];
    _title.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold];
    _title.textColor = NSColor.secondaryLabelColor;
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    _title.translatesAutoresizingMaskIntoConstraints = NO;
    [_title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _choice = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _choice.controlSize = NSControlSizeSmall;
    _choice.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _choice.bordered = NO;
    _choice.translatesAutoresizingMaskIntoConstraints = NO;
    _choice.toolTip = T(@"What this frame shows: choosing one that is in another frame swaps them");
    _choice.accessibilityLabel = T(@"Frame contents");
    for (int item : {kDockNewQso, kDockLog, kDockSpots, kDockContactMap, kDockQsoInfo, kDockMap, kDockNone}) {
        [_choice addItemWithTitle:itemName(item)];
        _choice.lastItem.tag = item;
    }
    _choice.target = self;
    _choice.action = @selector(chosen:);
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
    NSBox *rule = [[NSBox alloc] initWithFrame:NSZeroRect];
    rule.boxType = NSBoxSeparator;
    rule.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:_title];
    [header addSubview:_choice];
    [header addSubview:_close];
    [header addSubview:rule];
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
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:24],
        // The menu names the frame (what it shows); the title beside it, only what the window adds ("test.adi").
        [_choice.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:4],
        [_choice.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_title.leadingAnchor constraintEqualToAnchor:_choice.trailingAnchor constant:4],
        [_title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_close.leadingAnchor constraintGreaterThanOrEqualToAnchor:_title.trailingAnchor constant:6],
        [_close.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-4],
        [_close.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_close.widthAnchor constraintEqualToConstant:16],
        [_close.heightAnchor constraintEqualToConstant:16],
        [rule.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [rule.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [rule.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    return self;
}

- (void)setPosition:(int)position {
    _position = position;
    _header.position = position;
}

- (void)showItem:(int)item title:(NSString *)title content:(NSView *)content {
    _item = item;
    // The window's title less the frame's name: "Map — test.adi" shows "— test.adi" beside the menu.
    NSString *name = itemName(item), *extra = title ?: @"";
    if ([extra hasPrefix:name]) extra = [[extra substringFromIndex:name.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    _title.stringValue = extra;
    [_choice selectItemWithTag:item];
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
    if (self.onChoose) self.onChoose(self.position, item);
}

- (void)closePressed:(id)sender {
    if (self.onClose) self.onClose(self.position);
}

// Another frame dragged here by its header: marked while it is over this one, then the two swap.
- (int)draggedFrom:(id<NSDraggingInfo>)info {
    NSString *v = [info.draggingPasteboard stringForType:kFramePasteboardType];
    return v ? v.intValue : -1;
}
- (void)markDrop:(BOOL)on {
    self.wantsLayer = YES;
    self.layer.borderWidth = on ? 2 : 0;
    self.layer.borderColor = NSColor.controlAccentColor.CGColor;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    int from = [self draggedFrom:info];
    BOOL ok = from >= 0 && from != self.position;
    [self markDrop:ok];
    return ok ? NSDragOperationMove : NSDragOperationNone;
}
- (void)draggingExited:(id<NSDraggingInfo>)info {
    [self markDrop:NO];
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    [self markDrop:NO];
    int from = [self draggedFrom:info];
    if (from < 0 || from == self.position || !self.onSwap) return NO;
    self.onSwap(from, self.position);
    return YES;
}
@end

@implementation ADIFDockPanel
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
         withAttributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.smallSystemFontSize],
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
    NSFont *small = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
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
        NSTextField *list = [self text:lines font:[NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular]
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
        ADIFNightTrack(window);
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
- (BOOL)openPreset:(NSInteger)preset allowEmptyQso:(BOOL)allowEmptyQso;
- (NSMenuItem *)optionsMenuItem;
- (void)retitleMenu;
- (void)closePosition:(int)position;
- (void)abandon;
- (void)closeLayout;
- (void)presetChosen:(NSMenuItem *)sender;
- (int)positionOf:(int)item;
- (void)swap:(int)from with:(int)to;
- (BOOL)dock:(NSWindow<ADIFDockable> *)window;
- (NSView *)contentOf:(int)item;
- (void)setStatus:(NSString *)text;
- (BOOL)hide:(NSWindow<ADIFDockable> *)window closing:(BOOL)closing;
- (void)retitle:(NSWindow<ADIFDockable> *)window;
@end

static std::function<void()> gOpeners[kDockCount];

@implementation ADIFWorkspace {
    ADIFWorkspaceWindow *_host;
    NSView *_treeHolder;
    NSTextField *_statusText, *_statusClock;
    NSTimer *_clock;
    ADIFDockFrame *_frame[kWorkspaceFrameCount];
    int _item[kWorkspaceFrameCount];  // what each position shows
    int _preset;
    BOOL _active, _batching, _closing;
    int _builtPreset, _builtMask;
    NSMutableSet<NSString *> *_unsized;  // splits just built with no saved sizes
    NSView *_root;  // the frames' tree
    NSMutableDictionary<NSNumber *, NSValue *> *_window;   // by item (not retained: each is owned by its own module)
    NSMutableDictionary<NSNumber *, NSView *> *_content;   // the docked windows' content, while docked
    NSMapTable<NSView *, NSNumber *> *_shares;             // each frame's or split's share of its split (Node::share)
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
    _unsized = [NSMutableSet set];
    _window = [NSMutableDictionary dictionary];
    _content = [NSMutableDictionary dictionary];
    _shares = [NSMapTable weakToStrongObjectsMapTable];
    _builtPreset = _builtMask = -1;
    return self;
}

- (NSWindow<ADIFDockable> *)windowOf:(int)item {
    return (NSWindow<ADIFDockable> *)_window[@(item)].nonretainedObjectValue;
}

- (int)positionOf:(int)item {
    for (int p = 0; p < kWorkspaceFrameCount; ++p)
        if (item != kDockNone && _item[p] == item) return p;
    return -1;
}

// ── Settings ──

- (void)loadSettings {
    int preset = 0;
    std::string saved = adifhost::setting("layoutPreset");
    if (!saved.empty()) preset = std::clamp(atoi(saved.c_str()), 0, (int)presets().size() - 1);
    _preset = preset;
    for (int p = 0; p < kWorkspaceFrameCount; ++p) _item[p] = presets()[(size_t)preset].items[p];
    std::string items = adifhost::setting("layoutItemsV3");
    int got[kWorkspaceFrameCount] = {}, n = 0;
    size_t at = 0;
    while (n < kWorkspaceFrameCount && at <= items.size() && !items.empty()) {
        size_t comma = items.find(',', at);
        got[n++] = atoi(items.substr(at, comma == std::string::npos ? std::string::npos : comma - at).c_str());
        if (comma == std::string::npos) break;
        at = comma + 1;
    }
    bool ok = n == kWorkspaceFrameCount;
    for (int p = 0; ok && p < kWorkspaceFrameCount; ++p) {
        ok = got[p] >= kDockNone && got[p] < kDockCount;
        for (int q = 0; ok && q < p; ++q) ok = got[p] == kDockNone || got[p] != got[q];
    }
    if (ok)
        for (int p = 0; p < kWorkspaceFrameCount; ++p) _item[p] = got[p];
}

- (void)saveSettings {
    adifhost::setSetting("layoutPreset", std::to_string(_preset));
    std::string items;
    for (int p = 0; p < kWorkspaceFrameCount; ++p) {
        if (!items.empty()) items += ',';
        items += std::to_string(_item[p]);
    }
    adifhost::setSetting("layoutItemsV3", items);
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
    ADIFNightTrack(_host);
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
    _statusText.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _statusText.textColor = NSColor.secondaryLabelColor;
    _statusText.lineBreakMode = NSLineBreakByTruncatingTail;
    _statusText.identifier = @"loggingLayout.status";
    _statusText.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusText setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _statusClock = [NSTextField labelWithString:@""];
    _statusClock.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
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
    for (int p = 0; p < kWorkspaceFrameCount; ++p) {
        _frame[p] = [[ADIFDockFrame alloc] initWithFrame:NSMakeRect(0, 0, 300, 300)];
        _frame[p].position = p;
        _frame[p].onChoose = ^(int position, int item) { [me assign:item to:position]; };
        _frame[p].onClose = ^(int position) { [me closePosition:position]; };
        _frame[p].onSwap = ^(int from, int to) { [me swap:from with:to]; };
    }
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
    return [self openPreset:-1 allowEmptyQso:NO];
}

- (BOOL)openActivation {
    if (_active) {
        NSMenuItem *activation = [[NSMenuItem alloc] init];
        activation.tag = kActivationPreset;
        [self presetChosen:activation];
        return YES;
    }
    return [self openPreset:kActivationPreset allowEmptyQso:YES];
}

- (BOOL)openLogging {
    if (_active) {
        NSMenuItem *logging = [[NSMenuItem alloc] init];
        logging.tag = kLoggingPreset;
        [self presetChosen:logging];
        return YES;
    }
    return [self openPreset:kLoggingPreset allowEmptyQso:NO];
}

- (BOOL)openPreset:(NSInteger)preset allowEmptyQso:(BOOL)allowEmptyQso {
    _closing = NO;
    [self loadSettings];
    if (preset >= 0) {
        _preset = (int)preset;
        for (int p = 0; p < kWorkspaceFrameCount; ++p) _item[p] = presets()[(size_t)_preset].items[p];
    }
    [self makeHost];
    _active = YES;
    [self startClock];
    _batching = YES;
    _builtPreset = _builtMask = -1;
    [_host makeKeyAndOrderFront:nil];
    BOOL ok = YES;
    for (int item = 1; item < kDockCount; ++item) {
        int p = [self positionOf:item];
        if (p < 0 || !gOpeners[item]) continue;
        gOpeners[item]();
        if (![self windowOf:item].dockHost) {
            if (item == kDockNewQso) {
                if (allowEmptyQso) {
                    _item[p] = kDockNone;  // Start Activation may create its ADIF log after this window opens.
                    continue;
                }
                ok = NO;
                break;
            }
            _item[p] = kDockNone;
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

// Each window gets its own content back; those that were showing are told they closed.
- (void)undockAll:(BOOL)closed {
    _closing = YES;
    for (int item = 1; item < kDockCount; ++item) {
        NSWindow<ADIFDockable> *w = [self windowOf:item];
        NSView *content = _content[@(item)];
        if (!w || !content) continue;
        BOOL shown = [self positionOf:item] >= 0;
        w.dockHost = nil;
        [content removeFromSuperview];
        content.translatesAutoresizingMaskIntoConstraints = YES;
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        w.contentView = content;
        if (shown && closed) [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:w];
    }
    [_content removeAllObjects];
    [_window removeAllObjects];
    for (int p = 0; p < kWorkspaceFrameCount; ++p) [_frame[p] showItem:kDockNone title:@"" content:nil];
    [_root removeFromSuperview];
    _root = nil;
    _builtMask = -1;
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
    // Its frame: its own in this layout, else an empty one. With every frame in use it stays a window
    // of its own, rather than put out what is in a frame (New QSO, in the middle of an activation).
    int p = [self positionOf:item];
    for (int q = 0; q < kWorkspaceFrameCount && p < 0; ++q)
        if (_item[q] == kDockNone && presets()[(size_t)_preset].items[q] == item) p = q;
    for (int q = 0; q < kWorkspaceFrameCount && p < 0; ++q)
        if (_item[q] == kDockNone) p = q;
    if (p < 0) return NO;
    if (!_content[@(item)]) {
        [w orderOut:nil];
        NSView *content = w.contentView;
        w.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
        _content[@(item)] = content;
        _window[@(item)] = [NSValue valueWithNonretainedObject:w];
        w.dockHost = _host;
    }
    if ([self positionOf:item] < 0) {
        _item[p] = item;
        [self saveSettings];
    }
    [self rebuild];
    if (!_batching) [_host makeKeyAndOrderFront:nil];
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

- (void)closePosition:(int)position {
    [self closeItem:_item[position]];
}

- (void)closeItem:(int)item {
    int p = [self positionOf:item];
    if (p < 0) return;
    _item[p] = kDockNone;
    [self saveSettings];
    NSWindow<ADIFDockable> *w = [self windowOf:item];
    if (w) [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:w];
    bool any = false;
    for (int p = 0; p < kWorkspaceFrameCount; ++p) any |= _item[p] != kDockNone;
    if (!any) {
        [self closeLayout];
        return;
    }
    [self rebuild];
}

- (void)retitle:(NSWindow<ADIFDockable> *)w {
    int p = [self positionOf:w.dockItem];
    if (p >= 0 && w.dockHost) [_frame[p] showItem:w.dockItem title:w.title content:_content[@(w.dockItem)]];
}

// A frame dragged onto another: the two swap what they show.
- (void)swap:(int)from with:(int)to {
    if (from < 0 || to < 0 || from >= kWorkspaceFrameCount || to >= kWorkspaceFrameCount || from == to) return;
    std::swap(_item[from], _item[to]);
    [self saveSettings];
    [self rebuild];
}

// A frame's menu: that item here. One already in another frame swaps places with this frame's.
- (void)assign:(int)item to:(int)position {
    int old = _item[position];
    if (item == old) return;
    int other = [self positionOf:item];
    if (item == kDockNone) {
        [self closeItem:old];
        return;
    }
    if (other >= 0) {
        _item[other] = old;
        _item[position] = item;
        [self saveSettings];
        [self rebuild];
        return;
    }
    _item[position] = item;
    NSWindow<ADIFDockable> *oldWindow = [self windowOf:old];
    if (old != kDockNone && oldWindow) [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:oldWindow];
    [self saveSettings];
    if (gOpeners[item]) gOpeners[item]();
    if (![self windowOf:item].dockHost) _item[position] = kDockNone;
    [self rebuild];
}

- (void)presetChosen:(NSMenuItem *)sender {
    NSInteger i = sender.tag;
    if (i < 0 || (size_t)i >= presets().size() || (int)i == _preset) return;
    bool was[kDockCount] = {};
    for (int item = 1; item < kDockCount; ++item) was[item] = [self positionOf:item] >= 0;
    _preset = (int)i;
    for (int p = 0; p < kWorkspaceFrameCount; ++p) _item[p] = presets()[(size_t)i].items[p];
    [self saveSettings];
    if (!_active) return;
    _batching = YES;
    for (int item = 1; item < kDockCount; ++item) {
        int p = [self positionOf:item];
        if (was[item] && p < 0) {  // not in this layout
            NSWindow<ADIFDockable> *w = [self windowOf:item];
            if (w) [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:w];
        } else if (!was[item] && p >= 0 && gOpeners[item]) {
            gOpeners[item]();
            if (![self windowOf:item].dockHost) _item[p] = kDockNone;
        }
    }
    _batching = NO;
    [self rebuild];
}

- (void)frameToggled:(NSMenuItem *)sender {
    int item = (int)sender.tag;
    if ([self positionOf:item] >= 0) {
        if (!_active) {
            _item[[self positionOf:item]] = kDockNone;
            [self saveSettings];
            return;
        }
        [self closeItem:item];
        return;
    }
    if (!_active) {
        int position = -1;
        for (int p = 0; p < kWorkspaceFrameCount && position < 0; ++p)
            if (_item[p] == kDockNone && presets()[(size_t)_preset].items[p] == item) position = p;
        for (int p = 0; p < kWorkspaceFrameCount && position < 0; ++p)
            if (_item[p] == kDockNone) position = p;
        if (position < 0) position = 0;
        _item[position] = item;
        [self saveSettings];
        return;
    }
    if (gOpeners[item]) gOpeners[item]();
}

- (void)resetSizes:(id)sender {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSString *key in d.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"NSSplitView Subview Frames adif.layout"]) [d removeObjectForKey:key];
    _builtMask = -1;
    [self rebuild];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    for (NSMenuItem *mi in menu.itemArray) {
        if (mi.action == @selector(presetChosen:))
            mi.state = mi.tag == _preset ? NSControlStateValueOn : NSControlStateValueOff;
        else if (mi.action == @selector(frameToggled:))
            mi.state = [self positionOf:(int)mi.tag] >= 0 ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (NSMenuItem *)optionsMenuItem {
    if (_optionsMenuItem) return _optionsMenuItem;
    [self loadSettings];
    _optionsMenu = [[NSMenu alloc] initWithTitle:T(@"Console Layout Options")];
    _optionsMenu.delegate = self;
    for (size_t i = 0; i < presets().size(); ++i) {
        NSMenuItem *mi = [_optionsMenu addItemWithTitle:T(presets()[i].name) action:@selector(presetChosen:) keyEquivalent:@""];
        mi.target = self;
        mi.tag = (NSInteger)i;
    }
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
        if (mi.action == @selector(presetChosen:) && mi.tag >= 0 && (size_t)mi.tag < presets().size())
            mi.title = T(presets()[(size_t)mi.tag].name);
        else if (mi.action == @selector(frameToggled:))
            mi.title = itemName((int)mi.tag);
        else if (mi.action == @selector(resetSizes:))
            mi.title = T(@"Reset Frame Sizes");
    }
}

// ── The frames' tree ──

static bool prune(const Node &n, const int items[kWorkspaceFrameCount], Node *out) {
    if (n.kind == 'P') {
        if (items[n.position] == kDockNone) return false;
        *out = n;
        return true;
    }
    Node kept;
    kept.kind = n.kind;
    kept.share = n.share;
    for (const Node &k : n.kids) {
        Node c;
        if (prune(k, items, &c)) kept.kids.push_back(c);
    }
    if (kept.kids.empty()) return false;
    *out = kept.kids.size() == 1 ? kept.kids[0] : kept;
    return true;
}

static NSSize minimumOf(NSView *v) {
    if ([v isKindOfClass:ADIFDockFrame.class]) {
        NSSize m = itemMinimum(((ADIFDockFrame *)v).item);
        return NSMakeSize(m.width, m.height + 24);
    }
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

static double weightOf(NSView *v, bool width) {
    if ([v isKindOfClass:ADIFDockFrame.class]) return itemWeight(((ADIFDockFrame *)v).item, width);
    if (![v isKindOfClass:NSSplitView.class]) return 1;
    NSSplitView *s = (NSSplitView *)v;
    bool along = s.isVertical == width;
    double w = 0;
    for (NSView *k in s.subviews) w = along ? w + weightOf(k, width) : std::max(w, weightOf(k, width));
    return w;
}

- (NSView *)buildNode:(const Node &)n name:(NSString *)name counter:(int *)counter {
    if (n.kind == 'P') {
        if (n.share > 0) [_shares setObject:@(n.share) forKey:_frame[n.position]];
        else [_shares removeObjectForKey:_frame[n.position]];
        return _frame[n.position];
    }
    NSSplitView *s = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    s.vertical = n.kind == 'H';
    s.dividerStyle = NSSplitViewDividerStyleThin;
    s.delegate = self;
    s.arrangesAllSubviews = YES;
    for (const Node &k : n.kids) [s addSubview:[self buildNode:k name:name counter:counter]];
    if (n.share > 0) [_shares setObject:@(n.share) forKey:s];
    NSString *save = [NSString stringWithFormat:@"%@.%d", name, (*counter)++];
    if (![NSUserDefaults.standardUserDefaults objectForKey:[@"NSSplitView Subview Frames " stringByAppendingString:save]]) [_unsized addObject:save];
    s.autosaveName = save;
    return s;
}

// Splits with no saved sizes start in proportion to what is in them.
- (void)defaultSizes:(NSView *)v {
    if (![v isKindOfClass:NSSplitView.class]) return;
    NSSplitView *s = (NSSplitView *)v;
    if ([_unsized containsObject:s.autosaveName]) {
        bool width = s.isVertical;
        bool shared = true;  // each has a share of its own: those, else what each needs
        for (NSView *k in s.subviews) shared &= [_shares objectForKey:k] != nil;
        auto weight = [&](NSView *k) { return shared ? [_shares objectForKey:k].doubleValue : weightOf(k, width); };
        double total = 0;
        for (NSView *k in s.subviews) total += weight(k);
        CGFloat room = (width ? NSWidth(s.bounds) : NSHeight(s.bounds)) - s.dividerThickness * (s.subviews.count - 1);
        double sofar = 0;
        for (NSUInteger i = 0; i + 1 < s.subviews.count; ++i) {
            sofar += weight(s.subviews[i]);
            [s setPosition:std::round(room * sofar / total) + s.dividerThickness * i ofDividerAtIndex:(NSInteger)i];
        }
    }
    [s layoutSubtreeIfNeeded];
    for (NSView *k in s.subviews) [self defaultSizes:k];
}

- (void)rebuild {
    if (!_active || _batching || _closing) return;
    // Each position's item in its frame.
    for (int p = 0; p < kWorkspaceFrameCount; ++p) {
        int item = _item[p];
        NSWindow<ADIFDockable> *w = [self windowOf:item];
        [_frame[p] showItem:item title:w ? w.title : @"" content:item != kDockNone && w ? _content[@(item)] : nil];
    }
    int mask = 0;
    for (int p = 0; p < kWorkspaceFrameCount; ++p) mask |= _item[p] != kDockNone ? 1 << p : 0;
    if (_builtPreset != _preset || _builtMask != mask) {
        _builtPreset = _preset, _builtMask = mask;
        [_root removeFromSuperview];
        _root = nil;
        Node tree;
        if (prune(presets()[(size_t)_preset].tree, _item, &tree)) {
            int counter = 0;
            [_unsized removeAllObjects];
            // The activation layout's sizes kept apart from those saved for its first arrangement (1.7).
            NSString *base = _preset == kActivationPreset ? @"adif.layout3" : @"adif.layout2";
            _root = [self buildNode:tree name:[NSString stringWithFormat:@"%@.%d.%d", base, _preset, mask] counter:&counter];
            _root.translatesAutoresizingMaskIntoConstraints = NO;
            [_treeHolder addSubview:_root];
            [NSLayoutConstraint activateConstraints:@[
                [_root.topAnchor constraintEqualToAnchor:_treeHolder.topAnchor],
                [_root.leadingAnchor constraintEqualToAnchor:_treeHolder.leadingAnchor],
                [_root.trailingAnchor constraintEqualToAnchor:_treeHolder.trailingAnchor],
                [_root.bottomAnchor constraintEqualToAnchor:_treeHolder.bottomAnchor],
            ]];
            [_host.contentView layoutSubtreeIfNeeded];
            [self defaultSizes:_root];
        }
    }
    NSSize m = _root ? minimumOf(_root) : NSZeroSize;
    _host.contentMinSize = NSMakeSize(std::max<CGFloat>(m.width, 480), m.height + kStatusHeight + kADIFMargin);
    // Keep the standalone Map's list in its normal state; the static contact map has no log list.
    worldmap::setListSuppressed([self positionOf:kDockMap] >= 0 && [self positionOf:kDockLog] >= 0);
}

// ── Split delegate: no frame below its least size ──

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

void setOpener(int item, std::function<void()> open) {
    if (item > kDockNone && item < kDockCount) gOpeners[item] = std::move(open);
}

void setOnChange(std::function<void(bool)> onChange) { gOnChange = std::move(onChange); }

bool show(NSWindow<ADIFDockable> *window) { return [ADIFWorkspace.shared dock:window]; }

bool hide(NSWindow<ADIFDockable> *window, bool closing) { return [ADIFWorkspace.shared hide:window closing:closing]; }

bool visible(NSWindow<ADIFDockable> *window) {
    ADIFWorkspace *ws = ADIFWorkspace.shared;
    return ws.active && ws.host.isVisible && [ws positionOf:window.dockItem] >= 0;
}

NSView *content(NSWindow<ADIFDockable> *window) { return [ADIFWorkspace.shared contentOf:window.dockItem]; }

void retitle(NSWindow<ADIFDockable> *window) {
    if (window.dockHost) [ADIFWorkspace.shared retitle:window];
}

}  // namespace workspace
