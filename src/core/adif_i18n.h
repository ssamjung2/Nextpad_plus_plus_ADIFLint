// ADIF Lint's own words (menus, windows, messages) in the language the user reads Nextpad++
// in: a table per language (data/lang/<code>.json), keyed by the English text, so whatever a
// table lacks shows in English. A table is JSON:
//   {"meta": {"language": "fr", "name": "Français", "note": "..."},
//    "strings": {"Check Log...": "Vérifier le journal...",
//                "{n} record|{n} records": {"one": "{n} enregistrement", "other": "{n} enregistrements"}}}
// {name} placeholders are filled after translating, so a translation may move them. printf
// placeholders (%@, %zu, %s...) are filled by the caller afterwards: a translation keeps the
// same ones, in the same order or numbered (%1$@). A plural's key is its English one and other
// forms joined by "|"; its forms are the language's CLDR plural categories (one, other, and
// many for French and Spanish millions). A key may end in "##context" where one English word
// needs different translations ("Solid##line", "Solid##fill"); the context isn't shown.
#pragma once

#include <initializer_list>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

// Marks text for the tables that is translated where it is shown (a table's names, say).
#define N_(text) text

namespace adif::i18n {

struct Table {
    std::string language, name, note;  // "fr", "Français", how it was made
    std::unordered_map<std::string, std::string> strings;
    std::unordered_map<std::string, std::map<std::string, std::string>> plurals;  // "one|other" -> category -> text
};
// A table from its JSON; false, with why, when it isn't one.
bool parseTable(std::string_view json, Table *out, std::string *why);

// The table in use (nullptr: English). Set it once at start and when the language changes.
void use(std::shared_ptr<const Table> table);
std::string language();  // "en" when none

// The text in the language in use (the English when the table lacks it).
std::string tr(std::string_view english);
// The same, with {name} placeholders filled.
using Args = std::initializer_list<std::pair<std::string_view, std::string>>;
std::string trf(std::string_view english, Args args);
// A count: the English singular and plural forms with {n}, the form the language uses for n.
std::string trp(std::string_view one, std::string_view other, long long n, Args args = {});

// CLDR cardinal plural categories, for whole numbers: "one", "other", "many".
const char *pluralCategory(std::string_view language, long long n);

// The placeholders in a text, in order: {name}, and printf conversions (%@, %zu, %1$@...).
std::vector<std::string> placeholders(std::string_view text);
// {name} filled from args, in one pass (a value is never filled itself); others left alone.
std::string fill(std::string_view text, Args args);
std::string fill(std::string_view text, const std::vector<std::pair<std::string, std::string>> &args);

}  // namespace adif::i18n
