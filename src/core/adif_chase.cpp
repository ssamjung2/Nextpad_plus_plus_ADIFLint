#include "adif_chase.h"

#include "adif_enrich.h"
#include "adif_i18n.h"
#include "adif_parks.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>

namespace adif::chase {
namespace {

std::string lower(std::string s) {
    for (char &c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

std::string upper(std::string s) {
    for (char &c : s) c = (char)std::toupper((unsigned char)c);
    return s;
}

}  // namespace

std::string todayKey(std::string_view call, std::string_view band, std::string_view mode) {
    return lookupCall(call) + "|" + lower(std::string(band)) + "|" + std::to_string(modeGroup(mode));
}

std::string age(long long s) {
    if (s < 0) return "";
    if (s < 60) return i18n::trf("{n} s", {{"n", std::to_string(s)}});
    if (s < 3600) return i18n::trf("{n} min", {{"n", std::to_string(s / 60)}});
    long long m = (s % 3600) / 60;
    return m ? i18n::trf("{h} h {m} min", {{"h", std::to_string(s / 3600)}, {"m", std::to_string(m)}}) : i18n::trf("{h} h", {{"h", std::to_string(s / 3600)}});
}

std::vector<Opportunity> rank(const std::vector<Spot> &spots, const Inputs &in) {
    std::vector<Opportunity> out;
    static const WorkedIndex none;
    const WorkedIndex &w = in.worked ? *in.worked : none;
    const Weights &k = in.weights;
    for (size_t i = 0; i < spots.size(); ++i) {
        const Spot &s = spots[i];
        if (s.heardMe || s.activator.empty()) continue;
        if (in.workedToday.count(todayKey(s.activator, s.band, s.mode))) continue;  // a duplicate: worked today on this band and mode
        SpotStatus st = spotStatus(w, s, in.countries);
        Opportunity o;
        o.spot = i;
        std::vector<std::string> words;
        auto add = [&](Reason r, int weight, std::string text) {
            o.reasons.push_back(r);
            o.score += weight;
            words.push_back(std::move(text));
        };
        if (std::string on = watchedFor(in.watch, s, st.entity); !on.empty()) add(Reason::Watched, k.watched, i18n::trf("On your watch list ({what})", {{"what", on}}));
        switch (st.need) {
            case SpotNeed::NewDxcc: add(Reason::NewDxcc, k.newDxcc, i18n::trf("New DXCC entity ({entity})", {{"entity", st.entity}})); break;
            case SpotNeed::NewBand:
                add(Reason::NewBand, k.newBand, i18n::trf("{entity} new on {band}", {{"entity", st.entity}, {"band", s.band}}));
                break;
            case SpotNeed::NewMode:
                add(Reason::NewMode, k.newMode, i18n::trf("A new mode for {entity} on {band}", {{"entity", st.entity}, {"band", s.band}}));
                break;
            case SpotNeed::Worked:
                if (in.usesLotw && in.usesLotw(s.activator))
                    add(Reason::Unconfirmed, k.unconfirmed,
                        i18n::trf("{entity} worked on {band}, not confirmed; they use LoTW", {{"entity", st.entity}, {"band", s.band}}));
                break;
            default: break;
        }
        if (upper(s.program) == "IOTA")
            for (const std::string &r : s.refs)
                if (!r.empty() && !w.iota.count(upper(r))) {
                    add(Reason::NewIota, k.newIota, i18n::trf("IOTA {ref}: a group you haven't worked", {{"ref", upper(r)}}));
                    break;
                }
        if (st.newPark) add(Reason::NewPark, k.newPark, i18n::trf("{program} {ref}: a park you haven't worked", {{"program", s.program}, {"ref", s.reference}}));
        if (o.reasons.empty()) continue;
        // The most valuable first (the watch list's mention stays where its weight puts it).
        std::vector<size_t> order(o.reasons.size());
        for (size_t r = 0; r < order.size(); ++r) order[r] = r;
        auto weightOf = [&](Reason r) {
            switch (r) {
                case Reason::Watched: return k.watched;
                case Reason::NewDxcc: return k.newDxcc;
                case Reason::NewBand: return k.newBand;
                case Reason::NewMode: return k.newMode;
                case Reason::NewIota: return k.newIota;
                case Reason::NewPark: return k.newPark;
                case Reason::Unconfirmed: return k.unconfirmed;
            }
            return 0;
        };
        std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return weightOf(o.reasons[a]) > weightOf(o.reasons[b]); });
        std::vector<Reason> reasons;
        std::string why;
        for (size_t r : order) {
            reasons.push_back(o.reasons[r]);
            why += (why.empty() ? "" : "; ") + words[r];
        }
        o.reasons = std::move(reasons);
        why += ".";
        if (s.epoch > 0 && in.now >= s.epoch) why += " " + i18n::trf("Spotted {age} ago.", {{"age", age(in.now - s.epoch)}});
        o.why = why;
        out.push_back(std::move(o));
    }
    std::stable_sort(out.begin(), out.end(), [&](const Opportunity &a, const Opportunity &b) {
        const Spot &x = spots[a.spot], &y = spots[b.spot];
        if (a.score != b.score) return a.score > b.score;
        if (x.epoch != y.epoch) return x.epoch > y.epoch;
        if (x.activator != y.activator) return x.activator < y.activator;
        if (x.khz != y.khz) return std::atof(x.khz.c_str()) < std::atof(y.khz.c_str());
        return a.spot < b.spot;
    });
    return out;
}

}  // namespace adif::chase
