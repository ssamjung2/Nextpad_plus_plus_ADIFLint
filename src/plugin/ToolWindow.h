// A general window for the log tools: a "Log:" line, rows of options, an
// optional headline, a status line, a table (sortable, filterable, with
// optional tick boxes) or a read-only text report, and a row of buttons.
// AppKit only; LogTools.mm builds each tool from it and does the ADIF work.
//
// Rows are given and reported by their index in the vector passed to
// setRows (the "model row"), whatever the current sort and filter.
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>

struct ADIFToolColumn {
    std::string ident, title;
    CGFloat width = 80;
};

// Severity colours: -1 plain, 0 blue (note), 1 orange (warning), 2 red (error), 3 green (done).
NSColor *ADIFSeverityColor(int severity);
NSString *ADIFString(const std::string &s);  // UTF-8, falling back to Latin-1
std::string ADIFStd(NSString *s);
// Table order: plain numbers by value, other text with digit runs by value, ignoring case.
int ADIFNaturalCompare(const std::string &a, const std::string &b);

// Small controls for option rows.
NSTextField *ADIFLabel(NSString *text);
NSTextField *ADIFTextField(NSString *placeholder, CGFloat width);
NSPopUpButton *ADIFPopup(NSArray<NSString *> *items);
NSButton *ADIFCheckbox(NSString *title, BOOL on);
NSComboBox *ADIFComboBox(NSArray<NSString *> *items, CGFloat width);
// Run `block` when the control sends its action (popup choice, checkbox click,
// search text...). The control keeps the block alive.
void ADIFOnAction(NSControl *control, void (^block)(void));
// The same for a menu item.
void ADIFBlockMenuItem(NSMenuItem *item, void (^block)(void));

@interface ADIFToolWindow : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>

@property(nonatomic, readonly) NSPanel *window;
@property(nonatomic, copy) void (^onActivateRow)(NSInteger row);  // double-click
@property(nonatomic, copy) void (^onSelectionChanged)(void);  // the user changed the selection (never for restores)
@property(nonatomic, copy) void (^onTicksChanged)(void);
@property(nonatomic, copy) void (^onClose)(void);
// A cell of an editable column was edited (model row, column index, new text).
@property(nonatomic, copy) void (^onEditCell)(NSInteger row, size_t column, NSString *text);
// The user sorted by a column (-1: unsorted).
@property(nonatomic, copy) void (^onSortChanged)(NSInteger column, BOOL ascending);

// `headline`: reserve a line of large text above the status.
- (instancetype)initWithTitle:(NSString *)title size:(NSSize)size headline:(BOOL)headline;

- (void)setTarget:(NSString *)text;  // e.g. "Log: US-7929.adi"
- (NSStackView *)addOptionRow:(NSArray<NSView *> *)views;  // hide the returned row to remove it from the layout
- (NSButton *)addButton:(NSString *)title trailing:(BOOL)trailing action:(void (^)(void))action;
- (void)setDefaultButton:(NSButton *)button;  // Return presses it

- (void)setHeadline:(NSString *)text severity:(int)severity;
- (void)setStatus:(NSString *)text severity:(int)severity;

- (void)setColumns:(const std::vector<ADIFToolColumn> &)columns checkboxes:(BOOL)checkboxes sortable:(BOOL)sortable;
// Replaces the rows; tick boxes start ticked and the selection is cleared.
// `severities` (optional) colours each row's text.
- (void)setRows:(const std::vector<std::vector<std::string>> &)rows severities:(const std::vector<int> &)severities;
// The same with `keys` (one per row) naming what each row shows, so the
// selection stays on the same thing when rows come and go. `ticks` (optional)
// gives new rows' tick boxes; with keepTicks a row whose key was shown before
// keeps the tick the user gave it.
- (void)setRows:(const std::vector<std::vector<std::string>> &)rows
     severities:(const std::vector<int> &)severities
           keys:(const std::vector<std::string> &)keys
          ticks:(const std::vector<bool> &)ticks
      keepTicks:(BOOL)keepTicks;
- (void)setFilter:(NSString *)text;  // show rows with a cell containing the text (case-insensitive)
- (std::vector<NSInteger>)shownRows;     // model rows in display order
- (std::vector<NSInteger>)selectedRows;  // model rows
- (std::vector<bool>)ticked;             // per model row
- (void)setAllTicked:(BOOL)ticked;
- (void)setTicked:(const std::vector<bool> &)ticked;  // per model row
- (void)setCell:(const std::string &)text row:(NSInteger)row column:(size_t)column;  // model row; keeps ticks and sort
- (void)setRowSeverity:(int)severity row:(NSInteger)row;
- (void)selectRow:(NSInteger)row;        // model row; scrolls to it
// Columns whose cells can be edited (double-click one); double-click elsewhere activates the row.
- (void)setEditableColumns:(const std::vector<size_t> &)columns;
- (void)setSortColumn:(NSInteger)column ascending:(BOOL)ascending;  // -1: unsorted
- (void)setHeaderMenu:(NSMenu *)menu;  // the column headings' right-click menu

// Show a monospaced, read-only report instead of the table.
- (void)setText:(NSString *)text;
- (NSString *)text;

- (void)show;

@end
