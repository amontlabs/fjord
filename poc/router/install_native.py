#!/usr/bin/env python3
"""Registers native_host.py with Chrome for the Router POC extension. Run it once; it changes nothing else."""
import json
import os
import stat
import sys

EXTENSION_ID = "ecdmddbjdlfhkbljpagofhajaldgajaa"
NAME = "dev.fjord.router"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
WRAPPER = os.path.join(ROOT, ".build", "router-poc", "native-host")
MANIFEST = os.path.expanduser(f"~/Library/Application Support/Google/Chrome/NativeMessagingHosts/{NAME}.json")


def main(extension_id=EXTENSION_ID):
    os.makedirs(os.path.dirname(WRAPPER), exist_ok=True)
    with open(WRAPPER, "w") as out:
        out.write(f'#!/bin/sh\nexec "{sys.executable}" "{os.path.join(HERE, "native_host.py")}"\n')
    os.chmod(WRAPPER, os.stat(WRAPPER).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    manifest = {
        "name": NAME,
        "description": "Fjord Router POC: relays the claude.ai page's events to routerd.",
        "path": WRAPPER,
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{extension_id}/"],
    }
    with open(MANIFEST, "w") as out:
        json.dump(manifest, out, indent=2)
        out.write("\n")
    print(MANIFEST)
    print(WRAPPER)


if __name__ == "__main__":
    main(*sys.argv[1:2])
