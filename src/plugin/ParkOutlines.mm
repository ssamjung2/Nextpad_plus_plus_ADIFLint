#import "ParkOutlines.h"

#import "L10n.h"
#import "Network.h"
#import "PotaParks.h"
#import "ToolWindow.h"

#include "PluginHost.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>

using adif::i18n::tr;
using adif::i18n::trf;

NSString *const ADIFParkOutlinesChangedNotification = @"ADIFParkOutlinesChanged";

namespace parkoutlines {

namespace {

// Overpass's main instance (wiki.openstreetmap.org/wiki/Overpass_API, read 2026-10-20: identify
// the app; under 10,000 queries a day; wait after 429). PAD-US 4.1's fee layer at the USGS
// (https://doi.org/10.5066/P96WBCHS): Unit_Nm, Des_Tp, State_Nm; 2,000 records an answer.
NSString *const kOverpass = @"https://overpass-api.de/api/interpreter";
NSString *const kPadUs = @"https://edits.nationalmap.gov/arcgis/rest/services/PAD-US/PAD_US_4_1/MapServer/0/query";
NSString *const kPotaMap = @"https://pota-map.info/geojson/";
const std::set<std::string> kPotaMapCountries = {"AT", "CH", "CZ", "DE", "DK", "LU"};  // not LI: its data is WDPA's
constexpr size_t kPadUsBatch = 25;
constexpr double kSimplify = 0.00005;  // degrees, about 5 m

std::vector<adif::ParkOutline> gAll;
std::map<std::string, size_t> gIndex;
bool gLoaded = false, gBusy = false;
size_t gGeneration = 0;

std::string folder() { return adifhost::configDir() + "/parks"; }
std::string fileFor(const std::string &location) { return folder() + "/" + location + ".outlines"; }

std::string readFile(const std::string &path) {
    std::ifstream f(path, std::ios::binary);
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

bool locationShaped(const std::string &l) {  // "US-IL", "VK-NSW", "DE-HE": letters, digits and one dash
    if (l.size() < 4 || l.size() > 10 || l.find('-') == std::string::npos) return false;
    for (char c : l)
        if (!std::isupper((unsigned char)c) && !std::isdigit((unsigned char)c) && c != '-') return false;
    return true;
}

void load() {
    if (gLoaded) return;
    gLoaded = true;
    gAll.clear(), gIndex.clear();
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(folder().c_str()) error:nil];
    for (NSString *file in [files sortedArrayUsingSelector:@selector(compare:)]) {
        if (![file hasSuffix:@".outlines"]) continue;
        std::vector<adif::ParkOutline> got;
        std::string why;
        if (!adif::readOutlines(readFile(folder() + "/" + ADIFStd(file)), &got, &why)) continue;
        for (adif::ParkOutline &o : got)
            if (!gIndex.count(o.ref)) gIndex[o.ref] = gAll.size(), gAll.push_back(std::move(o));
    }
}

void changed() {
    gLoaded = false;
    ++gGeneration;
    [[NSNotificationCenter defaultCenter] postNotificationName:ADIFParkOutlinesChangedNotification object:nil];
}

// Whether a park is in a location: one of its list's ("US-DC,US-MD,US-WV").
bool inLocation(const adif::PotaPark &p, const std::string &location) {
    for (size_t b = 0; b <= p.location.size();) {
        size_t e = p.location.find(',', b);
        if (e == std::string::npos) e = p.location.size();
        if (p.location.compare(b, e - b, location) == 0) return true;
        b = e + 1;
    }
    return false;
}

// The location's parks in POTA's list, with a place.
std::vector<adif::ParkSite> sitesOf(const std::string &location) {
    std::vector<adif::ParkSite> out;
    for (const adif::PotaPark &p : ADIFPotaParks().parks())
        if (p.active && p.placed && inLocation(p, location)) out.push_back({p.ref, p.name, p.lat, p.lon});
    return out;
}

std::string sizeText(long long bytes) {
    char size[32];
    snprintf(size, sizeof size, bytes >= 1000000 ? "%.1f MB" : "%.0f KB", bytes >= 1000000 ? bytes / 1e6 : std::max(1.0, bytes / 1e3));
    return size;
}

NSString *formEncode(NSDictionary<NSString *, NSString *> *fields) {
    NSMutableCharacterSet *ok = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
    [ok addCharactersInString:@"-._~"];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, [fields[k] stringByAddingPercentEncodingWithAllowedCharacters:ok]]];
    return [parts componentsJoinedByString:@"&"];
}

bool busyStatus(NSInteger status) { return status == 429 || status == 502 || status == 503 || status == 504; }

// One download: what each source gave, and what is left to ask.
struct Job {
    std::string location;
    std::vector<adif::ParkSite> sites;
    std::set<std::string> refs;
    std::vector<adif::ParkOutline> osm, potaMap, padUs;
    std::vector<adif::PadUnit> units;
    std::vector<std::string> notes;  // a source that couldn't be read, and why
    size_t batch = 0;
    int offset = 0;
    void (^progress)(NSString *) = nil;
    void (^done)(BOOL, NSString *) = nil;
};

void finish(std::shared_ptr<Job> job);
void askPadUs(std::shared_ptr<Job> job);
void askPotaMap(std::shared_ptr<Job> job, bool country);

void keepMine(std::vector<adif::ParkOutline> &got, const std::set<std::string> &refs) {
    got.erase(std::remove_if(got.begin(), got.end(), [&](const adif::ParkOutline &o) { return !refs.count(o.ref); }), got.end());
    for (adif::ParkOutline &o : got) {
        for (adif::OutlineRing &r : o.rings) r = adif::simplifyRing(r, kSimplify);
        o.rings.erase(std::remove_if(o.rings.begin(), o.rings.end(), [](const adif::OutlineRing &r) { return r.empty(); }), o.rings.end());
        o.bound();
    }
    got.erase(std::remove_if(got.begin(), got.end(), [](const adif::ParkOutline &o) { return o.rings.empty(); }), got.end());
}

void askOverpass(std::shared_ptr<Job> job) {
    double w = 180, s = 90, e = -180, n = -90;
    for (const adif::ParkSite &p : job->sites) w = std::min(w, p.lon), e = std::max(e, p.lon), s = std::min(s, p.lat), n = std::max(n, p.lat);
    char bbox[128];
    snprintf(bbox, sizeof bbox, "%.4f,%.4f,%.4f,%.4f", std::max(-90.0, s - 0.2), std::max(-180.0, w - 0.2), std::min(90.0, n + 0.2), std::min(180.0, e + 0.2));
    NSString *query = [NSString stringWithFormat:@"[out:json][timeout:180];(way[\"communication:amateur_radio:pota\"](%s);"
                                                 @"relation[\"communication:amateur_radio:pota\"](%s););out geom;",
                                                 bbox, bbox];
    job->progress(ADIFString(trf("{location}: asking OpenStreetMap (Overpass)...", {{"location", job->location}})));
    ADIFOutlineRequest([NSURL URLWithString:kOverpass], formEncode(@{@"data" : query}), ^(NSData *body, NSInteger status, NSString *error) {
        if (error)
            job->notes.push_back(busyStatus(status) ? tr("OpenStreetMap: Overpass is busy; download again later for its outlines")
                                                    : trf("OpenStreetMap: {why}", {{"why", ADIFStd(error)}}));
        else {
            std::string why;
            if (adif::overpassOutlines(std::string_view((const char *)body.bytes, body.length), &job->osm, &why)) keepMine(job->osm, job->refs);
            else job->notes.push_back(trf("OpenStreetMap: {why}", {{"why", why}}));
        }
        std::string country = job->location.substr(0, job->location.find('-'));
        if (kPotaMapCountries.count(country)) askPotaMap(job, false);
        else if (country == "US") askPadUs(job);
        else finish(job);
    });
}

// pota-map.info: the location's own file, else (not for Germany's 95 MB) the country's.
void askPotaMap(std::shared_ptr<Job> job, bool country) {
    std::string cc = job->location.substr(0, job->location.find('-'));
    std::string name = (country ? cc : job->location) + ".geojson";
    job->progress(ADIFString(trf("{location}: asking pota-map.info...", {{"location", job->location}})));
    ADIFOutlineRequest([NSURL URLWithString:[kPotaMap stringByAppendingString:ADIFString(name)]], nil, ^(NSData *body, NSInteger status, NSString *error) {
        if (error && status == 404 && !country && cc != "DE") return askPotaMap(job, true);
        if (error) job->notes.push_back(trf("pota-map.info: {why}", {{"why", ADIFStd(error)}}));
        else {
            std::string why;
            if (adif::geojsonOutlines(std::string_view((const char *)body.bytes, body.length), "pota-map.info", &job->potaMap, &why))
                keepMine(job->potaMap, job->refs);
            else job->notes.push_back(trf("pota-map.info: {why}", {{"why", why}}));
        }
        finish(job);
    });
}

// PAD-US, a batch of parks at a time (their names in the query), each answer's pages in turn.
void askPadUs(std::shared_ptr<Job> job) {
    if (job->batch >= job->sites.size()) {
        std::vector<adif::ParkSite> unmatched;  // parks OSM gave an outline already need none
        std::set<std::string> have;
        for (const adif::ParkOutline &o : job->osm) have.insert(o.ref);
        for (const adif::ParkSite &p : job->sites)
            if (!have.count(p.ref)) unmatched.push_back(p);
        std::vector<adif::ParkOutline> matched = adif::matchPadUnits(unmatched, job->units);
        job->padUs = std::move(matched);
        std::vector<adif::PadUnit>().swap(job->units);
        return finish(job);
    }
    size_t end = std::min(job->sites.size(), job->batch + kPadUsBatch);
    std::vector<std::vector<std::string>> names;
    for (size_t i = job->batch; i < end; ++i) names.push_back(adif::parkNameWords(job->sites[i].name));
    std::string state = job->location.substr(3);
    job->progress(ADIFString(trf("{location}: asking PAD-US ({n} of {total} parks)...",
                                 {{"location", job->location}, {"n", std::to_string(end)}, {"total", std::to_string(job->sites.size())}})));
    NSDictionary *form = @{
        @"where" : ADIFString(adif::padUsWhere(state, names)),
        @"outFields" : @"Unit_Nm,Des_Tp",
        @"returnGeometry" : @"true",
        @"outSR" : @"4326",
        @"maxAllowableOffset" : @"0.0002",  // about 20 m: enough for a map, a fraction of the bytes
        @"geometryPrecision" : @"5",
        @"resultOffset" : [NSString stringWithFormat:@"%d", job->offset],
        @"f" : @"json",
    };
    ADIFOutlineRequest([NSURL URLWithString:kPadUs], formEncode(form), ^(NSData *body, NSInteger status, NSString *error) {
        bool more = false;
        if (error) job->notes.push_back(trf("PAD-US: {why}", {{"why", ADIFStd(error)}}));
        else {
            std::vector<adif::PadUnit> got;
            std::string why;
            if (adif::arcgisUnits(std::string_view((const char *)body.bytes, body.length), &got, &more, &why))
                job->units.insert(job->units.end(), std::make_move_iterator(got.begin()), std::make_move_iterator(got.end()));
            else job->notes.push_back(why);
        }
        if (error && busyStatus(status)) return finish(job);  // a busy server: stop asking
        if (more && job->offset < 20000) job->offset += 2000;
        else job->batch = end, job->offset = 0;
        // A short pause between requests: one at a time, gently.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 4)), dispatch_get_main_queue(), ^{ askPadUs(job); });
    });
}

void finish(std::shared_ptr<Job> job) {
    gBusy = false;
    // An exact reference first (OSM, then pota-map.info), then PAD-US's matches.
    std::vector<adif::ParkOutline> all;
    std::set<std::string> have;
    size_t osm = 0, potaMap = 0, padUs = 0;
    for (std::vector<adif::ParkOutline> *list : {&job->osm, &job->potaMap, &job->padUs})
        for (adif::ParkOutline &o : *list)
            if (have.insert(o.ref).second) {
                (o.source == "OSM" ? osm : o.source == "PAD-US" ? padUs : potaMap) += 1;
                all.push_back(std::move(o));
            }
    std::string notes;
    for (const std::string &n : job->notes) notes += " " + n + ".";
    if (all.empty() && !job->notes.empty()) return job->done(NO, ADIFString(trf("{location}: no outlines.", {{"location", job->location}}) + notes));
    [[NSFileManager defaultManager] createDirectoryAtPath:@(folder().c_str()) withIntermediateDirectories:YES attributes:nil error:nil];
    std::string tmp = fileFor(job->location) + ".part";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        f << adif::writeOutlines(all);
        if (!f) return job->done(NO, ADIFString(tr("Couldn't save the outlines in the plugin config folder.")));
    }
    std::rename(tmp.c_str(), fileFor(job->location).c_str());
    changed();
    std::string from;
    auto part = [&](size_t n, const char *source) {
        if (n) from += (from.empty() ? "" : ", ") + std::string(source) + " " + std::to_string(n);
    };
    part(osm, "OSM"), part(potaMap, "pota-map.info"), part(padUs, "PAD-US");
    job->done(YES, ADIFString(adif::i18n::trp("{location}: {have} of {n} park has an outline ({from}).",
                                              "{location}: {have} of {n} parks have an outline ({from}).", (long long)job->sites.size(),
                                              {{"location", job->location}, {"have", std::to_string(all.size())}, {"from", from.empty() ? tr("none") : from}}) +
                              notes));
}

}  // namespace

std::vector<std::string> locations() {
    std::set<std::string> out;
    for (const adif::PotaPark &p : ADIFPotaParks().parks()) {
        if (!p.active) continue;
        for (size_t b = 0; b <= p.location.size();) {
            size_t e = p.location.find(',', b);
            if (e == std::string::npos) e = p.location.size();
            std::string l = p.location.substr(b, e - b);
            if (locationShaped(l)) out.insert(l);
            b = e + 1;
        }
    }
    return {out.begin(), out.end()};
}

std::vector<Downloaded> downloaded() {
    load();
    std::map<std::string, Downloaded> by;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(folder().c_str()) error:nil];
    for (NSString *file in files) {
        if (![file hasSuffix:@".outlines"]) continue;
        std::string location = ADIFStd([file stringByDeletingPathExtension]);
        if (!locationShaped(location)) continue;
        Downloaded d;
        d.location = location;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:@((folder() + "/" + ADIFStd(file)).c_str()) error:nil];
        d.bytes = [attrs[NSFileSize] longLongValue];
        if (NSDate *when = attrs[NSFileModificationDate]) {
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            f.dateFormat = @"yyyy-MM-dd";
            d.date = ADIFStd([f stringFromDate:when]);
        }
        d.parks = sitesOf(location).size();
        by[location] = d;
    }
    // A park's outline counts for each downloaded location it is in (one across a border, in each).
    for (const adif::ParkOutline &o : gAll) {
        const adif::PotaPark *p = ADIFPotaParks().find(o.ref);
        if (!p) continue;
        for (auto &kv : by)
            if (inLocation(*p, kv.first)) {
                ++kv.second.outlines;
                ++(o.source == "OSM" ? kv.second.osm : o.source == "PAD-US" ? kv.second.padUs : kv.second.potaMap);
            }
    }
    std::vector<Downloaded> out;
    for (auto &kv : by) out.push_back(kv.second);
    return out;
}

std::string sources(const Downloaded &d) {
    std::string from;
    auto part = [&](size_t n, const char *source) {
        if (n) from += (from.empty() ? "" : ", ") + std::string(source) + " " + std::to_string(n);
    };
    part(d.osm, "OSM"), part(d.potaMap, "pota-map.info"), part(d.padUs, "PAD-US");
    return from.empty() ? tr("none") : from;
}

std::string describe(const Downloaded &d) {
    return adif::i18n::trp("{location}: {have} of {n} park, {size}, {date}", "{location}: {have} of {n} parks, {size}, {date}", (long long)d.parks,
                           {{"location", d.location}, {"have", std::to_string(d.outlines)}, {"size", sizeText(d.bytes)}, {"date", d.date}});
}

std::string summary(const std::vector<Downloaded> &all) {
    if (all.empty()) return tr("None downloaded.");
    size_t outlines = 0, parks = 0;
    long long bytes = 0;
    for (const Downloaded &d : all) outlines += d.outlines, parks += d.parks, bytes += d.bytes;
    char share[16];
    snprintf(share, sizeof share, "%.0f", parks ? 100.0 * (double)outlines / (double)parks : 0.0);
    return adif::i18n::trp("{locations}, {size}: {have} of {n} park has an outline ({share}%).",
                           "{locations}, {size}: {have} of {n} parks have an outline ({share}%).", (long long)parks,
                           {{"locations", adifhost::plural(all.size(), "location")}, {"size", sizeText(bytes)}, {"have", std::to_string(outlines)},
                            {"share", share}});
}

size_t generation() { return gGeneration; }

size_t parksIn(const std::string &location) { return locationShaped(location) ? sitesOf(location).size() : 0; }

const std::vector<adif::ParkOutline> &all() {
    load();
    return gAll;
}

const adif::ParkOutline *find(const std::string &ref) {
    load();
    auto it = gIndex.find(ref);
    return it == gIndex.end() ? nullptr : &gAll[it->second];
}

bool busy() { return gBusy; }

void download(const std::string &location, void (^progress)(NSString *what), void (^done)(BOOL ok, NSString *message)) {
    if (gBusy) return done(NO, T(@"Another download is running."));
    if (!locationShaped(location)) return done(NO, T(@"Choose a POTA location."));
    if (ADIFOffline()) return done(NO, ADIFOfflineReason());
    auto job = std::make_shared<Job>();
    job->location = location;
    job->sites = sitesOf(location);
    if (job->sites.empty())
        return done(NO, ADIFString(trf("{location}: no parks there in POTA's list (download the list first).", {{"location", location}})));
    for (const adif::ParkSite &p : job->sites) job->refs.insert(p.ref);
    job->progress = progress;
    job->done = done;
    gBusy = true;
    askOverpass(job);
}

void remove(const std::string &location) {
    if (!locationShaped(location)) return;
    std::remove(fileFor(location).c_str());
    changed();
}

}  // namespace parkoutlines
