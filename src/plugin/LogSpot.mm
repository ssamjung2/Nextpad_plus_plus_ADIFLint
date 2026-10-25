#import "LogSpot.h"

#import "L10n.h"
#import "Network.h"
#import "Spots.h"

#include "PluginHost.h"
#include "adif_spots.h"

#include <cstdlib>
#include <ctime>
#include <map>

using adifhost::setting;
using adif::i18n::tr;
using adif::i18n::trf;

namespace logspot {

namespace {

// When each was last spotted, so it isn't again within 10 minutes: call|band on the cluster,
// park|band|mode on pota.app.
std::map<std::string, long long> clusterSpotted, potaSpotted;

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

std::string potaRef(const adif::FieldList &fields) {
    std::string ref = field(fields, "MY_POTA_REF");
    if (ref.empty() && upperText(field(fields, "MY_SIG")) == "POTA") ref = field(fields, "MY_SIG_INFO");
    return ref;
}

bool recent(const std::map<std::string, long long> &spotted, const std::string &key, long long now) {
    auto last = spotted.find(key);
    return last != spotted.end() && now - last->second < kRespot;
}

}  // namespace

bool clusterWanted() { return setting("spotClusterOnLog") == "1"; }
bool potaWanted() { return setting("spotPotaOnLog") == "1"; }

void setWanted(bool cluster, bool pota) {
    adifhost::setSetting("spotClusterOnLog", cluster ? "1" : "0");
    adifhost::setSetting("spotPotaOnLog", pota ? "1" : "0");
}

Ready ready(const adif::FieldList &fields, bool contest) {
    Ready r;
    std::string why = contest ? tr("Not during a contest: contests limit spotting.")
                      : ADIFOffline() ? tr("Not in Offline Mode.")
                                      : "";
    std::string node = spotfeeds::clusterNode();
    r.cluster = why.empty() && !node.empty();
    r.clusterTip = !why.empty() ? why
                   : node.empty()
                       ? tr("Spot each station you log on the DX cluster, once the Map's Spots layer is connected to one (Settings, Spots).")
                       : trf("Spot each station you log on the DX cluster ({node}), with the QSO's program, reference and mode as its "
                             "comment: never your own callsign, nor a station spotted on that band in the last 10 minutes.",
                             {{"node", node}});
    std::string ref = potaRef(fields);
    r.pota = why.empty() && !ref.empty();
    r.potaTip = !why.empty() ? why
                : ref.empty() ? tr("Spot yourself on pota.app during a POTA activation (Start Activation, or MY_POTA_REF).")
                              : trf("Open pota.app in your browser to spot yourself at {ref}: when you start, and again when the band or "
                                    "mode changes or 10 minutes have passed.",
                                    {{"ref", ref}});
    return r;
}

void afterLog(const adif::FieldList &fields, bool contest, bool cluster, bool pota, void (^said)(const std::string &text)) {
    if (contest || ADIFOffline() || (!cluster && !pota)) return;
    std::string call = upperText(field(fields, "CALL")), band = field(fields, "BAND");
    std::string sub = field(fields, "SUBMODE");
    std::string mode = upperText(sub.empty() ? field(fields, "MODE") : sub);
    double khz = std::atof(field(fields, "FREQ").c_str()) * 1000;
    std::string station = upperText(field(fields, "STATION_CALLSIGN"));
    std::string node = spotfeeds::clusterNode();
    std::string myCall = !node.empty() ? spotfeeds::clusterCall() : !station.empty() ? station : upperText(setting("stationCall"));
    long long now = (long long)time(nullptr);
    std::string text;
    auto add = [&](const std::string &part) { text += (text.empty() ? "" : " ") + part; };
    // Yourself on pota.app: its spots page, whose Spot button takes your call, park, frequency and mode.
    if (std::string ref = potaRef(fields); pota && !ref.empty()) {
        std::string key = ref + "|" + band + "|" + mode;
        if (recent(potaSpotted, key, now))
            add(tr("pota.app: opened for this park, band and mode in the last 10 minutes."));
        else if (ADIFOpenURL(@"https://pota.app/")) {
            potaSpotted[key] = now;
            add(trf("pota.app opened: spot {call} at {ref}, {khz} kHz {mode}.",
                    {{"call", myCall}, {"ref", ref}, {"khz", adif::spotKhz(khz * 1000)}, {"mode", mode}}));
        }
    }
    // The station worked, on the cluster: connected, a callsign that isn't yours, not spotted on this band in 10 minutes.
    if (cluster) {
        std::string key = call + "|" + band;
        std::string command = adif::clusterSpotCommand(call, khz, adif::qsoSpotComment(fields), myCall);
        if (node.empty())
            add(tr("DX cluster: not connected, so not spotted."));
        else if (recent(clusterSpotted, key, now))
            add(trf("DX cluster: {call} was spotted on {band} in the last 10 minutes.", {{"call", call}, {"band", band}}));
        else if (command.empty())
            add(tr("DX cluster: not sent (that callsign or frequency can't be spotted)."));
        else {
            std::string before = text;
            add(tr("DX cluster: sending..."));
            said(text);  // first: clusterPost answers at once when the connection is down
            text.clear();
            spotfeeds::clusterPost(command, call, ^(bool ok, const std::string &answer) {
                if (ok) clusterSpotted[key] = (long long)time(nullptr);
                said(before + (before.empty() ? "" : " ") +
                     (ok ? trf("DX cluster: spotted ({answer}).", {{"answer", answer}})
                         : trf("DX cluster: not spotted: {answer}", {{"answer", answer}})));
            });
        }
    }
    if (!text.empty()) said(text);
}

}  // namespace logspot
