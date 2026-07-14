#!/bin/bash
# Submit a file to Apple notarization, poll to completion, staple.
#
#   APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_SPECIFIC_PASSWORD=... \
#     scripts/notarize.sh <file.dmg|file.zip> [staple-target]
#
# staple-target defaults to the submitted file (right for dmg/pkg; pass the
# .app path when submitting a zip of it — zips can't be stapled).
# Polls with fresh connections instead of `--wait`: a single long-lived
# session dies to transient runner network flakes.
set -euo pipefail

FILE="$1"
STAPLE_TARGET="${2:-$1}"
AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")

SUBMIT=$(xcrun notarytool submit "$FILE" "${AUTH[@]}" --output-format json)
echo "$SUBMIT"
SUBMISSION_ID=$(echo "$SUBMIT" | jq -r '.id // empty')
[ -n "$SUBMISSION_ID" ] || { echo "Submission failed — no id returned" >&2; exit 1; }

STATUS="In Progress"
DEADLINE=$((SECONDS + 3300))   # ~55 min
while [ $SECONDS -lt $DEADLINE ]; do
  sleep 30
  INFO=$(xcrun notarytool info "$SUBMISSION_ID" "${AUTH[@]}" --output-format json 2>&1) || {
    echo "poll error (transient, retrying): $INFO"
    continue
  }
  STATUS=$(echo "$INFO" | jq -r '.status // "unknown"')
  echo "status: $STATUS ($((SECONDS / 60))m elapsed)"
  [ "$STATUS" = "In Progress" ] || break
done

# Always fetch Apple's detailed log — it names the exact issues on rejection.
xcrun notarytool log "$SUBMISSION_ID" "${AUTH[@]}" || true

[ "$STATUS" = "Accepted" ] || { echo "Notarization not accepted (status: $STATUS)" >&2; exit 1; }
xcrun stapler staple "$STAPLE_TARGET"
