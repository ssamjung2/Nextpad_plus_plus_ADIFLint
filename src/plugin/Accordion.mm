#import "Accordion.h"

#import "L10n.h"

#include <algorithm>
#include <cmath>

// What a card being dragged puts on the pasteboard: its identifier. Private to the Map's columns.
static NSPasteboardType const kCardPasteboardType = @"io.github.ssamjung2.adiflint.card";

// Apple: a drag image once the pointer has moved about three points.
static const CGFloat kDragStartDistance = 3;

static bool reduceMotion() {
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

@interface ADIFAccordionHeader () <NSDraggingSource, NSMenuItemValidation>
@end

@implementation ADIFAccordionHeader {
    NSInteger _level;
    NSString *_spoken;
    NSImageView *_chevron, *_icon, *_grip;
    NSTextField *_summaryField;
    NSStackView *_row;
    NSTrackingArea *_tracking;
    BOOL _hover, _pressed;
    NSPoint _downAt;  // in the window, where the pointer went down
    NSMutableArray<NSView *> *_accessories;
}

- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol level:(NSInteger)level {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _level = level;
    _spoken = T(title);
    _accessories = [NSMutableArray array];
    _chevron = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _chevron.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:level == 1 ? 9 : 10 weight:NSFontWeightBold];
    _chevron.contentTintColor = NSColor.secondaryLabelColor;
    [_chevron.widthAnchor constraintEqualToConstant:12].active = YES;  // as wide either way: the title stays put
    _titleField = [NSTextField labelWithString:_spoken];
    _titleField.font = level == 2 ? [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold]
                       : level    ? [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold]
                                  : [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightBold];
    _titleField.textColor = level ? NSColor.labelColor : NSColor.secondaryLabelColor;
    _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
    [_titleField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _summaryField = [NSTextField labelWithString:@""];
    _summaryField.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize - (level ? 0 : 1)];
    _summaryField.textColor = NSColor.secondaryLabelColor;  // tertiary is too faint to read (HIG Accessibility: 4.5:1)
    _summaryField.lineBreakMode = NSLineBreakByTruncatingTail;
    _summaryField.hidden = YES;
    [_summaryField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    _row.spacing = 5;
    _row.edgeInsets = level == 2 ? NSEdgeInsetsMake(10, 12, 10, 12) : level ? NSEdgeInsetsMake(4, 2, 4, 2) : NSEdgeInsetsMake(10, 16, 8, 14);
    _row.spacing = level == 2 ? 7 : 5;
    [_row addView:_chevron inGravity:NSStackViewGravityLeading];
    if (symbol.length) {
        _icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] ?: [NSImage new]];
        _icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:level == 1 ? 11 : 12 weight:NSFontWeightRegular];
        _icon.contentTintColor = level == 2 ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
        [_icon.widthAnchor constraintEqualToConstant:18].active = YES;  // the titles line up whatever the symbol's width
        [_row addView:_icon inGravity:NSStackViewGravityLeading];
    }
    [_row addView:_titleField inGravity:NSStackViewGravityLeading];
    // A card in a card says what is set in it at its far end, as a value beside its name.
    [_row addView:_summaryField inGravity:level == 2 ? NSStackViewGravityTrailing : NSStackViewGravityLeading];
    if (level == 2) _summaryField.alignment = NSTextAlignmentRight;
    for (NSView *v in @[ _chevron, _titleField, _summaryField ]) v.accessibilityElement = NO;
    _icon.accessibilityElement = NO;
    _row.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_row];
    [NSLayoutConstraint activateConstraints:@[
        [_row.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
    self.open = YES;
    self.rule = level == 1;
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setRule:(BOOL)rule {
    _rule = rule;
    NSEdgeInsets e = _row.edgeInsets;
    e.top = _level == 1 ? (rule ? 8 : 4) : _level == 2 ? 10 : 10;
    _row.edgeInsets = e;
    [self setNeedsDisplay:YES];
}

- (void)setOpen:(BOOL)open {
    _open = open;
    _chevron.image = [NSImage imageWithSystemSymbolName:open ? @"chevron.down" : @"chevron.forward" accessibilityDescription:nil];
    [self setNeedsDisplay:YES];
}

- (void)setSummary:(NSString *)summary {
    _summary = [summary copy];
    _summaryField.stringValue = summary ?: @"";
    _summaryField.toolTip = summary.length ? summary : nil;  // whole when the heading is too narrow for it
    _summaryField.hidden = summary.length == 0;
}

- (void)addAccessory:(NSView *)view {
    [_accessories addObject:view];
    [_row addView:view inGravity:NSStackViewGravityTrailing];
}

- (void)toggle {
    self.open = !_open;
    if (self.onToggle) self.onToggle(_open);
}

// Its accessories take their own clicks; anywhere else is the header's.
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    if (!hit) return nil;
    for (NSView *a in _accessories)
        if (hit == a || [hit isDescendantOf:a]) return hit;
    return self;
}

- (void)mouseDown:(NSEvent *)event {
    _pressed = YES;
    _downAt = event.locationInWindow;
    [self setNeedsDisplay:YES];
}

// A card's header dragged a few points starts moving the card; a click anywhere on it toggles.
- (void)mouseDragged:(NSEvent *)event {
    ADIFAccordion *card = self.card;
    if (!_reorderable || !_pressed || !card) return;
    NSPoint at = event.locationInWindow;
    if (std::hypot(at.x - _downAt.x, at.y - _downAt.y) < kDragStartDistance) return;
    _pressed = NO;
    [self showGrip:YES];
    NSPasteboardItem *board = [[NSPasteboardItem alloc] init];
    [board setString:card.identifier ?: @"" forType:kCardPasteboardType];
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:board];
    [item setDraggingFrame:self.bounds contents:[self dragImage]];
    [self beginDraggingSessionWithItems:@[ item ] event:event source:self];  // the card slides back if it isn't dropped in its column
}

- (void)mouseUp:(NSEvent *)event {
    BOOL wasPressed = _pressed;
    _pressed = NO;
    [self setNeedsDisplay:YES];
    if (wasPressed && NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) [self toggle];
}

- (void)performClick:(id)sender {
    [self toggle];
}

- (void)updateTrackingAreas {
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
    [super updateTrackingAreas];
}

- (void)mouseEntered:(NSEvent *)event {
    _hover = YES;
    [self showGrip:YES];
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    _hover = NO;
    [self showGrip:NO];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty {
    CGFloat top = _rule ? 4 : 0;
    if (_rule) {  // a group's hairline, tying it to the groups above and below: one pixel
        [NSColor.separatorColor setFill];
        NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), 1 / (self.window.backingScaleFactor ?: 2)));
    }
    if (!_hover && !_pressed) return;
    [[NSColor.labelColor colorWithAlphaComponent:_pressed ? 0.1 : 0.05] setFill];
    CGFloat radius = 6;
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, top, NSWidth(self.bounds), NSHeight(self.bounds) - top) xRadius:radius yRadius:radius] fill];
}

// The keyboard: Space or Return toggles; the arrows open (right) and close (left), as in a list.
- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)canBecomeKeyView {
    return NSApp.isFullKeyboardAccessEnabled;
}

- (void)keyDown:(NSEvent *)event {
    unsigned short k = event.keyCode;
    NSEventModifierFlags mods = event.modifierFlags & (NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagShift);
    if (_reorderable && mods == NSEventModifierFlagOption && (k == 126 || k == 125)) [self moveBy:k == 126 ? ADIFCardMoveUp : ADIFCardMoveDown];
    else if (k == 49 || k == 36 || k == 76) [self toggle];
    else if (k == 124 && !_open) [self toggle];
    else if (k == 123 && _open) [self toggle];
    else [super keyDown:event];
}

- (NSRect)focusRingMaskBounds {
    return self.bounds;
}

- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:6 yRadius:6] fill];
}

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityDisclosureTriangleRole;
}

- (NSString *)accessibilityLabel {
    return _summary.length ? [NSString stringWithFormat:@"%@, %@", _spoken, _summary] : _spoken;
}

- (id)accessibilityValue {
    return @(_open ? 1 : 0);
}

- (BOOL)isAccessibilityExpanded {
    return _open;
}

- (BOOL)accessibilityPerformPress {
    [self toggle];
    return YES;
}

#pragma mark Moving the card

- (ADIFAccordion *)card {
    return [self.superview isKindOfClass:ADIFAccordion.class] ? (ADIFAccordion *)self.superview : nil;
}

- (ADIFCardColumn *)column {
    NSView *up = self.card.superview;
    return [up isKindOfClass:ADIFCardColumn.class] ? (ADIFCardColumn *)up : nil;
}

- (void)setReorderable:(BOOL)reorderable {
    if (reorderable == _reorderable) return;
    _reorderable = reorderable;
    if (reorderable && !_grip) {  // at the far end, whatever else is there; seen only while the pointer is over the header
        _grip = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"line.3.horizontal" accessibilityDescription:nil] ?: [NSImage new]];
        _grip.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightRegular];
        _grip.contentTintColor = NSColor.secondaryLabelColor;
        _grip.accessibilityElement = NO;
        _grip.toolTip = T(@"Drag to move this card");
        _grip.alphaValue = 0;
        [_grip.widthAnchor constraintEqualToConstant:14].active = YES;
        [_grip setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_row addView:_grip inGravity:NSStackViewGravityTrailing];
    }
    _grip.hidden = !reorderable;
    self.menu = reorderable ? [self cardMenu] : nil;
}

- (void)showGrip:(BOOL)show {
    _grip.alphaValue = show ? 1 : 0;
}

// The moves for those who can't or don't drag: the header's menu, its keys (shown there), VoiceOver's actions.
- (NSMenu *)cardMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    auto add = [&](NSString *title, SEL action, unichar arrow) {
        NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:arrow ? [NSString stringWithCharacters:&arrow length:1] : @""];
        item.target = self;
        if (arrow) item.keyEquivalentModifierMask = NSEventModifierFlagOption;
    };
    add(T(@"Move Up"), @selector(moveCardUp:), NSUpArrowFunctionKey);
    add(T(@"Move Down"), @selector(moveCardDown:), NSDownArrowFunctionKey);
    add(T(@"Move to Top"), @selector(moveCardToTop:), 0);
    add(T(@"Move to Bottom"), @selector(moveCardToBottom:), 0);
    [menu addItem:NSMenuItem.separatorItem];
    add(T(@"Reset Card Order"), @selector(resetCardOrder:), 0);
    return menu;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    ADIFAccordion *card = self.card;
    ADIFCardColumn *column = self.column;
    if (!card || !column) return NO;
    SEL action = item.action;
    if (action == @selector(moveCardUp:)) return [column canMoveCard:card by:ADIFCardMoveUp];
    if (action == @selector(moveCardDown:)) return [column canMoveCard:card by:ADIFCardMoveDown];
    if (action == @selector(moveCardToTop:)) return [column canMoveCard:card by:ADIFCardMoveToTop];
    if (action == @selector(moveCardToBottom:)) return [column canMoveCard:card by:ADIFCardMoveToBottom];
    if (action == @selector(resetCardOrder:)) return ![column.order isEqualToArray:column.defaultOrder];
    return YES;
}

- (BOOL)moveBy:(ADIFCardMove)move {
    ADIFAccordion *card = self.card;
    ADIFCardColumn *column = self.column;
    if (!card || !column || ![column moveCard:card by:move]) return NO;
    NSInteger place = 0, count = 0;
    for (NSView *v in column.arrangedSubviews) {
        if (v.hidden) continue;
        ++count;
        if (v == card) place = count;
    }
    NSAccessibilityPostNotificationWithUserInfo(
        self, NSAccessibilityAnnouncementRequestedNotification,
        @{ NSAccessibilityAnnouncementKey : TF(@"{name}, position {n} of {count}", @{@"name" : _spoken, @"n" : @(place), @"count" : @(count)}),
           NSAccessibilityPriorityKey : @(NSAccessibilityPriorityHigh) });
    return YES;
}

- (void)moveCardUp:(id)sender {
    [self moveBy:ADIFCardMoveUp];
}

- (void)moveCardDown:(id)sender {
    [self moveBy:ADIFCardMoveDown];
}

- (void)moveCardToTop:(id)sender {
    [self moveBy:ADIFCardMoveToTop];
}

- (void)moveCardToBottom:(id)sender {
    [self moveBy:ADIFCardMoveToBottom];
}

- (void)resetCardOrder:(id)sender {
    [self.column resetOrder];
}

- (NSString *)accessibilityHelp {
    return _reorderable ? T(@"Option-Up Arrow and Option-Down Arrow move this card") : nil;
}

- (NSArray<NSAccessibilityCustomAction *> *)accessibilityCustomActions {
    ADIFAccordion *card = self.card;
    ADIFCardColumn *column = self.column;
    if (!_reorderable || !card || !column) return @[];
    NSMutableArray<NSAccessibilityCustomAction *> *actions = [NSMutableArray array];
    NSArray<NSString *> *names = @[ T(@"Move Up"), T(@"Move Down"), T(@"Move to Top"), T(@"Move to Bottom") ];
    const ADIFCardMove moves[] = { ADIFCardMoveUp, ADIFCardMoveDown, ADIFCardMoveToTop, ADIFCardMoveToBottom };
    __weak ADIFAccordionHeader *weak = self;
    for (NSUInteger i = 0; i < names.count; i++) {
        ADIFCardMove move = moves[i];
        if (![column canMoveCard:card by:move]) continue;
        [actions addObject:[[NSAccessibilityCustomAction alloc] initWithName:names[i] handler:^BOOL {
            return [weak moveBy:move];
        }]];
    }
    return actions;
}

// What is dragged: the header on a translucent card of its own (the card itself stays put, dimmed).
- (NSImage *)dragImage {
    NSRect bounds = self.bounds;
    _hover = _pressed = NO;
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:bounds];
    [self cacheDisplayInRect:bounds toBitmapImageRep:rep];
    NSImage *content = [[NSImage alloc] initWithSize:bounds.size];
    [content addRepresentation:rep];
    NSAppearance *appearance = self.effectiveAppearance;
    return [NSImage imageWithSize:bounds.size
                          flipped:NO
                   drawingHandler:^BOOL(NSRect r) {
                       [appearance performAsCurrentDrawingAppearance:^{
                           NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5) xRadius:8 yRadius:8];
                           [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.9] setFill];
                           [card fill];
                           [NSColor.separatorColor setStroke];
                           [card stroke];
                           [content drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.92];
                       }];
                       return YES;
                   }];
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return context == NSDraggingContextWithinApplication ? NSDragOperationMove : NSDragOperationNone;
}

- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session {
    return YES;  // a card only moves: Option doesn't make it a copy
}

- (void)draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)screenPoint {
    self.card.alphaValue = 0.35;  // it stays where it is, dim, to show where it comes from
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    self.card.alphaValue = 1;
    _pressed = NO;
    _hover = self.window && NSPointInRect([self convertPoint:[self.window convertPointFromScreen:NSEvent.mouseLocation] fromView:nil], self.bounds);
    [self showGrip:_hover];
    [self setNeedsDisplay:YES];
}

@end

@implementation ADIFAccordion {
    NSInteger _level;
    NSLayoutConstraint *_openBottom, *_closedBottom, *_bodyLeading, *_bodyTrailing;
    NSColor *_cardTint;
}

- (instancetype)initWithIdentifier:(NSString *)ident title:(NSString *)title symbol:(NSString *)symbol body:(NSView *)body level:(NSInteger)level {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _level = level;
    self.identifier = ident;
    _header = [[ADIFAccordionHeader alloc] initWithTitle:title symbol:symbol level:level];
    _header.identifier = [ident stringByAppendingString:@".header"];
    _body = body;
    __weak ADIFAccordion *weak = self;
    _header.onToggle = ^(BOOL open) {
        ADIFAccordion *me = weak;
        if (!me) return;
        [me showBody:open];
        [me setNeedsDisplay:YES];
        if (me.onToggle) me.onToggle(open);
        if (open)  // what just opened, in sight: from its header down, as much as fits
            dispatch_async(dispatch_get_main_queue(), ^{
                CGFloat room = me.enclosingScrollView ? NSHeight(me.enclosingScrollView.contentView.bounds) : NSHeight(me.bounds);
                [me scrollRectToVisible:NSMakeRect(0, 0, NSWidth(me.bounds), MIN(NSHeight(me.bounds), room))];
            });
    };
    for (NSView *v in @[ _header, body ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:v];
    }
    CGFloat inset = level == 1 ? 0 : 1, side = level == 1 ? 0 : level == 2 ? 12 : 16, below = level == 1 ? 6 : 16;
    _openBottom = [body.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-below];
    _closedBottom = [_header.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-inset];
    _bodyLeading = [body.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:side];
    _bodyTrailing = [body.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-side];
    [NSLayoutConstraint activateConstraints:@[
        [_header.topAnchor constraintEqualToAnchor:self.topAnchor constant:inset],
        [_header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:inset],
        [_header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-inset],
        [body.topAnchor constraintEqualToAnchor:_header.bottomAnchor constant:level == 1 ? 2 : level == 2 ? 10 : 0],
        _bodyLeading,
        _bodyTrailing,
    ]];
    [self showBody:YES];
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)showBody:(BOOL)open {
    _body.hidden = !open;
    _closedBottom.active = NO;
    _openBottom.active = NO;
    (open ? _openBottom : _closedBottom).active = YES;
}

- (BOOL)open {
    return _header.open;
}

- (void)setOpen:(BOOL)open {
    _header.open = open;
    [self showBody:open];
    [self setNeedsDisplay:YES];
}

- (BOOL)rule {
    return _header.rule;
}

- (void)setRule:(BOOL)rule {
    _header.rule = rule;
}

- (CGFloat)bodyInset {
    return _bodyLeading.constant;
}

- (void)setBodyInset:(CGFloat)bodyInset {
    _bodyLeading.constant = bodyInset;
    _bodyTrailing.constant = -bodyInset;
    _openBottom.constant = -bodyInset;
}

- (NSColor *)cardTint {
    return _cardTint;
}

- (void)setCardTint:(NSColor *)cardTint {
    _cardTint = cardTint;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty {
    if (_level == 1) return;
    bool dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
    CGFloat pixel = 1 / (self.window.backingScaleFactor ?: 2), half = pixel / 2;
    if (_level == 0) {  // the card: the system's fill for a group's area, and a hairline edge
        NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, half, half) xRadius:10 yRadius:10];
        NSColor *fill = nil;
        NSColor *edge = NSColor.separatorColor;
        if (_cardTint) {
            fill = [_cardTint colorWithAlphaComponent:dark ? 0.24 : 0.08];
            edge = [_cardTint colorWithAlphaComponent:dark ? 0.45 : 0.18];
        } else {
            if (@available(macOS 14.0, *)) fill = NSColor.quaternarySystemFillColor;
            fill = fill ?: [NSColor.labelColor colorWithAlphaComponent:0.05];
        }
        [fill setFill];
        [card fill];
        [edge setStroke];
        card.lineWidth = pixel;
        [card stroke];
        return;
    }
    // A card in a card: set into the one round it (a shade darker, with a darker edge), its heading
    // a band of its own over a line in the same dark. Its corners are concentric with the card's:
    // that one's 10 less the 10 between, kept at 6 so it still reads as a card.
    NSColor *edge = [NSColor.blackColor colorWithAlphaComponent:dark ? 0.42 : 0.14];
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, half, half) xRadius:6 yRadius:6];
    [[NSColor.blackColor colorWithAlphaComponent:dark ? 0.16 : 0.025] setFill];
    [card fill];
    NSRect band = [self convertRect:_header.bounds fromView:_header];
    [NSGraphicsContext saveGraphicsState];
    [card addClip];
    [(dark ? [NSColor.whiteColor colorWithAlphaComponent:0.035] : [NSColor.whiteColor colorWithAlphaComponent:0.55]) setFill];
    NSRectFill(band);
    if (_header.open) {
        [edge setFill];
        NSRectFill(NSMakeRect(NSMinX(band), NSMaxY(band), NSWidth(band), pixel));
    }
    [NSGraphicsContext restoreGraphicsState];
    [edge setStroke];
    card.lineWidth = pixel;
    [card stroke];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

@end

#pragma mark - Cards that move

// Shows where a dragged card will go: a line in the accent colour in the gap between two cards.
@interface ADIFDropLine : NSView
@end

@implementation ADIFDropLine

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

- (BOOL)isAccessibilityElement {
    return NO;
}

- (void)drawRect:(NSRect)dirty {
    [NSColor.controlAccentColor setFill];
    CGFloat radius = NSHeight(self.bounds) / 2;
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:radius yRadius:radius] fill];
}

@end

// A card's top and bottom edges, as how far down the column they are (the column may or may not be flipped).
static void edges(NSView *column, NSView *card, CGFloat *top, CGFloat *bottom) {
    NSRect f = card.frame;
    *top = column.isFlipped ? NSMinY(f) : NSHeight(column.bounds) - NSMaxY(f);
    *bottom = *top + NSHeight(f);
}

@implementation ADIFCardColumn {
    NSArray<NSString *> *_defaultOrder;
    ADIFDropLine *_line;
    NSTimer *_scroller;
    NSPoint _pointer;         // where the drag is, in the window
    ADIFAccordion *_dragged;  // the card being dragged, while the drag is over this column
    ADIFAccordion *_before;   // the card it would go ahead of; nil: at the end
    BOOL _changes;            // dropping it now would change the order
}

+ (NSPasteboardType)pasteboardType {
    return kCardPasteboardType;
}

+ (instancetype)columnWithCards:(NSArray<ADIFAccordion *> *)cards spacing:(CGFloat)spacing {
    ADIFCardColumn *column = [[self alloc] initWithFrame:NSZeroRect];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeLeading;
    column.spacing = spacing;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (ADIFAccordion *card in cards) {
        [column addArrangedSubview:card];
        card.header.reorderable = YES;
        [names addObject:card.identifier ?: @""];
    }
    column->_defaultOrder = names;
    return column;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    [self registerForDraggedTypes:@[ kCardPasteboardType ]];
    return self;
}

- (void)dealloc {
    [_scroller invalidate];
}

- (NSArray<NSString *> *)defaultOrder {
    return _defaultOrder;
}

- (NSArray<NSString *> *)order {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSView *v in self.arrangedSubviews)
        if ([v isKindOfClass:ADIFAccordion.class]) [names addObject:v.identifier ?: @""];
    return names;
}

// The cards that take room, top to bottom.
- (NSArray<ADIFAccordion *> *)shownCards {
    NSMutableArray<ADIFAccordion *> *shown = [NSMutableArray array];
    for (NSView *v in self.arrangedSubviews)
        if ([v isKindOfClass:ADIFAccordion.class] && !v.hidden) [shown addObject:(ADIFAccordion *)v];
    return shown;
}

#pragma mark Moving

// Changes the arrangement, sliding the cards to their new places unless that would only distract.
- (void)rearrange:(void (^)(void))change animated:(BOOL)animated {
    if (!animated || !self.window.visible || reduceMotion()) {
        change();
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        context.allowsImplicitAnimation = YES;
        change();
        [self layoutSubtreeIfNeeded];
    }];
}

// Puts the card ahead of the one given, or last when there is none. A hidden card goes with the
// showing one above it (Spots with Quick Views): moving a card down and up again leaves everything
// as it was, hidden cards too.
- (void)place:(ADIFAccordion *)card before:(ADIFAccordion *)before animated:(BOOL)animated {
    NSMutableArray<NSView *> *rest = [self.arrangedSubviews mutableCopy];
    NSUInteger at = [rest indexOfObject:card];
    if (at == NSNotFound) return;
    NSRange group = NSMakeRange(at, 1);
    while (NSMaxRange(group) < rest.count && rest[NSMaxRange(group)].hidden) ++group.length;
    NSArray<NSView *> *moving = [rest subarrayWithRange:group];
    [rest removeObjectsInRange:group];
    NSUInteger index = before ? [rest indexOfObject:before] : rest.count;
    if (index == NSNotFound) return;
    [self rearrange:^{
        for (NSView *v in moving) [self removeArrangedSubview:v];  // they stay subviews, and keep the constraints that size them
        for (NSUInteger i = 0; i < moving.count; ++i) [self insertArrangedSubview:moving[i] atIndex:index + i];
    } animated:animated];
}

// The card a move would put this one ahead of (nil: at the end); NO when there is no card showing that way.
- (BOOL)destinationOf:(ADIFAccordion *)card by:(ADIFCardMove)move before:(ADIFAccordion **)before {
    NSArray<ADIFAccordion *> *shown = [self shownCards];
    NSUInteger at = [shown indexOfObject:card];
    if (at == NSNotFound) return NO;
    bool up = move == ADIFCardMoveUp || move == ADIFCardMoveToTop;
    if (up ? at == 0 : at + 1 >= shown.count) return NO;
    switch (move) {
        case ADIFCardMoveUp: *before = shown[at - 1]; break;
        case ADIFCardMoveToTop: *before = shown[0]; break;
        case ADIFCardMoveDown: *before = at + 2 < shown.count ? shown[at + 2] : nil; break;
        case ADIFCardMoveToBottom: *before = nil; break;
    }
    return YES;
}

- (BOOL)canMoveCard:(ADIFAccordion *)card by:(ADIFCardMove)move {
    ADIFAccordion *before = nil;
    return [self destinationOf:card by:move before:&before];
}

- (BOOL)moveCard:(ADIFAccordion *)card by:(ADIFCardMove)move {
    ADIFAccordion *before = nil;
    if (![self destinationOf:card by:move before:&before]) return NO;
    [self place:card before:before animated:YES];
    [self reordered];
    return YES;
}

- (void)reordered {
    if (_onReorder) _onReorder(self.order);
}

- (void)arrange:(NSArray<NSString *> *)identifiers animated:(BOOL)animated {
    NSMutableArray<NSView *> *rest = [self.arrangedSubviews mutableCopy], *wanted = [NSMutableArray array];
    for (NSString *ident in identifiers) {
        NSUInteger i = [rest indexOfObjectPassingTest:^BOOL(NSView *v, NSUInteger, BOOL *) {
            return [v isKindOfClass:ADIFAccordion.class] && [v.identifier isEqualToString:ident];
        }];
        if (i == NSNotFound) continue;
        [wanted addObject:rest[i]];
        [rest removeObjectAtIndex:i];
    }
    [wanted addObjectsFromArray:rest];
    [self rearrange:^{
        for (NSUInteger i = 0; i < wanted.count; ++i) {
            if (self.arrangedSubviews[i] == wanted[i]) continue;
            [self removeArrangedSubview:wanted[i]];
            [self insertArrangedSubview:wanted[i] atIndex:i];
        }
    } animated:animated];
}

- (void)arrangeInOrder:(NSArray<NSString *> *)identifiers {
    [self arrange:identifiers animated:NO];
}

- (void)resetOrder {
    if ([self.order isEqualToArray:_defaultOrder]) return;
    [self arrange:_defaultOrder animated:YES];
    [self reordered];
}

#pragma mark Dropping

// The card of this column being dragged, nil for anything else.
- (ADIFAccordion *)cardDragged:(id<NSDraggingInfo>)info {
    NSString *ident = [info.draggingPasteboard stringForType:kCardPasteboardType];
    if (!ident.length) return nil;
    for (NSView *v in self.arrangedSubviews)
        if ([v isKindOfClass:ADIFAccordion.class] && [v.identifier isEqualToString:ident]) return (ADIFAccordion *)v;
    return nil;
}

// With the pointer where it is: the card the dragged one would go ahead of (the first, below the
// pointer, whose middle is under it), and the line between the cards that shows it. Nothing shows
// where the card would stay as it is.
- (void)showDestination {
    NSArray<ADIFAccordion *> *shown = [self shownCards];
    NSUInteger at = _dragged ? [shown indexOfObject:_dragged] : NSNotFound;
    if (at == NSNotFound) {
        _changes = NO;
        _line.hidden = YES;
        return;
    }
    NSPoint p = [self convertPoint:_pointer fromView:nil];
    CGFloat y = self.isFlipped ? p.y : NSHeight(self.bounds) - p.y;
    _before = nil;
    for (ADIFAccordion *c in shown) {
        if (c == _dragged) continue;
        CGFloat top, bottom;
        edges(self, c, &top, &bottom);
        if (y < (top + bottom) / 2) {
            _before = c;
            break;
        }
    }
    _changes = _before != (at + 1 < shown.count ? shown[at + 1] : nil);
    if (!_changes) {
        _line.hidden = YES;
        return;
    }
    // Midway through the gap it would go into.
    CGFloat gap, top, bottom, unused;
    if (_before) {
        NSUInteger i = [shown indexOfObject:_before];
        edges(self, _before, &top, &unused);
        if (i) {
            edges(self, shown[i - 1], &unused, &bottom);
            gap = (bottom + top) / 2;
        } else {
            gap = top - self.spacing / 2;
        }
    } else {
        edges(self, shown.lastObject, &unused, &bottom);
        gap = bottom + self.spacing / 2;
    }
    if (!_line) {
        _line = [[ADIFDropLine alloc] initWithFrame:NSMakeRect(0, 0, 0, 3)];
        _line.hidden = YES;
    }
    if (self.subviews.lastObject != _line) [self addSubview:_line positioned:NSWindowAbove relativeTo:nil];  // over the cards, not under
    NSEdgeInsets inset = self.edgeInsets;
    CGFloat thickness = 3, topEdge = gap - thickness / 2;
    _line.frame = NSMakeRect(inset.left, self.isFlipped ? topEdge : NSHeight(self.bounds) - topEdge - thickness,
                             NSWidth(self.bounds) - inset.left - inset.right, thickness);
    _line.hidden = NO;
}

- (NSDragOperation)trackDrag:(id<NSDraggingInfo>)info {
    ADIFAccordion *card = [self cardDragged:info];
    if (!card) {  // another column's card, or something else: no drop here
        [self finishDrag];
        return NSDragOperationNone;
    }
    _dragged = card;
    _pointer = info.draggingLocation;
    [self startScrolling];
    [self showDestination];
    return NSDragOperationMove;
}

- (void)finishDrag {
    [self stopScrolling];
    _line.hidden = YES;
    _dragged = nil;
    _before = nil;
    _changes = NO;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    return [self trackDrag:info];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    return [self trackDrag:info];
}

- (void)draggingExited:(id<NSDraggingInfo>)info {
    [self finishDrag];
}

- (void)draggingEnded:(id<NSDraggingInfo>)info {
    [self finishDrag];
}

- (BOOL)wantsPeriodicDraggingUpdates {
    return NO;  // the timer scrolls it, which a drag held still can't ask for
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info {
    return [self cardDragged:info] != nil;
}

// A drop that changes nothing isn't one: the image goes back to where the card is.
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    _dragged = [self cardDragged:info];
    _pointer = info.draggingLocation;
    [self showDestination];
    ADIFAccordion *card = _dragged, *before = _before;
    BOOL changes = _changes;
    [self finishDrag];
    if (!card || !changes) return NO;
    [self place:card before:before animated:YES];
    [self reordered];
    return YES;
}

#pragma mark Scrolling while dragging

- (void)startScrolling {
    if (_scroller || !self.enclosingScrollView) return;
    __weak ADIFCardColumn *weak = self;
    _scroller = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        ADIFCardColumn *me = weak;
        if (me) [me scrollTowardPointer];
        else [timer invalidate];
    }];
    [NSRunLoop.mainRunLoop addTimer:_scroller forMode:NSRunLoopCommonModes];  // a drag runs in its own mode
}

- (void)stopScrolling {
    [_scroller invalidate];
    _scroller = nil;
}

// The pointer within a few points of the top or bottom of what shows scrolls the column that way,
// faster the nearer the edge; the card's place is found again for what is now under the pointer.
- (void)scrollTowardPointer {
    NSScrollView *scroll = self.enclosingScrollView;
    if (!_dragged || !scroll) {
        [self stopScrolling];
        return;
    }
    NSClipView *clip = scroll.contentView;
    NSRect visible = clip.bounds;
    NSPoint at = [clip convertPoint:_pointer fromView:nil];
    CGFloat fromTop = clip.isFlipped ? at.y - NSMinY(visible) : NSMaxY(visible) - at.y;
    CGFloat fromBottom = NSHeight(visible) - fromTop;
    const CGFloat zone = 44, fastest = 14;
    CGFloat step = 0;  // down is positive
    if (fromTop < zone) step = -(zone - std::max<CGFloat>(fromTop, 0)) / zone * fastest;
    else if (fromBottom < zone) step = (zone - std::max<CGFloat>(fromBottom, 0)) / zone * fastest;
    if (step == 0) return;
    NSRect wanted = visible;
    wanted.origin.y += clip.isFlipped ? step : -step;
    NSPoint origin = [clip constrainBoundsRect:wanted].origin;
    if (origin.y == visible.origin.y) return;
    [clip scrollToPoint:origin];
    [scroll reflectScrolledClipView:clip];
    [self showDestination];
}

@end

@implementation ADIFCardScrollView

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    [self registerForDraggedTypes:@[ kCardPasteboardType ]];
    return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    return [self.column draggingEntered:info];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    return [self.column draggingUpdated:info];
}

- (void)draggingExited:(id<NSDraggingInfo>)info {
    [self.column draggingExited:info];
}

- (void)draggingEnded:(id<NSDraggingInfo>)info {
    [self.column draggingEnded:info];
}

- (BOOL)wantsPeriodicDraggingUpdates {
    return NO;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info {
    return [self.column prepareForDragOperation:info];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    return [self.column performDragOperation:info];
}

@end

@implementation ADIFInsetBox {
    NSColor *_tint;
}

- (instancetype)initWithTint:(NSColor *)tint {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _tint = tint;
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirty {
    bool dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
    NSColor *fill = _tint ? [_tint colorWithAlphaComponent:dark ? 0.14 : 0.10] : [NSColor.blackColor colorWithAlphaComponent:dark ? 0.16 : 0.025];
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

@end

@implementation ADIFWrappingCheckbox {
    CGFloat _laidOutWidth;
}

+ (instancetype)boxWithTitle:(NSString *)title target:(id)target action:(SEL)action {
    ADIFWrappingCheckbox *b = [[ADIFWrappingCheckbox alloc] initWithFrame:NSZeroRect];
    [b setButtonType:NSButtonTypeSwitch];
    b.title = T(title);
    b.target = target;
    b.action = action;
    ((NSButtonCell *)b.cell).wraps = YES;
    b.cell.lineBreakMode = NSLineBreakByWordWrapping;
    b.cell.usesSingleLineMode = NO;
    [b setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return b;
}

- (NSSize)intrinsicContentSize {
    CGFloat w = NSWidth(self.bounds);
    if (w < 40) return [super intrinsicContentSize];  // not laid out yet: one line
    return NSMakeSize(NSViewNoIntrinsicMetric, std::ceil([self.cell cellSizeForBounds:NSMakeRect(0, 0, w, 10000)].height));
}

- (void)layout {
    [super layout];
    if (NSWidth(self.bounds) != _laidOutWidth) {
        _laidOutWidth = NSWidth(self.bounds);
        [self invalidateIntrinsicContentSize];
    }
}

@end

@implementation ADIFWrapRow {
    CGFloat _height;
}

+ (instancetype)rowWithViews:(NSArray<NSView *> *)views {
    ADIFWrapRow *r = [[ADIFWrapRow alloc] initWithFrame:NSZeroRect];
    r.spacing = 8;
    for (NSView *v in views) {
        v.translatesAutoresizingMaskIntoConstraints = YES;
        [r addSubview:v];
    }
    r->_height = [r place:NO width:10000];
    return r;
}

- (BOOL)isFlipped {
    return YES;
}

// Lays the views out in lines `width` wide (each line's views centred on it); its height.
- (CGFloat)place:(BOOL)apply width:(CGFloat)width {
    CGFloat y = 0;
    NSMutableArray<NSView *> *line = [NSMutableArray array];
    CGFloat x = 0, tall = 0;
    auto finish = [&]() {
        if (apply) {
            CGFloat at = 0;
            for (NSView *v in line) {
                NSSize s = v.fittingSize;
                v.frame = NSMakeRect(at, y + std::floor((tall - s.height) / 2), std::min(s.width, width), s.height);
                at += s.width + self.spacing;
            }
        }
        y += tall;
        [line removeAllObjects];
        x = 0, tall = 0;
    };
    for (NSView *v in self.subviews) {
        if (v.hidden) continue;
        NSSize s = v.fittingSize;
        if (line.count && x + s.width > width) {
            finish();
            y += 6;
        }
        [line addObject:v];
        x += s.width + self.spacing;
        tall = std::max(tall, s.height);
    }
    if (line.count) finish();
    return y;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, _height);
}

- (void)layout {
    [super layout];
    CGFloat h = [self place:YES width:NSWidth(self.bounds)];
    if (h != _height) {
        _height = h;
        [self invalidateIntrinsicContentSize];
    }
}

@end
