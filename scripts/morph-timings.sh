#!/bin/bash
# The window's open and close timings from the app's own signposts, without Instruments: plays a motion script on demo
# data (`--demo <scenario> --motion-script <steps> --quit-after`, the app quits by itself), then reads the run's signposts
# (subsystem com.amontlabs.fjord) from the unified log and prints, per interval name, how many, p50, p95 and the longest,
# in ms. Nothing is recorded to disk but the log the system keeps anyway. The app takes the screen and focus for the
# length of the script (some 1.5 s per step): no typing meanwhile.
#
#   scripts/morph-timings.sh                                       release build, "open,close x10" on busy
#   scripts/morph-timings.sh --bin /tmp/fjord-before/.build/release/Fjord --steps "open,close x6"
#   scripts/morph-timings.sh --json out.json                       also write the summary as JSON
#   scripts/morph-timings.sh --args "--window --router-v2-load --quit-after"
#                                                                  runs the build with those flags instead of the motion
#                                                                  script (they must make it quit by itself), and reads the
#                                                                  same signposts: the Router's ("router: T3 event", "Key",
#                                                                  "Flush"…) among them
set -u
cd "$(dirname "$0")/.." || exit 2

bin=.build/release/Fjord
scenario=busy
steps="open,close x10"
json=
args=
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || { echo "morph-timings: $1 needs a value"; exit 2; }
    case "$1" in
        --bin) bin=$2 ;;
        --scenario) scenario=$2 ;;
        --steps) steps=$2 ;;
        --json) json=$2 ;;
        --args) args=$2 ;;
        *) echo "morph-timings: unknown argument '$1' (--bin, --scenario, --steps, --json, --args)"; exit 2 ;;
    esac
    shift 2
done
[ -x "$bin" ] || { echo "morph-timings: no binary at $bin (swift build -c release)"; exit 2; }

start=$(date '+%Y-%m-%d %H:%M:%S')
sleep 1
if [ -n "$args" ]; then
    # shellcheck disable=SC2086 # the flags are words
    "$bin" $args > /dev/null 2>&1 &
else
    "$bin" --demo "$scenario" --motion-script "$steps" --quit-after > /dev/null 2>&1 &
fi
pid=$!
wait "$pid"
sleep 1

log show --start "$start" --signpost --style compact \
    --predicate "subsystem == \"com.amontlabs.fjord\" AND processID == $pid" 2>/dev/null |
    python3 -I -c "$(cat <<'PY'
import re, sys, json
from datetime import datetime
line = re.compile(r"^(\S+ \S+) .*\[com\.amontlabs\.fjord:(\w+)\] \[spid (\S+), \w+,\s+(begin|end)\] (.+?)\s*$")
open_, spans = {}, {}
for raw in sys.stdin:
    m = line.match(raw)
    if not m: continue
    when = datetime.strptime(m[1], "%Y-%m-%d %H:%M:%S.%f").timestamp() * 1000
    key = m[2] + ": " + m[5].split(" (")[0]
    # Paired by name and signpost id: intervals of one name that overlap (a key's "Key" and the next key's) each end
    # their own.
    pair = (key, m[3])
    if m[4] == "begin": open_.setdefault(pair, []).append(when)
    elif open_.get(pair): spans.setdefault(key, []).append(when - open_[pair].pop())
def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]
out = {k: {"n": len(v), "p50": round(pct(v, .5), 1), "p95": round(pct(v, .95), 1), "max": round(max(v), 1)} for k, v in sorted(spans.items())}
print("%-44s%4s%9s%9s%9s" % ("interval", "n", "p50", "p95", "max"))
for k, s in out.items(): print("%-44s%4d%9.1f%9.1f%9.1f" % (k, s["n"], s["p50"], s["p95"], s["max"]))
if len(sys.argv) > 1 and sys.argv[1]: json.dump(out, open(sys.argv[1], "w"), indent=1)
PY
)" "$json"
