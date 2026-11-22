#!/usr/bin/env python3
"""Aran watchdog.

If the GUI stops touching the heartbeat file (crash, kill -9, compositor exit)
every group Aran had pinned to a specific node is handed back to a kernel-managed
url-test group, so a dead pick can't leave you offline.

Usage: watchdog.py <addr> <secret> <heartbeat> <fallback_group> <group...>
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

TIMEOUT = 30  # seconds without heartbeat before we take over


def put_group(addr, secret, group, node):
    url = f"http://{addr}/proxies/{urllib.parse.quote(group, safe='')}"
    req = urllib.request.Request(
        url,
        data=json.dumps({"name": node}).encode(),
        method="PUT",
        headers={"Authorization": f"Bearer {secret}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5):
        pass


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 1
    addr, secret, hb, fallback = sys.argv[1:5]
    groups = sys.argv[5:]
    while True:
        try:
            age = time.time() - os.stat(hb).st_mtime
        except FileNotFoundError:
            age = 0  # never started yet: not our business
        if age > TIMEOUT:
            for g in groups:
                try:
                    put_group(addr, secret, g, fallback)
                    print(f"[watchdog] {g} -> {fallback}", flush=True)
                except Exception as e:
                    print(f"[watchdog] {g} failed: {e}", flush=True)
        time.sleep(5)


if __name__ == "__main__":
    sys.exit(main())
