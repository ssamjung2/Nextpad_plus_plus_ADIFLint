#!/bin/sh
# The adiflint log tools on the official ADIF test file: each output must lint
# without errors, and CSV must come back as the same number of records.
#   cli_tools.sh ADIFLINT OFFICIAL_ADI WORK_DIR
set -e
lint="$1"; adi="$2"; dir="$3"
rm -rf "$dir" && mkdir -p "$dir/pota"
"$lint" --summary "$adi" > "$dir/summary.txt" 2>/dev/null
grep -q "^Records" "$dir/summary.txt"
"$lint" --sort "$dir/sorted.adi" "$adi" 2>/dev/null
"$lint" --quiet "$dir/sorted.adi" > /dev/null 2>&1
"$lint" --dedupe "$dir/dedupe.adi" "$adi" 2>/dev/null
"$lint" --quiet "$dir/dedupe.adi" > /dev/null 2>&1
"$lint" --csv "$dir/log.csv" "$adi" 2>/dev/null
"$lint" --from-csv "$dir/back.adi" "$dir/log.csv" 2>/dev/null
n1=$("$lint" "$adi" 2>&1 >/dev/null | sed -n 's/.*: \([0-9]*\) record(s).*/\1/p')
n2=$("$lint" "$dir/back.adi" 2>&1 >/dev/null | sed -n 's/.*: \([0-9]*\) record(s).*/\1/p')
[ "$n1" = "$n2" ] || { echo "CSV round trip: $n1 records became $n2"; exit 1; }
"$lint" --cabrillo "$dir/log.cbr" --contest TEST --call K1ABC "$adi" 2>/dev/null
head -1 "$dir/log.cbr" | grep -q "START-OF-LOG: 3.0"
tail -1 "$dir/log.cbr" | grep -q "END-OF-LOG:"
echo "cli tools ok ($n1 records)"
