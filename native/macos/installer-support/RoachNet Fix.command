#!/bin/bash
set -euo pipefail

clear

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PREFERRED_APP_NAME="RoachNet Setup.app"

if [[ -d "$SCRIPT_DIR/$PREFERRED_APP_NAME" ]]; then
  SOURCE_APP="$SCRIPT_DIR/$PREFERRED_APP_NAME"
else
  SOURCE_APP="$(find "$SCRIPT_DIR" -maxdepth 1 -name '*.app' -type d | head -n 1 || true)"
fi

if [[ -z "${SOURCE_APP:-}" || ! -d "$SOURCE_APP" ]]; then
  echo
  echo "RoachNet Fix could not find an app bundle next to this helper."
  echo "Keep this file in the same DMG window as RoachNet Setup.app and run it from there."
  echo
  read -r -p "Press Enter to close."
  exit 1
fi

APP_NAME="$(basename "$SOURCE_APP")"
TARGET_APP="/Applications/$APP_NAME"

echo
echo "RoachNet Fix"
echo "============"
echo
echo "This helper will:"
echo "1. Copy $APP_NAME into /Applications"
echo "2. Remove quarantine flags from the copied app"
echo "3. Open the copied app"
echo
echo "It does not disable Gatekeeper globally."
echo
read -r -p "Press Enter to continue, or Ctrl+C to cancel."

echo
echo "Requesting administrator access for the install copy..."
sudo -v

echo
echo "Installing $APP_NAME into /Applications..."
sudo rm -rf "$TARGET_APP"
sudo ditto "$SOURCE_APP" "$TARGET_APP"

echo "Clearing quarantine metadata..."
sudo xattr -cr "$TARGET_APP" || true
sudo xattr -dr com.apple.quarantine "$TARGET_APP" || true

echo "Opening $APP_NAME..."
open "$TARGET_APP"

echo
echo "RoachNet Setup should be opening from:"
echo "$TARGET_APP"
echo
echo "If macOS still blocks it, open:"
echo "System Settings > Privacy & Security"
echo "and choose Open Anyway for the copied app."
echo
read -r -p "Press Enter to close."
