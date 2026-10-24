#import "Solar.h"

#import "L10n.h"
#import "Network.h"
#import "ToolWindow.h"

#include <ctime>
#include <vector>

NSString *const ADIFSolarChangedNotification = @"ADIFSolarChanged";

namespace solar {

namespace {

constexpr double kEvery = 900;        // 15 minutes: the indices change every 3 hours or each day; the aurora every few minutes
constexpr double kRefreshAfter = 60;  // Refresh asks again at most once a minute

NSString *const kBase = @"https://services.swpc.noaa.gov";

struct {
    bool indices = false, aurora = false;
    adif::SpaceWeather weather;
    adif::AuroraGrid auroraGrid;
    NSTimer *timer = nil;
    double asked = 0;  // CFAbsoluteTime of the last round
    int busy = 0;      // requests out
    long long updated = 0;
    std::string problem;
    id offlineObserver = nil;
} s;

void changed() { [[NSNotificationCenter defaultCenter] postNotificationName:ADIFSolarChangedNotification object:nil]; }

// One file: its text to `parse`, which keeps what it reads.
void get(NSString *path, bool (^parse)(std::string_view text)) {
    ++s.busy;
    ADIFFetchData([NSURL URLWithString:[kBase stringByAppendingString:path]], @"swpc", ^(NSData *body, NSString *error) {
        --s.busy;
        if (error) s.problem = ADIFStd(error);
        else if (!parse(std::string_view((const char *)body.bytes, body.length)))
            s.problem = trf("{file} was not as expected", {{"file", ADIFStd(path.lastPathComponent)}});
        else if (![path hasSuffix:@"ovation_aurora_latest.json"])
            s.updated = (long long)time(nullptr);
        if (s.busy == 0) changed();
    });
}

void fetch() {
    if (ADIFOffline() || s.busy) return;
    s.asked = CFAbsoluteTimeGetCurrent();
    s.problem.clear();
    if (s.indices) {
        get(@"/products/summary/10cm-flux.json", ^bool(std::string_view t) { return adif::parseSolarFlux(t, s.weather); });
        get(@"/products/noaa-planetary-k-index.json", ^bool(std::string_view t) { return adif::parsePlanetaryK(t, s.weather); });
        get(@"/text/daily-geomagnetic-indices.txt", ^bool(std::string_view t) { return adif::parseDailyIndices(t, s.weather); });
        get(@"/json/goes/primary/xrays-6-hour.json", ^bool(std::string_view t) { return adif::parseXrays(t, s.weather); });
        get(@"/products/noaa-scales.json", ^bool(std::string_view t) { return adif::parseNoaaScales(t, s.weather); });
    }
    if (s.aurora) get(@"/json/ovation_aurora_latest.json", ^bool(std::string_view t) { return adif::parseOvation(t, s.auroraGrid); });
}

void start() {
    if (!s.offlineObserver)
        s.offlineObserver = [[NSNotificationCenter defaultCenter] addObserverForName:ADIFOfflineChangedNotification
                                                                              object:nil
                                                                               queue:NSOperationQueue.mainQueue
                                                                          usingBlock:^(NSNotification *) {
                                                                              if (!ADIFOffline() && (s.indices || s.aurora)) fetch();
                                                                              changed();
                                                                          }];
    if (!s.timer) s.timer = [NSTimer scheduledTimerWithTimeInterval:kEvery repeats:YES block:^(NSTimer *) { fetch(); }];
}

}  // namespace

void setWanted(bool indices, bool aurora) {
    bool more = (indices && !s.indices) || (aurora && !s.aurora);
    s.indices = indices, s.aurora = aurora;
    if (!indices && !aurora) {
        [s.timer invalidate];
        s.timer = nil;
        return;
    }
    start();
    // Newly wanted: ask now, unless the last round was moments ago and brought it.
    if (more && (s.asked == 0 || CFAbsoluteTimeGetCurrent() - s.asked > kRefreshAfter || (aurora && s.auroraGrid.value.empty()))) fetch();
}

const adif::SpaceWeather &weather() { return s.weather; }
const adif::AuroraGrid &aurora() { return s.auroraGrid; }
long long updated() { return s.updated; }

std::string status() {
    if (ADIFOffline()) return ADIFStd(ADIFOfflineReason());
    if (s.busy) return tr("NOAA SWPC: asking...");
    if (!s.problem.empty()) return trf("NOAA SWPC: {why}", {{"why", s.problem}});
    if (s.updated == 0) return tr("NOAA SWPC: not asked yet");
    char at[16];
    time_t t = (time_t)s.updated;
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(at, sizeof at, "%H:%M", &tm);
    return trf("NOAA SWPC: updated {time} UTC (every 15 minutes)", {{"time", at}});
}

std::string refreshNow() {
    if (ADIFOffline()) return ADIFStd(ADIFOfflineReason());
    if (!s.indices && !s.aurora) return tr("Space weather is off");
    if (s.asked > 0 && CFAbsoluteTimeGetCurrent() - s.asked < kRefreshAfter) return tr("NOAA SWPC was asked less than a minute ago");
    fetch();
    return tr("NOAA SWPC: asking...");
}

}  // namespace solar
