#!/bin/sh
# Fails when any language's table leaves text cut short or controls overlapping in a window
# (tools/lang-report.sh in each language; the lang_layout test runs this).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bad=0
for f in "$root"/data/lang/*.json; do
    lang=$(basename "$f" .json)
    out=$(sh "$root/tools/lang-report.sh" "$lang" | grep -E '^(CLIPPED|OVERLAP)' || true)
    if [ -n "$out" ]; then
        echo "$lang:"
        echo "$out"
        bad=1
    fi
done
[ "$bad" = 0 ] && echo "no clipped or overlapping text in $(ls "$root"/data/lang/*.json | wc -l | tr -d ' ') languages"
exit $bad
