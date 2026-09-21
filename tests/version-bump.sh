#!/usr/bin/env bash
# Fail a pull request that changes shipped plugin content without bumping the
# version in .claude-plugin/plugin.json.
#
# Why this is a guard and not a convention: `claude plugin update` compares the
# version string and nothing else. Measured 2026-09-21 on this repository — a
# local cache of 0.1.0 sat behind main, `plugin marketplace update` refreshed
# the clone, and `plugin update` still answered "stingray is already at the
# latest version (0.1.0)". Only uninstall + reinstall recovered it. So a hook
# change shipped under an unchanged version does not reach any existing
# install, and the tool reports success while it happens.
#
# Scope is everything an install actually receives: the hook, the question set,
# and the manifest itself. The manifest is included because the plugin manager
# shows its metadata and refreshes it on the same version-pinned path, so a
# description edit under an unchanged version is stale for the same reason a
# hook edit is. A README or workflow change ships nothing and needs no bump; a
# guard firing on those would be edited around rather than obeyed.
set -uo pipefail

BASE="${1:-}"
[ -n "$BASE" ] || { echo "usage: $0 <base-ref>" >&2; exit 2; }

# An unresolvable base ref makes git diff fail with empty stdout, which is
# indistinguishable from "nothing changed" unless the status is read. Silently
# skipping the check is the failure direction this guard exists to prevent.
if ! changed=$(git diff --name-only "$BASE"...HEAD -- \
     .claude-plugin/plugin.json hooks questions.json); then
  echo "version-bump: cannot resolve base ref '$BASE'" >&2
  exit 2
fi

if [ -z "$changed" ]; then
  echo "version-bump: no shipped file changed; no bump required"
  exit 0
fi

head_v=$(jq -r '.version // empty' .claude-plugin/plugin.json 2>/dev/null)
base_v=$(git show "$BASE:.claude-plugin/plugin.json" 2>/dev/null | jq -r '.version // empty')

if [ -z "$head_v" ]; then
  echo "version-bump: .claude-plugin/plugin.json has no .version" >&2
  exit 1
fi

if [ "$head_v" = "$base_v" ]; then
  echo "version-bump: FAIL" >&2
  echo "  shipped files changed:" >&2
  printf '    %s\n' $changed >&2
  echo "  version is still $head_v on both sides." >&2
  echo "  Bump .claude-plugin/plugin.json; otherwise every existing install" >&2
  echo "  keeps the old code and 'claude plugin update' reports it as current." >&2
  exit 1
fi

echo "version-bump: OK ($base_v -> $head_v) for:"
printf '  %s\n' $changed
