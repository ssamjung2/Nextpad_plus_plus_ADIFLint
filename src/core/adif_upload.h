// Uploading a log to online services: which records to send, the request
// bodies, the replies, and the ADIF upload-status fields written afterwards.
// Pure C++17: the plugin does the HTTPS requests and runs TQSL.
//
// Sources (checked 2026-10-07):
//   QRZ Logbook API (www.qrz.com/docs/logbook/QRZLogbookAPI.html, updated
//     2025-03-07): POST https://logbook.qrz.com/api, form fields KEY, ACTION=INSERT,
//     ADIF (one QSO per INSERT), OPTION=REPLACE; reply RESULT=OK|FAIL|REPLACE|AUTH,
//     LOGID, COUNT, REASON; an identifiable User-Agent is required.
//   Club Log putlogs.php (clublog.org knowledge base, updated 2025-12-17):
//     multipart POST of email, password (an Application Password), callsign,
//     file, api; 200 means queued; on anything else show the message and stop.
//   eQSL ImportADIF (www.eqsl.cc/qslcard/ImportADIF.txt, revised 2026-03-01):
//     multipart POST to https://www.eQSL.cc/qslcard/ImportADIF.cfm with
//     Filename, EQSL_USER, EQSL_PSWD; reply lines "Result: x out of y records
//     added", "Error: ...", "Warning: ... Bad record: Duplicate".
//   TQSL command line (lotw.arrl.org/lotw-help/cmdline/): -x batch, -d no
//     date dialog, -u upload, -l station location, -a action; exit 0 success,
//     8 none processed (duplicates or out of date range), 9 some ignored.
//   ADIF 3.1.7: QSO_Upload_Status Y uploaded, N do not upload, M modified since
//     upload; QSL_Sent Y, N, R requested, Q queued, I ignore or invalid.
#pragma once

#include "adif_edit.h"
#include "adif_lint.h"

#include <string>
#include <string_view>
#include <vector>

namespace adif {

enum class UploadService { QRZ, LoTW, ClubLog, EQSL };

struct UploadFields {
    const char *status;  // QRZCOM_QSO_UPLOAD_STATUS, LOTW_QSL_SENT, CLUBLOG_QSO_UPLOAD_STATUS, EQSL_QSL_SENT
    const char *date;    // QRZCOM_QSO_UPLOAD_DATE, LOTW_QSLSDATE, CLUBLOG_QSO_UPLOAD_DATE, EQSL_QSLSDATE
};
UploadFields uploadFields(UploadService s);
const char *uploadServiceName(UploadService s);  // "QRZ.com Logbook", "LoTW", "Club Log", "eQSL"

struct UploadItem {
    int group = -1, record = 0;
    std::string call, date, time, band, mode, station;
    std::string status;   // the service's status field now
    bool done = false;    // already uploaded (or sent), by its status
    bool skip = false;    // marked not to upload (N, or I for QSL services)
    bool replace = false; // QRZ: modified since upload (M): send with OPTION=REPLACE
    std::string problem;  // why it cannot be sent (missing CALL, QSO_DATE...); empty when fine
};
// Every record, with its upload state for the service.
std::vector<UploadItem> uploadItems(std::string_view text, const DocModel &m, UploadService s);
// True when the item should be offered ticked: not done, not skipped, no problem.
inline bool uploadWanted(const UploadItem &i) { return !i.done && !i.skip && i.problem.empty(); }

// One record as ADI ("<CALL:4>K1AB ... <EOR>"), lengths in bytes, without the
// services' own status fields (and EQSL/APP fields for other services).
std::string recordAdi(std::string_view text, const DocModel &m, int group);
// A complete ADI file of the records, with a header.
std::string uploadFile(std::string_view text, const DocModel &m, const std::vector<int> &groups, std::string_view programVersion,
                       std::string_view utcTimestamp, std::string_view extraHeader = {});

// application/x-www-form-urlencoded
std::string formEncode(std::string_view s);
std::string formDecode(std::string_view s);

// QRZ Logbook.
std::string qrzInsertBody(std::string_view key, std::string_view adi, bool replace);
std::string qrzStatusBody(std::string_view key);
struct QrzReply {
    std::string result;  // OK, FAIL, REPLACE, AUTH, or "" when unreadable
    std::string logid, reason, count;
    bool ok() const { return result == "OK" || result == "REPLACE"; }
    bool duplicate() const;  // FAIL because the QSO is already in the logbook
};
QrzReply parseQrzReply(std::string_view body);

// eQSL.
struct EqslReply {
    int added = -1, total = -1;  // from "Result: x out of y records added"; -1 when absent
    bool duplicate = false;      // "Bad record: Duplicate"
    std::vector<std::string> errors, warnings, info;  // text after "Error:", "Warning:", "Information:"
};
EqslReply parseEqslReply(std::string_view html);

// QRZ Logbook FETCH: the reply's RESULT, COUNT and REASON, and its ADIF (after
// ADIF=, HTML entities decoded; QRZ's docs don't say how it is encoded, and
// Wavelog decodes it this way). False when there is no RESULT.
bool parseQrzFetch(std::string_view body, QrzReply *reply, std::string *adif);
// The FETCH request for records from `afterLogid` on, `max` at a time; with
// `between` ("2026-10-06+2026-10-07"), only QSOs on those dates.
std::string qrzFetchBody(std::string_view key, long long afterLogid, int max, std::string_view between = {});
// &lt; &gt; &amp; &quot; &#39; &#NN; decoded.
std::string htmlDecode(std::string_view s);

// eQSL DownloadInBox: the .adi link after "Your ADIF log file has been built",
// or "" with `error` set from an "Error:" line.
std::string eqslInboxLink(std::string_view html, std::string *error);

// TQSL's exit code in words.
std::string tqslExitMeaning(int code);

// Set the service's status to Y and its date to `today` (YYYYMMDD) on these records.
std::vector<TextEdit> markUploaded(std::string_view text, const DocModel &m, const std::vector<int> &groups, UploadService s,
                                   std::string_view today, LengthUnit unit, bool utf8);

// Fields that track QSLs and uploads rather than describe the QSO: QSL_RCVD,
// QSL_SENT, QSLRDATE, QSLSDATE and their _VIA fields, the LOTW_, EQSL_, DCL_,
// QRZCOM_, CLUBLOG_, HRDLOG_, HAMLOGEU_ and HAMQTH_ fields, and APP_ fields.
bool isTrackingField(std::string_view name);
// For these records, QRZCOM_QSO_UPLOAD_STATUS and CLUBLOG_QSO_UPLOAD_STATUS of
// Y become M: ADIF's "modified since being uploaded", so the next upload sends
// the change. (LoTW and eQSL have no such status.)
std::vector<TextEdit> markModified(std::string_view text, const DocModel &m, const std::vector<int> &groups,
                                   LengthUnit unit, bool utf8);
// `edits` plus those of `extra` that don't overlap any of them; sorted.
std::vector<TextEdit> mergeEdits(std::vector<TextEdit> edits, const std::vector<TextEdit> &extra);

// multipart/form-data: text fields and one file.
struct MultipartPart {
    std::string name, value;
    std::string filename;  // non-empty: a file part
};
std::string multipartBody(const std::vector<MultipartPart> &parts, std::string_view boundary);

}  // namespace adif
