// Station Profiles' TQSL Certificate: TQSL's callsign certificates on this Mac to choose from,
// and the chosen one's passphrase, tested against its own key (adif_tqsl.h) and kept in the
// Keychain (Lookup.h), never in the profiles file. Upload to LoTW passes it to TQSL with -p.
#pragma once

#include <string>

@class NSWindow;

namespace tqslcert {

// The certificate for the profile named `profile`, whose certificate now is `call` (and
// `serial`, when known), on a sheet over `parent` (Station Profiles, a floating panel a window
// would open behind). `done` gets the choice when Save is pressed: a callsign and its serial,
// or both empty to sign with the Station Location's own certificate.
void choose(NSWindow *parent, const std::string &profile, const std::string &call, const std::string &serial,
            void (^done)(const std::string &call, const std::string &serial));

}  // namespace tqslcert
