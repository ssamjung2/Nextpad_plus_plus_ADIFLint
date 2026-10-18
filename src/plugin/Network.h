// Offline mode: one switch that stops every network request ADIF Lint makes (callbook lookups,
// spots, uploads, imports from the online services, downloads, TQSL, and web pages opened in the
// browser), for off-grid operating or to be sure nothing is sent. Monitor's listening for the
// programs on this Mac goes on: it only receives. Kept in the settings as "offline".
// AppKit and Foundation only.
#pragma once

#import <Cocoa/Cocoa.h>

BOOL ADIFOffline(void);
void ADIFSetOffline(BOOL on);  // saved, then ADIFOfflineChangedNotification is posted
extern NSString *const ADIFOfflineChangedNotification;

// Why a request was refused, for a status line.
NSString *ADIFOfflineReason(void);

// Opens an http or https page in the browser; in offline mode, says why it can't (an alert) and
// returns NO. Other URLs (files) open as usual.
BOOL ADIFOpenURL(NSString *url);
