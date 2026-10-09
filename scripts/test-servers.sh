#!/usr/bin/env bash
# Runs the live SubsonicKit tests and the UI tests against every server in
# test-servers.local.env (gitignored). Each server is a block of variables:
#
#   NAVIDROME_HOST=https://music.example.com
#   NAVIDROME_USER=someone
#   NAVIDROME_PASSWORD=…
#   NAVIDROME_DOWNLOAD_ALBUM="a small album"        # optional
#   NAVIDROME_LYRICS_ALBUM="…"   # optional: first song has synced lyrics and ReplayGain -6.5 dB
#
#   OWNAUDIO_HOST=https://demo.example.com             # an own.audio server
#   OWNAUDIO_EMAIL=guest@example.com
#   OWNAUDIO_ACCOUNT_PASSWORD=…                        # used to fetch the Subsonic key
#   OWNAUDIO_DOWNLOAD_ALBUM="a small album"           # optional
#
# Usage: scripts/test-servers.sh [navidrome|ownaudio] [--live-only]
# One UI test only: ONLY_TESTING=testPartlyDownloadedAlbumPlaysOffline scripts/test-servers.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source ./test-servers.local.env

SIM="${SIMULATOR_ID:-$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F-]{36}')}"
OUT="${TEST_OUTPUT:-/tmp/subsonic-ios-tests}"
mkdir -p "$OUT"
only="${1:-all}"
live_only="${2:-}"

run() { # name host user password download-album lyrics-album
  local name=$1 host=$2 user=$3 password=$4 album=${5:-} lyrics=${6:-}
  echo "== $name: live client tests"
  (cd Packages/SubsonicKit && SUBSONIC_HOST="$host" SUBSONIC_USER="$user" SUBSONIC_PASSWORD="$password" \
    swift test --filter Live 2>&1 | grep -E "✘|Test run")
  [[ "$live_only" == "--live-only" ]] && return
  echo "== $name: UI tests (screenshots in $OUT/$name)"
  mkdir -p "$OUT/$name"
  xcodegen generate >/dev/null
  TEST_RUNNER_SUBSONIC_HOST="$host" TEST_RUNNER_SUBSONIC_USER="$user" TEST_RUNNER_SUBSONIC_PASSWORD="$password" \
  TEST_RUNNER_SUBSONIC_DOWNLOAD_ALBUM="$album" TEST_RUNNER_SUBSONIC_LYRICS_ALBUM="$lyrics" \
  TEST_RUNNER_SCREENSHOT_DIR="$OUT/$name" \
    xcodebuild test -project OwnAudioSubsonic.xcodeproj -scheme OwnAudioSubsonic -destination "id=$SIM" \
      -derivedDataPath "$OUT/DerivedData" -test-timeouts-enabled YES -default-test-execution-time-allowance 420 \
      ${ONLY_TESTING:+-only-testing:"OwnAudioSubsonicUITests/PlaybackSmokeTests/$ONLY_TESTING"} 2>&1 \
    | grep -E "Test Case.*(passed|failed)|\*\* TEST"
}

if [[ "$only" == all || "$only" == navidrome ]]; then
  run navidrome "$NAVIDROME_HOST" "$NAVIDROME_USER" "$NAVIDROME_PASSWORD" "${NAVIDROME_DOWNLOAD_ALBUM:-}" "${NAVIDROME_LYRICS_ALBUM:-}"
fi

if [[ "$only" == all || "$only" == ownaudio ]]; then
  # own.audio's Subsonic API takes a per-user key, not the account password; a demo server
  # that resets nightly issues a new one each day.
  token=$(curl -sf -A subsonic-ios-tests -X POST "$OWNAUDIO_HOST/api/v1/auth/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$OWNAUDIO_EMAIL\",\"password\":\"$OWNAUDIO_ACCOUNT_PASSWORD\"}" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
  key=$(curl -sf -A subsonic-ios-tests "$OWNAUDIO_HOST/api/v1/users/me/subsonic-key" -H "Authorization: Bearer $token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['api_key'])")
  run ownaudio "$OWNAUDIO_HOST" "$OWNAUDIO_EMAIL" "$key" "${OWNAUDIO_DOWNLOAD_ALBUM:-}"
fi
