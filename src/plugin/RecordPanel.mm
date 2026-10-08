#import "RecordPanel.h"

static NSString *const kFieldColumn = @"field";
static NSString *const kValueColumn = @"value";
static NSString *const kNoteColumn = @"note";
static NSString *const kLineBreakGlyph = @"⏎";  // ⏎

static NSString *ns(const std::string &s) {
    NSString *r = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return r ?: [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSISOLatin1StringEncoding];
}

static NSColor *severityColor(int severity) {
    switch (severity) {
        case 2: return NSColor.systemRedColor;
        case 1: return NSColor.systemOrangeColor;
        case 0: return NSColor.systemBlueColor;
        default: return NSColor.secondaryLabelColor;
    }
}

static NSButton *symbolButton(NSString *symbol, NSString *fallback, NSString *tip, id target, SEL action) {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    NSButton *b = image ? [NSButton buttonWithImage:image target:target action:action]
                        : [NSButton buttonWithTitle:fallback target:target action:action];
    b.bezelStyle = NSBezelStyleRecessed;
    b.toolTip = tip;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

@implementation ADIFRecordPanel {
    ADIFPanelSnapshot _snapshot;
    NSView *_root;
    NSTextField *_title;
    NSButton *_previous, *_next, *_add, *_remove;
    NSTableView *_table;
    NSTextField *_footer;
    // Add Field dialog
    NSComboBox *_addName, *_addValue;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 420)];

    _title = [NSTextField labelWithString:@""];
    _title.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize + 1];
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    _title.translatesAutoresizingMaskIntoConstraints = NO;
    [_title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    _previous = symbolButton(@"chevron.up", @"▲", @"Previous record", self, @selector(previousRecord:));
    _next = symbolButton(@"chevron.down", @"▼", @"Next record", self, @selector(nextRecord:));
    _add = symbolButton(@"plus", @"+", @"Add a field to this record", self, @selector(addField:));
    _remove = symbolButton(@"minus", @"-", @"Remove the selected field", self, @selector(removeField:));

    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _table.dataSource = self;
    _table.delegate = self;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.rowHeight = 24;
    _table.allowsMultipleSelection = NO;
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _table.target = self;
    _table.doubleAction = @selector(revealRow:);
    if (@available(macOS 11.0, *)) _table.style = NSTableViewStyleFullWidth;
    struct { NSString *ident, *title; CGFloat width; } cols[] = {
        {kFieldColumn, @"Field", 130}, {kValueColumn, @"Value", 150}, {kNoteColumn, @"Problem", 160}};
    for (auto &c : cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c.ident];
        col.title = c.title;
        col.width = c.width;
        col.minWidth = 60;
        [_table addTableColumn:col];
    }

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = _table;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    _footer = [NSTextField wrappingLabelWithString:@""];
    _footer.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _footer.maximumNumberOfLines = 4;
    _footer.translatesAutoresizingMaskIntoConstraints = NO;
    [_footer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    for (NSView *v in @[ _title, _previous, _next, scroll, _footer, _add, _remove ]) [_root addSubview:v];
    const CGFloat m = 6;
    [NSLayoutConstraint activateConstraints:@[
        [_title.topAnchor constraintEqualToAnchor:_root.topAnchor constant:m],
        [_title.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor constant:m],
        [_title.trailingAnchor constraintLessThanOrEqualToAnchor:_previous.leadingAnchor constant:-m],
        [_next.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor constant:-m],
        [_next.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
        [_previous.trailingAnchor constraintEqualToAnchor:_next.leadingAnchor constant:-2],
        [_previous.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:m],
        [scroll.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor constant:m],
        [scroll.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor constant:-m],
        [_footer.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:m],
        [_footer.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor constant:m],
        [_footer.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor constant:-m],
        [_add.topAnchor constraintEqualToAnchor:_footer.bottomAnchor constant:m],
        [_add.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor constant:m],
        [_remove.leadingAnchor constraintEqualToAnchor:_add.trailingAnchor constant:2],
        [_remove.centerYAnchor constraintEqualToAnchor:_add.centerYAnchor],
        [_add.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor constant:-m],
        [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:80],
    ]];
    [self update:ADIFPanelSnapshot{}];
    return self;
}

- (NSView *)view {
    return _root;
}

+ (NSString *)displayString:(const std::string &)value {
    NSString *s = ns(value);
    s = [s stringByReplacingOccurrencesOfString:@"\r\n" withString:kLineBreakGlyph];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:kLineBreakGlyph];
    return [s stringByReplacingOccurrencesOfString:@"\r" withString:kLineBreakGlyph];
}

+ (std::string)valueFromDisplay:(NSString *)display {
    // ADIF line breaks are CR LF (§II.B MultilineString).
    NSString *s = [display stringByReplacingOccurrencesOfString:kLineBreakGlyph withString:@"\r\n"];
    return s.UTF8String ?: "";
}

- (void)update:(const ADIFPanelSnapshot &)snapshot {
    _snapshot = snapshot;
    _title.stringValue = ns(snapshot.title);
    _footer.stringValue = ns(snapshot.footer);
    _footer.textColor = severityColor(snapshot.footerSeverity);
    _footer.hidden = snapshot.footer.empty();
    _previous.enabled = snapshot.canPrevious;
    _next.enabled = snapshot.canNext;
    _add.enabled = snapshot.hasGroup;
    [_table reloadData];
    if (snapshot.selectedRow >= 0 && snapshot.selectedRow < (int)snapshot.rows.size()) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)snapshot.selectedRow] byExtendingSelection:NO];
        [_table scrollRowToVisible:snapshot.selectedRow];
    } else {
        [_table deselectAll:nil];
    }
    _remove.enabled = snapshot.hasGroup && _table.selectedRow >= 0;
}

// ── Table ───────────────────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_snapshot.rows.size();
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    const ADIFPanelRow &r = _snapshot.rows[(size_t)row];
    NSString *ident = column.identifier;
    if ([ident isEqualToString:kFieldColumn]) {
        NSTextField *f = [tableView makeViewWithIdentifier:@"field.cell" owner:self];
        if (!f) {
            f = [NSTextField labelWithString:@""];
            f.identifier = @"field.cell";
            f.lineBreakMode = NSLineBreakByTruncatingTail;
            f.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
        }
        f.stringValue = ns(r.name);
        f.toolTip = ns(r.tooltip);
        return f;
    }
    if ([ident isEqualToString:kNoteColumn]) {
        NSTextField *f = [tableView makeViewWithIdentifier:@"note.cell" owner:self];
        if (!f) {
            f = [NSTextField labelWithString:@""];
            f.identifier = @"note.cell";
            f.lineBreakMode = NSLineBreakByTruncatingTail;
            f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        }
        f.stringValue = ns(r.note);
        f.textColor = severityColor(r.severity);
        f.toolTip = ns(r.tooltip);
        return f;
    }
    // Value: a combo box when there are values to offer, else a text field.
    NSString *display = [ADIFRecordPanel displayString:r.value];
    if (!r.choices.empty()) {
        NSComboBox *c = [tableView makeViewWithIdentifier:@"value.combo" owner:self];
        if (!c) {
            c = [[NSComboBox alloc] initWithFrame:NSZeroRect];
            c.identifier = @"value.combo";
            c.completes = YES;
            c.numberOfVisibleItems = 14;
            c.controlSize = NSControlSizeSmall;
            c.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
            c.delegate = self;
        }
        [c removeAllItems];
        for (const std::string &v : r.choices) [c addItemWithObjectValue:ns(v)];
        c.stringValue = display;
        c.toolTip = ns(r.tooltip);
        return c;
    }
    NSTextField *t = [tableView makeViewWithIdentifier:@"value.text" owner:self];
    if (!t) {
        t = [NSTextField textFieldWithString:@""];
        t.identifier = @"value.text";
        t.bordered = NO;
        t.drawsBackground = NO;
        t.lineBreakMode = NSLineBreakByTruncatingTail;
        t.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        t.delegate = self;
    }
    t.stringValue = display;
    t.toolTip = ns(r.tooltip);
    return t;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    _remove.enabled = _snapshot.hasGroup && _table.selectedRow >= 0;
}

- (void)commit:(NSControl *)control value:(NSString *)value {
    NSInteger row = [_table rowForView:control];
    if (row < 0 || row >= (NSInteger)_snapshot.rows.size() || !value) return;
    if ([ADIFRecordPanel valueFromDisplay:value] == _snapshot.rows[(size_t)row].value) return;  // unchanged
    if (self.onEditValue) self.onEditValue(row, value);
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSControl *c = notification.object;
    if (c == _addName || c == _addValue) return;
    [self commit:c value:c.stringValue];
}

- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    NSComboBox *c = notification.object;
    if (c == _addName) {
        [self refreshAddValues];
        return;
    }
    if (c == _addValue) return;
    // The combo box's string updates after this notification; use the selected item.
    id item = c.objectValueOfSelectedItem;
    if ([item isKindOfClass:NSString.class]) [self commit:c value:item];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _addName) [self refreshAddValues];
}

// ── Buttons ─────────────────────────────────────────────────────────────────

- (void)previousRecord:(id)sender {
    if (self.onGoToRecord) self.onGoToRecord(-1);
}

- (void)nextRecord:(id)sender {
    if (self.onGoToRecord) self.onGoToRecord(1);
}

- (void)revealRow:(id)sender {
    NSInteger row = _table.clickedRow;
    if (row >= 0 && self.onRevealRow) self.onRevealRow(row);
}

- (void)removeField:(id)sender {
    NSInteger row = _table.selectedRow;
    if (row >= 0 && self.onRemoveField) self.onRemoveField(row);
}

- (void)refreshAddValues {
    NSArray<NSString *> *values = self.valuesForField ? self.valuesForField(_addName.stringValue) : @[];
    [_addValue removeAllItems];
    [_addValue addItemsWithObjectValues:values ?: @[]];
}

- (void)addField:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Add a field";
    alert.informativeText = @"The data length is set for you.";
    [alert addButtonWithTitle:@"Add"];
    [alert addButtonWithTitle:@"Cancel"];

    _addName = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 30, 280, 26)];
    _addName.placeholderString = @"Field name, e.g. RST_SENT";
    _addName.completes = YES;
    _addName.numberOfVisibleItems = 14;
    for (const std::string &n : _snapshot.addableNames) [_addName addItemWithObjectValue:ns(n)];
    _addName.delegate = self;
    _addValue = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 280, 26)];
    _addValue.placeholderString = @"Value";
    _addValue.completes = YES;
    _addValue.numberOfVisibleItems = 14;
    _addValue.delegate = self;
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 58)];
    [box addSubview:_addName];
    [box addSubview:_addValue];
    alert.accessoryView = box;
    alert.window.initialFirstResponder = _addName;

    NSModalResponse response = [alert runModal];
    NSString *name = [_addName.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *value = _addValue.stringValue;
    _addName = nil;
    _addValue = nil;
    if (response == NSAlertFirstButtonReturn && name.length && self.onAddField) self.onAddField(name, value);
}

@end
