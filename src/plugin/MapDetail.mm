#import "MapDetail.h"

#import "Map.h"
#import "Network.h"
#import "PluginHost.h"

#include "adif_worked.h"
#include "adif_world.h"

#include <sys/stat.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <regex>

NSString *const ADIFMapDetailChangedNotification = @"ADIFMapDetailChanged";

namespace mapdetail {
namespace {

namespace pm = adif::pmtiles;

// The 50 states and DC, by the postal codes the Map's state outlines carry.
const std::map<std::string, const char *> &stateNames() {
    static const std::map<std::string, const char *> names = {
        {"AL", "Alabama"},       {"AK", "Alaska"},         {"AZ", "Arizona"},        {"AR", "Arkansas"},       {"CA", "California"},
        {"CO", "Colorado"},      {"CT", "Connecticut"},    {"DE", "Delaware"},       {"DC", "District of Columbia"},
        {"FL", "Florida"},       {"GA", "Georgia"},        {"HI", "Hawaii"},         {"ID", "Idaho"},          {"IL", "Illinois"},
        {"IN", "Indiana"},       {"IA", "Iowa"},           {"KS", "Kansas"},         {"KY", "Kentucky"},       {"LA", "Louisiana"},
        {"ME", "Maine"},         {"MD", "Maryland"},       {"MA", "Massachusetts"},  {"MI", "Michigan"},       {"MN", "Minnesota"},
        {"MS", "Mississippi"},   {"MO", "Missouri"},       {"MT", "Montana"},        {"NE", "Nebraska"},       {"NV", "Nevada"},
        {"NH", "New Hampshire"}, {"NJ", "New Jersey"},     {"NM", "New Mexico"},     {"NY", "New York"},       {"NC", "North Carolina"},
        {"ND", "North Dakota"},  {"OH", "Ohio"},           {"OK", "Oklahoma"},       {"OR", "Oregon"},         {"PA", "Pennsylvania"},
        {"RI", "Rhode Island"},  {"SC", "South Carolina"}, {"SD", "South Dakota"},   {"TN", "Tennessee"},      {"TX", "Texas"},
        {"UT", "Utah"},          {"VT", "Vermont"},        {"VA", "Virginia"},       {"WA", "Washington"},     {"WV", "West Virginia"},
        {"WI", "Wisconsin"},     {"WY", "Wyoming"}};
    return names;
}

const char kBuilds[] = "https://build-metadata.protomaps.dev/builds.json";
const char kBuildBase[] = "https://build.protomaps.com/";

std::string mapsDir() {
    std::string dir = adifhost::configDir();
    return dir.empty() ? std::string() : dir + "/maps";
}

std::string bytesText(uint64_t n) {
    char buf[32];
    if (n >= 1000000000ull) snprintf(buf, sizeof buf, "%.1f GB", n / 1e9);
    else if (n >= 1000000ull) snprintf(buf, sizeof buf, "%.0f MB", n / 1e6);
    else snprintf(buf, sizeof buf, "%.0f KB", std::max(1.0, n / 1e3));
    return buf;
}

std::string grouped(uint64_t n) {
    std::string s = std::to_string(n);
    for (int i = (int)s.size() - 3; i > 0; i -= 3) s.insert((size_t)i, ",");
    return s;
}

std::string buildDate(const std::string &build) {  // 20261018 -> 2026-10-18
    return build.size() == 8 ? build.substr(0, 4) + "-" + build.substr(4, 2) + "-" + build.substr(6, 2) : build;
}

// A file name's region name: no slashes, colons or leading dots.
std::string fileSafe(std::string s) {
    for (char &c : s)
        if (c == '/' || c == ':' || c == '\\' || (unsigned char)c < 32) c = '-';
    while (!s.empty() && s[0] == '.') s.erase(0, 1);
    return s.empty() ? "Region" : s;
}

struct Area {
    std::string name;
    std::vector<std::vector<std::pair<double, double>>> rings;
    std::array<double, 4> bounds{180, 90, -180, -90};
};

bool area(const std::string &choice, Area *out) {
    auto boundsOf = [](Area &a) {
        for (const auto &r : a.rings)
            for (const auto &[lon, lat] : r)
                a.bounds = {std::min(a.bounds[0], lon), std::min(a.bounds[1], lat), std::max(a.bounds[2], lon), std::max(a.bounds[3], lat)};
    };
    if (choice == "view") {
        std::array<double, 4> b{};
        if (!worldmap::shownArea(&b)) return false;
        char name[64];
        snprintf(name, sizeof name, "Map area %.2f%c %.2f%c", std::fabs((b[1] + b[3]) / 2), (b[1] + b[3]) >= 0 ? 'N' : 'S',
                 std::fabs((b[0] + b[2]) / 2), (b[0] + b[2]) >= 0 ? 'E' : 'W');
        out->name = name;
        out->rings = {{{b[0], b[1]}, {b[2], b[1]}, {b[2], b[3]}, {b[0], b[3]}}};
        boundsOf(*out);
        return true;
    }
    adif::Overlay o;
    std::string key;
    if (choice.rfind("state:", 0) == 0) o = adif::Overlay::UsStates, key = choice.substr(6);
    else if (choice.rfind("country:", 0) == 0) o = adif::Overlay::Countries, key = choice.substr(8);
    else return false;
    const adif::AreaIndex &index = adif::areaIndex(o);
    size_t i = index.byName(key);
    if (i == adif::AreaIndex::npos) return false;
    out->rings = index.area(i).rings;
    auto named = stateNames().find(key);
    out->name = o == adif::Overlay::UsStates && named != stateNames().end() ? named->second : key;
    boundsOf(*out);
    return !out->rings.empty();
}

// ── The downloaded regions ───────────────────────────────────────────────────

std::vector<Region> gRegions;
bool gLoaded = false;
long gDirTime = -1;  // the folder's last change, as last read: files added by hand show too

long dirTime() {
    struct stat st{};
    return mapsDir().empty() || stat(mapsDir().c_str(), &st) != 0 ? 0 : (long)st.st_mtimespec.tv_sec * 1000 + st.st_mtimespec.tv_nsec / 1000000;
}

void load() {
    gLoaded = true;
    gDirTime = dirTime();
    gRegions.clear();
    std::string dir = mapsDir();
    if (dir.empty()) return;
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(dir.c_str()) error:nil];
    static const std::regex kName("^(.+) z([0-9]{1,2}) ([0-9]{8})\\.pmtiles$");
    for (NSString *f in [files sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        std::string file = f.UTF8String ?: "";
        std::smatch m;
        if (!std::regex_match(file, m, kName)) continue;
        Region r;
        r.path = dir + "/" + file, r.name = m[1], r.maxZoom = std::atoi(m[2].str().c_str()), r.build = m[3];
        auto a = std::make_shared<pm::Archive>();
        std::string why;
        if (!a->open(r.path, &why) || a->header().tileType != pm::kMvt) continue;
        struct stat st{};
        if (stat(r.path.c_str(), &st) == 0) r.bytes = (uint64_t)st.st_size;
        const pm::Header &h = a->header();
        r.bounds = {h.minLonE7 / 1e7, h.minLatE7 / 1e7, h.maxLonE7 / 1e7, h.maxLatE7 / 1e7};
        r.archive = std::move(a);
        gRegions.push_back(std::move(r));
    }
}

void changed() {
    load();
    [[NSNotificationCenter defaultCenter] postNotificationName:ADIFMapDetailChangedNotification object:nil];
}

// ── Checking and downloading ─────────────────────────────────────────────────

struct Job {
    unsigned generation = 0;
    std::string choice;
    int zoom = 0;
    Area where;
    bool checking = false, checked = false, downloading = false;
    NSURL *url = nil;
    NSString *etag = nil;
    std::string build;
    std::unique_ptr<pm::Extract> extract;
    std::vector<pm::Range> ranges;
    size_t next = 0, written = 0;
    int inFlight = 0;
    std::map<size_t, std::string> ready;  // fetched, waiting for the ranges before them
    std::map<size_t, int> tries;
    uint64_t done = 0, total = 0;
    NSFileHandle *out = nil;
    NSString *partial = nil;
    NSMutableArray<NSURLSessionTask *> *tasks = [NSMutableArray array];
    void (^progress)(NSString *) = nil;
    void (^finished)(BOOL, NSString *) = nil;
};
Job job;

void track(NSURLSessionTask *t) {
    if (t) [job.tasks addObject:t];
}

void clearDownload() {
    for (NSURLSessionTask *t in job.tasks) [t cancel];
    [job.tasks removeAllObjects];
    if (job.out) [job.out closeFile];
    job.out = nil;
    if (job.partial) [[NSFileManager defaultManager] removeItemAtPath:job.partial error:nil];
    job.partial = nil;
    job.downloading = false;
    job.ready.clear();
    job.tries.clear();
    job.inFlight = 0;
}

// The directories, a request (up to 4 at once) per range; then done.
void readDirectories(unsigned gen, void (^done)(BOOL ok, NSString *message)) {
    if (gen != job.generation) return;
    if (job.extract->planned()) return done(YES, nil);
    std::vector<pm::Range> ranges = job.extract->directoryRanges();
    if (ranges.empty()) return done(NO, @"The build's directories didn't lead to the region's tiles.");
    __block size_t left = ranges.size();
    __block BOOL failed = NO;
    for (const pm::Range &r : ranges) {
        pm::Range range = r;
        track(ADIFFetchRange(job.url, r.offset, r.length, job.etag, ^(NSData *bytes, NSString *, NSString *error) {
            if (gen != job.generation || failed) return;
            std::string why;
            if (error || !job.extract->addDirectories(range, std::string_view((const char *)bytes.bytes, bytes.length), &why)) {
                failed = YES;
                return done(NO, error ?: [@"Reading the build's directories: " stringByAppendingString:@(why.c_str())]);
            }
            if (--left == 0) readDirectories(gen, done);
        }));
    }
}

void pump();

void fail(NSString *message) {
    void (^finished)(BOOL, NSString *) = job.finished;
    clearDownload();
    job.checked = false;
    if (finished) finished(NO, message);
}

void finish() {
    [job.out closeFile];
    job.out = nil;
    std::string name = fileSafe(job.where.name);
    std::string dir = mapsDir(), file = name + " z" + std::to_string(job.zoom) + " " + job.build + ".pmtiles";
    NSString *final = @((dir + "/" + file).c_str());
    NSError *err = nil;
    NSURL *finalUrl = [NSURL fileURLWithPath:final], *partialUrl = [NSURL fileURLWithPath:job.partial];
    BOOL moved = [[NSFileManager defaultManager] fileExistsAtPath:final]
                     ? [[NSFileManager defaultManager] replaceItemAtURL:finalUrl withItemAtURL:partialUrl backupItemName:nil options:0 resultingItemURL:nil error:&err]
                     : [[NSFileManager defaultManager] moveItemAtPath:job.partial toPath:final error:&err];
    job.partial = moved ? nil : job.partial;
    if (moved)  // the same region downloaded before (another zoom or build): replaced, now that the new one is kept
        for (const Region &r : regions())
            if (r.name == name && r.path != dir + "/" + file) [[NSFileManager defaultManager] removeItemAtPath:@(r.path.c_str()) error:nil];
    void (^finished)(BOOL, NSString *) = job.finished;
    uint64_t total = job.total;
    clearDownload();
    job.checked = false;
    changed();
    if (finished)
        finished(moved, moved ? @(("Downloaded " + job.where.name + ": " + bytesText(total) + ". Zoom in on the Map to see it.").c_str())
                              : [@"Couldn't keep the download: " stringByAppendingString:err.localizedDescription ?: @"unknown error"]);
}

void fetchRange(size_t i) {
    unsigned gen = job.generation;
    const pm::Range r = job.ranges[i];
    ++job.inFlight;
    track(ADIFFetchRange(job.url, r.offset, r.length, job.etag, ^(NSData *bytes, NSString *, NSString *error) {
        if (gen != job.generation || !job.downloading) return;
        --job.inFlight;
        if (error) {
            bool changedOnServer = [error containsString:@"412"] || [error containsString:@"changed"];
            if (!changedOnServer && ![error isEqualToString:@"Stopped."] && job.tries[i]++ < 2) return fetchRange(i);  // once or twice more
            return fail(changedOnServer ? @"Protomaps published a new build while this one was downloading. Check Size again for the new one."
                                        : [@"The download stopped: " stringByAppendingString:error]);
        }
        job.ready[i] = job.extract->copyFrom(i, std::string_view((const char *)bytes.bytes, bytes.length));
        while (job.ready.count(job.written)) {
            std::string &chunk = job.ready[job.written];
            @try {
                [job.out writeData:[NSData dataWithBytes:chunk.data() length:chunk.size()]];
            } @catch (NSException *e) {
                return fail([@"Couldn't write the map file: " stringByAppendingString:e.reason ?: @"disk full?"]);
            }
            job.done += chunk.size();
            job.ready.erase(job.written++);
        }
        if (job.progress)
            job.progress(@(("Downloading " + job.where.name + ": " + bytesText(job.done) + " of " + bytesText(job.total) + "...").c_str()));
        if (job.written == job.ranges.size()) return finish();
        pump();
    }));
}

void pump() {
    while (job.downloading && job.inFlight < 4 && job.next < job.ranges.size()) fetchRange(job.next++);
}

}  // namespace

std::vector<Choice> choices(bool mapOpen) {
    std::vector<Choice> out;
    if (mapOpen) out.push_back({"view", "The area shown on the Map"});
    std::vector<std::pair<std::string, std::string>> states;
    const adif::AreaIndex &si = adif::areaIndex(adif::Overlay::UsStates);
    for (size_t i = 0; i < si.size(); ++i) {
        auto n = stateNames().find(si.area(i).name);
        if (n != stateNames().end()) states.push_back({n->second, si.area(i).name});
    }
    std::sort(states.begin(), states.end());
    for (const auto &[name, code] : states) out.push_back({"state:" + code, name + std::string(" (US)")});
    std::vector<std::string> countries;
    const adif::AreaIndex &ci = adif::areaIndex(adif::Overlay::Countries);
    for (size_t i = 0; i < ci.size(); ++i) countries.push_back(ci.area(i).name);
    std::sort(countries.begin(), countries.end());
    countries.erase(std::unique(countries.begin(), countries.end()), countries.end());
    for (const std::string &c : countries) out.push_back({"country:" + c, c});
    return out;
}

const std::vector<Level> &levels() {
    static const std::vector<Level> l = {{15, "Streets and buildings (zoom 15)"}, {13, "Roads and towns (zoom 13)"}, {11, "Main roads (zoom 11)"}};
    return l;
}

const std::vector<Region> &regions() {
    if (!gLoaded || dirTime() != gDirTime) {
        bool had = gLoaded;
        load();
        if (had)  // later: this may be asked while the Map draws
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:ADIFMapDetailChangedNotification object:nil];
            });
    }
    return gRegions;
}

bool remove(const std::string &path, std::string *why) {
    if (job.downloading) {
        if (why) *why = "Wait for the download to finish, or stop it.";
        return false;
    }
    bool known = false;
    for (const Region &r : regions()) known |= r.path == path;
    NSError *err = nil;
    if (!known || ![[NSFileManager defaultManager] removeItemAtPath:@(path.c_str()) error:&err]) {
        if (why) *why = err ? std::string(err.localizedDescription.UTF8String ?: "") : "not a downloaded region";
        return false;
    }
    changed();
    return true;
}

NSString *status() {
    const std::vector<Region> &r = regions();
    if (r.empty()) return @"None downloaded yet.";
    uint64_t total = 0;
    std::string names;
    for (const Region &x : r) {
        total += x.bytes;
        names += (names.empty() ? "" : "; ") + x.name + " (zoom " + std::to_string(x.maxZoom) + ", " + bytesText(x.bytes) + ", build " + buildDate(x.build) + ")";
    }
    return @((adifhost::plural(r.size(), "region") + ", " + bytesText(total) + ": " + names + ".").c_str());
}

bool busy() { return job.checking || job.downloading; }

bool checked(const std::string &choice, int zoom) { return job.checked && !job.downloading && job.choice == choice && job.zoom == zoom; }

void stop() {
    ++job.generation;
    bool was = job.downloading || job.checking;
    clearDownload();
    job.checking = false;
    job.checked = false;
    void (^finished)(BOOL, NSString *) = job.finished;
    job.finished = nil;
    if (was && finished) finished(NO, @"Stopped. Nothing was kept.");
}

void check(const std::string &choice, int zoom, void (^done)(BOOL ok, NSString *message)) {
    if (busy()) return done(NO, @"A download is under way; stop it first.");
    if (mapsDir().empty()) return done(NO, @"Nextpad++ has no plugin settings folder to keep maps in.");
    Area where;
    if (!area(choice, &where)) return done(NO, choice == "view" ? @"Open the Map first, and show the area you want." : @"That region isn't known.");
    // About how many tiles at the top zoom (the region's box): too many for one file is refused.
    double tilesAcross = (pm::tileX(where.bounds[2], zoom) - pm::tileX(where.bounds[0], zoom) + 1) *
                         (pm::tileY(where.bounds[1], zoom) - pm::tileY(where.bounds[3], zoom) + 1);
    if (tilesAcross > 4e6)
        return done(NO, @((where.name + " is too large for this much detail (some " + grouped((uint64_t)tilesAcross) +
                           " tiles): choose less detail, or a smaller region (a state, or the area shown on the Map).")
                              .c_str()));
    unsigned gen = ++job.generation;
    job.choice = choice, job.zoom = zoom, job.where = where;
    job.checking = true, job.checked = false;
    void (^end)(BOOL, NSString *) = ^(BOOL ok, NSString *message) {
        if (gen != job.generation) return;
        job.checking = false;
        job.checked = ok;
        done(ok, message);
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::vector<uint64_t> tiles = pm::coveringTiles(where.rings, 0, zoom);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != job.generation) return;
            job.extract = std::make_unique<pm::Extract>(tiles, where.bounds);
            track(ADIFFetchFile([NSURL URLWithString:@(kBuilds)], ^(NSData *body, NSString *error) {
                if (gen != job.generation) return;
                // The newest build: keys "YYYYMMDD.pmtiles", nothing else accepted.
                NSArray *list = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
                NSString *newest = nil;
                for (id e in [list isKindOfClass:NSArray.class] ? list : @[]) {
                    NSString *key = [e isKindOfClass:NSDictionary.class] ? e[@"key"] : nil;
                    if (![key isKindOfClass:NSString.class] || key.length != 16 || ![key hasSuffix:@".pmtiles"]) continue;
                    if ([[key substringToIndex:8] rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound)
                        continue;
                    if (!newest || [key compare:newest] == NSOrderedDescending) newest = key;
                }
                if (!newest) return end(NO, error ? [@"Protomaps' list of builds: " stringByAppendingString:error] : @"Protomaps' list of builds had none.");
                job.build = [newest substringToIndex:8].UTF8String;
                job.url = [NSURL URLWithString:[@(kBuildBase) stringByAppendingString:newest]];
                job.etag = nil;
                track(ADIFFetchRange(job.url, 0, pm::kFirstBytes, nil, ^(NSData *first, NSString *etag, NSString *err) {
                    if (gen != job.generation) return;
                    std::string why;
                    if (err || !job.extract->start(std::string_view((const char *)first.bytes, first.length), &why))
                        return end(NO, err ?: [@"Protomaps' build: " stringByAppendingString:@(why.c_str())]);
                    if (job.extract->source().tileType != pm::kMvt) return end(NO, @"Protomaps' build isn't vector tiles.");
                    job.etag = etag;
                    pm::Range m = job.extract->metadataRange();
                    track(ADIFFetchRange(job.url, m.offset, m.length, job.etag, ^(NSData *meta, NSString *, NSString *err2) {
                        if (gen != job.generation) return;
                        std::string why2;
                        if (err2 || !job.extract->metadata(std::string_view((const char *)meta.bytes, meta.length), &why2))
                            return end(NO, err2 ?: @(why2.c_str()));
                        readDirectories(gen, ^(BOOL ok, NSString *message) {
                            if (!ok) return end(NO, message);
                            job.total = job.extract->tileBytes();
                            if (job.extract->tileCount() == 0) return end(NO, @(("Protomaps' build has no map tiles for " + where.name + ".").c_str()));
                            const char *level = "";
                            for (const Level &l : levels())
                                if (l.zoom == zoom) level = l.title;
                            end(YES, @((where.name + ", " + level + ": " + bytesText(job.total) + " (" + grouped(job.extract->tileCount()) +
                                        " map tiles) from Protomaps' OpenStreetMap build of " + buildDate(job.build) + ". Press Download to fetch it.")
                                           .c_str()));
                        });
                    }));
                }));
            }));
        });
    });
}

void download(void (^progress)(NSString *message), void (^done)(BOOL ok, NSString *message)) {
    if (!job.checked || job.downloading || !job.extract) return done(NO, @"Check Size first.");
    std::string dir = mapsDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:@(dir.c_str()) withIntermediateDirectories:YES attributes:nil error:nil];
    NSNumber *free = [[NSFileManager defaultManager] attributesOfFileSystemForPath:@(dir.c_str()) error:nil][NSFileSystemFreeSize];
    if (free && free.unsignedLongLongValue < job.total + (200ull << 20))  // the region, and room to spare
        return done(NO, @(("Not enough free disk space: " + job.where.name + " needs " + bytesText(job.total) + ", and " +
                           bytesText(free.unsignedLongLongValue) + " is free.")
                              .c_str()));
    job.partial = [NSString stringWithFormat:@"%s/.download-%@.partial", dir.c_str(), NSUUID.UUID.UUIDString];
    if (![[NSFileManager defaultManager] createFileAtPath:job.partial contents:nil attributes:nil] ||
        !(job.out = [NSFileHandle fileHandleForWritingAtPath:job.partial])) {
        job.partial = nil;
        return done(NO, @"Couldn't create the map file in the plugin's settings folder.");
    }
    std::string head = job.extract->head();
    [job.out writeData:[NSData dataWithBytes:head.data() length:head.size()]];
    job.ranges = job.extract->dataRanges();
    job.next = job.written = 0;
    job.done = 0;
    job.downloading = true;
    job.progress = progress;
    job.finished = done;
    if (job.ranges.empty()) return finish();
    progress(@(("Downloading " + job.where.name + ": " + bytesText(job.total) + "...").c_str()));
    pump();
}

}  // namespace mapdetail
