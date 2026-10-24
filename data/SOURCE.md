# Country data

`cty.csv` is Jim Reisert AD1C's Big CTY country file, release of 15 September 2026,
from https://www.country-files.com/bigcty/download/2026/bigcty-20260915.zip
(downloaded 2026-10-07). It is MIT-licensed; the notice is in `cty-copyright.txt`.

The plugin installs this copy next to `ADIFLint.dylib`. **Settings → Country Data →
Update** downloads the newest release into the plugin config folder, and that copy
is used from then on.

# Map overlays

The Map's **CQ zones** and **ITU zones** come from `cqzones.geojson` and `ituzones.geojson` in
HB9HIL's https://github.com/HB9HIL/hamradio-zones-geojson, commit
19599364fe316b36182f02dbe99deffab5801111 (2024-10-31; downloaded 2026-10-10). They are
MIT-licensed; the notice is in `zones-license.txt`. They are the zone files Wavelog uses. The
repository does not say where the lines were drawn from, so treat them as approximate: zone
lines across the sea are not exact in any source, and sources disagree in places.

**US states** and **Countries** come from Natural Earth's
`ne_50m_admin_1_states_provinces.geojson` and `ne_50m_admin_0_countries.geojson` (public
domain), from https://github.com/nvkelso/natural-earth-vector commit ca96624 (downloaded
2026-10-10).

**US counties** and the **map subunits** the DXCC layer shades (England apart from Scotland,
Alaska apart from the lower 48) come from Natural Earth's `ne_10m_admin_2_counties.geojson`
and `ne_50m_admin_0_map_subunits.geojson` (public domain), same commit ca96624 (downloaded
2026-10-13).

`tools/gen_map_overlays.py` turns the six files into `src/core/adif_overlays_data.cpp`.

# Map detail

`map-detail.bin`, the 1:10m detail the Map draws from 12× (land, lakes, rivers, country
borders, state and province lines, urban areas and 7,342 cities), comes from Natural Earth's
`ne_10m_land`, `ne_10m_lakes`, `ne_10m_rivers_lake_centerlines`,
`ne_10m_admin_0_boundary_lines_land`, `ne_10m_admin_1_states_provinces_lines`,
`ne_10m_urban_areas` and `ne_10m_populated_places_simple` (.geojson, public domain), commit
ca96624 (downloaded 2026-10-13). `tools/gen_map_detail.py` writes it and describes its format;
the plugin installs it next to `ADIFLint.dylib`.

# Terrain

`relief.jpg`, the Map's **Terrain** (Style Options), is Natural Earth's 1:50m Shaded Relief
Basic (`SR_50M.tif`, 10,800 x 5,400 8-bit grey, plate carrée, public domain; VERSION 2.0.0),
from https://naciscdn.org/naturalearth/50m/raster/SR_50M.zip (11,380,369 bytes, SHA-256
ff810f5f2747463fd8ffa612b23e5f5e5d593a345218976872b6749610976ab7; downloaded 2026-10-24).
`tools/gen_relief.py` scales it to 8,192 x 4,096 and maps its flat grey (206, measured: the sea
and flat land) to 128; the plugin installs it next to `ADIFLint.dylib`.

# Country flags

`src/core/adif_flags.cpp` maps each current DXCC entity to a flag (ISO 3166-1 codes, a few codes
ISO reserves that Unicode draws, England's, Scotland's and Wales's tag sequences, the UN's). It was
written for this plugin on 2026-10-24 and checked against k0swe/dxcc-json (Apache-2.0, commit
7d0c8dd), Wavelog's `DxccFlag.php` (MIT, 5e9513e) and QLog's `dxcc.json` (4d41fc7), and against
Unicode's `emoji-sequences.txt` 18.0: no data was copied from them.

# Fetched on request: space weather

The Map's space weather and aurora come from NOAA's Space Weather Prediction Center
(https://services.swpc.noaa.gov, public domain per https://www.weather.gov/disclaimer):
`products/summary/10cm-flux.json`, `products/noaa-planetary-k-index.json`,
`text/daily-geomagnetic-indices.txt`, `json/goes/primary/xrays-6-hour.json`,
`products/noaa-scales.json` and `json/ovation_aurora_latest.json`, in the formats served since
SWPC's change of 31 March 2026 (SCN 26-21; read 2026-10-24). Only when you turn them on, every
15 minutes at most. `tests/fixtures/lookup/swpc/` holds files in their layout for the tests;
the values in them are examples and the aurora ring is made up.

# NCDXF beacons

`src/core/adif_beacons.cpp` holds the NCDXF/IARU beacons' calls, places and grids and their
schedule, from https://www.ncdxf.org/beacon/ (index.html, beaconlocations.html and the schedule
table in beaconschedule.html, read 2026-10-24). Nothing is fetched: NCDXF asks programs not to
read its status file on each user's behalf.

# Not included

POTA's park list (`all_parks_ext.csv`, about 9.5 MB, rebuilt daily) has no published terms of
use (docs.pota.app and parksontheair.com, read 2026-10-14), so it is not in this repository or
in a release: **Settings → POTA Parks → Download** fetches it from https://pota.app into the
plugin config folder, on the user's request, as other loggers (Ham2K PoLo, Wavelog) fetch it at
run time. `tests/fixtures/lookup/pota/all_parks_ext.csv` is made-up test data in its layout.

IOTA's group list (`groups.json`) is © RSGB and IOTA Ltd, who allow downloading it for
personal non-commercial use (iota-world.org, read 2026-10-13). It is not in this repository
or in a release: **Settings → IOTA Groups → Download** fetches it into the plugin config
folder, on the user's request. `tests/fixtures/lookup/iota/groups.json` is made-up test data
in the same layout.

## Map Detail (not included)

The streets and buildings of **Settings → Map Detail** are OpenStreetMap data, © OpenStreetMap
contributors under the Open Database License (https://www.openstreetmap.org/copyright), in
Protomaps' basemap (v4, https://docs.protomaps.com/basemaps/layers; its code is BSD and its
map styles CC0). Nothing of it is in the repository or a release: the plugin cuts the
regions the user chooses out of Protomaps' daily planet build (https://build.protomaps.com,
listed in https://build-metadata.protomaps.dev/builds.json, read 2026-10-18) by HTTP byte
ranges and keeps them in the plugin config folder. Protomaps' download page discourages
hotlinking its builds (docs.protomaps.com/basemaps/downloads, read 2026-10-18), so the Map
reads only the downloaded files, never the build, while it draws. The tests use a made-up
stand-in (`tests/fixtures/lookup/mapdetail`, made by `tools/pmtiles_dev.cpp fixture`).

## Park outlines (not included)

The outlines of **Settings → POTA Parks → Park Outlines** are downloaded by the user, for one
POTA location at a time, into the plugin config folder's `parks` folder; nothing of them is in
the repository or a release, and the tests use made-up stand-ins written by the harness.

- **OpenStreetMap** areas tagged `communication:amateur_radio:pota` (9,666 on taginfo,
  2026-10-20), © OpenStreetMap contributors under the Open Database License
  (https://www.openstreetmap.org/copyright), read through the Overpass API
  (https://overpass-api.de; its usage policy on https://wiki.openstreetmap.org/wiki/Overpass_API,
  read 2026-10-20: identify the program, keep well under 10,000 queries a day, wait after
  429). The Map credits "© OpenStreetMap contributors" whenever it draws one.
- **pota-map.info** (DK5UR), its GeoJSON per POTA location (https://pota-map.info/geojson/,
  read 2026-10-20): the compilation is MIT-licensed; its sources are government open data
  under their own licences (Germany: the federal Nutzungsbestimmungen and the states'
  dl-de/zero-2-0, dl-de/by-2-0, CC BY 3.0 DE, CC BY 4.0 and ODbL; Austria and Czechia CC BY
  4.0; Switzerland opendata.swiss's terms; Denmark and Luxembourg CC0). Liechtenstein's file
  comes from WDPA, whose terms are narrower, so it isn't used. The Map credits pota-map.info.
- **PAD-US 4.1**: U.S. Geological Survey (USGS) Gap Analysis Project (GAP), 2025, Protected
  Areas Database of the United States (PAD-US) 4.1: U.S. Geological Survey data release,
  https://doi.org/10.5066/P96WBCHS, queried at
  https://edits.nationalmap.gov/arcgis/rest/services/PAD-US/PAD_US_4_1/MapServer/0 (fields
  Unit_Nm, Des_Tp and State_Nm; its designation codes read 2026-10-20). US Government data,
  credited as "PAD-US 4.1 (USGS)" on the Map. Matched to POTA's parks by name and place, so a
  match can be wrong; the Map says which outlines are matched and to which unit.

## Language tables (`lang/`)

`lang/ko.json`, `fr.json`, `de.json`, `es.json` and `ja.json` translate ADIF Lint's own
texts, keyed by the English. They were drafted by Claude (an AI, Anthropic) in October 2026
from the plugin's English texts and are part of ADIF Lint, under its licence; no other
translation was copied. They have not yet been reviewed by native speakers. Ham-radio and
ADIF terms (QSO, CALL, BAND, field and enumeration names), service names and the ADIF
specification's own texts stay in English.
