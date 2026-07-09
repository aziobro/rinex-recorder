# Shared helpers for convert-daily.sh and merge-days.sh. Source, don't run.

# Runs convbin, retrying up to 3 times if it exits 0 but doesn't actually
# produce a non-empty output file. Confirmed empirically (2026-07-09): a
# dot-prefixed (hidden) *input* filename makes convbin exit 0 without ever
# writing output -- see merge-days.sh's COMBINED_RAW for the real fix
# (don't hide the input filename). This retry is just defense-in-depth on
# top of that -- convbin's exit code alone isn't a fully reliable success
# signal, so the output file is checked directly regardless.
#
# Usage: run_convbin_with_retry OUT_FILE LOG_FILE  <convbin args incl. -o OUT_FILE and the input file>
run_convbin_with_retry() {
    local out_file="$1" log_file="$2"
    shift 2
    local attempt
    for attempt in 1 2 3; do
        rm -f "$out_file"
        if "$CONVBIN" "$@" > "$log_file" 2>&1 && [ -s "$out_file" ]; then
            return 0
        fi
        echo "convbin attempt $attempt/3 failed or produced no output, retrying..." >&2
    done
    echo "convbin failed after 3 attempts:" >&2
    tail -20 "$log_file" >&2
    return 1
}
