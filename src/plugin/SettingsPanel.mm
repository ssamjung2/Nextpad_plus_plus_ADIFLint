#import "SettingsPanel.h"
#import "Theme.h"
#import "Accordion.h"
#import "Night.h"
#import "L10n.h"

#import "Lookup.h"
#import "Spots.h"
#import "ParkOutlines.h"
#import "Country.h"
#import "IotaGroups.h"
#import "LotwUsers.h"
#import "PotaParks.h"

#include "PluginHost.h"
#include "adif_geo.h"
#include "adif_spec.h"

#include <algorithm>
#include <string>
#include <vector>
#import "ToolWindow.h"

// Flipped, so the sections start at the top of the scroll view.
@interface ADIFSettingsDocument : NSView
@end
@implementation ADIFSettingsDocument
- (BOOL)isFlipped {
    return YES;
}
@end

// A category's symbol in one colour, as System Settings draws its panes' icons.
// An account's state as Settings shows it: what the last action on it left.
typedef NS_ENUM(NSInteger, ADIFAccountState) {
    ADIFAccountNone,
    ADIFAccountSaved,
    ADIFAccountSignedIn,
    ADIFAccountSignInFailed,
    ADIFAccountTesting,
    ADIFAccountSaveFailed,
};

static NSImage *settingsGlyph(NSString *symbol, NSColor *colour, CGFloat pointSize) {
    NSImage *glyph = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    if (!glyph) return [NSImage new];
    glyph = [glyph imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:NSFontWeightRegular]];
    return [NSImage imageWithSize:glyph.size
                          flipped:NO
                   drawingHandler:^BOOL(NSRect rect) {
                       [glyph drawInRect:rect];
                       [colour set];
                       NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);  // the symbol's shape, in colour
                       return YES;
                   }];
}

// A sidebar category: its symbol, its name (Station adds its callsign and grid under it) and a rounded
// highlight when it is the chosen one. It is still a button, so Tab, Space and VoiceOver work as they do for any button.
@interface ADIFSettingsNavButton : NSButton
@property(nonatomic, strong) NSImage *glyph, *chosenGlyph;  // the symbol in the text colour, and in white on the highlight
@property(nonatomic, copy) NSString *subtitle;              // a second line under the name; empty for none
@end
@implementation ADIFSettingsNavButton
- (void)setState:(NSControlStateValue)state {
    [super setState:state];
    [self setNeedsDisplay:YES];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    BOOL chosen = self.state == NSControlStateValueOn;
    NSRect pillRect = NSInsetRect(self.bounds, 0, 1);
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:pillRect xRadius:8 yRadius:8];
    if (chosen) {
        [NSColor.controlAccentColor setFill];
        [pill fill];
    }
    if (self.window.firstResponder == self) {  // the keyboard's focus ring
        [NSGraphicsContext saveGraphicsState];
        NSSetFocusRingStyle(NSFocusRingOnly);
        [pill fill];
        [NSGraphicsContext restoreGraphicsState];
    }
    NSImage *glyph = chosen ? self.chosenGlyph : self.glyph;
    NSRect glyphRect = NSMakeRect(NSMinX(pillRect) + 12, NSMidY(pillRect) - glyph.size.height / 2, glyph.size.width, glyph.size.height);
    [glyph drawInRect:glyphRect];
    NSDictionary *attributes = @{
        NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : chosen ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor
    };
    NSSize size = [self.title sizeWithAttributes:attributes];
    CGFloat x = NSMaxX(glyphRect) + 10;
    if (!self.subtitle.length) {
        [self.title drawAtPoint:NSMakePoint(x, NSMidY(pillRect) - size.height / 2) withAttributes:attributes];
        return;
    }
    NSDictionary *small = @{
        NSFontAttributeName : [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName : chosen ? [NSColor.alternateSelectedControlTextColor colorWithAlphaComponent:0.8] : NSColor.secondaryLabelColor
    };
    // The name's line is on top, the subtitle under it.
    CGFloat lines = size.height + [self.subtitle sizeWithAttributes:small].height;
    [self.title drawAtPoint:NSMakePoint(x, NSMidY(pillRect) + lines / 2 - size.height) withAttributes:attributes];
    [self.subtitle drawAtPoint:NSMakePoint(x, NSMidY(pillRect) - lines / 2) withAttributes:small];
}

// Drawn in the unflipped coordinates the lines above assume, whatever the view it sits in.
- (BOOL)isFlipped {
    return NO;
}
@end

// A group of settings: a rounded card with a faint fill and a hairline edge, as System Settings groups its rows.
@interface ADIFSettingsCard : NSView
@end
@implementation ADIFSettingsCard
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:10 yRadius:10];
    [[NSColor.labelColor colorWithAlphaComponent:0.045] setFill];
    [path fill];
    [NSColor.separatorColor setStroke];
    [path stroke];
}
@end

// A group's status in its heading: a capsule, green when what it covers is set up or on, faint otherwise.
@interface ADIFStatusPill : NSTextField
@property(nonatomic) BOOL positive;
@property(nonatomic) BOOL failed;  // a problem, in red; takes precedence over positive
+ (instancetype)pill;
@end
@implementation ADIFStatusPill
+ (instancetype)pill {
    ADIFStatusPill *pill = [[ADIFStatusPill alloc] initWithFrame:NSZeroRect];
    pill.stringValue = @"";
    pill.editable = NO;
    pill.selectable = NO;
    pill.bezeled = NO;
    pill.drawsBackground = NO;
    pill.usesSingleLineMode = YES;
    pill.lineBreakMode = NSLineBreakByTruncatingTail;
    pill.alignment = NSTextAlignmentCenter;
    pill.font = theme::small();
    // Its width is its text's and its ends; the heading beside it gives way, never the capsule.
    [pill setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [pill setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    pill.positive = NO;
    return pill;
}
- (void)setPositive:(BOOL)positive {
    _positive = positive;
    [self refreshTint];
}
- (void)setFailed:(BOOL)failed {
    _failed = failed;
    [self refreshTint];
}
- (NSColor *)statusTint {
    return self.failed ? theme::error() : self.positive ? theme::fine() : theme::faint();
}
- (void)refreshTint {
    self.textColor = self.statusTint;
    [self setNeedsDisplay:YES];
}
- (NSSize)intrinsicContentSize {
    NSSize size = [super intrinsicContentSize];
    size.width += 16;  // the capsule's rounded ends
    size.height += 2;
    return size;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSColor *tint = self.statusTint;
    NSRect capsule = NSInsetRect(self.bounds, 0.5, 0.5);
    CGFloat radius = NSHeight(capsule) / 2;
    [[tint colorWithAlphaComponent:0.16] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:capsule xRadius:radius yRadius:radius] fill];
    [self.cell drawInteriorWithFrame:NSInsetRect(self.bounds, 8, 0) inView:self];  // the text, inside the capsule's rounded ends
}
@end

// The i beside a card's explanation: its details (credits, licence, sources, instructions) show when the pointer rests on it,
// and stay open when it is clicked, until clicked again.
@interface ADIFInfoButton : NSButton <NSPopoverDelegate>
@property(nonatomic, copy) NSString *details;
+ (instancetype)infoWithDetails:(NSString *)details;
@end
@implementation ADIFInfoButton {
    NSPopover *_popover;
    BOOL _hovered, _pinned;
}
+ (instancetype)infoWithDetails:(NSString *)details {
    ADIFInfoButton *button = [ADIFInfoButton buttonWithImage:settingsGlyph(@"info.circle", theme::faint(), 14) target:nil action:@selector(clicked:)];
    button.target = button;
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.details = T(details);
    button.accessibilityLabel = T(@"More information");
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:18].active = YES;
    [button.heightAnchor constraintEqualToConstant:18].active = YES;
    [button setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return button;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                          owner:self
                                                       userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event {
    _hovered = YES;
    [self showDetails];
}
- (void)mouseExited:(NSEvent *)event {
    _hovered = NO;
    // A short wait lets the pointer reach the details without them closing under it.
    __weak ADIFInfoButton *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ADIFInfoButton *s = weakSelf;
        if (s && !s->_hovered && !s->_pinned) [s->_popover close];
    });
}
- (void)clicked:(id)sender {
    _pinned = !_pinned;
    if (_pinned) [self showDetails];
    else [_popover close];
}
- (void)showDetails {
    if (_popover.shown) return;
    if (!_popover) {
        _popover = [NSPopover new];
        _popover.behavior = NSPopoverBehaviorApplicationDefined;  // a click elsewhere leaves it open; hovering off or clicking closes it
        _popover.delegate = self;
    }
    NSViewController *controller = [NSViewController new];
    controller.view = [self detailsView];
    _popover.contentViewController = controller;
    [_popover showRelativeToRect:self.bounds ofView:self preferredEdge:NSRectEdgeMaxY];
}
- (void)popoverDidClose:(NSNotification *)notification {
    _pinned = NO;
}
- (NSView *)detailsView {
    NSTextField *text = [NSTextField wrappingLabelWithString:self.details];
    text.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [text.widthAnchor constraintEqualToConstant:300].active = YES;
    NSView *view = [[NSView alloc] initWithFrame:NSZeroRect];
    [view addSubview:text];
    [NSLayoutConstraint activateConstraints:@[
        [text.topAnchor constraintEqualToAnchor:view.topAnchor constant:12],
        [text.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-12],
        [text.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:14],
        [text.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-14],
    ]];
    [view setFrameSize:[view fittingSize]];
    return view;
}
@end

// A region's outline, drawn to fit its box with its proportions kept.
@interface ADIFOutlineView : NSView
@property(nonatomic, strong) NSBezierPath *outline;
@end
@implementation ADIFOutlineView
- (void)drawRect:(NSRect)dirtyRect {
    if (!self.outline) return;
    NSRect box = self.outline.bounds;
    if (NSWidth(box) <= 0 || NSHeight(box) <= 0) return;
    NSRect area = NSInsetRect(self.bounds, 2, 2);
    CGFloat scale = MIN(NSWidth(area) / NSWidth(box), NSHeight(area) / NSHeight(box));
    NSAffineTransform *fit = [NSAffineTransform transform];
    [fit translateXBy:NSMinX(area) + (NSWidth(area) - NSWidth(box) * scale) / 2 yBy:NSMinY(area) + (NSHeight(area) - NSHeight(box) * scale) / 2];
    [fit scaleBy:scale];
    [fit translateXBy:-NSMinX(box) yBy:-NSMinY(box)];
    NSBezierPath *shape = [fit transformBezierPath:self.outline];
    NSColor *accent = NSColor.controlAccentColor;
    [[accent colorWithAlphaComponent:0.22] setFill];
    [shape fill];
    shape.lineWidth = 1.5;
    [accent setStroke];
    [shape stroke];
}
@end

// A Remove button that knows which downloaded area (a POTA location, a Map region) its card is for.
@interface ADIFAreaButton : NSButton
@property(nonatomic, copy) NSString *area;
@end
@implementation ADIFAreaButton
@end

@class ADIFAccountCard;

@interface ADIFSettingsPanel () <NSTextFieldDelegate, NSSearchFieldDelegate>
- (NSStackView *)accountListStack;
- (void)accountCard:(ADIFAccountCard *)card draggedTo:(NSPoint)point;
- (void)accountCard:(ADIFAccountCard *)card movedBy:(NSInteger)steps;
- (void)accountCardDropped:(ADIFAccountCard *)card;
- (void)accountCardSave:(ADIFAccountCard *)card;
- (void)accountCardTest:(ADIFAccountCard *)card;
- (void)accountCardRemove:(ADIFAccountCard *)card;
- (void)accountCardCancel:(ADIFAccountCard *)card;
- (void)accountCardToggled:(ADIFAccountCard *)card on:(BOOL)on;
- (void)accountCardMakeDefault:(ADIFAccountCard *)card;
@end

// A status line: hidden while it has nothing to say, so an empty one leaves no gap in its card.
@interface ADIFStatusLine : NSTextField
@end
@implementation ADIFStatusLine
- (void)setStringValue:(NSString *)value {
    [super setStringValue:value ?: @""];
    self.hidden = self.stringValue.length == 0;
}
@end

// An account's card in the Accounts list: a summary that opens to its credentials and actions. The account being set up is a
// card of its own, open, until it is saved.
@interface ADIFAccountCard : ADIFSettingsCard <NSTextFieldDelegate>
@property(nonatomic) ADIFSource source;
@property(nonatomic, copy) NSString *label;  // a log's callsign for QRZ.com Logbook and LoTW; empty for the first account
@property(nonatomic) BOOL isNew;             // an account being set up, not saved yet
@property(nonatomic) ADIFAccountState state;
@property(nonatomic, copy) NSString *note;   // what the last sign-in or save said: the failure line and the pill's tooltip
@property(nonatomic, weak) ADIFSettingsPanel *owner;
- (instancetype)initWithSource:(ADIFSource)source label:(NSString *)label isNew:(BOOL)isNew owner:(ADIFSettingsPanel *)owner;
- (void)refreshFromStore;  // the pills, toggle, buttons and placeholders, from what is saved
- (void)reloadFields;      // the saved username, and a blank password: the saved password is never shown
- (void)setExpanded:(BOOL)expanded;
- (void)focusFirstField;
- (NSString *)typedUser;
- (NSString *)typedSecret;
- (NSString *)typedLabel;  // a new account's log callsign, uppercased; empty when none is asked for
@end

@implementation ADIFSettingsPanel {
    NSMutableDictionary<NSString *, NSStackView *> *_groups;
    NSMutableDictionary<NSString *, NSStackView *> *_groupBodies, *_groupHeaders;
    NSMutableDictionary<NSString *, NSTextField *> *_groupSummaries;
    NSMutableDictionary<NSString *, NSStackView *> *_taken;  // a section's controls, in their panel
    NSMutableDictionary<NSString *, NSView *> *_away;        // in its place here: where they are
    NSMutableDictionary<NSString *, NSStackView *> *_categoryPages;
    NSMutableDictionary<NSString *, NSButton *> *_categoryButtons;
    NSMutableDictionary<NSString *, NSString *> *_categoryDescriptions;
    NSArray<NSString *> *_categoryKeys;
    NSArray<NSString *> *_categoryTitles;
    NSString *_selectedCategory;
    NSSearchField *_searchField;
    NSTextField *_searchFeedback, *_categoryTitle, *_categoryDescription;
    NSImageView *_categoryIcon;
    NSArray<NSImage *> *_categoryIcons;
    NSScrollView *_settingsScroll;
    NSView *_settingsDocument;
    NSStackView *_accountList;                                          // the account cards, in their order
    NSTextField *_accountEmpty;
    NSButton *_addAccount;
    NSPopover *_addPopover;
    NSMutableDictionary<NSString *, ADIFAccountCard *> *_accountCards;  // the saved accounts, by source and label
    ADIFAccountCard *_pendingAccount;                                   // an account being set up: not saved yet
    NSTextField *_countryStatus;
    NSButton *_countryUpdate, *_lotwUpdate;
    NSTextField *_lotwStatus, *_iotaStatus, *_potaStatus;
    NSButton *_iotaUpdate, *_potaUpdate;
    BOOL _countryBusy, _lotwBusy, _iotaBusy, _potaBusy;  // a download started here, until its result comes back
    NSString *_outlinesBusy;                             // the POTA location whose outlines are downloading
    NSSwitch *_checkOnOpen;
    NSTextField *_detailWhat;                            // what the detail level chosen holds
    NSArray<NSString *> *_detailWhats;                   // each level's, from Basic
    NSTextField *_welcome, *_stationCall, *_stationGrid, *_logsFolder, *_stationStatus;
    NSArray<NSSwitch *> *_editorBoxes;
    NSSwitch *_adxSwitch;
    NSStackView *_adxGroup;
    NSSwitch *_offline;
    NSPopUpButton *_language;
    NSPopUpButton *_adifVersion;
    NSStackView *_spotsView;
    NSSwitch *_spotsSpothole, *_spotsCluster, *_spotsPsk;
    NSStackView *_spotsListPage;                                    // the provider rows, and the help
    NSMutableDictionary<NSString *, NSStackView *> *_spotsPages;   // one provider's settings, by key
    NSComboBox *_spotsNode;
    NSTextField *_spotsLogin, *_spotsCommands, *_spotsEmail, *_spotsStatus;
    NSPopUpButton *_spotsPskQuery;
    NSTextField *_spotsPskArea;
    NSComboBox *_outlinesLocation;
    NSButton *_outlinesDownload;
    NSSwitch *_outlinesOn;
    NSStackView *_outlinesCards;  // a card for each location downloaded
    NSTextField *_outlinesNone, *_outlinesStatus, *_outlinesSummary;
    NSTextField *_spotsPskCall;
    id _spotsObserver;
    NSPopUpButton *_detailRegion;
    NSStackView *_detailRegionCards, *_outlinesGroup, *_adifVersionGroup;  // the region cards; the POTA outlines and ADIF version cards
    NSSegmentedControl *_detailLevel;
    NSArray<NSNumber *> *_detailZooms;  // each segment's zoom, Basic first
    NSButton *_detailCheck, *_detailDownload, *_detailStop;
    NSTextField *_detailStatus, *_detailNone;
}

// A settings group has a persistent heading and a flat body; a push button goes in a row of its own size.
static NSStackView *sectionGroup(NSString *title, NSString *symbol, NSArray<NSView *> *views, NSString *identifier, BOOL card, NSView *control) {
    NSMutableArray<NSView *> *parts = [NSMutableArray array];
    for (NSView *v in views) {
        // A push button sits in a row of its own size, not stretched across the card; checkboxes and popups fill it.
        bool push = [v isKindOfClass:NSButton.class] && ![v isKindOfClass:ADIFWrappingCheckbox.class] && ![v isKindOfClass:NSPopUpButton.class];
        [parts addObject:push ? [ADIFWrapRow rowWithViews:@[ v ]] : v];
    }
    NSStackView *body = [[NSStackView alloc] initWithFrame:NSZeroRect];
    body.detachesHiddenViews = YES;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *part in parts) [body addArrangedSubview:part];
    body.orientation = NSUserInterfaceLayoutOrientationVertical;
    body.alignment = NSLayoutAttributeLeading;
    body.spacing = 10;
    for (NSView *v in parts) {
        [v.widthAnchor constraintEqualToAnchor:body.widthAnchor].active = YES;
        [v setContentCompressionResistancePriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];  // the panel's width rules
    }
    NSTextField *heading = [NSTextField labelWithString:T(title)];
    heading.font = [NSFont systemFontOfSize:NSFont.systemFontSize + 1 weight:NSFontWeightSemibold];
    NSStackView *header = [[NSStackView alloc] initWithFrame:NSZeroRect];
    header.detachesHiddenViews = YES;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 7;
    header.edgeInsets = NSEdgeInsetsMake(0, 0, 0, 4);  // keeps the status pill's trailing end inside the heading
    if (symbol.length) {
        NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] ?: [NSImage new]];
        icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
        icon.contentTintColor = theme::faint();
        [icon.widthAnchor constraintEqualToConstant:18].active = YES;
        [header addView:icon inGravity:NSStackViewGravityLeading];
    }
    [heading setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    heading.lineBreakMode = NSLineBreakByTruncatingTail;
    [header addView:heading inGravity:NSStackViewGravityLeading];
    ADIFStatusPill *summary = [ADIFStatusPill pill];
    summary.font = theme::small();
    summary.textColor = theme::faint();
    summary.hidden = YES;
    summary.lineBreakMode = NSLineBreakByTruncatingTail;
    [header addView:summary inGravity:NSStackViewGravityTrailing];
    if (control) [header addView:control inGravity:NSStackViewGravityTrailing];  // a toggle, at the heading's trailing end

    // A card's settings sit in a rounded card, inset from its edges; a flat section has none.
    NSView *content = body;
    if (card) {
        ADIFSettingsCard *box = [[ADIFSettingsCard alloc] initWithFrame:NSZeroRect];
        box.translatesAutoresizingMaskIntoConstraints = NO;
        [box addSubview:body];
        [NSLayoutConstraint activateConstraints:@[
            [body.topAnchor constraintEqualToAnchor:box.topAnchor constant:12],
            [body.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-12],
            [body.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:14],
            [body.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-14],
        ]];
        content = box;
    }
    NSStackView *group = [[NSStackView alloc] initWithFrame:NSZeroRect];
    group.translatesAutoresizingMaskIntoConstraints = NO;
    [group addArrangedSubview:header];
    [group addArrangedSubview:content];
    group.detachesHiddenViews = YES;
    group.orientation = NSUserInterfaceLayoutOrientationVertical;
    group.alignment = NSLayoutAttributeLeading;
    group.spacing = 8;
    group.identifier = identifier;
    [header.widthAnchor constraintEqualToAnchor:group.widthAnchor].active = YES;
    [content.widthAnchor constraintEqualToAnchor:group.widthAnchor].active = YES;
    return group;
}

// A flat section: a heading, then its settings.
static NSStackView *sectionStack(NSString *title, NSString *symbol, NSArray<NSView *> *views, NSString *identifier) {
    return sectionGroup(title, symbol, views, identifier, NO, nil);
}

// "Callsign:" in the language in use (French puts a space before the colon).
static NSString *colon(NSString *label) { return TF(@"{label}:", @{@"label" : label}); }

// A field's name beside its control, as System Settings sets a row: the name leading, the control at the trailing
// edge at a steady width.
static NSStackView *field(NSString *label, NSView *control) {
    NSTextField *name = [NSTextField labelWithString:label];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [control.widthAnchor constraintEqualToConstant:260].active = YES;
    NSStackView *row = [NSStackView stackViewWithViews:@[ name, spacer, control ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 12;
    for (NSView *v in @[ name, control ]) [v setContentCompressionResistancePriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return row;
}

// A setting's name at the leading edge and its switch at the trailing edge, as System Settings sets a toggle row.
static NSStackView *toggleRow(NSString *label, NSSwitch *toggle) {
    NSTextField *name = [NSTextField wrappingLabelWithString:label];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *row = [NSStackView stackViewWithViews:@[ name, spacer, toggle ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 12;
    [name setContentCompressionResistancePriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return row;
}

// A hairline between a page's sections.
static NSBox *settingsRule() {
    NSBox *rule = [NSBox new];
    rule.boxType = NSBoxSeparator;
    rule.translatesAutoresizingMaskIntoConstraints = NO;
    return rule;
}

static NSTextField *wrapping(NSString *text, CGFloat size, NSColor *color) {
    NSTextField *t = text.length ? [NSTextField wrappingLabelWithString:T(text)] : [ADIFStatusLine wrappingLabelWithString:@""];
    t.hidden = text.length == 0;
    t.font = [NSFont systemFontOfSize:size];
    t.textColor = color;
    [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return t;
}

// A card's explanation label, with an i beside it for the details (credits, licence, sources, instructions).
static NSView *explainedLabel(NSTextField *t, NSString *details) {
    if (!details.length) return t;
    NSStackView *row = [NSStackView stackViewWithViews:@[ t, [ADIFInfoButton infoWithDetails:details] ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeTop;
    row.spacing = 8;
    return row;
}

// A card's explanation: what its settings are for, and an i beside it for the details.
static NSView *explained(NSString *text, NSString *details) {
    return explainedLabel(wrapping(text, NSFont.smallSystemFontSize, theme::faint()), details);
}

// A downloaded area as a card: its name and status pill (the pill at the heading's trailing edge), its summary, and a footnote
// along the bottom with Remove at the lower right. A graphic, when given, sits at the leading edge, centred on the card's height.
static ADIFSettingsCard *areaCard(NSString *name, NSString *status, BOOL positive, NSString *summary, NSString *details,
                                  NSString *footnote, NSView *graphic, NSButton *remove) {
    NSTextField *title = [NSTextField labelWithString:name];
    title.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    ADIFStatusPill *pill = [ADIFStatusPill pill];
    pill.stringValue = status;
    [pill setPositive:positive];
    NSStackView *heading = [[NSStackView alloc] initWithFrame:NSZeroRect];
    heading.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    heading.alignment = NSLayoutAttributeCenterY;
    heading.spacing = 6;
    heading.detachesHiddenViews = YES;
    [heading addView:title inGravity:NSStackViewGravityLeading];
    if (details.length) [heading addView:[ADIFInfoButton infoWithDetails:details] inGravity:NSStackViewGravityLeading];
    [heading addView:pill inGravity:NSStackViewGravityTrailing];

    NSTextField *text = [NSTextField wrappingLabelWithString:summary ?: @""];
    text.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    text.textColor = theme::faint();
    text.hidden = summary.length == 0;

    NSTextField *foot = [NSTextField labelWithString:footnote ?: @""];
    foot.font = [NSFont systemFontOfSize:10];
    foot.textColor = NSColor.tertiaryLabelColor;
    foot.lineBreakMode = NSLineBreakByTruncatingTail;
    foot.hidden = footnote.length == 0;
    NSStackView *footer = [[NSStackView alloc] initWithFrame:NSZeroRect];
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footer.alignment = NSLayoutAttributeCenterY;
    footer.spacing = 8;
    footer.detachesHiddenViews = YES;
    [footer addView:foot inGravity:NSStackViewGravityLeading];
    if (remove) [footer addView:remove inGravity:NSStackViewGravityTrailing];
    footer.hidden = footnote.length == 0 && !remove;

    NSStackView *column = [NSStackView stackViewWithViews:@[ heading, text, footer ]];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeLeading;
    column.spacing = 6;
    column.detachesHiddenViews = YES;
    column.translatesAutoresizingMaskIntoConstraints = NO;

    ADIFSettingsCard *card = [[ADIFSettingsCard alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:column];
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [column.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [column.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [column.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
    ]];
    if (graphic) {
        graphic.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:graphic];
        [constraints addObjectsFromArray:@[
            [graphic.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
            [graphic.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
            [graphic.widthAnchor constraintEqualToConstant:104],
            [graphic.heightAnchor constraintEqualToConstant:80],
            [column.leadingAnchor constraintEqualToAnchor:graphic.trailingAnchor constant:14],
            [card.heightAnchor constraintGreaterThanOrEqualToConstant:104],
        ]];
    } else {
        [constraints addObject:[column.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    for (NSView *v in @[ heading, text, footer ]) [v.widthAnchor constraintEqualToAnchor:column.widthAnchor].active = YES;
    return card;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _accountCards = [NSMutableDictionary dictionary];
    _groups = [NSMutableDictionary dictionary];
    _groupBodies = [NSMutableDictionary dictionary];
    _groupHeaders = [NSMutableDictionary dictionary];
    _groupSummaries = [NSMutableDictionary dictionary];
    _categoryPages = [NSMutableDictionary dictionary];
    _categoryButtons = [NSMutableDictionary dictionary];
    _categoryDescriptions = [NSMutableDictionary dictionary];

    _welcome = wrapping(@"Welcome to ADIF Lint. Enter your callsign and grid in Your Station: New QSO and the exports use them for "
                        @"a log that doesn't have them yet. Accounts for QRZ.com, LoTW, eQSL and Club Log are further "
                        @"down, when you want them.",
                        NSFont.systemFontSize, NSColor.labelColor);
    _welcome.hidden = YES;
    _welcome.identifier = @"settings.welcome";

    NSArray<NSStackView *> *primaryGroups = @[ [self stationSection], [self editorSection], [self languageSection], [self offlineSection],
                                                [self keyboardSection], [self countrySection], [self lotwSection], [self potaSection],
                                                [self iotaSection], [self mapDetailSection], [self spotsSection] ];
    for (NSStackView *group in primaryGroups) [self registerGroup:group];
    [self registerGroup:_outlinesGroup];
    [self registerGroup:_adifVersionGroup];
    [self registerGroup:_adxGroup];

    NSStackView *accountsGroup = [self accountsSection];
    [self registerGroup:accountsGroup];

    _categoryKeys = @[ @"station", @"editor", @"accounts", @"data", @"pota", @"map", @"spot-sources", @"application" ];
    _categoryTitles = @[ N(@"Station"), N(@"Editor"), N(@"Accounts"), N(@"Data"), N(@"POTA"), N(@"Map"), N(@"Spot Sources"), N(@"Application") ];
    NSMutableArray<NSView *> *pagesInOrder = [NSMutableArray array];
    NSArray<NSString *> *descriptions = @[
        N(@"Station identity, callsign, grid square and logs folder."),
        N(@"Validation, syntax highlighting, autocomplete and ADIF compatibility."),
        N(@"Accounts for the online services ADIF Lint looks up and uploads to."),
        N(@"Country data, LoTW users and IOTA groups."),
        N(@"POTA parks and their outlines for the Map."),
        N(@"Map detail puts streets, buildings and place names on the Map when you zoom in. Download the regions you log from or "
          @"activate: each is kept on this Mac, so the Map draws it fast and without a network connection. Choose a level of detail; "
          @"more detail means a bigger download."),
        N(@"Configure SpotHole, DX Cluster and PSKReporter feeds."),
        N(@"Language, Offline Mode and keyboard shortcuts.")
    ];
    NSArray<NSArray<NSView *> *> *content = @[
        @[ _welcome, _groups[@"settings.station"] ],
        @[ _groups[@"settings.editor"], _adxGroup, _adifVersionGroup ],
        @[ accountsGroup ],
        @[ _groups[@"settings.country"], _groups[@"settings.lotwusers"], _groups[@"settings.iota"] ],
        @[ _groups[@"settings.pota"], _outlinesGroup ],
        @[ _groups[@"settings.mapdetail"], _detailRegionCards ],
        @[ _groups[@"settings.spots"] ],
        @[ _groups[@"settings.offline"], _groups[@"settings.language"], _groups[@"settings.keyboard"] ]
    ];

    NSView *root = [[ADIFSettingsDocument alloc] initWithFrame:NSZeroRect];
    root.identifier = @"settings";
    [root.widthAnchor constraintGreaterThanOrEqualToConstant:640].active = YES;
    [root.heightAnchor constraintGreaterThanOrEqualToConstant:420].active = YES;
    NSStackView *sidebar = [NSStackView stackViewWithViews:@[]];
    sidebar.identifier = @"settings.sidebar";
    sidebar.orientation = NSUserInterfaceLayoutOrientationVertical;
    sidebar.detachesHiddenViews = YES;
    sidebar.alignment = NSLayoutAttributeLeading;
    sidebar.spacing = 4;
    sidebar.edgeInsets = NSEdgeInsetsMake(16, 14, 14, 12);
    sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    // The search field is in the window's title bar (ADIFLint.mm), at the top right, as in System Settings.
    _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.placeholderString = T(@"Search Settings");
    _searchField.identifier = @"settings.search";
    _searchField.delegate = self;
    _searchField.target = self;
    _searchField.action = @selector(searchSettings:);
    NSLayoutConstraint *searchWidth = [_searchField.widthAnchor constraintEqualToConstant:220];
    searchWidth.priority = 750;  // the title bar's box gives the field its width; this is its preferred one
    searchWidth.active = YES;
    _searchFeedback = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _searchFeedback.translatesAutoresizingMaskIntoConstraints = NO;
    _searchFeedback.identifier = @"settings.search.feedback";

    // Each category's symbol, as in System Settings' sidebar; its page heading shows it large in the accent colour.
    NSArray<NSString *> *symbols = @[
        @"antenna.radiowaves.left.and.right", @"square.and.pencil", @"key", @"cylinder.split.1x2", @"leaf", @"map",
        @"dot.radiowaves.left.and.right", @"slider.horizontal.3"
    ];
    NSMutableArray<NSImage *> *icons = [NSMutableArray array];
    for (NSUInteger i = 0; i < symbols.count; ++i) [icons addObject:settingsGlyph(symbols[i], NSColor.controlAccentColor, 30)];
    _categoryIcons = icons;

    for (NSUInteger i = 0; i < _categoryKeys.count; ++i) {
        NSString *key = _categoryKeys[i], *title = _categoryTitles[i];
        ADIFSettingsNavButton *button = [[ADIFSettingsNavButton alloc] initWithFrame:NSZeroRect];
        button.title = T(title);
        button.target = self;
        button.action = @selector(categorySelected:);
        button.buttonType = NSButtonTypeToggle;
        button.bordered = NO;
        button.glyph = settingsGlyph(symbols[i], NSColor.labelColor, 17);
        button.chosenGlyph = settingsGlyph(symbols[i], NSColor.alternateSelectedControlTextColor, 17);
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.identifier = [@"settings.nav." stringByAppendingString:key];
        button.accessibilityLabel = T(title);
        button.tag = (NSInteger)i;
        [sidebar addArrangedSubview:button];
        [button.widthAnchor constraintEqualToAnchor:sidebar.widthAnchor constant:-26].active = YES;
        [button.heightAnchor constraintEqualToConstant:[key isEqualToString:@"station"] ? 46 : 34].active = YES;
        _categoryButtons[key] = button;

        NSStackView *page = [[NSStackView alloc] initWithFrame:NSZeroRect];
        page.detachesHiddenViews = YES;
        page.translatesAutoresizingMaskIntoConstraints = NO;
        for (NSView *section in content[i]) {
            if (page.arrangedSubviews.count) [page addArrangedSubview:settingsRule()];
            [page addArrangedSubview:section];
        }
        page.orientation = NSUserInterfaceLayoutOrientationVertical;
        page.alignment = NSLayoutAttributeLeading;
        page.spacing = 18;
        page.identifier = [@"settings.page." stringByAppendingString:key];
        for (NSView *section in page.arrangedSubviews)
            [section.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;
        page.hidden = YES;
        _categoryPages[key] = page;
        [pagesInOrder addObject:page];
    }

    [sidebar addArrangedSubview:_searchFeedback];
    [_searchFeedback.widthAnchor constraintEqualToAnchor:sidebar.widthAnchor constant:-26].active = YES;

    NSStackView *main = [NSStackView stackViewWithViews:@[]];
    main.orientation = NSUserInterfaceLayoutOrientationVertical;
    main.detachesHiddenViews = YES;
    main.alignment = NSLayoutAttributeLeading;
    main.spacing = 14;
    main.edgeInsets = NSEdgeInsetsMake(18, 18, 16, 18);
    main.translatesAutoresizingMaskIntoConstraints = NO;
    // The page's heading: its large icon, then its name and a line about it.
    _categoryIcon = [NSImageView imageViewWithImage:_categoryIcons.firstObject];
    [_categoryIcon.widthAnchor constraintEqualToConstant:32].active = YES;
    [_categoryIcon.heightAnchor constraintEqualToConstant:32].active = YES;
    _categoryTitle = [NSTextField labelWithString:@""];
    _categoryTitle.font = [NSFont systemFontOfSize:24 weight:NSFontWeightBold];
    _categoryDescription = wrapping(@"", NSFont.systemFontSize, theme::faint());
    NSStackView *titles = [NSStackView stackViewWithViews:@[ _categoryTitle, _categoryDescription ]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 3;
    titles.detachesHiddenViews = YES;
    NSStackView *heading = [NSStackView stackViewWithViews:@[ _categoryIcon, titles ]];
    heading.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    heading.alignment = NSLayoutAttributeTop;
    heading.spacing = 14;
    [main addArrangedSubview:heading];
    _categoryDescription.hidden = NO;
    [_categoryDescription.widthAnchor constraintEqualToAnchor:main.widthAnchor constant:-(36 + 58)].active = YES;

    _settingsScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _settingsScroll.hasVerticalScroller = YES;
    _settingsScroll.autohidesScrollers = YES;
    _settingsScroll.drawsBackground = NO;
    _settingsScroll.borderType = NSNoBorder;
    _settingsScroll.translatesAutoresizingMaskIntoConstraints = NO;
    ADIFSettingsDocument *document = [[ADIFSettingsDocument alloc] initWithFrame:NSZeroRect];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    _settingsDocument = document;
    NSStackView *pages = [[NSStackView alloc] initWithFrame:NSZeroRect];
    pages.orientation = NSUserInterfaceLayoutOrientationVertical;
    pages.alignment = NSLayoutAttributeLeading;
    pages.spacing = 0;
    pages.detachesHiddenViews = YES;
    pages.identifier = @"settings.pages";
    pages.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *page in pagesInOrder) [pages addArrangedSubview:page];
    [document addSubview:pages];
    for (NSView *page in pages.arrangedSubviews)
        [page.widthAnchor constraintEqualToAnchor:pages.widthAnchor].active = YES;
    _settingsScroll.documentView = document;
    NSClipView *clip = _settingsScroll.contentView;
    [NSLayoutConstraint activateConstraints:@[
        [document.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [document.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [document.widthAnchor constraintEqualToAnchor:clip.widthAnchor],
        [pages.topAnchor constraintEqualToAnchor:document.topAnchor],
        [pages.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [pages.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [document.bottomAnchor constraintEqualToAnchor:pages.bottomAnchor],
    ]];
    [main addArrangedSubview:_settingsScroll];
    [_settingsScroll.widthAnchor constraintEqualToAnchor:main.widthAnchor constant:-36].active = YES;
    [_settingsScroll.heightAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;

    NSView *divider = [NSView new];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.wantsLayer = YES;
    divider.layer.backgroundColor = NSColor.separatorColor.CGColor;
    [divider.widthAnchor constraintEqualToConstant:1].active = YES;
    [root addSubview:sidebar];
    [root addSubview:divider];
    [root addSubview:main];
    [NSLayoutConstraint activateConstraints:@[
        [sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [sidebar.topAnchor constraintEqualToAnchor:root.topAnchor],
        [sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [sidebar.widthAnchor constraintEqualToConstant:210],
        [divider.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [divider.topAnchor constraintEqualToAnchor:root.topAnchor],
        [divider.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [main.leadingAnchor constraintEqualToAnchor:divider.trailingAnchor],
        [main.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [main.topAnchor constraintEqualToAnchor:root.topAnchor],
        [main.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        [main.widthAnchor constraintGreaterThanOrEqualToConstant:360],
    ]];

    _view = root;
    for (NSUInteger i = 0; i < _categoryKeys.count; ++i) {
        NSStackView *page = _categoryPages[_categoryKeys[i]];
        page.identifier = [@"settings.page." stringByAppendingString:_categoryKeys[i]];
        page.accessibilityLabel = T(_categoryTitles[i]);
        _categoryDescriptions[_categoryKeys[i]] = T(descriptions[i]);
    }
    [self refresh];
    // The main button of each reference-data group sits in its heading, beside the status pill.
    [self putInHeader:_countryUpdate ofGroup:@"settings.country"];
    [self putInHeader:_potaUpdate ofGroup:@"settings.pota"];
    [self putInHeader:_iotaUpdate ofGroup:@"settings.iota"];
    [self selectCategory:@"station"];
    return self;
}

- (void)registerGroup:(NSStackView *)group {
    NSString *ident = group.identifier;
    _groups[ident] = group;
    _groupHeaders[ident] = group.arrangedSubviews.firstObject;
    NSView *content = group.arrangedSubviews.count > 1 ? group.arrangedSubviews[1] : nil;  // a card's rows are inside it
    _groupBodies[ident] = [content isKindOfClass:ADIFSettingsCard.class] ? (NSStackView *)content.subviews.firstObject : (NSStackView *)content;
    NSStackView *header = _groupHeaders[ident];
    for (NSView *v in header.arrangedSubviews)
        if ([v isKindOfClass:NSTextField.class] && ((NSTextField *)v).stringValue.length == 0) _groupSummaries[ident] = (NSTextField *)v;
}

- (NSStackView *)stationSection {
    _stationCall = [NSTextField textFieldWithString:@""];
    _stationCall.placeholderString = T(@"e.g. KW9D");
    _stationGrid = [NSTextField textFieldWithString:@""];
    _stationGrid.placeholderString = T(@"e.g. EN52");
    _stationCall.identifier = @"settings.station.call";
    _stationGrid.identifier = @"settings.station.grid";
    _logsFolder = [NSTextField labelWithString:@""];
    _logsFolder.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_logsFolder setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *choose = [NSButton buttonWithTitle:T(@"Choose...") target:self action:@selector(chooseFolder:)];
    NSStackView *folder = [NSStackView stackViewWithViews:@[ _logsFolder, choose ]];
    folder.spacing = 8;
    NSButton *save = [NSButton buttonWithTitle:T(@"Save") target:self action:@selector(saveStation:)];
    NSButton *profiles = [NSButton buttonWithTitle:T(@"Station Profiles...") target:self action:@selector(stationProfiles:)];
    profiles.toolTip = T(@"Named sets of your station's fields (home, portable, a club station) for New QSO and activations");
    ADIFWrapRow *buttons = [ADIFWrapRow rowWithViews:@[ save, profiles ]];
    _stationStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _stationStatus.identifier = @"settings.station.status";
    NSTextField *help = wrapping(@"Used when a log doesn't say: New QSO fills STATION_CALLSIGN and MY_GRIDSQUARE from them "
                                 @"in a new log, and the exports use the callsign. Worked Before searches the logs folder.",
                                 NSFont.smallSystemFontSize, theme::faint());
    return sectionStack(N(@"Your Station"), @"person.crop.circle", @[ help, field(T(@"Callsign:"), _stationCall), field(T(@"Grid:"), _stationGrid), field(T(@"Logs folder:"), folder), buttons,
                                               _stationStatus ],
                        @"settings.station");
}

- (void)stationProfiles:(id)sender {
    if (self.onStationProfiles) self.onStationProfiles();
}

- (void)chooseFolder:(id)sender {
    if (self.onChooseLogsFolder) self.onChooseLogsFolder();
}

- (void)saveStation:(id)sender {
    if (self.onStationSave) self.onStationSave(_stationCall.stringValue, _stationGrid.stringValue);
}

- (void)setStationCall:(NSString *)call grid:(NSString *)grid logsFolder:(NSString *)folder {
    _stationCall.stringValue = call ?: @"";
    _stationGrid.stringValue = grid ?: @"";
    _logsFolder.stringValue = folder.length ? folder.stringByAbbreviatingWithTildeInPath : T(@"(none)");
    [self summarize];
}

- (void)setStationStatus:(NSString *)text ok:(BOOL)ok {
    _stationStatus.stringValue = T(text);
    _stationStatus.textColor = ok ? theme::faint() : theme::error();
}

- (NSStackView *)editorSection {
    NSArray<NSString *> *titles = @[
        N(@"Check .adi files while typing (problem marks)"), N(@"Colour ADIF syntax"),
        N(@"Autocomplete field names and values, with lengths"), N(@"Count lengths in characters, not bytes (for UTF-8 logs)")
    ];
    NSMutableArray<NSView *> *rows = [NSMutableArray array];
    NSMutableArray<NSSwitch *> *switches = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; ++i) {
        NSSwitch *s = [self toggleWithAction:@selector(editorOption:)];
        s.tag = (NSInteger)i;
        [switches addObject:s];
        [rows addObject:toggleRow(T(titles[i]), s)];
    }
    _editorBoxes = switches;
    // The ADIF version the checks follow: the newest (which moves on as ADIF Lint learns newer ones), or a fixed older one.
    _adifVersion = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _adifVersion.identifier = @"settings.adifversion.popup";
    for (const auto &[value, title] : adifhost::adifVersionChoices()) {
        [_adifVersion addItemWithTitle:ADIFString(title)];
        _adifVersion.lastItem.representedObject = ADIFString(value);
    }
    _adifVersion.target = self;
    _adifVersion.action = @selector(adifVersionChosen:);
    NSTextField *help = wrapping(@"The ADIF version the problem marks, Check Log and autocomplete follow, and the one the logs ADIF Lint "
                                 @"writes declare. Choose an older one when your logs must suit a program that reads it: fields and "
                                 @"values that came later are marked, with the version that brought them. The version each log "
                                 @"declares checks every log against its own ADIF_VER. Check Log offers the same choice.",
                                 NSFont.smallSystemFontSize, theme::faint());
    _adifVersionGroup = sectionGroup(N(@"ADIF Version"), @"doc.text", @[ field(T(@"Check against:"), _adifVersion), help ], @"settings.adifversion", YES, nil);
    _adxSwitch = [self toggleWithAction:@selector(editorOption:)];
    _adxSwitch.tag = 4;
    _adxSwitch.identifier = @"settings.adx.switch";
    _adxGroup = sectionGroup(N(@"ADX Files"), @"doc.richtext",
                             @[ explained(@"ADX is ADIF's XML form. With this on, .adx and other XML files are checked against the ADX schemas.",
                                          @"ADX is defined by the ADIF specification (adif.org). Off, XML files are not checked and their problem marks are removed."),
                                toggleRow(T(@"Check ADX files"), _adxSwitch) ],
                             @"settings.adx", YES, nil);
    _checkOnOpen = [self toggleWithAction:@selector(editorOption:)];
    _checkOnOpen.tag = 5;
    _checkOnOpen.identifier = @"settings.checkonopen.switch";
    [rows addObject:toggleRow(T(@"Check the log when a file opens"), _checkOnOpen)];
    return sectionGroup(N(@"Editing"), @"pencil", rows, @"settings.editor", YES, nil);
}

- (void)adifVersionChosen:(id)sender {
    if (self.onAdifVersion) self.onAdifVersion(_adifVersion.selectedItem.representedObject ?: @"");
    [self summarize];
}

- (void)setAdifVersion:(NSString *)version {
    NSInteger at = [_adifVersion indexOfItemWithRepresentedObject:version ?: @""];
    [_adifVersion selectItemAtIndex:at < 0 ? 0 : at];
    [self summarize];
}

- (void)editorOption:(NSSwitch *)sender {
    if (self.onEditorOption) self.onEditorOption(sender.tag, sender.state == NSControlStateValueOn);
    [self summarize];
}

- (void)setCheckLogOnOpen:(BOOL)on {
    _checkOnOpen.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    [self summarize];
}

- (void)setAdxCheck:(BOOL)on {
    _adxSwitch.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)setEditorValidate:(BOOL)validate colour:(BOOL)colour autocomplete:(BOOL)autocomplete characters:(BOOL)characters {
    BOOL on[] = {validate, colour, autocomplete, characters};
    for (NSUInteger i = 0; i < _editorBoxes.count && i < 4; ++i)
        _editorBoxes[i].state = on[i] ? NSControlStateValueOn : NSControlStateValueOff;
    [self summarize];
}

- (NSStackView *)languageSection {
    _language = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _language.identifier = @"settings.language.popup";
    [_language addItemWithTitle:@"-"];  // Nextpad++'s language, named in setLanguage:
    _language.lastItem.representedObject = @"";
    for (const auto &[code, name] : ADIFLanguages()) {
        [_language addItemWithTitle:@(name.c_str())];
        _language.lastItem.representedObject = @(code.c_str());
    }
    _language.target = self;
    _language.action = @selector(languageChosen:);
    NSTextField *help = wrapping(@"The language of ADIF Lint's menu, windows and messages. The translations were drafted by Claude, "
                                 @"an AI, and are waiting for review by native speakers; anything not yet translated shows in "
                                 @"English, and so does the User Guide. The menu and new messages change at once; windows ADIF "
                                 @"Lint has already shown change when Nextpad++ starts again.",
                                 NSFont.smallSystemFontSize, theme::faint());
    return sectionGroup(N(@"Language"), @"globe", @[ help, field(T(@"Language:"), _language) ], @"settings.language", YES, nil);
}

- (void)languageChosen:(id)sender {
    if (self.onLanguageChosen) self.onLanguageChosen(_language.selectedItem.representedObject ?: @"");
}

- (void)setLanguage:(NSString *)code {
    std::string host = ADIFHostLanguage(), hostName = "English";
    for (const auto &[c, name] : ADIFLanguages())
        if (c == host) hostName = name;
    [_language itemAtIndex:0].title = TF(@"Same as Nextpad++ ({language})", @{@"language" : @(hostName.c_str())});
    NSInteger at = [_language indexOfItemWithRepresentedObject:code ?: @""];
    [_language selectItemAtIndex:at < 0 ? 0 : at];
    [self summarize];
}

- (NSStackView *)offlineSection {
    _offline = [self toggleWithAction:@selector(offlineToggled:)];  // in the card's heading
    _offline.identifier = @"settings.offline.switch";
    _offline.accessibilityLabel = T(@"Work offline: make no network requests");
    NSTextField *help = wrapping(@"For off-grid operating, or to be sure nothing is sent. Callbook lookups, spots, uploads (TQSL "
                                 @"too), imports from the online services, downloads and web pages are refused while it is on; "
                                 @"everything that works on this Mac's files goes on, and Monitor still hears the programs on "
                                 @"this Mac. Also in the ADIF Lint menu: Offline Mode.",
                                 NSFont.smallSystemFontSize, theme::faint());
    return sectionGroup(N(@"Offline Mode"), @"wifi.slash", @[ help ], @"settings.offline", YES, _offline);
}

- (NSStackView *)mapDetailSection {
    _detailWhat = wrapping(@"Streets, buildings, land use, water and place names on the Map when you zoom in, for the regions you choose.",
                           NSFont.smallSystemFontSize, theme::faint());
    NSView *help = explainedLabel(_detailWhat,
                                  @"Credits: © OpenStreetMap contributors, ODbL (openstreetmap.org/copyright).\n"
                                  @"Source: Protomaps' daily builds (protomaps.com), kept on this Mac; the Map draws only from what is kept here.\n"
                                  @"Check Size reads the build's index for the region and says what it would take: a city is about 10 MB with "
                                  @"streets and buildings, a state hundreds.");
    _detailRegion = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _detailRegion.identifier = @"settings.mapdetail.region";
    // The detail is three segments, Basic to Detailed; each says its full name (the level's) when pointed at.
    _detailLevel = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    _detailLevel.identifier = @"settings.mapdetail.level";
    _detailLevel.trackingMode = NSSegmentSwitchTrackingSelectOne;
    for (NSControl *c in @[ _detailRegion, _detailLevel ]) {
        c.target = self;
        c.action = @selector(detailChoiceChanged:);
    }
    _detailCheck = [NSButton buttonWithTitle:T(@"Check Size") target:self action:@selector(detailCheck:)];
    _detailDownload = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(detailDownload:)];
    _detailStop = [NSButton buttonWithTitle:T(@"Stop") target:self action:@selector(detailStop:)];
    _detailDownload.enabled = _detailStop.enabled = NO;
    ADIFWrapRow *buttons = [ADIFWrapRow rowWithViews:@[ _detailCheck, _detailDownload, _detailStop ]];
    _detailStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _detailStatus.identifier = @"settings.mapdetail.status";
    // What is downloaded: a card for each region (setMapDetailChoices:), or a line saying there is none.
    _detailNone = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _detailNone.identifier = @"settings.mapdetail.none";
    _detailRegionCards = [NSStackView stackViewWithViews:@[ _detailNone ]];
    _detailRegionCards.orientation = NSUserInterfaceLayoutOrientationVertical;
    _detailRegionCards.alignment = NSLayoutAttributeLeading;
    _detailRegionCards.spacing = 12;
    _detailRegionCards.detachesHiddenViews = YES;
    _detailRegionCards.identifier = @"settings.mapdetail.regions";
    return sectionGroup(N(@"Map Detail"), @"map",
                        @[ help, field(colon(T(@"Region")), _detailRegion), field(colon(T(@"Detail")), _detailLevel), buttons, _detailStatus ],
                        @"settings.mapdetail", YES, nil);
}

// The zoom of the detail segment chosen (nil until the levels are known).
- (NSNumber *)selectedDetailZoom {
    NSInteger at = _detailLevel.selectedSegment;
    return at >= 0 && at < (NSInteger)_detailZooms.count ? _detailZooms[(NSUInteger)at] : nil;
}

- (void)setMapDetailChoices:(NSArray<NSArray *> *)choices
                     levels:(NSArray<NSArray *> *)levels
                  installed:(NSArray<NSArray *> *)installed {
    id was = _detailRegion.selectedItem.representedObject, level = [self selectedDetailZoom];
    [_detailRegion removeAllItems];
    NSString *group = nil;
    for (NSArray *c in choices) {
        NSString *ident = c[0], *kind = [ident hasPrefix:@"state:"] ? @"state" : [ident hasPrefix:@"country:"] ? @"country" : @"view";
        if (group && ![group isEqualToString:kind]) [_detailRegion.menu addItem:[NSMenuItem separatorItem]];
        group = kind;
        NSMenuItem *item = [_detailRegion.menu addItemWithTitle:c[1] action:nil keyEquivalent:@""];
        item.representedObject = ident;
    }
    NSInteger at = was ? [_detailRegion indexOfItemWithRepresentedObject:was] : -1;
    if (at >= 0) [_detailRegion selectItemAtIndex:at];
    // Basic (the least detail) to Detailed, whatever order the levels come in. Each level: its zoom, its tooltip, its name on
    // the slider, and what it holds (shown when it is chosen).
    NSArray *ascending = [levels sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    NSMutableArray<NSNumber *> *zooms = [NSMutableArray array];
    NSMutableArray<NSString *> *whats = [NSMutableArray array];
    _detailLevel.segmentCount = (NSInteger)ascending.count;
    for (NSUInteger i = 0; i < ascending.count; ++i) {
        [_detailLevel setLabel:ascending[i][2] forSegment:(NSInteger)i];
        [_detailLevel setToolTip:ascending[i][1] forSegment:(NSInteger)i];
        [zooms addObject:ascending[i][0]];
        [whats addObject:ascending[i][3]];
    }
    _detailZooms = zooms;
    _detailWhats = whats;
    at = level ? (NSInteger)[zooms indexOfObject:level] : -1;
    _detailLevel.selectedSegment = at >= 0 ? at : (NSInteger)zooms.count - 1;  // the most detail, as the popup began
    [self showDetailWhat];
    // A card for each region downloaded, with its Remove; none, the line saying so.
    for (NSView *card in [_detailRegionCards.arrangedSubviews copy])
        if (card != _detailNone) {
            [_detailRegionCards removeArrangedSubview:card];
            [card removeFromSuperview];
        }
    _detailNone.stringValue = installed.count ? @"" : T(@"None downloaded yet.");
    __weak ADIFSettingsPanel *me = self;
    for (NSArray *region in installed) {  // @[ path, name, summary, size, outline or NSNull ]
        NSString *path = region[0];
        ADIFAreaButton *remove = [ADIFAreaButton buttonWithTitle:T(@"Remove") target:nil action:nil];
        ADIFOnAction(remove, ^{
            ADIFSettingsPanel *panel = me;
            if (panel.onMapDetailRemove) panel.onMapDetailRemove(path);
        });
        NSBezierPath *outline = [region[4] isKindOfClass:NSBezierPath.class] ? region[4] : nil;
        NSView *graphic = nil;
        if (outline) {
            ADIFOutlineView *shape = [[ADIFOutlineView alloc] initWithFrame:NSZeroRect];
            shape.outline = outline;
            graphic = shape;
        }
        ADIFSettingsCard *card = areaCard(region[1], T(@"Installed"), YES, region[2], nil, region[3], graphic, remove);
        card.identifier = [@"settings.mapdetail.region." stringByAppendingString:path];
        [_detailRegionCards addArrangedSubview:card];
        [card.widthAnchor constraintEqualToAnchor:_detailRegionCards.widthAnchor].active = YES;
    }
    [self summarize];
}

- (void)showDetailWhat {
    NSInteger at = _detailLevel.selectedSegment;
    if (at >= 0 && at < (NSInteger)_detailWhats.count) _detailWhat.stringValue = _detailWhats[(NSUInteger)at];
}

- (void)setMapDetailState:(NSString *)message ok:(BOOL)ok checked:(BOOL)checked busy:(BOOL)busy {
    _detailStatus.stringValue = T(message);
    _detailStatus.textColor = ok ? theme::faint() : theme::error();
    _detailDownload.enabled = checked && !busy;
    _detailStop.enabled = busy;
    _detailCheck.enabled = !busy;
    _detailRegion.enabled = _detailLevel.enabled = !busy;
}

- (void)detailChoiceChanged:(id)sender {
    if (sender == _detailLevel) [self showDetailWhat];
    _detailDownload.enabled = NO;  // check again for the new choice
    _detailStatus.stringValue = @"";
}

- (void)detailCheck:(id)sender {
    NSString *choice = _detailRegion.selectedItem.representedObject;
    NSNumber *zoom = [self selectedDetailZoom];
    if (choice && zoom && self.onMapDetailCheck) self.onMapDetailCheck(choice, zoom.integerValue);
}

- (void)detailDownload:(id)sender {
    if (self.onMapDetailDownload) self.onMapDetailDownload();
}

- (void)detailStop:(id)sender {
    if (self.onMapDetailStop) self.onMapDetailStop();
}

// Map Detail's Remove is on each region's card (setMapDetailChoices:).

- (void)offlineToggled:(id)sender {
    if (self.onOfflineToggled) self.onOfflineToggled(_offline.state == NSControlStateValueOn);
    [self summarize];
}

- (void)setOffline:(BOOL)on {
    _offline.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    [self summarize];
}

- (NSStackView *)keyboardSection {
    NSTextField *help = wrapping(
        @"Nextpad++ binds plugin commands in its own Shortcut Mapper: Edit > Shortcut Mapper..., the Plugin commands tab. "
        @"Suggestions: New QSO Control-Option-N, Log Table Control-Option-T, Check Log Control-Option-C, Next Problem "
        @"Control-Option-Down, Previous Problem Control-Option-Up, Spots Control-Option-S (pick others if Nextpad++ "
        @"already uses one).",
        NSFont.smallSystemFontSize, theme::faint());
    return sectionGroup(N(@"Keyboard Shortcuts"), @"keyboard", @[ help ], @"settings.keyboard", YES, nil);
}

- (void)selectCategory:(NSString *)key {
    NSUInteger index = [_categoryKeys indexOfObject:key];
    if (index == NSNotFound) return;
    _selectedCategory = key;
    for (NSString *candidate in _categoryKeys) {
        _categoryPages[candidate].hidden = ![candidate isEqualToString:key];
        _categoryButtons[candidate].state = [candidate isEqualToString:key] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    _categoryTitle.stringValue = T(_categoryTitles[index]);
    _categoryIcon.image = _categoryIcons[index];
    _categoryDescription.stringValue = _categoryDescriptions[key] ?: @"";
    [_settingsScroll layoutSubtreeIfNeeded];
    [_settingsScroll.contentView scrollToPoint:NSZeroPoint];
    [_settingsScroll reflectScrolledClipView:_settingsScroll.contentView];
}

- (void)categorySelected:(NSButton *)sender {
    NSString *prefix = @"settings.nav.";
    if ([sender.identifier hasPrefix:prefix]) [self selectCategory:[sender.identifier substringFromIndex:prefix.length]];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _searchField) [self searchSettings:_searchField];
}

- (NSView *)matchingSettingInView:(NSView *)view query:(NSString *)query {
    if (!view) return nil;
    NSMutableString *text = [NSMutableString string];
    if ([view isKindOfClass:NSTextField.class]) {
        NSTextField *field = (NSTextField *)view;
        // A setting's name, field, status and heading are on one line; an explanation wraps over several, and is not searched.
        if (field.editable || field.lineBreakMode != NSLineBreakByWordWrapping)
            [text appendFormat:@"%@ %@", field.stringValue ?: @"", field.placeholderString ?: @""];
    } else if ([view isKindOfClass:NSButton.class]) {
        [text appendString:((NSButton *)view).title ?: @""];
    } else if ([view isKindOfClass:NSPopUpButton.class]) {
        for (NSMenuItem *item in ((NSPopUpButton *)view).itemArray) [text appendFormat:@" %@", item.title];
    } else if ([view isKindOfClass:NSComboBox.class]) {
        NSComboBox *combo = (NSComboBox *)view;
        [text appendFormat:@"%@ %@", combo.stringValue ?: @"", combo.placeholderString ?: @""];
        for (id item in combo.objectValues) [text appendFormat:@" %@", item];
    }
    if ([text rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound)
        return view;
    for (NSView *child in view.subviews)
        if (NSView *match = [self matchingSettingInView:child query:query]) return match;
    return nil;
}

- (void)searchSettings:(id)sender {
    NSString *query = [_searchField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) {
        _searchFeedback.stringValue = @"";
        _searchFeedback.hidden = YES;
        return;
    }
    // A setting first (its heading, field, button or switch, in any category), then a category's name.
    NSString *matchedCategory = nil;
    NSView *match = nil;
    for (NSString *key in _categoryKeys) {
        match = [self matchingSettingInView:_categoryPages[key] query:query];
        if (match) {
            matchedCategory = key;
            break;
        }
    }
    for (NSUInteger i = 0; !matchedCategory && i < _categoryKeys.count; ++i) {
        NSString *key = _categoryKeys[i];
        NSString *categoryText = [NSString stringWithFormat:@"%@ %@", T(_categoryTitles[i]), _categoryDescriptions[key]];
        if ([categoryText rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound)
            matchedCategory = key;
    }
    if (!matchedCategory) {
        _searchFeedback.stringValue = T(@"No matching settings.");
        _searchFeedback.hidden = NO;
        return;
    }
    [self selectCategory:matchedCategory];
    if ([matchedCategory isEqualToString:@"spot-sources"]) {  // a provider's setting shows its page; anything else, the list
        NSString *page = nil;
        for (NSString *key in _spotsPages)
            if (match && [match isDescendantOf:_spotsPages[key]]) page = key;
        [self showSpotsPage:page];
    }
    _searchFeedback.stringValue = T(@"Showing matching setting.");
    _searchFeedback.hidden = NO;
    if (match) {
        [_settingsScroll layoutSubtreeIfNeeded];
        [match scrollRectToVisible:match.bounds];
    }
}

- (NSString *)categoryForGroup:(NSString *)ident {
    if ([ident hasPrefix:@"settings.station"]) return @"station";
    if ([ident hasPrefix:@"settings.editor"]) return @"editor";
    if ([ident hasPrefix:@"settings.accounts"] || [ident hasPrefix:@"settings.source."]) return @"accounts";
    if ([ident hasPrefix:@"settings.country"] || [ident hasPrefix:@"settings.lotwusers"] || [ident hasPrefix:@"settings.iota"]) return @"data";
    if ([ident hasPrefix:@"settings.pota"] || [ident hasPrefix:@"settings.outlines"]) return @"pota";
    if ([ident hasPrefix:@"settings.mapdetail"]) return @"map";
    if ([ident hasPrefix:@"settings.spots"]) return @"spot-sources";
    if ([ident hasPrefix:@"settings.language"] || [ident hasPrefix:@"settings.offline"] ||
        [ident hasPrefix:@"settings.keyboard"]) return @"application";
    return nil;
}

- (void)showWelcome {
    _welcome.hidden = NO;
    [self selectCategory:@"station"];
    [_view.window makeFirstResponder:_stationCall];
    [_welcome scrollRectToVisible:_welcome.bounds];
}

- (void)openGroup:(NSString *)ident {
    NSString *category = [self categoryForGroup:ident];
    if (category) [self selectCategory:category];
    [_view layoutSubtreeIfNeeded];
    NSView *group = _groups[ident];
    if (group) {
        [_settingsScroll layoutSubtreeIfNeeded];
        [group scrollRectToVisible:group.bounds];
    }
}

- (NSStackView *)countrySection {
    NSView *help = explained(@"Works out a call's DXCC entity, CQ and ITU zones and continent from its prefix, offline, for Enrich and New QSO.",
                             @"Credits: Jim Reisert, AD1C, Big CTY country files (country-files.com).\n"
                             @"Licence: MIT (data/cty-copyright.txt).\n"
                             @"Update downloads the newest release, updated every few weeks.");
    _countryUpdate = [NSButton buttonWithTitle:T(@"Update") target:self action:@selector(countryUpdate:)];
    _countryStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    return sectionGroup(N(@"Country Data"), @"flag", @[ help, _countryUpdate, _countryStatus ], @"settings.country", YES, nil);
}

- (NSStackView *)lotwSection {
    NSView *help = explained(@"Shows which stations upload to LoTW, and when they last did, in New QSO's lookup and in the Spots window.",
                             @"Credits: ARRL's LoTW user activity list (lotw.arrl.org/lotw-user-activity.csv), about 6 MB; not included with ADIF Lint.\n"
                             @"Downloaded when you press Update, and again once a week, into the plugin's settings folder on this Mac.");
    // Update takes the switch's place in the heading: the list is in use whenever it is downloaded.
    _lotwUpdate = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(lotwUpdate:)];
    _lotwUpdate.identifier = @"settings.lotwusers.update";
    _lotwStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    return sectionGroup(N(@"LoTW Users"), @"checkmark.seal", @[ help, _lotwStatus ], @"settings.lotwusers", YES, _lotwUpdate);
}

- (void)lotwUpdate:(id)sender {
    _lotwBusy = YES;
    _lotwUpdate.enabled = NO;
    _lotwStatus.stringValue = T(@"Downloading ARRL's LoTW user list...");
    [self summarize];
    if (self.onLotwUsersUpdate) self.onLotwUsersUpdate();
}

- (void)setLotwUsersStatus:(NSString *)text ok:(BOOL)ok {
    _lotwBusy = NO;
    _lotwUpdate.enabled = YES;
    _lotwStatus.stringValue = T(text);
    _lotwStatus.textColor = ok ? theme::faint() : theme::error();
    [self summarize];
}

- (NSStackView *)potaSection {
    NSView *help = explained(@"Puts POTA parks on the Map: the ones you've activated or hunted, and the ones you haven't worked yet.",
                             @"Credits: Parks on the Air (pota.app), the park list: about 9.5 MB, every park's name and place.\n"
                             @"Downloaded when you press Download, into the plugin's settings folder on this Mac. ADIF Lint isn't affiliated "
                             @"with Parks on the Air, a registered service mark.");
    _potaUpdate = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(potaUpdate:)];
    _potaStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    // Park Outlines has a card of its own, below the POTA parks card.
    NSView *outlinesHelp = explained(
        @"Draws each park as its outline on the Map, one POTA location at a time (US-IL, DE-HE, VK-NSW).",
        @"Downloaded when you press Download: OpenStreetMap's areas tagged with the park's reference (through Overpass, \u00A9 OpenStreetMap "
        @"contributors, ODbL); pota-map.info's for Austria, Czechia, Denmark, Germany, Luxembourg and Switzerland (DK5UR's compilation of "
        @"government park data); and USGS's PAD-US for US parks (public domain), matched by name and by POTA's place (drawn dashed, and "
        @"said so). A state can take a minute; Overpass is sometimes too busy, and then OpenStreetMap's are left for another try.");
    _outlinesLocation = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    _outlinesLocation.completes = YES;
    _outlinesLocation.numberOfVisibleItems = 15;
    _outlinesLocation.placeholderString = T(@"POTA location, such as US-IL");
    _outlinesLocation.identifier = @"settings.outlines.location";
    [_outlinesLocation.widthAnchor constraintEqualToConstant:150].active = YES;  // a location's reference is short
    _outlinesLocation.target = self;
    _outlinesLocation.action = @selector(outlinesLocationChosen:);
    _outlinesDownload = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(outlinesDownload:)];
    _outlinesDownload.identifier = @"settings.outlines.download";
    ADIFWrapRow *outlinesRow = [ADIFWrapRow rowWithViews:@[ _outlinesLocation, _outlinesDownload ]];
    _outlinesStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _outlinesStatus.identifier = @"settings.outlines.status";
    // What is downloaded: a card for each location, and all of them summed up.
    _outlinesCards = [[NSStackView alloc] initWithFrame:NSZeroRect];
    _outlinesCards.orientation = NSUserInterfaceLayoutOrientationVertical;
    _outlinesCards.alignment = NSLayoutAttributeLeading;
    _outlinesCards.spacing = 12;
    _outlinesCards.detachesHiddenViews = YES;
    _outlinesCards.identifier = @"settings.outlines.cards";
    _outlinesNone = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _outlinesNone.identifier = @"settings.outlines.none";
    _outlinesSummary = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _outlinesSummary.identifier = @"settings.outlines.summary";
    _outlinesOn = [self toggleWithAction:@selector(outlinesToggled:)];  // in the card's heading
    _outlinesOn.identifier = @"settings.outlines.switch";
    _outlinesOn.accessibilityLabel = T(@"Show park outlines on the Map");
    _outlinesOn.state = parkoutlines::shown() ? NSControlStateValueOn : NSControlStateValueOff;
    [self fillOutlines];
    _outlinesGroup = sectionGroup(N(@"Park Outlines"), @"mappin.and.ellipse",
                                  @[ outlinesHelp, outlinesRow, _outlinesStatus, _outlinesCards, _outlinesSummary ],
                                  @"settings.outlines", YES, _outlinesOn);
    return sectionGroup(N(@"POTA Parks"), @"leaf", @[ help, _potaUpdate, _potaStatus ], @"settings.pota", YES, nil);
}

// The locations to choose from (the park list's), the one to offer (the last chosen, else your
// grid's nearest park's), and what is downloaded.
- (void)fillOutlines {
    if (!_outlinesLocation) return;
    std::vector<std::string> locations = parkoutlines::locations();
    [_outlinesLocation removeAllItems];
    for (const std::string &l : locations) [_outlinesLocation addItemWithObjectValue:@(l.c_str())];
    if (!_outlinesLocation.stringValue.length) {
        std::string chosen = adifhost::setting("outlinesLocation");
        double lat, lon;
        if (chosen.empty() && adif::gridToLatLon(adifhost::setting("stationGrid"), &lat, &lon)) {
            double best = 1e9;
            for (const adif::PotaPark &p : ADIFPotaParks().parks()) {
                if (!p.active || !p.placed) continue;
                double d = std::hypot(p.lat - lat, (p.lon - lon) * std::cos(lat * M_PI / 180));
                if (d < best) best = d, chosen = p.location.substr(0, p.location.find(','));
            }
        }
        _outlinesLocation.stringValue = @(chosen.c_str());
    }
    bool none = locations.empty();
    _outlinesLocation.enabled = !none && !parkoutlines::busy();
    _outlinesDownload.enabled = !none && !parkoutlines::busy();
    std::vector<parkoutlines::Downloaded> have = parkoutlines::downloaded();
    [self showOutlineCards:have];
    _outlinesSummary.stringValue = @(parkoutlines::summary(have).c_str());
    if (parkoutlines::busy()) return;
    if (none) {
        _outlinesStatus.stringValue = T(@"Download POTA's park list first.");
        _outlinesStatus.textColor = theme::faint();
    } else {
        [self showOutlinesLocation];
    }
}

// What the location chosen has: its parks, and what was downloaded for it, and when.
- (void)showOutlinesLocation {
    std::string location = ADIFStd([[_outlinesLocation.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString]);
    size_t parks = parkoutlines::parksIn(location);
    std::string text;
    if (location.empty() || !parks) {
        text = location.empty() ? "" : adif::i18n::trf("{location}: no parks there in POTA's list.", {{"location", location}});
    } else {
        text = adif::i18n::trp("{location}: {n} park; not downloaded.", "{location}: {n} parks; not downloaded.", (long long)parks,
                               {{"location", location}});
        for (const parkoutlines::Downloaded &d : parkoutlines::downloaded())
            if (d.location == location)
                text = adif::i18n::trp("{location}: {have} of {n} park has an outline ({from}), downloaded {date}. Download again to update.",
                                       "{location}: {have} of {n} parks have an outline ({from}), downloaded {date}. Download again to update.",
                                       (long long)d.parks,
                                       {{"location", location}, {"have", std::to_string(d.outlines)}, {"from", parkoutlines::sources(d)}, {"date", d.date}});
    }
    _outlinesStatus.stringValue = @(text.c_str());
    _outlinesStatus.textColor = theme::faint();
}

- (void)outlinesLocationChosen:(id)sender {
    if (!parkoutlines::busy()) [self showOutlinesLocation];
}

- (void)outlinesDownload:(id)sender {
    std::string location = ADIFStd([[_outlinesLocation.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString]);
    adifhost::setSetting("outlinesLocation", location);
    _outlinesLocation.stringValue = @(location.c_str());  // as POTA writes it
    _outlinesDownload.enabled = NO, _outlinesLocation.enabled = NO;
    _outlinesBusy = location.empty() ? nil : @(location.c_str());
    __weak ADIFSettingsPanel *weakSelf = self;
    parkoutlines::download(
        location,
        ^(NSString *what) {
            ADIFSettingsPanel *me = weakSelf;
            if (!me) return;
            me->_outlinesStatus.stringValue = what;
            me->_outlinesStatus.textColor = theme::faint();
        },
        ^(BOOL ok, NSString *message) {
            ADIFSettingsPanel *me = weakSelf;
            if (!me) return;
            me->_outlinesBusy = nil;
            [me fillOutlines];
            me->_outlinesStatus.stringValue = message;
            me->_outlinesStatus.textColor = ok ? theme::faint() : theme::error();
        });
    [self fillOutlines];  // the card of this location now says Downloading (its Download is off until the result)
}

// A card for each location downloaded (or a line saying there are none). Each card is greyed out while the Map doesn't
// draw park outlines, and its Remove is off while a download runs.
- (void)showOutlineCards:(const std::vector<parkoutlines::Downloaded> &)have {
    for (NSView *old in [_outlinesCards.arrangedSubviews copy]) {
        [_outlinesCards removeArrangedSubview:old];
        [old removeFromSuperview];
    }
    if (have.empty()) {
        _outlinesNone.stringValue = T(@"No park outlines downloaded yet. Choose a POTA location and press Download.");
        [_outlinesCards addArrangedSubview:_outlinesNone];
        return;
    }
    BOOL shown = parkoutlines::shown(), idle = !parkoutlines::busy();
    for (const parkoutlines::Downloaded &d : have) {
        NSString *location = @(d.location.c_str());
        BOOL busy = [_outlinesBusy isEqualToString:location];
        NSString *size = [NSByteCountFormatter stringFromByteCount:d.bytes countStyle:NSByteCountFormatterCountStyleFile];
        std::string summary = adif::i18n::trp("{have} of {n} park has an outline ({from}).", "{have} of {n} parks have an outline ({from}).",
                                              (long long)d.parks, {{"have", std::to_string(d.outlines)}, {"from", parkoutlines::sources(d)}});
        NSString *footnote = TF(@"{size}, downloaded {date}", @{@"size" : size, @"date" : @(d.date.c_str())});
        NSString *details = [NSString stringWithFormat:@"Sources: %s.\nOpenStreetMap contributors (ODbL), pota-map.info (DK5UR) and USGS PAD-US "
                                                       @"(public domain). Their licences are in data/SOURCE.md.", parkoutlines::sources(d).c_str()];
        ADIFAreaButton *remove = [ADIFAreaButton buttonWithTitle:T(@"Remove") target:self action:@selector(outlinesRemove:)];
        remove.area = location;
        remove.identifier = @"settings.outlines.remove";
        remove.enabled = idle;
        ADIFSettingsCard *card = areaCard(location, busy ? T(@"Downloading") : T(@"Installed"), !busy, @(summary.c_str()), details, footnote, nil, remove);
        card.identifier = @"settings.outlines.card";
        card.alphaValue = shown ? 1 : 0.4;
        [_outlinesCards addArrangedSubview:card];
        [card.widthAnchor constraintEqualToAnchor:_outlinesCards.widthAnchor].active = YES;
    }
}

- (void)outlinesRemove:(ADIFAreaButton *)sender {
    parkoutlines::remove(ADIFStd(sender.area));
    [self fillOutlines];
}

- (void)outlinesToggled:(id)sender {
    parkoutlines::setShown(_outlinesOn.state == NSControlStateValueOn);
    [self fillOutlines];
    [self summarize];
}

- (void)potaUpdate:(id)sender {
    _potaBusy = YES;
    _potaUpdate.enabled = NO;
    _potaStatus.stringValue = T(@"Downloading POTA's park list...");
    _potaStatus.textColor = theme::faint();
    [self summarize];
    if (self.onPotaUpdate) self.onPotaUpdate();
}

- (void)setPotaStatus:(NSString *)text ok:(BOOL)ok {
    _potaBusy = NO;
    [self fillOutlines];  // the list's locations (it may have just been downloaded)
    _potaUpdate.enabled = YES;
    _potaStatus.stringValue = T(text);
    _potaStatus.textColor = ok ? theme::faint() : theme::error();
    [self summarize];
}

- (NSStackView *)iotaSection {
    NSView *help = explained(@"Draws IOTA's island groups on the Map, with the groups in your log filled in.",
                             @"Credits: \u00A9 RSGB and IOTA Ltd. IOTA is a registered trade mark of the RSGB.\n"
                             @"Not included with ADIF Lint: downloaded from iota-world.org (about 290 KB) for your own personal, "
                             @"non-commercial use, into the plugin's settings folder on this Mac.");
    _iotaUpdate = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(iotaUpdate:)];
    _iotaStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    return sectionGroup(N(@"IOTA Groups"), @"drop", @[ help, _iotaUpdate, _iotaStatus ], @"settings.iota", YES, nil);
}

- (void)iotaUpdate:(id)sender {
    _iotaBusy = YES;
    _iotaUpdate.enabled = NO;
    _iotaStatus.stringValue = T(@"Downloading IOTA's group list...");
    _iotaStatus.textColor = theme::faint();
    [self summarize];
    if (self.onIotaUpdate) self.onIotaUpdate();
}

- (void)setIotaStatus:(NSString *)text ok:(BOOL)ok {
    _iotaBusy = NO;
    _iotaUpdate.enabled = YES;
    _iotaStatus.stringValue = T(text);
    _iotaStatus.textColor = ok ? theme::faint() : theme::error();
    [self summarize];
}

- (void)countryUpdate:(id)sender {
    _countryBusy = YES;
    _countryUpdate.enabled = NO;
    _countryStatus.stringValue = T(@"Downloading the newest country file...");
    _countryStatus.textColor = theme::faint();
    [self summarize];
    if (self.onCountryUpdate) self.onCountryUpdate();
}

- (void)setCountryStatus:(NSString *)text ok:(BOOL)ok {
    _countryBusy = NO;
    _countryUpdate.enabled = YES;
    _countryStatus.stringValue = T(text);
    _countryStatus.textColor = ok ? theme::faint() : theme::error();
    [self summarize];
}

// What an account is for, in a line; its instructions are behind the ? beside it.
static NSString *accountPurpose(ADIFSource source) {
    switch (source) {
        case ADIFSourceQRZ: return N(@"Looks up callsigns for New QSO and Enrich: name, address and grid.");
        case ADIFSourceHamQTH: return N(@"Looks up callsigns for New QSO and Enrich, and uploads your log to HamQTH.");
        case ADIFSourceQRZLogbook: return N(@"Uploads your QSOs to your QRZ.com Logbook and imports from it.");
        case ADIFSourceClubLog: return N(@"Uploads your log to Club Log.");
        case ADIFSourceClubLogKey: return N(@"Lets ADIF Lint upload to Club Log as this program.");
        case ADIFSourceEQSL: return N(@"Uploads your QSOs to eQSL and checks its InBox for confirmations.");
        case ADIFSourceTqsl: return N(@"Gives your TQSL certificate's password to TQSL when you upload to LoTW.");
        case ADIFSourceWRL: return N(@"Uploads your QSOs to World Radio League.");
        case ADIFSourceHRDLog: return N(@"Uploads your QSOs to HRDLog.net.");
        case ADIFSourceLoTW: return N(@"Imports your confirmed QSOs from LoTW.");
        default: return @"";
    }
}

// A placeholder for each service's logo until its official graphic is added.
static NSString *accountSymbol(ADIFSource source) {
    switch (source) {
        case ADIFSourceQRZ: return @"person.crop.rectangle";
        case ADIFSourceHamQTH: return @"antenna.radiowaves.left.and.right";
        case ADIFSourceQRZLogbook: return @"book.closed";
        case ADIFSourceClubLog: return @"list.bullet.rectangle";
        case ADIFSourceClubLogKey: return @"key";
        case ADIFSourceEQSL: return @"envelope";
        case ADIFSourceTqsl: return @"checkmark.seal";
        case ADIFSourceWRL: return @"globe";
        case ADIFSourceHRDLog: return @"doc.text";
        case ADIFSourceLoTW: return @"checkmark.circle";
        default: return @"key";
    }
}

static NSString *accountKey(ADIFSource source, NSString *label) {
    return label.length ? [NSString stringWithFormat:@"%ld:%@", (long)source, label] : [NSString stringWithFormat:@"%ld", (long)source];
}

static NSString *accountIdentifier(ADIFSource source, NSString *label) {
    return label.length ? [NSString stringWithFormat:@"settings.source.%ld.%@", (long)source, label]
                        : [NSString stringWithFormat:@"settings.source.%ld", (long)source];
}

// A log's callsign: letters, figures, slashes and hyphens, up to 16 characters.
static BOOL validAccountLabel(NSString *label) {
    if (label.length < 1 || label.length > 16) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-"];
    return [label rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

// The Accounts section: a card for each account set up, and Add beside its heading to set one up.
- (NSStackView *)accountsSection {
    _accountList = [[NSStackView alloc] initWithFrame:NSZeroRect];
    _accountList.orientation = NSUserInterfaceLayoutOrientationVertical;
    _accountList.alignment = NSLayoutAttributeLeading;
    _accountList.spacing = 10;
    _accountList.detachesHiddenViews = YES;
    _accountList.identifier = @"settings.accounts.list";
    _accountEmpty = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _accountEmpty.identifier = @"settings.accounts.none";
    _addAccount = [NSButton buttonWithTitle:T(@"Add...") target:self action:@selector(showAddAccount:)];
    _addAccount.identifier = @"settings.accounts.add";
    NSView *help = explained(@"Each account signs ADIF Lint in to an online service. Look up uses the account marked as the default.",
                             @"Expand an account to change its credentials. Switch an account off to keep its credentials without using it. "
                             @"Drag its handle, or use its menu, to set the order.");
    return sectionGroup(N(@"Configured Accounts"), @"key", @[ help, _accountEmpty, _accountList ], @"settings.accounts", NO, _addAccount);
}

// The integrations to set up: those not set up yet, and those whose logs can each have an account of their own.
- (void)showAddAccount:(NSButton *)sender {
    NSStackView *rows = [[NSStackView alloc] initWithFrame:NSZeroRect];
    rows.orientation = NSUserInterfaceLayoutOrientationVertical;
    rows.alignment = NSLayoutAttributeLeading;
    rows.spacing = 2;
    rows.edgeInsets = NSEdgeInsetsMake(10, 10, 10, 10);
    rows.detachesHiddenViews = YES;
    for (NSInteger s = 0; s < ADIFSourceCount; ++s) {
        ADIFSource source = (ADIFSource)s;
        if (ADIFHasSavedSecret(source) && !ADIFAllowsManyAccounts(source)) continue;
        if (_pendingAccount && _pendingAccount.source == source) continue;
        NSButton *row = [NSButton buttonWithTitle:ADIFSourceName(source) target:self action:@selector(pickAccount:)];
        row.image = settingsGlyph(accountSymbol(source), theme::faint(), 14);
        row.imagePosition = NSImageLeading;
        row.bordered = NO;
        row.alignment = NSTextAlignmentLeft;
        row.tag = s;
        row.toolTip = T(accountPurpose(source));
        row.identifier = [NSString stringWithFormat:@"accounts.add.%ld", (long)s];
        [rows addArrangedSubview:row];
    }
    if (!rows.arrangedSubviews.count) {
        NSTextField *none = wrapping(@"Every integration is set up.", NSFont.smallSystemFontSize, theme::faint());
        [rows addArrangedSubview:none];
    }
    NSViewController *controller = [[NSViewController alloc] init];
    controller.view = rows;
    _addPopover = [[NSPopover alloc] init];
    _addPopover.behavior = NSPopoverBehaviorTransient;
    _addPopover.contentViewController = controller;
    _addPopover.contentSize = rows.fittingSize;
    [_addPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMinY];
}

- (void)pickAccount:(NSButton *)sender {
    [_addPopover close];
    [self startNewAccount:(ADIFSource)sender.tag];
}

// An account being set up: a card at the top of the list, expanded, that is saved only once its sign-in works.
- (void)startNewAccount:(ADIFSource)source {
    [_pendingAccount removeFromSuperview];
    _pendingAccount = [[ADIFAccountCard alloc] initWithSource:source label:@"" isNew:YES owner:self];
    _pendingAccount.identifier = [NSString stringWithFormat:@"settings.source.%ld.new", (long)source];
    [self rebuildAccounts];
    [self openGroup:@"settings.accounts"];
    [_pendingAccount focusFirstField];
}

// The cards, in the order the accounts are kept; a card is made for an account the first time it is listed.
- (void)rebuildAccounts {
    if (!_accountList) return;
    NSMutableArray<ADIFAccountCard *> *wanted = [NSMutableArray array];
    if (_pendingAccount) [wanted addObject:_pendingAccount];
    NSMutableSet<NSString *> *listed = [NSMutableSet set];
    for (const ADIFAccountRef &a : ADIFAccounts()) {
        NSString *label = a.label.empty() ? @"" : @(a.label.c_str());
        NSString *key = accountKey(a.source, label);
        ADIFAccountCard *card = _accountCards[key];
        if (!card) {
            card = [[ADIFAccountCard alloc] initWithSource:a.source label:label isNew:NO owner:self];
            card.identifier = accountIdentifier(a.source, label);
            _accountCards[key] = card;
        }
        [card refreshFromStore];
        [listed addObject:key];
        [wanted addObject:card];
    }
    for (NSString *key in [_accountCards.allKeys copy])
        if (![listed containsObject:key]) {
            ADIFAccountCard *gone = _accountCards[key];
            [_accountCards removeObjectForKey:key];
            [gone removeFromSuperview];
        }
    for (NSView *v in [_accountList.arrangedSubviews copy]) [_accountList removeArrangedSubview:v];
    for (ADIFAccountCard *card in wanted) {
        if (card.superview != _accountList) {
            [_accountList addSubview:card];
            [card.widthAnchor constraintEqualToAnchor:_accountList.widthAnchor].active = YES;
        }
        [_accountList addArrangedSubview:card];
    }
    _accountEmpty.stringValue = wanted.count ? @"" : T(@"No accounts are set up. Choose Add to set one up.");
    _accountEmpty.hidden = wanted.count > 0;
}

// Where a card is dragged to: the list's cards above the pointer come before it. The account being set up stays on top.
- (void)accountCard:(ADIFAccountCard *)card draggedTo:(NSPoint)point {
    [_accountList layoutSubtreeIfNeeded];  // the cards' frames as they are now, so the drop point is read from them
    NSArray<NSView *> *views = _accountList.arrangedSubviews;
    if ([views indexOfObject:card] == NSNotFound) return;
    NSInteger above = 0;
    for (NSView *v in views) {
        if (v == card || ![v isKindOfClass:ADIFAccountCard.class] || ((ADIFAccountCard *)v).isNew) continue;
        CGFloat mid = NSMidY([_accountList convertRect:v.bounds fromView:v]);
        if (_accountList.isFlipped ? mid < point.y : mid > point.y) ++above;
    }
    [self moveAccountCard:card toIndex:(_pendingAccount ? 1 : 0) + above];
}

- (void)accountCard:(ADIFAccountCard *)card movedBy:(NSInteger)steps {
    NSArray<NSView *> *views = _accountList.arrangedSubviews;
    NSInteger from = [views indexOfObject:card];
    if (from == NSNotFound || card.isNew) return;
    NSInteger lowest = _pendingAccount ? 1 : 0;
    NSInteger to = MAX(lowest, MIN((NSInteger)views.count - 1, from + steps));
    [self moveAccountCard:card toIndex:to];
    [self accountCardDropped:card];
}

- (void)moveAccountCard:(ADIFAccountCard *)card toIndex:(NSInteger)to {
    NSInteger from = [_accountList.arrangedSubviews indexOfObject:card];
    if (from == NSNotFound || from == to) return;
    [_accountList removeArrangedSubview:card];
    NSInteger last = (NSInteger)_accountList.arrangedSubviews.count;
    [_accountList insertArrangedSubview:card atIndex:MIN(MAX(to, 0), last)];
}

// The list's order is kept: the accounts on screen first, in order, then any that are not.
- (void)accountCardDropped:(ADIFAccountCard *)card {
    std::vector<ADIFAccountRef> order;
    for (NSView *v in _accountList.arrangedSubviews) {
        if (![v isKindOfClass:ADIFAccountCard.class] || ((ADIFAccountCard *)v).isNew) continue;
        ADIFAccountCard *c = (ADIFAccountCard *)v;
        order.push_back({c.source, std::string(c.label.UTF8String ?: "")});
    }
    for (const ADIFAccountRef &a : ADIFAccounts()) {
        BOOL present = NO;
        for (const ADIFAccountRef &o : order) present |= o.source == a.source && o.label == a.label;
        if (!present) order.push_back(a);
    }
    ADIFSetAccountOrder(order);
    if (self.onAccountsChanged) self.onAccountsChanged(NO);
}

// Save: a new account's sign-in must have worked (unless the service has no test); an existing one's fields are kept as
// they are when left blank, the saved password included.
- (void)accountCardSave:(ADIFAccountCard *)card {
    ADIFSource source = card.source;
    BOOL apiKey = ADIFSourceCredentialKind(source) == ADIFCredentialAPIKey;
    if (card.isNew && ADIFSourceCanTest(source) && card.state != ADIFAccountSignedIn && card.state != ADIFAccountSaveFailed) return;  // Save waits for a sign-in
    NSString *label = card.isNew ? card.typedLabel : card.label;
    NSString *user = card.typedUser, *secret = card.typedSecret;
    NSString *storeLabel = label.length ? label : nil;
    NSString *error = nil;
    if (card.isNew && ADIFAllowsManyAccounts(source) && ADIFHasSavedSecret(source) && !label.length)
        error = T(@"Enter the callsign of the log this key is for.");
    else if (label.length && !validAccountLabel(label))
        error = T(@"A log is named by its callsign, such as KW9D.");
    else if (card.isNew && label.length && ADIFHasSavedSecret(source, label))
        error = T(@"That log already has an account.");
    else if (!card.isNew) {
        if (!user.length && !apiKey) user = ADIFSavedAccount(source, storeLabel) ?: @"";
        if (!secret.length) secret = ADIFSavedSecret(source, storeLabel) ?: @"";
    }
    if (!error && !secret.length) error = T(@"Enter both fields.");
    if (!error && !apiKey && !user.length) error = T(@"Enter both fields.");
    if (error) {
        card.state = ADIFAccountSaveFailed;
        card.note = error;
        [card refreshFromStore];
        return;
    }
    NSString *saveError = nil;
    if (!ADIFSaveCredential(source, user, secret, &saveError, storeLabel)) {
        card.state = ADIFAccountSaveFailed;
        card.note = saveError ?: T(@"Could not save.");
        [card refreshFromStore];
        return;
    }
    if (card.isNew) {
        ADIFSetSourceOn(source, YES, storeLabel);
        std::vector<ADIFAccountRef> order = ADIFAccounts();
        BOOL listed = NO;
        for (const ADIFAccountRef &a : order) listed |= a.source == source && a.label == std::string(label.UTF8String ?: "");
        if (!listed) order.push_back({source, std::string(label.UTF8String ?: "")});
        ADIFSetAccountOrder(order);
        [_pendingAccount removeFromSuperview];
        _pendingAccount = nil;
    } else {
        card.state = ADIFAccountSaved;
        card.note = @"";
        [card reloadFields];  // the password typed is not kept in the window
    }
    [self rebuildAccounts];
    [self summarize];
    if (self.onChanged) self.onChanged(source);
    if (self.onAccountsChanged) self.onAccountsChanged(NO);
}

// Test Sign-In: the typed username and password stand in for the saved ones, which are not changed by a test.
- (void)accountCardTest:(ADIFAccountCard *)card {
    ADIFSource source = card.source;
    NSString *label = card.isNew ? card.typedLabel : card.label;
    NSString *storeLabel = label.length ? label : nil;
    NSString *user = card.typedUser, *secret = card.typedSecret;
    if (!card.isNew) {
        if (!user.length) user = ADIFSavedAccount(source, storeLabel) ?: @"";
        if (!secret.length) secret = ADIFSavedSecret(source, storeLabel) ?: @"";
    }
    card.state = ADIFAccountTesting;
    card.note = @"";
    [card refreshFromStore];
    __weak ADIFAccountCard *weakCard = card;
    __weak ADIFSettingsPanel *weakSelf = self;
    ADIFTestCredential(source, storeLabel, user, secret, ^(BOOL ok, NSString *message) {
        ADIFAccountCard *c = weakCard;
        ADIFSettingsPanel *panel = weakSelf;
        if (!c || !panel) return;
        c.state = ok ? ADIFAccountSignedIn : ADIFAccountSignInFailed;
        c.note = message ?: @"";
        [c refreshFromStore];
        [panel summarize];
    });
}

// Remove: the account's credential is deleted, and the account leaves the list (and the default with it).
- (void)accountCardRemove:(ADIFAccountCard *)card {
    ADIFSource source = card.source;
    NSString *storeLabel = card.label.length ? card.label : nil;
    ADIFDeleteCredential(source, storeLabel);
    BOOL defaultChanged = !storeLabel && ADIFLookupDefault() == (int)source;
    if (defaultChanged) ADIFSetLookupDefault(-1);
    std::vector<ADIFAccountRef> order;
    for (const ADIFAccountRef &a : ADIFAccounts())
        if (!(a.source == source && a.label == std::string(storeLabel.UTF8String ?: ""))) order.push_back(a);
    ADIFSetAccountOrder(order);
    [self rebuildAccounts];
    [self summarize];
    if (self.onChanged) self.onChanged(source);
    if (self.onAccountsChanged) self.onAccountsChanged(defaultChanged);
}

- (void)accountCardCancel:(ADIFAccountCard *)card {
    if (card != _pendingAccount) return;
    [_pendingAccount removeFromSuperview];
    _pendingAccount = nil;
    [self rebuildAccounts];
}

- (void)accountCardToggled:(ADIFAccountCard *)card on:(BOOL)on {
    ADIFSetSourceOn(card.source, on, card.label.length ? card.label : nil);
    [card refreshFromStore];
    [self summarize];
    if (self.onChanged) self.onChanged(card.source);
    if (self.onAccountsChanged) self.onAccountsChanged(NO);
}

- (void)accountCardMakeDefault:(ADIFAccountCard *)card {
    ADIFSetLookupDefault((int)card.source);
    [self rebuildAccounts];
    [self summarize];
    if (self.onAccountsChanged) self.onAccountsChanged(YES);
}

- (NSStackView *)accountListStack {
    return _accountList;
}

- (NSStackView *)spotsSection {
    NSTextField *help = wrapping(@"Where the Map's Spots layer gets its spots. Nothing is fetched until you tick Show under Spots on the Map, and "
                                 @"only while the Map is open; nothing at all in Offline Mode. New QSO's Spot when logging boxes post "
                                 @"the stations you log on the DX cluster connected here.",
                                 NSFont.smallSystemFontSize, theme::faint());
    _spotsSpothole = [self providerSwitch];
    _spotsCluster = [self providerSwitch];
    _spotsNode = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    _spotsNode.placeholderString = T(@"host:port");
    NSMutableArray *tips = [NSMutableArray array];
    for (size_t i = 0; i < spotfeeds::kNodeCount; ++i) {
        NSString *node = [NSString stringWithFormat:@"%s:%d", spotfeeds::kNodes[i].host, spotfeeds::kNodes[i].port];
        [_spotsNode addItemWithObjectValue:node];
        [tips addObject:[NSString stringWithFormat:@"%@: %@", node, T(@(spotfeeds::kNodes[i].note))]];
    }
    _spotsNode.toolTip = [tips componentsJoinedByString:@"\n"];
    _spotsLogin = [NSTextField textFieldWithString:@""];
    _spotsLogin.placeholderString = T(@"your callsign (Your Station)");
    _spotsCommands = [NSTextField textFieldWithString:@""];
    _spotsCommands.placeholderString = T(@"optional, e.g. set/skimmer");
    _spotsCommands.toolTip = T(@"Commands to send after logging in, \";\" between them; they're the node's own (see its help)");
    _spotsPsk = [self providerSwitch];
    _spotsPskQuery = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_spotsPskQuery addItemsWithTitles:@[ T(@"My callsign"), T(@"Around my grid square"), T(@"My ARRL section's region"), T(@"My state") ]];
    _spotsPskQuery.target = self, _spotsPskQuery.action = @selector(spotsChanged:);
    _spotsPskQuery.toolTip = T(@"My callsign: the stations that heard you, and the ones your station heard if your program uploads what it hears "
                               @"(WSJT-X: Enable PSK Reporter Spotting). Around my grid square: what stations in your 4-character square heard, "
                               @"and who heard them, so there is something to see when you aren't on the air. My ARRL section's region and My state: "
                               @"reports with a station in that state, or in the states of the section's ARRL division (PSKReporter can't be asked by "
                               @"state, so the live feed is asked for the squares over it and the reports are kept to it)");
    _spotsPskQuery.identifier = @"settings.spots.pskQuery";
    _spotsPskCall = [NSTextField textFieldWithString:@""];
    _spotsPskCall.placeholderString = T(@"your callsign (Your Station)");
    _spotsPskCall.toolTip = T(@"The callsign whose reception reports PSKReporter gives: your own (Your Station) when empty, or another one: a "
                              @"club station, a portable call, or a friend's");
    _spotsPskCall.identifier = @"settings.spots.pskCall";
    _spotsPskArea = [NSTextField textFieldWithString:@""];
    _spotsPskArea.placeholderString = T(@"from your grid square");
    _spotsPskArea.toolTip = T(@"The state (WI) or ARRL section (WI, EMA, STX) for My state and My ARRL section's region; empty is where Your Station's "
                              @"grid square is");
    _spotsPskArea.identifier = @"settings.spots.pskArea";
    _spotsEmail = [NSTextField textFieldWithString:@""];
    _spotsEmail.placeholderString = T(@"optional");
    _spotsEmail.toolTip = T(@"PSKReporter asks the programs that query it for a contact email address (appcontact), in case of a problem. "
                            @"Leave it empty to send none.");
    NSButton *save = [NSButton buttonWithTitle:T(@"Save") target:self action:@selector(spotsChanged:)];
    _spotsStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _spotsSpothole.identifier = @"settings.spots.spothole", _spotsCluster.identifier = @"settings.spots.cluster";
    _spotsPsk.identifier = @"settings.spots.psk", _spotsNode.identifier = @"settings.spots.node";
    _spotsLogin.identifier = @"settings.spots.login", _spotsCommands.identifier = @"settings.spots.commands";
    _spotsEmail.identifier = @"settings.spots.email", save.identifier = @"settings.spots.save";
    if (!_spotsObserver)
        _spotsObserver = [[NSNotificationCenter defaultCenter] addObserverForName:ADIFSpotsChangedNotification
                                                                           object:nil
                                                                            queue:nil
                                                                       usingBlock:^(NSNotification *) { [self fillSpotsStatus]; }];
    // Each provider's row holds its switch and its Configure button; its settings open on a page of their own.
    NSView *spotholeRow = [self providerRowNamed:N(@"SpotHole") detail:N(@"POTA, WWFF, GMA, DX clusters and RBN")
                                          symbol:@"antenna.radiowaves.left.and.right" toggle:_spotsSpothole key:@"spothole"];
    NSView *clusterRow = [self providerRowNamed:N(@"DX Cluster") detail:N(@"Telnet DX cluster connection") symbol:@"network" toggle:_spotsCluster
                                            key:@"cluster"];
    NSView *pskRow = [self providerRowNamed:N(@"PSKReporter") detail:N(@"Digital-mode reception reports") symbol:@"waveform.path.ecg"
                                     toggle:_spotsPsk key:@"psk"];
    _spotsListPage = [NSStackView stackViewWithViews:@[ help, spotholeRow, clusterRow, pskRow ]];
    _spotsListPage.orientation = NSUserInterfaceLayoutOrientationVertical;
    _spotsListPage.alignment = NSLayoutAttributeLeading;
    _spotsListPage.spacing = 10;
    _spotsListPage.detachesHiddenViews = YES;
    _spotsListPage.identifier = @"settings.spots.list";
    for (NSView *row in _spotsListPage.arrangedSubviews) [row.widthAnchor constraintEqualToAnchor:_spotsListPage.widthAnchor].active = YES;
    _spotsPages = [NSMutableDictionary dictionary];
    _spotsPages[@"spothole"] = [self providerPageKey:@"spothole" title:N(@"SpotHole")
                                                note:N(@"Spothole: POTA, WWFF, GMA and other programs, and the DX clusters and RBN it reads "
                                                       @"(spothole.app, every 2 minutes; SOTA left out)")
                                               views:@[]];
    _spotsPages[@"cluster"] = [self providerPageKey:@"cluster" title:N(@"DX Cluster") note:N(@"A DX cluster (telnet), logged in with your callsign")
                                              views:@[ field(colon(T(@"Node")), _spotsNode), field(colon(T(@"Login")), _spotsLogin),
                                                       field(colon(T(@"Then send")), _spotsCommands) ]];
    _spotsPages[@"psk"] = [self providerPageKey:@"psk" title:N(@"PSKReporter")
                                           note:N(@"PSKReporter: the digital-mode reception reports of your callsign, grid square, ARRL section or state (every 5 minutes)")
                                          views:@[ field(colon(T(@"Reports")), _spotsPskQuery), field(T(@"Callsign:"), _spotsPskCall),
                                                   field(colon(T(@"State or section")), _spotsPskArea), field(colon(T(@"Your email")), _spotsEmail),
                                                   save, _spotsStatus ]];
    _spotsView = sectionStack(N(@"Spot Sources"), @"antenna.radiowaves.left.and.right",
                              @[ _spotsListPage, _spotsPages[@"spothole"], _spotsPages[@"cluster"], _spotsPages[@"psk"] ], @"settings.spots");
    [self fillSpots];
    return _spotsView;
}

// A switch that turns a spot provider on or off: its row (providerRowNamed:) holds it, and spotsChanged: saves it.
- (NSSwitch *)providerSwitch {
    return [self toggleWithAction:@selector(spotsChanged:)];
}

// A medium switch, as the cards' toggles and the spot providers' use: its action is called when it changes.
- (NSSwitch *)toggleWithAction:(SEL)action {
    NSSwitch *toggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    toggle.controlSize = NSControlSizeSmall;  // a medium toggle, not the large one
    toggle.target = self;
    toggle.action = action;
    return toggle;
}

// A spot provider's row: its symbol, name and a line about it, its switch, and Configure, which opens its settings.
- (NSView *)providerRowNamed:(NSString *)name detail:(NSString *)detail symbol:(NSString *)symbol toggle:(NSSwitch *)toggle key:(NSString *)key {
    ADIFSettingsCard *card = [[ADIFSettingsCard alloc] initWithFrame:NSZeroRect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    NSImageView *icon = [NSImageView imageViewWithImage:settingsGlyph(symbol, NSColor.labelColor, 20)];
    NSTextField *title = [NSTextField labelWithString:T(name)];
    title.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
    NSTextField *line = wrapping(detail, NSFont.smallSystemFontSize, theme::faint());
    NSStackView *text = [NSStackView stackViewWithViews:@[ title, line ]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 2;
    toggle.accessibilityLabel = T(name);
    NSView *toggleGap = [NSView new];  // pushes the switch to the card's trailing edge
    [toggleGap setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *top = [NSStackView stackViewWithViews:@[ icon, text, toggleGap, toggle ]];
    top.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    top.alignment = NSLayoutAttributeCenterY;
    top.spacing = 12;
    NSButton *configure = [NSButton buttonWithTitle:T(@"Configure...") target:self action:@selector(spotsConfigure:)];
    configure.identifier = [@"settings.spots.configure." stringByAppendingString:key];
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *bottom = [NSStackView stackViewWithViews:@[ spacer, configure ]];
    bottom.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottom.alignment = NSLayoutAttributeCenterY;
    NSStackView *inner = [NSStackView stackViewWithViews:@[ top, bottom ]];
    inner.orientation = NSUserInterfaceLayoutOrientationVertical;
    inner.alignment = NSLayoutAttributeLeading;
    inner.spacing = 10;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [top.widthAnchor constraintEqualToAnchor:inner.widthAnchor],
        [bottom.widthAnchor constraintEqualToAnchor:inner.widthAnchor],
    ]];
    return card;
}

// One provider's page, opened by its row's Configure: a Back button to the list, its name, a line about it, and its settings.
- (NSStackView *)providerPageKey:(NSString *)key title:(NSString *)title note:(NSString *)note views:(NSArray<NSView *> *)views {
    NSButton *back = [NSButton buttonWithTitle:T(@"Spot Sources") target:self action:@selector(spotsBack:)];
    back.bordered = NO;
    back.image = [NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:nil];
    back.imagePosition = NSImageLeading;
    back.identifier = [@"settings.spots.back." stringByAppendingString:key];
    NSTextField *heading = [NSTextField labelWithString:T(title)];
    heading.font = [NSFont systemFontOfSize:NSFont.systemFontSize + 1 weight:NSFontWeightSemibold];
    NSMutableArray<NSView *> *parts = [NSMutableArray arrayWithObjects:back, heading, nil];
    if (note.length) [parts addObject:wrapping(note, NSFont.systemFontSize, theme::faint())];
    [parts addObjectsFromArray:views];
    NSStackView *page = [NSStackView stackViewWithViews:parts];
    page.orientation = NSUserInterfaceLayoutOrientationVertical;
    page.alignment = NSLayoutAttributeLeading;
    page.spacing = 10;
    page.detachesHiddenViews = YES;
    page.translatesAutoresizingMaskIntoConstraints = NO;
    page.identifier = [@"settings.spots.page." stringByAppendingString:key];
    for (NSView *part in parts)
        if (part != back) [part.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;
    page.hidden = YES;
    return page;
}

// The Spot Sources list (key nil), or one provider's page (spothole, cluster, psk).
- (void)showSpotsPage:(NSString *)key {
    _spotsListPage.hidden = key != nil;
    for (NSString *page in _spotsPages) _spotsPages[page].hidden = ![page isEqualToString:key];
}

- (void)spotsConfigure:(NSButton *)sender {
    NSString *prefix = @"settings.spots.configure.";
    if ([sender.identifier hasPrefix:prefix]) [self showSpotsPage:[sender.identifier substringFromIndex:prefix.length]];
}

- (void)spotsBack:(NSButton *)sender {
    [self showSpotsPage:nil];
}

- (void)fillSpots {
    spotfeeds::Config c = spotfeeds::config();
    _spotsSpothole.state = c.spothole ? NSControlStateValueOn : NSControlStateValueOff;
    _spotsCluster.state = c.cluster ? NSControlStateValueOn : NSControlStateValueOff;
    _spotsPsk.state = c.psk ? NSControlStateValueOn : NSControlStateValueOff;
    [_spotsPskQuery selectItemAtIndex:c.pskQuery];
    _spotsPskCall.stringValue = @(c.pskCall.c_str());
    _spotsPskArea.stringValue = @(c.pskArea.c_str());
    _spotsNode.stringValue = c.host.empty() ? @"" : [NSString stringWithFormat:@"%s:%d", c.host.c_str(), c.port];
    _spotsLogin.stringValue = @(c.login.c_str());
    _spotsCommands.stringValue = @(c.commands.c_str());
    _spotsEmail.stringValue = @(c.email.c_str());
    [self fillSpotsStatus];
    [self summarize];
}

- (void)fillSpotsStatus {
    std::string st = spotfeeds::status();
    _spotsStatus.stringValue = st.empty() ? T(@"Tick Show under Spots on the Map to fetch them.") : @(st.c_str());
}

- (void)spotsChanged:(id)sender {
    spotfeeds::Config c;
    c.spothole = _spotsSpothole.state == NSControlStateValueOn;
    c.cluster = _spotsCluster.state == NSControlStateValueOn;
    c.psk = _spotsPsk.state == NSControlStateValueOn;
    c.pskQuery = (int)std::max<NSInteger>(0, _spotsPskQuery.indexOfSelectedItem);
    // "host:port", or a host alone (DXSpider nodes listen on 7300; telnet's own port is 23).
    std::string node = ADIFStd([_spotsNode.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
    size_t colonAt = node.rfind(':');
    if (colonAt != std::string::npos && colonAt + 1 < node.size() && node.find_first_not_of("0123456789", colonAt + 1) == std::string::npos)
        c.host = node.substr(0, colonAt), c.port = std::atoi(node.c_str() + colonAt + 1);
    else
        c.host = node, c.port = node.empty() ? 0 : 23;
    auto trimmed = ^(NSTextField *f) { return ADIFStd([f.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]); };
    c.login = trimmed(_spotsLogin);
    c.commands = trimmed(_spotsCommands);
    c.email = trimmed(_spotsEmail);
    c.pskCall = ADIFStd([[_spotsPskCall.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString]);
    c.pskArea = ADIFStd([[_spotsPskArea.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString]);
    spotfeeds::setConfig(c);
    [self fillSpots];
}

// A group's status pill: green when what it covers is set up or on.
- (void)markGroup:(NSString *)ident positive:(BOOL)positive {
    ADIFStatusPill *pill = (ADIFStatusPill *)self->_groupSummaries[ident];
    if ([pill isKindOfClass:ADIFStatusPill.class]) pill.positive = positive;
}

// A group's main button goes in its heading, beside its status pill, as a row's action does in System Settings.
- (void)putInHeader:(NSButton *)button ofGroup:(NSString *)ident {
    NSStackView *body = _groupBodies[ident];
    NSView *holder = button.superview;  // the row sectionStack put it in, if it is a push button's
    if ([holder isKindOfClass:ADIFWrapRow.class] && holder.superview == body) [holder removeFromSuperview];
    [button removeFromSuperview];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [_groupHeaders[ident] addView:button inGravity:NSStackViewGravityTrailing];
}

// What each group's heading says is set in it, at a glance.
- (void)summarize {
    if (!_groups) return;
    auto say = ^(NSString *ident, NSString *text) {
        NSTextField *summary = self->_groupSummaries[ident];
        summary.stringValue = text ?: @"";
        summary.hidden = summary.stringValue.length == 0;
    };
    NSMutableArray *station = [NSMutableArray array];
    for (NSTextField *f in @[ _stationCall, _stationGrid ])
        if (f.stringValue.length) [station addObject:f.stringValue.uppercaseString];
    NSString *stationText = station.count ? [station componentsJoinedByString:@" \u00B7 "] : T(@"not set");
    say(@"settings.station", stationText);
    [self markGroup:@"settings.station" positive:station.count > 0];
    ADIFSettingsNavButton *stationNav = (ADIFSettingsNavButton *)_categoryButtons[@"station"];
    stationNav.subtitle = stationText;
    [stationNav setNeedsDisplay:YES];
    NSArray<NSSwitch *> *editing = _checkOnOpen ? [_editorBoxes arrayByAddingObject:_checkOnOpen] : _editorBoxes;
    NSInteger on = 0;
    for (NSSwitch *b in editing) on += b.state == NSControlStateValueOn;
    say(@"settings.editor", [_adifVersion.selectedItem.representedObject isEqual:@"file"]
                                ? TF(@"{on} of {all} on \u00B7 each log's ADIF_VER", @{@"on" : @(on), @"all" : @(editing.count)})
                                : TF(@"{on} of {all} on \u00B7 ADIF {version}", @{@"on" : @(on), @"all" : @(editing.count),
                                                                               @"version" : @(adif::specVersion())}));
    [self markGroup:@"settings.editor" positive:on > 0];
    say(@"settings.language", _language.titleOfSelectedItem);
    NSInteger regions = (NSInteger)_detailRegionCards.arrangedSubviews.count - 1;  // less the line that says none
    say(@"settings.mapdetail", regions ? TP(@"{n} region", @"{n} regions", regions) : T(@"none downloaded"));
    [self markGroup:@"settings.mapdetail" positive:regions > 0];
    NSMutableArray *sources = [NSMutableArray array];
    if (_spotsSpothole.state == NSControlStateValueOn) [sources addObject:@"Spothole"];
    if (_spotsCluster.state == NSControlStateValueOn) [sources addObject:T(@"DX cluster")];
    if (_spotsPsk.state == NSControlStateValueOn) [sources addObject:@"PSKReporter"];
    say(@"settings.spots", sources.count ? [sources componentsJoinedByString:@", "] : T(@"none"));
    [self markGroup:@"settings.spots" positive:sources.count > 0];
    // The accounts: how many are set up; each card's pills follow its store and the default.
    std::vector<ADIFAccountRef> accounts = ADIFAccounts();
    BOOL anyOn = NO;
    for (const ADIFAccountRef &a : accounts) anyOn |= ADIFSourceOn(a.source, a.label.empty() ? nil : @(a.label.c_str()));
    say(@"settings.accounts", accounts.empty() ? T(@"none set up") : TP(@"{n} account", @"{n} accounts", (long long)accounts.size()));
    [self markGroup:@"settings.accounts" positive:anyOn];
    for (ADIFAccountCard *card in _accountCards.allValues) [card refreshFromStore];
    [_pendingAccount refreshFromStore];
    // Each reference set's heading: Downloading while its download runs, else Installed once it is here.
    auto reference = ^(NSString *ident, BOOL busy, BOOL have) {
        say(ident, busy ? T(@"Downloading") : have ? T(@"Installed") : T(@"Not installed"));
        [self markGroup:ident positive:have && !busy];
    };
    BOOL lotwHave = ADIFLotwUsersOn();
    reference(@"settings.lotwusers", _lotwBusy, lotwHave);
    _lotwUpdate.title = T(lotwHave ? @"Update" : @"Download");
    BOOL outlinesShown = parkoutlines::shown();
    say(@"settings.outlines", outlinesShown ? T(@"On") : T(@"Off"));
    [self markGroup:@"settings.outlines" positive:outlinesShown && !parkoutlines::all().empty()];
    BOOL installed = !ADIFCountries().empty();
    reference(@"settings.country", _countryBusy, installed);
    _countryUpdate.title = T(installed ? @"Update" : @"Download");  // Update once the data is here
    BOOL potaDownloaded = ADIFPotaParks().size() > 0;
    reference(@"settings.pota", _potaBusy, potaDownloaded);
    _potaUpdate.title = T(potaDownloaded ? @"Update" : @"Download");
    BOOL iotaDownloaded = !ADIFIotaGroups().empty();
    reference(@"settings.iota", _iotaBusy, iotaDownloaded);
    _iotaUpdate.title = T(iotaDownloaded ? @"Update" : @"Download");
}

// ── Sections as panels of their own ──

- (NSView *)takeSection:(NSString *)ident {
    if (!_taken) _taken = [NSMutableDictionary dictionary], _away = [NSMutableDictionary dictionary];
    if (_taken[ident]) return _taken[ident];
    NSStackView *body = _groupBodies[ident];
    if (!body) return nil;
    NSStackView *out = [NSStackView stackViewWithViews:@[]];
    out.orientation = NSUserInterfaceLayoutOrientationVertical;
    out.detachesHiddenViews = YES;
    out.alignment = NSLayoutAttributeLeading;
    out.spacing = body.spacing;
    out.identifier = [ident stringByAppendingString:@".panel"];
    out.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in [body.arrangedSubviews copy]) {
        [body removeArrangedSubview:v];
        [v removeFromSuperview];
        [out addArrangedSubview:v];
        [v.widthAnchor constraintEqualToAnchor:out.widthAnchor].active = YES;
    }
    NSTextField *where = wrapping(@"Shown in a panel of its own.", NSFont.smallSystemFontSize, theme::faint());
    NSButton *show = [NSButton buttonWithTitle:T(@"Show It") target:nil action:nil];
    show.identifier = [ident stringByAppendingString:@".showPanel"];
    __weak ADIFSettingsPanel *me = self;
    NSString *name = [ident copy];
    ADIFOnAction(show, ^{
        ADIFSettingsPanel *panel = me;
        if (panel.onShowSection) panel.onShowSection(name);
    });
    NSStackView *note = [NSStackView stackViewWithViews:@[ where, show ]];
    note.spacing = kADIFSpacing;
    note.identifier = [ident stringByAppendingString:@".away"];
    [body addArrangedSubview:note];
    [note.widthAnchor constraintEqualToAnchor:body.widthAnchor].active = YES;
    _taken[ident] = out, _away[ident] = note;
    return out;
}

- (void)returnSection:(NSString *)ident {
    NSStackView *out = _taken[ident];
    NSStackView *body = _groupBodies[ident];
    if (!out || !body) return;
    [body removeArrangedSubview:_away[ident]];
    [_away[ident] removeFromSuperview];
    for (NSView *v in [out.arrangedSubviews copy]) {
        [out removeArrangedSubview:v];
        [v removeFromSuperview];
        [body addArrangedSubview:v];
        [v.widthAnchor constraintEqualToAnchor:body.widthAnchor].active = YES;
    }
    [_taken removeObjectForKey:ident];
    [_away removeObjectForKey:ident];
}

- (void)offerPanel:(NSString *)ident tip:(NSString *)tip {
    NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"macwindow.on.rectangle" accessibilityDescription:tip] target:nil action:nil];
    b.bordered = NO;
    b.contentTintColor = theme::faint();
    b.toolTip = tip;
    b.identifier = [ident stringByAppendingString:@".openPanel"];
    __weak ADIFSettingsPanel *me = self;
    NSString *name = [ident copy];
    ADIFOnAction(b, ^{
        ADIFSettingsPanel *panel = me;
        if (panel.onShowSection) panel.onShowSection(name);
    });
    [_groupHeaders[ident] addView:b inGravity:NSStackViewGravityTrailing];
}

- (void)refresh {
    [self fillSpots];
    for (ADIFAccountCard *card in _accountCards.allValues) [card reloadFields];
    [self rebuildAccounts];
    [self summarize];
}

- (void)showSource:(NSInteger)source {
    [self refresh];
    if (source == -3) {  // country data
        [self openGroup:@"settings.country"];
        [self focusSetting:_countryUpdate];
        return;
    }
    if (source == -4) {  // spots
        [self openGroup:@"settings.spots"];
        [self focusSetting:_spotsView];
        return;
    }
    if (source >= 0 && source < ADIFSourceCount) {
        // The account's card, opened; an integration with no account yet is set up at once.
        ADIFAccountCard *card = _accountCards[accountKey((ADIFSource)source, nil)];
        if (!card) {
            [self startNewAccount:(ADIFSource)source];
            return;
        }
        [card setExpanded:YES];
        [self openGroup:@"settings.accounts"];
        [card scrollRectToVisible:card.bounds];
        [card focusFirstField];
    }
}

- (void)focusSetting:(NSView *)view {
    if (!view) return;
    [_view.window makeFirstResponder:view];
    [_settingsScroll layoutSubtreeIfNeeded];
    [view scrollRectToVisible:view.bounds];
}

@end

// A card's summary row. A click on it, away from the switch and the buttons, opens or closes the card.
@interface ADIFAccountHeader : NSView
@property(nonatomic, copy) void (^onClick)(void);
@end
@implementation ADIFAccountHeader
- (void)mouseDown:(NSEvent *)event {
    if (self.onClick) self.onClick();
}
@end

// The handle at a card's leading edge: dragging it moves the account, and its menu moves it a step at a time.
@interface ADIFAccountGrip : NSImageView
@property(nonatomic, weak) ADIFAccountCard *card;
@end
@implementation ADIFAccountGrip
- (void)mouseDown:(NSEvent *)event {
    // Taken here, so a press on the handle does not open the card.
}
- (void)mouseDragged:(NSEvent *)event {
    NSStackView *list = [self.card.owner accountListStack];
    [self.card.owner accountCard:self.card draggedTo:[list convertPoint:event.locationInWindow fromView:nil]];
}
- (void)mouseUp:(NSEvent *)event {
    [self.card.owner accountCardDropped:self.card];
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSMenu *menu = [[NSMenu alloc] init];
    [[menu addItemWithTitle:T(@"Move Up") action:@selector(moveUp:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:T(@"Move Down") action:@selector(moveDown:) keyEquivalent:@""] setTarget:self];
    return menu;
}
- (void)moveUp:(id)sender {
    [self.card.owner accountCard:self.card movedBy:-1];
}
- (void)moveDown:(id)sender {
    [self.card.owner accountCard:self.card movedBy:1];
}
@end

@implementation ADIFAccountCard {
    ADIFAccountHeader *_header;
    ADIFAccountGrip *_grip;
    NSImageView *_icon;
    NSButton *_chevron;
    NSTextField *_title, *_subtitle, *_failure;
    ADIFStatusPill *_defaultPill, *_statePill;
    NSSwitch *_toggle;
    NSStackView *_body;
    NSView *_logRow, *_userRow, *_secretRow;
    NSTextField *_logField, *_userField;
    NSSecureTextField *_secretField;
    NSButton *_save, *_test, *_makeDefault, *_cancel, *_remove;
    BOOL _expanded;
}

- (instancetype)initWithSource:(ADIFSource)source label:(NSString *)label isNew:(BOOL)isNew owner:(ADIFSettingsPanel *)owner {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    self.source = source;
    self.label = label ?: @"";
    self.isNew = isNew;
    self.owner = owner;
    [self buildCard];
    [self reloadFields];
    [self setExpanded:isNew];
    return self;
}

- (void)buildCard {
    _grip = [[ADIFAccountGrip alloc] initWithFrame:NSZeroRect];
    _grip.card = self;
    _grip.image = [NSImage imageWithSystemSymbolName:@"line.3.horizontal" accessibilityDescription:nil] ?: [NSImage new];
    _grip.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
    _grip.contentTintColor = theme::faint();
    _grip.toolTip = T(@"Drag to set the order");
    _grip.accessibilityLabel = T(@"Drag to set the order");
    [_grip.widthAnchor constraintEqualToConstant:12].active = YES;

    _icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:accountSymbol(self.source) accessibilityDescription:nil] ?: [NSImage new]];
    _icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightRegular];
    _icon.contentTintColor = theme::faint();
    [_icon.widthAnchor constraintEqualToConstant:22].active = YES;

    _title = [NSTextField labelWithString:@""];
    _title.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    _subtitle = [NSTextField labelWithString:@""];
    _subtitle.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _subtitle.textColor = theme::faint();
    _subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    NSStackView *titles = [NSStackView stackViewWithViews:@[ _title, _subtitle ]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 1;
    [titles setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    _defaultPill = [ADIFStatusPill pill];
    _defaultPill.stringValue = T(@"Default for lookup");
    _defaultPill.positive = YES;
    _statePill = [ADIFStatusPill pill];
    _toggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    _toggle.controlSize = NSControlSizeSmall;  // a medium toggle, as the other cards' toggles are
    _toggle.target = self;
    _toggle.action = @selector(toggled:);
    _chevron = [NSButton buttonWithImage:[NSImage new] target:self action:@selector(toggleExpanded:)];
    _chevron.bordered = NO;
    _chevron.imagePosition = NSImageOnly;
    _chevron.contentTintColor = theme::faint();
    _title.identifier = @"account.title";
    _statePill.identifier = @"account.pill";
    _defaultPill.identifier = @"account.default";
    _toggle.identifier = @"account.switch";
    _chevron.identifier = @"account.chevron";

    _header = [[ADIFAccountHeader alloc] initWithFrame:NSZeroRect];
    _header.translatesAutoresizingMaskIntoConstraints = NO;
    __weak ADIFAccountCard *card = self;
    _header.onClick = ^{
        [card toggleExpanded:nil];
    };
    NSStackView *head = [[NSStackView alloc] initWithFrame:NSZeroRect];
    head.translatesAutoresizingMaskIntoConstraints = NO;
    head.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    head.alignment = NSLayoutAttributeCenterY;
    head.spacing = 8;
    head.detachesHiddenViews = YES;
    [head addView:_grip inGravity:NSStackViewGravityLeading];
    [head addView:_icon inGravity:NSStackViewGravityLeading];
    [head addView:titles inGravity:NSStackViewGravityLeading];
    [head addView:_defaultPill inGravity:NSStackViewGravityTrailing];
    [head addView:_statePill inGravity:NSStackViewGravityTrailing];
    [head addView:_toggle inGravity:NSStackViewGravityTrailing];
    [head addView:_chevron inGravity:NSStackViewGravityTrailing];
    [_header addSubview:head];
    [NSLayoutConstraint activateConstraints:@[
        [head.topAnchor constraintEqualToAnchor:_header.topAnchor],
        [head.bottomAnchor constraintEqualToAnchor:_header.bottomAnchor],
        [head.leadingAnchor constraintEqualToAnchor:_header.leadingAnchor],
        [head.trailingAnchor constraintEqualToAnchor:_header.trailingAnchor],
    ]];

    _logField = [NSTextField textFieldWithString:@""];
    _logField.placeholderString = T(@"Callsign");
    _logField.delegate = self;
    _logField.identifier = @"account.log";
    _logRow = field(colon(T(@"Log callsign")), _logField);
    _logRow.identifier = @"account.logrow";

    _userField = [NSTextField textFieldWithString:@""];
    _userField.placeholderString = ADIFSourceUserLabel(self.source);
    _userField.delegate = self;
    _userField.identifier = @"account.user";
    _userRow = field(colon(ADIFSourceUserLabel(self.source)), _userField);
    _userRow.hidden = ADIFSourceCredentialKind(self.source) == ADIFCredentialAPIKey;
    _userRow.identifier = @"account.userrow";

    _secretField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    _secretField.placeholderString = ADIFSourceSecretLabel(self.source);
    _secretField.delegate = self;
    _secretField.identifier = @"account.secret";
    _secretRow = field(colon(ADIFSourceSecretLabel(self.source)), _secretField);

    _failure = wrapping(@"", NSFont.smallSystemFontSize, theme::error());
    _failure.identifier = @"account.failure";

    _save = [NSButton buttonWithTitle:T(@"Save") target:self action:@selector(saveTapped:)];
    _test = [NSButton buttonWithTitle:T(@"Test Sign-In") target:self action:@selector(testTapped:)];
    _makeDefault = [NSButton buttonWithTitle:T(@"Make Default") target:self action:@selector(makeDefaultTapped:)];
    _cancel = [NSButton buttonWithTitle:T(@"Cancel") target:self action:@selector(cancelTapped:)];
    _remove = [NSButton buttonWithTitle:T(@"Remove") target:self action:@selector(removeTapped:)];
    // Save, Test Sign-In and Make Default lead the card's lower edge; Cancel or Remove is at its lower right.
    NSStackView *footer = [[NSStackView alloc] initWithFrame:NSZeroRect];
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footer.alignment = NSLayoutAttributeCenterY;
    footer.spacing = 8;
    footer.detachesHiddenViews = YES;
    [footer addView:_save inGravity:NSStackViewGravityLeading];
    [footer addView:_test inGravity:NSStackViewGravityLeading];
    [footer addView:_makeDefault inGravity:NSStackViewGravityLeading];
    [footer addView:_cancel inGravity:NSStackViewGravityTrailing];
    [footer addView:_remove inGravity:NSStackViewGravityTrailing];

    NSView *purpose = explained(accountPurpose(self.source), ADIFSourceCredentialHelp(self.source));
    _body = [[NSStackView alloc] initWithFrame:NSZeroRect];
    _body.translatesAutoresizingMaskIntoConstraints = NO;
    _body.orientation = NSUserInterfaceLayoutOrientationVertical;
    _body.alignment = NSLayoutAttributeLeading;
    _body.spacing = 10;
    _body.identifier = @"account.body";
    _body.detachesHiddenViews = YES;
    for (NSView *part in @[ purpose, _logRow, _userRow, _secretRow, _failure, footer ]) {
        [_body addArrangedSubview:part];
        [part.widthAnchor constraintEqualToAnchor:_body.widthAnchor].active = YES;
    }

    NSStackView *root = [[NSStackView alloc] initWithFrame:NSZeroRect];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 12;
    root.detachesHiddenViews = YES;
    [root addArrangedSubview:_header];
    [root addArrangedSubview:_body];
    [_header.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;
    [_body.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;
    [self addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
        [root.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
        [root.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [root.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
    ]];
}

- (NSString *)storeLabel {
    return self.label.length ? self.label : nil;
}

// The pills, the toggle, the buttons and the fields' placeholders, from what is saved and what the last action left.
- (void)refreshFromStore {
    BOOL canTest = ADIFSourceCanTest(self.source);
    NSString *store = self.storeLabel;
    BOOL saved = !self.isNew && ADIFHasSavedSecret(self.source, store);
    BOOL on = !self.isNew && ADIFSourceOn(self.source, store);
    BOOL isDefault = !self.isNew && !self.label.length && ADIFLookupDefault() == (int)self.source;
    BOOL lookup = self.source == ADIFSourceQRZ || self.source == ADIFSourceHamQTH;  // the two the lookup default can be

    NSString *shown = self.isNew ? self.typedLabel : self.label;
    NSString *name = ADIFSourceName(self.source);
    _title.stringValue = shown.length ? [NSString stringWithFormat:@"%@ \u00B7 %@", name, shown] : name;
    _subtitle.stringValue = self.isNew ? @"" : (ADIFSavedAccount(self.source, store) ?: @"");
    _subtitle.hidden = _subtitle.stringValue.length == 0;
    _grip.hidden = self.isNew;
    _toggle.hidden = self.isNew;
    _toggle.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    _toggle.accessibilityLabel = _title.stringValue;
    _defaultPill.hidden = !isDefault;

    NSString *text;
    BOOL failed = NO, positive = NO;
    if (!self.isNew && !saved) text = T(@"Not set");
    else if (!self.isNew && !on) text = T(@"Off");
    else if (self.state == ADIFAccountTesting) text = T(@"Signing in...");
    else if (self.state == ADIFAccountSignInFailed) { text = T(@"Sign-in failed"); failed = YES; }
    else if (self.state == ADIFAccountSaveFailed) { text = T(@"Not saved"); failed = YES; }
    else if (self.state == ADIFAccountSignedIn) { text = T(@"Signed in"); positive = YES; }
    else if (self.isNew) text = canTest ? T(@"Not signed in") : T(@"Not tested");
    else if (!canTest) text = T(@"Not tested");
    else { text = T(@"Saved##summary"); positive = YES; }
    _statePill.stringValue = text;
    _statePill.failed = failed;
    _statePill.positive = positive;
    _statePill.toolTip = self.note.length ? self.note : nil;
    _failure.stringValue = failed ? (self.note ?: @"") : @"";

    _save.enabled = !self.isNew || !canTest || self.state == ADIFAccountSignedIn || self.state == ADIFAccountSaveFailed;
    _test.hidden = !canTest;
    _test.enabled = self.state != ADIFAccountTesting;
    _makeDefault.hidden = self.isNew || self.label.length > 0 || !lookup || !on || !saved || isDefault;
    _remove.hidden = self.isNew;
    _cancel.hidden = !self.isNew;

    _logRow.hidden = !(self.isNew && ADIFAllowsManyAccounts(self.source) && ADIFHasSavedSecret(self.source));
    _secretField.placeholderString = saved ? T(@"Saved (type to replace)") : ADIFSourceSecretLabel(self.source);
}

// The saved username; the password box is left blank, as the saved password is never shown.
- (void)reloadFields {
    NSString *user = self.isNew ? nil : ADIFSavedAccount(self.source, self.storeLabel);
    _userField.stringValue = user ?: @"";
    _secretField.stringValue = @"";
    [self refreshFromStore];
}

- (void)setExpanded:(BOOL)expanded {
    _expanded = expanded;
    _body.hidden = !expanded;
    _chevron.image = [NSImage imageWithSystemSymbolName:expanded ? @"chevron.down" : @"chevron.right" accessibilityDescription:nil];
    _chevron.accessibilityLabel = expanded ? T(@"Collapse") : T(@"Expand");
}

- (void)focusFirstField {
    NSView *first = !_logRow.hidden ? _logField : !_userRow.hidden ? _userField : _secretField;
    [self.window makeFirstResponder:first];
}

- (NSString *)typedUser {
    return [_userField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

- (NSString *)typedSecret {
    return _secretField.stringValue;
}

- (NSString *)typedLabel {
    if (_logRow.hidden) return @"";
    return [[_logField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString];
}

- (void)toggleExpanded:(id)sender {
    [self setExpanded:!_expanded];
}

- (void)toggled:(NSSwitch *)sender {
    [self.owner accountCardToggled:self on:sender.state == NSControlStateValueOn];
}

- (void)saveTapped:(id)sender {
    [self.owner accountCardSave:self];
}

- (void)testTapped:(id)sender {
    [self.owner accountCardTest:self];
}

- (void)makeDefaultTapped:(id)sender {
    [self.owner accountCardMakeDefault:self];
}

- (void)cancelTapped:(id)sender {
    [self.owner accountCardCancel:self];
}

- (void)removeTapped:(id)sender {
    [self.owner accountCardRemove:self];
}

// A new account's sign-in is for the details it was made with: changing them means signing in again.
- (void)controlTextDidChange:(NSNotification *)notification {
    if (self.isNew && self.state != ADIFAccountTesting) {
        self.state = ADIFAccountNone;
        self.note = @"";
    }
    [self refreshFromStore];
}

@end