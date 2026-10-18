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

// Map Detail's downloads (Settings → Map Detail). A small file whole, or a byte range of a big
// one: HTTP Range, where only a 206 answer counts; with an ETag given, If-Match keeps every
// range from the same version of the file (412: it changed since). Completion on the main
// queue; the task can be cancelled. Refused in offline mode. In the tests
// (ADIFLINT_FAKE_LOOKUP_DIR), answered from the fixtures' mapdetail folder by file name.
NSURLSessionTask *ADIFFetchFile(NSURL *url, void (^done)(NSData *body, NSString *error));
NSURLSessionTask *ADIFFetchRange(NSURL *url, uint64_t offset, uint64_t length, NSString *etag,
                                 void (^done)(NSData *bytes, NSString *etag, NSString *error));
