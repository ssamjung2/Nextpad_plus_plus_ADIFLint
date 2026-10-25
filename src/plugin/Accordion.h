// The sections of the Map's sidebar and selected panel: a header that opens and closes what is
// under it. Its chevron points right when the section is closed and down when it is open; the
// whole header is the target, Space or Return toggles it from the keyboard, and VoiceOver hears a
// disclosure triangle named for the section. Closing hides only the section's body: the controls
// in it keep their values.
//
// Level 0 is a card: a rounded, tinted box round the header and the body. Level 1 is a group in
// one: a smaller header, with a hairline above it. Level 2 is a card in a card (Style Options' and
// Settings' groups): set into the one round it (a shade darker, with a darker edge), a heading band
// with an icon, its name and what is set in it, so the setting wanted is quick to find.
//
// After Apple's Human Interface Guidelines (read 2026-10-24): the disclosure chevron at the leading
// edge, right when closed and down when open (Disclosure controls); titles in sentence style
// (Boxes); fills and hairlines in the system's semantic colours, quaternarySystemFillColor for a
// group's area where macOS has it (14 and later); a corner inside another concentric with it, its
// radius the outer one less the space between (WWDC25 session 356). Two levels at most.
// AppKit only.
#pragma once

#import <Cocoa/Cocoa.h>

@interface ADIFAccordionHeader : NSControl
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol level:(NSInteger)level;
@property(nonatomic) BOOL open;                       // setting it doesn't call onToggle
@property(nonatomic, copy) NSString *summary;         // after the title, dimmed ("3 on"); nil or "" none
@property(nonatomic, readonly) NSTextField *titleField;
@property(nonatomic) BOOL rule;                       // a hairline above it (level 1: on at first)
@property(nonatomic, copy) void (^onToggle)(BOOL open);  // clicked, or Space or Return
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
@property(nonatomic, copy) void (^onToggle)(BOOL open);
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
