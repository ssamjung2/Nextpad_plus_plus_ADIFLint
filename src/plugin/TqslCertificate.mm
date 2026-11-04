#import "TqslCertificate.h"

#import "L10n.h"
#import "Lookup.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#import "Uploads.h"
#include "adif_spec.h"
#include "adif_tqsl.h"

#include <algorithm>
#include <vector>

using namespace adifhost;

namespace tqslcert {
namespace {

struct Chooser {
    ADIFToolWindow *w = nil;
    NSSecureTextField *passphrase = nil;
    std::vector<adif::TqslCertificate> certs;  // in table rows' order
    std::string profile, folder;
    void (^done)(const std::string &call, const std::string &serial) = nil;
} ch;

const adif::TqslCertificate *selected() {
    std::vector<NSInteger> sel = [ch.w selectedRows];
    return sel.size() == 1 && (size_t)sel[0] < ch.certs.size() ? &ch.certs[(size_t)sel[0]] : nullptr;
}

// As the specification names it, like ADIF Lint's other DXCC entities.
std::string entity(int dxcc) {
    const char *n = dxcc ? adif::dxccEntityName(std::to_string(dxcc)) : nullptr;
    return n ? std::to_string(dxcc) + " " + n : dxcc ? std::to_string(dxcc) : "";
}

// Away: the sheet ended, or the window (when it opened as one) put away.
void dismiss() {
    NSWindow *win = ch.w.window;
    if (NSWindow *parent = win.sheetParent) [parent endSheet:win];
    else [win orderOut:nil];
}

void showPassphrase() {
    const adif::TqslCertificate *c = selected();
    bool saved = c && ADIFTqslPassphrase(ADIFString(c->call));
    ch.passphrase.placeholderString = saved ? T(@"Saved in your Keychain") : T(@"Its passphrase, if it has one");
}

// TQSL's certificates, newest first for each callsign; the profile's own selected.
void load(const std::string &call, const std::string &serial) {
    ch.folder = uploads::tqslFolder();
    ch.certs.clear();
    if (!ch.folder.empty())
        if (NSData *data = [NSData dataWithContentsOfFile:ADIFString(ch.folder + "/certs/user")])
            ch.certs = adif::parseTqslCertificates(std::string_view((const char *)data.bytes, data.length));
    std::stable_sort(ch.certs.begin(), ch.certs.end(), [](const adif::TqslCertificate &a, const adif::TqslCertificate &b) {
        return a.call != b.call ? a.call < b.call : a.expires > b.expires;
    });
    std::string today = utcNow("%Y-%m-%d");
    std::vector<std::vector<std::string>> rows;
    std::vector<int> severities;
    std::vector<std::string> keys;
    NSInteger pick = -1;
    for (size_t i = 0; i < ch.certs.size(); ++i) {
        const adif::TqslCertificate &c = ch.certs[i];
        bool expired = !c.expires.empty() && c.expires < today;
        rows.push_back({c.call, entity(c.dxcc), c.qsoFrom, c.qsoTo, expired ? trf("{date} (expired)", {{"date", c.expires}}) : c.expires, c.serial});
        severities.push_back(expired ? 1 : -1);
        keys.push_back(c.call + "#" + c.serial);
        if (c.call == call && (pick < 0 || c.serial == serial)) pick = (NSInteger)i;
    }
    [ch.w setRows:rows severities:severities keys:keys ticks:std::vector<bool>() keepTicks:NO];
    if (pick >= 0) [ch.w selectRow:pick];
    [ch.w setTarget:TF(@"Profile: {name}", @{@"name" : ADIFString(ch.profile)})];
    if (ch.certs.empty())
        [ch.w setStatus:ADIFString(ch.folder.empty() ? tr("TQSL has no callsign certificates on this Mac. Request one in TQSL, or load a certificate file "
                                                          "(.p12 or .tq6) there, then press Refresh.")
                                                     : trf("TQSL's folder ({folder}) holds no callsign certificates. Request one in TQSL, or load a "
                                                           "certificate file (.p12 or .tq6) there, then press Refresh.",
                                                           {{"folder", ADIFStd(ADIFString(ch.folder).stringByAbbreviatingWithTildeInPath)}}))
                severity:1];
    else
        [ch.w setStatus:ADIFString(tr("Choose the certificate this profile's LoTW uploads sign with, enter its passphrase if it has one, and "
                                      "press Test, then Save. The passphrase is kept in your Keychain."))
                severity:-1];
    showPassphrase();
}

// The passphrase typed, else the one saved, tested against the certificate's own key.
adif::TqslKeyCheck check(const adif::TqslCertificate &c, NSString *typed) {
    NSString *pass = typed.length ? typed : ADIFTqslPassphrase(ADIFString(c.call)) ?: @"";
    NSData *keys = [NSData dataWithContentsOfFile:ADIFString(ch.folder + "/keys/" + adif::tqslKeyFileName(c.call))];
    std::string_view file = keys ? std::string_view((const char *)keys.bytes, keys.length) : std::string_view();
    return adif::checkTqslPassphrase(file, c.publicKey, pass.UTF8String);
}

// What a check means, and its colour.
std::string meaning(adif::TqslKeyCheck r, const adif::TqslCertificate &c, bool typed, int *severity) {
    switch (r) {
        case adif::TqslKeyCheck::Unlocked:
            *severity = 3;
            return trf("The passphrase unlocks the {call} certificate (serial {serial}).", {{"call", c.call}, {"serial", c.serial}});
        case adif::TqslKeyCheck::NoPassphrase:
            *severity = 3;
            return trf("The {call} certificate has no passphrase: TQSL signs with it without asking.", {{"call", c.call}});
        case adif::TqslKeyCheck::Wrong:
            *severity = 2;
            return typed || ADIFTqslPassphrase(ADIFString(c.call)) ? tr("That passphrase does not unlock this certificate.")
                                                                   : trf("The {call} certificate has a passphrase: enter it.", {{"call", c.call}});
        case adif::TqslKeyCheck::NoKey:
            *severity = 1;
            return trf("This Mac has no key for the {call} certificate (serial {serial}), so the passphrase cannot be tested: TQSL signs with it "
                       "only where it was requested, or once its .p12 file is loaded in TQSL.",
                       {{"call", c.call}, {"serial", c.serial}});
        case adif::TqslKeyCheck::Unreadable:
            *severity = 1;
            return tr("The certificate's key is in a form ADIF Lint cannot test; if the passphrase is wrong, TQSL will ask for it.");
    }
    return "";
}

void test() {
    const adif::TqslCertificate *c = selected();
    if (!c) {
        [ch.w setStatus:T(@"Choose a certificate first.") severity:1];
        return;
    }
    int severity = -1;
    std::string m = meaning(check(*c, ch.passphrase.stringValue), *c, ch.passphrase.stringValue.length > 0, &severity);
    [ch.w setStatus:ADIFString(m) severity:severity];
}

void save() {
    const adif::TqslCertificate *c = selected();
    if (!c) {
        [ch.w setStatus:T(@"Choose a certificate, or press No Certificate to sign with the Station Location's own.") severity:1];
        return;
    }
    NSString *typed = ch.passphrase.stringValue;
    if (typed.length) {
        adif::TqslKeyCheck r = check(*c, typed);
        int severity = -1;
        if (r == adif::TqslKeyCheck::Wrong) {
            [ch.w setStatus:ADIFString(meaning(r, *c, true, &severity) + " " + tr("Nothing was saved.")) severity:2];
            return;
        }
        if (r == adif::TqslKeyCheck::NoPassphrase) {
            ADIFForgetTqslPassphrase(ADIFString(c->call));  // none needed: nothing to pass with -p
        } else {
            NSString *error = nil;
            if (!ADIFSaveTqslPassphrase(ADIFString(c->call), typed, &error)) {
                [ch.w setStatus:TF(@"The passphrase could not be saved in your Keychain: {why}", @{@"why" : error ?: @""}) severity:2];
                return;
            }
        }
    }
    ch.passphrase.stringValue = @"";
    std::string call = c->call, serial = c->serial;
    auto done = ch.done;
    dismiss();
    if (done) done(call, serial);
}

}  // namespace

void choose(NSWindow *parent, const std::string &profile, const std::string &call, const std::string &serial,
            void (^done)(const std::string &call, const std::string &serial)) {
    if (!ch.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"TQSL Certificate" size:NSMakeSize(900, 360) headline:NO normal:YES];
        ch.w = w;
        [w setColumns:std::vector<ADIFToolColumn>{{"call", "Callsign", 90},
                                                  {"dxcc", "DXCC Entity", 260},
                                                  {"from", "QSOs From", 90},
                                                  {"to", "QSOs To", 90},
                                                  {"expires", "Expires", 170},
                                                  {"serial", "Serial", 90}}
            checkboxes:NO
              sortable:NO];
        ch.passphrase = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
        ch.passphrase.identifier = @"tqslcert.passphrase";
        [ch.passphrase.widthAnchor constraintEqualToConstant:240].active = YES;
        NSButton *testButton = [NSButton buttonWithTitle:T(@"Test") target:nil action:nil];
        ADIFOnAction(testButton, ^{ test(); });
        [w addOptionRow:@[ ADIFLabel(@"Passphrase:"), ch.passphrase, testButton ]];
        w.onSelectionChanged = ^{
            ch.passphrase.stringValue = @"";
            showPassphrase();
        };
        [w addButton:@"Open TQSL" trailing:NO action:^{
            std::string app = uploads::tqslApplication();
            size_t at = app.find(".app/");
            if (app.empty() || at == std::string::npos) {
                [ch.w setStatus:T(@"TQSL is not installed. Get it from lotw.arrl.org, or name it in Settings.") severity:2];
                return;
            }
            NSURL *url = [NSURL fileURLWithPath:ADIFString(app.substr(0, at + 4))];
            [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
            [ch.w setStatus:T(@"In TQSL, load a certificate file (.p12 or .tq6) or request a certificate, then press Refresh here.") severity:-1];
        }];
        [w addButton:@"Refresh" trailing:NO action:^{
            const adif::TqslCertificate *c = selected();
            std::string call = c ? c->call : "", serial = c ? c->serial : "";
            load(call, serial);
        }];
        [w addButton:@"Forget Passphrase" trailing:NO action:^{
            const adif::TqslCertificate *c = selected();
            if (!c) return;
            ADIFForgetTqslPassphrase(ADIFString(c->call));
            showPassphrase();
            [ch.w setStatus:ADIFString(trf("The {call} certificate's passphrase was removed from your Keychain.", {{"call", c->call}})) severity:-1];
        }];
        [w addButton:@"No Certificate" trailing:NO action:^{
            auto done = ch.done;
            ch.passphrase.stringValue = @"";
            dismiss();
            if (done) done("", "");
        }];
        NSButton *saveButton = [w addButton:@"Save" trailing:YES action:^{ save(); }];
        [w setDefaultButton:saveButton];
    }
    ch.profile = profile;
    ch.done = done;
    ch.passphrase.stringValue = @"";
    load(call, serial);
    NSWindow *win = ch.w.window;
    if (win.sheetParent) return;  // open already
    if (parent.visible) {
        [win orderOut:nil];
        [parent beginSheet:win completionHandler:nil];
    } else {
        [ch.w show];
    }
}

}  // namespace tqslcert
