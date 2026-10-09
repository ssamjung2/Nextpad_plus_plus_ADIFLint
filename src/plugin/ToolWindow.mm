#import "ToolWindow.h"

#import <objc/runtime.h>

#include "adif_tools.h"

#include <algorithm>
#include <cstdlib>
#include <map>
#include <set>

NSColor *ADIFSeverityColor(int severity) {
    switch (severity) {
        case 3: return NSColor.systemGreenColor;
        case 2: return NSColor.systemRedColor;
        case 1: return NSColor.systemOrangeColor;
        case 0: return NSColor.systemBlueColor;
        default: return NSColor.labelColor;
    }
}

NSString *ADIFString(const std::string &s) {
    NSString *r = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return r ?: [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSISOLatin1StringEncoding];
}

std::string ADIFStd(NSString *s) {
    const char *p = s.UTF8String;
    return p ? std::string(p) : std::string();
}

NSTextField *ADIFLabel(NSString *text) { return [NSTextField labelWithString:text ?: @""]; }

NSTextField *ADIFTextField(NSString *placeholder, CGFloat width) {
    NSTextField *f = [NSTextField textFieldWithString:@""];
    f.placeholderString = placeholder;
    [f.widthAnchor constraintEqualToConstant:width].active = YES;
    return f;
}

NSPopUpButton *ADIFPopup(NSArray<NSString *> *items) {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [p addItemsWithTitles:items];
    return p;
}

NSButton *ADIFCheckbox(NSString *title, BOOL on) {
    NSButton *b = [NSButton checkboxWithTitle:title target:nil action:nil];
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    return b;
}

NSComboBox *ADIFComboBox(NSArray<NSString *> *items, CGFloat width) {
    NSComboBox *c = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    [c addItemsWithObjectValues:items];
    c.numberOfVisibleItems = 16;
    c.completes = YES;
    [c.widthAnchor constraintEqualToConstant:width].active = YES;
    return c;
}

@interface ADIFBlockTarget : NSObject
@property(nonatomic, copy) void (^block)(void);
- (void)fire:(id)sender;
@end

@implementation ADIFBlockTarget
- (void)fire:(id)sender {
    if (self.block) self.block();
}
@end

void ADIFOnAction(NSControl *control, void (^block)(void)) {
    static char kKey;
    ADIFBlockTarget *t = [[ADIFBlockTarget alloc] init];
    t.block = block;
    objc_setAssociatedObject(control, &kKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    control.target = t;
    control.action = @selector(fire:);
}

void ADIFBlockMenuItem(NSMenuItem *item, void (^block)(void)) {
    static char kKey;
    ADIFBlockTarget *t = [[ADIFBlockTarget alloc] init];
    t.block = block;
    objc_setAssociatedObject(item, &kKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    item.target = t;
    item.action = @selector(fire:);
}

// Numbers compare as numbers ("7.074" < "14.074"); otherwise digit runs compare
// by value and letters case-insensitively ("K1ABC" < "K10ABC").
int ADIFNaturalCompare(const std::string &a, const std::string &b) { return adif::naturalCompare(a, b); }

static bool containsNoCase(const std::string &hay, const std::string &upperNeedle) {
    if (upperNeedle.empty()) return true;
    if (hay.size() < upperNeedle.size()) return false;
    for (size_t i = 0; i + upperNeedle.size() <= hay.size(); ++i) {
        size_t k = 0;
        while (k < upperNeedle.size() && std::toupper((unsigned char)hay[i + k]) == (unsigned char)upperNeedle[k]) ++k;
        if (k == upperNeedle.size()) return true;
    }
    return false;
}

@implementation ADIFToolWindow {
    NSPanel *_window;
    NSTextField *_target, *_headline, *_status;
    NSStackView *_options, *_bottom;
    NSScrollView *_scroll;
    NSTableView *_table;
    NSTextView *_textView;
    std::vector<ADIFToolColumn> _columns;
    bool _checkboxes;
    std::vector<std::vector<std::string>> _rows;
    std::vector<int> _severity;
    std::vector<bool> _ticked;
    std::vector<std::string> _keys;  // per model row, or empty
    std::vector<size_t> _editable;   // editable column indexes
    bool _quiet;                     // a selection change made here, not by the user
    std::vector<NSInteger> _shown;  // display order -> model row
    std::string _filter;            // upper case
    NSMutableArray *_actions;       // button blocks, by tag
}

- (instancetype)initWithTitle:(NSString *)title size:(NSSize)size headline:(BOOL)headline {
    if (!(self = [super init])) return nil;
    _actions = [NSMutableArray array];
    _window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                   NSWindowStyleMaskResizable
                                           backing:NSBackingStoreBuffered
                                             defer:YES];
    _window.title = title;
    _window.floatingPanel = YES;
    _window.hidesOnDeactivate = YES;
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    _window.contentMinSize = NSMakeSize(MIN(size.width, 520), MIN(size.height, 320));
    [_window center];
    NSView *root = _window.contentView;

    _target = [NSTextField labelWithString:@""];
    _target.textColor = NSColor.secondaryLabelColor;
    _target.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_target setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    _options = [[NSStackView alloc] initWithFrame:NSZeroRect];
    _options.orientation = NSUserInterfaceLayoutOrientationVertical;
    _options.alignment = NSLayoutAttributeLeading;
    _options.spacing = 8;

    if (headline) {
        _headline = [NSTextField wrappingLabelWithString:@""];
        _headline.font = [NSFont systemFontOfSize:NSFont.systemFontSize + 4 weight:NSFontWeightSemibold];
        _headline.maximumNumberOfLines = 2;
        [_headline setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    _status = [NSTextField wrappingLabelWithString:@""];
    _status.maximumNumberOfLines = 4;
    [_status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _table.dataSource = self;
    _table.delegate = self;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.allowsMultipleSelection = YES;
    _table.rowHeight = 20;
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _table.target = self;
    _table.doubleAction = @selector(doubleClicked:);
    if (@available(macOS 11.0, *)) _table.style = NSTableViewStyleFullWidth;
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _table;
    _scroll.hasVerticalScroller = YES;
    _scroll.hasHorizontalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.borderType = NSBezelBorder;

    _bottom = [[NSStackView alloc] initWithFrame:NSZeroRect];
    _bottom.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    NSButton *close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closePressed:)];
    close.keyEquivalent = @"\033";
    [_bottom addView:close inGravity:NSStackViewGravityTrailing];

    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObjects:_target, _options, nil];
    if (_headline) [views addObject:_headline];
    [views addObjectsFromArray:@[ _status, _scroll, _bottom ]];
    for (NSView *v in views) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:v];
    }
    const CGFloat m = 14;
    NSMutableArray *c = [NSMutableArray array];
    NSView *above = nil;
    for (NSView *v in views) {
        [c addObject:[v.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m]];
        if (v == _options) [c addObject:[v.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m]];
        else [c addObject:[v.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m]];
        [c addObject:above ? [v.topAnchor constraintEqualToAnchor:above.bottomAnchor constant:v == _scroll ? 6 : 10]
                           : [v.topAnchor constraintEqualToAnchor:root.topAnchor constant:m]];
        above = v;
    }
    [c addObject:[_bottom.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-m]];
    [c addObject:[_scroll.heightAnchor constraintGreaterThanOrEqualToConstant:120]];
    [NSLayoutConstraint activateConstraints:c];
    return self;
}

- (NSPanel *)window {
    return _window;
}

- (void)setTarget:(NSString *)text {
    _target.stringValue = text ?: @"";
}

- (NSStackView *)addOptionRow:(NSArray<NSView *> *)views {
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeFirstBaseline;
    row.spacing = 6;
    [_options addArrangedSubview:row];
    return row;
}

- (NSButton *)addButton:(NSString *)title trailing:(BOOL)trailing action:(void (^)(void))action {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:@selector(buttonPressed:)];
    b.tag = (NSInteger)_actions.count;
    [_actions addObject:action ? [action copy] : [NSNull null]];
    if (trailing) [_bottom addView:b inGravity:NSStackViewGravityTrailing];  // after Close: rightmost
    else [_bottom addView:b inGravity:NSStackViewGravityLeading];
    return b;
}

- (void)setDefaultButton:(NSButton *)button {
    for (NSView *v in _bottom.views)
        if ([v isKindOfClass:NSButton.class] && [((NSButton *)v).keyEquivalent isEqualToString:@"\r"])
            ((NSButton *)v).keyEquivalent = @"";
    button.keyEquivalent = @"\r";
}

- (void)buttonPressed:(NSButton *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)_actions.count) return;
    id block = _actions[(NSUInteger)sender.tag];
    if (block != [NSNull null]) ((void (^)(void))block)();
}

- (void)setHeadline:(NSString *)text severity:(int)severity {
    _headline.stringValue = text ?: @"";
    _headline.textColor = ADIFSeverityColor(severity);
}

- (void)setStatus:(NSString *)text severity:(int)severity {
    _status.stringValue = text ?: @"";
    _status.textColor = severity < 0 ? NSColor.secondaryLabelColor : ADIFSeverityColor(severity);
}

// ── Table ───────────────────────────────────────────────────────────────────

- (void)setColumns:(const std::vector<ADIFToolColumn> &)columns checkboxes:(BOOL)checkboxes sortable:(BOOL)sortable {
    // Quiet: new columns are not the user choosing "no sort" (the Log Table remembers its sort).
    _quiet = true;
    _scroll.documentView = _table;
    while (_table.tableColumns.count) [_table removeTableColumn:_table.tableColumns.lastObject];
    _columns = columns;
    _checkboxes = checkboxes;
    if (checkboxes) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"__use"];
        col.title = @"";
        col.width = 24;
        col.minWidth = 24;
        [_table addTableColumn:col];
    }
    for (size_t i = 0; i < columns.size(); ++i) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%zu", i]];
        col.title = ADIFString(columns[i].title);
        col.width = columns[i].width;
        col.minWidth = 30;
        col.headerToolTip = ADIFString(columns[i].ident);
        if (sortable) col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:col.identifier ascending:YES];
        [_table addTableColumn:col];
    }
    _table.sortDescriptors = @[];
    _quiet = false;
    _rows.clear();
    [self rebuild];
}

- (void)setRows:(const std::vector<std::vector<std::string>> &)rows severities:(const std::vector<int> &)severities {
    static const std::vector<std::string> noKeys;
    static const std::vector<bool> noTicks;
    [self setRows:rows severities:severities keys:noKeys ticks:noTicks keepTicks:NO];
}

- (void)setRows:(const std::vector<std::vector<std::string>> &)rows
     severities:(const std::vector<int> &)severities
           keys:(const std::vector<std::string> &)keys
          ticks:(const std::vector<bool> &)ticks
      keepTicks:(BOOL)keepTicks {
    // What was selected and ticked, by key.
    std::set<std::string> selectedKeys;
    std::map<std::string, bool> oldTicks;
    if (_keys.size() == _rows.size()) {
        for (NSInteger r : [self selectedRows]) selectedKeys.insert(_keys[(size_t)r]);
        for (size_t i = 0; i < _keys.size() && i < _ticked.size(); ++i) oldTicks[_keys[i]] = _ticked[i];
    }
    bool keyed = keys.size() == rows.size();
    _rows = rows;
    _severity = severities;
    _keys = keyed ? keys : std::vector<std::string>();
    _ticked.assign(rows.size(), true);
    for (size_t i = 0; i < rows.size(); ++i) {
        if (i < ticks.size()) _ticked[i] = ticks[i];
        if (keyed && keepTicks) {
            auto it = oldTicks.find(keys[i]);
            if (it != oldTicks.end()) _ticked[i] = it->second;
        }
    }
    std::vector<NSInteger> select;
    if (keyed)
        for (size_t i = 0; i < rows.size(); ++i)
            if (selectedKeys.count(keys[i])) select.push_back((NSInteger)i);
    [self rebuildSelecting:select];
}

- (void)setFilter:(NSString *)text {
    std::string f = ADIFStd(text);
    for (char &ch : f) ch = (char)std::toupper((unsigned char)ch);
    if (f == _filter) return;
    _filter = f;
    [self rebuild];
}

// Recompute the shown rows (filter, then sort), keeping the selection.
- (void)rebuild {
    [self rebuildSelecting:[self selectedRows]];
}

- (void)rebuildSelecting:(std::vector<NSInteger>)selected {
    _shown.clear();
    for (size_t r = 0; r < _rows.size(); ++r) {
        bool keep = _filter.empty();
        for (size_t c = 0; !keep && c < _rows[r].size(); ++c) keep = containsNoCase(_rows[r][c], _filter);
        if (keep) _shown.push_back((NSInteger)r);
    }
    NSSortDescriptor *sd = _table.sortDescriptors.firstObject;
    if (sd) {
        size_t col = (size_t)sd.key.integerValue;
        bool asc = sd.ascending;
        std::stable_sort(_shown.begin(), _shown.end(), [&](NSInteger x, NSInteger y) {
            const std::string &a = col < _rows[(size_t)x].size() ? _rows[(size_t)x][col] : std::string();
            const std::string &b = col < _rows[(size_t)y].size() ? _rows[(size_t)y][col] : std::string();
            if (self.compareCells) {  // the caller's order, with empty cells last either way
                if (a.empty() != b.empty()) return b.empty();
                int c = self.compareCells(col, a, b);
                return asc ? c < 0 : c > 0;
            }
            int c = ADIFNaturalCompare(a, b);
            return asc ? c < 0 : c > 0;
        });
    }
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (size_t i = 0; i < _shown.size(); ++i)
        if (std::find(selected.begin(), selected.end(), _shown[i]) != selected.end()) [set addIndex:i];
    bool wasQuiet = _quiet;  // a caller may be quiet already (setColumns)
    _quiet = true;           // restoring the selection is not the user choosing a row
    [_table reloadData];
    [_table selectRowIndexes:set byExtendingSelection:NO];
    _quiet = wasQuiet;
}

- (std::vector<NSInteger>)shownRows {
    return _shown;
}

- (std::vector<NSInteger>)selectedRows {
    std::vector<NSInteger> out;
    NSIndexSet *set = _table.selectedRowIndexes;
    for (NSUInteger i = set.firstIndex; i != NSNotFound; i = [set indexGreaterThanIndex:i])
        if (i < _shown.size()) out.push_back(_shown[i]);
    return out;
}

- (std::vector<bool>)ticked {
    return _ticked;
}

- (void)setAllTicked:(BOOL)ticked {
    _ticked.assign(_rows.size(), ticked);
    [_table reloadData];
    if (self.onTicksChanged) self.onTicksChanged();
}

- (void)setTicked:(const std::vector<bool> &)ticked {
    for (size_t i = 0; i < _ticked.size() && i < ticked.size(); ++i) _ticked[i] = ticked[i];
    [_table reloadData];
}

- (void)setCell:(const std::string &)text row:(NSInteger)row column:(size_t)column {
    if (row < 0 || (size_t)row >= _rows.size()) return;
    if (_rows[(size_t)row].size() <= column) _rows[(size_t)row].resize(column + 1);
    _rows[(size_t)row][column] = text;
    for (size_t i = 0; i < _shown.size(); ++i)
        if (_shown[i] == row)
            [_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:i]
                              columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _table.numberOfColumns)]];
}

- (void)setRowSeverity:(int)severity row:(NSInteger)row {
    if (row < 0 || (size_t)row >= _rows.size()) return;
    if (_severity.size() < _rows.size()) _severity.resize(_rows.size(), -1);
    _severity[(size_t)row] = severity;
    [self setCell:_rows[(size_t)row].empty() ? std::string() : _rows[(size_t)row][0] row:row column:0];
}

- (void)selectRow:(NSInteger)row {
    for (size_t i = 0; i < _shown.size(); ++i) {
        if (_shown[i] != row) continue;
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
        [_table scrollRowToVisible:(NSInteger)i];
        return;
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_shown.size();
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (row < 0 || (size_t)row >= _shown.size()) return nil;
    size_t model = (size_t)_shown[(size_t)row];
    if ([column.identifier isEqualToString:@"__use"]) {
        NSButton *b = [tableView makeViewWithIdentifier:@"use.cell" owner:self];
        if (!b) {
            b = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleRow:)];
            b.identifier = @"use.cell";
        }
        b.state = _ticked[model] ? NSControlStateValueOn : NSControlStateValueOff;
        return b;
    }
    NSTextField *f = [tableView makeViewWithIdentifier:@"text.cell" owner:self];
    if (!f) {
        f = [NSTextField labelWithString:@""];
        f.identifier = @"text.cell";
        f.lineBreakMode = NSLineBreakByTruncatingTail;
        f.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
    }
    size_t col = (size_t)column.identifier.integerValue;
    const std::vector<std::string> &cells = _rows[model];
    bool editable = std::find(_editable.begin(), _editable.end(), col) != _editable.end();
    f.editable = editable;
    f.selectable = editable;
    f.target = editable ? self : nil;
    f.action = editable ? @selector(cellEdited:) : nil;
    f.stringValue = col < cells.size() ? ADIFString(cells[col]) : @"";
    f.toolTip = f.stringValue.length > 24 ? f.stringValue : nil;
    f.textColor = ADIFSeverityColor(model < _severity.size() ? _severity[model] : -1);
    return f;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    [self rebuild];
    if (_quiet) return;
    NSSortDescriptor *sd = _table.sortDescriptors.firstObject;
    if (self.onSortChanged) self.onSortChanged(sd ? sd.key.integerValue : -1, sd ? sd.ascending : YES);
}

- (void)setSortColumn:(NSInteger)column ascending:(BOOL)ascending {
    _quiet = true;
    _table.sortDescriptors = column < 0 ? @[] : @[ [NSSortDescriptor sortDescriptorWithKey:[NSString stringWithFormat:@"%ld", (long)column]
                                                                               ascending:ascending] ];
    _quiet = false;
    [self rebuild];
}

- (std::vector<size_t>)columnOrder {
    std::vector<size_t> out;
    for (NSTableColumn *c in _table.tableColumns)
        if (![c.identifier isEqualToString:@"__use"]) out.push_back((size_t)c.identifier.integerValue);
    return out;
}

- (void)setHeaderMenu:(NSMenu *)menu {
    _table.headerView.menu = menu;
}

- (void)setEditableColumns:(const std::vector<size_t> &)columns {
    _editable = columns;
    [_table reloadData];
}

- (void)cellEdited:(NSTextField *)sender {
    NSInteger row = [_table rowForView:sender], column = [_table columnForView:sender];
    if (row < 0 || (size_t)row >= _shown.size() || column < 0) return;
    size_t col = (size_t)_table.tableColumns[(NSUInteger)column].identifier.integerValue;
    NSInteger model = _shown[(size_t)row];
    const std::vector<std::string> &cells = _rows[(size_t)model];
    std::string now = col < cells.size() ? cells[col] : std::string();
    if (ADIFStd(sender.stringValue) == now) return;  // unchanged
    if (self.onEditCell) self.onEditCell(model, col, sender.stringValue);
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_quiet) return;
    if (self.onSelectionChanged) self.onSelectionChanged();
}

- (void)toggleRow:(NSButton *)sender {
    NSInteger row = [_table rowForView:sender];
    if (row < 0 || (size_t)row >= _shown.size()) return;
    _ticked[(size_t)_shown[(size_t)row]] = sender.state == NSControlStateValueOn;
    if (self.onTicksChanged) self.onTicksChanged();
}

- (void)doubleClicked:(id)sender {
    NSInteger row = _table.clickedRow, column = _table.clickedColumn;
    if (row < 0 || (size_t)row >= _shown.size()) return;
    if (column >= 0) {
        size_t col = (size_t)_table.tableColumns[(NSUInteger)column].identifier.integerValue;
        if (std::find(_editable.begin(), _editable.end(), col) != _editable.end() &&
            ![_table.tableColumns[(NSUInteger)column].identifier isEqualToString:@"__use"]) {
            [_table editColumn:column row:row withEvent:nil select:YES];
            return;
        }
    }
    if (self.onActivateRow) self.onActivateRow(_shown[(size_t)row]);
}

// ── Text report ─────────────────────────────────────────────────────────────

- (void)setText:(NSString *)text {
    if (!_textView) {
        _textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        _textView.editable = NO;
        _textView.selectable = YES;
        _textView.richText = NO;
        _textView.font = [NSFont monospacedSystemFontOfSize:NSFont.systemFontSize - 1 weight:NSFontWeightRegular];
        _textView.textContainerInset = NSMakeSize(6, 6);
        _textView.verticallyResizable = YES;
        _textView.horizontallyResizable = NO;
        _textView.autoresizingMask = NSViewWidthSizable;
        _textView.textContainer.widthTracksTextView = YES;
    }
    _scroll.documentView = _textView;
    _textView.string = text ?: @"";
    _textView.textColor = NSColor.textColor;
}

- (NSString *)text {
    return _textView.string ?: @"";
}

- (void)show {
    [_window makeKeyAndOrderFront:nil];
}

- (void)closePressed:(id)sender {
    [_window performClose:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (self.onClose) self.onClose();
}

@end
