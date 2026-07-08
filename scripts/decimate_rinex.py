#!/usr/bin/env python3
"""Thins a RINEX 3 observation file to one epoch every N seconds.

Exists because RTKLIB convbin's own -ti decimation flag was found to
silently produce zero epochs for -ti 30 specifically (10/15/20/25 all work)
against this project's captured RTCM3 data -- see README "Decisions". Rather
than depend on that undocumented, version-specific behavior, decimation is
done here against the plain-text RINEX body, where the epoch-keep rule is
fully ours to see and test.
"""
import sys

USAGE = "usage: decimate_rinex.py <interval_sec> <in_file> <out_file>"


def epoch_seconds_of_day(header_line: str) -> float:
    # "> 2026  7  8 14 16 41.0000000  0 33 ..."
    fields = header_line[1:].split()
    hh, mm, ss = int(fields[3]), int(fields[4]), float(fields[5])
    return hh * 3600 + mm * 60 + ss


def decimate(interval: int, in_path: str, out_path: str) -> None:
    with open(in_path, "r") as src, open(out_path, "w") as dst:
        in_header = True
        keep_epoch = True
        for line in src:
            if in_header:
                dst.write(line)
                # RINEX header lines are space-padded to column 80, so the
                # label never sits at the true end of the line -- must
                # search for it, not anchor on endswith().
                if "END OF HEADER" in line:
                    in_header = False
                continue
            if line.startswith(">"):
                seconds = epoch_seconds_of_day(line)
                keep_epoch = abs(round(seconds) % interval) == 0
            if keep_epoch:
                dst.write(line)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(USAGE, file=sys.stderr)
        sys.exit(1)
    decimate(int(sys.argv[1]), sys.argv[2], sys.argv[3])
