#!/bin/sh
# Opens every ADIF Lint window in a language and lists the texts its table didn't change and
# any overlaps. With no language, uses a pseudo-language that marks every text it knows and
# makes it a third longer, so whatever isn't marked is text the tables can't reach yet.
#
#   tools/lang-report.sh          (pseudo-language)
#   tools/lang-report.sh de       (data/lang/de.json)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
lang=${1:-qps}
if [ "$lang" = qps ]; then
    python3 -I "$root/tools/extract_strings.py" --pseudo "$dir/qps.json" > /dev/null
    export ADIFLINT_TEST_LANG_MARKER='⟦'
else
    cp "$root/data/lang/$lang.json" "$dir/"
fi
ADIFLINT_TEST_LANG_REPORT=1 ADIFLINT_TEST_HOST_LANGUAGE="$lang" ADIFLINT_LANG_DIR="$dir" \
    "$root/build/host_harness" "$root/build/ADIFLint.dylib" "$root/tests/fixtures/lookup" | grep -E '^(UNTRANSLATED|OVERLAP)' || true
