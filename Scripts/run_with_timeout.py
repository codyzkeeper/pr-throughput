#!/usr/bin/env python3
"""Run one command with inherited stdio and terminate its process group on timeout."""

from __future__ import annotations

import math
import os
import signal
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} SECONDS COMMAND [ARG ...]", file=sys.stderr)
        return 64
    try:
        timeout = float(sys.argv[1])
    except ValueError:
        print("timeout must be a number", file=sys.stderr)
        return 64
    if not math.isfinite(timeout) or timeout <= 0:
        print("timeout must be positive", file=sys.stderr)
        return 64

    process = subprocess.Popen(sys.argv[2:], start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"command timed out after {timeout:g}s: {sys.argv[2]}", file=sys.stderr)
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
