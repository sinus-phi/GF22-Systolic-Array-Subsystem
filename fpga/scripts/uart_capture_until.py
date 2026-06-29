#!/usr/bin/env python3
"""Capture a raw UART device, print live text, and stop on PASS/FAIL patterns."""

from __future__ import annotations

import argparse
import os
import re
import select
import sys
import termios
import time
import fcntl
from pathlib import Path


BAUD_MAP = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
    230400: termios.B230400,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture UART output live and exit on pass/fail regexes."
    )
    parser.add_argument("--dev", required=True, help="UART device, e.g. /dev/ttyACM0")
    parser.add_argument("--baud", type=int, default=9600, help="UART baud rate")
    parser.add_argument("--timeout", type=float, default=20.0, help="Capture timeout in seconds")
    parser.add_argument("--log", required=True, help="Log file path")
    parser.add_argument("--pass-regex", default=r"TEST PASS", help="Regex that marks success")
    parser.add_argument("--fail-regex", default=r"TEST FAIL", help="Regex that marks failure")
    return parser.parse_args()


def configure_uart(fd: int, baud: int):
    if baud not in BAUD_MAP:
        raise SystemExit(f"unsupported baud: {baud}")

    old_attrs = termios.tcgetattr(fd)
    attrs = termios.tcgetattr(fd)

    attrs[0] &= ~(
        termios.IGNBRK
        | termios.BRKINT
        | termios.PARMRK
        | termios.ISTRIP
        | termios.INLCR
        | termios.IGNCR
        | termios.ICRNL
        | termios.IXON
        | termios.IXOFF
        | termios.IXANY
    )
    attrs[1] &= ~termios.OPOST
    attrs[2] &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)
    attrs[2] |= termios.CS8 | termios.CREAD | termios.CLOCAL
    if hasattr(termios, "CRTSCTS"):
        attrs[2] &= ~termios.CRTSCTS
    attrs[3] &= ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG | termios.IEXTEN)
    attrs[4] = BAUD_MAP[baud]
    attrs[5] = BAUD_MAP[baud]
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0

    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)

    for attr in ("TIOCMBIS", "TIOCM_DTR", "TIOCM_RTS"):
        if not hasattr(termios, attr):
            break
    else:
        modem_bits = termios.TIOCM_DTR | termios.TIOCM_RTS
        fcntl.ioctl(fd, termios.TIOCMBIS, modem_bits.to_bytes(4, sys.byteorder))

    return old_attrs


def normalize_for_terminal(data: bytes) -> str:
    text = data.decode("utf-8", errors="replace")
    text = text.replace("\r\n", "\n")
    return text.replace("\r", "\n")


def main() -> int:
    args = parse_args()
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    fd = os.open(args.dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    old_attrs = configure_uart(fd, args.baud)
    pass_re = re.compile(args.pass_regex)
    fail_re = re.compile(args.fail_regex)
    start = time.monotonic()
    transcript = ""

    try:
      with log_path.open("w", encoding="utf-8", errors="replace") as log_file:
        print(f"[UART] Capturing {args.dev} @ {args.baud} 8N1", flush=True)
        print(f"[UART] Log: {log_path}", flush=True)

        while True:
            remaining = args.timeout - (time.monotonic() - start)
            if remaining <= 0:
                print("\n[UART] TIMEOUT waiting for PASS/FAIL pattern", flush=True)
                return 124

            readable, _, _ = select.select([fd], [], [], min(0.25, remaining))
            if not readable:
                continue

            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                continue

            if not chunk:
                continue

            text = normalize_for_terminal(chunk)
            transcript += text
            log_file.write(text)
            log_file.flush()
            sys.stdout.write(text)
            sys.stdout.flush()

            if fail_re.search(transcript):
                print("\n[UART] FAIL pattern detected", flush=True)
                return 2
            if pass_re.search(transcript):
                print("\n[UART] PASS pattern detected", flush=True)
                return 0
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, old_attrs)
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
