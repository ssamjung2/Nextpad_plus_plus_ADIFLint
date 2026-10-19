// Spots: a station heard or worked on a frequency, from POTA, WWFF, Spothole, a DX cluster or
// PSKReporter, in one form for the Spots window and the Map's Spots layer. Where a spot is on
// the map, which spots the Map's filters keep, and a running list that a feed adds to and
// ages out.
#pragma once

#include "adif_country.h"
#include "adif_parks.h"
#include "adif_world.h"

#include <cstddef>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace adif {

enum class SpotSource { Pota, Wwff, Spothole, Cluster, PskReporter };
const char *spotSourceName(SpotSource s);  // "POTA", "WWFF", "Spothole", "DX cluster", "PSKReporter"

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

// The Map's filters for spots: the Map's own (band, mode and places; dates and confirmed don't
// apply to spots), plus their age, sources and programs.
struct SpotFilter {
    MapFilter map;
    long long maxAge = 0;            // seconds; 0 any age
    std::set<SpotSource> sources;    // empty: all
    std::set<std::string> programs;  // empty: all; "" stands for plain DX spots
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
// pskreporter.info/pskdev.html, read 2026-10-19): <receptionReport receiverCallsign="KB1MBX"
// receiverLocator="FN42hn" senderCallsign="N1DQ" frequency=14070987 flowStartSeconds=.../>, the
// frequency in Hz and the time in Unix seconds; mode, senderLocator and sNR when they're there
// (the page's sample shows neither quotes everywhere nor these, so both forms are read). Asked
// for by your callsign as the sender, a report is a station that heard you: it becomes a spot of
// that receiver (activator, grid), spotted by you (spotter, spotterGrid). At most `limit`.
// False, with why, when the text isn't PSKReporter's answer.
bool parsePskReports(std::string_view xml, std::vector<Spot> *out, std::string *why, size_t limit = 2000);
// The query for who heard `call` in the last `seconds` (at most 24 hours), reports only, with
// `appcontact` when given (PSKReporter's author asks for an address to reach whoever queries).
std::string pskQueryUrl(std::string_view call, long long seconds, std::string_view appcontact);

// A spot's frequency in kHz from Hz, as spots show it: "14074", "7032.5".
std::string spotKhz(double hz);
// HH:MM UTC of a Unix time.
std::string spotTime(long long epoch);
// A UTC time as the spot sites write it, "2026-10-07T21:11:57", "2026-10-08 00:30:18" or with
// "Z" or "+00:00" after it, as Unix seconds; 0 when it isn't one.
long long spotEpoch(std::string_view utc);

}  // namespace adif
