#!/usr/bin/env python3
"""Connects to an NTRIP v1 caster and appends the raw RTCM3 byte stream to
date-stamped files, reconnecting with backoff on any failure.

Decoding/RINEX conversion is intentionally NOT done here -- see
scripts/convert-daily.sh (uses RTKLIB's convbin). This script only needs to
speak the minimal NTRIP v1 handshake, so it has no external dependencies.
"""
import datetime
import logging
import os
import signal
import socket
import sys
import time

HOST = os.environ.get("NTRIP_HOST", "192.168.8.186")
PORT = int(os.environ.get("NTRIP_PORT", "2101"))
MOUNTPOINT = os.environ.get("NTRIP_MOUNTPOINT", "BASE0")
RAW_DIR = os.environ.get("RAW_DIR", "/home/aziobro/rinex-recorder/raw")

CONNECT_TIMEOUT_SEC = 10
RECV_TIMEOUT_SEC = 30  # local LAN link; the base station sends >=1 msg/sec
RECV_CHUNK = 4096
BACKOFF_BASE_SEC = 2
BACKOFF_MAX_SEC = 60

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("rtcm_capture")

_running = True


def _handle_signal(signum, _frame):
    global _running
    log.info("received signal %d, shutting down", signum)
    _running = False


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


def current_raw_path() -> str:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d")
    return os.path.join(RAW_DIR, f"rtcm3_{stamp}.bin")


def connect() -> socket.socket:
    sock = socket.create_connection((HOST, PORT), timeout=CONNECT_TIMEOUT_SEC)
    sock.settimeout(RECV_TIMEOUT_SEC)
    request = (
        f"GET /{MOUNTPOINT} HTTP/1.1\r\n"
        f"User-Agent: rinex-recorder/1.0\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    )
    sock.sendall(request.encode("ascii"))
    # The caster replies "ICY 200 OK\r\n\r\n" immediately, then starts
    # streaming raw RTCM3 -- read just enough to see the reply header before
    # treating everything else as stream data.
    reply = sock.recv(512)
    if b"ICY 200" not in reply:
        sock.close()
        raise ConnectionError(f"unexpected caster reply: {reply[:200]!r}")
    return sock


def stream_to_disk() -> None:
    os.makedirs(RAW_DIR, exist_ok=True)
    backoff = BACKOFF_BASE_SEC
    while _running:
        try:
            sock = connect()
        except OSError as exc:
            log.warning("connect failed: %s (retry in %ds)", exc, backoff)
            time.sleep(backoff)
            backoff = min(backoff * 2, BACKOFF_MAX_SEC)
            continue

        log.info("connected to %s:%d/%s", HOST, PORT, MOUNTPOINT)
        backoff = BACKOFF_BASE_SEC
        bytes_this_connection = 0
        path = current_raw_path()
        out = open(path, "ab")
        log.info("writing to %s", path)
        try:
            while _running:
                new_path = current_raw_path()
                if new_path != path:
                    out.close()
                    path = new_path
                    out = open(path, "ab")
                    log.info("rotated to %s", path)
                try:
                    chunk = sock.recv(RECV_CHUNK)
                except socket.timeout:
                    raise ConnectionError(
                        f"no data for {RECV_TIMEOUT_SEC}s"
                    ) from None
                if not chunk:
                    raise ConnectionError("caster closed connection")
                out.write(chunk)
                out.flush()
                bytes_this_connection += len(chunk)
        except (ConnectionError, OSError) as exc:
            log.warning(
                "disconnected after %d bytes: %s", bytes_this_connection, exc
            )
        finally:
            out.close()
            sock.close()

        if _running:
            time.sleep(backoff)
            backoff = min(backoff * 2, BACKOFF_MAX_SEC)

    log.info("stopped")


if __name__ == "__main__":
    stream_to_disk()
