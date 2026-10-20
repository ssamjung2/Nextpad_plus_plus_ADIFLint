// After New QSO logs a QSO, an offer to spot it, sent only on Send:
// - the station you worked, on the DX cluster connection (a dx command with an editable comment;
//   never your own callsign: DXSpider's manual asks for the station "you have worked or heard,
//   (ie not your own callsign!)"), when the cluster is connected;
// - yourself, during a POTA activation, on pota.app in your browser (POTA lets activators spot
//   themselves there, and documents no way for programs to post spots).
// Not offered during a contest (contests limit spotting), in offline mode, for a station already
// spotted on that band in the last 10 minutes, or once turned off (its box, or Settings → Spots).
// AppKit and Foundation.
#pragma once

#import <Cocoa/Cocoa.h>

#include "adif_profiles.h"

namespace spotoffer {

void afterLog(const adif::FieldList &fields, bool contest);
bool wanted();  // "spotOfferAfterLog", on at first
void setWanted(bool on);

}  // namespace spotoffer
