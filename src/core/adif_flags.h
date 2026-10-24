// Flags for the DXCC entities, shown beside their names and calls on the Map. An entity has its
// own ISO 3166-1 code's flag where it has one (Guam, Åland, Heard I.), else the flag of the
// country it belongs to (Alaska, Corsica, Crete); Unicode's flags for codes ISO reserves (Canary
// Is. IC, Ceuta & Melilla EA, Clipperton CP, Ascension AC, Tristan da Cunha TA); England,
// Scotland and Wales their own (the RGI tag sequences; Northern Ireland, which has none, the
// UK's); the UN's for the UN and ITU headquarters; Antarctica's for the places in the Antarctic
// Treaty area. None for the Spratly Is. and Scarborough Reef (disputed), the Sovereign Military
// Order of Malta, or deleted entities.
//
// Drafted 2026-10-24 and checked against k0swe/dxcc-json (Apache-2.0, 7d0c8dd), Wavelog's
// DxccFlag.php (MIT, 5e9513e) and QLog's dxcc.json (4d41fc7): where they differ it is by policy
// (a country's flag for a territory with its own code, none for anything claimed by two) or by
// mistake in theirs (Peter 1 I. as Bouvet's BV, Northern Ireland's tag sequence, which no system
// draws). Every code is an RGI emoji flag in Unicode's emoji-sequences.txt 18.0 (2026-04-30).
#pragma once

#include <string>

namespace adif {

// The entity's flag code: an ISO 3166-1 alpha-2 code, a reserved one Unicode draws, "UN", or
// "GB-ENG", "GB-SCT", "GB-WLS"; empty for none.
std::string dxccFlagCode(int dxcc);
// Its flag as text: an emoji (two regional indicator letters, or a tag sequence); empty for none.
std::string dxccFlag(int dxcc);

}  // namespace adif
