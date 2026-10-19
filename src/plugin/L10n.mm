#import "L10n.h"

#import "PluginHost.h"
#import "ToolWindow.h"

#include <dlfcn.h>

#include <algorithm>
#include <cctype>
#include <memory>

NSString *const ADIFLanguageChangedNotification = @"ADIFLanguageChanged";

namespace {

std::string gLanguage = "en";

std::string lower(std::string s) {
    for (char &c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

// Where the tables are: beside the plugin (lang/), or ADIFLINT_LANG_DIR in the tests.
std::string langDir() {
    if (const char *d = getenv("ADIFLINT_LANG_DIR")) return d;
    Dl_info info{};
    if (!dladdr((const void *)&ADIFLoadLanguage, &info) || !info.dli_fname) return "";
    std::string p = info.dli_fname;
    return p.substr(0, p.find_last_of('/')) + "/lang";
}

// A language as Nextpad++ or a person might name it: its file's name, a code, its own name.
std::string codeFor(std::string v) {
    v = lower(v);
    if (v.size() > 4 && v.substr(v.size() - 4) == ".xml") v.resize(v.size() - 4);
    if (size_t slash = v.find_last_of('/'); slash != std::string::npos) v = v.substr(slash + 1);
    static const std::pair<const char *, const char *> kNames[] = {
        {"english", "en"},  {"english_customizable", "en"}, {"en", "en"},    {"korean", "ko"},   {"ko", "ko"}, {"한국어", "ko"},
        {"french", "fr"},   {"fr", "fr"},                   {"français", "fr"}, {"german", "de"}, {"de", "de"}, {"deutsch", "de"},
        {"spanish", "es"},  {"spanish_ar", "es"},           {"es", "es"},    {"español", "es"},  {"japanese", "ja"}, {"ja", "ja"},
        {"日本語", "ja"}};
    for (const auto &[name, code] : kNames)
        if (v == name) return code;
    // Any other code with a table (the tests' pseudo-language, qps): used when its file is there.
    bool code = v.size() >= 2 && v.size() <= 3 && std::all_of(v.begin(), v.end(), [](char c) { return c >= 'a' && c <= 'z'; });
    return code ? v : "";
}

}  // namespace

NSString *T(NSString *english) {
    if (!english.length) return english ?: @"";
    return ADIFString(adif::i18n::tr(ADIFStd(english)));
}

NSString *TF(NSString *english, NSDictionary<NSString *, id> *args) {
    std::string text = adif::i18n::tr(ADIFStd(english));
    std::vector<std::pair<std::string, std::string>> kv;
    for (NSString *k in args) kv.push_back({ADIFStd(k), ADIFStd([args[k] description])});
    // Fill one name at a time (the core's fill takes a fixed list).
    for (const auto &[k, v] : kv) text = adif::i18n::fill(text, {{k, v}});
    return ADIFString(text);
}

NSString *TP(NSString *one, NSString *other, long long n) { return ADIFString(adif::i18n::trp(ADIFStd(one), ADIFStd(other), n)); }

const std::vector<std::pair<std::string, std::string>> &ADIFLanguages(void) {
    static const std::vector<std::pair<std::string, std::string>> l = {
        {"en", "English"}, {"ko", "한국어"}, {"fr", "Français"}, {"de", "Deutsch"}, {"es", "Español"}, {"ja", "日本語"}};
    return l;
}

std::string ADIFHostLanguage(void) {
    if (const char *test = getenv("ADIFLINT_TEST_HOST_LANGUAGE")) return codeFor(test);
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:@"language"];  // Nextpad++'s own defaults: we run inside it
    return v.length ? codeFor(ADIFStd(v)) : "en";
}

std::string ADIFLanguage(void) { return gLanguage; }

bool ADIFLoadLanguage(void) {
    std::string chosen = codeFor(adifhost::setting("uiLanguage"));
    std::string code = !chosen.empty() ? chosen : ADIFHostLanguage();
    if (code.empty()) code = "en";
    std::shared_ptr<adif::i18n::Table> table;
    if (code != "en") {
        NSData *d = [NSData dataWithContentsOfFile:@((langDir() + "/" + code + ".json").c_str())];
        auto t = std::make_shared<adif::i18n::Table>();
        std::string why;
        if (d && adif::i18n::parseTable(std::string_view((const char *)d.bytes, d.length), t.get(), &why)) table = t;
        else code = "en";  // no table: English
    }
    bool changed = code != gLanguage;
    gLanguage = code;
    adif::i18n::use(table);
    if (changed) [[NSNotificationCenter defaultCenter] postNotificationName:ADIFLanguageChangedNotification object:nil];
    return changed;
}
