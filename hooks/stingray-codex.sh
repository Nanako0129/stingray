#!/bin/bash
# Run the existing Stingray implementation with Codex's Stop payload, then
# translate Stingray's blocking exit into Codex's explicit JSON response.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null 2>&1 || {
  echo "(stingray: unavailable — jq not found)" >&2
  exit 0
}

input=$(cat)

# Git for Windows keeps shasum outside the non-login PATH. Convert Codex's
# native plugin-data path once so shell tools all receive the same POSIX path.
if ! command -v shasum >/dev/null 2>&1 && [ -x /usr/bin/core_perl/shasum ]; then
  export PATH="/usr/bin/core_perl:$PATH"
fi
plugin_data="${PLUGIN_DATA:-}"
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if [ -n "$plugin_data" ] && command -v cygpath >/dev/null 2>&1; then
      plugin_data=$(cygpath -u "$plugin_data") || exit 0
      mkdir -p "$plugin_data" 2>/dev/null || exit 0
      export TMPDIR="$plugin_data"
    fi
    ;;
esac

# Plugin state belongs outside the immutable install/cache directory.
if [ -n "$plugin_data" ] && [ -z "${STINGRAY_STATE_DIR:-}" ]; then
  export STINGRAY_STATE_DIR="$plugin_data"
fi

err=$(mktemp) || exit 0
trap 'rm -f "$err"' EXIT
# Keep the shared Claude hook byte-for-byte unchanged. Windows jq can emit
# non-ASCII JSON through the active code page, so only Codex's two JSON-producing
# invocations use ASCII escapes before the payload and question hash are built.
printf '%s' "$input" | (
  jq() {
    case "${1:-}" in
      -cn) shift; command jq -acn "$@" ;;
      -cS) shift; command jq -acS "$@" ;;
      *) command jq "$@" ;;
    esac
  }
  . "$HERE/stingray.sh"
) 2>"$err"
status=$?

if [ "$status" = 2 ]; then
  reason=$(cat "$err")
  jq -cn --arg reason "$reason" '{decision:"block", reason:$reason}'
  exit 0
fi

cat "$err" >&2
exit "$status"
