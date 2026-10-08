// ADIF Lint Settings: the radio connection for New QSO, and accounts and API
// keys for the online services, stored in the macOS Keychain (see Lookup.h).
// AppKit and Foundation only; ADIFLint.mm keeps the radio settings.
#pragma once

#import <Cocoa/Cocoa.h>

@interface ADIFSettingsPanel : NSObject <NSWindowDelegate>

@property(nonatomic, readonly) NSPanel *window;
// A credential was saved or removed for this source.
@property(nonatomic, copy) void (^onChanged)(NSInteger source);

// The radio section: program (0 none, 1 rigctld, 2 flrig), host and port.
@property(nonatomic, copy) void (^onRadioSave)(NSInteger kind, NSString *host, int port);
@property(nonatomic, copy) void (^onRadioTest)(NSInteger kind, NSString *host, int port);
- (void)setRadioKind:(NSInteger)kind host:(NSString *)host port:(int)port;
- (void)setRadioStatus:(NSString *)text ok:(BOOL)ok;

// The country data section: Update downloads AD1C's newest country file.
@property(nonatomic, copy) void (^onCountryUpdate)(void);
- (void)setCountryStatus:(NSString *)text ok:(BOOL)ok;

- (void)showSource:(NSInteger)source;  // show the window with that source's first field focused (-2: the radio, -3: country data)
- (void)refresh;                       // reload what is saved

@end
