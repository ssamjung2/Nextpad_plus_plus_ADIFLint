#import "Accordion.h"

#import "L10n.h"

#include <algorithm>
#include <cmath>

@implementation ADIFAccordionHeader {
    NSInteger _level;
    NSString *_spoken;
    NSImageView *_chevron, *_icon;
    NSTextField *_summaryField;
    NSStackView *_row;
    NSTrackingArea *_tracking;
    BOOL _hover, _pressed;
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
    _row.edgeInsets = level == 2 ? NSEdgeInsetsMake(10, 12, 10, 12) : level ? NSEdgeInsetsMake(4, 2, 4, 2) : NSEdgeInsetsMake(7, 8, 7, 6);
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
    e.top = _level == 1 ? (rule ? 8 : 4) : _level == 2 ? 10 : 7;
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
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    _pressed = NO;
    [self setNeedsDisplay:YES];
    if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) [self toggle];
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
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    _hover = NO;
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
    if (k == 49 || k == 36 || k == 76) [self toggle];
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

@end

@implementation ADIFAccordion {
    NSInteger _level;
    NSLayoutConstraint *_openBottom, *_closedBottom;
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
    CGFloat inset = level == 1 ? 0 : 1, side = level == 1 ? 0 : level == 2 ? 12 : 10, below = level == 1 ? 6 : 12;
    _openBottom = [body.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-below];
    _closedBottom = [_header.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-inset];
    [NSLayoutConstraint activateConstraints:@[
        [_header.topAnchor constraintEqualToAnchor:self.topAnchor constant:inset],
        [_header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:inset],
        [_header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-inset],
        [body.topAnchor constraintEqualToAnchor:_header.bottomAnchor constant:level == 1 ? 2 : level == 2 ? 10 : 0],
        [body.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:side],
        [body.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-side],
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

- (void)drawRect:(NSRect)dirty {
    if (_level == 1) return;
    bool dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
    CGFloat pixel = 1 / (self.window.backingScaleFactor ?: 2), half = pixel / 2;
    if (_level == 0) {  // the card: the system's fill for a group's area, and a hairline edge
        NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, half, half) xRadius:10 yRadius:10];
        NSColor *fill = nil;
        if (@available(macOS 14.0, *)) fill = NSColor.quaternarySystemFillColor;
        [(fill ?: [NSColor.labelColor colorWithAlphaComponent:0.05]) setFill];
        [card fill];
        [NSColor.separatorColor setStroke];
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
