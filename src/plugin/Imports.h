// Import from LoTW, QRZ.com Logbook and eQSL: download the QSOs the site holds
// for you, then add the ones the log lacks and the confirmations of the ones it
// has, after a review (one undo step). The ADIF work is in src/core/adif_import,
// the HTTPS requests in Lookup.mm.
#pragma once

namespace imports {

void cmdImportLotw();
void cmdImportQrzLogbook();
void cmdImportEqsl();

// The active document changed or another became active.
void documentChanged();

}  // namespace imports
