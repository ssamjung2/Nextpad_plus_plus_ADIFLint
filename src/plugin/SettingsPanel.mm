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
    self.textColor = positive ? theme::fine() : theme::faint();
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
    NSColor *tint = self.positive ? theme::fine() : theme::faint();
    NSRect capsule = NSInsetRect(self.bounds, 0.5, 0.5);
    CGFloat radius = NSHeight(capsule) / 2;
    [[tint colorWithAlphaComponent:0.16] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:capsule xRadius:radius yRadius:radius] fill];
    [self.cell drawInteriorWithFrame:NSInsetRect(self.bounds, 8, 0) inView:self];  // the text, inside the capsule's rounded ends
}
@end

@interface ADIFSettingsPanel () <NSTextFieldDelegate, NSSearchFieldDelegate>
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
    NSMutableArray<NSTextField *> *_user;    // per source; hidden for API-key sources
    NSMutableArray<NSSecureTextField *> *_secret;
    NSMutableArray<NSTextField *> *_status;
    NSTextField *_countryStatus;
    NSButton *_countryUpdate, *_lotwOn, *_lotwUpdate;
    NSTextField *_lotwStatus, *_iotaStatus, *_potaStatus;
    NSButton *_iotaUpdate, *_potaUpdate;
    NSTextField *_welcome, *_stationCall, *_stationGrid, *_logsFolder, *_stationStatus;
    NSArray<NSButton *> *_editorBoxes;
    NSButton *_offline;
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
    NSButton *_outlinesDownload, *_outlinesRemove;
    NSTextField *_outlinesStatus, *_outlinesSummary;
    NSPopUpButton *_outlinesHave;
    NSTextField *_spotsPskCall;
    id _spotsObserver;
    NSPopUpButton *_detailRegion, *_detailInstalled;
    NSSegmentedControl *_detailLevel;
    NSArray<NSNumber *> *_detailZooms;  // each segment's zoom, Basic first
    NSButton *_detailCheck, *_detailDownload, *_detailStop, *_detailRemove;
    NSTextField *_detailStatus, *_detailSummary;
}

// A settings group has a persistent heading and a flat body; a push button goes in a row of its own size.
static NSStackView *sectionStack(NSString *title, NSString *symbol, NSArray<NSView *> *views, NSString *identifier) {
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

    NSStackView *group = [[NSStackView alloc] initWithFrame:NSZeroRect];
    group.translatesAutoresizingMaskIntoConstraints = NO;
    [group addArrangedSubview:header];
    [group addArrangedSubview:body];
    group.detachesHiddenViews = YES;
    group.orientation = NSUserInterfaceLayoutOrientationVertical;
    group.alignment = NSLayoutAttributeLeading;
    group.spacing = 8;
    group.identifier = identifier;
    [header.widthAnchor constraintEqualToAnchor:group.widthAnchor].active = YES;
    [body.widthAnchor constraintEqualToAnchor:group.widthAnchor].active = YES;
    return group;
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

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _user = [NSMutableArray array];
    _secret = [NSMutableArray array];
    _status = [NSMutableArray array];
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

    NSTextField *accounts = wrapping(@"Accounts and API keys for the online services. They are saved in your macOS Keychain "
                                     @"(items named \"ADIF Lint: ...\"), never in a file, and a saved password is never shown "
                                     @"here.",
                                     NSFont.smallSystemFontSize, theme::faint());
    NSStackView *accountGroup = sectionStack(N(@"Service Accounts"), @"key", @[ accounts ], @"settings.accounts");
    [self registerGroup:accountGroup];
    NSMutableArray<NSView *> *credentialGroups = [NSMutableArray array];
    for (NSInteger s = 0; s < ADIFSourceCount; ++s) {
        NSStackView *group = [self sectionFor:(ADIFSource)s];
        [self registerGroup:group];
        [credentialGroups addObject:group];
    }

    _categoryKeys = @[ @"station", @"editor", @"data-awards", @"map", @"spot-sources", @"application" ];
    _categoryTitles = @[ N(@"Station"), N(@"Editor"), N(@"Data & Awards"), N(@"Map"), N(@"Spot Sources"), N(@"Application") ];
    NSMutableArray<NSView *> *pagesInOrder = [NSMutableArray array];
    NSArray<NSString *> *descriptions = @[
        N(@"Station identity, callsign, grid square and logs folder."),
        N(@"Validation, syntax highlighting, autocomplete and ADIF compatibility."),
        N(@"Country data, LoTW users, award references and service accounts."),
        N(@"Geographic data and map detail downloads."),
        N(@"Configure SpotHole, DX Cluster and PSKReporter feeds."),
        N(@"Language, Offline Mode and keyboard shortcuts.")
    ];
    NSArray<NSArray<NSView *> *> *content = @[
        @[ _welcome, _groups[@"settings.station"] ],
        @[ _groups[@"settings.editor"] ],
        [@[ _groups[@"settings.country"], _groups[@"settings.lotwusers"], _groups[@"settings.pota"],
             _groups[@"settings.iota"], accountGroup ] arrayByAddingObjectsFromArray:credentialGroups],
        @[ _groups[@"settings.mapdetail"] ],
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
    [_searchField.widthAnchor constraintEqualToConstant:220].active = YES;
    _searchFeedback = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _searchFeedback.translatesAutoresizingMaskIntoConstraints = NO;
    _searchFeedback.identifier = @"settings.search.feedback";

    // Each category's symbol, as in System Settings' sidebar; its page heading shows it large in the accent colour.
    NSArray<NSString *> *symbols = @[
        @"antenna.radiowaves.left.and.right", @"square.and.pencil", @"cylinder.split.1x2", @"map", @"dot.radiowaves.left.and.right",
        @"slider.horizontal.3"
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
    _groupBodies[ident] = group.arrangedSubviews.count > 1 ? (NSStackView *)group.arrangedSubviews[1] : nil;
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
    NSMutableArray<NSButton *> *boxes = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; ++i) {
        NSButton *b = [ADIFWrappingCheckbox boxWithTitle:titles[i] target:self action:@selector(editorOption:)];
        b.tag = (NSInteger)i;
        [boxes addObject:b];
    }
    _editorBoxes = boxes;
    // The ADIF version the checks follow: the newest (which moves on as ADIF Lint learns newer ones), or a fixed older one.
    _adifVersion = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _adifVersion.identifier = @"settings.adifversion";
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
    NSMutableArray *views = [boxes mutableCopy];
    [views addObjectsFromArray:@[ field(T(@"Check against:"), _adifVersion), help ]];
    return sectionStack(N(@"Editor"), @"pencil", views, @"settings.editor");
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

- (void)editorOption:(NSButton *)sender {
    if (self.onEditorOption) self.onEditorOption(sender.tag, sender.state == NSControlStateValueOn);
    [self summarize];
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
    return sectionStack(N(@"Language"), @"globe", @[ help, field(T(@"Language:"), _language) ], @"settings.language");
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
    _offline = [ADIFWrappingCheckbox boxWithTitle:@"Work offline: make no network requests" target:self action:@selector(offlineToggled:)];
    _offline.identifier = @"settings.offline.box";
    NSTextField *help = wrapping(@"For off-grid operating, or to be sure nothing is sent. Callbook lookups, spots, uploads (TQSL "
                                 @"too), imports from the online services, downloads and web pages are refused while it is on; "
                                 @"everything that works on this Mac's files goes on, and Monitor still hears the programs on "
                                 @"this Mac. Also in the ADIF Lint menu: Offline Mode.",
                                 NSFont.smallSystemFontSize, theme::faint());
    return sectionStack(N(@"Offline Mode"), @"wifi.slash", @[ help, _offline ], @"settings.offline");
}

- (NSStackView *)mapDetailSection {
    NSTextField *help = wrapping(
        @"Streets, buildings, land use, water and place names on the Map when you zoom in, for the regions you choose. They are "
        @"OpenStreetMap's (© OpenStreetMap contributors, ODbL: openstreetmap.org/copyright), cut from Protomaps' newest daily "
        @"build (protomaps.com) and kept on this Mac; the Map draws only from what is kept here. Check Size reads the build's "
        @"index for the region and says what it would take (a city is about 10 MB with streets and buildings, a state hundreds); "
        @"Download fetches it.",
        NSFont.smallSystemFontSize, theme::faint());
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
    _detailInstalled = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _detailInstalled.identifier = @"settings.mapdetail.installed";
    _detailRemove = [NSButton buttonWithTitle:T(@"Remove") target:self action:@selector(detailRemove:)];
    _detailSummary = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _detailSummary.identifier = @"settings.mapdetail.summary";
    return sectionStack(N(@"Map Detail"), @"map", @[ help, field(colon(T(@"Region")), _detailRegion), field(colon(T(@"Detail")), _detailLevel), buttons, _detailStatus,
                                             field(T(@"Downloaded:"), _detailInstalled), _detailRemove, _detailSummary ],
                        @"settings.mapdetail");
}

// The zoom of the detail segment chosen (nil until the levels are known).
- (NSNumber *)selectedDetailZoom {
    NSInteger at = _detailLevel.selectedSegment;
    return at >= 0 && at < (NSInteger)_detailZooms.count ? _detailZooms[(NSUInteger)at] : nil;
}

- (void)setMapDetailChoices:(NSArray<NSArray *> *)choices
                     levels:(NSArray<NSArray *> *)levels
                  installed:(NSArray<NSArray<NSString *> *> *)installed
                    summary:(NSString *)summary {
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
    // Basic (the least detail) to Detailed, whatever order the levels come in.
    NSArray *ascending = [levels sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    NSArray<NSString *> *names = @[ T(@"Basic"), T(@"Normal"), T(@"Detailed") ];
    NSMutableArray<NSNumber *> *zooms = [NSMutableArray array];
    _detailLevel.segmentCount = (NSInteger)ascending.count;
    for (NSUInteger i = 0; i < ascending.count; ++i) {
        [_detailLevel setLabel:(i < names.count ? names[i] : @"") forSegment:(NSInteger)i];
        [_detailLevel setToolTip:ascending[i][1] forSegment:(NSInteger)i];
        [zooms addObject:ascending[i][0]];
    }
    _detailZooms = zooms;
    at = level ? (NSInteger)[zooms indexOfObject:level] : -1;
    _detailLevel.selectedSegment = at >= 0 ? at : (NSInteger)zooms.count - 1;  // the most detail, as the popup began
    [_detailInstalled removeAllItems];
    for (NSArray<NSString *> *r in installed) [_detailInstalled.menu addItemWithTitle:r[1] action:nil keyEquivalent:@""].representedObject = r[0];
    if (!installed.count) [_detailInstalled addItemWithTitle:T(@"(none)")];
    _detailInstalled.enabled = _detailRemove.enabled = installed.count > 0;
    _detailSummary.stringValue = summary ?: @"";
    [self summarize];
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

- (void)detailRemove:(id)sender {
    NSString *path = _detailInstalled.selectedItem.representedObject;
    if (path && self.onMapDetailRemove) self.onMapDetailRemove(path);
}

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
    return sectionStack(N(@"Keyboard Shortcuts"), @"keyboard", @[ help ], @"settings.keyboard");
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
    NSString *matchedCategory = nil;
    NSView *match = nil;
    for (NSUInteger i = 0; i < _categoryKeys.count; ++i) {
        NSString *key = _categoryKeys[i];
        match = [self matchingSettingInView:_categoryPages[key] query:query];
        if (match) {
            matchedCategory = key;
            break;
        }
        NSString *categoryText = [NSString stringWithFormat:@"%@ %@", T(_categoryTitles[i]), _categoryDescriptions[key]];
        if ([categoryText rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
            matchedCategory = key;
            break;
        }
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
    if ([ident hasPrefix:@"settings.country"] || [ident hasPrefix:@"settings.lotwusers"] ||
        [ident hasPrefix:@"settings.pota"] || [ident hasPrefix:@"settings.iota"] ||
        [ident hasPrefix:@"settings.accounts"] || [ident hasPrefix:@"settings.source."]) return @"data-awards";
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
    NSTextField *help = wrapping(@"DXCC entity, CQ and ITU zones and continent from a call's prefix, offline, for Enrich from "
                                 @"Country Data and New QSO. From Jim Reisert AD1C's country files (country-files.com, "
                                 @"MIT licence), updated every few weeks. Update downloads the newest release.",
                                 NSFont.smallSystemFontSize, theme::faint());
    _countryUpdate = [NSButton buttonWithTitle:T(@"Update") target:self action:@selector(countryUpdate:)];
    _countryStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    return sectionStack(N(@"Country Data"), @"flag", @[ help, _countryUpdate, _countryStatus ], @"settings.country");
}

- (NSStackView *)lotwSection {
    NSTextField *help = wrapping(@"Marks the stations that upload to LoTW, with their last upload, in New QSO's lookup line and the "
                                 @"Spots window. It uses ARRL's list of LoTW users (lotw.arrl.org, about 6 MB, updated weekly), "
                                 @"downloaded when you press Update and again when a week old.",
                                 NSFont.smallSystemFontSize, theme::faint());
    _lotwOn = [NSButton checkboxWithTitle:T(@"Show LoTW users") target:self action:@selector(lotwToggled:)];
    _lotwUpdate = [NSButton buttonWithTitle:T(@"Update") target:self action:@selector(lotwUpdate:)];
    ADIFWrapRow *row = [ADIFWrapRow rowWithViews:@[ _lotwOn, _lotwUpdate ]];
    row.spacing = 12;
    _lotwStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    return sectionStack(N(@"LoTW Users"), @"checkmark.seal", @[ help, row, _lotwStatus ], @"settings.lotwusers");
}

- (void)lotwToggled:(id)sender {
    if (self.onLotwUsersToggled) self.onLotwUsersToggled(_lotwOn.state == NSControlStateValueOn);
    [self summarize];
}

- (void)lotwUpdate:(id)sender {
    _lotwUpdate.enabled = NO;
    _lotwStatus.stringValue = T(@"Downloading ARRL's LoTW user list...");
    if (self.onLotwUsersUpdate) self.onLotwUsersUpdate();
}

- (void)setLotwUsersOn:(BOOL)on status:(NSString *)text ok:(BOOL)ok {
    _lotwOn.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    _lotwUpdate.enabled = YES;
    _lotwStatus.stringValue = T(text);
    _lotwStatus.textColor = ok ? theme::faint() : theme::error();
    [self summarize];
    [self summarize];
}

- (NSStackView *)potaSection {
    NSTextField *help = wrapping(@"Places POTA parks on the Map's POTA layer: with Show, a badge (a tree in a circle) at each park you've "
                                 @"hunted or activated, at the park itself; with Overlay, a smaller badge or a dot at each park you haven't worked; and "
                                 @"the Map's Parks in View lists them. Download fetches POTA's list of "
                                 @"parks (pota.app, about 9.5 MB: every park's name and place) into the plugin's settings folder on "
                                 @"this Mac; download again for new parks. ADIF Lint isn't affiliated with Parks on the Air.",
                                 NSFont.smallSystemFontSize, theme::faint());
    _potaUpdate = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(potaUpdate:)];
    _potaStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    // Park Outlines: a POTA location's park boundaries, downloaded when asked.
    NSTextField *outlinesTitle = [NSTextField labelWithString:T(@"Park Outlines")];
    outlinesTitle.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize + 1];
    NSTextField *outlinesHelp = wrapping(
        @"Draws parks as their outlines on the Map's POTA layer, for one POTA location at a time (US-IL, DE-HE, VK-NSW), downloaded when you "
        @"press Download: OpenStreetMap's areas tagged with the park's reference (through Overpass), pota-map.info's for Austria, Czechia, "
        @"Denmark, Germany, Luxembourg and Switzerland, and for US parks USGS's PAD-US, matched by name and by POTA's place for the park "
        @"(dashed on the map, and said so). A state can take a minute; Overpass is sometimes too busy, and then OpenStreetMap's are left "
        @"for another try.",
        NSFont.smallSystemFontSize, theme::faint());
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
    // What is downloaded: a location each in the menu (to remove one), and all of them summed up.
    _outlinesHave = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _outlinesHave.identifier = @"settings.outlines.installed";
    _outlinesRemove = [NSButton buttonWithTitle:T(@"Remove") target:self action:@selector(outlinesRemove:)];
    _outlinesRemove.identifier = @"settings.outlines.remove";
    _outlinesSummary = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    _outlinesSummary.identifier = @"settings.outlines.summary";
    [self fillOutlines];
    return sectionStack(N(@"POTA Parks"), @"leaf", @[ help, _potaUpdate, _potaStatus, outlinesTitle, outlinesHelp, outlinesRow, _outlinesStatus,
                                             field(T(@"Downloaded:"), _outlinesHave), _outlinesRemove, _outlinesSummary ],
                        @"settings.pota");
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
    NSString *was = _outlinesHave.selectedItem.representedObject;
    [_outlinesHave removeAllItems];
    for (const parkoutlines::Downloaded &d : have)
        [_outlinesHave.menu addItemWithTitle:@(parkoutlines::describe(d).c_str()) action:nil keyEquivalent:@""].representedObject = @(d.location.c_str());
    if (have.empty()) [_outlinesHave addItemWithTitle:T(@"(none)")];
    NSInteger at = was ? [_outlinesHave indexOfItemWithRepresentedObject:was] : -1;
    if (at >= 0) [_outlinesHave selectItemAtIndex:at];
    _outlinesHave.enabled = !have.empty();
    _outlinesRemove.enabled = !have.empty() && !parkoutlines::busy();
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
    _outlinesDownload.enabled = NO, _outlinesLocation.enabled = NO, _outlinesRemove.enabled = NO;
    __weak ADIFSettingsPanel *weakSelf = self;
    NSString *chosen = @(location.c_str());
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
            [me fillOutlines];
            NSInteger at = [me->_outlinesHave indexOfItemWithRepresentedObject:chosen];
            if (at >= 0) [me->_outlinesHave selectItemAtIndex:at];  // the one just downloaded
            me->_outlinesStatus.stringValue = message;
            me->_outlinesStatus.textColor = ok ? theme::faint() : theme::error();
        });
}

- (void)outlinesRemove:(id)sender {
    NSString *location = _outlinesHave.selectedItem.representedObject;
    if (!location) return;
    parkoutlines::remove(ADIFStd(location));
    [self fillOutlines];
}

- (void)potaUpdate:(id)sender {
    _potaUpdate.enabled = NO;
    _potaStatus.stringValue = T(@"Downloading POTA's park list...");
    _potaStatus.textColor = theme::faint();
    if (self.onPotaUpdate) self.onPotaUpdate();
}

- (void)setPotaStatus:(NSString *)text ok:(BOOL)ok {
    [self fillOutlines];  // the list's locations (it may have just been downloaded)
    _potaUpdate.enabled = YES;
    _potaStatus.stringValue = T(text);
    _potaStatus.textColor = ok ? theme::faint() : theme::error();
    [self summarize];
}

- (NSStackView *)iotaSection {
    NSTextField *help = wrapping(@"Draws IOTA's island groups on the Map (Overlays: IOTA), with the groups in your log filled in. "
                                 @"The group list is \u00A9 RSGB and IOTA Ltd, who allow downloading it for your own personal, "
                                 @"non-commercial use, so ADIF Lint doesn't include it: Download fetches it from iota-world.org "
                                 @"(about 290 KB) into the plugin's settings folder on this Mac. Download again to update it.",
                                 NSFont.smallSystemFontSize, theme::faint());
    _iotaUpdate = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(iotaUpdate:)];
    _iotaStatus = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());
    return sectionStack(N(@"IOTA Groups"), @"drop", @[ help, _iotaUpdate, _iotaStatus ], @"settings.iota");
}

- (void)iotaUpdate:(id)sender {
    _iotaUpdate.enabled = NO;
    _iotaStatus.stringValue = T(@"Downloading IOTA's group list...");
    _iotaStatus.textColor = theme::faint();
    if (self.onIotaUpdate) self.onIotaUpdate();
}

- (void)setIotaStatus:(NSString *)text ok:(BOOL)ok {
    _iotaUpdate.enabled = YES;
    _iotaStatus.stringValue = T(text);
    _iotaStatus.textColor = ok ? theme::faint() : theme::error();
    [self summarize];
}

- (void)countryUpdate:(id)sender {
    _countryUpdate.enabled = NO;
    [self setCountryStatus:@"Downloading the newest country file..." ok:YES];
    if (self.onCountryUpdate) self.onCountryUpdate();
}

- (void)setCountryStatus:(NSString *)text ok:(BOOL)ok {
    _countryUpdate.enabled = YES;
    _countryStatus.stringValue = T(text);
    _countryStatus.textColor = ok ? theme::faint() : theme::error();
    [self summarize];
}

- (NSStackView *)sectionFor:(ADIFSource)source {
    NSTextField *help = wrapping(ADIFSourceCredentialHelp(source), NSFont.smallSystemFontSize, theme::faint());

    BOOL apiKey = ADIFSourceCredentialKind(source) == ADIFCredentialAPIKey;
    NSTextField *user = [NSTextField textFieldWithString:@""];
    user.placeholderString = ADIFSourceUserLabel(source);
    NSSecureTextField *secret = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    secret.placeholderString = ADIFSourceSecretLabel(source);
    NSStackView *userField = field(colon(ADIFSourceUserLabel(source)), user), *secretField = field(colon(ADIFSourceSecretLabel(source)), secret);
    userField.hidden = apiKey;

    NSButton *save = [NSButton buttonWithTitle:T(@"Save") target:self action:@selector(save:)];
    NSButton *test = [NSButton buttonWithTitle:T(@"Test Sign-In") target:self action:@selector(test:)];
    test.hidden = !ADIFSourceCanTest(source);
    NSButton *remove = [NSButton buttonWithTitle:T(@"Remove") target:self action:@selector(remove:)];
    for (NSButton *b in @[ save, test, remove ]) b.tag = source;
    ADIFWrapRow *buttons = [ADIFWrapRow rowWithViews:@[ save, test, remove ]];
    NSTextField *status = wrapping(@"", NSFont.smallSystemFontSize, theme::faint());

    NSStackView *section = sectionStack(ADIFSourceName(source), @"key", @[ help, userField, secretField, buttons, status ],
                                       [NSString stringWithFormat:@"settings.source.%ld", (long)source]);

    [_user addObject:user];
    [_secret addObject:secret];
    [_status addObject:status];
    return section;
}

- (void)setStatus:(NSString *)text ok:(BOOL)ok forSource:(NSInteger)s {
    _status[(NSUInteger)s].stringValue = T(text);
    _status[(NSUInteger)s].textColor = ok ? theme::faint() : theme::error();
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
    NSSwitch *toggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    toggle.controlSize = NSControlSizeSmall;  // a medium toggle, not the large one
    toggle.target = self;
    toggle.action = @selector(spotsChanged:);
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
    auto onOff = ^(NSButton *b) { return b.state == NSControlStateValueOn ? T(@"On##summary") : T(@"Off##summary"); };
    NSMutableArray *station = [NSMutableArray array];
    for (NSTextField *f in @[ _stationCall, _stationGrid ])
        if (f.stringValue.length) [station addObject:f.stringValue.uppercaseString];
    NSString *stationText = station.count ? [station componentsJoinedByString:@" \u00B7 "] : T(@"not set");
    say(@"settings.station", stationText);
    [self markGroup:@"settings.station" positive:station.count > 0];
    ADIFSettingsNavButton *stationNav = (ADIFSettingsNavButton *)_categoryButtons[@"station"];
    stationNav.subtitle = stationText;
    [stationNav setNeedsDisplay:YES];
    NSInteger on = 0;
    for (NSButton *b in _editorBoxes) on += b.state == NSControlStateValueOn;
    say(@"settings.editor", [_adifVersion.selectedItem.representedObject isEqual:@"file"]
                                ? TF(@"{on} of {all} on \u00B7 each log's ADIF_VER", @{@"on" : @(on), @"all" : @(_editorBoxes.count)})
                                : TF(@"{on} of {all} on \u00B7 ADIF {version}", @{@"on" : @(on), @"all" : @(_editorBoxes.count),
                                                                               @"version" : @(adif::specVersion())}));
    [self markGroup:@"settings.editor" positive:on > 0];
    say(@"settings.language", _language.titleOfSelectedItem);
    say(@"settings.offline", onOff(_offline));
    say(@"settings.lotwusers", onOff(_lotwOn));
    [self markGroup:@"settings.lotwusers" positive:_lotwOn.state == NSControlStateValueOn];
    NSInteger regions = _detailInstalled.enabled ? _detailInstalled.numberOfItems : 0;
    say(@"settings.mapdetail", regions ? TP(@"{n} region", @"{n} regions", regions) : T(@"none downloaded"));
    [self markGroup:@"settings.mapdetail" positive:regions > 0];
    NSMutableArray *sources = [NSMutableArray array];
    if (_spotsSpothole.state == NSControlStateValueOn) [sources addObject:@"Spothole"];
    if (_spotsCluster.state == NSControlStateValueOn) [sources addObject:T(@"DX cluster")];
    if (_spotsPsk.state == NSControlStateValueOn) [sources addObject:@"PSKReporter"];
    say(@"settings.spots", sources.count ? [sources componentsJoinedByString:@", "] : T(@"none"));
    [self markGroup:@"settings.spots" positive:sources.count > 0];
    for (NSInteger s = 0; s < ADIFSourceCount; ++s) {
        NSString *ident = [NSString stringWithFormat:@"settings.source.%ld", (long)s];
        say(ident, ADIFHasSecret((ADIFSource)s) ? T(@"Saved##summary") : T(@"not set"));
        [self markGroup:ident positive:ADIFHasSecret((ADIFSource)s)];
    }
    // The reference data's state, as the heading of its group shows it.
    BOOL installed = !ADIFCountries().empty();
    say(@"settings.country", installed ? T(@"Installed") : T(@"none downloaded"));
    [self markGroup:@"settings.country" positive:installed];
    BOOL potaDownloaded = ADIFPotaParks().size() > 0;
    say(@"settings.pota", potaDownloaded ? T(@"Downloaded") : T(@"none downloaded"));
    [self markGroup:@"settings.pota" positive:potaDownloaded];
    BOOL iotaDownloaded = !ADIFIotaGroups().empty();
    say(@"settings.iota", iotaDownloaded ? T(@"Downloaded") : T(@"none downloaded"));
    [self markGroup:@"settings.iota" positive:iotaDownloaded];
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
    for (NSInteger s = 0; s < ADIFSourceCount; ++s) {
        NSString *account = ADIFSavedAccount((ADIFSource)s);
        BOOL secret = ADIFHasSecret((ADIFSource)s);
        BOOL apiKey = ADIFSourceCredentialKind((ADIFSource)s) == ADIFCredentialAPIKey;
        _user[(NSUInteger)s].stringValue = apiKey ? @"" : (account ?: @"");
        _secret[(NSUInteger)s].stringValue = @"";
        _secret[(NSUInteger)s].placeholderString =
            secret ? T(@"Saved in your Keychain (type to replace)") : ADIFSourceSecretLabel((ADIFSource)s);
        [self setStatus:secret ? N(@"Saved.") : N(@"Not set.") ok:YES forSource:s];
    }
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
        [self openGroup:[NSString stringWithFormat:@"settings.source.%ld", (long)source]];
        BOOL apiKey = ADIFSourceCredentialKind((ADIFSource)source) == ADIFCredentialAPIKey;
        NSTextField *first = apiKey || _user[(NSUInteger)source].stringValue.length ? _secret[(NSUInteger)source]
                                                                                     : _user[(NSUInteger)source];
        [self focusSetting:first];
    }
}

- (void)focusSetting:(NSView *)view {
    if (!view) return;
    [_view.window makeFirstResponder:view];
    [_settingsScroll layoutSubtreeIfNeeded];
    [view scrollRectToVisible:view.bounds];
}

- (void)save:(NSButton *)sender {
    NSInteger s = sender.tag;
    NSString *user = [_user[(NSUInteger)s].stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *secret = _secret[(NSUInteger)s].stringValue;
    NSString *error = nil;
    if (!ADIFSaveCredential((ADIFSource)s, user, secret, &error)) {
        [self setStatus:error ?: N(@"Could not save.") ok:NO forSource:s];
        return;
    }
    _secret[(NSUInteger)s].stringValue = @"";  // do not keep the secret in the window
    _secret[(NSUInteger)s].placeholderString = T(@"Saved in your Keychain (type to replace)");
    [self setStatus:@"Saved in your Keychain." ok:YES forSource:s];
    if (self.onChanged) self.onChanged(s);
}

- (void)test:(NSButton *)sender {
    NSInteger s = sender.tag;
    sender.enabled = NO;
    [self setStatus:@"Signing in..." ok:YES forSource:s];
    ADIFTestCredential((ADIFSource)s, ^(BOOL ok, NSString *message) {
        sender.enabled = YES;
        [self setStatus:message ok:ok forSource:s];
    });
}

- (void)remove:(NSButton *)sender {
    NSInteger s = sender.tag;
    ADIFDeleteCredential((ADIFSource)s);
    [self refresh];
    [self setStatus:@"Removed from your Keychain." ok:YES forSource:s];
    if (self.onChanged) self.onChanged(s);
}

@end
