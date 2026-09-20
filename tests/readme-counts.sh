#!/bin/bash
# Do the numbers in README.md match what the suites actually report?
#
# Every count in a README is a claim with a short shelf life. Four of them went
# stale here inside two rounds — the acceptance case count, the mutant list, the
# stub server's modes — and none were caught by review, because the file they
# lived in was skipped as "similar to previous changes". A zero finding count
# over a file nobody read says nothing.
#
# So the counts are checked by running the suites and reading their totals,
# rather than by remembering to update prose.
#
#   ./tests/readme-counts.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
README="$ROOT/README.md"
pass=0; fail=0

# Record one check outcome. say ok|no <description>; anything but "ok" counts
# as a failure and makes the script exit non-zero, so a check that forgets to
# report cannot be mistaken for one that passed.
say() { if [ "$1" = ok ]; then pass=$((pass+1)); printf '  ok    %s\n' "$2";
        else fail=$((fail+1)); printf '  FAIL  %s\n' "$2"; fi; }

total() {  # total <suite> -> the number it reports as passed
  bash "$HERE/$1" 2>/dev/null | sed -n 's/^passed \([0-9]*\),.*/\1/p' | tail -1
}

echo "stingray README count checks"

acc=$(total acceptance.sh)
mut=$(total mutants.sh)
[ -n "$acc" ] && [ -n "$mut" ] || { echo "  could not read suite totals"; exit 1; }

# claim <description> <actual> <grep -o pattern picking the number>
claim() {
  local what="$1" actual="$2" pattern="$3" found
  found=$(grep -oE "$pattern" "$README" | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
  if [ -z "$found" ]; then
    say no "$what — no such claim found in README (pattern moved?)"
  elif [ "$(echo "$found" | tr -d ' ')" = "$actual" ]; then
    say ok "$what — README says $actual, suite reports $actual"
  else
    say no "$what — README says '${found% }', suite reports $actual"
  fi
}

claim "acceptance cases (Layout)" "$acc" '[0-9]+ offline cases'
claim "acceptance cases (Tests)"  "$acc" '# [0-9]+ cases, no key'
claim "mutant count"              "$mut" '\([0-9]+ mutants\)'

# The mutant list names the acceptance cases it re-derives; those names have to
# be the ones mutants.sh actually targets, not a list someone forgot to extend.
listed=$(grep -oE 're-derives that cases [0-9, and]+' "$README" | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')
targeted=$(grep -oE '^mutate "[^"]+" "[0-9]+' "$HERE/mutants.sh" | grep -oE '[0-9]+$' | sort -n | tr '\n' ' ')
if [ "$listed" = "$targeted" ]; then
  say ok "mutant case list — README names ${listed% }, mutants.sh targets the same"
else
  say no "mutant case list — README names '${listed% }', mutants.sh targets '${targeted% }'"
fi

# The stub server's modes are documented in the Layout tree; a mode added
# without updating it is the same class of drift.
#
# Ask the program, do not read its docstring. An earlier version scanned the
# usage text, which is prose: a dispatch branch could be renamed or deleted
# while the docstring stayed put, and this check would keep passing on a mode
# that no longer exists. --list-modes prints the tuple dispatch itself uses.
modes=$(python3 "$HERE/stub_server.py" --list-modes 2>/dev/null | tr '\n' ' ')
[ -n "$modes" ] || { echo "  could not list stub server modes"; exit 1; }
missing=""
for m in $modes; do
  grep -qE "stub_server\.py .*$m" "$README" || missing="$missing $m"
done
[ -z "$missing" ] \
  && say ok "stub server modes — README lists all of: ${modes% }" \
  || say no "stub server modes — README omits:$missing"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
