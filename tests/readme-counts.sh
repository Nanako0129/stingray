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
# Both READMEs. A translation is a second home for the same contract, and the
# copy nobody rereads is the one that goes stale.
READMES="$ROOT/README.md $ROOT/README.zh-TW.md"
pass=0; fail=0

# Record one check outcome. say ok|no <description>; anything but "ok" counts
# as a failure and makes the script exit non-zero, so a check that forgets to
# report cannot be mistaken for one that passed.
say() { if [ "$1" = ok ]; then pass=$((pass+1)); printf '  ok    %s\n' "$2";
        else fail=$((fail+1)); printf '  FAIL  %s\n' "$2"; fi; }

total() {  # total <output> -> the number that run reported as passed
  printf '%s\n' "$1" | sed -n 's/^passed \([0-9]*\),.*/\1/p' | tail -1
}

echo "stingray README count checks"

acc_out=$(bash "$HERE/acceptance.sh" 2>/dev/null)
mut_out=$(bash "$HERE/mutants.sh" 2>/dev/null)
acc=$(total "$acc_out")
mut=$(total "$mut_out")
[ -n "$acc" ] && [ -n "$mut" ] || { echo "  could not read suite totals"; exit 1; }

# Assert one numeric claim in every README.
# claim <description> <actual> <grep -oE pattern picking the number>
claim() {
  local what="$1" actual="$2" pattern="$3" f found
  for f in $READMES; do
    found=$(grep -oE "$pattern" "$f" | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
    if [ -z "$found" ]; then
      say no "$what — claim absent from $(basename "$f") (pattern moved?)"
    elif [ "$(echo "$found" | tr -d ' ')" = "$actual" ]; then
      say ok "$what — $(basename "$f") says $actual"
    else
      say no "$what — $(basename "$f") says '${found% }', suite reports $actual"
    fi
  done
}

claim "acceptance cases (Layout)" "$acc" '[0-9]+ (offline cases|個離線案例)'
claim "acceptance cases (Tests)"  "$acc" '# [0-9]+ (cases, no key|個案例，不需 key)'
# Full-width parentheses in the Chinese page are correct typography, so the
# pattern accepts both rather than the translation being bent to fit the check.
claim "mutant count"              "$mut" '[（(][0-9]+ (mutants|個 mutant)[）)]'

# The mutant list names the acceptance cases it re-derives; those names have to
# be the ones mutants.sh actually targets, not a list someone forgot to extend.
targeted=$(printf '%s\n' "$mut_out" \
  | sed -n 's/.*case \([0-9]*\) *fails, as it must.*/\1/p' | sort -n | tr '\n' ' ')
[ -n "$targeted" ] || { echo "  mutants.sh reported no cases; cannot compare"; exit 1; }
for f in $READMES; do
  listed=$(grep -oE '(re-derives that cases|重新推導案例) [0-9, and、和]+' "$f" | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')
  if [ "$listed" = "$targeted" ]; then
    say ok "mutant case list — $(basename "$f") names ${listed% }"
  else
    say no "mutant case list — $(basename "$f") names '${listed% }', mutants.sh targets '${targeted% }'"
  fi
done

# The stub server's modes are documented in the Layout tree; a mode added
# without updating it is the same class of drift.
#
# Ask the program, do not read its docstring. An earlier version scanned the
# usage text, which is prose: a dispatch branch could be renamed or deleted
# while the docstring stayed put, and this check would keep passing on a mode
# that no longer exists. --list-modes prints the tuple dispatch itself uses.
if ! modes_raw=$(python3 "$HERE/stub_server.py" --list-modes 2>/dev/null); then
  echo "  stub_server.py --list-modes exited non-zero"; exit 1
fi
modes=$(printf '%s\n' "$modes_raw" | tr '\n' ' ')
[ -n "${modes// /}" ] || { echo "  stub_server.py --list-modes printed nothing"; exit 1; }
for f in $READMES; do
  missing=""
  for m in $modes; do
    grep -qE "stub_server\.py .*(^|[^A-Za-z0-9_])$m([^A-Za-z0-9_]|$)" "$f" || missing="$missing $m"
  done
  [ -z "$missing" ] \
    && say ok "stub server modes — $(basename "$f") lists all of: ${modes% }" \
    || say no "stub server modes — $(basename "$f") omits:$missing"
done

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
