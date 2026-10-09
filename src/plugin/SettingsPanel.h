// ADIF Lint Settings: the country data, and accounts and API keys for the
// online services, stored in the macOS Keychain (see Lookup.h).
// AppKit and Foundation only.
#pragma once

#import <Cocoa/Cocoa.h>

@interface ADIFSettingsPanel : NSObject <NSWindowDelegate>

@property(nonatomic, readonly) NSPanel *window;
// A credential was saved or removed for this source.
@property(nonatomic, copy) void (^onChanged)(NSInteger source);

// The country data section: Update downloads AD1C's newest country file.
@property(nonatomic, copy) void (^onCountryUpdate)(void);
- (void)setCountryStatus:(NSString *)text ok:(BOOL)ok;

- (void)showSource:(NSInteger)source;  // show the window with that source's first field focused (-3: country data)
- (void)refresh;                       // reload what is saved

@end
