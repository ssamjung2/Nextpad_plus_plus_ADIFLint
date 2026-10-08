// "New QSO Fields": choose and order the fields the New QSO window asks for,
// from a searchable list of the fields this log can use, each with a brief
// description. AppKit only; ADIFLint.mm saves the choice and rebuilds New QSO.
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>

struct ADIFFieldChoice {
    std::string name;     // upper case
    std::string type;     // e.g. "String", "Enumeration"
    std::string brief;    // first paragraph of the spec's description
    std::string details;  // the spec's full description, for the tooltip
    bool hasValues = false;  // New QSO offers a list of values
};

@interface ADIFQsoFieldsPanel : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSSearchFieldDelegate>

@property(nonatomic, readonly) NSPanel *window;
// `automatic`: use the log's own fields (the list is then ignored).
@property(nonatomic, copy) void (^onSave)(const std::vector<std::string> &fields, BOOL automatic, BOOL carryHidden);

// `fields`: the list to start from (what the New QSO window shows now).
// `choices`: every field this log can use, with its description.
- (void)showFields:(const std::vector<std::string> &)fields
       carryHidden:(BOOL)carryHidden
           choices:(const std::vector<ADIFFieldChoice> &)choices;

@end
