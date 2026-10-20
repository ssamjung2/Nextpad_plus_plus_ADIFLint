// The spot feeds behind the Map's Spots layer: Spothole, a DX cluster (telnet, your callsign as
// the login) and PSKReporter (who hears your callsign). Each runs only while the layer shows
// and only if it is turned on in Settings → Spots; none runs in offline mode. Their spots go
// into one list; ADIFSpotsChangedNotification says it changed.
// AppKit, Foundation and Network.framework.
#pragma once

#import <Cocoa/Cocoa.h>

#include "adif_spots.h"

#include <string>

extern NSString *const ADIFSpotsChangedNotification;

// A Spothole spot (GET /api/v3/spots): dx_call, freq (Hz), mode, time (Unix seconds) or time_iso,
// activities (the first is the program), activity_refs (id, name, grid), dx_grid, dx_latitude and
// dx_longitude with dx_location_good, de_call, de_grid, de_latitude and de_longitude, comment,
// source, id. Empty activator when it isn't usable. Spothole's received_time goes to `received`.
adif::Spot ADIFSpotholeSpot(NSDictionary *d, long long *received = nullptr);

namespace spotfeeds {

// The Map's Spots layer turned on or off (or the Map closed): the feeds turned on in Settings
// start or stop.
void setWanted(bool wanted);
// The Map's home grid (Settings, else the log's most used MY_GRIDSQUARE), for PSKReporter's
// Around my grid square when Settings has no grid.
void setHomeGrid(const std::string &grid);
// The Map's "Only spots of" callsign ("" none): PSKReporter asks about it while it is set (Of my
// callsign), in place of Settings' callsign, so the Map shows who heard that station.
void setFocusCall(const std::string &call);

// Posting a spot on the DX cluster (after New QSO logs a QSO, when you say Send). The node and
// callsign of the connection when it is logged in, else "".
std::string clusterNode();
std::string clusterCall();
// Sends `command` (adif::clusterSpotCommand's) on the connection; `done` gets whether the node took
// it and what it said: its echo of the spot, a refusal ("Sorry..."), or nothing within 10 s (sent,
// unconfirmed: ok). Fails at once when the cluster isn't connected.
void clusterPost(const std::string &command, const std::string &call, void (^done)(bool ok, const std::string &said));
bool wanted();
// Every spot the feeds have now, newest first.
const adif::SpotList &spots();
// What each feed is doing, one line each, for the Map ("DX cluster: connected to ...").
std::string status();
// The Map's Refresh: each feed turned on asks again now, within its limits. Spothole is asked
// unless it was asked in the last minute (and its 2-minute round starts again); PSKReporter only
// when 5 minutes have passed since it was last asked, as it asks; a DX cluster waiting to
// reconnect connects now (a connected one sends its spots as they come). Says what each did.
std::string refreshNow();

// Settings → Spots, saved in ADIFLint.ini.
struct Config {
    bool spothole = true;
    bool cluster = false;
    std::string host, login, commands;  // login: "" is Your Station's callsign; commands: sent after it, ";" between
    int port = 0;
    bool psk = false;
    int pskQuery = 0;   // PSKReporter: 0 a callsign on either side (who heard it, what it heard), 1 around your grid square
    std::string pskCall;  // PSKReporter's callsign: "" is Your Station's
    std::string email;  // PSKReporter's appcontact, when given
};
Config config();
void setConfig(const Config &c);  // saved, then the feeds restart as needed

// The cluster nodes Settings suggests: host, port and a note.
struct Node {
    const char *host;
    int port;
    const char *note;
};
extern const Node kNodes[];
extern const size_t kNodeCount;

}  // namespace spotfeeds
