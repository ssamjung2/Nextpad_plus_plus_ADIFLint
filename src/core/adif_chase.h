// Chasing (docs/OPERATING_STYLES_PLAN.md, Stage 4): what each spot offers you, explained, and the
// spots in order of how much. Every need a spot meets counts: on your watch list, a new DXCC
// entity (else a new band for it, else a new mode there), an IOTA group or a POTA park you
// haven't worked, and an entity worked on the band but not confirmed there when the station
// uploads to LoTW (a QSO now can confirm it). Each need has a weight; a spot's score is the sum.
// The order is deterministic: the score, then the newest spot, then the call, the frequency and
// the spot's place in the list. A spot that meets no need is no opportunity, nor is one of a
// station you worked today on its band and mode (a duplicate), nor your own signal.
#pragma once

#include "adif_needs.h"
#include "adif_spots.h"

#include <functional>
#include <set>
#include <string>
#include <vector>

namespace adif::chase {

enum class Reason { Watched, NewDxcc, NewBand, NewMode, NewIota, NewPark, Unconfirmed };

// How much each need counts (a goal's weight; Stage 7 lets you change them).
struct Weights {
    int watched = 60, newDxcc = 100, newBand = 40, newMode = 25, newIota = 30, newPark = 20, unconfirmed = 10;
};

struct Inputs {
    const WorkedIndex *worked = nullptr;
    const CountryTable *countries = nullptr;
    std::vector<std::string> watch;     // adif::watchList's
    std::set<std::string> workedToday;  // todayKey()s of today's QSOs (UTC): a spot of one is a duplicate
    std::function<bool(const std::string &call)> usesLotw;  // optional: the station uploads to LoTW
    long long now = 0;                  // Unix seconds UTC, for how fresh a spot is
    Weights weights;
};

struct Opportunity {
    size_t spot = 0;              // its index in the spots given
    int score = 0;                // its needs' weights, summed
    std::vector<Reason> reasons;  // the most valuable first
    std::string why;              // the reasons in words, then how fresh: "New DXCC entity (Malta). Spotted 2 min ago."
};

// A call on a band in a mode group, as a QSO or a spot has them: "K1ABC|20m|0".
std::string todayKey(std::string_view call, std::string_view band, std::string_view mode);
// The opportunities among the spots, the best first.
std::vector<Opportunity> rank(const std::vector<Spot> &spots, const Inputs &in);
// "2 min", "42 s", "1 h 5 min"; "" for no time.
std::string age(long long seconds);

}  // namespace adif::chase
