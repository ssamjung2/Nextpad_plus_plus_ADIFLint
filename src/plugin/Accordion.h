// The sections of the Map's sidebar and selected panel: a header that opens and closes what is
// under it. Its chevron points right when the section is closed and down when it is open; the
// whole header is the target, Space or Return toggles it from the keyboard, and VoiceOver hears a
// disclosure triangle named for the section. Closing hides only the section's body: the controls
// in it keep their values.
//
// Level 0 is a card: a rounded box round the header and the body. It can have a subtle category
// tint. Level 1 is a group in one: a smaller header, with a hairline above it. Level 2 is an inset
// card: set into the one round it, with a heading band and its name and summary.
//
// After Apple's Human Interface Guidelines (read 2026-10-24): the disclosure chevron at the leading
// edge, right when closed and down when open (Disclosure controls); titles in sentence style
// (Boxes); fills and hairlines in the system's semantic colours, quaternarySystemFillColor for a
// group's area where macOS has it (14 and later); a corner inside another concentric with it, its
// radius the outer one less the space between (WWDC25 session 356). Two levels at most.
//
// Cards in an ADIFCardColumn can be moved: by dragging the header (a line shows where the card
// will go, and the column scrolls when it is held near an edge), or without a pointer, from the
// header's menu, Option-Up and Option-Down, or VoiceOver's actions (Apple's Drag and drop: the
// same change made another way). AppKit only.
#pragma once

#import <Cocoa/Cocoa.h>

@interface ADIFAccordionHeader : NSControl
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol level:(NSInteger)level;
@property(nonatomic) BOOL open;                       // setting it doesn't call onToggle
@property(nonatomic, copy) NSString *summary;         // after the title, dimmed ("3 on"); nil or "" none
@property(nonatomic, readonly) NSTextField *titleField;
@property(nonatomic) BOOL rule;                       // a hairline above it (level 1: on at first)
@property(nonatomic, copy) void (^onToggle)(BOOL open);  // clicked, or Space or Return
// The header's card can be moved in its column (ADIFCardColumn sets it): a grip shows while the
// pointer is over the header, and the menu, Option-Up and Option-Down and VoiceOver have the moves.
@property(nonatomic) BOOL reorderable;
// A control at the header's trailing end (a button of its own: a click on it doesn't toggle).
- (void)addAccessory:(NSView *)view;
- (void)toggle;
@end

@interface ADIFAccordion : NSView
- (instancetype)initWithIdentifier:(NSString *)ident title:(NSString *)title symbol:(NSString *)symbol body:(NSView *)body level:(NSInteger)level;
@property(nonatomic, readonly) ADIFAccordionHeader *header;
@property(nonatomic, readonly) NSView *body;
@property(nonatomic) BOOL open;  // shows or hides the body; doesn't call onToggle
@property(nonatomic) BOOL rule;  // the header's hairline
@property(nonatomic, strong) NSColor *cardTint;  // nil for the system's fill; else a subtle fill and edge, resolved for the current appearance
// How far the body is in from the card's sides and bottom (a card: 16). A card of cards (Layers)
// sets less: the cards in it have the padding of their own.
@property(nonatomic) CGFloat bodyInset;
@property(nonatomic, copy) void (^onToggle)(BOOL open);
@end

typedef NS_ENUM(NSInteger, ADIFCardMove) {
    ADIFCardMoveUp,        // past the card above it that is showing
    ADIFCardMoveDown,
    ADIFCardMoveToTop,
    ADIFCardMoveToBottom,
};

// Cards one under another (the Map's sidebar, its selected panel) that can be rearranged. A card
// moves only within its column. A card that is hidden (Spots, with no spots) isn't counted, and
// goes with the card showing above it; it is still there when it shows again.
@interface ADIFCardColumn : NSStackView
// The cards in order, 8 apart say, each made reorderable; the order given is the column's default.
+ (instancetype)columnWithCards:(NSArray<ADIFAccordion *> *)cards spacing:(CGFloat)spacing;
@property(nonatomic, readonly) NSArray<NSString *> *order;         // the cards' identifiers, top to bottom
@property(nonatomic, readonly) NSArray<NSString *> *defaultOrder;  // the order they were given in
@property(nonatomic, copy) void (^onReorder)(NSArray<NSString *> *order);  // after a move or a reset, not after arrangeInOrder:
// Those cards named, in the order named, then the rest as they were; names that are none of its are ignored.
- (void)arrangeInOrder:(NSArray<NSString *> *)identifiers;
- (BOOL)canMoveCard:(ADIFAccordion *)card by:(ADIFCardMove)move;
- (BOOL)moveCard:(ADIFAccordion *)card by:(ADIFCardMove)move;  // NO when it is there already
- (void)resetOrder;
// The pasteboard type of a card being dragged: its identifier.
+ (NSPasteboardType)pasteboardType;
@end

// The scroll view round a card column: a card dropped anywhere in it, even in the empty space
// below the cards, goes to the column.
@interface ADIFCardScrollView : NSScrollView
@property(nonatomic, weak) ADIFCardColumn *column;
@end

// A box inside a card for content set apart (a spot's reasons): a tinted fill with no edge, its
// corners concentric with the card's, as Apple's Boxes guidance prefers to nested borders.
@interface ADIFInsetBox : NSView
- (instancetype)initWithTint:(NSColor *)tint;  // nil: the neutral fill of a card in a card
@end

// Narrow panels' building blocks.
// A checkbox whose title wraps to the width it is given (Auto Layout sets the width; its height
// follows).
@interface ADIFWrappingCheckbox : NSButton
+ (instancetype)boxWithTitle:(NSString *)title target:(id)target action:(SEL)action;  // the title is translated
@end

// A row of controls that goes on to another line when it is too narrow for them all.
@interface ADIFWrapRow : NSView
+ (instancetype)rowWithViews:(NSArray<NSView *> *)views;
@property(nonatomic) CGFloat spacing;  // between neighbours, 8 at first; lines 6 apart
@end
