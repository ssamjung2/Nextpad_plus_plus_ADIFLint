// Upload to QRZ.com Logbook, LoTW (through TQSL), Club Log and eQSL. Each
// window lists the QSOs it would send and sends nothing until Upload is
// pressed; afterwards the uploaded records get the service's ADIF status and
// date fields (one undo step). The ADIF work is in src/core/adif_upload, the
// HTTPS requests in Lookup.mm.
#pragma once

namespace uploads {

void cmdUploadQrz();
void cmdUploadLotw();
void cmdUploadClubLog();
void cmdUploadEqsl();

// The active document changed or another became active.
void documentChanged();

}  // namespace uploads
