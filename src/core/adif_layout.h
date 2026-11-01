// What shows where (docs/WINDOWING_ARCHITECTURE.md): the arrangement of ADIF Lint's panels as
// plain data. The Operating Console is a split tree of rows and columns whose leaves are stacks
// of panels, shown as tabs (one panel: no tab bar); other panels sit in windows of their own;
// and each panel's panes (the Map's sidebar, list and selected panel) are shown or hidden.
//
// Panels are named by stable ids, never by window. An arrangement is written and read as
// versioned JSON; one of another version reads as nothing (the defaults show instead). Every
// change returns a tidied copy: unknown or repeated panels dropped, empty stacks and one-child
// splits gone, shares summing to 1 where every sibling has one. Presets are named arrangements;
// `migrate` reads the console's and the Map's settings from before arrangements, once.
#pragma once

#include <array>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace adif::layout {

constexpr int kVersion = 1;

// The panels, by id (kept in settings and layouts; never renamed).
inline constexpr const char *kMap = "map";
inline constexpr const char *kLogTable = "logtable";
inline constexpr const char *kNewQso = "newqso";
inline constexpr const char *kSpots = "spots";
inline constexpr const char *kContactMap = "contactmap";
inline constexpr const char *kQsoDetails = "qsodetails";
inline constexpr const char *kMapStyle = "mapstyle";
inline constexpr const char *kAids = "aids";
inline constexpr const char *kSpotSources = "spotsources";  // Settings' Spots section as a panel
inline constexpr const char *kStation = "station";          // Settings' Your Station section as a panel
inline constexpr const char *kClocks = "clocks";            // the clocks, of the time zones you choose
const std::vector<std::string> &knownPanels();

struct Node {
    enum class Kind { Stack, Row, Column };
    Kind kind = Kind::Stack;
    double share = 0;                 // of its parent split; 0: by what it needs (when any sibling has none)
    std::vector<Node> children;       // Row (side by side), Column (one over another)
    std::vector<std::string> panels;  // Stack: its tabs, in order
    size_t front = 0;                 // Stack: the tab in front
};
Node stack(std::vector<std::string> panels, double share = 0, size_t front = 0);
Node row(std::vector<Node> children, double share = 0);
Node column(std::vector<Node> children, double share = 0);

struct Frame {
    double x = 0, y = 0, w = 0, h = 0;  // a window's frame; all 0: where its window opens by itself
};

// Where a panel is in the console, so that it can go back there once closed: a tab in the stack of
// `beside` (at `tabAt`); or a frame of its own beside the part of the console holding `next`
// (before it: left of it in a row, above it in a column), with its share of that split.
struct Place {
    bool tab = false;
    std::string beside;
    size_t tabAt = 0;
    std::vector<std::string> next;
    Node::Kind split = Node::Kind::Row;
    bool before = false;
    double share = 0;
};

struct Arrangement {
    Node console;                                              // an empty stack: nothing in the console
    std::map<std::string, Frame> windows;                      // panels in windows of their own
    std::map<std::string, std::map<std::string, bool>> panes;  // panel → pane → shown ("map" → "sidebar")
    std::map<std::string, Place> closed;                       // panels closed from the console: where they were
};

bool operator==(const Node &a, const Node &b);
bool operator==(const Frame &a, const Frame &b);
bool operator==(const Place &a, const Place &b);
bool operator==(const Arrangement &a, const Arrangement &b);
inline bool operator!=(const Arrangement &a, const Arrangement &b) { return !(a == b); }

// Every panel shown: the console's tabs in order (left to right, top to bottom), then the windows'.
std::vector<std::string> shown(const Arrangement &a);
bool shows(const Arrangement &a, std::string_view panel);
bool inConsole(const Arrangement &a, std::string_view panel);
// A pane shown or not (unset: shown, as Apple's guidelines advise against hiding a sidebar at first).
bool paneShown(const Arrangement &a, std::string_view panel, std::string_view pane);

// The changes, each returning the arrangement tidied.
// Show a panel in the console: as a tab beside `beside` when that shows there, else in a stack of
// its own at the end of the console's top row (the console made a row first if it is a column).
Arrangement showInConsole(Arrangement a, std::string_view panel, std::string_view beside = {});
Arrangement showInWindow(Arrangement a, std::string_view panel, Frame frame = {});
Arrangement hide(Arrangement a, std::string_view panel);
// Nothing when the panel isn't in the console, or is all it holds.
std::optional<Place> placeOf(const Arrangement &a, std::string_view panel);
// `panel` back at its place: a tab beside `beside`; or a frame beside the smallest part of the
// console holding the panels of `next` still there, in the split of that kind (made when that
// part isn't in one), with its share. As showInConsole puts it when none of them is there.
Arrangement showAt(Arrangement a, std::string_view panel, const Place &place);
// Out of the console, where it was kept in `closed` (when it has a place there).
Arrangement closePanel(Arrangement a, std::string_view panel);
// Back in the console: where it was closed from, else as showInConsole puts it.
Arrangement reopenPanel(Arrangement a, std::string_view panel);

// Regions. A side of a frame, or of the whole console.
enum class Side { Left, Right, Top, Bottom };
// `panel` (from wherever it is, or not shown yet) in a frame of its own on `side` of the frame
// holding `target`: that region split in two, the halves sharing what it had.
Arrangement splitBeside(Arrangement a, std::string_view panel, std::string_view target, Side side);
// The frame holding `panel`, all its tabs, to `side` of the frame holding `target` (that region
// split in two, as splitBeside); with no target, to that edge of the console, the whole height or
// width, with `share` of it (0: by what each needs).
Arrangement moveFrame(Arrangement a, std::string_view panel, std::string_view target, Side side, double share = 0);
// The split holding the frame of `panel`: Row (side by side), Column (one above the other), or
// Stack when that frame is the whole console.
Node::Kind splitOf(const Arrangement &a, std::string_view panel);
// That split's frames side by side (Row) or one above the other (Column).
Arrangement alignSplit(Arrangement a, std::string_view panel, Node::Kind kind);
// `panel` to the stack holding `target`, as its front tab.
Arrangement moveToTab(Arrangement a, std::string_view panel, std::string_view target);
// Two shown panels trade places (console tabs or windows).
Arrangement swap(Arrangement a, std::string_view first, std::string_view second);
Arrangement bringToFront(Arrangement a, std::string_view panel);
Arrangement setPane(Arrangement a, std::string_view panel, std::string_view pane, bool shown);

// The tidy form: only `known` panels, each once (the console's first, then a window's); empty
// stacks and splits gone, a one-child split replaced by its child (with the split's share), a
// split inside one of its own kind merged into it; shares summing to 1 where every sibling has
// one, else all 0; each stack's front within it.
Arrangement tidy(Arrangement a, const std::vector<std::string> &known = knownPanels());
// What is wrong with an arrangement, in words (empty: nothing): for tests and the log.
std::vector<std::string> problems(const Arrangement &a, const std::vector<std::string> &known = knownPanels());

std::string write(const Arrangement &a);
// The arrangement written: nothing when it isn't JSON of this version and shape (`why` says),
// else tidied.
std::optional<Arrangement> read(std::string_view json, std::string *why = nullptr);

struct Preset {
    std::string id;    // kept in settings
    const char *name;  // English, for tr(): as the console's Layouts menu shows it
    Arrangement arrangement;
};
// The console's built-in layouts: the nine it has had, then the operating styles' (their ids the
// styles' own: "social", "chasing", "contest", "portable").
const std::vector<Preset> &presets();
const Preset *preset(std::string_view id);

// Each layout as you adjusted it, by the console's id for it ("logging", "mine:Evening",
// "style:chasing"); kept as one JSON value. What can't be read is left out, not the rest.
std::string writeAdjusted(const std::map<std::string, Arrangement> &layouts);
std::map<std::string, Arrangement> readAdjusted(std::string_view json);

// Your own layouts (Save Layout As...), each named, in the order saved; kept as one JSON value.
struct Named {
    std::string name;
    Arrangement arrangement;
};
// A name as kept: on one line, trimmed, at most 60 characters (whole UTF-8 characters); empty: none.
std::string cleanName(std::string_view name);
// The same name, with letter case ignored (ASCII): "Evening" is "evening".
bool sameName(std::string_view a, std::string_view b);
std::string writeNamed(const std::vector<Named> &list);
// What can be read: an entry that isn't sound is left out, not the rest; nothing when it isn't
// JSON of this version.
std::vector<Named> readNamed(std::string_view json);
const Named *findNamed(const std::vector<Named> &list, std::string_view name);
// The list with `name` kept as `a`: in place of one of that name, else at the end (a name that
// cleans to nothing changes nothing).
std::vector<Named> saveNamed(std::vector<Named> list, std::string_view name, const Arrangement &a);
std::vector<Named> removeNamed(std::vector<Named> list, std::string_view name);

// The settings before arrangements: the console's preset (`layoutPreset`, its index) and what
// each of its five places showed (`layoutItemsV3`, the dock items 0 none, 1 Map, 2 Log Table,
// 3 New QSO, 4 Spots, 5 Contact Map, 6 QSO Details); the Map's panes (`mapSidebar`, `mapList`,
// `mapSelected`).
using Getter = std::function<std::string(const std::string &key)>;
Arrangement migrate(const Getter &get);

}  // namespace adif::layout
