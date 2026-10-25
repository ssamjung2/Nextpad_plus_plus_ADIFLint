# Contributing to ADIF Lint

Bug reports, log files that ADIF Lint gets wrong, and pull requests are welcome on
[GitHub](https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/issues). For a validation
problem, attach the smallest `.adi` excerpt that shows it (remove anything private) and
say what you expected, ideally with the section of the
[ADIF 3.1.7 specification](https://www.adif.org/317/ADIF_317.htm) that says so. For a
security problem, see [SECURITY.md](SECURITY.md) instead.

By contributing, you agree that your contribution is licensed under the
[GNU GPL v3](LICENSE), like the rest of the project.

## Build

Requirements: macOS 11 or later, the Xcode command-line tools, CMake 3.20 or later and
Python 3 (only to regenerate the ADIF tables). Nextpad++ 1.1.2 or later to try the plugin.

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
```

```bash
cmake --build build -j
```

The build is universal (arm64 and x86_64), as Nextpad++ plugins must be. It produces
`build/ADIFLint.dylib` (the plugin), `build/adiflint` (the command-line checker) and the
test programs.

To try your build in Nextpad++:

```bash
cmake --install build
```

This copies the dylib to `~/Library/Application Support/Nextpad++/plugins/ADIFLint/` by
writing a new file and renaming it over the old one, so it is safe while Nextpad++ is
running. Nextpad++ loads plugins only at launch: restart it to load the new build.

## Test

```bash
cd build && ctest --output-on-failure
```

| Test | What it checks |
|---|---|
| `adif_tests` | One case per validation rule, with the expected result taken from the specification; the document model, reformatting and edits; the log tools, uploads, imports, grids, country data, WWFF and SOTA, CSV and Cabrillo, spots (DX cluster lines captured from DXSpider's format, PSKReporter's sample reply), the map's worked areas, regions and projections, the sun, NOAA SWPC's space-weather files, the NCDXF beacon schedule and the DXCC flags. The official ADIF 3.1.7 test file (6,197 records) must give no errors or warnings, lengths broken at random in it must be repaired to the original bytes, and reformatting it must keep every field byte for byte. |
| `fuzz_smoke` | Mutated logs, network replies, CSV and country files, the datagrams and TCP messages the Monitor reads, a DX cluster's byte stream, PSKReporter's replies, park outline sources, PMTiles and vector tiles and NOAA SWPC's files, must give in-bounds results and safe edits without crashing; 2 MB hostile inputs must stay fast. |
| `adiflint_official`, `adiflint_tools` | The command-line checker and log tools on the official test file. |
| `lang_check` | Each language table in `data/lang/` parses, has no key the sources no longer have, keeps every placeholder (`{name}` and printf ones, the latter in order unless numbered `%2$@`) and gives each count its plural forms. |
| `lang_layout` | Every window in every language: no text cut short and no controls overlapping (label `slow`, about a minute; `ctest -LE slow` skips it). |
| `host_harness` | Loads the built dylib through its plugin exports and drives every window against a simulated Nextpad++ and Scintilla: the menu, validation, colouring, autocomplete, the Record Panel, New QSO, Enrich, Import, Settings, the log tools, the Map (its layers, filters, list, selected panel, terrain, flags, space weather from fixtures in NOAA SWPC's layout, beacons; spots with a stand-in DX cluster node on a loopback port), uploads (a stand-in TQSL), the Monitor (real UDP and TCP messages to loopback ports from `ADIFLINT_TEST_PORTS`, and a watched file) and layout (no two controls may overlap). Network replies come from `tests/fixtures/lookup`; credentials are kept in memory, never in the Keychain. |

Also run, before a pull request that touches the plugin or the core:

- **Intel**, under Rosetta:

  ```bash
  arch -x86_64 build/host_harness build/ADIFLint.dylib tests/fixtures/lookup
  ```

- **AddressSanitizer and UBSan** on the core:

  ```bash
  cmake -B build-asan -DADIF_SANITIZE=ON -DCMAKE_BUILD_TYPE=Debug
  ```

  ```bash
  cmake --build build-asan -j && (cd build-asan && ctest --output-on-failure)
  ```

- **Layout**, for a change to a window: run the harness with `ADIFLINT_SNAPSHOT_DIR` set
  to a folder, and look at the dark-mode PNG it saves of each window.
- **Screenshots** in the README and user guide: `tools/docs-screenshots.sh` (after a build)
  saves them into `docs/images` from the harness, the map and Log Table drawn from a
  generated sample log (`ADIFLINT_DOCS=1`), never a real one. Add a window to its list to
  use a new one.

## Project layout

| Path | Contents |
|---|---|
| `src/core/` | Everything about ADIF, in plain C++17 with no editor or AppKit code: the validator and length fixer (`adif_lint`), document model and edits (`adif_edit`), log tools (`adif_tools`), enrichment rules (`adif_enrich`), uploads (`adif_upload`), imports from LoTW, QRZ.com Logbook and eQSL (`adif_import`), WWFF, SOTA and Spothole (`adif_programs`), country data (`adif_country`), grid squares and ADIF Locations (`adif_geo`), CSV and Cabrillo (`adif_formats`), station profiles and activations (`adif_profiles`), QSOs captured from other programs and writing them into a log (`adif_capture`), comparing two logs (`adif_compare`), TQSL Station Locations, QSL Sync's summary and LoTW users (`adif_qsl`), contests and Field Day (`adif_contest`), QSL labels (`adif_labels`), the map's data and land outline, DXCC land and IOTA groups (`adif_world`, and `adif_world_data.cpp` generated by `tools/gen_world_outline.py`; the countries, map subunits, US states and counties and CQ and ITU zones in `adif_overlays_data.cpp`, by `tools/gen_map_overlays.py`), the map's 1:10m detail and cities, read from `data/map-detail.bin` (`adif_detail`; the file by `tools/gen_map_detail.py`), POTA's park list (`adif_parks`), a small bounded JSON reader (`adif_json`), POTA park outlines from Overpass, GeoJSON and PAD-US with name-and-place matching and their cache file (`adif_outlines`), spots in one form for the Spots window and the Map, with the DX cluster's telnet lines and `DX de` spots and PSKReporter's reports (`adif_spots`), the map's colours and their colour-blind check (`adif_palette`), the map's projections, the globe's horizon clipping and great circles (`adif_projection`), where a QSO counts on the area layers (`adif_worked`), US regions for the filters (`adif_regions`), what the log has worked and what a spot means for it, and the watch list (`adif_needs`), the sun's place, day and night and the grey line (`adif_sun`), Map Detail's PMTiles files and vector tiles (`adif_pmtiles`, `adif_mvt`), NOAA SWPC's space-weather files and the aurora grid (`adif_solar`), the NCDXF beacons' schedule (`adif_beacons`), the DXCC entities' flags (`adif_flags`), and the translator hook (`adif_i18n`) |
| `src/core/adif_spec.h`, `adif_spec_317.cpp` | The ADIF tables and their lookups; `adif_spec_317.cpp` is generated by `tools/gen_spec_tables.py`, do not edit it by hand |
| `src/plugin/ADIFLint.mm`, `PluginHost.h` | The Nextpad++ glue: menu, indicators, colouring, hover, autocomplete, New QSO and Enrich logic; `PluginHost.h` is what it offers the other plugin files (the active document, settings, edits as one undo step, shared helpers) |
| `src/plugin/*Panel.mm`, `ToolWindow.mm` | The AppKit windows; `ToolWindow` is the general window the log tools are built from |
| `src/plugin/LogTools.mm`, `Uploads.mm`, `Imports.mm` | The log tools, the upload windows (with the TQSL runner) and the import windows |
| `src/plugin/CheckLog.mm`, `Families.mm` | Check Log; the Import…, Export… and upload families and the popup that switches between their windows |
| `src/plugin/Station.mm`, `Monitor.mm` | Station profiles and Start Activation; the Monitor (sockets, file watching, the queue and its window) |
| `src/plugin/Contest.mm`, `Labels.mm`, `Map.mm`, `LotwUsers.mm`, `PotaParks.mm`, `IotaGroups.mm` | The Contest window, Print QSL Labels, the Map, the LoTW user list, POTA's park list and IOTA's group list (both downloaded on request, never shipped) |
| `src/plugin/Lookup.mm`, `Country.mm` | Network clients and Keychain storage, the country file |
| `src/plugin/Spots.mm` | The Map's spot feeds: Spothole, the DX cluster connection (Network.framework) and PSKReporter, each started only while the Map's Spots layer shows, and posting a spot on the cluster |
| `src/plugin/ParkOutlines.mm` | Park Outlines: the downloads per POTA location (Overpass, pota-map.info, PAD-US) and the cache the Map reads |
| `src/plugin/MapView.mm`, `MapLayers.mm`, `MapRelief.mm`, `MapPropagation.mm`, `MapOsm.mm`, `MapDetail.mm` | The Map's view (`MapView.h` says what they share): the plane, pointer and legend; the layers, one method each, in drawing order; the terrain; the aurora, the spots' heat map and the NCDXF beacons; Map Detail's drawing and its downloads |
| `src/plugin/Solar.mm` | Space weather from NOAA SWPC, fetched only while the Map shows it and the user turned it on |
| `src/plugin/Network.mm`, `L10n.mm` | Offline Mode, opening web pages, and the plain downloads (Map Detail, park outlines, space weather); the language tables |
| `src/plugin/LogSpot.mm`, `Night.mm` | Spot when logging (New QSO's two boxes); Night Mode (every ADIF Lint window red on black) |
| `src/plugin/Accordion.mm` | The cards and groups of the Map's sidebar and selected panel (Style Options and Settings among them), and the narrow panels' wrapping checkboxes and rows |
| `src/cli/` | The `adiflint` command-line tool |
| `spec/adif-3.1.7/` | ADIF's JSON export and HTML specification the tables are generated from (see `SOURCE.md`) |
| `data/` | AD1C's country file (see `SOURCE.md`), the Map's 1:10m detail (`map-detail.bin`) and terrain (`relief.jpg`), `toolbar/`, the toolbar icons, and `lang/`, the language tables, all installed beside the plugin |
| `third_party/` | The Nextpad++ plugin header and Scintilla headers, unchanged (see `README.md` there) |
| `tests/` | The tests above, their fixtures and the official ADIF test file |
| `tools/` | The table generator; the map data generators (`gen_world_outline.py`, `gen_map_overlays.py`, `gen_map_detail.py`, `gen_relief.py`); `make-release.sh`; `docs-screenshots.sh`; the translation tools (`extract_strings.py`, `merge_translations.py`, `lang-report.sh`, `lang-layout-check.sh`); `pmtiles_dev.cpp`, a developer's tool for PMTiles files; and `make-toolbar-icons.m`, which draws the toolbar icons (run it after changing them) |

## Guidelines for changes

- **ADIF logic goes in `src/core`** with a test in `tests/adif_tests.cpp`; the plugin
  files only connect it to the editor and windows.
- **Cite your sources.** Every validation rule comes from the ADIF specification, and
  every fact about another service (an API, a file-name rule, a program's rules) is
  written in a comment with its source and the date it was checked. Don't write a CAT
  command, endpoint or field from memory.
- **Edits are one undo step** and never touch data the user didn't ask to change.
- **Nothing is sent without the user asking.** Uploads send only after Upload is pressed;
  lookups and downloads run only from an explicit command (Enrich, Import, Update, Download),
  an enabled lookup, an open Spots window, or a Map layer or switch the user turned on (spots,
  space weather, the aurora), and only while the Map is open. Every request goes through
  Offline Mode (`Network.h`), and every host is listed in the README.
- **Credentials only in the Keychain**, never in `ADIFLint.ini`, logs, test fixtures or
  the repository. Never commit an API key (Club Log deletes keys it finds published).
- **Settings** go in `ADIFLint.ini` in the plugin config folder that Nextpad++ gives
  plugins (`plugins/Config/`), not in the plugin's own folder, which an update replaces.
- **Host limits:** Nextpad++ ignores plugin default shortcuts, `NPPM_SETSTATUSBAR` does
  nothing on macOS, plugins can't supply a lexer, and `NPPN_FILEOPENED` never fires. The
  comments at the top of `src/plugin/ADIFLint.mm` list what the plugin relies on.
- **Objective-C++:** don't put braced initialisers (`{...}`) inside an Objective-C message
  send; build a named variable or `std::vector<T>{...}` first.
- Match the surrounding code's style, naming and comment density.

## Translations

Text shown to the user is written in English and marked where it is written: `T(@"...")`,
`TF(@"... {name} ...", @{...})` and `TP(one, other, n)` in the plugin, `tr`, `trf` and
`trp` in the core, and `N(...)`/`N_(...)` for a table of texts translated where they are
shown. Messages are whole sentences with `{name}` placeholders, never built by joining
pieces, so a language can reorder them. A word with two meanings gets a context after `##`
(`"Solid##line"`), which is never shown.

- `tools/extract_strings.py` lists every key (`--keys`), what a language lacks
  (`--missing fr`), and checks the tables (`--check`, the `lang_check` test).
- `tools/merge_translations.py KEYS.json BATCH.txt...` merges drafted translations into the
  tables (the format is at the top of the script).
- `tools/lang-report.sh fr` opens every window in French and lists text the table didn't
  change, text cut short and overlaps; with no language, a pseudo-language that marks every
  translated text and makes it a third longer finds text the tables can't reach.
- Leave English what is data (field names, enumeration codes, place names, the ADIF
  specification's descriptions), what is written into files, and what goes over the network
  (HTTP headers, user agents).

## Updating the ADIF specification

Replace `spec/adif-3.1.7/all.json` (and `ADIF_317.htm`) with the new version's files from
the ADIF website, run `cmake --build build --target regen-spec`, rebuild, and run the
tests against the new official test file.

## Updating the country data

Download the newest Big CTY release from
[country-files.com](https://www.country-files.com/category/big-cty/), replace
`data/cty.csv`, and update the release and download date in `data/SOURCE.md`.

## Releasing

1. Set the version in `project(ADIFLint VERSION x.y.z ...)` in `CMakeLists.txt` and in
   `ADIFLINT_VERSION` in `src/plugin/ADIFLint.mm` (the release script checks they match).
2. Move the changes under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) to a new version
   with the date.
3. Run all the tests above.
4. Run `tools/make-release.sh`. It builds `dist/ADIFLintvx.y.z.zip` (the `ADIFLint` folder
   only, without macOS metadata), checks both architectures and the version baked into the
   dylib, and prints the zip's and the dylib's SHA-256 with the entry for the Nextpad++
   plugin list.
5. Commit, tag `vx.y.z`, push, and publish a GitHub release for the tag. Since 1.3.0 the
   release has no zip: the plugin list builds, signs and notarizes its own from the reviewed
   commit.
6. Ask for the plugin list to be updated: open an issue in
   [nppPluginList](https://github.com/nextpad-plus-plus/nppPluginList) naming the commit to
   review and what changed (network hosts, files stored, programs run, the build, tests);
   its maintainers review the source and build the entry in `pl.macos-arm64.json`.
