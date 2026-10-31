// The spot feeds behind the Map's Spots layer: Spothole, a DX cluster (telnet, your callsign as
// the login) and PSKReporter (who hears your callsign). Each runs only while the layer shows
// and only if it is turned on in Settings → Spots; none runs in offline mode. Their spots go
// into one list; ADIFSpotsChangedNotification says it changed.
// AppKit, Foundation and Network.framework.
#pragma once

#import <Cocoa/Cocoa.h>

#include "adif_spots.h"

#include <string>
#include <string_view>
#include <vector>

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
// callsign), in place of Settings' callsign, so the Map shows who heard that station. PSKReporter's
// live feed (MQTT, mqtt.pskreporter.info) streams its reports as they are made; the 5-minute
// query only fills in what came before.
void setFocusCall(const std::string &call);

// A datagram from WSJT-X's UDP server (the Monitor's listener): its decodes become spots (source
// WSJT-X) heard by your own station, with who they are working in the comment, while the Spots
// layer shows.
void wsjtxDatagram(std::string_view bytes);

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
// The sources turned on whose last request failed (or the cluster that is down, or Offline Mode),
// by name: the Map's live dot is orange while any is, however fresh the others' spots are.
std::vector<std::string> troubled();
// When a feed last brought spots (Unix seconds; 0 none yet): Spothole or PSKReporter answering,
// or the DX cluster sending one.
long long lastUpdate();
// The Map's Refresh: each feed turned on asks again now, within its limits. Spothole is asked
// unless it was asked in the last minute (and its 2-minute round starts again); PSKReporter only
// when 5 minutes have passed since it was last asked, as it asks; a DX cluster waiting to
// reconnect connects now (a connected one sends its spots as they come). Says what each did.
std::string refreshNow();

// The Portable operating style's lighter use of the network: Spothole every 5 minutes instead of
// 2, and no connection kept open (the DX cluster, PSKReporter's live feed); PSKReporter's query
// asks every 5 minutes as always. policyChanged: the style changed, the feeds start again as it says.
bool lowPower();
void policyChanged();

// Settings → Spots, saved in ADIFLint.ini.
struct Config {
    bool spothole = true;
    bool cluster = false;
    std::string host, login, commands;  // login: "" is Your Station's callsign; commands: sent after it, ";" between
    int port = 0;
    bool psk = false;
    // PSKReporter: 0 a callsign on either side (who heard it, what it heard), 1 around your grid square,
    // 2 an ARRL section's region (its division), 3 a state; either station in it.
    int pskQuery = 0;
    std::string pskCall;  // PSKReporter's callsign: "" is Your Station's
    std::string pskArea;  // the section (2) or state (3): "" is where Your Station's grid is
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
