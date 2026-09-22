# Sourced by the suites that drive the hook. Sets HOOK_SH to the interpreter
# hooks.json runs the hook with, so the tests exercise what ships.
#
# The suites used to run the hook as `bash "$HOOK"`, which is whichever bash is
# first on PATH. On macOS that is usually Homebrew's 5.x while hooks.json names
# /bin/bash, which is 3.2 — so the interpreter every macOS install actually uses
# had never been under test. Read from hooks.json rather than written here, so a
# change to the shipped command is followed instead of silently diverged from.
HOOK_SH=$(jq -r '.hooks.Stop[0].hooks[0].command' "$HERE/../hooks/hooks.json" 2>/dev/null | awk '{print $1}')
if [ ! -f "${HOOK_SH:-}" ] || [ ! -x "$HOOK_SH" ]; then
  echo "cannot take the hook interpreter from hooks/hooks.json (got '${HOOK_SH:-}')" >&2
  exit 2
fi
# Run it once here, so an interpreter that cannot execute fails the suite with
# this message instead of failing every case with a different one. The single
# quotes are deliberate: $BASH_VERSION is expanded by HOOK_SH, not by this shell.
if ! HOOK_SH_VERSION=$("$HOOK_SH" -c 'echo "$BASH_VERSION"' 2>/dev/null); then
  echo "cannot execute the hook interpreter from hooks/hooks.json (got '$HOOK_SH')" >&2
  exit 2
fi
