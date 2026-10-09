// Import from LoTW, QRZ.com Logbook and eQSL: the QSOs a site holds for you,
// matched against the log. A QSO the log already has gains the site's
// confirmation and the details that come with it (only fields it lacks, as
// Enrich does); a QSO the log lacks is added as a new record. Pure C++17: the
// plugin downloads, this code reads the download and plans the edits.
//
// Matching follows LoTW's rule (https://lotw.arrl.org/lotw-help/key-concepts/):
// the same CALL and BAND, start times within 30 minutes, and the same mode or
// mode group (CW, phone, data). Each downloaded QSO matches at most one record
// and each record at most one downloaded QSO: the same mode first, then the
// closest time.
#pragma once

#include "adif_edit.h"
#include "adif_enrich.h"
#include "adif_lint.h"

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

enum class ImportSite { LoTW, QRZLogbook, EQSL };
const char *importSiteName(ImportSite s);  // "LoTW", "QRZ.com Logbook", "eQSL"

// One QSO from a site's download, from your side of the contact.
struct SiteQso {
    int group = -1;  // in the downloaded document
    std::string call, date, time, band, mode;
    bool confirmed = false;
    // The record to add when the log lacks this QSO, in field order.
    std::vector<std::pair<std::string, std::string>> fields;
    // What a matching record may gain: the confirmation, upload status and
    // the details the site adds for this QSO.
    FieldMap update;
    std::string problem;  // why it can't be added (no CALL, date, time, band or mode); empty when fine
    bool addByDefault = true;  // eQSL InBox records are the other station's: offered, not ticked
};
// The download's records, read for each site (sources checked 2026-10-08):
//   LoTW lotwreport.adi with qso_qsl=no, qso_withown, qso_mydetail and
//     qso_qsldetail (lotw.arrl.org/lotw-help/developer-query-qsos-qsls/): your
//     uploaded QSOs with QSL_RCVD Y or N, QSLRDATE, APP_LoTW_RXQSO (when LoTW
//     received the upload) and, for a confirmed QSO, the confirming station's
//     DXCC, COUNTRY, CONT, CQZ, ITUZ, IOTA, GRIDSQUARE, VUCC_GRIDS, STATE, CNTY.
//     A non-ADIF mode comes as APP_LoTW_MODE; a submode there is mapped to its mode.
//   QRZ.com Logbook FETCH (www.qrz.com/docs/logbook/QRZLogbookAPI.html, updated
//     2025-03-07; qrz.com/docs/logbook30/adif-standard): the ADIF you uploaded,
//     plus APP_QRZLOG_LOGID, APP_QRZLOG_STATUS (C confirmed, N not confirmed,
//     2 requested, S seen, R rejected) and APP_QRZLOG_QSLDATE. '_' in a call
//     stands for '/' (observed, not documented).
//   eQSL DownloadInBox (www.eqsl.cc/qslcard/DownloadInBox.txt, revised
//     2025-10-12): the eQSLs other stations sent you, from their side: CALL is
//     the sender, RST_SENT their report to you; EQSL_QSL_RCVD Y, EQSL_QSLRDATE,
//     GRIDSQUARE when 4 or more characters. eQSL warns that the InBox is not
//     your station log.
std::vector<SiteQso> siteQsos(ImportSite site, std::string_view text, const DocModel &m, std::string_view today);

struct ImportItem {
    enum class Kind { Add, Update, InLog };
    Kind kind = Kind::Add;
    size_t qso = 0;                     // index into the SiteQso list
    int group = -1;                     // the matching record (Update, InLog)
    int record = 0;                     // its record number (1-based)
    std::vector<EnrichChange> changes;  // Update: what the record gains
};
// One item per downloaded QSO, in the download's order.
std::vector<ImportItem> planImport(std::string_view logText, const DocModel &log, const std::vector<SiteQso> &qsos,
                                   ImportSite site);

// The new records for these QSOs, built in the log's layout and joined for appendRecord().
std::string importedRecords(const std::vector<SiteQso> &qsos, const std::vector<size_t> &which, Layout layout,
                            std::string_view eol, LengthUnit unit, bool utf8);

}  // namespace adif
