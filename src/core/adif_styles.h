// Operating Styles (docs/OPERATING_STYLES_PLAN.md): Social, Chasing, Contest and Portable, each
// a set of the Map's own settings for what the operator is doing. A style owns only `map*`
// keys; it never changes Offline Mode, accounts, the logging target, a contest or the log.
//
// Each style has three layers: its recommended defaults, the operator's changes (saved when
// the style is left, back when it is chosen again), and what is on screen now. Choosing a
// style is a Transition: every key it changes, before and after, so it can be reported
// ("What changed?") and undone ("Restore previous layout"). The Map applies it (Map.mm):
// a style's workflow and Quick View set other keys of their own.
#pragma once

#include <functional>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace adif::styles {

enum class OperatingStyle { Social, Chasing, Contest, Portable };
constexpr int kStyleCount = 4;

std::string_view id(OperatingStyle s);                     // "social", "chasing", "contest", "portable"
std::optional<OperatingStyle> parse(std::string_view id);  // nullopt: none chosen (empty or unknown)
const char *title(OperatingStyle s);                       // English, for tr(): "Social"...

using Settings = std::map<std::string, std::string>;
using Getter = std::function<std::string(const std::string &key)>;
using Setter = std::function<void(const std::string &key, const std::string &value)>;

// The settings a style sets the first time (and on Reset); only `map*` keys.
const Settings &defaults(OperatingStyle s);
// The keys a style keeps for itself: `workflowKeys` (the Map's, which change as layers are
// added) and every key any style's defaults name.
std::vector<std::string> ownedKeys(const std::vector<std::string> &workflowKeys);

// Where a style's saved state lives in the settings: "mapStyle" + Id + key (as the Map's
// workflows keep theirs, "mapWf" + N + key), and "mapStyle" + Id + "Saved" once saved.
std::string savedKey(OperatingStyle s, std::string_view key);
bool hasSaved(OperatingStyle s, const Getter &get);
// The owned keys as they are now, kept as the style's own.
void save(OperatingStyle s, const std::vector<std::string> &owned, const Getter &get, const Setter &set);
// Forget the operator's changes to a style (Reset).
void forget(OperatingStyle s, const std::vector<std::string> &owned, const Setter &set);

// What choosing a style sets: its saved state when it has one, else its defaults. Owned keys
// neither names are left as they are.
Settings target(OperatingStyle s, const std::vector<std::string> &owned, const Getter &get);

// The owned keys' values now: before and after a change of style, for its report.
Settings snapshot(const std::vector<std::string> &owned, const Getter &get);

struct Change {
    std::string key, before, after;
};
struct Transition {
    std::optional<OperatingStyle> from, to;
    std::vector<Change> changes;  // only the keys whose value changed, in key order
};
// The keys that differ between two snapshots (a key missing from one counts as empty).
Transition diff(std::optional<OperatingStyle> from, std::optional<OperatingStyle> to, const Settings &before, const Settings &after);
// The same transition backwards: Restore previous layout.
Transition reversed(const Transition &t);

// Whether the operator changed a style's defaults (the customized mark): a default key whose
// value now differs.
bool customized(OperatingStyle s, const Getter &get);

}  // namespace adif::styles
