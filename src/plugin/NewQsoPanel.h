// The New QSO window: one row per field, a status column, Log QSO and Close.
//
// AppKit only, like RecordPanel: ADIFLint.mm supplies the rows, checks the
// values whenever they change, and appends the record when Log QSO is pressed.
#pragma once

#import <Cocoa/Cocoa.h>

#import "ToolWindow.h"

#include <string>
#include <utility>
#include <vector>

struct ADIFQsoRow {
    std::string name;                  // upper case
    std::string value;
    std::string description;           // tooltip
    std::vector<std::string> choices;  // values to offer (empty: free text)
    bool required = false;
    ADIFSuggestBlock suggest = nil;    // values to offer as you type (a search), in place of `choices`
};

@interface ADIFNewQsoPanel : NSObject <NSWindowDelegate, NSTextFieldDelegate, NSComboBoxDelegate>

@property(nonatomic, readonly) NSPanel *window;
@property(nonatomic, copy) void (^onChange)(void);  // any value edited
@property(nonatomic, copy) void (^onLog)(void);     // Log QSO pressed
@property(nonatomic, copy) void (^onCustomize)(void);  // Fields... pressed
@property(nonatomic, copy) void (^onSpots)(void);      // Spots... pressed
@property(nonatomic, copy) void (^onContest)(void);    // Contest... pressed
// Look up the call as you type: 0 off, 1 country data (offline), 2 QRZ.com, 3 HamQTH.
@property(nonatomic) NSInteger lookupSource;
@property(nonatomic, copy) void (^onLookupChanged)(NSInteger source);
// The Station popup: index 0 is the log's own station fields, then the profiles,
// then "Edit Profiles..." (onStationChosen gets -1 for that).
@property(nonatomic, copy) void (^onStationChosen)(NSInteger index);
- (void)setStations:(NSArray<NSString *> *)names selected:(NSInteger)index;
// Beside the Station popup: what the station writes, its key fields ("KW9D · EN52wa · 5 W · KX2").
- (void)setStationSummary:(NSString *)text;
// Spot when logging: the station worked on the DX cluster, yourself on pota.app. The boxes stay as
// you leave them; onSpotChanged when either is ticked or unticked.
@property(nonatomic) BOOL spotCluster;
@property(nonatomic) BOOL spotPota;
@property(nonatomic, copy) void (^onSpotChanged)(void);
// Whether each box can spot now (dimmed when not), and what its tooltip says.
- (void)setSpotReady:(BOOL)cluster clusterTip:(NSString *)clusterTip pota:(BOOL)pota potaTip:(NSString *)potaTip;
@property(nonatomic, readonly) BOOL spotClusterReady;
@property(nonatomic, readonly) BOOL spotPotaReady;
- (void)setSpotStatus:(NSString *)text;  // what spotting the last QSO did; "" hides the line
@property(nonatomic, readonly) BOOL useCurrentTime; // fill QSO_DATE/TIME_ON at the moment of logging
@property(nonatomic) NSInteger timeDigits;          // 4 (HHMM) or 6 (HHMMSS)

- (void)setRows:(const std::vector<ADIFQsoRow> &)rows;
- (std::vector<std::pair<std::string, std::string>>)values;  // in row order
- (std::string)valueForField:(const std::string &)name;
- (void)setValue:(const std::string &)value forField:(const std::string &)name;
- (void)setChoices:(const std::vector<std::string> &)choices forField:(const std::string &)name;
// Per row, in row order: severity (-1 none, 0 note, 1 warning, 2 error) and message.
- (void)setRowStatus:(const std::vector<std::pair<int, std::string>> &)status;
- (void)setSummary:(const std::string &)text severity:(int)severity;
- (void)setTarget:(const std::string &)documentName;
- (void)setNote:(NSString *)note;  // e.g. station fields copied from the last record
// What the lookup says, a fact a row ([name, fact] or [name, fact, more for its tooltip]), and a
// message under them (a callbook's notice or error; nil none) in its severity's colour.
- (void)setLookupFacts:(NSArray<NSArray<NSString *> *> *)facts message:(NSString *)message severity:(int)severity;
- (BOOL)hasField:(const std::string &)name;
- (void)refreshTime;  // put the current UTC date and time in QSO_DATE/TIME_ON
- (void)focusField:(const std::string &)name;
- (void)show;

@end
