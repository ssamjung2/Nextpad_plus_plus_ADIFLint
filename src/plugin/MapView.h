// The Map's view, ADIFMapView, and what its files share: Map.mm builds the window around it,
// MapView.mm holds the view (the plane, the pointer, the legend) and MapLayers.mm draws the
// layers, one method each, in drawRect's order.
#pragma once

#import <Cocoa/Cocoa.h>

#include "adif_detail.h"
#include "adif_palette.h"
#include "adif_projection.h"
#include "adif_world.h"

#include <array>
#include <cstdint>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <tuple>
#include <utility>
#include <vector>


struct ADIFMapEntity {
    int dxcc = 0;
    double lat = 0, lon = 0;
    std::vector<size_t> qsos;  // into MapData::qsos
    bool confirmed = false;
    std::string name;
    std::vector<adif::RingRef> land;  // the entity's own land (adif::dxccRings); empty: a dot
};

// What the pointer is over, or what was clicked.
struct ADIFMapHit {
    enum Kind { None, Square, Dxcc, Park, Contact, Iota, Pota, Area, Empty } kind = None;
    std::string square;  // the 4-character square under the point (always set on the map)
    // Into squares, entities, parks, contacts, IOTA groups (ADIFIotaGroups), POTA's parks
    // (ADIFPotaParks), or (Area) the layer's areas (adif::areaIndex).
    size_t index = 0;
    int layer = 0;  // Area: the MapLayerId
};

// The Map's layers of areas. Each has Show (the areas worked in the log, shaded), Overlay
// (every area outlined) and Labels (their names or numbers); Cities has no Show.
enum MapLayerId { kLayerSquares, kLayerCountries, kLayerStates, kLayerCounties, kLayerCq, kLayerItu, kLayerPota, kLayerIota, kLayerCities, kLayerCount };
struct LayerState {
    bool show = false, overlay = false, labels = true;
};

// How the map looks: the Style Options, the colour popup and the layer checkboxes.
struct ADIFMapStyle {
    int colorBy = 0;    // 0 confirmation, 1 band, 2 mode, 3 QSO count, 4 year first worked
    int palette = 0;    // 0 standard, 1 colour-blind safe, 2 high contrast, 3 light (print)
    int shape = 0;      // markers: 0 by layer (DXCC dots, park triangles, program diamonds), 1 circles, 2 squares
    int fill = 0;       // worked squares: 0 solid, 1 translucent, 2 outline
    int contact = 0;    // contacts: 0 pins, 1 dots, 2 crosshairs
    int lineStyle = 0;  // lines to contacts: 0 solid, 1 dashed, 2 dotted
    int lineWidth = 1;  // 0 thin, 1 medium, 2 thick
    double marker = 1;  // marker size factor
    bool legend = true, rings = false, paths = false, mine = true;
    bool arcs = true;  // on the globe, lines to contacts arch over it
    // Squares: Show the worked squares, Overlay the Maidenhead grid, Labels its names. Countries:
    // Show each worked DXCC entity's land. POTA and IOTA need their lists (downloaded in Settings).
    std::array<LayerState, kLayerCount> layer;
    const LayerState &operator[](MapLayerId l) const { return layer[(size_t)l]; }
};

// QSOs at one exact place (MapQso::located), for the Contacts layer.
struct ADIFMapContact {
    double lat = 0, lon = 0;
    std::vector<size_t> qsos;  // into MapData::qsos
};

// What colours a square or a DXCC dot, over its QSOs.
struct ADIFMapAgg {
    std::string band;  // the band with the most QSOs
    int mode = 2;      // the mode group with the most QSOs: 0 CW, 1 phone, 2 data
    size_t count = 0;
    int year = 0;      // the first QSO's year
    bool confirmed = false;
};

// Your QSOs with a POTA park: hunting it (POTA_REF) and activating it (MY_POTA_REF).
struct ADIFParkWork {
    std::vector<size_t> hunted, activated;  // into MapData::qsos
};
// A POTA park's marker in the view: its index in ADIFPotaParks(), and where it is (a pin's head).
struct ADIFParkSpot {
    size_t park = 0;
    NSPoint at = NSZeroPoint;
    bool pin = false;        // a park you worked; else a ring
    bool activated = false;  // a pin for a park you activated
    ADIFMapAgg agg;          // a hunted park's QSOs, for its colour
    bool dot = false;        // a small dot, where too many rings would show
};

namespace mapkit {

constexpr double kMaxZoom = 1024;   // city level: a kilometre is some 30 points across
constexpr double kDetailZoom = 12;  // from here the 1:10m detail (map-detail.bin) replaces the 1:50m maps
constexpr double kPin = 4;  // a contact pin's head radius (times Style's marker size); the head is 2.2 of these above the point

using adif::MapPalette;
NSColor *rgb(unsigned hex, CGFloat a = 1);
const MapPalette &paletteAt(int i);
void setFill(CGContextRef ctx, unsigned hex, CGFloat a = 1);
void setStroke(CGContextRef ctx, unsigned hex, CGFloat a = 1);
int bandIndex(const std::string &band);
bool darkColour(NSColor *c);  // needs a light edge to show on a dark map (60m's navy)
NSColor *ramp(double t, const MapPalette &p);
int countBucket(size_t n);  // QSO counts in five steps: 1, 2-4, 5-9, 10-24, 25 and more
extern const char *const kCountLabels[5];
extern const char *const kModeLabels[3];

// Other programs the map lists, with what their references are; any other SIG in the log follows.
struct ProgramInfo {
    const char *key, *label;
};
extern const ProgramInfo kPrograms[];
extern const size_t kProgramCount;

// The overlays' areas, read once, with each area's extent for deciding when its name fits.
struct OverlayCache {
    std::vector<adif::OverlayArea> areas;
    std::vector<std::pair<double, double>> span;  // longitude and latitude extent
};
const OverlayCache &overlay(adif::Overlay o);
const adif::MapDetail &mapDetail();
double webZoom(double zoom);
CGMutablePathRef detailPath(const adif::Projector &pr, adif::DetailLayer l, bool polygons, double west, double south, double east, double north,
                            const std::function<bool(int)> &keep);
CGPathRef projectedLayer(const adif::Projector &pr, adif::MapLayer l, int maxRank = 99);
// The overlay a layer of worked areas is drawn from (states, counties, CQ and ITU zones).
inline adif::Overlay layerOverlay(int layer) {
    return layer == kLayerStates ? adif::Overlay::UsStates : layer == kLayerCounties ? adif::Overlay::UsCounties
           : layer == kLayerCq   ? adif::Overlay::CqZones
                                 : adif::Overlay::ItuZones;
}

}  // namespace mapkit

// What drawRect's layers share: set up by drawBase, read by the rest.
struct MapDrawCtx {
    CGContextRef ctx = nullptr;
    NSRect b = NSZeroRect;
    const adif::MapPalette *pal = nullptr;
    CGFloat ink = 0;  // 1 on a dark map, 0 on a light one
    double ppu = 1;
    bool globe = false, curved = false;
    NSBezierPath *world = nil;                       // the world's outline in the view
    double west = 0, south = 0, east = 0, north = 0;  // the longitudes and latitudes in view
    double squareW = 0, fieldW = 0;                  // a grid square's and field's width on screen
    // County names wait for city names, and go only where they're clear of them.
    bool countiesAfterCities = false;
    std::vector<std::pair<NSString *, NSRect>> countyNames;
    NSDictionary *countyAttrs = nil;
    std::vector<NSRect> taken;  // city names and dots
};

// The map, in one of four projections. Scroll or pinch to zoom (a trackpad's two-finger
// scroll pans), drag to pan, double-click to zoom in, + and - keys, 0 for the whole world.
// On the globe, dragging, a two-finger scroll and the arrow keys turn it instead.
@interface ADIFMapView : NSView {
    adif::MapData _data;
    std::vector<ADIFMapEntity> _entities;
    std::vector<ADIFMapContact> _contacts;
    std::vector<ADIFMapAgg> _squareAgg, _entityAgg, _contactAgg;
    std::vector<bool> _entityDot;  // drawn as a dot: no land at this scale, or too small on screen
    // The worked areas of the States, Counties, CQ and ITU layers: area name -> its QSOs.
    std::array<std::map<std::string, std::vector<size_t>>, kLayerCount> _areaQsos;
    std::array<std::map<std::string, ADIFMapAgg>, kLayerCount> _areaAgg;
    std::map<std::string, std::vector<size_t>> _iotaQsos;  // IOTA reference -> its QSOs (into _data.qsos)
    std::map<std::string, ADIFParkWork> _potaWork;         // a POTA park, as the list writes it -> your QSOs there
    std::vector<ADIFParkSpot> _potaSpots;                  // where the parks' markers are (placeParks)
    adif::MapFilter _parkFilter;  // the Filters' places, for parks not worked
    BOOL _filterParks;             // "Apply to POTA parks"
    std::tuple<double, double, double, double, double, int, double, double, double, int, uintptr_t, size_t, int> _parksPlacedFor;
    int _dataGeneration;                                   // counts setData, for placeParks
    std::vector<std::string> _bands;  // in the data, frequency order
    int _minYear, _maxYear;
    adif::Projector _pr;    // in use: the globe turned to wherever you dragged it
    adif::Projector _base;  // as chosen: the globe centred on home
    bool _hasHome;
    double _homeLat, _homeLon;
    NSString *_homeGrid;
    double _cx, _cy, _zoom;  // the view's centre on the plane, and its zoom
    ADIFMapHit _hover, _selected;
    NSPoint _down;
    BOOL _dragged;
    NSTrackingArea *_tracking;
    // The properties' own, here so the layers (MapLayers.mm) can read them too.
    BOOL _showContacts;
    std::set<std::string> _hiddenPrograms;
    std::map<std::string, size_t> _qsosPerBand;
    ADIFMapStyle _style;
}
@property(nonatomic) BOOL showContacts;
@property(nonatomic) std::set<std::string> hiddenPrograms;
@property(nonatomic) std::map<std::string, size_t> qsosPerBand;  // over the whole log, for the colour-blind safe band colours
@property(nonatomic) ADIFMapStyle style;
@property(nonatomic, readonly) double zoom;
@property(nonatomic, copy) void (^onHover)(const ADIFMapHit &hit);
@property(nonatomic, copy) void (^onSelect)(const ADIFMapHit &hit);
@property(nonatomic, copy) void (^onViewChanged)(void);
- (void)setData:(const adif::MapData &)data entities:(const std::vector<ADIFMapEntity> &)entities;
- (void)setProjector:(const adif::Projector &)projector home:(NSString *)homeGrid lat:(double)lat lon:(double)lon;
- (void)zoomBy:(double)factor;  // about the middle
- (void)showWorld;
- (void)fitLog;                 // zoom to what the log shows
- (void)showWest:(double)w south:(double)s east:(double)e north:(double)n;  // a region
- (NSPoint)viewPointForLon:(double)lon lat:(double)lat;
- (const std::vector<ADIFMapContact> &)contacts;
- (std::vector<size_t>)areaQsos:(int)layer name:(const std::string &)name;  // a worked area's QSOs
- (void)setParkFilter:(const adif::MapFilter &)filter on:(BOOL)on;      // the Filters, for parks not worked
- (std::vector<size_t>)iotaQsos:(const std::string &)ref;  // the QSOs with this IOTA reference
- (ADIFParkWork)parkWork:(const std::string &)ref;          // your QSOs with this POTA park (as the list writes it)
- (void)selectedPlace:(double *)lat lon:(double *)lon name:(std::string *)name;
@end

// What MapView.mm implements for the layers and the window.
@interface ADIFMapView ()
- (instancetype)initWithFrame:(NSRect)frame;
- (BOOL)isFlipped;
- (BOOL)acceptsFirstResponder;
- (BOOL)acceptsFirstMouse:(NSEvent *)event;
- (double)zoom;
- (void)updateTrackingAreas;
- (ADIFMapAgg)aggregate:(const std::vector<size_t> &)qsos;
- (void)setShowContacts:(BOOL)on;
- (void)setStyle:(ADIFMapStyle)style;
- (void)setHiddenPrograms:(std::set<std::string>)hidden;
- (double)ppu;
- (BOOL)globe;
- (void)turnTo:(double)x y:(double)y;
- (void)rotateBy:(double)dx y:(double)dy;
- (BOOL)atHome;
- (void)clampCenter;
- (NSPoint)planeToView:(double)x y:(double)y;
- (void)viewToPlane:(NSPoint)p x:(double *)x y:(double *)y;
- (BOOL)lonLatAt:(NSPoint)p lon:(double *)lon lat:(double *)lat;
- (NSBezierPath *)viewPath:(const std::vector<std::pair<double, double>> &)pts close:(BOOL)close wraps:(BOOL)wraps;
- (NSBezierPath *)squarePath:(const std::string &)grid;
- (NSBezierPath *)iotaBoxPath:(const std::array<double, 4> &)box;
- (void)visibleWest:(double *)west south:(double *)south east:(double *)east north:(double *)north;
- (double)pixelsForLon:(double)lon lat:(double)lat span:(double)span;
- (void)viewChanged;
- (void)zoomBy:(double)factor at:(NSPoint)p;
- (void)fitPlaneWest:(double)west south:(double)south east:(double)east north:(double)north;
- (NSColor *)bandColor:(const std::string &)band;
- (void)setQsosPerBand:(std::map<std::string, size_t>)counts;
- (NSColor *)colorFor:(const ADIFMapAgg &)a entity:(BOOL)entity;
- (NSColor *)programColor:(const std::string &)program;
- (NSBezierPath *)marker:(int)kind at:(NSPoint)p size:(double)r;
- (double)dotRadius:(size_t)qsos;
- (NSBezierPath *)outlineOf:(const adif::OverlayArea &)a;
- (void)styleLine:(NSBezierPath *)path;
- (NSBezierPath *)contactMarkerAt:(NSPoint)p;
- (BOOL)programShown:(const adif::MapPark &)pk;
- (BOOL)parkPinned:(const adif::MapPark &)pk;
- (void)drawLabel:(NSString *)text at:(NSPoint)p size:(CGFloat)size alpha:(CGFloat)alpha;
- (void)drawLegend;
- (ADIFMapHit)hitAt:(NSPoint)p;
- (void)mouseMoved:(NSEvent *)event;
- (void)mouseExited:(NSEvent *)event;
- (void)mouseDown:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
- (void)scrollWheel:(NSEvent *)event;
- (void)magnifyWithEvent:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;
- (void)setFrameSize:(NSSize)size;
@end

// The layers (MapLayers.mm), in drawRect's order.
@interface ADIFMapView (Layers)
- (void)drawWorkedAreas:(MapDrawCtx &)d;
- (size_t)workedAreaAt:(MapLayerId)layer lon:(double)lon lat:(double)lat;  // a worked area's index (adif::areaIndex), or npos
- (BOOL)parkFiltered:(const adif::PotaPark &)p;
- (void)drawBase:(MapDrawCtx &)d;
- (void)drawGridLines:(MapDrawCtx &)d;
- (void)drawDxccLand:(MapDrawCtx &)d;
- (void)drawOverlays:(MapDrawCtx &)d;
- (void)drawIota:(MapDrawCtx &)d;
- (void)drawCities:(MapDrawCtx &)d;
- (void)drawLines:(MapDrawCtx &)d;
- (void)drawSquares:(MapDrawCtx &)d;
- (void)drawGridLabels:(MapDrawCtx &)d;
- (void)drawRings:(MapDrawCtx &)d;
- (void)drawDxccDots:(MapDrawCtx &)d;
- (void)drawContacts:(MapDrawCtx &)d;
- (void)drawPrograms:(MapDrawCtx &)d;
- (void)drawMine:(MapDrawCtx &)d;
- (void)drawSelection:(MapDrawCtx &)d;
- (void)drawParkPinAt:(NSPoint)p color:(NSColor *)c activated:(BOOL)activated lit:(BOOL)lit;
- (void)placeParks;
- (void)drawParkRings;
- (void)drawParkPins;
- (void)drawParkLabelsIn:(NSRect)b;
@end
