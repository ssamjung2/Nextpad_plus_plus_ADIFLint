// ADIF Lint in the user's language, the plugin's side of adif_i18n.h. The language is
// Settings → Language when chosen there, else the one Nextpad++ shows: its "language" default,
// the name of its language file ("french" for localization/french.xml; Nextpad++ 1.1.2 keeps
// it there and posts NPPLocalizationChanged when it changes, read from its binary 2026-10-19),
// else English. The tables (lang/<code>.json) are installed beside the plugin.
// AppKit and Foundation only.
#pragma once

#import <Cocoa/Cocoa.h>

#include "adif_i18n.h"

#include <string>
#include <utility>
#include <vector>

// For C++ text (std::string): tr("..."), trf("... {name} ...", {{"name", value}}), trp(one, other, n).
using adif::i18n::tr;
using adif::i18n::trf;
using adif::i18n::trp;

// The text in the language in use; English when it has no translation.
NSString *T(NSString *english);
// With {name} placeholders filled: TF(@"Downloaded {name}.", @{@"name": name}).
NSString *TF(NSString *english, NSDictionary<NSString *, id> *args);
// A count: TP(@"{n} record", @"{n} records", n).
NSString *TP(NSString *one, NSString *other, long long n);

// The languages ADIF Lint has: code and its own name ("fr", "Français"), English first.
const std::vector<std::pair<std::string, std::string>> &ADIFLanguages(void);
// Nextpad++'s language as a code ("fr"), or "" when it is one ADIF Lint doesn't have.
std::string ADIFHostLanguage(void);
// The language in use ("en", "fr"...).
std::string ADIFLanguage(void);
// Reads the setting and Nextpad++'s choice again and loads that table; when the language
// changed, posts ADIFLanguageChangedNotification. True when it changed.
bool ADIFLoadLanguage(void);
extern NSString *const ADIFLanguageChangedNotification;

// Marks text for the tables that is translated where it is shown (a table of titles, say):
// N(@"Grid squares") is just @"Grid squares", and T(...) at the place that shows it.
#define N(text) text
