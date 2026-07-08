# rinex-recorder

Runs on the Raspberry Pi already sitting on the LAN next to the
[gps-base-station](../gps-base-station) device, and independently records a
RINEX observation archive from its RTCM3 stream -- without touching the
device's own outbound push to RTK2go/Onocoy/RTKdata. It's a second, passive
consumer of the base station's **local** NTRIP mountpoint (`BASE0`,
`192.168.8.186:2101`), which already speaks plain unauthenticated NTRIP v1 for
LAN clients.

## Why a separate pipeline, not the device's own RINEX logger

The device already has an on-device RINEX logger (`rinex_logger.cpp`, see
gps-base-station's `docs/agent-memory/project_rinex.md`) that reads raw
receiver output (RANGEA) directly off the UM980. This project is a
**different, independent** path: it reconstructs RINEX from the RTCM3 MSM7
messages already being broadcast for the NTRIP casters, captured over the
network rather than off the receiver's UART. Running both means one doesn't
depend on the other -- e.g. the Pi can record continuously regardless of
whether the device's own RINEX toggle is on, and vice versa.

## Architecture

```
gps-base-station (192.168.8.186:2101/BASE0)
        |  NTRIP v1 (no auth, LAN only)
        v
capture/rtcm_capture.py  ---- continuous, systemd Restart=always
        |  raw bytes, appended, rotated at UTC midnight
        v
raw/rtcm3_YYYYMMDD.bin
        |  scripts/convert-daily.sh (RTKLIB convbin), daily via systemd timer
        v
rinex/YYYYMMDD.obs
```

Capture and conversion are deliberately two separate steps (see "Decisions"
below): the raw archive is never overwritten, so any bug in the conversion
step is recoverable by just re-running it.

## Why RTKLIB for conversion, not for capture

- **Conversion** (RTCM3 -> RINEX) uses `convbin` from
  [RTKLIB](https://github.com/tomojitakasu/RTKLIB) -- hardened, widely-used
  RTCM3 MSM decode and RINEX 3 writer logic, not worth reimplementing.
- **Capture** is just a raw byte copy over a five-line NTRIP v1 handshake (see
  `local_caster.cpp` in gps-base-station: `GET /BASE0 HTTP/1.x` ->
  `ICY 200 OK` -> raw stream). Writing ~100 lines of stdlib-only Python for
  this keeps the file-rotation and reconnect/backoff logic fully in our
  control instead of depending on `str2str`'s own file-output flag semantics
  (which have subtleties around append-vs-truncate on restart that we'd
  rather not get wrong on unattended, unattended-for-months capture).

## No RTCM ephemeris -> no RINEX nav file, and that's fine

The base station does not broadcast RTCM ephemeris messages (1019/1020/1042
etc. -- see gps-base-station's `project_um980_config.md`, "ALLEPHRTCM"), so
`convbin` will only ever produce a RINEX **observation** file here, never a
matching nav file. This matches the existing on-device RINEX pipeline, which
submits obs-only files to OPUS/CSRS-PPP successfully (90% ambiguity fix per
`project_rinex.md`) -- both services fetch broadcast/precise ephemeris
themselves and don't require you to supply it.

## Setup (Raspberry Pi)

1. Build `convbin` (only piece of RTKLIB we need):
   ```
   git clone --depth 1 https://github.com/tomojitakasu/RTKLIB.git
   cd RTKLIB/app/convbin/gcc && make
   sudo cp convbin /usr/local/bin/
   ```
2. `cp config.env.sample config.env` and edit paths/antenna metadata.
3. Install the systemd units (paths in them assume `/home/aziobro/rinex-recorder`
   -- adjust if deployed elsewhere):
   ```
   sudo cp systemd/*.service systemd/*.timer /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now rinex-capture.service
   sudo systemctl enable --now rinex-convert.timer
   ```
4. Verify capture is receiving data:
   ```
   sudo systemctl status rinex-capture.service
   ls -la raw/
   ```
5. Verify conversion (don't wait for the timer -- run it directly against a
   completed day's file):
   ```
   scripts/convert-daily.sh 20260707
   ```

## Decisions made and why

- **RTKLIB (`convbin`) for RTCM3 decode / RINEX write, not a custom parser.**
  Battle-tested, avoids reimplementing CRC24Q and MSM signal-ID tables.
- **Archive raw RTCM3 first, convert on a timer -- not real-time
  direct-to-RINEX.** Mirrors the serial-logger pattern already used on this
  same Pi for gps-base-station: capture reliability shouldn't depend on the
  converter being bug-free. If `convbin`'s output is ever wrong, the raw
  bytes are still there to reprocess.
- **30-second RINEX epochs (`EPOCH_INTERVAL_SEC`), not the raw 1Hz capture
  rate.** Matches gps-base-station's on-device `rinex_logger.cpp`
  (`kEpochInterval = 30`) and the standard CORS/IGS static-observation rate --
  keeps output files consistent between the two independent RINEX pipelines
  and ~30x smaller. The raw archive stays at full 1Hz in case finer
  resolution is ever needed later; only the converted `.obs` output is
  thinned. Decimation is done by `scripts/decimate_rinex.py` against
  convbin's full-rate text output, not convbin's own `-ti` flag -- see
  "convbin's `-ti 30` produces zero epochs" below.

## Known issue: convbin's `-ti 30` silently produces zero epochs

Empirically (2026-07-08, RTKLIB convbin 2.4.2), running `convbin -ti 30`
against this project's captured RTCM3 data produces a RINEX file with **zero
observation epochs** -- `-ti 10/15/20/25` all work fine, `-ti 30` specifically
doesn't (with or without `-scan` first). Rather than depend on that
undocumented, version-specific behavior, `convert-daily.sh` runs `convbin`
at full rate and decimates the resulting plain-text RINEX body itself
(`scripts/decimate_rinex.py`), where the epoch-keep rule is fully ours to see
and test. If a future RTKLIB version fixes this, it'd be reasonable to drop
the post-processing step and pass `-ti` directly again -- just re-verify
against real data first, the same way this was found.

## Requires gps-base-station ota142+

Earlier firmware had a bug where `LocalCaster`'s internal broadcast queue
(4 deep) would overflow roughly every 30 seconds -- exactly when the 5s/10s/
30s periodic RTCM messages converged with the 1Hz MSM7 burst in the same
batch window -- and respond by force-disconnecting **every** connected local
NTRIP client, not just dropping the excess packet. This capture client's
continuous connection is what surfaced the bug (previous local clients were
only ever connected briefly). Fixed in gps-base-station ota142 (see its
`docs/agent-memory/project_ntrip.md`); against ota141 and earlier, expect
frequent "Connection reset by peer" reconnects and systematically missing
`:00`/`:30`-second epochs.
