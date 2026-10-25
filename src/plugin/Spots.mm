#import "Spots.h"
#import "L10n.h"
#import "Lookup.h"
#import "Network.h"
#import "PluginHost.h"
#import "ToolWindow.h"

#import <Network/Network.h>

#include "adif_edit.h"
#include "adif_geo.h"
#include "adif_programs.h"
#include "adif_spec.h"
#include "adif_tools.h"

#include <algorithm>
#include <cmath>
#include <ctime>

NSString *const ADIFSpotsChangedNotification = @"ADIFSpotsChanged";

using namespace adifhost;

namespace {

std::string upperText(std::string s) {
    for (char &c : s) c = (char)std::toupper((unsigned char)c);
    return s;
}

// A JSON value as printable ASCII text, at most `limit` characters.
std::string jsonText(NSDictionary *d, NSString *key, size_t limit = 120) {
    id v = d[key];
    NSString *s = [v isKindOfClass:NSString.class] ? v : [v isKindOfClass:NSNumber.class] ? [v stringValue] : nil;
    std::string out;
    for (char c : (s ? ADIFStd(s) : std::string()))
        if (c >= 32 && c < 127 && out.size() < limit) out.push_back(c);
    return out;
}

bool jsonNumber(NSDictionary *d, NSString *key, double *out) {
    id v = d[key];
    if (![v isKindOfClass:NSNumber.class]) return false;
    double x = [v doubleValue];
    if (!std::isfinite(x)) return false;
    *out = x;
    return true;
}

NSString *agent() {
    return [NSString stringWithFormat:@"ADIF Lint/%s (Nextpad++ plugin; https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint)", ADIFLINT_VERSION];
}

}  // namespace

adif::Spot ADIFSpotholeSpot(NSDictionary *d, long long *received) {
    adif::Spot sp;
    sp.source = adif::SpotSource::Spothole;
    sp.activator = upperText(jsonText(d, @"dx_call", 20));
    double hz = 0;
    if (sp.activator.empty() || !jsonNumber(d, @"freq", &hz) || !(hz > 0)) return adif::Spot();
    sp.khz = adif::spotKhz(hz);
    if (adif::khzToMHz(sp.khz).empty()) return adif::Spot();
    double t = 0;
    sp.epoch = jsonNumber(d, @"time", &t) && t > 0 ? (long long)t : adif::spotEpoch(jsonText(d, @"time_iso", 40));
    sp.time = adif::spotTime(sp.epoch);
    sp.mode = upperText(jsonText(d, @"mode", 12));
    NSArray *acts = [d[@"activities"] isKindOfClass:NSArray.class] ? d[@"activities"] : @[];
    if (acts.count && [acts[0] isKindOfClass:NSString.class]) sp.program = jsonText(@{@"a" : acts[0]}, @"a", 30);
    NSArray *refs = [d[@"activity_refs"] isKindOfClass:NSArray.class] ? d[@"activity_refs"] : @[];
    for (id r in refs) {
        if (![r isKindOfClass:NSDictionary.class]) continue;
        std::string ref = upperText(jsonText(r, @"id", 30));
        if (ref.empty()) continue;
        sp.refs.push_back(ref);
        if (sp.park.empty()) sp.park = jsonText(r, @"name");
        if (sp.grid.empty()) sp.grid = jsonText(r, @"grid", 10);
    }
    bool good = [d[@"dx_location_good"] isEqual:@YES];
    if (sp.grid.empty() && good) sp.grid = jsonText(d, @"dx_grid", 10);
    double lat = 0, lon = 0;
    if (jsonNumber(d, @"dx_latitude", &lat) && jsonNumber(d, @"dx_longitude", &lon))
        sp.placeGiven = true, sp.placeExact = good, sp.lat = lat, sp.lon = lon;
    if (jsonNumber(d, @"de_latitude", &lat) && jsonNumber(d, @"de_longitude", &lon)) sp.spotterPlaceGiven = true, sp.spotterLat = lat, sp.spotterLon = lon;
    sp.spotterGrid = jsonText(d, @"de_grid", 10);
    sp.reference = sp.refs.empty() ? "" : sp.refs[0] + (sp.refs.size() > 1 ? " +" + std::to_string(sp.refs.size() - 1) : "");
    sp.location = jsonText(d, @"source", 20);  // Spothole's source: Cluster, RBN, POTA...
    sp.spotter = upperText(jsonText(d, @"de_call", 20));
    sp.comments = jsonText(d, @"comment");
    sp.hasSnr = adif::commentReport(sp.comments, &sp.snr);  // an RBN spot's "20 dB"
    sp.band = adif::bandForFrequency(adif::khzToMHz(sp.khz));
    std::string id = jsonText(d, @"id", 80);
    sp.key = id.empty() ? sp.activator + "|" + sp.reference + "|" + sp.khz + "|" + sp.mode : id;
    if (received) *received = jsonNumber(d, @"received_time", &t) && t > 0 ? (long long)t : 0;
    return sp;
}

namespace spotfeeds {

const Node kNodes[] = {
    // DXSpider wiki, How to connect (edited 2025-02-11): G1FEF's node; "set/skimmer" adds RBN spots.
    {"dxc.hamserve.uk", 7300, N_("a DXSpider node (G1FEF); after logging in, set/skimmer adds RBN spots")},
    // Spothole's telnet help (read 2026-10-19): its own DXSpider node.
    {"spothole.app", 7300, N_("Spothole's DXSpider node")},
};
const size_t kNodeCount = sizeof kNodes / sizeof kNodes[0];

namespace {

constexpr double kSpotholeEvery = 120;  // Spothole reads POTA every 2 minutes; asking faster gains nothing
constexpr double kSpotholeRefresh = 60;  // Refresh asks Spothole again at most once a minute
constexpr long long kPskEvery = 300;    // PSKReporter: "no more often than once every five minutes"
constexpr long long kPskGridWindow = 1800;  // around a square: the last half hour (an hour can be 1,500 reports)
constexpr long long kKeep = 3600;       // spots older than an hour go (Spothole keeps about an hour)
const int kRetry[] = {15, 30, 60, 120, 300, 600};  // seconds before reconnecting a cluster, one step each failure

struct {
    bool wanted = false;
    adif::SpotList list{3000};
    NSTimer *prune = nil;
    bool notifyQueued = false;
    id offlineObserver = nil;
    // Spothole
    NSTimer *spotholeTimer = nil;
    bool spotholeBusy = false;
    double spotholeAsked = 0;
    long long receivedSince = 0;
    std::vector<std::string> programs;
    std::string spotholeStatus;
    long long updated = 0;  // when a feed last brought spots (lastUpdate)
    // A source in trouble (troubled()): its last request failed, or the cluster is down.
    bool spotholeTrouble = false, clusterTrouble = false, pskTrouble = false;
    // DX cluster
    nw_connection_t conn = nil;
    int generation = 0;
    adif::TelnetLines telnet;
    bool loginSent = false, stopped = false;
    double connectedAt = 0, loginAt = 0;
    int failures = 0;
    NSTimer *retry = nil, *loginTimer = nil;
    std::string clusterStatus;
    size_t clusterSpots = 0;
    // Posting a spot: the command's call, and what to tell when the node answers.
    std::string postCall;
    void (^postDone)(bool, const std::string &) = nil;
    NSTimer *postTimer = nil;
    // PSKReporter
    std::string homeGrid, focusCall;
    NSTimer *pskTimer = nil;
    bool pskBusy = false;
    std::string pskStatus;
} f;

void changed() {
    if (f.notifyQueued) return;
    f.notifyQueued = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 2)), dispatch_get_main_queue(), ^{
        f.notifyQueued = false;
        [[NSNotificationCenter defaultCenter] postNotificationName:ADIFSpotsChangedNotification object:nil];
    });
}

std::string myCall(const Config &c) {
    std::string call = upperText(c.login.empty() ? setting("stationCall") : c.login);
    call.erase(std::remove_if(call.begin(), call.end(), [](char ch) { return ch == ' '; }), call.end());
    return call;
}

// ── Spothole ──

void spotholeFetch() {
    if (f.spotholeBusy) return;
    double now = CFAbsoluteTimeGetCurrent();
    if (f.spotholeAsked > 0 && now - f.spotholeAsked < kSpotholeEvery - 5) return;
    f.spotholeBusy = true;
    f.spotholeAsked = now;
    void (^fetch)(void) = ^{
        std::string csv;
        for (const std::string &p : f.programs) csv += p + ",";
        csv += "NO_ACTIVITY";  // plain DX spots: the clusters and the RBN Spothole reads
        ADIFFetchSpotholeMapSpots(agent(), ADIFString(csv), f.receivedSince, kKeep, ^(NSArray<NSDictionary *> *list, NSString *error) {
            f.spotholeBusy = false;
            if (!f.wanted) return;
            if (error) {
                f.spotholeStatus = trf("Spothole: {why}", {{"why", ADIFStd(error)}});
            f.spotholeTrouble = true;
                f.spotholeTrouble = true;
                changed();
                return;
            }
            size_t n = 0;
            for (NSDictionary *d in list) {
                long long received = 0;
                adif::Spot sp = ADIFSpotholeSpot(d, &received);
                if (sp.activator.empty() || adif::equalsNoCase(sp.program, "SOTA") || adif::equalsNoCase(sp.location, "SOTA")) continue;
                f.receivedSince = std::max(f.receivedSince, received);
                f.list.add(std::move(sp));
                ++n;
            }
            f.spotholeTrouble = false;
            f.spotholeStatus = trp("Spothole: {n} new spot at {time} UTC (every 2 minutes)", "Spothole: {n} new spots at {time} UTC (every 2 minutes)",
                                   (long long)n, {{"time", utcNow("%H:%M")}});
            f.updated = (long long)time(nullptr);
            changed();
        });
    };
    if (!f.programs.empty()) return fetch();
    ADIFFetchSpotholePrograms(agent(), ^(NSArray<NSDictionary *> *programs, NSString *error) {
        if (error) {
            f.spotholeBusy = false;
            f.spotholeStatus = trf("Spothole: {why}", {{"why", ADIFStd(error)}});
            changed();
            return;
        }
        for (NSDictionary *a in programs) {
            std::string name = jsonText(a, @"name", 40), type = jsonText(a, @"activity_type", 20);
            if (adif::spotholeProgramWanted(name, type, [a[@"has_refs"] isEqual:@YES]) || name == "POTA" || name == "WWFF")
                f.programs.push_back(name);
        }
        fetch();
    });
}

// ── DX cluster ──

void clusterConnect();

void clusterSend(const std::string &bytes) {
    if (!f.conn || bytes.empty()) return;
    dispatch_data_t data = dispatch_data_create(bytes.data(), bytes.size(), dispatch_get_main_queue(), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(f.conn, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t) {});
}

void clusterClose() {
    ++f.generation;
    if (f.postDone) {
        auto d = f.postDone;
        f.postDone = nil;
        [f.postTimer invalidate], f.postTimer = nil;
        d(false, tr("the connection closed"));
    }
    if (f.conn) nw_connection_cancel(f.conn);
    f.conn = nil;
    [f.retry invalidate], f.retry = nil;
    [f.loginTimer invalidate], f.loginTimer = nil;
}

// The connection ended: try again later, a step longer each time it fails soon after starting.
void clusterLost(const std::string &why) {
    clusterClose();
    if (!f.wanted || f.stopped) return;
    if (f.connectedAt > 0 && CFAbsoluteTimeGetCurrent() - f.connectedAt > 300) f.failures = 0;
    int wait = kRetry[std::min<size_t>((size_t)f.failures, sizeof kRetry / sizeof kRetry[0] - 1)];
    ++f.failures;
    f.clusterStatus = trf("DX cluster: {why}; trying again in {n} s.", {{"why", why}, {"n", std::to_string(wait)}});
    f.clusterTrouble = true;
    changed();
    f.retry = [NSTimer scheduledTimerWithTimeInterval:wait repeats:NO block:^(NSTimer *) {
        f.retry = nil;
        clusterConnect();
    }];
}

// Stop for good (until Settings change): the node refused the login or wants a password.
void clusterStop(const std::string &why) {
    clusterClose();
    f.stopped = true;
    f.clusterStatus = why;
    f.clusterTrouble = true;
    changed();
}

void clusterLogin() {
    if (f.loginSent || !f.conn) return;
    Config c = config();
    std::string call = myCall(c);
    f.loginSent = true;
    f.loginAt = CFAbsoluteTimeGetCurrent();
    f.telnet.clearPending();  // the prompt is answered
    [f.loginTimer invalidate], f.loginTimer = nil;
    clusterSend(call + "\r\n");
    for (size_t b = 0; b <= c.commands.size();) {  // the commands after logging in, ";" between
        size_t e = c.commands.find(';', b);
        if (e == std::string::npos) e = c.commands.size();
        std::string cmd = c.commands.substr(b, e - b);
        while (!cmd.empty() && cmd.front() == ' ') cmd.erase(cmd.begin());
        while (!cmd.empty() && cmd.back() == ' ') cmd.pop_back();
        if (!cmd.empty()) clusterSend(cmd + "\r\n");
        b = e + 1;
    }
    f.clusterStatus = trf("DX cluster: connected to {node} as {call}.", {{"node", c.host + ":" + std::to_string(c.port)}, {"call", call}});
    f.clusterTrouble = false;
    changed();
}

void clusterRead(const std::string &bytes) {
    std::vector<std::string> lines;
    std::string reply;
    f.telnet.feed(bytes, &lines, &reply);
    clusterSend(reply);
    long long now = (long long)time(nullptr);
    bool loggingIn = !f.loginSent || CFAbsoluteTimeGetCurrent() - f.loginAt < 10;  // a refusal comes right after the call
    Config c = config();
    std::string node = c.host + ":" + std::to_string(c.port);
    size_t added = 0;
    for (const std::string &line : lines) {
        if (loggingIn) {
            adif::ClusterPrompt p = adif::clusterPrompt(line);
            if (p == adif::ClusterPrompt::Refused)
                return clusterStop(trf("DX cluster: {node} refused the login: {line}", {{"node", node}, {"line", line}}));
            if (p == adif::ClusterPrompt::Password)
                return clusterStop(trf("DX cluster: {node} asks for a password; ADIF Lint doesn't log in with one. Choose another node in Settings.",
                                       {{"node", node}}));
            if (p == adif::ClusterPrompt::Login && !f.loginSent) clusterLogin();
        }
        if (f.postDone) {  // a spot posted: the node's echo of it, or a refusal
            adif::ClusterPostAnswer a = adif::clusterPostAnswer(line, myCall(c), f.postCall, now);
            if (a != adif::ClusterPostAnswer::None) {
                auto done = f.postDone;
                f.postDone = nil;
                [f.postTimer invalidate], f.postTimer = nil;
                done(a == adif::ClusterPostAnswer::Accepted, line);
            }
        }
        adif::Spot sp;
        if (adif::parseClusterSpot(line, now, &sp)) f.list.add(std::move(sp)), ++added;
    }
    if (!f.loginSent) {
        adif::ClusterPrompt p = adif::clusterPrompt(f.telnet.pending());
        if (p == adif::ClusterPrompt::Login) clusterLogin();
        else if (p == adif::ClusterPrompt::Password)
            return clusterStop(trf("DX cluster: {node} asks for a password; ADIF Lint doesn't log in with one. Choose another node in Settings.",
                                   {{"node", node}}));
    }
    if (added) {
        f.clusterSpots += added;
        f.updated = (long long)time(nullptr);
        changed();
    }
}

void clusterReceive(nw_connection_t conn, int gen) {
    nw_connection_receive(conn, 1, 65536, ^(dispatch_data_t content, nw_content_context_t, bool complete, nw_error_t error) {
        if (gen != f.generation) return;
        if (content) {
            __block std::string bytes;
            dispatch_data_apply(content, ^bool(dispatch_data_t, size_t, const void *buffer, size_t size) {
                bytes.append((const char *)buffer, size);
                return true;
            });
            clusterRead(bytes);
            if (gen != f.generation) return;  // stopped while reading
        }
        if (error || complete) {
            std::string why = error ? trf("the connection ended (error {n})", {{"n", std::to_string(nw_error_get_error_code(error))}})
                                    : tr("the node closed the connection");
            return clusterLost(why);
        }
        clusterReceive(conn, gen);
    });
}

void clusterConnect() {
    Config c = config();
    std::string call = myCall(c);
    if (c.host.empty() || c.port <= 0 || c.port > 65535) {
        f.clusterStatus = tr("DX cluster: choose a node in Settings (Spots).");
        f.clusterTrouble = true;
        return changed();
    }
    if (call.empty()) {
        f.clusterStatus = tr("DX cluster: it logs in with your callsign: add it in Settings (Your Station).");
        f.clusterTrouble = true;
        return changed();
    }
    clusterClose();
    int gen = f.generation;
    f.telnet = adif::TelnetLines(1024);
    f.loginSent = false;
    f.connectedAt = 0;
    std::string node = c.host + ":" + std::to_string(c.port);
    f.clusterStatus = trf("DX cluster: connecting to {node}...", {{"node", node}});
    changed();
    nw_endpoint_t endpoint = nw_endpoint_create_host(c.host.c_str(), std::to_string(c.port).c_str());
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, ^(nw_protocol_options_t tcp) {
        nw_tcp_options_set_connection_timeout(tcp, 20);
        nw_tcp_options_set_enable_keepalive(tcp, true);
    });
    nw_connection_t conn = nw_connection_create(endpoint, params);
    f.conn = conn;
    nw_connection_set_queue(conn, dispatch_get_main_queue());
    nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state, nw_error_t error) {
        if (gen != f.generation) return;
        if (state == nw_connection_state_ready) {
            f.connectedAt = CFAbsoluteTimeGetCurrent();
            f.clusterStatus = trf("DX cluster: connected to {node}, logging in...", {{"node", node}});
            changed();
            clusterReceive(conn, gen);
            // No prompt seen in 15 s (a node that words it its own way): send the callsign anyway.
            f.loginTimer = [NSTimer scheduledTimerWithTimeInterval:15 repeats:NO block:^(NSTimer *) {
                f.loginTimer = nil;
                if (gen == f.generation) clusterLogin();
            }];
        } else if (state == nw_connection_state_failed || state == nw_connection_state_waiting) {
            clusterLost(error ? trf("couldn't connect to {node} (error {n})", {{"node", node}, {"n", std::to_string(nw_error_get_error_code(error))}})
                              : trf("couldn't connect to {node}", {{"node", node}}));
        }
    });
    nw_connection_start(conn);
}

// ── PSKReporter ──

// The callsign PSKReporter is asked about: the Map's Only spots of, else Settings', else Your
// Station's; never the cluster's login.
std::string pskCall(const Config &c) {
    std::string call = upperText(!f.focusCall.empty() ? f.focusCall : c.pskCall.empty() ? setting("stationCall") : c.pskCall);
    call.erase(std::remove_if(call.begin(), call.end(), [](char ch) { return ch == ' '; }), call.end());
    return call;
}

void pskFetch() {
    if (f.pskBusy) return;
    Config c = config();
    std::string call = pskCall(c);
    bool around = c.pskQuery == 1;
    std::string square = upperText(setting("stationGrid").empty() ? f.homeGrid : setting("stationGrid")).substr(0, 4);
    double lat, lon;
    if (around && (square.size() < 4 || !adif::gridToLatLon(square, &lat, &lon))) {
        f.pskStatus = tr("PSKReporter: it asks around your grid square: add your grid in Settings (Your Station).");
        f.pskTrouble = true;
        return changed();
    }
    if (!around && call.empty()) {
        f.pskStatus = tr("PSKReporter: it asks who hears your callsign: add it in Settings (Your Station).");
        f.pskTrouble = true;
        return changed();
    }
    long long now = (long long)time(nullptr), last = std::atoll(setting("spotsPskLast").c_str());
    if (last > 0 && last <= now && now - last < kPskEvery) {  // asked less than five minutes ago (the timer tries again)
        if (f.pskStatus.empty())
            f.pskStatus = trf("PSKReporter: asked at most once in 5 minutes; next at {time} UTC.", {{"time", adif::spotTime(last + kPskEvery)}}), changed();
        return;
    }
    setSetting("spotsPskLast", std::to_string(now));
    f.pskBusy = true;
    NSString *url = ADIFString(adif::pskQueryUrl(around ? square : call, around ? adif::PskQuery::Grid : adif::PskQuery::Callsign,
                                                 around ? kPskGridWindow : kKeep, c.email));
    ADIFFetchPskReports(agent(), url, ^(NSData *xml, NSString *error) {
        f.pskBusy = false;
        if (!f.wanted) return;
        std::vector<adif::Spot> reports;
        std::string why = error ? ADIFStd(error) : "";
        if (!error && !adif::parsePskReports(std::string_view((const char *)xml.bytes, xml.length), &reports, &why, 2000, call)) error = @"";
        if (error) {
            f.pskStatus = trf("PSKReporter: {why}", {{"why", why}});
            f.pskTrouble = true;
            return changed();
        }
        size_t n = reports.size();
        f.pskTrouble = false;
        f.list.replace(adif::SpotSource::PskReporter, std::move(reports));
        f.updated = (long long)time(nullptr);
        f.pskStatus = around ? trp("PSKReporter: {n} report around {grid} in the last half hour, at {time} UTC (every 5 minutes)",
                                   "PSKReporter: {n} reports around {grid} in the last half hour, at {time} UTC (every 5 minutes)", (long long)n,
                                   {{"grid", square}, {"time", utcNow("%H:%M")}})
                             : trp("PSKReporter: {n} report of {call} in the last hour, at {time} UTC (every 5 minutes)",
                                   "PSKReporter: {n} reports of {call} in the last hour, at {time} UTC (every 5 minutes)", (long long)n,
                                   {{"call", call}, {"time", utcNow("%H:%M")}});
        // None of your callsign: reports come from transmitting on a digital mode, or from a program
        // that uploads what it hears (WSJT-X User Guide 3.2.0, 6.5 Reporting).
        if (n == 0 && !around)
            f.pskStatus += " " + tr("Reports come when you transmit on a digital mode, or when your program uploads what it hears (WSJT-X: "
                                    "Settings, Reporting, Enable PSK Reporter Spotting). Or choose Around my grid square in Settings (Spots).");
        changed();
    });
}

// ── Starting and stopping ──

void stopAll() {
    [f.spotholeTimer invalidate], f.spotholeTimer = nil;
    [f.pskTimer invalidate], f.pskTimer = nil;
    [f.prune invalidate], f.prune = nil;
    clusterClose();
}

void restart() {
    stopAll();
    if (!f.offlineObserver)
        f.offlineObserver = [[NSNotificationCenter defaultCenter] addObserverForName:ADIFOfflineChangedNotification
                                                                              object:nil
                                                                               queue:nil
                                                                          usingBlock:^(NSNotification *) { restart(); }];
    Config c = config();
    // What Spothole and PSKReporter said last still holds (their lists are kept); the cluster starts again.
    f.clusterStatus.clear();
    if (!c.spothole || f.spotholeStatus == ADIFStd(ADIFOfflineReason())) f.spotholeStatus.clear();
    if (!c.psk) f.pskStatus.clear();
    if (!f.wanted) return changed();
    if (ADIFOffline()) {
        f.spotholeStatus = ADIFStd(ADIFOfflineReason());
        return changed();
    }
    if (c.spothole) {
        spotholeFetch();  // unless it was asked in the last 2 minutes
        f.spotholeTimer = [NSTimer scheduledTimerWithTimeInterval:kSpotholeEvery repeats:YES block:^(NSTimer *) { spotholeFetch(); }];
    }
    if (c.cluster) {
        f.stopped = false, f.failures = 0;
        clusterConnect();
    }
    if (c.psk) {
        pskFetch();
        f.pskTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *) { pskFetch(); }];  // asks only every five minutes
    }
    f.prune = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *) {
        size_t before = f.list.spots().size();
        f.list.prune((long long)time(nullptr), kKeep);
        if (f.list.spots().size() != before) changed();
    }];
    changed();
}

}  // namespace

void setWanted(bool w) {
    if (w == f.wanted) return;
    f.wanted = w;
    restart();
}

bool wanted() { return f.wanted; }

void setHomeGrid(const std::string &grid) { f.homeGrid = grid; }

void setFocusCall(const std::string &call) {
    std::string c = upperText(call);
    if (c == f.focusCall) return;
    Config cfg = config();
    std::string was = pskCall(cfg);
    f.focusCall = c;
    if (cfg.pskQuery == 0 && pskCall(cfg) != was) {  // the reports were another station's
        f.list.clear(adif::SpotSource::PskReporter);
        f.pskStatus.clear();
        if (f.wanted && config().psk && !ADIFOffline()) pskFetch();
        changed();
    }
}

std::string clusterNode() {
    if (!f.conn || !f.loginSent || f.stopped) return "";
    Config c = config();
    return c.host + ":" + std::to_string(c.port);
}

std::string clusterCall() { return clusterNode().empty() ? "" : myCall(config()); }

void clusterPost(const std::string &command, const std::string &call, void (^done)(bool ok, const std::string &said)) {
    if (clusterNode().empty() || command.empty()) return done(false, tr("the DX cluster isn't connected"));
    if (f.postDone) f.postDone(false, tr("replaced by a newer spot")), f.postDone = nil;
    [f.postTimer invalidate];
    f.postCall = call;
    f.postDone = done;
    clusterSend(command + "\r\n");
    f.postTimer = [NSTimer scheduledTimerWithTimeInterval:10 repeats:NO block:^(NSTimer *) {
        f.postTimer = nil;
        if (!f.postDone) return;
        auto d = f.postDone;
        f.postDone = nil;
        d(true, tr("sent; the node didn't echo it"));
    }];
}

const adif::SpotList &spots() { return f.list; }

std::string refreshNow() {
    Config c = config();
    if (!f.wanted) return tr("Tick Show under Spots to fetch them.");
    if (ADIFOffline()) return ADIFStd(ADIFOfflineReason());
    if (!c.spothole && !c.cluster && !c.psk) return tr("No spot source is turned on: choose them in Settings (Spots).");
    std::vector<std::string> said;
    if (c.spothole) {
        double now = CFAbsoluteTimeGetCurrent();
        if (f.spotholeBusy) said.push_back(tr("Spothole: asking now."));
        else if (f.spotholeAsked > 0 && now - f.spotholeAsked < kSpotholeRefresh)
            said.push_back(tr("Spothole: asked less than a minute ago."));
        else {
            f.spotholeAsked = 0;
            spotholeFetch();
            [f.spotholeTimer invalidate];  // the next round 2 minutes from now
            f.spotholeTimer = [NSTimer scheduledTimerWithTimeInterval:kSpotholeEvery repeats:YES block:^(NSTimer *) { spotholeFetch(); }];
            said.push_back(tr("Spothole: asking now."));
        }
    }
    if (c.cluster) {
        if (f.stopped) said.push_back(f.clusterStatus);  // why it stopped; Settings must change first
        else if (f.retry) {
            [f.retry invalidate], f.retry = nil;
            clusterConnect();
            said.push_back(tr("DX cluster: connecting now."));
        } else if (f.conn) said.push_back(tr("DX cluster: connected; spots arrive as the node sends them."));
        else if (!f.clusterStatus.empty()) said.push_back(f.clusterStatus);
    }
    if (c.psk) {
        long long now = (long long)time(nullptr), last = std::atoll(setting("spotsPskLast").c_str());
        if (f.pskBusy) said.push_back(tr("PSKReporter: asking now."));
        else if (last > 0 && last <= now && now - last < kPskEvery)
            said.push_back(trf("PSKReporter: asked at most once in 5 minutes; next at {time} UTC.", {{"time", adif::spotTime(last + kPskEvery)}}));
        else {
            pskFetch();
            said.push_back(f.pskBusy ? tr("PSKReporter: asking now.") : f.pskStatus);
        }
    }
    {
        size_t before = f.list.spots().size();
        f.list.prune((long long)time(nullptr), kKeep);
        if (f.list.spots().size() != before) changed();
    }
    std::string out;
    for (const std::string &s : said)
        if (!s.empty()) out += (out.empty() ? "" : " ") + s;
    return out;
}

long long lastUpdate() { return f.updated; }

std::vector<std::string> troubled() {
    std::vector<std::string> out;
    if (!f.wanted) return out;
    Config c = config();
    if (ADIFOffline()) {
        if (c.spothole || c.cluster || c.psk) out.push_back(tr("Offline Mode"));
        return out;
    }
    if (c.spothole && f.spotholeTrouble) out.push_back("Spothole");
    if (c.cluster && f.clusterTrouble) out.push_back(tr("DX cluster"));
    if (c.psk && f.pskTrouble) out.push_back("PSKReporter");
    return out;
}

std::string status() {
    std::string out;
    for (const std::string *s : {&f.spotholeStatus, &f.clusterStatus, &f.pskStatus})
        if (!s->empty()) out += (out.empty() ? "" : "\n") + *s;
    return out;
}

Config config() {
    Config c;
    auto flag = [](const char *key, bool fallback) {
        std::string v = setting(key);
        return v.empty() ? fallback : v == "1";
    };
    c.spothole = flag("spotsSpothole", true);
    c.cluster = flag("spotsCluster", false);
    c.host = setting("spotsClusterHost");
    c.port = std::atoi(setting("spotsClusterPort").c_str());
    c.login = setting("spotsClusterLogin");
    c.commands = setting("spotsClusterCommands");
    c.psk = flag("spotsPsk", false);
    c.pskQuery = std::clamp(std::atoi(setting("spotsPskQuery").c_str()), 0, 1);
    c.pskCall = setting("spotsPskCall");
    c.email = setting("spotsPskEmail");
    return c;
}

void setConfig(const Config &c) {
    Config was = config();
    setSetting("spotsSpothole", c.spothole ? "1" : "0");
    setSetting("spotsCluster", c.cluster ? "1" : "0");
    setSetting("spotsClusterHost", c.host);
    setSetting("spotsClusterPort", c.port > 0 ? std::to_string(c.port) : "");
    setSetting("spotsClusterLogin", c.login);
    setSetting("spotsClusterCommands", c.commands);
    setSetting("spotsPsk", c.psk ? "1" : "0");
    setSetting("spotsPskQuery", std::to_string(c.pskQuery));
    setSetting("spotsPskCall", c.pskCall);
    setSetting("spotsPskEmail", c.email);
    if (c.spothole && !was.spothole) f.spotholeAsked = 0;  // turned on: ask at once
    if (c.pskQuery != was.pskQuery || c.pskCall != was.pskCall) f.pskStatus.clear();
    // A feed turned off takes its spots with it.
    if (!c.spothole && was.spothole) f.list.clear(adif::SpotSource::Spothole), f.receivedSince = 0;
    if (!c.cluster && was.cluster) f.list.clear(adif::SpotSource::Cluster);
    if ((!c.psk && was.psk) || c.pskQuery != was.pskQuery || c.pskCall != was.pskCall) f.list.clear(adif::SpotSource::PskReporter);
    if (c.host != was.host || c.port != was.port || c.login != was.login) f.list.clear(adif::SpotSource::Cluster);
    if (f.wanted) restart();
    else changed();
}

}  // namespace spotfeeds
