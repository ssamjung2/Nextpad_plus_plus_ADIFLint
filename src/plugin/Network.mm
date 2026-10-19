#import "Network.h"
#import "L10n.h"

#include "PluginHost.h"

#include <algorithm>

NSString *const ADIFOfflineChangedNotification = @"ADIFOfflineChanged";

BOOL ADIFOffline(void) { return adifhost::setting("offline") == "1"; }

void ADIFSetOffline(BOOL on) {
    if (ADIFOffline() == on) return;
    adifhost::setSetting("offline", on ? "1" : "");
    [[NSNotificationCenter defaultCenter] postNotificationName:ADIFOfflineChangedNotification object:nil];
}

NSString *ADIFOfflineReason(void) {
    return T(@"Offline mode is on, so ADIF Lint makes no network requests (ADIF Lint menu: Offline Mode).");
}

BOOL ADIFOpenURL(NSString *url) {
    NSURL *u = [NSURL URLWithString:url ?: @""];
    if (!u) return NO;
    bool web = [u.scheme caseInsensitiveCompare:@"http"] == NSOrderedSame || [u.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame;
    if (web && ADIFOffline()) {
        if (const char *log = getenv("ADIFLINT_TEST_URL_LOG")) {  // tests: no alert
            [[NSString stringWithFormat:@"refused %@\n", url] writeToFile:@(log) atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return NO;
        }
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = T(@"Offline mode is on");
        alert.informativeText = [NSString stringWithFormat:T(@"ADIF Lint didn't open %@. Turn Offline Mode off in the ADIF Lint menu to "
                                                           @"open web pages again."),
                                                           u.host ?: url];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        return NO;
    }
    if (const char *log = getenv("ADIFLINT_TEST_URL_LOG")) {
        [[NSString stringWithFormat:@"opened %@\n", url] writeToFile:@(log) atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return YES;
    }
    return [[NSWorkspace sharedWorkspace] openURL:u];
}

// ── Map Detail downloads ──────────────────────────────────────────────────

namespace {

NSURLSession *downloadSession() {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.timeoutIntervalForRequest = 60;
        c.timeoutIntervalForResource = 900;
        c.URLCache = nil;
        c.HTTPMaximumConnectionsPerHost = 4;
        session = [NSURLSession sessionWithConfiguration:c];
    });
    return session;
}

// Who is asking, as servers like to know: the program and where to find it.
NSString *userAgent() { return [NSString stringWithFormat:@"ADIFLint/%s (+https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint)", ADIFLINT_VERSION]; }

NSString *fixture(NSURL *url) {
    const char *dir = getenv("ADIFLINT_FAKE_LOOKUP_DIR");
    if (!dir || !*dir || !url.lastPathComponent.length) return nil;
    return [[@(dir) stringByAppendingPathComponent:@"mapdetail"] stringByAppendingPathComponent:url.lastPathComponent];
}

void later(void (^block)(void)) { dispatch_async(dispatch_get_main_queue(), block); }

}  // namespace

NSURLSessionTask *ADIFFetchFile(NSURL *url, void (^done)(NSData *body, NSString *error)) {
    if (ADIFOffline()) {
        NSString *why = ADIFOfflineReason();
        later(^{ done(nil, why); });
        return nil;
    }
    if (NSString *path = fixture(url)) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        later(^{ done(d, d ? nil : @"HTTP 404 (fixture)"); });
        return nil;
    }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    [r setValue:userAgent() forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [downloadSession() dataTaskWithRequest:r
                                                      completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
                                                          NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                                                                                 ? ((NSHTTPURLResponse *)response).statusCode
                                                                                 : 0;
                                                          NSString *problem = err ? err.localizedDescription
                                                                              : status != 200
                                                                                  ? [NSString stringWithFormat:T(@"HTTP %ld from %@"), (long)status, url.host]
                                                                                  : nil;
                                                          later(^{ done(problem ? nil : data, problem); });
                                                      }];
    [task resume];
    return task;
}

NSURLSessionTask *ADIFFetchRange(NSURL *url, uint64_t offset, uint64_t length, NSString *etag,
                                 void (^done)(NSData *bytes, NSString *etag, NSString *error)) {
    if (ADIFOffline()) {
        NSString *why = ADIFOfflineReason();
        later(^{ done(nil, nil, why); });
        return nil;
    }
    if (length == 0) {
        later(^{ done([NSData data], etag, nil); });
        return nil;
    }
    if (NSString *path = fixture(url)) {
        NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
        unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
        NSString *tag = [NSString stringWithFormat:@"\"fixture-%llu\"", size];
        NSData *d = nil;
        if (h && offset < size && (!etag.length || [etag isEqualToString:tag])) {  // past the end: what there is, as servers do
            [h seekToFileOffset:offset];
            d = [h readDataOfLength:(NSUInteger)std::min<unsigned long long>(length, size - offset)];
        }
        [h closeFile];
        NSString *why = d ? nil : etag.length && ![etag isEqualToString:tag] ? T(@"The file changed on the server (HTTP 412).") : @"HTTP 416 (fixture)";
        later(^{ done(d, d ? tag : nil, why); });
        return nil;
    }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    [r setValue:userAgent() forHTTPHeaderField:@"User-Agent"];
    [r setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", (unsigned long long)offset, (unsigned long long)(offset + length - 1)]
        forHTTPHeaderField:@"Range"];
    if (etag.length) [r setValue:etag forHTTPHeaderField:@"If-Match"];
    NSURLSessionDataTask *task = [downloadSession()
        dataTaskWithRequest:r
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
              NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
              NSString *tag = [http valueForHTTPHeaderField:@"ETag"];
              NSString *problem = nil;
              if (err) problem = err.code == NSURLErrorCancelled ? T(@"Stopped.") : err.localizedDescription;
              else if (http.statusCode == 412) problem = T(@"The file changed on the server while it was being read (HTTP 412).");
              else if (http.statusCode != 206) problem = [NSString stringWithFormat:T(@"HTTP %ld from %@ (expected 206 for a range)"), (long)http.statusCode, url.host];
              else if (data.length != length) {
                  // A range past the end of the file comes back short: fine when it reaches the end
                  // (Content-Range: bytes first-last/total).
                  NSString *range = [http valueForHTTPHeaderField:@"Content-Range"];
                  NSRange slash = [range rangeOfString:@"/" options:NSBackwardsSearch];
                  unsigned long long total = slash.location != NSNotFound ? strtoull([range substringFromIndex:slash.location + 1].UTF8String, nullptr, 10) : 0;
                  if (data.length > length || offset + data.length != total) problem = T(@"The server sent a different length than asked for.");
              }
              else if (etag.length && tag.length && ![tag isEqualToString:etag]) problem = T(@"The file changed on the server while it was being read (HTTP 412).");
              later(^{ done(problem ? nil : data, problem ? nil : (tag ?: etag), problem); });
          }];
    [task resume];
    return task;
}
