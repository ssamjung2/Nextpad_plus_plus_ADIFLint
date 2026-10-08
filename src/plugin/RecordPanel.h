// The record panel: the header or record under the caret as an editable table.
//
// This class is AppKit only. It knows nothing about Scintilla or ADIF parsing:
// ADIFLint.mm hands it a snapshot to show and receives the user's edits
// through the callback blocks, which it applies to the document.
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>

struct ADIFPanelRow {
    std::string name;                  // as written in the file
    std::string value;                 // the field's data
    std::string note;                  // most severe problem on this field, or empty
    std::string tooltip;               // every problem on this field, and the field's description
    int severity = -1;                 // -1 none, 0 note, 1 warning, 2 error
    std::vector<std::string> choices;  // values to offer (empty: free text)
};

struct ADIFPanelSnapshot {
    bool hasGroup = false;     // false: nothing to show (not ADIF, or no record at the caret)
    std::string title;         // "Record 3 of 7 · line 13", "Header", or why nothing is shown
    std::string footer;        // problems that belong to the record as a whole
    int footerSeverity = -1;
    std::vector<ADIFPanelRow> rows;
    std::vector<std::string> addableNames;  // for the Add Field dialog
    int selectedRow = -1;      // the field under the caret
    bool canPrevious = false, canNext = false;
};

@interface ADIFRecordPanel : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSComboBoxDelegate>

@property(nonatomic, readonly) NSView *view;

@property(nonatomic, copy) void (^onEditValue)(NSInteger row, NSString *value);
@property(nonatomic, copy) void (^onAddField)(NSString *name, NSString *value);
@property(nonatomic, copy) void (^onRemoveField)(NSInteger row);
@property(nonatomic, copy) void (^onGoToRecord)(NSInteger delta);  // -1 previous, +1 next
@property(nonatomic, copy) void (^onRevealRow)(NSInteger row);      // select the field's data in the editor
@property(nonatomic, copy) NSArray<NSString *> * (^valuesForField)(NSString *name);

- (void)update:(const ADIFPanelSnapshot &)snapshot;

// Line breaks inside a value are shown as ⏎ in the single-line cells.
+ (NSString *)displayString:(const std::string &)value;
+ (std::string)valueFromDisplay:(NSString *)display;

@end
