#import "SettingsPanel.h"
#import "Night.h"
#import "L10n.h"

#import "Lookup.h"
#import "Spots.h"
#import "ParkOutlines.h"
#import "PotaParks.h"

#include "PluginHost.h"
#include "adif_geo.h"
#import "ToolWindow.h"

// Flipped, so the sections start at the top of the scroll view.
@interface ADIFSettingsDocument : NSView
@end
@implementation ADIFSettingsDocument
- (BOOL)isFlipped {
    return YES;
}
@end

@implementation ADIFSettingsPanel {
    NSPanel *_window;
    NSMutableArray<NSTextField *> *_user;    // per source; hidden for API-key sources
    NSMutableArray<NSSecureTextField *> *_secret;
    NSMutableArray<NSTextField *> *_status;
    NSTextField *_countryStatus;
    NSButton *_countryUpdate, *_lotwOn, *_lotwUpdate;
    NSTextField *_lotwStatus, *_iotaStatus, *_potaStatus;
    NSButton *_iotaUpdate, *_potaUpdate;
    NSScrollView *_scroll;
    NSTextField *_welcome, *_stationCall, *_stationGrid, *_logsFolder, *_stationStatus;
    NSArray<NSButton *> *_editorBoxes;
    NSButton *_offline;
    NSPopUpButton *_language;
    NSView *_spotsView;
    NSButton *_spotsSpothole, *_spotsCluster, *_spotsPsk;
    NSComboBox *_spotsNode;
    NSTextField *_spotsLogin, *_spotsCommands, *_spotsEmail, *_spotsStatus;
    NSPopUpButton *_spotsPskQuery;
    NSComboBox *_outlinesLocation;
    NSButton *_outlinesDownload, *_outlinesRemove;
    NSTextField *_outlinesStatus, *_outlinesSummary;
    NSPopUpButton *_outlinesHave;
    NSTextField *_spotsPskCall;
    id _spotsObserver;
    NSPopUpButton *_detailRegion, *_detailLevel, *_detailInstalled;
    NSButton *_detailCheck, *_detailDownload, *_detailStop, *_detailRemove;
    NSTextField *_detailStatus, *_detailSummary;
}

static NSTextField *sectionTitle(NSString *text) {
    NSTextField *title = [NSTextField labelWithString:T(text)];
    title.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize + 1];
    return title;
}

static NSStackView *sectionStack(NSArray<NSView *> *views, NSString *identifier) {
    NSStackView *section = [NSStackView stackViewWithViews:views];
    section.orientation = NSUserInterfaceLayoutOrientationVertical;
    section.alignment = NSLayoutAttributeLeading;
    section.spacing = 8;
    [section setCustomSpacing:4 afterView:views.firstObject];
    section.identifier = identifier;
    return section;
}

// Fixed text width: wrapping labels need it to work out their height.
static const CGFloat kTextWidth = 520;

// "Callsign:" in the language in use (French puts a space before the colon).
static NSString *colon(NSString *label) { return TF(@"{label}:", @{@"label" : label}); }

// The label column, the same in every section so the fields line up: the widest label, and at
// least 80 points (longer in some languages).
static CGFloat labelColumnWidth() {
    NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithArray:@[
        T(@"Callsign:"), T(@"Grid:"), T(@"Logs folder:"), colon(T(@"Node")), colon(T(@"Login")), colon(T(@"Then send")), colon(T(@"Your email")),
        colon(T(@"Reports"))
    ]];
    for (NSInteger s = 0; s < ADIFSourceCount; ++s) {
        [labels addObject:colon(ADIFSourceUserLabel((ADIFSource)s))];
        [labels addObject:colon(ADIFSourceSecretLabel((ADIFSource)s))];
    }
    CGFloat w = 80;
    for (NSString *l in labels) w = MAX(w, ceil([NSTextField labelWithString:l].intrinsicContentSize.width));
    return w;
}

static NSTextField *wrapping(NSString *text, CGFloat size, NSColor *color) {
    NSTextField *t = [NSTextField wrappingLabelWithString:T(text)];
    t.font = [NSFont systemFontOfSize:size];
    t.textColor = color;
    t.preferredMaxLayoutWidth = kTextWidth;
    [t.widthAnchor constraintEqualToConstant:kTextWidth].active = YES;
    return t;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _user = [NSMutableArray array];
    _secret = [NSMutableArray array];
    _status = [NSMutableArray array];
    _window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kTextWidth + 40, 400)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                           backing:NSBackingStoreBuffered
                                             defer:YES];
    _window.title = T(@"ADIF Lint Settings");
    ADIFNightTrack(_window);
    _window.floatingPanel = YES;
    _window.hidesOnDeactivate = YES;
    _window.releasedWhenClosed = NO;
    _window.delegate = self;

    NSMutableArray<NSView *> *views = [NSMutableArray array];
    _welcome = wrapping(@"Welcome to ADIF Lint. Enter your callsign and grid below: New QSO and the exports use them for "
                        @"a log that doesn't have them yet. Accounts for QRZ.com, LoTW, eQSL and Club Log are further "
                        @"down, when you want them.",
                        NSFont.systemFontSize, NSColor.labelColor);
    _welcome.hidden = YES;
    [views addObject:_welcome];
    for (NSView *section in @[ [self stationSection], [self editorSection], [self languageSection], [self offlineSection], [self keyboardSection], [self countrySection], [self lotwSection],
                                 [self potaSection], [self iotaSection], [self mapDetailSection], [self spotsSection] ]) {
        [views addObject:section];
        NSBox *line = [[NSBox alloc] init];
        line.boxType = NSBoxSeparator;
        [line.widthAnchor constraintEqualToConstant:kTextWidth].active = YES;
        [views addObject:line];
    }
    [views addObject:wrapping(@"Accounts and API keys for the online services. They are saved in your macOS Keychain "
                              @"(items named \"ADIF Lint: ...\"), never in a file, and a saved password is never shown "
                              @"here.",
                              NSFont.systemFontSize, NSColor.labelColor)];
    for (NSInteger s = 0; s < ADIFSourceCount; ++s) {
        NSBox *line = [[NSBox alloc] init];
        line.boxType = NSBoxSeparator;
        [line.widthAnchor constraintEqualToConstant:kTextWidth].active = YES;
        [views addObject:line];
        [views addObject:[self sectionFor:(ADIFSource)s]];
    }
    // Plain stack views size themselves from their content (an NSBox does not).
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.edgeInsets = NSEdgeInsetsMake(18, 20, 20, 20);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    // The sections scroll when the screen is too short for all of them.
    NSView *document = [[ADIFSettingsDocument alloc] initWithFrame:NSZeroRect];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:stack];
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.drawsBackground = NO;
    _scroll.documentView = document;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *root = _window.contentView;
    [root addSubview:_scroll];
    NSSize fit = stack.fittingSize;
    CGFloat screen = NSScreen.mainScreen ? NSHeight(NSScreen.mainScreen.visibleFrame) - 80 : 760;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor],
        [document.leadingAnchor constraintEqualToAnchor:_scroll.contentView.leadingAnchor],
        [document.trailingAnchor constraintEqualToAnchor:_scroll.contentView.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:_scroll.contentView.topAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    [_window setContentSize:NSMakeSize(fit.width, MIN(fit.height, MAX(screen, 400)))];
    _window.contentMinSize = NSMakeSize(fit.width, 300);
    _window.contentMaxSize = NSMakeSize(fit.width, fit.height);
    _window.styleMask |= NSWindowStyleMaskResizable;
    [_window center];
    [self refresh];
    return self;
}

- (NSView *)stationSection {
    _stationCall = [NSTextField textFieldWithString:@""];
    _stationCall.placeholderString = T(@"e.g. KW9D");
    _stationGrid = [NSTextField textFieldWithString:@""];
    _stationGrid.placeholderString = T(@"e.g. EN52");
    for (NSTextField *f in @[ _stationCall, _stationGrid ]) [f.widthAnchor constraintEqualToConstant:140].active = YES;
    _logsFolder = [NSTextField labelWithString:@""];
    _logsFolder.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_logsFolder.widthAnchor constraintLessThanOrEqualToConstant:300].active = YES;
    NSButton *choose = [NSButton buttonWithTitle:T(@"Choose...") target:self action:@selector(chooseFolder:)];
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[ [NSTextField labelWithString:T(@"Callsign:")], _stationCall ],
        @[ [NSTextField labelWithString:T(@"Grid:")], _stationGrid ],
        @[ [NSTextField labelWithString:T(@"Logs folder:")], [NSStackView stackViewWithViews:@[ _logsFolder, choose ]] ],
    ]];
    grid.rowSpacing = 6;
    grid.columnSpacing = 8;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:0].width = labelColumnWidth();
    NSButton *save = [NSButton buttonWithTitle:T(@"Save") target:self action:@selector(saveStation:)];
    NSButton *profiles = [NSButton buttonWithTitle:T(@"Station Profiles...") target:self action:@selector(stationProfiles:)];
    profiles.toolTip = T(@"Named sets of your station's fields (home, portable, a club station) for New QSO and activations");
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ save, profiles ]];
    _stationStatus = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    NSTextField *help = wrapping(@"Used when a log doesn't say: New QSO fills STATION_CALLSIGN and MY_GRIDSQUARE from them "
                                 @"in a new log, and the exports use the callsign. Worked Before searches the logs folder.",
                                 NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    return sectionStack(@[ sectionTitle(@"Your Station"), help, grid, buttons, _stationStatus ], @"settings.station");
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
}

- (void)setStationStatus:(NSString *)text ok:(BOOL)ok {
    _stationStatus.stringValue = T(text);
    _stationStatus.textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
}

- (NSView *)editorSection {
    NSArray<NSString *> *titles = @[
        N(@"Check .adi files while typing (problem marks)"), N(@"Colour ADIF syntax"),
        N(@"Autocomplete field names and values, with lengths"), N(@"Count lengths in characters, not bytes (for UTF-8 logs)")
    ];
    NSMutableArray<NSButton *> *boxes = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; ++i) {
        NSButton *b = [NSButton checkboxWithTitle:T(titles[i]) target:self action:@selector(editorOption:)];
        b.tag = (NSInteger)i;
        [boxes addObject:b];
    }
    _editorBoxes = boxes;
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:sectionTitle(@"Editor")];
    [views addObjectsFromArray:boxes];
    return sectionStack(views, @"settings.editor");
}

- (void)editorOption:(NSButton *)sender {
    if (self.onEditorOption) self.onEditorOption(sender.tag, sender.state == NSControlStateValueOn);
}

- (void)setEditorValidate:(BOOL)validate colour:(BOOL)colour autocomplete:(BOOL)autocomplete characters:(BOOL)characters {
    BOOL on[] = {validate, colour, autocomplete, characters};
    for (NSUInteger i = 0; i < _editorBoxes.count && i < 4; ++i)
        _editorBoxes[i].state = on[i] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (NSView *)languageSection {
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
                                 NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    NSStackView *row = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:T(@"Language:")], _language ]];
    row.spacing = 8;
    return sectionStack(@[ sectionTitle(@"Language"), help, row ], @"settings.language");
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
}

- (NSView *)offlineSection {
    _offline = [NSButton checkboxWithTitle:T(@"Work offline: make no network requests") target:self action:@selector(offlineToggled:)];
    _offline.identifier = @"settings.offline.box";
    NSTextField *help = wrapping(@"For off-grid operating, or to be sure nothing is sent. Callbook lookups, spots, uploads (TQSL "
                                 @"too), imports from the online services, downloads and web pages are refused while it is on; "
                                 @"everything that works on this Mac's files goes on, and Monitor still hears the programs on "
                                 @"this Mac. Also in the ADIF Lint menu: Offline Mode.",
                                 NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    return sectionStack(@[ sectionTitle(@"Offline Mode"), help, _offline ], @"settings.offline");
}

- (NSView *)mapDetailSection {
    NSTextField *help = wrapping(
        @"Streets, buildings, land use, water and place names on the Map when you zoom in, for the regions you choose. They are "
        @"OpenStreetMap's (© OpenStreetMap contributors, ODbL: openstreetmap.org/copyright), cut from Protomaps' newest daily "
        @"build (protomaps.com) and kept on this Mac; the Map draws only from what is kept here. Check Size reads the build's "
        @"index for the region and says what it would take (a city is about 10 MB with streets and buildings, a state hundreds); "
        @"Download fetches it.",
        NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _detailRegion = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _detailRegion.identifier = @"settings.mapdetail.region";
    [_detailRegion.widthAnchor constraintEqualToConstant:250].active = YES;
    _detailLevel = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _detailLevel.identifier = @"settings.mapdetail.level";
    for (NSPopUpButton *p in @[ _detailRegion, _detailLevel ]) {
        p.target = self;
        p.action = @selector(detailChoiceChanged:);
    }
    NSStackView *choose = [NSStackView stackViewWithViews:@[ _detailRegion, _detailLevel ]];
    _detailCheck = [NSButton buttonWithTitle:T(@"Check Size") target:self action:@selector(detailCheck:)];
    _detailDownload = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(detailDownload:)];
    _detailStop = [NSButton buttonWithTitle:T(@"Stop") target:self action:@selector(detailStop:)];
    _detailDownload.enabled = _detailStop.enabled = NO;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ _detailCheck, _detailDownload, _detailStop ]];
    _detailStatus = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _detailStatus.identifier = @"settings.mapdetail.status";
    _detailInstalled = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _detailInstalled.identifier = @"settings.mapdetail.installed";
    [_detailInstalled.widthAnchor constraintEqualToConstant:330].active = YES;
    _detailRemove = [NSButton buttonWithTitle:T(@"Remove") target:self action:@selector(detailRemove:)];
    NSStackView *have = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:T(@"Downloaded:")], _detailInstalled, _detailRemove ]];
    _detailSummary = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _detailSummary.identifier = @"settings.mapdetail.summary";
    return sectionStack(@[ sectionTitle(@"Map Detail"), help, choose, buttons, _detailStatus, have, _detailSummary ], @"settings.mapdetail");
}

- (void)setMapDetailChoices:(NSArray<NSArray *> *)choices
                     levels:(NSArray<NSArray *> *)levels
                  installed:(NSArray<NSArray<NSString *> *> *)installed
                    summary:(NSString *)summary {
    id was = _detailRegion.selectedItem.representedObject, level = _detailLevel.selectedItem.representedObject;
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
    [_detailLevel removeAllItems];
    for (NSArray *l in levels) [_detailLevel.menu addItemWithTitle:l[1] action:nil keyEquivalent:@""].representedObject = l[0];
    at = level ? [_detailLevel indexOfItemWithRepresentedObject:level] : -1;
    if (at >= 0) [_detailLevel selectItemAtIndex:at];
    [_detailInstalled removeAllItems];
    for (NSArray<NSString *> *r in installed) [_detailInstalled.menu addItemWithTitle:r[1] action:nil keyEquivalent:@""].representedObject = r[0];
    if (!installed.count) [_detailInstalled addItemWithTitle:T(@"(none)")];
    _detailInstalled.enabled = _detailRemove.enabled = installed.count > 0;
    _detailSummary.stringValue = summary ?: @"";
}

- (void)setMapDetailState:(NSString *)message ok:(BOOL)ok checked:(BOOL)checked busy:(BOOL)busy {
    _detailStatus.stringValue = T(message);
    _detailStatus.textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
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
    NSNumber *zoom = _detailLevel.selectedItem.representedObject;
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
}

- (void)setOffline:(BOOL)on {
    _offline.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (NSView *)keyboardSection {
    NSTextField *help = wrapping(
        @"Nextpad++ binds plugin commands in its own Shortcut Mapper: Edit > Shortcut Mapper..., the Plugin commands tab. "
        @"Suggestions: New QSO Control-Option-N, Log Table Control-Option-T, Check Log Control-Option-C, Next Problem "
        @"Control-Option-Down, Previous Problem Control-Option-Up, Spots Control-Option-S (pick others if Nextpad++ "
        @"already uses one).",
        NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    return sectionStack(@[ sectionTitle(@"Keyboard Shortcuts"), help ], @"settings.keyboard");
}

- (void)showWelcome {
    _welcome.hidden = NO;
    [self refresh];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_stationCall];
    [_welcome scrollRectToVisible:_welcome.bounds];
}

- (NSView *)countrySection {
    NSTextField *title = [NSTextField labelWithString:T(@"Country Data")];
    title.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize + 1];
    NSTextField *help = wrapping(@"DXCC entity, CQ and ITU zones and continent from a call's prefix, offline, for Enrich from "
                                 @"Country Data and New QSO. From Jim Reisert AD1C's country files (country-files.com, "
                                 @"MIT licence), updated every few weeks. Update downloads the newest release.",
                                 NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _countryUpdate = [NSButton buttonWithTitle:T(@"Update") target:self action:@selector(countryUpdate:)];
    _countryStatus = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    NSStackView *section = [NSStackView stackViewWithViews:@[ title, help, _countryUpdate, _countryStatus ]];
    section.orientation = NSUserInterfaceLayoutOrientationVertical;
    section.alignment = NSLayoutAttributeLeading;
    section.spacing = 8;
    [section setCustomSpacing:4 afterView:title];
    section.identifier = @"settings.country";
    return section;
}

- (NSView *)lotwSection {
    NSTextField *help = wrapping(@"Marks the stations that upload to LoTW, with their last upload, in New QSO's lookup line and the "
                                 @"Spots window. It uses ARRL's list of LoTW users (lotw.arrl.org, about 6 MB, updated weekly), "
                                 @"downloaded when you press Update and again when a week old.",
                                 NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _lotwOn = [NSButton checkboxWithTitle:T(@"Show LoTW users") target:self action:@selector(lotwToggled:)];
    _lotwUpdate = [NSButton buttonWithTitle:T(@"Update") target:self action:@selector(lotwUpdate:)];
    NSStackView *row = [NSStackView stackViewWithViews:@[ _lotwOn, _lotwUpdate ]];
    row.spacing = 12;
    _lotwStatus = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    return sectionStack(@[ sectionTitle(@"LoTW Users"), help, row, _lotwStatus ], @"settings.lotwusers");
}

- (void)lotwToggled:(id)sender {
    if (self.onLotwUsersToggled) self.onLotwUsersToggled(_lotwOn.state == NSControlStateValueOn);
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
    _lotwStatus.textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
}

- (NSView *)potaSection {
    NSTextField *help = wrapping(@"Places POTA parks on the Map's POTA layer: with Show, a badge (a tree in a circle) at each park you've "
                                 @"hunted or activated, at the park itself; with Overlay, a smaller badge or a dot at each park you haven't worked; and "
                                 @"the Map's Parks in View lists them. Download fetches POTA's list of "
                                 @"parks (pota.app, about 9.5 MB: every park's name and place) into the plugin's settings folder on "
                                 @"this Mac; download again for new parks. ADIF Lint isn't affiliated with Parks on the Air.",
                                 NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _potaUpdate = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(potaUpdate:)];
    _potaStatus = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    // Park Outlines: a POTA location's park boundaries, downloaded when asked.
    NSTextField *outlinesTitle = [NSTextField labelWithString:T(@"Park Outlines")];
    outlinesTitle.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize + 1];
    NSTextField *outlinesHelp = wrapping(
        @"Draws parks as their outlines on the Map's POTA layer, for one POTA location at a time (US-IL, DE-HE, VK-NSW), downloaded when you "
        @"press Download: OpenStreetMap's areas tagged with the park's reference (through Overpass), pota-map.info's for Austria, Czechia, "
        @"Denmark, Germany, Luxembourg and Switzerland, and for US parks USGS's PAD-US, matched by name and by POTA's place for the park "
        @"(dashed on the map, and said so). A state can take a minute; Overpass is sometimes too busy, and then OpenStreetMap's are left "
        @"for another try.",
        NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _outlinesLocation = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    _outlinesLocation.completes = YES;
    _outlinesLocation.numberOfVisibleItems = 15;
    _outlinesLocation.placeholderString = T(@"POTA location, such as US-IL");
    _outlinesLocation.identifier = @"settings.outlines.location";
    [_outlinesLocation.widthAnchor constraintEqualToConstant:150].active = YES;
    _outlinesLocation.target = self;
    _outlinesLocation.action = @selector(outlinesLocationChosen:);
    _outlinesDownload = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(outlinesDownload:)];
    _outlinesDownload.identifier = @"settings.outlines.download";
    NSStackView *outlinesRow = [NSStackView stackViewWithViews:@[ _outlinesLocation, _outlinesDownload ]];
    outlinesRow.spacing = 8;
    _outlinesStatus = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _outlinesStatus.identifier = @"settings.outlines.status";
    // What is downloaded: a location each in the menu (to remove one), and all of them summed up.
    _outlinesHave = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _outlinesHave.identifier = @"settings.outlines.installed";
    [_outlinesHave.widthAnchor constraintEqualToConstant:330].active = YES;
    _outlinesRemove = [NSButton buttonWithTitle:T(@"Remove") target:self action:@selector(outlinesRemove:)];
    _outlinesRemove.identifier = @"settings.outlines.remove";
    NSStackView *have = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:T(@"Downloaded:")], _outlinesHave, _outlinesRemove ]];
    have.spacing = 8;
    _outlinesSummary = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _outlinesSummary.identifier = @"settings.outlines.summary";
    [self fillOutlines];
    return sectionStack(@[ sectionTitle(@"POTA Parks"), help, _potaUpdate, _potaStatus, outlinesTitle, outlinesHelp, outlinesRow, _outlinesStatus, have,
                           _outlinesSummary ],
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
        _outlinesStatus.textColor = NSColor.secondaryLabelColor;
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
    _outlinesStatus.textColor = NSColor.secondaryLabelColor;
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
            me->_outlinesStatus.textColor = NSColor.secondaryLabelColor;
        },
        ^(BOOL ok, NSString *message) {
            ADIFSettingsPanel *me = weakSelf;
            if (!me) return;
            [me fillOutlines];
            NSInteger at = [me->_outlinesHave indexOfItemWithRepresentedObject:chosen];
            if (at >= 0) [me->_outlinesHave selectItemAtIndex:at];  // the one just downloaded
            me->_outlinesStatus.stringValue = message;
            me->_outlinesStatus.textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
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
    _potaStatus.textColor = NSColor.secondaryLabelColor;
    if (self.onPotaUpdate) self.onPotaUpdate();
}

- (void)setPotaStatus:(NSString *)text ok:(BOOL)ok {
    [self fillOutlines];  // the list's locations (it may have just been downloaded)
    _potaUpdate.enabled = YES;
    _potaStatus.stringValue = T(text);
    _potaStatus.textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
}

- (NSView *)iotaSection {
    NSTextField *help = wrapping(@"Draws IOTA's island groups on the Map (Overlays: IOTA), with the groups in your log filled in. "
                                 @"The group list is \u00A9 RSGB and IOTA Ltd, who allow downloading it for your own personal, "
                                 @"non-commercial use, so ADIF Lint doesn't include it: Download fetches it from iota-world.org "
                                 @"(about 290 KB) into the plugin's settings folder on this Mac. Download again to update it.",
                                 NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _iotaUpdate = [NSButton buttonWithTitle:T(@"Download") target:self action:@selector(iotaUpdate:)];
    _iotaStatus = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    return sectionStack(@[ sectionTitle(@"IOTA Groups"), help, _iotaUpdate, _iotaStatus ], @"settings.iota");
}

- (void)iotaUpdate:(id)sender {
    _iotaUpdate.enabled = NO;
    _iotaStatus.stringValue = T(@"Downloading IOTA's group list...");
    _iotaStatus.textColor = NSColor.secondaryLabelColor;
    if (self.onIotaUpdate) self.onIotaUpdate();
}

- (void)setIotaStatus:(NSString *)text ok:(BOOL)ok {
    _iotaUpdate.enabled = YES;
    _iotaStatus.stringValue = T(text);
    _iotaStatus.textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
}

- (void)countryUpdate:(id)sender {
    _countryUpdate.enabled = NO;
    [self setCountryStatus:@"Downloading the newest country file..." ok:YES];
    if (self.onCountryUpdate) self.onCountryUpdate();
}

- (void)setCountryStatus:(NSString *)text ok:(BOOL)ok {
    _countryUpdate.enabled = YES;
    _countryStatus.stringValue = T(text);
    _countryStatus.textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
}

- (NSView *)sectionFor:(ADIFSource)source {
    NSTextField *title = [NSTextField labelWithString:T(ADIFSourceName(source))];
    title.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize + 1];
    NSTextField *help = wrapping(ADIFSourceCredentialHelp(source), NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);

    BOOL apiKey = ADIFSourceCredentialKind(source) == ADIFCredentialAPIKey;
    NSTextField *user = [NSTextField textFieldWithString:@""];
    user.placeholderString = ADIFSourceUserLabel(source);
    NSSecureTextField *secret = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    secret.placeholderString = ADIFSourceSecretLabel(source);
    for (NSTextField *f in @[ user, secret ]) [f.widthAnchor constraintEqualToConstant:300].active = YES;
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[ [NSTextField labelWithString:colon(ADIFSourceUserLabel(source))], user ],
        @[ [NSTextField labelWithString:colon(ADIFSourceSecretLabel(source))], secret ],
    ]];
    grid.rowSpacing = 6;
    grid.columnSpacing = 8;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:0].width = labelColumnWidth();
    [grid rowAtIndex:0].hidden = apiKey;

    NSButton *save = [NSButton buttonWithTitle:T(@"Save") target:self action:@selector(save:)];
    NSButton *test = [NSButton buttonWithTitle:T(@"Test Sign-In") target:self action:@selector(test:)];
    test.hidden = !ADIFSourceCanTest(source);
    NSButton *remove = [NSButton buttonWithTitle:T(@"Remove") target:self action:@selector(remove:)];
    for (NSButton *b in @[ save, test, remove ]) b.tag = source;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ save, test, remove ]];
    buttons.spacing = 8;
    NSTextField *status = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);

    NSStackView *section = [NSStackView stackViewWithViews:@[ title, help, grid, buttons, status ]];
    section.orientation = NSUserInterfaceLayoutOrientationVertical;
    section.alignment = NSLayoutAttributeLeading;
    section.spacing = 8;
    [section setCustomSpacing:4 afterView:title];
    section.identifier = [NSString stringWithFormat:@"settings.source.%ld", (long)source];

    [_user addObject:user];
    [_secret addObject:secret];
    [_status addObject:status];
    return section;
}

- (NSPanel *)window {
    return _window;
}

- (void)setStatus:(NSString *)text ok:(BOOL)ok forSource:(NSInteger)s {
    _status[(NSUInteger)s].stringValue = T(text);
    _status[(NSUInteger)s].textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
}

- (NSView *)spotsSection {
    NSTextField *help = wrapping(@"Where the Map's Spots layer gets its spots. Nothing is fetched until you tick Show under Spots on the Map, and "
                                 @"only while the Map is open; nothing at all in Offline Mode. New QSO's Spot when logging boxes post "
                                 @"the stations you log on the DX cluster connected here.",
                                 NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _spotsSpothole = [NSButton checkboxWithTitle:T(@"Spothole: POTA, WWFF, GMA and other programs, and the DX clusters and RBN it reads "
                                                   @"(spothole.app, every 2 minutes; SOTA left out)")
                                          target:self
                                          action:@selector(spotsChanged:)];
    _spotsCluster = [NSButton checkboxWithTitle:T(@"A DX cluster (telnet), logged in with your callsign") target:self action:@selector(spotsChanged:)];
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
    for (NSTextField *f in @[ _spotsNode, _spotsLogin, _spotsCommands ]) [f.widthAnchor constraintEqualToConstant:300].active = YES;
    _spotsPsk = [NSButton checkboxWithTitle:T(@"PSKReporter: the digital-mode reception reports of your callsign or your grid square (every 5 minutes)")
                                     target:self
                                     action:@selector(spotsChanged:)];
    _spotsPskQuery = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_spotsPskQuery addItemsWithTitles:@[ T(@"Of my callsign: who heard me, and what my station heard"), T(@"Around my grid square") ]];
    _spotsPskQuery.target = self, _spotsPskQuery.action = @selector(spotsChanged:);
    _spotsPskQuery.toolTip = T(@"My callsign: the stations that heard you, and the ones your station heard if your program uploads what it hears "
                               @"(WSJT-X: Enable PSK Reporter Spotting). Around my grid square: what stations in your 4-character square heard, "
                               @"and who heard them, so there is something to see when you aren't on the air");
    _spotsPskQuery.identifier = @"settings.spots.pskQuery";
    _spotsPskCall = [NSTextField textFieldWithString:@""];
    _spotsPskCall.placeholderString = T(@"your callsign (Your Station)");
    _spotsPskCall.toolTip = T(@"The callsign whose reception reports PSKReporter gives: your own (Your Station) when empty, or another one: a "
                              @"club station, a portable call, or a friend's");
    _spotsPskCall.identifier = @"settings.spots.pskCall";
    [_spotsPskCall.widthAnchor constraintEqualToConstant:300].active = YES;
    _spotsEmail = [NSTextField textFieldWithString:@""];
    _spotsEmail.placeholderString = T(@"optional");
    _spotsEmail.toolTip = T(@"PSKReporter asks the programs that query it for a contact email address (appcontact), in case of a problem. "
                            @"Leave it empty to send none.");
    [_spotsEmail.widthAnchor constraintEqualToConstant:300].active = YES;
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[ [NSTextField labelWithString:colon(T(@"Node"))], _spotsNode ], @[ [NSTextField labelWithString:colon(T(@"Login"))], _spotsLogin ],
        @[ [NSTextField labelWithString:colon(T(@"Then send"))], _spotsCommands ]
    ]];
    NSGridView *pskGrid = [NSGridView gridViewWithViews:@[
        @[ [NSTextField labelWithString:colon(T(@"Reports"))], _spotsPskQuery ], @[ [NSTextField labelWithString:T(@"Callsign:")], _spotsPskCall ],
        @[ [NSTextField labelWithString:colon(T(@"Your email"))], _spotsEmail ]
    ]];
    for (NSGridView *g in @[ grid, pskGrid ]) {
        g.rowSpacing = 6;
        g.columnSpacing = 8;
        g.rowAlignment = NSGridRowAlignmentFirstBaseline;
        [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        [g columnAtIndex:0].width = labelColumnWidth();
    }
    NSButton *save = [NSButton buttonWithTitle:T(@"Save") target:self action:@selector(spotsChanged:)];
    _spotsStatus = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _spotsSpothole.identifier = @"settings.spots.spothole", _spotsCluster.identifier = @"settings.spots.cluster";
    _spotsPsk.identifier = @"settings.spots.psk", _spotsNode.identifier = @"settings.spots.node";
    _spotsLogin.identifier = @"settings.spots.login", _spotsCommands.identifier = @"settings.spots.commands";
    _spotsEmail.identifier = @"settings.spots.email", save.identifier = @"settings.spots.save";
    if (!_spotsObserver)
        _spotsObserver = [[NSNotificationCenter defaultCenter] addObserverForName:ADIFSpotsChangedNotification
                                                                           object:nil
                                                                            queue:nil
                                                                       usingBlock:^(NSNotification *) { [self fillSpotsStatus]; }];
    _spotsView = sectionStack(@[ sectionTitle(@"Spots"), help, _spotsSpothole, _spotsCluster, grid, _spotsPsk, pskGrid, save, _spotsStatus ],
                              @"settings.spots");
    [self fillSpots];
    return _spotsView;
}

- (void)fillSpots {
    spotfeeds::Config c = spotfeeds::config();
    _spotsSpothole.state = c.spothole ? NSControlStateValueOn : NSControlStateValueOff;
    _spotsCluster.state = c.cluster ? NSControlStateValueOn : NSControlStateValueOff;
    _spotsPsk.state = c.psk ? NSControlStateValueOn : NSControlStateValueOff;
    [_spotsPskQuery selectItemAtIndex:c.pskQuery];
    _spotsPskCall.stringValue = @(c.pskCall.c_str());
    _spotsNode.stringValue = c.host.empty() ? @"" : [NSString stringWithFormat:@"%s:%d", c.host.c_str(), c.port];
    _spotsLogin.stringValue = @(c.login.c_str());
    _spotsCommands.stringValue = @(c.commands.c_str());
    _spotsEmail.stringValue = @(c.email.c_str());
    [self fillSpotsStatus];
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
    spotfeeds::setConfig(c);
    [self fillSpots];
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
}

- (void)showSource:(NSInteger)source {
    [self refresh];
    [_window makeKeyAndOrderFront:nil];
    if (source == -3) {  // country data
        [_countryUpdate scrollRectToVisible:_countryUpdate.bounds];
        return;
    }
    if (source == -4) {  // spots
        [_spotsView scrollRectToVisible:_spotsView.bounds];
        return;
    }
    if (source >= 0 && source < ADIFSourceCount) {
        BOOL apiKey = ADIFSourceCredentialKind((ADIFSource)source) == ADIFCredentialAPIKey;
        NSTextField *first = apiKey || _user[(NSUInteger)source].stringValue.length ? _secret[(NSUInteger)source]
                                                                                     : _user[(NSUInteger)source];
        [_window makeFirstResponder:first];
        [first scrollRectToVisible:first.bounds];
    }
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
