# ADIF Lint for Nextpad++

A [Nextpad++](https://nextpad.org) (macOS) plugin that checks amateur-radio log files in
[ADIF 3.1.7](https://www.adif.org/317/ADIF_317.htm) ADI format (`.adi`, `.adif`) as you
type, and repairs their data lengths.

Hand-editing an ADI file is risky: every field is written `<NAME:LENGTH>data`, so changing
`W1AW` to `W1AW/P` without changing `4` to `6` silently truncates the call, and a length
that is too long swallows the next field. Importers don't report either mistake.

## What it does (v0.8)

- **New QSO…** opens a window for logging contacts one after another.
  - Your station's fields carry over from the last record: STATION_CALLSIGN, OPERATOR,
    MY_* such as MY_SIG_INFO and MY_STATE, BAND, FREQ, MODE and SUBMODE.
  - Per-contact fields start empty each time. The window keeps the log's field order,
    then adds CALL, QSO_DATE, TIME_ON, BAND, FREQ, MODE, SUBMODE, RST_SENT and RST_RCVD
    if the log doesn't have them.
  - QSO_DATE and TIME_ON are filled with the current UTC time when you log. Untick the
    box to enter them by hand when typing up a paper log.
  - BAND follows FREQ, the SUBMODE list follows MODE, and reports default to 59 (phone)
    or 599 (CW, RTTY).
  - Every field is checked as you type. CALL, QSO_DATE, TIME_ON, MODE, and BAND or FREQ
    are required.
  - A contact already in the log on the same band, mode and UTC day gets a warning, by
    POTA's rule: the same activator at another park (SIG_INFO or POTA_REF) is a new
    contact. Portable forms of the call (K1ABC/P) count as the same station.
  - **Log QSO** (Return) appends the record with correct lengths, in the log's own layout,
    as one undo step, then clears the window for the next contact.
  - In an empty document, it starts a new log with a header.
  - **Fields…** chooses and orders the fields the window asks for. Your fields are on the
    left; every field you can add is on the right with its type and a brief description.
    - The descriptions are the first paragraph of the ADIF 3.1.7 specification's own text;
      hover a row for the full text.
    - Search matches names and descriptions ("park" finds POTA_REF), with exact name
      matches first.
    - Add the selected fields (several at once) or double-click one. Remove fields, and
      reorder them with Move Up and Move Down.
    - CALL, QSO_DATE, TIME_ON and MODE always stay, and so does BAND or FREQ.
    - **Use the Log's Fields** returns to the automatic list: the last record's fields
      plus the core ones.
    - With "Also copy this station's details…" ticked (the default), station fields that
      aren't listed are still copied from the last record into each new QSO:
      STATION_CALLSIGN, OPERATOR, OWNER_CALLSIGN, TX_PWR and the MY_ fields. The window
      names them, for example "Also written, from the last record: MY_SIG_INFO US-7929".
    - The choice is saved in `ADIFLint.ini`.
  - **From Radio** reads the frequency and mode from your radio through Hamlib's
    `rigctld` or through flrig (set up under Settings → Radio). FREQ is written in MHz,
    BAND follows, and MODE/SUBMODE are set from the radio's mode: USB/LSB → SSB with that
    sideband, CW, RTTY, AM, FM, C4FM and D-STAR → DIGITALVOICE. For a data mode (PKTUSB,
    DATA-U, USB-D…) MODE is left to you, since only the program decoding it knows it is FT8.
    **Follow the radio** reads it every 2 seconds and updates the fields when the radio
    changes. Only queries are sent (rigctld `get_freq`/`get_mode`; flrig `rig.get_xcvr`,
    `rig.get_vfo`, `rig.get_mode`): nothing keys or tunes the radio. flrig answers
    14.070 MHz USB when it has no radio, so ADIF Lint checks `rig.get_xcvr` first.
  - **Look up** fills the fields a new call leaves empty, as you type. **Country data**
    (the default, offline) gives DXCC, COUNTRY, CQZ, ITUZ and CONT from the call's prefix;
    **QRZ.com** or **HamQTH** add name, QTH, state, grid and more from your callbook account
    (the home address of a portable or park station is shown but not written). The line
    under it shows what was found, the distance and bearing from MY_GRIDSQUARE to the
    station's grid ("7,086 km at 42°", also written to DISTANCE when the window has that
    field), and, for a park, reference or summit in SIG_INFO, POTA_REF, WWFF_REF or
    SOTA_REF, what your logs say about it ("US-1234: a new park!", "KFF-5255: worked 2
    times before, last 2026-10-03 (a.adi)"). Changing the call takes back what the last
    lookup filled, unless you edited it.
  - **Spots…** (also on the menu as **Spots (POTA, WWFF)…**) lists the activators spotted
    now, from `api.pota.app` or `spots.wwff.co`, refreshed every minute while the window
    is open, with band and mode filters and a search box. Double-click one (or **Use in New
    QSO**) to fill CALL, FREQ, BAND, MODE (SSB gets LSB below 10 MHz except 60 m, else USB;
    FT4 is MFSK/FT4) and the reference as SIG (POTA or WWFF) and SIG_INFO, plus POTA_REF
    or WWFF_REF. If the window shows neither SIG_INFO nor POTA_REF nor WWFF_REF, SIG and
    SIG_INFO rows are added so the reference is logged. The Worked column says **NEW**
    (green) for a park or reference that isn't in this log or your logs folder, **worked**
    for one that is, and **today** (blue) for a station already worked today on that band.
  - With a logs folder chosen in Worked Before, the window also says when the call is in
    your other logs ("K1ABC: 4 QSOs in 2 other logs; last 2026-09-30 14:05 on 20m SSB").
- **Log Table…** shows every record in a sortable table (click a heading; numbers sort
  as numbers) with a filter box. Dates and times read as 2026-10-06 and 22:30. Selecting
  a row shows that record in the editor; double-clicking the # goes there.
  - Double-click a value to edit it: the field is written back with its length (empty
    removes it, dates and times may be typed either way), as one undo step, and an
    uploaded QSO becomes M (see Uploads).
  - Right-click the headings to choose the columns shown. The columns and the sort are
    remembered.
  - **Bulk Edit Selected…** edits the selected rows, and **Export CSV…** saves the rows
    shown. The table follows your edits.
- **Activation Tracker (POTA, WWFF, SOTA)…** counts activations with each program's rule
  (choose the program at the top; it is remembered):
  - **POTA** ([rules](https://docs.pota.app/docs/rules.html), modified 2026-10-04): 10 QSOs
    from one park in one UTC day; a repeat of the same CALL, band, mode and park-to-park
    park doesn't count; records missing CALL, TIME_ON, BAND or MODE, or working your own
    call, are rejected. Parks come from MY_POTA_REF, or MY_SIG=POTA with MY_SIG_INFO.
  - **WWFF** (WWFF Global Rules v5.10, 2025-09-03, wwff.co): 44 QSOs per
    reference, counted over all your activations of it; the same call again on another
    band, mode or day counts. References come from MY_WWFF_REF, or MY_SIG=WWFF with
    MY_SIG_INFO.
  - **SOTA**: one QSO activates a summit and four different stations score its points
    (from SOTA's published guides; check sota.org.uk). The QSOs column counts stations.
    Summits come from MY_SOTA_REF, or MY_SIG=SOTA with MY_SIG_INFO.
  - Records without STATION_CALLSIGN or OPERATOR count for the log's usual station. The
    headline shows today's activation ("US-7929 today: 7 QSOs, 3 more to activate"), and
    it updates as you log. **Export Logs…** opens the export for that program.
- **Export Activation Logs…** writes one file per park (reference, summit) and UTC day.
  Each file is listed with its QSO count and notes (short of 10, duplicates the program
  will drop) before anything is saved, and existing files are replaced only on a second
  press. Records without STATION_CALLSIGN or OPERATOR get the callsign you enter. A `/` in
  a callsign becomes `_` in the file name.
  - **POTA**, named as POTA asks for emailed logs
    ([submitting logs](https://docs.pota.app/docs/activator_reference/submitting_logs.html)):
    `KW9D@US-7929-20261006.adi`, with the state added for a park spanning several
    (`W8MSC@US-4239-20181231-US-MI.adi`). A two-fer gives one file per park, each with
    MY_SIG=POTA and that park in MY_SIG_INFO (POTA wants a separate log per park).
  - **WWFF**: `KW9D@KFF-1234 20261006.adi`, the name WWFF's log search tutorial (v1.3,
    April 2025) asks for, with MY_WWFF_REF set. Send them to your national WWFF log manager.
  - **SOTA**: `KW9D_W7A-AE-001_20261006.adi` with MY_SOTA_REF set, for the upload page of
    the SOTA database.
- **Worked Before…** searches every `.adi`/`.adif` file in a folder you choose (and its
  subfolders) for a call, matching portable forms (`VE3/K1ABC/P` finds K1ABC). The folder
  is read in the background and re-read when files change.
- **Log Summary…** reports records, calls, date range, QSOs per band, mode and UTC day,
  DXCC entities, states, grids, parks activated and parks worked (a hunter's tally), and
  how many QSOs are confirmed and uploaded to each service. **Copy** puts it on the
  clipboard.
- **Bulk Edit…** sets, replaces text in, removes or renames a field across all records,
  the editor selection, or the rows selected in the Log Table, optionally only where
  another field is, contains, lacks or has a value. **Preview** lists every change
  (untick any) and says whether the log would have more errors afterwards; **Apply** is
  one undo step. A rename that would duplicate a field in a record skips that record.
  **Fill DISTANCE from grid squares** writes DISTANCE (km, great circle between the
  centres of MY_GRIDSQUARE and GRIDSQUARE) where both grids are known.
- **Time Shift…** converts QSO_DATE/TIME_ON (and QSO_DATE_OFF/TIME_OFF) between UTC and
  a time zone, in either direction: **From local time to UTC** for a log written in local
  time (ADIF times are UTC), or **From UTC to local time** to undo that. The zone is a
  name such as America/Chicago (your Mac's zone at first, then the last one used), and
  each QSO gets the offset in force on its own date, daylight saving included, from
  macOS's time zone database. A local time the clocks skipped (spring forward) or
  repeated (fall back) is listed by record and left alone, since its UTC time is unknown
  or ambiguous; fix those with **By a fixed amount**, which moves times by days, hours
  and minutes. Dates follow across midnight, month and year ends, and times keep HHMM or
  HHMMSS. Same preview and scope as Bulk Edit.
- **Sort Records by Date and Time** reorders the records (one undo step). A comment
  between records moves with the record after it; records without a valid date and time
  go last in their old order.
- **Remove Duplicates…** finds QSOs logged more than once: same CALL, band and mode
  starting within 2 minutes (adjustable), and no different STATION_CALLSIGN, MY_SIG_INFO,
  SIG_INFO or POTA references, so park-to-park lines repeated for each park of a two-fer
  stay. It keeps the record with the most fields and can copy fields only the removed one
  had. Untick any set before removing.
- **Merge Another Log…** adds another file's records at the end, rebuilt in this log's
  layout with lengths counted this log's way, skipping QSOs it already has, and then
  sorts by date and time if you like. It warns about USERDEF fields this log's header
  lacks.
- **Export CSV…** saves the log as CSV (RFC 4180, a column per field used). A value a
  spreadsheet would run as a formula (`=…`, `@…`) gets a leading apostrophe; numbers
  like `-10` are left alone.
- **Import CSV…** adds the rows of a CSV file (comma, semicolon or tab separated, the first
  row naming the columns) to the log, then sorts by date and time if you like. Columns
  named as ADIF fields are used as they are; common names are mapped too (Callsign,
  Date, UTC, Frequency, "Freq (kHz)", RST Sent, RST Rcvd, Grid, Park, Summit, Notes,
  Power…). Dates must be year first (2026-10-06, 2026/10/06 or 20261006), since 06/10 could
  be either month; times may be 22:30, 2230 or 22:30:15; a frequency in kHz becomes MHz;
  the apostrophe Export CSV puts before a formula is taken off. The window lists every
  row and the column mapping before anything is added (one undo step).
- **Export Cabrillo…** writes the log as a Cabrillo 3.0 contest log
  ([WWROF spec](https://wwrof.org/cabrillo/)): the header from the contest, callsign,
  category, grid and location you enter, and a QSO line per record with the frequency in
  kHz (or the band for 50 MHz and up), mode CW/PH/FM/RY/DG, date, time, and the reports
  and exchange from STX_STRING/STX and SRX_STRING/SRX. A line missing an exchange shows `-`
  and the window says how many do. Check the contest's own template before submitting.
- **Upload to QRZ.com Logbook… / LoTW (TQSL)… / Club Log… / eQSL…** list the QSOs not yet
  sent (by the ADIF status field), with the ones that can't be sent (no MODE…) shown in
  red. Nothing is sent until you press **Upload**. Each QSO's result is shown, and the
  ones accepted get the status field Y and today's date, as one undo step:
  QRZCOM_QSO_UPLOAD_STATUS/DATE, LOTW_QSL_SENT/LOTW_QSLSDATE,
  CLUBLOG_QSO_UPLOAD_STATUS/DATE, EQSL_QSL_SENT/EQSL_QSLSDATE. Per ADIF, a QRZ or Club Log
  status of N means "do not upload" and is skipped, M (modified) is sent again (to QRZ
  with OPTION=REPLACE), and a QSL status of I is skipped. **Copy ADIF** copies exactly what
  would be sent. QSOs you untick stay unticked while you edit the log.
  - When you change a QSO that was already uploaded, its QRZCOM_QSO_UPLOAD_STATUS and
    CLUBLOG_QSO_UPLOAD_STATUS of Y become M, as ADIF prescribes, so the next upload sends
    the change. Bulk Edit, Time Shift, Enrich and Remove Duplicates do this in the same
    undo step; typing, autocomplete and the Record Panel do it once the log reads cleanly
    again (lengths right), as its own undo step. Changes to QSL and upload fields
    themselves don't count. Sending an already-uploaded QSO to QRZ again uses REPLACE.
  - **QRZ.com Logbook**: one INSERT per QSO with the logbook's API key
    ([QRZ Logbook API](https://www.qrz.com/docs/logbook/QRZLogbookAPI.html)). A QSO the
    logbook already has counts as sent. A key error stops the run.
  - **LoTW**: runs TQSL (`/Applications/TrustedQSL/tqsl.app`, or choose it) as
    `tqsl -x -d -u -a compliant -l "<Station Location>" file`, which signs with that
    Station Location's certificate and uploads. If your certificate has a password, save
    it under Settings → TQSL certificate and it is passed with TQSL's `-p`. Only exit code
    0 marks records: for 8 or 9 TQSL doesn't say which QSOs it skipped, so nothing is
    marked and its report is shown. TQSL is stopped if it hasn't finished in 10 minutes.
  - **Club Log**: one batch upload to `putlogs.php` with your account email, an
    Application Password and an API key (Club Log gives each program its own; request
    one at clublog.org/requestapikey.php). Club Log firewalls programs that repeat failed
    requests, so the first error stops and is shown.
  - **eQSL**: one QSO per request to ImportADIF, with an optional QTH Nickname for users
    with several accounts ([eQSL interface](https://www.eqsl.cc/qslcard/ImportADIF.txt)).
    A QSO eQSL already has counts as sent; a sign-in error stops the run.
- **Enrich from …** (one menu item per source: QRZ.com, HamQTH, LoTW Confirmations,
  QRZ.com Logbook Confirmations, eQSL Confirmations, Country Data) add fields a record
  lacks: NAME, QTH, STATE, CNTY, GRIDSQUARE, DXCC and COUNTRY, CQZ, ITUZ, IOTA, CONT and,
  optionally, LAT/LON, and the confirmations. Every proposed change is listed for review,
  and nothing changes until you press **Apply**. Applied changes are one undo step.
  - **QRZ.com XML**: worldwide. Grid, county and zones need a QRZ XML Logbook Data
    subscription; without one, QRZ returns only a few fields, and the window says so.
    Coordinates that QRZ only estimated from the entity or state are not used.
  - **HamQTH**: free account, worldwide; its data is credited in the window.
  - **LoTW confirmations**: downloads your confirmed QSOs for the log's date range and
    matches them the way LoTW does: same call and band, the same mode or mode group,
    start times within 30 minutes. It adds the other station's grid, state, county and
    zones as they certified them for that QSO, and sets LOTW_QSL_RCVD=Y and
    LOTW_QSLRDATE. An existing N becomes Y.
  - **QRZ.com Logbook confirmations**: downloads the QSOs your logbook shows as confirmed
    (FETCH with your logbook API key, 250 at a time), matched the same way, and sets
    APP_QRZLOG_STATUS=C, APP_QRZLOG_QSLDATE, QRZCOM_QSO_DOWNLOAD_STATUS=Y and its date.
  - **eQSL confirmations**: downloads your eQSL InBox (DownloadInBox, your eQSL login) and
    sets EQSL_QSL_RCVD=Y and EQSL_QSLRDATE for each QSO it matches, plus the grid the other
    station sent.
  - **Country data**: offline, from the call's prefix (AD1C's country file, see Settings):
    DXCC, COUNTRY, CQZ, ITUZ and CONT. Portable calls use the prefix part (`VE3/K1ABC` is
    Canada; `/P`, `/M`, `/QRP` and a call-area digit are ignored), and `/MM` and `/AM`
    (maritime and aeronautical mobile) get no entity.
  - Club Log has no documented way for programs to download confirmations, so it isn't a
    source.
  - COUNTRY comes from ADIF's own DXCC entity table ("UNITED STATES OF AMERICA"), so it
    matches LoTW and ADIF.
  - Only fields a record lacks are filled; existing values are never replaced. The one
    exception is LOTW_QSL_RCVD, where N, R, Q or I becomes Y when LoTW confirms the QSO.
  - Callbooks give a station's *home* data. For portable calls (`K1ABC/P`, `VE3/K1ABC`)
    and records with SIG_INFO, POTA_REF, SOTA_REF or WWFF_REF, where the station was
    elsewhere, only the name is added. LoTW data describes each QSO, so it is always used.
  - Accented names are transliterated to ASCII ("Jürg" → "Jurg"), since ADI is ASCII.
- **Settings…** sets up the radio (rigctld or flrig, host and port, with **Test**, which
  reports what New QSO would log), shows the country data in use with **Update** (which
  downloads the newest Big CTY release from country-files.com into the plugin config
  folder), and holds the accounts for the online services, one section each: QRZ.com,
  HamQTH and LoTW for Enrich; QRZ.com Logbook (API key), Club Log (email and Application
  Password, plus the API key) and eQSL for uploads and confirmations; and the TQSL
  certificate password. Enter a username and password, then **Save**. **Test Sign-In** tries them against the service
  (for QRZ.com it also shows the XML subscription end date), and **Remove** deletes them.
  - Credentials are saved only in your macOS Keychain (items named "ADIF Lint: QRZ.com",
    "ADIF Lint: HamQTH", "ADIF Lint: LoTW"), never in `ADIFLint.ini`. A saved password is
    never shown again, and the field is cleared once saved.
  - All three services sign in with a username and password. QRZ's callsign lookups (its
    XML interface) don't take an API key; the API key on QRZ's logbook settings page is
    for its separate Logbook API. Settings can also hold an API key for a source that
    needs one, though none of these three does.
  - All requests use HTTPS. The QRZ.com sign-in is sent as a POST, so the password isn't
    in a URL. LoTW's report API and eQSL's DownloadInBox take the login as query
    parameters of their HTTPS URL; that is how they document it.
- **Marks problems while you type** in `.adi`/`.adif` files: red squiggles for errors,
  orange for warnings, blue dots for notes. **Hover** a mark to read why.
- **Colours the syntax**:
  - field names in blue;
  - `<`, `:LENGTH` and `>` in grey;
  - `<EOH>` and `<EOR>` in purple;
  - comments (header text, notes between records) in green.

  Data keeps the theme's text colour.
- **Fix Lengths** rewrites every wrong `<FIELD:LENGTH>` to match its data, as one undo step.
- **Reformat** puts one record, or one field, on each line. Only the whitespace between
  fields changes: every data specifier and comment is copied byte for byte, and the
  file keeps its header. It refuses while any length is wrong.
- **Autocomplete**:
  - type `<` for a list of field names: QSO fields in records, header fields in the
    header, plus the file's own `USERDEFn` and `APP_` fields;
  - enumerated fields (BAND, MODE, SUBMODE for the record's MODE, STATE for its DXCC,
    QSL statuses, Y/N…) then offer their values, and picking one writes the value and
    its length;
  - for free-text fields, type the data, and the length is filled in when you press
    Enter, type the next `<`, or move the caret away.
- **Record Panel**: a docked table of the header or record at the caret, with each
  field's problem.
  - Edit a value in place (enumerated fields are drop-downs); the length is set for you.
  - **+** adds a field and **−** removes one.
  - ▲ and ▼ step between records; double-click a row to select that field's data in
    the editor.
- **Next Problem / Previous Problem** jump between marks and show the message.
- **Validate Now** checks any document, whatever its extension, and shows a summary.

Menu: **Plugins → ADIF Lint**.

| Command | Does |
|---|---|
| New QSO... | Open the window for logging new contacts |
| Spots (POTA, WWFF)... | Activators spotted now; pick one to fill New QSO |
| Log Table... | Sortable, filterable, editable table of the log |
| Activation Tracker (POTA, WWFF, SOTA)... | Activations counted as each program does |
| Worked Before... | Search a folder of logs for a call |
| Log Summary... | Counts by band, mode, day, entity, park; confirmations and uploads |
| Bulk Edit... / Time Shift... | Change a field, or convert times between UTC and a time zone (or by a fixed amount), with a preview (one undo step) |
| Sort Records by Date and Time | Reorder records (one undo step) |
| Remove Duplicates... | Find and remove QSOs logged twice, with a review |
| Merge Another Log... | Add another log's new QSOs |
| Import CSV... | Add a CSV file's rows to the log |
| Export CSV... / Export Activation Logs... / Export Cabrillo... | Save the log as CSV, as POTA, WWFF or SOTA upload files, or as a Cabrillo contest log |
| Upload to QRZ.com Logbook... / LoTW (TQSL)... / Club Log... / eQSL... | List what would be sent, upload on your OK, mark it uploaded |
| Enrich from QRZ.com... / HamQTH... / LoTW, QRZ.com Logbook or eQSL Confirmations... / Country Data... | Find missing station data or confirmations from that source and review them before applying |
| Validate Now | Check the current document; summary in a call tip |
| Fix Lengths | Correct all data lengths (one undo step) |
| Next Problem / Previous Problem | Move to the next/previous mark |
| Reformat: One Record per Line / One Field per Line | Re-lay the file without touching data (one undo step) |
| Record Panel | Show or hide the docked record table |
| Validate .adi Files While Typing | Toggle the problem marks as you type (on by default) |
| Colour ADIF Syntax | Toggle colouring (on by default) |
| Autocomplete Field Names and Values | Toggle the `<` lists and automatic lengths (on by default) |
| Count Lengths in Characters | Count lengths in UTF-8 characters instead of bytes (see below) |
| Settings... | Radio connection, country data, and accounts for the online services (kept in your Keychain) |

All settings are saved in `ADIFLint.ini` in Nextpad++'s plugin config folder.

### What is checked

Every rule comes from the ADIF 3.1.7 specification (2026-03-22). Every field, data type,
enumeration value, band edge and import-only flag is generated from ADIF's official JSON
export, not typed by hand.

- **Structure** (§IV.A): data specifier syntax, data lengths (too short, too long, past the
  end of file, includes the line break), leading zeros in lengths (import-only), header and
  `<EOH>` rules, `<EOR>` on every record, a field repeated in one header or record, a stray
  `<`, and a field missing its `<`.
- **Fields**: unknown names, header fields in records and the reverse, import-only fields,
  `_INTL` fields (which ADI cannot carry), and type indicators that don't match the field.
- **Data types** (§II.B): Date, Time, Number (no `+`, no `,`), Integer, PositiveInteger,
  Boolean, String and MultilineString characters (ASCII only, CR LF line breaks),
  GridSquare, GridSquareExt, GridSquareList, Location, IOTA, POTA, SOTA, WWFF, CreditList,
  SponsoredAwardList, and min/max values (CQZ, ITUZ, AGE, K_INDEX…).
- **Enumerations**: BAND, MODE, QSL statuses, DXCC, ARRL section, continent, propagation
  mode, and the rest, plus deprecated values with the spec's advice (e.g. `MODE C4FM` →
  `DIGITALVOICE` + `SUBMODE C4FM`).
- **Between fields**: SUBMODE must belong to MODE; FREQ must lie in BAND, and FREQ_RX in
  BAND_RX (inclusive band edges); STATE and CNTY must belong to the DXCC entity where ADIF
  lists that entity's subdivisions.
- **User fields**: `USERDEFn` definitions in the header, with their enumerations
  `{S,M,L}` or ranges `{5:20}`, and `APP_PROGRAMID_FIELDNAME` fields, whose type the first
  occurrence fixes.
- **Notes**: records lacking ADIF's guideline minimum (QSO_DATE, TIME_ON, CALL, BAND or
  FREQ, MODE), CONTEST_ID and SUBMODE values not in ADIF's lists.

### Bytes or characters?

ADI files are ASCII only (§II.B), where a length counts bytes and characters equally. Some
programs write UTF-8 anyway (`Jürg` is 4 characters but 5 bytes), and they disagree on
which to count. ADIF Lint warns about non-ASCII text. When a length is wrong, it also says
whether the length would be right in the other unit. Turn on **Count Lengths in
Characters** for files whose program counted characters. Fix Lengths uses whichever unit
is selected.

## Install

### From a release

Download `ADIFLintvX.Y.Z.zip` from the [releases](https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/releases),
unzip it, and move the `ADIFLint` folder into
`~/Library/Application Support/Nextpad++/plugins/`, then restart Nextpad++. The dylib is
universal (Apple silicon and Intel) and ad-hoc signed, not notarized. If Nextpad++ won't
load it after a browser download, clear the download's quarantine flag:

```bash
xattr -dr com.apple.quarantine ~/Library/Application\ Support/Nextpad++/plugins/ADIFLint
```

### From source

Requirements: macOS 11+, Nextpad++ 1.1.2 or later, Xcode command-line tools and CMake.

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
```

```bash
cmake --build build -j
```

```bash
cmake --install build
```

The install step copies `ADIFLint.dylib` to
`~/Library/Application Support/Nextpad++/plugins/ADIFLint/` and ad-hoc signs it, with the
country file (`cty.csv` and its copyright notice) beside it. It writes
a new file and renames it over the old one, so installing is safe while Nextpad++ is running.
**Restart Nextpad++** to load the new version. To try it out, open `examples/try-me.adi`, which contains
deliberate mistakes.

To uninstall, quit Nextpad++ and delete that `ADIFLint` folder.

`tools/make-release.sh` builds the release zip in `dist/` (the `ADIFLint` folder only,
without macOS metadata), checks both architectures and the version, and prints the zip's
and the dylib's SHA-256 with the entry for Nextpad++'s plugin list
([nppPluginList](https://github.com/nextpad-plus-plus/nppPluginList), `pl.macos-arm64.json`).

## Command line

The same checks are available without the editor:

```bash
build/adiflint examples/try-me.adi
```

Output is `file:line:column: severity: message`. The exit status is 1 when there are
errors.
- `--fix OUT` writes a copy with corrected lengths.
- `--reformat records|fields OUT` writes a copy laid out one record or one field per line.
- `--chars` counts characters instead of bytes.
- `--quiet` shows errors only.

The log tools work on one file and write a new one; the file itself is never changed:

- `--sort OUT`, `--dedupe OUT`: sorted by date and time; repeated QSOs removed.
- `--csv OUT`, `--from-csv OUT`: CSV out; or the input is a CSV file, written as ADIF.
- `--summary`: the Log Summary report.
- `--cabrillo OUT --contest ID --call CALL`: a Cabrillo 3.0 log.
- `--export pota|wwff|sota DIR [--call CALL]`: the activation upload files, into DIR.

```bash
build/adiflint --export pota ~/Desktop/upload "KW9D@US-7929.adi"
```

## Tests

```bash
cd build && ctest --output-on-failure
```

- `adif_tests`: one case per rule, with the expected result taken from the spec text, plus
  the document model, reformatting, field edits and value lists, and the log tools,
  uploads, grids, country data (the installed `data/cty.csv`), WWFF and SOTA, CSV and
  Cabrillo.
  - The official ADIF 3.1.7 test file (6,197 records) must give no errors or warnings.
  - Lengths broken at random in it must be repaired to the original bytes.
  - Reformatting it either way must keep every field byte for byte, keep its header, and
    give the same result if done twice.
- `fuzz_smoke`: mutated files must give in-bounds results, ordered model offsets and safe
  edits; mutated network replies, CSV and country files must not crash. 2 MB hostile
  inputs must stay fast.
- `adiflint_tools`: the command-line log tools on the official test file; each output
  must lint clean, and CSV must come back with every record.
- `host_harness`: loads the built `.dylib` through the five plugin exports and drives it
  against a simulated Nextpad++ and Scintilla:
  - menu, validation, colouring, hover, Next Problem, Fix Lengths (one undo step);
  - both reformats, and the refusal when a length is wrong;
  - the autocomplete flow, including the host's word completion replacing the list, and
    the lengths set from value lists and free text;
  - the record panel, read and edited through its real table and callbacks;
  - the New QSO window, filled in and logged through its real controls: carry-over,
    BAND from FREQ, required fields, duplicates, and a new log in an empty document;
  - New QSO Fields: descriptions listed, search by description, remove (required fields
    refused), add, reorder, save, hidden station fields written, and back to the log's
    fields;
  - Enrich with each source, reading fixture responses instead of the network
    (`tests/fixtures/lookup`, based on QRZ's and HamQTH's documented samples): review,
    tick and untick, apply as one undo step, the portable-call rule, and changes skipped
    when a record was edited after Find Data;
  - Settings: save, test, remove, the "add an account" message, and the saved password
    never being shown. Tests keep credentials in memory, never in the Keychain;
  - the log tools on a POTA log: Log Table (filter, sort, click to the record), Summary,
    the Activation Tracker, Sort, Remove Duplicates, Bulk Edit and Time Shift (preview
    and apply as one undo step), CSV and POTA export (the second-press replace), Merge
    (duplicates skipped, sorted into place), and Worked Before across a folder, also in
    New QSO. File dialogs are replaced by `ADIFLINT_TEST_SAVE_DIR`, `ADIFLINT_TEST_FOLDER`
    and `ADIFLINT_TEST_OPEN_FILE`;
  - the radio over real loopback sockets: stand-in rigctld and flrig servers answer
    Settings' Test and New QSO's From Radio, including flrig with no radio and a closed
    port;
  - POTA and WWFF spots from fixtures (a malformed spot is dropped), the band filter, the
    Worked column, and a spot filling New QSO with SIG and SIG_INFO rows added;
  - QRZ.com Logbook, eQSL and country-data confirmations, the New QSO lookup line and
    fields, Log Table editing (M marking), column choice and the remembered sort, Fill
    DISTANCE, Cabrillo, Import CSV, the WWFF and SOTA tracker and export, and Update
    Country Data;
  - uploads: nothing sent before Upload, one QRZ INSERT per QSO without status fields, a
    duplicate counted as sent, eQSL with the QTH nickname, one Club Log batch, TQSL run
    with the documented arguments and the certificate password (a stand-in script), exit 9
    marking nothing, the time limit, and the status fields written afterwards;
  - layout: no two controls overlap in any window. To look
    at them, run the harness with `ADIFLINT_SNAPSHOT_DIR=<folder>`: it saves a dark-mode
    PNG of each window;
  - saved settings.

A build with AddressSanitizer and UBSan:

```bash
cmake -B build-asan -DADIF_SANITIZE=ON -DCMAKE_BUILD_TYPE=Debug
```

```bash
cmake --build build-asan -j && (cd build-asan && ctest --output-on-failure)
```

## Layout

| Path | Contents |
|---|---|
| `src/core/` | Validator, length fixer, document model, reformatter, field edits, value lists, and the enrichment rules (pure C++17, no editor code) |
| `src/core/adif_tools.cpp` | Log tools: records, table columns, summary, bulk edit, time shift, sort, duplicates, merge, CSV, POTA activations and export, spots, worked before |
| `src/core/adif_radio.cpp` | rigctld and flrig requests and replies, rig mode → ADIF |
| `src/core/adif_upload.cpp` | Upload candidates, QRZ/eQSL/Club Log bodies and replies, TQSL exit codes, status marking, confirmation downloads |
| `src/core/adif_programs.cpp` | WWFF and SOTA activations and export files, reference history |
| `src/core/adif_country.cpp` | AD1C country file: prefix → DXCC, zones, continent |
| `src/core/adif_geo.cpp` | Grid squares → distance and bearing |
| `src/core/adif_formats.cpp` | CSV import and Cabrillo export |
| `src/core/adif_spec_317.cpp` | Generated ADIF tables (do not edit) |
| `src/plugin/ADIFLint.mm` | Nextpad++ glue: menu, indicators, colouring, hover, fixes, autocomplete |
| `src/plugin/RecordPanel.mm` | The record panel's AppKit view (knows nothing about Scintilla) |
| `src/plugin/NewQsoPanel.mm` | The New QSO window's AppKit view |
| `src/plugin/QsoFieldsPanel.mm` | The New QSO Fields window (choose and order the fields) |
| `src/plugin/EnrichPanel.mm` | The Enrich Log window's AppKit view |
| `src/plugin/Lookup.mm` | QRZ.com and HamQTH clients, the LoTW report download, Keychain storage, sign-in tests |
| `src/plugin/SettingsPanel.mm` | The Settings window (radio, accounts and API keys) |
| `src/plugin/ToolWindow.mm` | The general window the log tools are built from |
| `src/plugin/LogTools.mm` | Log Table, Summary, Tracker, Worked Before, Bulk Edit, Sort, Duplicates, Merge, exports, POTA Spots |
| `src/plugin/Radio.mm` | TCP client for rigctld and flrig (read-only queries) |
| `src/plugin/Uploads.mm` | The four upload windows and the TQSL runner |
| `src/plugin/Country.mm` | Loads the country file (downloaded, else the one installed with the plugin) and updates it |
| `src/plugin/PluginHost.h` | What ADIFLint.mm offers the other plugin files |
| `src/cli/` | `adiflint` command-line tool |
| `tools/gen_spec_tables.py` | Generates the tables from `spec/adif-3.1.7/all.json` and the field descriptions from `ADIF_317.htm` |
| `data/` | AD1C's Big CTY `cty.csv` (2026-09-15), installed beside the plugin; see `data/SOURCE.md` |
| `tests/` | Tests, harness, and the official ADIF test file |
| `third_party/` | Nextpad++ plugin header and Scintilla headers (see `third_party/README.md`) |

**A new ADIF version:** replace `spec/adif-3.1.7/all.json` with the new export from
`https://adif.org.uk/<version>/resources`, run `cmake --build build --target regen-spec`,
and rebuild. Then run the tests against the new official test file.

## Limits

- Nextpad++ 1.1.2 ignores plugin default shortcuts and doesn't let plugins write to the
  status bar, so summaries appear in a call tip at the caret. You can assign your own
  shortcuts in Nextpad++'s Shortcut Mapper. It stores them in `shortcuts.xml` under
  `<PluginCommands>`, keyed by `moduleName="ADIF Lint"` and the command's position.
- Plugins can't supply a lexer, so colours are text-colour indicators, painted for the
  lines on screen as you scroll. While you type, colours catch up when you pause.
- With Nextpad++'s own word completion on, its list can flash briefly before ADIF Lint's
  list takes its place again. The autocomplete value lists are alphabetical (bands too),
  because Scintilla's list order is a shared setting the host relies on. The panel's
  drop-downs keep the natural order.
- CNTY is checked only for entities whose subdivisions ADIF lists (US counties are not
  listed). DARC_DOK and COUNTRY are not checked against a list, and SOTA references
  get a loose check because the spec's definition is loose.
- Trailing spaces inside data are legal, so a length that includes one is not flagged.
- Only the active document is checked; the host gives plugins no access to other tabs.
- Enrich and the uploads have been tested against fixture responses and stand-ins
  (servers on loopback, a script in place of TQSL), not the live services, and the radio
  against stand-in rigctld and flrig servers. The first real run against each is the
  true test. The POTA spot format was checked against the live feed on 2026-10-07.
- TQSL must have the Station Location set up. A certificate password saved in Settings
  is passed on TQSL's command line (`-p`, the only way TQSL takes it in batch mode), where
  other programs running on your Mac could see it while TQSL runs.
- No SOTA spots: the SOTA API's terms of service don't allow software written with AI
  tools without the SOTA team's approval. SOTA tracking and export work offline. The SOTA
  rule is taken from SOTA's published guides, since the official pages could not be read.
- Confirmations are matched like LoTW (same call and band, mode or mode group, within
  30 minutes). QRZ.com doesn't document how FETCH encodes its ADIF; it is decoded as HTML
  entities, as Wavelog does.
- The country file installed with ADIF Lint is the 2026-09-15 release; press Update in
  Settings for the newest. Prefix rules give the usual entity: special exceptions
  (Guantanamo, some islands) are only right when the file lists the exact call.
- POTA's file name rule is the one its docs give for emailed logs; the pota.app uploader
  also reads the park from the file name.
- ADX (XML) files are not handled.

## License

GPL-3.0, matching Nextpad++ (whose plugin header is included) and its plugin registry.
The Scintilla headers are under the Scintilla license (`third_party/scintilla/License.txt`).
The ADIF specification exports are published by the ADIF Development Group for developers.
`data/cty.csv` is Jim Reisert AD1C's Big CTY country file, under the MIT licence
(`data/cty-copyright.txt`).
