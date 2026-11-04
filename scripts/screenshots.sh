#!/usr/bin/env bash
# Captures screenshots of a Debug build in a booted simulator (used by the Screenshots workflow).
# Usage: UDID=<simulator> scripts/screenshots.sh path/to/SuperOTP.app
set -euo pipefail
APP="$1"
BID=app.superotp
OUT=screenshots
mkdir -p "$OUT"

fresh() {
  xcrun simctl uninstall "$UDID" "$BID" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP"
}

shot() {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BID" "$@" >/dev/null
  sleep "${WAIT:-6}"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null
  echo "captured $name"
}

fresh
shot 01-empty
shot 02-home -demoData YES -hideCodes NO
shot 03-home-hidden -demoData YES -hideCodes YES
shot 04-home-dark -demoData YES -hideCodes NO -theme dark
shot 05-select -demoData YES -hideCodes NO -screen select
shot 06-edit -demoData YES -screen edit
shot 07-import -demoData YES -screen import
shot 08-settings -demoData YES -screen settings
shot 09-backup -demoData YES -screen backup
shot 10-groups -demoData YES -screen groups
shot 11-home-zh -demoData YES -hideCodes NO -AppleLanguages "(zh-Hans)" -AppleLocale zh_CN
shot 12-settings-zh -demoData YES -screen settings -AppleLanguages "(zh-Hans)" -AppleLocale zh_CN
shot 13-import-zh -demoData YES -screen import -AppleLanguages "(zh-Hans)" -AppleLocale zh_CN
shot 14-lock -demoData YES -appLock YES -noAutoPrompt YES
