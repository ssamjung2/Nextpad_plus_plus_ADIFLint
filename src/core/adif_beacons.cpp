#include "adif_beacons.h"

#include <cmath>

namespace adif {

const Beacon kBeacons[kBeaconCount] = {
    {"4U1UN", "United Nations, New York", "FN30as"}, {"VE8AT", "Inuvik, Northwest Territories", "CP38gh"},
    {"W6WX", "Mt. Umunhum, California", "CM97bd"},   {"KH6RS", "Maui, Hawaii", "BL10ts"},
    {"ZL6B", "Masterton, New Zealand", "RE78tw"},    {"VK6RBP", "Rolystone, Western Australia", "OF87av"},
    {"JA2IGY", "Mt. Asama, Japan", "PM84jk"},        {"RR9O", "Novosibirsk, Russia", "NO14kx"},
    {"VR2B", "Hong Kong", "OL72bg"},                 {"4S7B", "Colombo, Sri Lanka", "MJ96wv"},
    {"ZS6DN", "Pretoria, South Africa", "KG33xi"},   {"5Z4B", "Kikuyu, Kenya", "KI88hr"},
    {"4X6TU", "Tel Aviv, Israel", "KM72jb"},         {"OH2B", "Lohja, Finland", "KP20eh"},
    {"CS3B", "São Jorge, Madeira", "IM12jt"},        {"LU4AA", "Buenos Aires, Argentina", "GF05tj"},
    {"OA4B", "Lima, Peru", "FH17mw"},                {"YV5B", "Caracas, Venezuela", "FK60nd"},
};

const double kBeaconMHz[kBeaconBands] = {14.100, 18.110, 21.150, 24.930, 28.200};
const char *const kBeaconBandNames[kBeaconBands] = {"20m", "17m", "15m", "12m", "10m"};

namespace {

// The 10-second slot of the 3-minute cycle, 0-17.
size_t slotAt(double unixSeconds) {
    double s = std::fmod(std::floor(unixSeconds), 180.0);
    if (s < 0) s += 180;
    return (size_t)(s / 10) % kBeaconCount;
}

}  // namespace

size_t beaconOn(size_t band, double unixSeconds) {
    return (slotAt(unixSeconds) + kBeaconCount - band % kBeaconBands) % kBeaconCount;
}

double beaconSlotLeft(double unixSeconds) {
    double s = std::fmod(unixSeconds, 10.0);
    return 10 - (s < 0 ? s + 10 : s);
}

size_t beaconBand(size_t beacon, double unixSeconds) {
    size_t band = (slotAt(unixSeconds) + kBeaconCount - beacon % kBeaconCount) % kBeaconCount;
    return band < kBeaconBands ? band : kBeaconBands;
}

}  // namespace adif
