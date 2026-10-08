// Reading the radio's frequency and mode through Hamlib's rigctld or flrig,
// over TCP, for New QSO. Read-only: only get_freq/get_mode (rigctld) and
// rig.get_xcvr/rig.get_vfo/rig.get_mode (flrig) are sent. The requests and
// replies are built and parsed by src/core/adif_radio.
#pragma once

#import <Foundation/Foundation.h>

#include <string>

typedef NS_ENUM(NSInteger, ADIFRadioKind) {
    ADIFRadioNone = 0,
    ADIFRadioRigctld = 1,  // Hamlib rigctld, default port 4532
    ADIFRadioFlrig = 2,    // flrig XML-RPC, default port 12345
};

NSString *ADIFRadioKindName(ADIFRadioKind kind);  // "Hamlib rigctld", "flrig"
int ADIFRadioDefaultPort(ADIFRadioKind kind);
ADIFRadioKind ADIFRadioKindFromSetting(const std::string &value);  // "rigctld", "flrig", else None
std::string ADIFRadioKindSetting(ADIFRadioKind kind);

struct ADIFRadioReading {
    std::string hz;       // frequency in Hz, as the program reported it
    std::string rigMode;  // the mode name as the program reported it
    std::string rigName;  // flrig's transceiver name; empty for rigctld
};

// Ask once, on a background queue; `done` runs on the main queue with error nil on success.
void ADIFReadRadio(ADIFRadioKind kind, NSString *host, int port, void (^done)(const ADIFRadioReading &reading, NSString *error));
