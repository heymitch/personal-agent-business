#!/usr/bin/env bash
# ============================================================================
# setup.sh -- Launch the Personal Agent Business setup dashboard (localhost).
#
# Usage:
#   ./scripts/setup.sh
#
# Opens a local web page to guide you through filling .env. It binds to
# 127.0.0.1 only, mints a one-time token, and prints the tokened URL as
# SETUP_URL=...  Nothing leaves your machine.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
COCKPIT_DIR="$(cd "$HERE/.." && pwd)"
SETUP_UI="$COCKPIT_DIR/setup-ui"

# ---- Heads-up: provisioning tools check (non-blocking) ---------------------
_missing_tools=""
for _tool in jq ssh curl; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    _missing_tools="${_missing_tools:+$_missing_tools, }$_tool"
  fi
done
if [ -n "$_missing_tools" ]; then
  echo ""
  echo "Heads-up: the provisioning and deploy steps later will need jq, ssh, and curl."
  echo "Missing: $_missing_tools"
  echo "  On macOS:   brew install jq  (ssh and curl are built in)"
  echo "  On Windows: install Git for Windows (https://git-scm.com/downloads/win)"
  echo "              which includes all of them."
  echo ""
fi
unset _missing_tools _tool

# ---- Require python3 -------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "ERROR: python3 is not installed (or not on PATH)." >&2
  echo ""
  echo "On macOS: run this in your terminal to install Xcode Command Line Tools," >&2
  echo "which includes python3:" >&2
  echo ""
  echo "  xcode-select --install" >&2
  echo ""
  echo "After it finishes, close and reopen your terminal, then run setup.sh again." >&2
  echo ""
  exit 1
fi

# ---- Check setup-ui files exist --------------------------------------------
if [ ! -f "$SETUP_UI/server.py" ] || [ ! -f "$SETUP_UI/index.html" ]; then
  echo "ERROR: setup-ui/ files missing in $SETUP_UI" >&2
  echo "Make sure server.py and index.html are both present." >&2
  exit 1
fi

# ---- Launch the server and capture the URL ---------------------------------
echo ""
echo "Starting the Personal Agent Business setup dashboard..."
echo ""

# Export COCKPIT_DIR so the server writes .env to the right place
export COCKPIT_DIR

# Run python3 in the setup-ui dir; capture stdout line-by-line for the URL
SETUP_URL=""

python3 "$SETUP_UI/server.py" 2>&1 | while IFS= read -r line; do
  echo "$line"
  if [[ "$line" == SETUP_URL=* ]]; then
    SETUP_URL="${line#SETUP_URL=}"
    echo "Open this URL in your browser: $SETUP_URL"
    # Try to auto-open based on platform
    if command -v open >/dev/null 2>&1; then
      open "$SETUP_URL" || true
    elif command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$SETUP_URL" || true
    elif command -v cygstart >/dev/null 2>&1; then
      cygstart "$SETUP_URL" || true
    elif [ -n "${WINDIR:-}" ] || [ -n "${windir:-}" ]; then
      cmd.exe //c start "" "$SETUP_URL" || true
    fi
  fi
done

echo ""
echo "Setup server stopped."
