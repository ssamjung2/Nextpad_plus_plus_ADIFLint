#import "SpotOffer.h"

#import "L10n.h"
#import "Network.h"
#import "Night.h"
#import "Spots.h"
#import "ToolWindow.h"

#include "PluginHost.h"
#include "adif_spots.h"

#include <cmath>
#include <ctime>
#include <map>

using adifhost::setting;
using adif::i18n::tr;
using adif::i18n::trf;

namespace spotoffer {

namespace {

struct {
    NSPanel *panel = nil;
    NSTextField *what = nil, *comment = nil, *status = nil;
    NSButton *cluster = nil, *pota = nil, *offer = nil, *send = nil, *skip = nil;
    std::string call, band, mode, myCall, potaRef;
    double khz = 0;
    std::map<std::string, long long> spotted;  // call|band: when you spotted it, so it isn't spotted again within 10 minutes
} o;

constexpr long long kRespot = 600;

std::string field(const adif::FieldList &fields, const char *name) {
    for (const auto &f : fields)
        if (f.first == name) return f.second;
    return "";
}

std::string upperText(std::string s) {
    for (char &c : s) c = (char)std::toupper((unsigned char)c);
    return s;
}

void setStatus(const std::string &text) { o.status.stringValue = ADIFString(text); }

void done() {
    o.send.enabled = NO;
    o.skip.title = T(@"Close");
}

void send() {
    bool cluster = !o.cluster.hidden && o.cluster.state == NSControlStateValueOn;
    bool pota = !o.pota.hidden && o.pota.state == NSControlStateValueOn;
    if (!cluster && !pota) return [o.panel orderOut:nil];
    std::string said;
    if (pota) {  // pota.app's spots page: its Spot button takes your call, park, frequency and mode
        if (ADIFOpenURL(@"https://pota.app/"))
            said = trf("pota.app opened: spot {call} at {ref}, {khz} kHz {mode}.",
                       {{"call", o.myCall}, {"ref", o.potaRef}, {"khz", adif::spotKhz(o.khz * 1000)}, {"mode", o.mode}});
    }
    if (cluster) {
        std::string command = adif::clusterSpotCommand(o.call, o.khz, ADIFStd(o.comment.stringValue), o.myCall);
        if (command.empty()) {
            setStatus(said + (said.empty() ? "" : " ") + tr("DX cluster: not sent (that callsign or frequency can't be spotted)."));
            return done();
        }
        std::string key = o.call + "|" + o.band;
        setStatus(said + (said.empty() ? "" : " ") + tr("DX cluster: sending..."));
        spotfeeds::clusterPost(command, o.call, ^(bool ok, const std::string &answer) {
            if (ok) o.spotted[key] = (long long)time(nullptr);
            setStatus(said + (said.empty() ? "" : " ") +
                      (ok ? trf("DX cluster: spotted ({answer}).", {{"answer", answer}})
                          : trf("DX cluster: not spotted: {answer}", {{"answer", answer}})));
        });
    } else {
        setStatus(said);
    }
    done();
}

void build() {
    if (o.panel) return;
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 220)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
                                              backing:NSBackingStoreBuffered
                                                defer:YES];
    p.title = T(@"Spot This QSO");
    p.identifier = @"spot.offer";
    p.releasedWhenClosed = NO;
    p.hidesOnDeactivate = NO;
    ADIFNightTrack(p);
    o.what = [NSTextField wrappingLabelWithString:@""];
    o.what.preferredMaxLayoutWidth = 420;
    o.cluster = ADIFCheckbox(@"DX cluster", YES);
    o.cluster.identifier = @"spot.offer.cluster";
    o.comment = [NSTextField textFieldWithString:@""];
    o.comment.identifier = @"spot.offer.comment";
    o.comment.placeholderString = T(@"comment");
    o.comment.toolTip = T(@"The spot's remarks: the program and reference, the mode, a name; at most 30 characters");
    [o.comment.widthAnchor constraintEqualToConstant:300].active = YES;
    o.pota = ADIFCheckbox(@"pota.app", YES);
    o.pota.identifier = @"spot.offer.pota";
    o.offer = ADIFCheckbox(@"Offer to spot after each QSO", YES);
    o.offer.identifier = @"spot.offer.again";
    o.offer.toolTip = T(@"Turn this offer off; Settings (Spots) turns it on again");
    ADIFOnAction(o.offer, ^{ setWanted(o.offer.state == NSControlStateValueOn); });
    o.status = [NSTextField wrappingLabelWithString:@""];
    o.status.preferredMaxLayoutWidth = 420;
    o.status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    o.status.textColor = NSColor.secondaryLabelColor;
    o.status.identifier = @"spot.offer.status";
    o.skip = [NSButton buttonWithTitle:T(@"Skip") target:nil action:nil];
    o.skip.identifier = @"spot.offer.skip";
    o.skip.keyEquivalent = @"\033";
    ADIFOnAction(o.skip, ^{ [o.panel orderOut:nil]; });
    o.send = [NSButton buttonWithTitle:T(@"Send") target:nil action:nil];
    o.send.identifier = @"spot.offer.send";
    o.send.keyEquivalent = @"\r";
    ADIFOnAction(o.send, ^{ send(); });
    NSStackView *commentRow = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Comment:"), o.comment ]];
    commentRow.spacing = 6;
    commentRow.edgeInsets = NSEdgeInsetsMake(0, 20, 0, 0);
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ o.offer, [NSView new], o.skip, o.send ]];
    buttons.distribution = NSStackViewDistributionFill;
    NSStackView *stack = [NSStackView stackViewWithViews:@[ o.what, o.cluster, commentRow, o.pota, o.status, buttons ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [p.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:p.contentView.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:p.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:p.contentView.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:p.contentView.bottomAnchor],
        [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-32],
        [stack.widthAnchor constraintGreaterThanOrEqualToConstant:440],
    ]];
    o.panel = p;
}

}  // namespace

bool wanted() {
    std::string v = setting("spotOfferAfterLog");
    return v.empty() || v == "1";
}

void setWanted(bool on) { adifhost::setSetting("spotOfferAfterLog", on ? "1" : "0"); }

void afterLog(const adif::FieldList &fields, bool contest) {
    if (!wanted() || contest || ADIFOffline()) return;
    o.call = upperText(field(fields, "CALL"));
    o.band = field(fields, "BAND");
    std::string sub = field(fields, "SUBMODE");
    o.mode = upperText(sub.empty() ? field(fields, "MODE") : sub);
    o.khz = std::atof(field(fields, "FREQ").c_str()) * 1000;
    std::string station = upperText(field(fields, "STATION_CALLSIGN"));
    std::string node = spotfeeds::clusterNode();
    o.myCall = !node.empty() ? spotfeeds::clusterCall() : !station.empty() ? station : upperText(setting("stationCall"));
    // The station worked, on the cluster: connected, a callsign that isn't yours, not spotted on this band in 10 minutes.
    long long now = (long long)time(nullptr);
    auto last = o.spotted.find(o.call + "|" + o.band);
    bool recent = last != o.spotted.end() && now - last->second < kRespot;
    std::string remarks = adif::qsoSpotComment(fields);
    bool cluster = !node.empty() && !recent && !adif::clusterSpotCommand(o.call, o.khz, remarks, o.myCall).empty();
    // Yourself on pota.app: a POTA activation's QSO.
    o.potaRef = field(fields, "MY_POTA_REF");
    if (o.potaRef.empty() && upperText(field(fields, "MY_SIG")) == "POTA") o.potaRef = field(fields, "MY_SIG_INFO");
    bool pota = !o.potaRef.empty();
    if (!cluster && !pota) return;
    build();
    o.what.stringValue = ADIFString(trf("Logged {call} on {khz} kHz {mode}. Spot it?",
                                        {{"call", o.call}, {"khz", adif::spotKhz(o.khz * 1000)}, {"mode", o.mode}}));
    o.cluster.hidden = !cluster;
    o.comment.superview.hidden = !cluster;
    o.cluster.title = ADIFString(trf("{call} on the DX cluster ({node})", {{"call", o.call}, {"node", node}}));
    o.cluster.state = NSControlStateValueOn;
    o.comment.stringValue = ADIFString(remarks);
    o.pota.hidden = !pota;
    o.pota.title = ADIFString(trf("Yourself ({call}) at {ref} on pota.app, in your browser", {{"call", o.myCall}, {"ref", o.potaRef}}));
    o.pota.state = NSControlStateValueOn;
    o.offer.state = NSControlStateValueOn;
    o.send.enabled = YES;
    o.skip.title = T(@"Skip");
    setStatus("");
    [o.panel.contentView layoutSubtreeIfNeeded];
    [o.panel setContentSize:o.panel.contentView.fittingSize];
    if (!o.panel.visible) [o.panel center];
    [o.panel orderFront:nil];
}

}  // namespace spotoffer
