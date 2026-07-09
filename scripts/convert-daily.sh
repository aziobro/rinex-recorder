#!/usr/bin/env bash
# Converts one day's raw RTCM3 archive into a RINEX 3.03 observation file
# using RTKLIB's convbin. Run via systemd/rinex-convert.timer (yesterday's
# file, once it's stopped being appended to) or manually:
#   scripts/convert-daily.sh 20260708
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/../config.env" ] && source "$SCRIPT_DIR/../config.env"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

RAW_DIR="${RAW_DIR:-/home/aziobro/rinex-recorder/raw}"
RINEX_DIR="${RINEX_DIR:-/home/aziobro/rinex-recorder/rinex}"
CONVBIN="${CONVBIN:-convbin}"

# Antenna metadata -- keep in sync with the base station's own /config page
# (see gps-base-station docs/agent-memory/project_rinex.md) so files from
# both pipelines describe the same physical setup.
ANT_TYPE="${ANT_TYPE:-HXCGPS500 NONE}"
ANT_DELTA="${ANT_DELTA:-0/0/0}"
MARKER_NAME="${MARKER_NAME:-BASE0}"

# Our capture is 1Hz (MSM7 broadcast at ONTIME 1), but the archive should
# match the on-device RINEX pipeline's epoch spacing -- gps-base-station's
# rinex_logger.cpp uses kEpochInterval=30 (RANGEA logged at ONTIME 30), the
# standard CORS/IGS static-observation rate. raw/ keeps the full 1Hz stream
# regardless -- only the converted output is thinned.
#
# NOT done via convbin's own -ti flag: empirically, -ti 30 against this
# project's captured data silently produces a RINEX file with zero epochs
# (10/15/20/25 all work fine -- isolated to exactly 30). Decimating our own
# plain-text RINEX body post-conversion avoids depending on that undocumented,
# version-specific behavior.
EPOCH_INTERVAL_SEC="${EPOCH_INTERVAL_SEC:-30}"

DATESTAMP="${1:?usage: convert-daily.sh YYYYMMDD}"
IN_FILE="$RAW_DIR/rtcm3_${DATESTAMP}.bin"
OUT_FILE="$RINEX_DIR/${DATESTAMP}.obs"

if [ ! -f "$IN_FILE" ]; then
    echo "no raw file for $DATESTAMP: $IN_FILE" >&2
    exit 1
fi

mkdir -p "$RINEX_DIR"

FULL_RATE_FILE="$(mktemp "${RINEX_DIR}/.fullrate_${DATESTAMP}_XXXXXX.obs")"
CONVBIN_LOG="$(mktemp "${RINEX_DIR}/.convbin_${DATESTAMP}_XXXXXX.log")"
trap 'rm -f "$FULL_RATE_FILE" "$CONVBIN_LOG"' EXIT

run_convbin_with_retry "$FULL_RATE_FILE" "$CONVBIN_LOG" \
    -r rtcm3 -v 3.03 \
    -hm "$MARKER_NAME" \
    -ha "$ANT_TYPE" \
    -hd "$ANT_DELTA" \
    -od -os \
    -o "$FULL_RATE_FILE" \
    "$IN_FILE"

"$SCRIPT_DIR/decimate_rinex.py" "$EPOCH_INTERVAL_SEC" "$FULL_RATE_FILE" "$OUT_FILE"

echo "wrote $OUT_FILE"
