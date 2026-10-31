// Spots: a station heard or worked on a frequency, from POTA, WWFF, Spothole, a DX cluster or
// PSKReporter, in one form for the Spots window and the Map's Spots layer. Where a spot is on
// the map, which spots the Map's filters keep, and a running list that a feed adds to and
// ages out.
#pragma once

#include "adif_country.h"
#include "adif_parks.h"
#include "adif_profiles.h"
#include "adif_world.h"

#include <cstddef>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace adif {

enum class SpotSource { Pota, Wwff, Spothole, Cluster, PskReporter, Wsjtx };
const char *spotSourceName(SpotSource s);  // "POTA", "WWFF", "Spothole", "DX cluster", "PSKReporter", "WSJT-X"

struct Spot {
    SpotSource source = SpotSource::Pota;
    std::string key;           // the source's id (else call, reference, frequency, mode), so a refresh keeps a selection
    long long epoch = 0;       // when it was spotted, Unix seconds UTC; 0 when the source doesn't say
    std::string time;          // HH:MM UTC, as shown
    std::string activator;     // the station spotted
    std::string khz, band, mode;
    std::string program;       // POTA, WWFF, GMA...; "" for a plain DX spot
    std::vector<std::string> refs;  // every reference of the spot
    std::string reference;     // the first, with "+n" for more
    std::string park;          // the reference's name
    std::string location;      // POTA's location ("US-WI"), or the program
    std::string spotter;       // who spotted it (a cluster or RBN node's "-#" suffix kept)
    std::string spotterGrid;   // where the spotter is, when the source says
    std::string grid;          // where the spotted station is, when the source says
    std::string comments;
    int snr = 0;               // dB, from a skimmer or PSKReporter
    bool hasSnr = false;
    bool heardMe = false;      // PSKReporter: your own signal (you are the activator), heard by the spotter
    // Where the source says the station and the spotter are (Spothole's dx_ and de_latitude and
    // longitude), when it does; `exact` when it is better than a country's centre.
    bool placeGiven = false, placeExact = false, spotterPlaceGiven = false;
    double lat = 0, lon = 0, spotterLat = 0, spotterLon = 0;
};

// Where a station is on the map: its grid (the centre of 4, 6 or 8 characters), else the
// country data's place for its call. `exact` for a grid of 6 or more; `from` says which. A
// spot's own place (Spot::placeGiven) comes first.
struct SpotPlace {
    bool ok = false, exact = false;
    double lat = 0, lon = 0;
    std::string from;  // "grid", "country data"
};
SpotPlace stationPlace(std::string_view call, std::string_view grid, const CountryTable *countries);
SpotPlace spotPlace(const Spot &s, const CountryTable *countries);
SpotPlace spotterPlace(const Spot &s, const CountryTable *countries);
// A spotter's call without a node's suffix: "W3LPL-#" and "K1TTT-2" are W3LPL and K1TTT.
std::string spotterCall(std::string_view spotter);

// How each band is doing, from the spots: the stations spotted on it and the stations that
// heard them; how many of those are within `nearKm` of home (where spotterPlace puts them), how
// many stations they heard, and the best signal report they gave; the newest spot; and the
// stations' continents (country data), the most first. In band order, bands in lower case;
// your own signal (heardMe) left out. Without a home (hasHome false), nothing is near.
struct BandActivity {
    std::string band;
    size_t stations = 0, spotters = 0;
    size_t nearSpotters = 0, nearStations = 0;
    bool nearSnr = false;
    int bestNearSnr = 0;
    long long newest = 0;
    std::vector<std::pair<std::string, size_t>> continents;
};
std::vector<BandActivity> bandActivity(const std::vector<Spot> &spots, bool hasHome, double homeLat, double homeLon, double nearKm,
                                       const CountryTable *countries);

// The Map's filters for spots: the Map's own (band, mode and places; dates and confirmed don't
// apply to spots), plus their age, sources and programs.
struct SpotFilter {
    MapFilter map;
    long long maxAge = 0;            // seconds; 0 any age
    std::set<SpotSource> sources;    // empty: all
    std::set<std::string> programs;  // empty: all; "" stands for plain DX spots
    std::string onlyCall;            // only the spots of this station ("" all): who heard it
};
// A spot as the map's QSOs are, so the Map's place filters apply: its call, band, mode and
// place, and its POTA parks.
MapQso spotQso(const Spot &s, const CountryTable *countries);
bool spotMatches(const SpotFilter &f, const Spot &s, long long now, const CountryTable *countries, const PotaParks *parks);

// The spots a feed has given, by key: a spot given again replaces the old one, spots older than
// the age are dropped, and the list keeps at most `limit`, the newest.
class SpotList {
public:
    explicit SpotList(size_t limit = 2000) : limit_(limit) {}
    void add(Spot s);
    // Replaces every spot from `source` (a feed that sends its whole list each time).
    void replace(SpotSource source, std::vector<Spot> spots);
    void prune(long long now, long long maxAge);
    void clear(SpotSource source);
    const std::vector<Spot> &spots() const { return spots_; }

private:
    void trim();
    size_t limit_;
    std::vector<Spot> spots_;  // newest first
};

// A spot as New QSO fields: CALL, FREQ, BAND, MODE and SUBMODE, and its program's fields (SIG,
// SIG_INFO, POTA_REF, WWFF_REF...) as the Spots window gives them; a DX cluster or PSKReporter
// spot adds GRIDSQUARE when it says where the station is.
std::vector<std::pair<std::string, std::string>> spotQsoFields(const Spot &s);

// One spot per station and band, the newest: what the map marks.
std::vector<Spot> latestPerStation(const std::vector<Spot> &spots);

// A telnet byte stream (RFC 854, https://www.rfc-editor.org/rfc/rfc854) as text lines, as a DX
// cluster sends it. Every option is refused once (IAC WILL x is answered IAC DONT x, IAC DO x
// IAC WONT x); subnegotiation (IAC SB ... IAC SE) and other commands are skipped. CR LF, LF or
// CR ends a line; other control characters (a bell) and bytes above 126 are dropped, and a line
// longer than `limit` is cut there.
class TelnetLines {
public:
    explicit TelnetLines(size_t limit = 1024) : limit_(limit) {}
    // Complete lines go to `lines`; what to send back (the refusals) is added to `reply`.
    void feed(std::string_view bytes, std::vector<std::string> *lines, std::string *reply);
    // The unfinished line: a prompt ends without a line break ("login: ").
    const std::string &pending() const { return line_; }
    // A prompt was answered: what follows starts a line of its own.
    void clearPending() { line_.clear(); }

private:
    enum class State { Text, Iac, Option, Sub, SubIac } state_ = State::Text;
    unsigned char verb_ = 0;
    size_t limit_;
    bool cr_ = false;
    std::string line_;
    std::set<int> refused_;  // (verb << 8) | option, each refused once
};

// A DX cluster's spot line, as DXSpider writes it (perl/DXCommandmode.pm format_dx_spot, read
// 2026-10-19 on its official mirror github.com/EA3CV/dxspider, mojo branch):
//   DX de G4XYZ:     14285.0  M0TRT/P      SSB POTA GB-0001 tnx 73         1234Z
//   DX de DJ9IE-#:    14034.9 UN7BBD       CW   4dB Q:5*+              17 1444Z 14
// The spotter and its colon, the frequency in kHz, the call, the comment, the time HHMMZ (UTC),
// and an optional slot a node may add: the spotter's grid (with the station's in the comment's
// last word), CQ or ITU zones, or US states. Columns aren't fixed (long calls squeeze them), so
// it is read by words. A skimmer (RBN) spotter ends "-#". The mode is the comment's first word
// that names one (RBN puts it first); the signal report "4dB" or "15 dB" is kept. The date is
// today's, or yesterday's for a time ahead of `now`. A node's prompt may come first on the line
// (it ends without a line break): the spot is read from "DX de ". False for any other line (WWV,
// WCY, announcements, chat, prompts).
bool parseClusterSpot(std::string_view line, long long now, Spot *out);

// What a cluster's text asks for: its login prompt ("login: ", RBN's "...call:"), a password
// (ADIF Lint doesn't log in with one), or a refused login ("Sorry ... is an invalid callsign").
// A prompt has no line end: pass the unfinished line (TelnetLines::pending) as well as lines.
enum class ClusterPrompt { None, Login, Password, Refused };
ClusterPrompt clusterPrompt(std::string_view text);

// PSKReporter's reception reports (https://retrieve.pskreporter.info/query, documented on
// pskreporter.info/pskdev.html, read 2026-10-19 and 2026-10-20): <receptionReport
// receiverCallsign="KB1MBX" receiverLocator="FN42hn" senderCallsign="N1DQ" frequency=14070987
// flowStartSeconds=.../>, the frequency in Hz and the time in Unix seconds; mode, senderLocator
// and sNR when they're there (the page's sample shows neither quotes everywhere nor these, so
// both forms are read). A report is a spot of its sender (activator, grid) by its receiver
// (spotter, spotterGrid), as a spot site would give it; when the sender is `me` it is your own
// signal, marked heardMe, and its receivers are the stations that heard you. At most `limit`.
// False, with why, when the text isn't PSKReporter's answer.
bool parsePskReports(std::string_view xml, std::vector<Spot> *out, std::string *why, size_t limit = 2000, std::string_view me = "");
// What to ask PSKReporter for: the reports with a callsign on either side (who heard you, and
// what your station reported hearing: `callsign=`), or with either station in a grid square
// (`callsign=` with `modify=grid`), both documented on its developer page.
enum class PskQuery { Callsign, Grid };
// The query for the last `seconds` (at most 24 hours), reports only, at most 1,000 of them
// (`rptlimit`: a square's hour can be 1,500 reports, 600 KB), with `appcontact` when given
// (PSKReporter's author asks for an address to reach whoever queries). A grid is cut to its
// 4-character square.
std::string pskQueryUrl(std::string_view callOrGrid, PskQuery query, long long seconds, std::string_view appcontact);

// PSKReporter's live feed, MQTT 3.1.1 over TCP (https://www.mqtt.pskreporter.info/, read
// 2026-10-28; mqtt.pskreporter.info :1883 plain, :1884 TLS): every report as it is made, on topics
// pskr/filter/v2/{band}/{mode}/{tx call}/{rx call}/{tx grid}/{rx grid}/{tx dxcc}/{rx dxcc}
// (grids of 4 characters), each payload one report as JSON: f (Hz), md, rp (dB), t (Unix
// seconds), sc and sl (sender), rc and rl (receiver), b (band). Only what a client needs of
// MQTT is here: CONNECT, SUBSCRIBE (QoS 0), PINGREQ and reading what the broker sends.
std::string mqttConnect(std::string_view clientId, int keepAliveSeconds);
std::string mqttSubscribe(int packetId, const std::vector<std::string> &topics);
std::string mqttPing();
struct MqttPacket {
    int type = 0;  // 2 CONNACK, 3 PUBLISH, 9 SUBACK, 13 PINGRESP...
    int flags = 0;
    std::string body;
};
// A byte stream as packets; a packet longer than `limit` is skipped, and `broken` is set for a
// length that isn't valid.
class MqttPackets {
public:
    explicit MqttPackets(size_t limit = 65536) : limit_(limit) {}
    void feed(std::string_view bytes, std::vector<MqttPacket> *out);
    bool broken() const { return broken_; }

private:
    std::string buf_;
    size_t limit_;
    size_t skip_ = 0;
    bool broken_ = false;
};
// A QoS 0 PUBLISH's topic and payload (false for a malformed or QoS 1/2 one).
bool mqttPublish(const MqttPacket &p, std::string *topic, std::string *payload);
// The topics that bring the reports of a station (either side of the path): one for it as the
// sender, one as the receiver. "/" in a call is "_" in a topic.
std::vector<std::string> pskTopicsForCall(std::string_view call);
// The topics for the reports with either station in a 4-character grid square.
std::vector<std::string> pskTopicsForGrid(std::string_view grid);
// PSKReporter can't be asked for a state or a section, only for a callsign or a 4-character
// square (the live feed also by DXCC), so those are asked as the squares over the area and the
// reports kept to those with a station in it (pskInArea).
struct PskArea {
    std::set<std::string> states;       // postal codes
    std::vector<std::string> squares;   // 4-character squares that hold part of it
    bool empty() const { return states.empty() || squares.empty(); }
};
// The US state `grid` (4 or more characters) is in, by its centre; "" when none.
std::string pskStateOfGrid(std::string_view grid);
// A state's area (postal code, as "WI"); empty when it is not a state of the Map.
PskArea pskAreaForState(std::string_view state);
// The region of an ARRL section ("WI", "EMA", "STX"): its ARRL division's states, the states a
// split section is in included. With no section, the divisions `state` is in. Empty when none.
PskArea pskAreaForSection(std::string_view section, std::string_view state = "");
// Whether the sender or the receiver of a report is in the area.
bool pskInArea(const PskArea &area, const Spot &s);
// The topics for the reports with either station in any of the squares.
std::vector<std::string> pskTopicsForSquares(const std::vector<std::string> &squares);
// One report's payload as a spot of its sender by its receiver (as parsePskReports gives it);
// `me` marks your own signal. False when it isn't a usable report.
bool parsePskLive(std::string_view payload, Spot *out, std::string_view me = "");

// WSJT-X's UDP messages as spots of what this station hears, with who it hears working whom
// (https://github.com/WSJTX/wsjtx Network/NetworkMessage.hpp: Status 1 gives the dial frequency,
// mode and DE call and grid; Decode 2 gives the message heard). A decode "CQ K1ABC FN42" is
// K1ABC calling; "W9XYZ K1ABC -10" is K1ABC working W9XYZ: a spot of K1ABC (and one of W9XYZ,
// who is being answered), heard by your station, the comment saying who it is working.
class WsjtxHeard {
public:
    // One datagram; the spots it gives are added to *out. `now`: Unix seconds.
    void feed(std::string_view bytes, long long now, std::vector<Spot> *out);

private:
    struct Rig {
        double hz = 0;
        std::string mode, call, grid;
    };
    std::map<std::string, Rig> rigs_;
};

// A spot's frequency in kHz from Hz, as spots show it: "14074", "7032.5".
std::string spotKhz(double hz);
// HH:MM UTC of a Unix time.
std::string spotTime(long long epoch);
// A UTC time as the spot sites write it, "2026-10-07T21:11:57", "2026-10-08 00:30:18" or with
// "Z" or "+00:00" after it, as Unix seconds; 0 when it isn't one.
long long spotEpoch(std::string_view utc);

// A signal report in a spot's comment, as skimmers write it: "20 dB" or "4dB" ("CW 20 dB 25 WPM
// CQ"), with an optional sign; the first one. False when the comment has none. Spothole has no
// field for it (its apidocs, read 2026-10-20), so its RBN spots' reports come from here too.
bool commentReport(std::string_view comment, int *snr);
// Spotting a QSO you logged on a DX cluster, as DXSpider takes it ("dx (frequency) (callsign)
// (remarks)", the frequency in kHz; the station "you have worked or heard, (ie not your own
// callsign!)", dxcluster.org user manual section 4, read 2026-10-20): "dx 14074.0 K1ABC FT8".
// Empty when the call is yours (in any portable form), isn't a callsign, or the frequency isn't
// one. The remarks are cut to 30 printable characters.
std::string clusterSpotCommand(std::string_view call, double khz, std::string_view remarks, std::string_view myCall);
// The same station: the longest part of each call between "/" (K1ABC/P is K1ABC, VE3/K1ABC too).
bool sameStation(std::string_view a, std::string_view b);
// What a node said after a spot was posted: Accepted when it echoes it ("DX de <you>: ... <call>"),
// Refused on a line saying sorry, not allowed, not registered, invalid or error; else None.
enum class ClusterPostAnswer { None, Accepted, Refused };
ClusterPostAnswer clusterPostAnswer(std::string_view line, std::string_view myCall, std::string_view call, long long now);
// The spot comment for a logged QSO, as hunters write it: its program and reference first ("POTA
// US-1234"), then its mode (the SUBMODE when there is one): "POTA US-1234 SSB", "FT8".
std::string qsoSpotComment(const FieldList &fields);
// How long ago a spot was made: "just now" under a minute, else "{n} min"; "" when the source
// doesn't say when.
std::string spotAge(long long epoch, long long now);
// A signal report as the spot sites write it: "+1 dB", "-12 dB"; "" without one.
std::string spotSnr(const Spot &s);
// What the Map's label shows under a spot's call, as Style Options choose: its mode, frequency,
// how long ago it was spotted and its signal report, " · " between them ("FT8 · 14074 kHz ·
// 3 min · -12 dB"); "" when none of them is chosen or known. `time` adds when it was last
// heard, "14:32Z" (UTC).
struct SpotLabel {
    bool mode = true, khz = false, age = true, snr = true, time = false;
};
std::string spotLabelDetails(const Spot &s, const SpotLabel &show, long long now);

}  // namespace adif
