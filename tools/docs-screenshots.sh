#!/bin/sh
# Refreshes the README's and user guide's screenshots in docs/images from the host harness:
# its usual window snapshots, plus the map and Log Table on a generated sample log
# (ADIFLINT_DOCS=1; no real log). Each is saved at the screen's 1x size.
#
#   tools/docs-screenshots.sh            (after cmake --build build)
#
# The Map Detail picture needs a region downloaded in Settings → Map Detail (OpenStreetMap
# data, which isn't in the repository): give its file, and it shows downtown Madison from it:
#   ADIFLINT_DOCS_MAPDETAIL=".../maps/Wisconsin z15 20261018.pmtiles" tools/docs-screenshots.sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
shots=$(mktemp -d)
trap 'rm -rf "$shots"' EXIT
ADIFLINT_DOCS=1 ADIFLINT_SNAPSHOT_DIR="$shots" "$root/build/host_harness" "$root/build/ADIFLint.dylib" "$root/tests/fixtures/lookup" > "$shots/log.txt" 2>&1 || {
    tail -20 "$shots/log.txt" >&2
    exit 1
}

copy() {
    src="$shots/$1.png"
    w=$(sips -g pixelWidth "$src" | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/ {print $2}')
    max=$(( (w > h ? w : h) / 2 ))
    sips -Z "$max" "$src" --out "$root/docs/images/$2.png" > /dev/null
    echo "docs/images/$2.png"
}
if [ -f "$shots/docs-map-detail-streets.png" ]; then copy docs-map-detail-streets map-detail; fi

# snapshot name -> docs/images name
while read -r from to; do
    [ -f "$shots/$from.png" ] || { echo "no snapshot $from" >&2; exit 1; }
    copy "$from" "$to"
done << 'EOF'
docs-map-globe map-globe
docs-map-zones map-zones
docs-map-europe map-europe
docs-map-states map-states
docs-map-colour-blind map-colour-blind
docs-map-city map-city
docs-map-day-night map-day-night
docs-log-table log-table
check-log check-log
new-qso-lookup new-qso-lookup
new-qso-spot new-qso-spot
pota-spots spots
monitor monitor
qsl-sync qsl-sync
start-activation start-activation
activation-tracker activation-tracker
upload-qrz upload-qrz
import-qrz import-qrz
bulk-edit bulk-edit
compare compare
EOF
