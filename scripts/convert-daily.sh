#!/usr/bin/env bash
# Converts one day's raw RTCM3 archive into a RINEX 3.03 observation file
# using RTKLIB's convbin. Run via systemd/rinex-convert.timer (yesterday's
# file, once it's stopped being appended to) or manually:
#   scripts/convert-daily.sh 20260708
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/../config.env" ] && source "$SCRIPT_DIR/../config.env"

RAW_DIR="${RAW_DIR:-/home/aziobro/rinex-recorder/raw}"
RINEX_DIR="${RINEX_DIR:-/home/aziobro/rinex-recorder/rinex}"
CONVBIN="${CONVBIN:-convbin}"

# Antenna metadata -- keep in sync with the base station's own /config page
# (see gps-base-station docs/agent-memory/project_rinex.md) so files from
# both pipelines describe the same physical setup.
ANT_TYPE="${ANT_TYPE:-HXCGPS500 NONE}"
ANT_DELTA="${ANT_DELTA:-0/0/0}"
MARKER_NAME="${MARKER_NAME:-BASE0}"

DATESTAMP="${1:?usage: convert-daily.sh YYYYMMDD}"
IN_FILE="$RAW_DIR/rtcm3_${DATESTAMP}.bin"
OUT_FILE="$RINEX_DIR/${DATESTAMP}.obs"

if [ ! -f "$IN_FILE" ]; then
    echo "no raw file for $DATESTAMP: $IN_FILE" >&2
    exit 1
fi

mkdir -p "$RINEX_DIR"

"$CONVBIN" -r rtcm3 -v 3.03 \
    -hm "$MARKER_NAME" \
    -ha "$ANT_TYPE" \
    -hd "$ANT_DELTA" \
    -od -os \
    -o "$OUT_FILE" \
    "$IN_FILE"

echo "wrote $OUT_FILE"
