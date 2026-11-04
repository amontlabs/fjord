#!/bin/sh
# The Python suite against the Swift core: builds the debug binary, then one pytest run with FJORD_CORE=swift.
# FJORD_SWIFT_BIN=poc/router/tests/fake_bridge.py runs it through the Python stand-in instead (no build).
set -e
cd "$(dirname "$0")/../../.."
[ -n "$FJORD_SWIFT_BIN" ] || swift build
FJORD_CORE=swift exec python3 -m pytest -q poc/router/tests "$@"
