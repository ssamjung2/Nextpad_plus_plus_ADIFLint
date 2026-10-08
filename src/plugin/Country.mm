#import "Country.h"

#import "Lookup.h"
#import "PluginHost.h"

#include <dlfcn.h>

#include <fstream>
#include <sstream>
#include <string>

namespace {

adif::CountryTable gTable;
bool gLoaded = false;
std::string gSource;  // where the table came from, for the status line

std::string pluginDir() {
    Dl_info info{};
    if (!dladdr((const void *)&ADIFCountries, &info) || !info.dli_fname) return "";
    std::string p = info.dli_fname;
    return p.substr(0, p.find_last_of('/'));
}

std::string downloadedPath() {
    std::string dir = adifhost::configDir();
    return dir.empty() ? std::string() : dir + "/ADIFLint-cty.csv";
}

bool loadFile(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::stringstream ss;
    ss << in.rdbuf();
    adif::CountryTable t;
    if (!t.load(ss.str())) return false;
    gTable = std::move(t);
    return true;
}

}  // namespace

const adif::CountryTable &ADIFCountries(void) {
    if (!gLoaded) {
        gLoaded = true;
        std::string release = adifhost::setting("countryRelease");
        if (loadFile(downloadedPath())) gSource = (release.empty() ? std::string("downloaded") : release) + ", downloaded";
        else if (loadFile(pluginDir() + "/cty.csv")) gSource = "installed with ADIF Lint";
    }
    return gTable;
}

NSString *ADIFCountryDataStatus(void) {
    const adif::CountryTable &t = ADIFCountries();
    if (t.empty()) return @"No country data: press Update to download AD1C's country file.";
    return [NSString stringWithFormat:@"%zu DXCC entities and prefixes (%s).", t.entities(), gSource.c_str()];
}

void ADIFUpdateCountryData(void (^done)(BOOL ok, NSString *message)) {
    NSString *agent = [NSString stringWithFormat:@"ADIFLint/%s", ADIFLINT_VERSION];
    ADIFDownloadCountryData(agent, ^(NSString *csv, NSString *release, NSString *error) {
        if (error) {
            done(NO, error);
            return;
        }
        adif::CountryTable t;
        std::string problem;
        std::string text = csv.UTF8String ?: "";
        if (!t.load(text, &problem)) {
            done(NO, [@"The download was not a country file: " stringByAppendingString:@(problem.c_str())]);
            return;
        }
        std::string path = downloadedPath();
        NSData *d = [NSData dataWithBytes:text.data() length:text.size()];
        if (path.empty() || ![d writeToFile:@(path.c_str()) atomically:YES]) {
            done(NO, @"Could not save the country file in the plugin config folder.");
            return;
        }
        adifhost::setSetting("countryRelease", release.UTF8String ?: "");
        gTable = std::move(t);
        gLoaded = true;
        gSource = std::string(release.UTF8String ?: "") + ", downloaded";
        done(YES, [NSString stringWithFormat:@"Updated to %@: %zu entities.", release, gTable.entities()]);
    });
}
