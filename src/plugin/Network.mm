#import "Network.h"

#include "PluginHost.h"

NSString *const ADIFOfflineChangedNotification = @"ADIFOfflineChanged";

BOOL ADIFOffline(void) { return adifhost::setting("offline") == "1"; }

void ADIFSetOffline(BOOL on) {
    if (ADIFOffline() == on) return;
    adifhost::setSetting("offline", on ? "1" : "");
    [[NSNotificationCenter defaultCenter] postNotificationName:ADIFOfflineChangedNotification object:nil];
}

NSString *ADIFOfflineReason(void) {
    return @"Offline mode is on, so ADIF Lint makes no network requests (ADIF Lint menu: Offline Mode).";
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
        alert.messageText = @"Offline mode is on";
        alert.informativeText = [NSString stringWithFormat:@"ADIF Lint didn't open %@. Turn Offline Mode off in the ADIF Lint menu to "
                                                           @"open web pages again.",
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
