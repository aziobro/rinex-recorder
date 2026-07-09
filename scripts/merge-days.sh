#!/usr/bin/env bash
# Merges multiple days' raw RTCM3 archives into one multi-day RINEX 3.03
# observation file -- for longer OPUS/CSRS-PPP sessions than a single day
# gives you (longer static sessions generally resolve more ambiguities and
# tighten the solution). Usage:
#   scripts/merge-days.sh 20260708 20260712
# merges every day in [START, END] inclusive that has a raw file, skipping
# (with a warning) any day that doesn't.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/../config.env" ] && source "$SCRIPT_DIR/../config.env"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

RAW_DIR="${RAW_DIR:-/home/aziobro/rinex-recorder/raw}"
RINEX_DIR="${RINEX_DIR:-/home/aziobro/rinex-recorder/rinex}"
CONVBIN="${CONVBIN:-convbin}"

ANT_TYPE="${ANT_TYPE:-HXCGPS500 NONE}"
ANT_DELTA="${ANT_DELTA:-0/0/0}"
MARKER_NAME="${MARKER_NAME:-BASE0}"
EPOCH_INTERVAL_SEC="${EPOCH_INTERVAL_SEC:-30}"

START="${1:?usage: merge-days.sh START_YYYYMMDD END_YYYYMMDD}"
END="${2:?usage: merge-days.sh START_YYYYMMDD END_YYYYMMDD}"

FILES=()
MISSING=()
d="$START"
while [ "$d" -le "$END" ]; do
    f="$RAW_DIR/rtcm3_${d}.bin"
    if [ -f "$f" ]; then
        FILES+=("$f")
    else
        MISSING+=("$d")
    fi
    d="$(date -u -d "${d} +1 day" +%Y%m%d)"
done

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "no raw files found for $START..$END" >&2
    exit 1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "warning: no raw file for: ${MISSING[*]} -- merging the rest" >&2
fi

mkdir -p "$RINEX_DIR"

OUT_FILE="$RINEX_DIR/merged_${START}_${END}.obs"
# COMBINED_RAW's filename must NOT start with a dot. Confirmed empirically
# (2026-07-09), isolated by bisecting every other variable (tmpfs vs real
# disk, function call vs top-level command, retry count, file size): a
# dot-prefixed (hidden) input filename makes convbin exit 0 without
# producing any output, 100% reproducibly, while the identical operation
# against a non-hidden filename has never once failed. Whatever convbin's
# internal reason is, this is the actual trigger -- don't reintroduce a
# leading dot here. Lives on tmpfs (/tmp) rather than RAW_DIR mainly to
# avoid the extra disk write for a large short-lived temp file; ~1.9GB
# available (df -h /tmp), fine for a several-day merge.
COMBINED_RAW="$(mktemp "/tmp/rinex-merge_${START}_${END}_XXXXXX.bin")"
FULL_RATE_FILE="$(mktemp "${RINEX_DIR}/.fullrate_${START}_${END}_XXXXXX.obs")"
CONVBIN_LOG="$(mktemp "${RINEX_DIR}/.convbin_${START}_${END}_XXXXXX.log")"
trap 'rm -f "$COMBINED_RAW" "$FULL_RATE_FILE" "$CONVBIN_LOG"' EXIT

# Plain concatenation is safe here: RTCM3 frames are self-delimiting
# (preamble + length + CRC24Q), so convbin's streaming decoder resyncs on
# the next valid frame if a rotation happened to split one across the
# UTC-midnight file boundary -- worst case, one frame (a few hundred
# bytes) is silently dropped at each day seam.
cat "${FILES[@]}" > "$COMBINED_RAW"

run_convbin_with_retry "$FULL_RATE_FILE" "$CONVBIN_LOG" \
    -r rtcm3 -v 3.03 \
    -hm "$MARKER_NAME" \
    -ha "$ANT_TYPE" \
    -hd "$ANT_DELTA" \
    -od -os \
    -o "$FULL_RATE_FILE" \
    "$COMBINED_RAW"

"$SCRIPT_DIR/decimate_rinex.py" "$EPOCH_INTERVAL_SEC" "$FULL_RATE_FILE" "$OUT_FILE"

echo "merged ${#FILES[@]} day(s) ($START..$END) -> $OUT_FILE"
