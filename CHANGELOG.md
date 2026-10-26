# Changelog

All notable changes to ADIF Lint are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is 0.x, a
minor version may change behaviour.

Versions before 0.8.0 were development builds and were not published.

## [Unreleased]

### Added

- **Upload to World Radio League** (Upload…, QSL Sync): the ticked QSOs as one ADIF import
  into your default WRL logbook, by WRL's API (start, send the file, follow it until it's
  done), with an API key in Settings whose Test Sign-In shows your membership, daily import
  allowance and default logbook. ADIF has no WRL fields, so uploaded QSOs get
  APP_ADIFLINT_WRL_QSO_UPLOAD_STATUS Y and its date; they are marked only when WRL has every
  one. API read 2026-10-25.

## [1.6.0] - 2026-10-25

### Added

- **Contests by their rules** (New QSO → Contest…): CQ WW (SSB, CW, RTTY), CQ WPX (SSB, CW,
  RTTY), ARRL International DX (CW, SSB), IARU HF, ARRL Sweepstakes (CW, SSB), NAQP (CW, SSB,
  RTTY), NA Sprint (CW, SSB, RTTY), ARRL 10 m and 160 m, and a state QSO party. Your exchange
  and theirs written to their ADIF fields and to STX_STRING/SRX_STRING; serial numbers where a
  contest sends them; duplicates by each contest's rule; warnings for bands and modes it doesn't
  count; Cabrillo lines with the exchange in order. Rules read from the organisers on
  2026-10-25.
- **Log Summary → Charts:** QSOs by band, mode and continent, per day (or week, or 30 days),
  by UTC hour and weekday, and the DXCC entities, US states and grid squares reached over
  time; each mark's number in its tooltip; Copy and Export PNG. One series a chart, in one
  blue checked against the window in light and dark mode.
- **TQSL certificate per station profile:** a **TQSL Certificate** column in Station
  Profiles and a **Certificate** box in Upload to LoTW, offering the callsigns of TQSL's
  certificates. When set, TQSL signs with `-c <call>` (that call's certificate, the Station
  Location's DXCC entity), and the pre-flight checks each QSO's call against it.

### Changed

- **Upload to LoTW:** TQSL's exit codes 12 to 15 are explained (unknown error, busy, already
  uploaded, wrong certificate password), and code 4 says it may mean no valid certificate.
- **New QSO:** the lookup's line becomes the station's facts, a row each: Operator (name and
  QTH), Country (entity, continent, zones, DXCC), Grid, Distance with the short-path and
  long-path bearings (km or miles, as the Map), the station's Local time (the country file's
  standard time for the entity), QSL (LoTW), Worked before (this log and the logs folder,
  no longer in the summary line) and its references.
- **New QSO:** **Station** is the first row, with what the profile writes beside it ("KW9D ·
  EN52wa · 5 W · Elecraft T1").
- **Logging Layout** (ADIF Lint menu): New QSO on the right, the Map over the Log Table on the
  left, kept in front of the log; each QSO logged is chosen on the Map and in the Log Table.
- **Map:** the selected panel follows Apple's guidance as the cards in it do: a spot's reasons
  are set apart by a green tint rather than a border, headings are in sentence style, New QSO
  is a system push button tinted green, and the parts are spaced on a 4-point rhythm.
- **New QSO and Start Activation:** type part of a park's name or reference in POTA_REF,
  MY_POTA_REF or the activation's References, and the list offers the parks it could be,
  nearest your grid first; choosing one puts its reference in (after a comma, the next one).

## [1.5.0] - 2026-10-25

### Changed

- **Settings** live in the Map: a **Settings** card in the selected panel, in place of the
  ADIF Lint Settings window. **Settings…** in the menu, the Map's gear and every "add one in
  Settings" open the Map with it. Each section (Your Station, Editor, Language, Offline Mode,
  the downloads, Spots and each account) is a card of its own, closed until opened, its
  heading saying what is set in it ("KW9D · EN52", "3 of 4 on", **Saved** or **not set**).
- **Style Options** is a card in the selected panel too, in place of its window: its groups
  (Colours, Markers, Worked areas, Lines to contacts, Spots, POTA parks, Sun, On the map) are
  cards in it, closed at first, each heading summing up what is chosen in it.
- **Map:** the sidebar and the selected panel are in cards (Quick Views, Spots, Layers, Map,
  Filters; Selected, Situation, Style Options, Settings), each opening and closing from its
  heading, with groups inside (the layers' Worked areas, Programs, Places, Contacts, Sun and
  propagation; Awards, Band conditions, Recent spots, Details). After Apple's Human Interface
  Guidelines: the chevron at the leading edge, right when closed and down when open; the whole
  heading is the target, Space or the arrow keys from the keyboard, and VoiceOver hears a
  disclosure triangle. Closing one hides only its controls: what is set in it stays.
- **Map:** **Terrain** is a layer (Layers → Base map, subtle or strong), no longer in Style
  Options.
- **Map:** the selected panel gives the operator's **Name** for a spot or a QSO: the NAME of
  your latest QSO with the call, else the callbook New QSO looks calls up in (QRZ.com or
  HamQTH, when chosen there), asked once per call.
- **New QSO:** spotting is two boxes under **Spot when logging**, in place of the Spot This
  QSO panel after each QSO: **The station, on the DX cluster** and **Myself, on pota.app**.
  Each stays as you leave it (off at first), and Log QSO spots what is ticked, with the same
  rules as before; the line under them says what was done. A box is dimmed, its tooltip saying
  why, when it can't spot. Settings → Spots' "offer to spot" box is gone.
- **Map:** the live dot turns orange when any spot source you turned on fails, not only when the
  spots grow old, and the toolbar names it ("DX cluster not answering") or says Offline Mode is
  on.
- **Map:** the toolbar says how many the filters keep ("40 of 257 QSOs on the map", "5 of 18
  stations on the map").
- **Map:** a spot without a grid or an exact place, drawn at its country's centre, says its
  distance is rough (**≈** in the list, "about …" in its description, and its Grid says where
  it is drawn).
- **Map → Band conditions** says it shows every band while the band filter is on.
- **Map:** the layers' Worked, All and Labels headings have tooltips, the toolbar's live time
  explains itself beside QSL synced, and the footer's hint follows the workflow.

## [1.4.1] - 2026-10-24

### Changed

- The user guide, README, CONTRIBUTING and every screenshot are brought up to date with 1.4.0's
  Map (and the README's install section with the plugin store).

### Fixed

- **Map Detail:** for a region larger than a town (a state or a country), the Map drew only
  that region's zoom-10 tiles however far you zoomed in, so streets, their names and
  buildings never showed, only main roads. It now draws the tiles for the view. (Since 1.3.0;
  the box of the view it measured had margins of whole degrees, which at street level took in
  hundreds of tiles.)

## [1.4.0] - 2026-10-24

### Added

- **Map → POTA: park outlines** (Settings → POTA Parks → Park Outlines). For one POTA location
  at a time, downloaded on request and kept in the plugin config folder: OpenStreetMap's
  areas tagged with the park's reference (through Overpass), pota-map.info's for Austria,
  Czechia, Denmark, Germany, Luxembourg and Switzerland, and for US parks USGS's PAD-US 4.1,
  matched by name, by POTA's place for the park and by designation (70% of Illinois's parks
  and 80% of Missouri's in tests). Parks you worked are filled in their badges' colours, the
  others outlined; matched outlines are dashed and name the PAD-US unit; pointing anywhere
  in a park finds it; the sources are credited on the map. **Downloaded** lists each
  location (parks with an outline, its size and date) with **Remove**, a line sums them all
  up, and the location chosen says what you have of it and from which sources.
- **Map → POTA: park badges**, as on POTA's own map: a round badge with a tree at each park
  (for the parks you worked, filled in the map's colours (band, mode, confirmation…) with a
  white tree and rim; a star for those you activated; pale with the tree in the park colour
  for the others, smaller where many show), the reference in a box under it, placed clear
  of other badges and labels. They replace the pins and rings. **Style Options → POTA parks →
  Parks with an outline: Outline only** shows a park whose outline is big enough to see as
  just the outline and its label.
- **Map → POTA parks in**: the parks you haven't worked show only in the POTA locations you
  choose (US states, Canadian provinces, other countries' regions) and, in a US state, the
  counties you choose; at first, your station's location, for a map of your own state
  without the clutter of the rest. **Everywhere** shows them all.
- **Map: History and Live, in a new layout.** Two ways of working, each keeping its own
  layers, colours, list and Quick View: **History** reads the log (what you worked on each
  layer, for looking back and planning), **Live** shows the stations spotted now and which
  your log needs. A header (your call, the log, Style Options, Export, buttons for the
  panes); a toolbar (History or Live, what the map shows — the QSOs and their dates, or the
  stations spotted — the band, mode, date, confirmation and continent filters, More
  Filters, the filters it can't show as tags that remove themselves, and Clear); a sidebar
  in closable sections (**Quick Views** with counts; Live's **Spots**; **Layers** under
  Worked, All and Labels, with **Contacts** and **Sun**; **Map**; **Filters**); the map,
  with its zoom buttons (+, −, Home, Fit Log or, in Live, the spots, World) at its top left
  and a distance scale and the legend at its bottom left; the list under it; the
  **selected panel** on the right; and a footer (how fresh the spots are, as a coloured dot
  that shows each feed's state, and what is under the pointer). The header also has Log
  Table, Settings and Help. Dividers can be dragged, panes hidden, and all is remembered.
- **Map → Quick Views.** History's: the whole log and each layer with how many you worked
  (and confirmed); choosing one shows that layer's worked areas among all of it; **Needs
  confirmation** keeps the QSOs not confirmed by card, LoTW or eQSL. Live's: **All spots**,
  **Needed on its band** (a new DXCC or a new band), **New DXCC**, **New band**, **New
  mode**, **New POTA parks**, **POTA activators**, **My watch list** and **Worked before**,
  each with its count; choosing one shows only those.
- **Map → keyboard and accessibility**: ⌘] and ⌘[ (or ] and [ on the map) step through the
  list's rows, choosing each on the map; ⌘↩ New QSO, ⌘L Center, ⌘D Watch, ⌘F Find; Return on
  the map acts on what is chosen. Style Options' **Map text** makes the map's text larger, and
  **Hatch what isn't confirmed** shows confirmation without colour; spots' rings differ by
  shape too (two for a new DXCC, dashed for a new band or mode). Faint text follows macOS's
  Increase contrast. The legend's clickable entries are VoiceOver actions. A layer's name has
  a right-click menu (its boxes, Only This Layer, the shading).
- **Map → header and toolbar**: the header says **Operating Map** and when confirmations were
  last downloaded (a click opens QSL Sync). Live's toolbar adds a **DXCC** menu (the spots by
  what they mean for your DXCC) and a **Spots** menu (any program, POTA only, new POTA parks,
  plain DX only). **Clear** counts the filters that are on and lists them in its tooltip.
- **Map → toolbar**: in Live, when a feed last brought spots ("updated 14:32 UTC"), and menus
  for how new the spots are and from which source; the band and mode menus say **Band:** and
  **Mode:** while they filter. When a click on the map switches the list to Selected, **← Back
  to** returns to what it listed.
- **Map → your own Quick Views**: **Save View…** keeps the layers, colours and filters (and in
  Live which spots show) as a Quick View in that workflow; right-click one to remove it.
- **Map → selected panel**: a reason that can show more has an arrow (a band or mode: the
  entity in the list's DXCC; a new DXCC or park: its Quick View; heard near you: Band
  conditions; your QSOs: the list). **Details** gives who heard the spot, your QSOs with the
  call, its references and its entity. In POTA, Best opportunity puts new parks first.
- **Map → DX Chase and POTA**, beside History and Live: Live with its own settings for chasing
  what you need (Needed on its band, plain DX spots, the grey line) or for hunting parks (POTA
  activators, every park).
- **Map → Find**, in the header: a call (your QSOs with it, or its spot), a grid square, a DXCC
  entity or a POTA park, chosen on the map; a menu when several match.
- **Map → List: Issues and DXCC.** **Issues** lists Check Log's errors and warnings in the QSOs
  shown (double-click goes to the problem); **DXCC** is DXCC Progress, each entity worked with
  ● confirmed or ○ worked on each band from 160m to 6m and in CW, phone and data.
- **Map → Band conditions** (Live, in the selected panel): from the spots, each band's stations
  spotted, those heard by spotters within 1,500 km of you and the best report they gave, and
  a line for the band in focus; a band's name sets the band filter.
- **Map → the map.** Spot labels are tags beside their markers, edged in each spot's colour;
  the chosen spot's always shows, edged in the accent colour, with a dashed path from your
  station to it and its distance and bearing (a chosen contact too). The legend is at the top
  right (Style Options: off, top right or bottom left), and a click on a spot's kind or band,
  the POTA activators, or another program hides or shows them. **Home**'s right-click menu
  sets the view as your Home view, or forgets it.
- **Map → Awards** (History, in the selected panel): DXCC, WAS, WAZ and VUCC (6m, 2m) toward
  their goals, counting the confirmations each sponsor accepts (rules read 2026-10-24); US
  counties, continents, IOTA groups and POTA parks hunted as counts. Each QSO now says which
  services confirmed it.
- **Map → More Filters** in groups: Where, How far, Programs, Which records.
- **Map → Filters.** The dates menu has **Custom Range…** (from one day to another, the
  range shown in the menu). The confirmation menu adds **Confirmed on LoTW**, **by eQSL**,
  **by card** and **Not confirmed on LoTW**. More Filters adds **Within** so many km or mi of
  your station (QSOs, spots, and the parks you haven't worked when they follow the filters)
  and **Records**: without a grid square, possible duplicates, or with problems Check Log
  finds. Each shows as a tag in the toolbar.
- **Map → Layers.** Each group (Worked areas, Programs, Places, Contacts, Sun and propagation) closes on its
  own with its triangle, remembered. **Other programs** is a row in Programs with a box for
  them all (off hides them, on brings back those you had shown); its name is the menu of
  which. A Labels box that can't work (its layer hidden) is faded, so it doesn't look merely
  unticked. The Map section has the palettes as swatches, one click each.
- **Map → watch list.** Calls, references (POTA parks, IOTA groups, any program's) and DXCC
  entities to watch for: **Watch** in the selected panel or a row's right-click menu, or
  **Watch List…** in Spots. A watched station spotted has a star on the map and in the list
  (a **★** column), comes first under Best opportunity, says **Watched** in Why it matters,
  and is counted by a **bell** in the header; the bell's menu lists them (each chooses its
  spot) and says when the feeds have gone quiet. In the Map only: no notifications.
- **Map → selected panel.** What you clicked, with its kind (**Live spot**, **QSO**, **DXCC
  entity**, **POTA park**…), a line under its name, its facts, and for a spot **Why it's
  interesting** (a new DXCC, band, mode or park, LoTW, how many heard it near you, your QSOs
  with the call), **New QSO** and **Center**; then its entity's bands and modes in your log.
  Under it, **Situation**: the log at a glance (worked and confirmed, a click shows the layer
  in History), today, the QSOs without a grid, the spots you most want now as links, the
  busiest bands and the sun at your station. Its facts have symbols, say **Unavailable** for what a spot
  doesn't give (signal, grid), and give the spotter and how long ago; a QSO chosen gets
  **View QSO**; **×** hides the panel. **Recent spots** lists the five newest, each a link.
- **Map → List: Selected, Contacts, Parks, Spots, Recent.** The QSO table under the map
  became the list's **Selected** (the QSOs of what you click); **Recent** has the log's QSOs,
  the newest first. Each tab says how many it has. Every list has pages (25 to 500 rows a
  page), sorts by any column, and chooses its columns (right-click a title, or Columns):
  country, state, county, zones, park and record for QSOs; location, how worked and outline
  for parks; country, grid, distance, band, spotter, age and **Why it matters** (the most
  wanted first) for spots, and time, program, reference, park, source, signal report and
  comment. A **Sort** menu has the orders that matter for each list; a row's
  right-click menu has New QSO, View QSO, Center and Zoom to It; **Why it matters** joins
  the reasons ("New on 40m + POTA + heard near you").
- **Map → Style Options → Reference layers** (strong, subtle, faint): the grid, the
  overlays' lines and names and the distance rings drawn more lightly, subtle at first, so
  the log's markers stand out. **Spotlight what's chosen** dims the rest of the map round
  what you click. What you click gets a ring in the accent colour. Style Options is now in
  two columns.
- **Map → List: Search and Within**: keep the rows with a call, reference, name... in them,
  and within a distance; the contact panel's subject in bold over its description.
- **Map → Spots: POTA activators** are POTA's badge (the tree in the band's colour, with the
  spot's ring round it) instead of the plain spot marker, on the map, in the legend, and as
  a tree in the list of spots.
- **Map → List**: beside the map (the **List** button shows or hides it), the 50 POTA parks,
  contacts or spots in view nearest your station, the map's centre or a grid square you
  type, with distance (mi or km) and bearing. Click one to choose it on the map,
  double-click to zoom right in to it; something clicked on the map chooses its row.

- **Map → Spots: spotters.** The stations that heard each spot (up to 12: a cluster's
  spotters, RBN skimmers, and you for PSKReporter) are faint triangles. Point at a spot for
  its spotters' lines, or at a spotter for the stations it heard; click one for the list.
  The legend explains both markers.
- **Map → Refresh** (the round arrow beside Spots…): the spot sources asked again now, as
  far as each allows: Spothole once a minute at most, PSKReporter once its 5 minutes have
  passed, a DX cluster waiting to reconnect at once.
- **Map → Style Options → Spots**: spotters hidden, faint grey, as markers, or with their
  calls; the spotters' lines in the band's colour, faint, or faint grey; what each spot's
  label shows under its call (mode, frequency, time since spotted, signal report); and
  fading older spots on or off.
- **Settings → Spots → PSKReporter → Around my grid square**: the last half hour's reports
  with either station in your 4-character square, so there are spots when you are off the
  air.
- **Night Mode** (the ADIF Lint menu): every ADIF Lint window and popover red on black, and
  the Map in its Night (red) palette, to keep night vision. Nextpad++'s own windows and the
  menus can't be reached by a plugin; the user guide shows macOS's Color Tint for the whole
  screen. The new menu item moves Settings… and About… down one place, so a shortcut
  assigned to either in Nextpad++'s Shortcut Mapper needs assigning again.
- **Map → information box**: a click on a spot or a spotter shows everything known about the
  station at the bottom right: frequency, band, mode, when and where from, program and
  reference, report, grid and position, country, continent and zones, distance and
  bearing, whether it's in the log, the comment, and every station that heard it (or, for a
  spotter, every station it heard), with reports and ages.
- **Settings → Spots → PSKReporter → Callsign**: the callsign to ask about (Your Station's
  when empty).
- **Map → Spots → Only spots of**: only one station's spots (yours when the callsign is
  empty), each with every station that heard it, as on PSKReporter's map; PSKReporter is
  asked about that callsign while it is ticked. The Spots section (Live) holds Sources and Filters…
  (formerly Spots…) and the refresh arrow too.
- **Spot This QSO**: after Log QSO in New QSO, an offer to spot the station you worked on
  the DX cluster (a `dx` command, comment editable, the node's answer shown) and, while
  activating for POTA, to open pota.app to spot yourself. Sent only on Send; never your own
  callsign on a cluster; not during a contest, offline, or for a station spotted on that
  band in the last 10 minutes; turned off in the panel or in Settings → Spots.
- A spot's description gives its signal report and how many spotters heard it. Spothole's
  RBN spots get their reports from their comments ("20 dB"), as Spothole has no field for
  them.

- **Map → Style Options → Terrain** (off, subtle or strong): the land's mountains and valleys
  shaded, from Natural Earth's 1:50m shaded relief (public domain, bundled as `relief.jpg`), in
  every palette and projection; it fades out as you zoom in past its detail.
- **Map: country flags** before each DXCC entity's name in the list's Country and DXCC entity
  columns and in the selected panel's title (Style Options → Country flags, on at first). The
  table of 337 entities was checked against k0swe/dxcc-json, Wavelog and QLog and against
  Unicode's flag list.
- **Map's toolbar: Save View…, Copy Map and Focus Map**, three buttons at its end: keep the view
  as a Quick View, copy the map to the clipboard as Export PNG would save it, and show the map
  alone (the sidebar, list and selected panel hidden; again to bring them back).

- **Map: space weather** from NOAA SWPC (public domain), at the right of the header once turned
  on in its popover: the solar flux and the K and A indices (orange or red during geomagnetic
  storms), and in the popover the X-ray flare class, NOAA's R, S and G scales and the last day's
  K. Every 15 minutes while the Map is open; never in Offline mode. Band conditions shows the
  indices too.
- **Map → Sun and propagation → Aurora**: NOAA SWPC's OVATION aurora forecast, shaded from green
  to red.
- **Map → Sun and propagation → NCDXF beacons**: the 18 NCDXF/IARU beacons, the ones sending now
  ringed in their band's colour (the band filter's band, when it is one of theirs); a click tells
  when one sends next on each band.
- **Map → Spots → Heat map**: the spots shown as a heat map.

### Changed

- **Map**: **Spots…** moved from the Filters row to the Spots group.
- **Map → Day and night**: the night side is darker (up to 65% black, from 50%).
- **PSKReporter** (Settings → Spots → Reports) asks for your callsign on either side, so the
  stations your station heard show too when your program uploads what it hears (WSJT-X:
  Enable PSK Reporter Spotting); before, only the stations that heard you. Your own signal
  is now the spot, with the stations that heard it as its spotters (up to 100); before,
  each of them was drawn as a spot with you as its spotter, which looked as if you had
  spotted them. PSKReporter uses Your Station's callsign (or its own setting), never the
  DX cluster's login. When there are none, the status line says where reports come from. Queries
  ask for at most 1,000 reports.
- **Spots**: showing the layer again, or saving Settings → Spots, no longer asks Spothole
  again before its 2 minutes are up; what each source said last stays shown.
- Spot ages, the Spots age filter and fading follow the clock each minute while the Map shows.

### Fixed

- **Map → Colour by** now colours the spots too; they were always in their band's colour.
- **Map:** a smaller window no longer squeezes the sidebar and the selected panel under their
  least widths (the layers' column titles and the Watch button were cut); the map and its list
  take the change, the list's bars give way, and the panel's buttons wrap.
- **Map:** the band filter lists the bands spotted too, not only the log's.
- **Map:** your station's grid, when it comes from the log's MY_GRIDSQUARE, is taken from the
  whole log, not only the QSOs the filters keep (with none kept, the map lost its home).
- **Map:** History's toolbar no longer shows Live's menus (spot age, sources, DXCC, program) when
  the Map first opens, nor Live's the dates and confirmation, until you switched workflows.
- **Map:** a click off everything (open sea, a square you haven't worked) chooses nothing, and so
  does **Escape** on the map; before, it chose the square, and only a click off the Earth cleared
  the selected panel.

## [1.3.0] - 2026-10-19

### Added

- **Map → Spots**: a layer of the stations spotted now, a dot in a ring in each one's band
  colour, fading as the spot ages; **Overlay** draws a line from each spotter, **Labels**
  the calls. **Spots…** in the Filters row chooses how new (10 minutes, 30 minutes or an
  hour), which sources and which program, and says what each source is doing; the Map's
  band, mode and place filters apply too. Click a spot for who spotted it, when, and whether
  it's in the log, and **Use in New QSO** to fill New QSO from it. Nothing is fetched until
  Show is ticked, and only while the Map is open.
- **Settings → Spots**: where the Map's spots come from. **Spothole** (on at first, every 2
  minutes; SOTA left out); **a DX cluster** over telnet, logged in with your callsign, with
  commands to send after logging in (such as `set/skimmer`), reconnecting with growing
  pauses and stopping if the node wants a password or refuses the login; **PSKReporter**,
  the stations that heard your callsign in the last hour, no more than every 5 minutes, with
  an optional contact email for PSKReporter.

- **Map → layers**: a grid of layers (grid squares, countries, US states, US counties, CQ
  zones, ITU zones, POTA, IOTA, cities), each with **Show**, **Overlay** and **Labels**.
  Show marks what you worked on that layer and ticks its Overlay and Labels too.
- **Map → Show** for **US states**, **US counties**, **CQ zones** and **ITU zones** shades the
  areas worked: by the QSO's STATE, CNTY, CQZ or ITUZ, else by where the QSO was (its LAT and
  LON or a 6-character grid inside the area, or for a state a 4-character square wholly
  inside it), else for zones by the country data. Click an area for its QSOs and where each
  one's area came from.
- **Map → Filters → More Filters…**: keep the QSOs in some continents, countries (DXCC), CQ
  and ITU zones, US states and counties, US regions (call areas W1 to W0, KL7 and KH6, Census
  regions and divisions, ARRL divisions, by ARRL_SECT for California, New York and New
  Jersey) or POTA locations; optionally limit the POTA parks you haven't worked to the same
  places.
- **Map → Style Options…**, a panel in place of the Options menu: colours, markers, worked
  areas (with how strongly countries, states, counties and zones are shaded), lines to
  contacts (with their strength), the legend, distance rings, and **Reset to Defaults**.
- **Map → Style Options → Night (red)**: the whole map, legend and labels in the screen's own
  reds on black, to keep night vision; PNG exports too.
- **Map Detail** (Settings): OpenStreetMap's streets with their names, buildings, land use,
  water, rail and place names for a US state, a country or the area shown on the Map, at
  three levels of detail. Check Size says what a region takes; Download cuts it from
  Protomaps' newest planet build by byte ranges (one build throughout) into the plugin's
  `maps` folder, and the Map draws it from there, offline, zooming in to 16,384× where it is,
  credited "© OpenStreetMap contributors".
- **Offline Mode** (the ADIF Lint menu, and Settings): no network requests at all (lookups,
  spots, uploads and TQSL, imports, downloads, web pages) until it is turned off; Monitor
  still listens to the programs on your Mac.
- **Map → Style Options → Day and night** and **Grey line**: the night side shaded, deeper
  to 18° below the horizon, the line between day and night, the sun overhead, and the
  twilight band to 6° down tinted gold; for now (each minute) or the selected QSO's time.
  The sun's place comes from NOAA's solar calculator equations.
- **Languages**: ADIF Lint's menu, windows and messages (the problems in a log too) in
  Korean, French, German, Spanish and Japanese, following the language Nextpad++ shows, or
  the one chosen in **Settings → Language**. The translations were drafted by Claude, an AI,
  and wait for review by native speakers; anything untranslated, and the user guide, stays
  in English. The menu and new messages change at once; windows already shown change when
  Nextpad++ starts again. The tables are `lang/*.json` beside the plugin.

### Changed

- **Map**: the **Only** row is now **Filters**, with **More Filters…** and **Clear**.
- **Map**: lines to contacts take the colour of the marker at their end (the contact's pin,
  else its square, else its entity's dot).
- **Map → POTA**: the parks you haven't worked show as rings, or as small dots where more
  than 1,500 would show, with no more numbered counts. **Show** pins the parks you worked
  (it was **Parks**); WWFF parks are now under **Other programs**.
- **Upload to LoTW (TQSL)** offers the Station Location of New QSO's chosen profile, and
  remembers the last one used for each profile; before, the last location used for any
  profile was offered, so a profile's own location never applied.

### Fixed

- **Log Summary**: a label as long as the column ("Uploaded to Club Log") ran into its
  value; the column now fits the longest label.

### Removed

- **Map → Apple Maps**.

## [1.2.0] - 2026-10-14

### Added

- **Map → Options → Arch over the globe** (on at first): on the globe, lines to contacts
  arch over it, rising with the distance and leaning to one side, and show over the horizon
  for contacts on the far side.
- **Map → DXCC** shades each worked entity's own land, worked out from the country file's
  names and places over Natural Earth's map subunits (Alaska and Hawaii apart from the
  United States, Sardinia apart from Italy, England, Scotland, Wales and Northern Ireland
  each their own); an entity with no land at this scale, or too small on screen, stays a dot.
- **Map, zoomed in**: from 12× the map draws Natural Earth's 1:10m detail (coasts, lakes,
  rivers, borders, state lines and towns' built-up areas, in `map-detail.bin` beside the
  plugin), down to city level at up to 1,024×.
- **Map → Overlays → US counties** (from 2.5×) and **Cities** (7,300 cities and towns, more
  as you zoom in), each with its names in the Labels row.
- **Map → Overlays → IOTA**: IOTA's island groups, the ones in the log filled in, with their
  references (and names where there is room) as labels; point at one for its QSOs. The
  group list is © RSGB and IOTA Ltd and isn't included: **Settings → IOTA Groups →
  Download** fetches it from iota-world.org for your own use.
- **Map → Apple Maps** opens what you clicked, or the middle of the map, in Apple's Maps app
  for streets and satellite views.
- **Map → Overlays → POTA**: POTA's parks at the parks themselves, from POTA's park list
  (**Settings → POTA Parks → Download**, about 9.5 MB from pota.app, on request): a pin for
  each park you hunted, a starred pin for each you activated, and a ring for each active
  park you haven't worked, gathered into counts where there are thousands. Labels give the
  references, and names when zoomed in; point at a park for its QSOs and distance. Old
  references (K-0001) find the renamed park (US-0001) where POTA kept the numbers.

### Changed

- **Map**: the Overlays row lists **Grid squares** (was Maidenhead grid), CQ zones, ITU
  zones, Countries, US states, US counties, Cities, POTA and IOTA, and a **Labels** row
  under it turns each one's names or numbers on and off.
- **Map**: on the colour-blind safe palette, the legend lists the bands without a colour of
  their own in one row ("other bands: 160m, 12m, 6m") instead of a grey swatch each.
- The README and the user guide are revised: highlights and screenshots of the main windows
  and the Map, a quick tour, and the Map in its own section of the guide.
  `tools/docs-screenshots.sh` refreshes the screenshots from the test suite.

## [1.1.0] - 2026-10-11

### Added

- **Map → Globe**: the Earth as seen from space (the orthographic projection, Snyder 1987),
  centred on your grid. Drag, scroll on a trackpad or use the arrow keys to turn it in any
  direction; zoom in for detail; **World** turns it back to home. Coasts, borders, the grid,
  lines to contacts and distance rings stop at the horizon, and bearings from the centre are
  true (beam headings).
- **Map → Contacts**: a pin, dot or crosshair at each contact's own place, from LAT and LON,
  else a 6 or 8 character GRIDSQUARE; point at one for the calls and the distance and
  bearing from home, click it for its QSOs. Placeholder places (LAT/LON 0°, 0° as QRZ.com
  writes them, grids AA00 and JJ00) are drawn nowhere, and LAT/LON more than half a square
  from the QSO's grid is left out.
- **Map projections**: Equirectangular, Mercator, Equal Earth (every area at its true size)
  and the Globe.
- **Map → Colour by** confirmation, band (in PSKReporter's band colours), mode, QSO count or
  year first worked, with a legend (in the PNG too). The **Colour-blind safe** palette has
  its own seven band colours, from Tol's, Okabe and Ito's and Petroff's colour-blind safe
  sets, chosen to stay apart under simulated protan, deutan and tritan vision on the dark map
  (tested: CIEDE2000 14.9 or more between any two; viridis, tried first, fell to 5.3).
- **Map → Options**: palettes (Standard, Colour-blind safe, High contrast, Light for
  printing), marker size and shape, contact markers, worked squares solid, see-through or
  outlined, **Lines to contacts** (great circles from your station to each contact's
  LAT/LON, grid, or DXCC entity) solid, dashed or dotted and thin, medium or thick, the
  legend, and distance rings from your grid.
- **Map → Show**: **Other programs** as a list of common programs with a colour and a count
  each (SOTA, IOTA, GMA, WWBOTA, HEMA, SiOTA, WCA, ILLW, ARLHS, MOTA, ZLOTA, WOTA and any
  other SIG). **Overlays**: the Maidenhead grid and its labels, **Countries** outlined with
  their names and **US states** with their postal codes (Natural Earth), and **CQ zones**
  and **ITU zones** with their numbers (HB9HIL's hamradio-zones-geojson, MIT), each on or
  off.
- **Map → Region** zooms to a continent; the globe turns to face it.
- **Map → Only**: dates (the last 30 days, the last 12 months, this year, a year) and
  confirmed or not confirmed QSOs, beside band and mode.
- The Map's status line gives the distance and bearing from home of the square under the
  pointer. Every Map choice is remembered.

## [1.0.1] - 2026-10-10

### Added

- **Bulk Edit → Change case**: UPPER CASE, lower case or Title Case for names and places
  (`O'Brien-Smith`, `McDonald`, `III` kept; words with digits left alone). **Field** takes
  several fields separated by commas (`NAME, QTH`) for every action but Rename.
- **Bulk Edit → Only where** has more ways to match: starts with, ends with, is one of,
  matches pattern (`*/P`), matches regular expression, is less than, is greater than and is
  between (numbers and dates by value), and a **not** box that turns any of them around.

### Changed

- **Enrich is much faster on large logs**: it looks up only calls with a record that lacks
  one of the chosen fields, four at a time on one QRZ.com or HamQTH session (one at a time
  after an error), and shows the time left.
- **QSL Sync → QRZ.com Logbook** sends three QSOs at a time instead of one after another
  with a pause (the QRZ Logbook API takes one QSO per INSERT and has no batch upload).
- Check Log repairs a field repeated with one copy empty (`<STATE:0>` plus `<STATE:3>NLE`),
  keeping the value once, and a STATE or CNTY that is ADIF's code spelled another way
  (`AK,Matanuska Susitna` becomes `AK,Matanuska-Susitna`) instead of only offering to remove it.
- Retired subdivision codes whose subdivision ADIF lists again under a new code (Mexico's
  `NL` is `NLE`, the Netherlands' `ZL` is `ZE`, 41 in all) get that code as their repair.

### Fixed

- Enrich added a second STATE (or other field) to a record that had the field empty
  (`<STATE:0>`), a duplicate-field error; it now fills the empty one.
- Enrich wrote state codes ADIF retired (QRZ.com's `NL` for Nuevo León) and county names
  in the callbook's spelling (`AK,Matanuska Susitna`), which lint as problems. It now writes
  the current code and ADIF's spelling, and leaves out any value ADIF Lint would report.

## [1.0.0] - 2026-10-10

### Added

- **Monitor (WSJT-X, N1MM, Loggers)…**: QSOs other programs log are added to the log you
  choose as they're logged. It listens for WSJT-X's and JTDX's QSO Logged and Logged ADIF
  messages (2237, with an optional multicast group), JS8Call's `LOG.QSO`, ADIF records over
  UDP (2333), N1MM Logger+'s contact broadcasts with their edits and deletions (12060), and
  GridTracker's DXKeeper and HRD Logbook commands over TCP (52001), and can watch WSJT-X's
  log file or any log a program appends to. QSOs go into the open log (one undo step
  each), into the file when it isn't open, or into a queue while it's open in another tab;
  a QSO the log already has isn't added again. It only listens, on this Mac unless you
  allow other computers.
- **Import… → WSJT-X log file** compares and merges WSJT-X's own log.
- **Compare and Merge Logs…** (replacing Merge Another Log): two logs compared QSO by QSO,
  listing QSOs only one has and the fields the same QSO has differently; add the ticked
  QSOs and copy the fields this log lacks (or replace differing ones), in one undo step.
- **QSL Sync (Upload, Confirmations)…** (replacing Upload…): each service's QSOs to upload,
  changed, uploaded, unsendable and confirmed, the last upload and download, with Upload
  and Download Confirmations.
- **Spots → More programs (Spothole)**: spots from dozens of programs (GMA, WWBOTA, ZLOTA,
  IOTA, HEMA, castles, lighthouses...) through spothole.app, with a program filter, every 2
  minutes as Spothole asks; SOTA is left out. Using a spot fills SIG and SIG_INFO (and IOTA,
  and GRIDSQUARE when known). Any program's references in SIG_INFO, and IOTA, now count as
  worked, and show on the Map under Other programs (Parks keeps to POTA and WWFF). The menu
  item is now Spots (POTA, WWFF, More)….
- **Contest…** in New QSO: ARRL Field Day, Winter Field Day or serial numbers. New QSO asks
  for the other station's exchange (CLASS and ARRL_SECT, or SRX), writes CONTEST_ID, the
  exchanges (STX_STRING, SRX_STRING, MY_ARRL_SECT) or the next STX, and warns of duplicates
  by the Field Day rule (once per band and mode: CW, Phone, Digital) and of a band, mode or
  repeater the rules don't count (ARRL Field Day 2026; Winter Field Day 2027: no 12, 17, 30
  or 60 m, no WSJT modes, direct contacts only). Export Cabrillo writes Field Day lines
  without reports.
- **Map (Grids, DXCC, Parks)…**: the log on a world map, offline (Natural Earth's land,
  lakes, rivers, borders and state lines, public domain): worked and confirmed grid
  squares, DXCC, hunted parks and your grid. Zoom (pinch, wheel, double-click, buttons) and drag around, with
  field and square names as you zoom in; point at anything to read it, click it to list
  its QSOs, double-click one to go to its record. Band and mode filters, PNG export.
- **Export… → QSL labels (PDF)**: a label per station for the cards to send (QSL_SENT R or
  Q), on Avery 5160, 5163 or L7163 sheets, then Mark as Sent (QSL_SENT Y and QSLSDATE).
- **LoTW Users** (Settings, off by default): ARRL's weekly list of LoTW users, shown in New
  QSO's lookup line, a Spots column and an optional Log Table column.
- **LoTW pre-flight**: the upload window checks each QSO's call, DXCC, grid, state, county
  and zones against the TQSL Station Location as TQSL does, and names a location that
  matches the ones it would refuse. Station Locations are read from TQSL's folder
  (`~/.tqsl` or `$TQSLDIR`); a station profile's TQSL location is used when none is chosen.

- **Station profiles**: named sets of your station's fields (callsign, operator, grid,
  state, county, rig, antenna, power, TQSL location), edited in their own window and chosen
  in New QSO's new **Station** popup.
- **Start Activation…**: a POTA (two-fers too), WWFF or SOTA activation in a new log named
  as the program asks, or the open log. New QSO opens on it, writes the activation's fields
  and your profile in every QSO, and shows the progress ("US-7929 today: 8 of 10").
  **Finish** opens Check Log and the export, and for POTA a button opens pota.app's upload
  page.

- **Check Log…**: every problem in one list, with its record, line, field and repair; the
  ticked repairs are applied together as one undo step. Repairs: a MODE that is really a
  submode (`USB`, `FT4`, `JS8`, `PSK31`… become MODE SSB, MFSK or PSK with that SUBMODE),
  a SUBMODE under the wrong MODE or without one, dates and times typed `2026-10-06` and
  `22:30`, FREQ written in kHz or outside BAND, BAND missing, lowercase calls and states,
  SAT_NAME without PROP_MODE SAT, a POTA record without STATION_CALLSIGN, a repeated
  field with the same value, a missing final `<EOR>`, a byte-order mark.
- New checks for what services expect: BAND when only FREQ is given (POTA reads BAND),
  upper-case calls and states, QSO dates in the future (POTA refuses them), PROP_MODE SAT
  with SAT_NAME (LoTW), and STATION_CALLSIGN or OPERATOR in POTA activation records.
- The **Record Panel** offers a problem's repair on a right-click.
- `adiflint --fix-all OUT` applies every repair, and each diagnostic line ends with its
  code (`[mode-is-submode]`).
- **Toolbar buttons** for New QSO, Log Table, Check Log and Spots, with light and dark
  icons.
- The **Record Panel** sums up the whole log under its title: problems, QSOs waiting for each
  upload service the log uses, and today's POTA activation.
- **Settings** gains **Your Station** (callsign and grid for logs that don't name them, used
  by New QSO, distances and the exports, and the logs folder), **Editor** (the options that
  were menu items) and **Keyboard Shortcuts** (where to assign them, with suggestions). The
  first run opens Settings with a welcome.
- **Export… → CSV** shows the log as it will be saved before **Save CSV…**.
- **More of ADIF 3.1.7 checked** (every rule verified against the specification text,
  2026-10-10; see [docs/ADIF_CONFORMANCE.md](docs/ADIF_CONFORMANCE.md)):
  - codes ADIF deleted are valid only for QSOs in their dates (§II.C): ARRL sections (`ON`
    until 2012-09-01, `GTA` and `NT` until 2023, `GH`, `NB`, `NS`, `TER` from 2023), the
    Kosovo region and Russian and Austrian districts; a single named replacement valid on
    the QSO's date is the repair (`GTA` → `GH`). Autocomplete no longer offers them.
  - REGION must belong to the record's DXCC entity (§III.B.21).
  - VUCC_GRIDS and MY_VUCC_GRIDS: two or four adjacent locators of 4 or 6 characters,
    agreeing with GRIDSQUARE (§III.A.1).
  - GRIDSQUARE_EXT after an 8-character GRIDSQUARE; one longer than 4 characters is cut
    to 4, as importers ignore the rest.
  - LAT and MY_LAT start with N or S, LON and MY_LON with E or W.
  - USACA_COUNTIES (two or more `state,county`) and CNTY_ALT (`NZ_Regions:...` items, each
    list name once, codes from ADIF's table).
  - QSL dates need the status that makes them valid (QSLRDATE when QSL_RCVD is Y, I or V;
    QSLSDATE when QSL_SENT is Y, Q or I; LoTW, eQSL and DCL alike; a missing status is N).
  - A note, once per file, when STATE, CNTY, MY_STATE or MY_CNTY lacks its DXCC (§I.E),
    and when a file has a header but no records (§IV.A.2).

### Changed

- **A shorter menu**: 28 commands instead of 39. **Import…**, **Export…** and **Enrich…**
  each open the window used last, with a popup at its top for the others (Import from:
  LoTW, QRZ.com Logbook, eQSL, CSV file, WSJT-X log file); the upload windows open from QSL
  Sync and switch with the same popup. Check Log replaces **Validate Now**; Sort
  and Organize's **Date and Time** button replaces **Sort Records by Date and Time**;
  colouring, autocomplete and counting characters moved to Settings → Editor, and
  "Validate .adi Files While Typing" is now **Check .adi Files While Typing**. Nextpad++
  keeps plugin shortcuts by menu position, so check any you assigned (Edit → Shortcut
  Mapper…).
- Sort and Organize remembers a field order only when you apply one.
- A STATE or CNTY that isn't on its country's ADIF list is a warning, not an error, and says
  which country and lists its codes (Hungary's are counties such as `BP` and `PE`). These
  usually come from callbooks: QRZ.com Logbook copies the other station's profile, such as
  `H` for Hungary. Check Log offers to remove one, unticked.
- Check Log groups a problem repeated in many records into one row (an option, on by
  default), and repairing the row repairs every record. New repairs: a placeholder such as
  IOTA `none` or GRIDSQUARE `-` is removed; a Field Day class in ARRL_SECT (`1D`) moves to
  CLASS; a retired code the specification names a replacement for (STATE `DF` for Mexico
  City) becomes the new one (`CMX`).
- Check Log names the field of every problem and shows a tick box only where there is a
  repair. The Record Panel's "to upload" counts a service only once something was sent to it
  (Y or M), not when a downloaded log merely says N.
- Check Log repairs TX_PWR and RX_PWR written with a unit (`30W` becomes `30`, `1.5kW`
  `1500`), as WSJT-X writes whatever you type in its power box.

### Fixed

- WWFF export files are named as WWFF asks, `KW9D @ KFF-1234 20261006.adi`: spaces around
  the `@`, a `/` in the call written as `-`, and an activation over consecutive UTC days in
  one file named for its first day (it was one file per day, `KW9D@KFF-1234 20261006.adi`).
- The LoTW window looked for TQSL's Station Locations only in
  `~/Library/Application Support/TrustedQSL`; TQSL keeps them in `~/.tqsl` on a Mac.
- Messages cited §II.B for data types, the section number in older ADIF versions; in ADIF
  3.1.7 it is §III.A.
- ANT_AZ and ANT_EL outside 0-360 and -90-90 were errors; the specification calls them
  import-only, to be normalized on export, so they are warnings with the normalized value
  as the repair (370 → 10, 100 → 80).
- `USERDEF01` was flagged for its leading zero; n only has to be a positive integer.
- An APP_ field that first appears without a type (so a MultilineString) and later with
  another type is now reported, as the specification forbids changing it.
- A latitude of 90 degrees with minutes, or a longitude of 180 with minutes, was accepted.

## [0.9.0] - 2026-10-09

### Added

- The **Log Table edits like a spreadsheet**. Click a cell and type, or press Return; Tab,
  Shift-Tab and Return move on, Esc cancels, and Left and Right move the active cell.
  Command-C copies the selected rows as tab-separated text with a heading row of field
  names (for Numbers or Excel); Command-V pastes cells, by field name when the text has
  that heading row, with rows past the end becoming new QSOs. Command-D fills down, Delete
  clears a field, Command-Delete deletes rows, **Add Row** appends a QSO with today's UTC
  date and time and the station's fields, and the heading menu can **Add Field…** as a new
  column or **Remove** a field from every record. A right-click menu on the rows offers
  the same. Each change is one undo step in the `.adi` file.
- **Sort and Organize…**: sort the records by up to three fields (ascending or descending;
  bands by frequency, dates and times in time order, numbers by value), and give every
  record the same field order without changing any data. One undo step; the choices are
  remembered. The Log Table's **Organize Log…** starts from its sort and columns, and the
  table now sorts bands by frequency and empty cells last. `adiflint --sort-by` and
  `--field-order` do the same from the command line.
- **Import from LoTW…, Import from QRZ.com Logbook…, Import from eQSL…**, grouped with
  Import CSV: download your QSOs from the site, add the ones the log lacks, and add the
  confirmation and its details to the ones it has, after a review (one undo step). LoTW
  returns every QSO you uploaded, confirmed or not; QRZ.com Logbook every record; eQSL its
  InBox, whose QSOs the log lacks are offered but not ticked, since they are the other
  station's records.
- [User guide](docs/USER_GUIDE.md), [CONTRIBUTING.md](CONTRIBUTING.md) and
  [SECURITY.md](SECURITY.md); the README is rewritten as an overview, with this changelog
  kept separately.

### Changed

- The **Record Panel** can be sorted: click a heading to order its rows by field name,
  value or problem (errors first), or **#** (a new column, the field's position) for the
  record's own order. Only the view changes, and the choice is remembered.
- The confirmation sources leave Enrich: **Enrich from LoTW Confirmations…**, **QRZ.com
  Logbook Confirmations…** and **eQSL Confirmations…** are replaced by the Import commands.
  Enrich keeps QRZ.com, HamQTH and Country Data.
- A confirmation from eQSL or QRZ.com Logbook upgrades a status that says it hasn't
  happened (EQSL_QSL_RCVD N, R, Q or I becomes Y; APP_QRZLOG_STATUS becomes C), as LoTW's
  already did.
- Using a spot runs New QSO's lookup, so the country and the park's history show at once.
- The About box describes the current features and links to the project page.

### Removed

- The radio connection: **From Radio**, **Follow the radio** and Settings → Radio
  (Hamlib `rigctld` and flrig). The old radio settings are dropped from `ADIFLint.ini`.

## [0.8.0] - 2026-10-08

First public release.

### Added

- **New QSO lookup as you type.** Country data (offline) fills DXCC, COUNTRY, CQZ, ITUZ
  and CONT from the call's prefix; QRZ.com or HamQTH add name, QTH, state and grid from
  your callbook account. A line under it shows distance and bearing from MY_GRIDSQUARE
  and what your logs say about the park, reference or summit.
- **WWFF spots** beside POTA spots, from spots.wwff.co, and a Worked column marking each
  spot NEW, worked or today.
- **WWFF and SOTA** in the Activation Tracker and the export: WWFF counts 44 QSOs per
  reference over all activations; SOTA counts distinct stations per summit and day.
  Files are named as each program asks (`KW9D@KFF-1234 20261006.adi`,
  `KW9D_W7A-AE-001_20261006.adi`).
- **Confirmations from QRZ.com Logbook and eQSL**, as two new Enrich sources.
- **Offline country data** from AD1C's Big CTY file (MIT licence), installed with the
  plugin, with **Update** in Settings to download the newest release.
- **Import CSV**, **Export Cabrillo** (Cabrillo 3.0) and **Fill DISTANCE from grid
  squares** in Bulk Edit.
- **Log Table** editing (double-click a value), column choice (right-click the headings)
  and a remembered sort.
- **Parks worked** (a hunter's tally) in the Log Summary.
- **TQSL certificate password**, kept in the Keychain and passed to TQSL with `-p`.
- **Command-line log tools**: `--sort`, `--dedupe`, `--csv`, `--from-csv`, `--summary`,
  `--cabrillo` and `--export pota|wwff|sota`.
- `tools/make-release.sh`, which builds the release zip and prints the plugin-list entry.

### Changed

- Menu items renamed: **POTA Spots…** is now **Spots (POTA, WWFF)…**, **POTA Activation
  Tracker…** is **Activation Tracker (POTA, WWFF, SOTA)…**, and **Export POTA Logs…** is
  **Export Activation Logs…**.
- **Time Shift** converts between UTC and a named time zone in either direction, using the
  offset in force on each QSO's date; skipped and repeated local times are listed and left
  alone. The fixed-amount shift remains.
- An uploaded QSO that you change becomes M (modified since upload), as ADIF prescribes,
  and is sent again; QRZ.com receives it with OPTION=REPLACE.
- The Log Table shows dates and times as 2026-10-06 and 22:30.

### Fixed

- The Log Table moved the editor's caret to the selected record whenever the log was
  re-checked while you typed.
- Table selections followed the row position instead of the record, so a refreshed spot
  list could fill New QSO with a different activator.
- Records without STATION_CALLSIGN split an activation in two and produced two export
  files with the same name.
- A park listed twice in MY_POTA_REF put the record in the export file twice.
- New QSO warned about a duplicate when working the same activator at another park
  (park-to-park), and treated `N0CX/P` and `N0CX` as different calls.
- Upload windows re-ticked QSOs you had unticked whenever the log changed.
- Table sorting treated `INF`, `NAN` and `0x…` as numbers.
- TQSL could run with no time limit; it is now stopped after 10 minutes.
- A CW spot left an earlier USB SUBMODE from the radio in New QSO.

## [0.7.0] - 2026-10-07

### Added

- **Log tools:** Log Table, Log Summary, POTA Activation Tracker, Export POTA Logs (one
  file per park and UTC day), Worked Before across a folder of logs, Bulk Edit, Time Shift
  by a fixed amount, Sort Records by Date and Time, Remove Duplicates, Merge Another Log
  and Export CSV. Every change is one undo step, and Bulk Edit and Time Shift preview
  every change first.
- **Radio in New QSO:** From Radio and Follow the radio, through Hamlib `rigctld` or flrig,
  read-only.
- **POTA Spots**, filling New QSO from an activator's spot.
- **Worked before** in New QSO, from the logs folder.
- **Uploads** to QRZ.com Logbook, LoTW (through TQSL), Club Log and eQSL. Each lists what
  would be sent and sends nothing until you press Upload; accepted QSOs get the ADIF
  upload-status field and date.
- Settings → Radio, with Test.

## [0.6.0] - 2026-10-07

### Added

- **New QSO Fields…**: choose and order the fields New QSO asks for, with each field's
  type and the description from the ADIF 3.1.7 specification, searchable by name or
  description. Station fields you hide are still copied from the last record unless you
  turn that off.

### Changed

- Field descriptions are generated from the ADIF specification's HTML, not its data
  export, so descriptions and notes no longer run together.

## [0.5.0] - 2026-10-07

### Added

- **Settings…**: one section per service, with Save, Test Sign-In and Remove. Accounts are
  kept only in the macOS Keychain.

### Changed

- Enrich is one menu item per source: Enrich from QRZ.com…, from HamQTH… and from LoTW
  Confirmations….
- The QRZ.com sign-in is sent as a POST, so the password is not in a URL, and messages
  QRZ.com sends back are shown.

### Fixed

- New QSO left a large empty area below its fields.

## [0.4.0] - 2026-10-06

### Added

- **Enrich Log**: add missing NAME, QTH, STATE, CNTY, GRIDSQUARE, DXCC and COUNTRY, zones,
  IOTA and continent from QRZ.com XML, HamQTH or LoTW confirmations, reviewed before
  anything changes. Portable and park-to-park records get only the name from a callbook.

## [0.3.0] - 2026-10-06

### Added

- **New QSO…**: a window for logging contacts one after another. Station fields carry
  over from the last record, date and time are UTC, duplicates are flagged, and each
  record is appended with correct lengths in the log's own layout.

## [0.2.0] - 2026-10-06

### Added

- Syntax colouring, Reformat (one record or one field per line), autocomplete of field
  names and values with automatic lengths, and the docked Record Panel.
- `adiflint --reformat records|fields OUT`.

## [0.1.0] - 2026-10-06

### Added

- Validation of `.adi` files as you type against ADIF 3.1.7, with marks you can hover to
  read, Next Problem and Previous Problem, and Validate Now.
- **Fix Lengths**, as one undo step, and **Count Lengths in Characters**.
- The `adiflint` command-line tool.

[Unreleased]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v0.9.0...v1.0.0
[0.9.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/releases/tag/v0.8.0
