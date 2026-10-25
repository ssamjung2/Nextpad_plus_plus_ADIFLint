#import "PotaParks.h"
#import "L10n.h"

#import "Lookup.h"
#import "PluginHost.h"

#include "adif_geo.h"

#include <sys/stat.h>

#include <ctime>

namespace {

adif::PotaParks parks;
bool loaded = false;
std::string listDate;  // when it was downloaded, YYYY-MM-DD

std::string cachePath() {
    std::string dir = adifhost::configDir();
    return dir.empty() ? std::string() : dir + "/ADIFLint-pota-parks.csv";
}

std::string fileDate(const std::string &path) {
    struct stat st{};
    if (path.empty() || stat(path.c_str(), &st) != 0) return "";
    struct tm tm{};
    gmtime_r(&st.st_mtime, &tm);
    char buf[16];
    strftime(buf, sizeof buf, "%Y-%m-%d", &tm);
    return buf;
}

void loadCache() {
    loaded = true;
    NSData *d = [NSData dataWithContentsOfFile:@(cachePath().c_str())];
    if (d.length) parks.load(std::string_view((const char *)d.bytes, d.length));
    listDate = fileDate(cachePath());
}

std::string grouped(size_t n) {
    std::string s = std::to_string(n);
    for (int i = (int)s.size() - 3; i > 0; i -= 3) s.insert((size_t)i, ",");
    return s;
}

}  // namespace

const adif::PotaParks &ADIFPotaParks(void) {
    if (!loaded) loadCache();
    return parks;
}

NSString *ADIFPotaParksStatus(void) {
    if (!ADIFPotaParks().size()) return T(@"Not downloaded.");
    std::string s = trf(listDate.empty() ? "{n} parks ({active} active)." : "{n} parks ({active} active), downloaded {date}.",
                        {{"n", grouped(parks.size())}, {"active", grouped(parks.active())}, {"date", listDate}});
    return @(s.c_str());
}

void ADIFUpdatePotaParks(void (^done)(BOOL ok, NSString *message)) {
    NSString *agent = [NSString stringWithFormat:@"ADIFLint/%s", ADIFLINT_VERSION];
    ADIFDownloadPotaParks(agent, ^(NSData *body, NSString *error) {
        if (error) {
            done(NO, TF(@"Could not download POTA's park list: {why}", @{@"why" : error}));
            return;
        }
        adif::PotaParks fresh;
        if (body.length > 64 * 1024 * 1024 || !fresh.load(std::string_view((const char *)body.bytes, body.length))) {
            done(NO, parks.size() ? T(@"The download wasn't POTA's park list; the old copy is kept.") : T(@"The download wasn't POTA's park list."));
            return;
        }
        std::string path = cachePath();
        if (!path.empty()) [body writeToFile:@(path.c_str()) options:NSDataWritingAtomic error:nil];
        parks = std::move(fresh);
        loaded = true;
        listDate = fileDate(path);
        done(YES, ADIFPotaParksStatus());
    });
}

NSArray<NSArray<NSString *> *> *ADIFParkSuggestions(NSString *part) {
    const adif::PotaParks &list = ADIFPotaParks();
    if (part.length < 2 || list.size() == 0) return @[];
    double lat = 0, lon = 0;
    bool home = adif::gridToLatLon(adifhost::setting("stationGrid"), &lat, &lon);
    NSMutableArray *out = [NSMutableArray array];
    for (size_t i : list.search(part.UTF8String, 20, home ? &lat : nullptr, home ? &lon : nullptr)) {
        const adif::PotaPark &p = list.parks()[i];
        std::string shown = p.ref + "  " + p.name + (p.location.empty() ? "" : " (" + p.location + ")");
        if (!p.active) shown += "  " + adif::i18n::tr("(inactive)");
        [out addObject:@[ @(p.ref.c_str()), @(shown.c_str()) ]];
    }
    return out;
}
