#!/bin/bash
# Idle is 0%. Launches the release build on the demo data (`--demo agents`: a working session, so its ring is turning),
# lets it settle (until its CPU time has stopped moving), then reads the process's cumulative CPU time at the start and
# end of a window and asserts the average stays under the limit, at rest and kept open (`--open`), on the right edge and
# along the top (the full-width strip is where the window grows). The demo does not poll or watch Claude's files, so this
# measures the bar itself: the ring, the clock, the hover trigger.
#
# What is measured has to have a working session, with Reduce Motion off. The app says so on stdout (`--lifecycle`, for this
# script only): `lifecycle: sessions=S working=W showing=0|1 reduceMotion=0|1`, once after a few seconds and again whenever
# Reduce Motion changes. The script fails when no session works, or when Reduce Motion is on at the start or at any moment of
# the window: it stops the bar's animation, and a number from a bar that stands still proves nothing. ALLOW_HIDDEN=1 turns
# that failure into a warning.
#
# A sample that is missing or malformed, a window that is not positive or a CPU time that goes backwards is a failure,
# never a 0%. In a single run WindowServer's share over the same window is printed apart and is not part of the verdict: it
# draws the ring. To say what the ring costs it, the bar is measured once more on `--demo busy`, which has no working
# session, and the difference is printed.
#
# Glass against opaque (AB=1, docs/design/fjord/glass-plan.md §7). FJORD_GLASS pins the app's `Chrome.mode`, but until the
# chrome views read it (the plan's Phases 2 and 3) both launches still draw the same: a pass then says nothing about glass,
# only that the method's noise is low. The bar on `--demo busy` (no ring turning), on the first
# of EDGES, at rest and kept open (AB_STATES), launched with FJORD_GLASS=0 and FJORD_GLASS=1 in turn, RUNS times each, the
# order swapped every run so a drift of the machine falls on both. Each launch is judged on the app's CPU as above; then the
# medians and spreads (lowest to highest) of the app's and WindowServer's CPU are printed for each state, and WindowServer
# is judged: the glass runs' median less the opaque runs' median must be at most WS_LIMIT points of a core, and at most the
# opaque runs' spread (no more than the noise between opaque runs). WindowServer is every client's: keep the pointer off the
# bar and the screen otherwise still (no video, no seconds in the menu bar's clock). It takes RUNS × states × 2 launches of
# about WINDOW + 10 seconds: some 15 minutes with the defaults.
#
# `--baseline FILE` stores each measure's samples as JSON when FILE does not exist, and compares with it when it does: each
# measure's median now beside the stored one, a WindowServer median more than WS_LIMIT above the stored one failing. Delete
# the file to store a new baseline.
#
# What it does not measure: the network, notifications, the updater's loop, Claude's files changing under the watchers,
# typing, hovering and scrolling. Those are for Instruments by hand.
#
# This puts the bar on screen for about two minutes, so it is for the final gate, not for every change.
#
#   scripts/idle-cpu.sh                 build (release) and measure
#   LIMIT=0.2 WINDOW=60 EDGES="right top bottom left" scripts/idle-cpu.sh
#   SKIP_BUILD=1 scripts/idle-cpu.sh    use the release build as it is
#   ROUTER=1 scripts/idle-cpu.sh        the window kept open on the Router page (`--demo router --open router`: working
#                                       lines, a sheen, the mark), on the first of EDGES; LIMIT 0.6 unless set
#   AB=1 [RUNS=5] [WS_LIMIT=0.3] [AB_STATES="rest open"] scripts/idle-cpu.sh    glass against opaque
#   AB=1 scripts/idle-cpu.sh --baseline docs/design/fjord/baselines/idle-ab.json  store, then compare
set -u
cd "$(dirname "$0")/.."

baseline=
while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) [ $# -ge 2 ] || { echo "idle-cpu: --baseline needs a file"; exit 2; }; baseline=$2; shift 2 ;;
        *) echo "idle-cpu: unknown argument '$1' (only --baseline FILE)"; exit 2 ;;
    esac
done

router=${ROUTER:-0}
if [ "$router" = 1 ]; then limit=${LIMIT:-0.6}; else limit=${LIMIT:-0.1}; fi     # percent of one core
settle=${SETTLE:-5}     # seconds between launch and the wait for the CPU time to stop moving
quiet_for=${QUIET_FOR:-3}   # whole seconds the CPU time must not move before the window begins (ps reports hundredths)
quiet_max=${QUIET_MAX:-40}  # whole seconds that wait takes at most
window=${WINDOW:-30}    # seconds between the two samples
edges=${EDGES:-"right top"}
ab=${AB:-0}
runs=${RUNS:-5}
ws_limit=${WS_LIMIT:-0.3}  # points of one core: glass's WindowServer median over opaque's, at most
ab_states=${AB_STATES:-"rest open"}
bin=.build/release/Fjord

number() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
for value in "$limit" "$settle" "$window" "$ws_limit"; do
    number "$value" || { echo "idle-cpu: LIMIT, SETTLE, WINDOW and WS_LIMIT are numbers ('$value' is not)"; exit 2; }
done
[ "$ab" = 0 ] || [ "$ab" = 1 ] || { echo "idle-cpu: AB is 0 or 1 ('$ab' is not)"; exit 2; }
[[ "$runs" =~ ^[1-9][0-9]*$ ]] || { echo "idle-cpu: RUNS is a whole number above 0 ('$runs' is not)"; exit 2; }
for state in $ab_states; do
    case "$state" in rest | open) ;; *) echo "idle-cpu: AB_STATES are rest or open ('$state' is not)"; exit 2 ;; esac
done
[ -z "$baseline" ] || [ ! -e "$baseline" ] || [ -f "$baseline" ] || { echo "idle-cpu: $baseline is not a file"; exit 2; }
command -v python3 >/dev/null || { echo "idle-cpu: python3 is needed for the summary"; exit 2; }
for value in "$quiet_for" "$quiet_max"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { echo "idle-cpu: QUIET_FOR and QUIET_MAX are whole numbers ('$value' is not)"; exit 2; }
done
awk -v limit="$limit" -v window="$window" 'BEGIN { exit !(limit > 0 && window > 0) }' || { echo "idle-cpu: LIMIT and WINDOW must be above 0"; exit 2; }
for edge in $edges; do
    case "$edge" in left | right | top | bottom) ;; *) echo "idle-cpu: EDGES are left, right, top or bottom ('$edge' is not)"; exit 2 ;; esac
done

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    swift build -c release >/dev/null || { echo "idle-cpu: release build failed"; exit 2; }
fi
[ -x "$bin" ] || { echo "idle-cpu: $bin not found"; exit 2; }

# cpu_seconds <pid>: cumulative CPU time, from ps's [[H:]M:]S.cc. Prints nothing, and fails, when there is none to read.
cpu_seconds() {
    local text
    text=$(ps -o cputime= -p "$1" 2>/dev/null | tr -d ' ') || return 1
    [[ "$text" =~ ^[0-9]+(:[0-9]+){0,2}(\.[0-9]+)?$ ]] || return 1
    awk -v t="$text" 'BEGIN {
        n = split(t, p, ":"); s = 0
        for (i = 1; i <= n; i++) s = s * 60 + p[i]
        printf "%.2f\n", s
    }'
}

# motion_problem <first>: why the bar stood still at some point since the <first>th report of the app (the last report
# before a window is the state it begins in), or nothing when it did not. A report that never came is a problem too.
motion_problem() {
    awk -v first="$1" '
        /^lifecycle:/ {
            n++
            if (n < first) next
            reduce = ""
            for (i = 2; i <= NF; i++) {
                split($i, kv, "=")
                if (kv[1] == "reduceMotion") reduce = kv[2]
            }
            seen = 1
            if (reduce == "1") { print "Reduce Motion is on: the bar is static, so the number would mean nothing (turn it off in System Settings)"; exit }
        }
        END { if (!seen) print "the app made no report of its state" }
    ' "$out"
}

out=$(mktemp)
# One line per launch measured: state, edge, scenario, glass (- in a single run), app %, WindowServer % (n/a: not sampled).
results=$(mktemp)
pid=
# stop_app: ends the app a measure launched, and waits for it, so none outlives its measure or reaches the next one's window.
stop_app() {
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=
}
cleanup() {
    stop_app
    rm -f "$out" "$results"
}
trap cleanup EXIT

failed=0
scenario=agents
# FJORD_GLASS for the launches (AB=1), else empty: not set.
glass=
last_ws=n/a

# measure <label> <edge> [launch argument]: one launch, one verdict. However it ends, the app is stopped.
measure() {
    sample "$@"
    stop_app
    # The next launch starts from a clean slate, not beside the previous one's window.
    sleep 1
}

sample() {
    local label=$1 edge=$2; shift 2
    last_ws=n/a
    : >"$out"
    # `env` execs the app, so the pid is the app's.
    env ${glass:+FJORD_GLASS="$glass"} "$bin" --demo "$scenario" --lifecycle --edge "$edge" "$@" >"$out" 2>&1 &
    pid=$!
    [ -z "$glass" ] || label="$label glass=$glass"
    sleep "$settle"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "idle-cpu: $label $edge: the app exited during the first $settle seconds"
        failed=1
        return
    fi
    # Launching costs a second of CPU or more, longer on a busy machine and longer still when the bar opens at once (--open:
    # the whole hub is built and its avatars asked for): the window starts once the CPU time has not moved for a few seconds,
    # so it never holds a start-up that was still going. At most `quiet_max` seconds are waited.
    local still=0 last now_cpu waited=0
    last=$(cpu_seconds "$pid") || last=
    while [ "$still" -lt "$quiet_for" ] && [ "$waited" -lt "$quiet_max" ]; do
        sleep 1
        waited=$((waited + 1))
        now_cpu=$(cpu_seconds "$pid") || now_cpu=
        if [ -n "$now_cpu" ] && [ "$now_cpu" = "$last" ]; then still=$((still + 1)); else still=0; fi
        last=$now_cpu
    done
    if [ "$still" -lt "$quiet_for" ]; then
        echo "idle-cpu: $label $edge: the CPU time was still moving $quiet_max s after the start-up (the window begins anyway)"
    fi
    if [ "$scenario" = agents ] && ! grep -q 'lifecycle: sessions=[0-9]* working=[1-9]' "$out"; then
        echo "idle-cpu: $label $edge: no working session on the bar ($(grep 'lifecycle:' "$out" | tail -1 || echo 'no report')): there is no ring to measure"
        failed=1
    fi
    # The reports so far; the window starts from the last of them.
    local reports problem
    reports=$(grep -c '^lifecycle:' "$out")
    if [ "$scenario" = agents ] && problem=$(motion_problem "$reports") && [ -n "$problem" ]; then
        echo "idle-cpu: $label $edge: $problem"
        if [ "${ALLOW_HIDDEN:-0}" != "1" ]; then
            failed=1
            return
        fi
    fi
    local ws; ws=$(pgrep -x WindowServer | head -1)
    local app0 app1 ws0 ws1
    app0=$(cpu_seconds "$pid") || { echo "idle-cpu: $label $edge: no CPU sample of the app at the start"; failed=1; return; }
    ws0=$(cpu_seconds "${ws:-0}") || ws0=
    sleep "$window"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "idle-cpu: $label $edge: the app exited while it was measured"
        failed=1
        return
    fi
    app1=$(cpu_seconds "$pid") || { echo "idle-cpu: $label $edge: no CPU sample of the app at the end"; failed=1; return; }
    ws1=$(cpu_seconds "${ws:-0}") || ws1=
    # Nothing may have stopped the bar's animation while the window ran: a stretch standing still costs nothing and passes for free.
    if [ "$scenario" = agents ] && problem=$(motion_problem "$reports") && [ -n "$problem" ]; then
        echo "idle-cpu: $label $edge: $problem (during the measurement)"
        [ "${ALLOW_HIDDEN:-0}" = "1" ] || failed=1
    fi
    if [ -n "$ws0" ] && [ -n "$ws1" ]; then
        last_ws=$(awk -v w0="$ws0" -v w1="$ws1" -v window="$window" 'BEGIN { printf "%.2f", (w1 - w0) / window * 100 }')
    else
        last_ws="n/a"
    fi
    awk -v label="$label $edge" -v window="$window" -v limit="$limit" -v a0="$app0" -v a1="$app1" -v ws="$last_ws" 'BEGIN {
        if (!(window > 0) || a1 < a0) {
            printf "%-12s FAIL: a window of %s s and CPU time going from %s to %s are no measurement\n", label, window, a0, a1
            exit 1
        }
        app = (a1 - a0) / window * 100
        verdict = app < limit ? "ok" : "FAIL"
        printf "%-12s app %.3f%% (limit %s%%)  WindowServer %s%% (all clients)  %s\n", label, app, limit, ws, verdict
        exit app < limit ? 0 : 1
    }' || failed=1
    # A measurement, passed or not, goes to the summary; one that is no measurement (the CPU time went backwards) does not.
    awk -v a0="$app0" -v a1="$app1" 'BEGIN { exit !(a1 >= a0) }' || return
    awk -v state="${label%% glass=*}" -v edge="$edge" -v scenario="$scenario" -v glass="${glass:--}" -v window="$window" \
        -v a0="$app0" -v a1="$app1" -v ws="$last_ws" \
        'BEGIN { printf "%s\t%s\t%s\t%s\t%.4f\t%s\n", state, edge, scenario, glass, (a1 - a0) / window * 100, ws }' >>"$results"
}

if [ "$router" = 1 ]; then
    # The Router page open, nothing changing but its own working lines (IMPLEMENTATION.md 2.4).
    scenario=router
    measure "open router" "${edges%% *}" --open router
elif [ "$ab" = 1 ]; then
    # Glass against opaque: no ring turning (§7), opaque and glass in turn, the order swapped every run.
    scenario=busy
    edge=${edges%% *}
    for ((run = 1; run <= runs; run++)); do
        order="0 1"
        [ $((run % 2)) = 0 ] && order="1 0"
        for state in $ab_states; do
            for glass in $order; do
                if [ "$state" = open ]; then measure open "$edge" --open; else measure rest "$edge"; fi
            done
        done
    done
    glass=
else
    ring_ws=
    for edge in $edges; do
        measure rest "$edge"
        [ -z "$ring_ws" ] && ring_ws=$last_ws
        measure open "$edge" --open
    done

    # What the ring costs: the same bar at rest with no working session, WindowServer's share beside the first one's.
    scenario=busy
    measure "no ring" "${edges%% *}"
    awk -v ring="$ring_ws" -v none="$last_ws" 'BEGIN {
        if (ring == "n/a" || none == "n/a") { print "ring: WindowServer not sampled"; exit }
        printf "ring: WindowServer %.2f%% with a working session, %.2f%% without (all clients; %+.2f%%)\n", ring, none, ring - none
    }'
fi

# The medians, spreads and WindowServer's verdict (AB=1), and the baseline. Exits 1 on a failed verdict.
python3 -I - "$results" "$ab" "$ws_limit" "$limit" "$window" "$baseline" <<'PY' || failed=1
import json, os, statistics, sys, time

results, ab, ws_limit, limit, window, baseline = sys.argv[1:7]
ab, ws_limit = ab == "1", float(ws_limit)
groups = {}
for line in open(results):
    state, edge, scenario, glass, app, ws = line.rstrip("\n").split("\t")
    g = groups.setdefault((state, edge, scenario, glass), {"app": [], "ws": []})
    g["app"].append(float(app))
    if ws != "n/a":
        g["ws"].append(float(ws))

def stats(xs):
    return (statistics.median(xs), min(xs), max(xs)) if xs else None

def show(xs, digits):
    s = stats(xs)
    return "n/a" if s is None else f"{s[0]:.{digits}f}% ({s[1]:.{digits}f}–{s[2]:.{digits}f}, n={len(xs)})"

failed = False
if ab and not groups:
    print("FAIL: no measurement to judge")
    failed = True
if ab:
    for key in sorted({k[:3] for k in groups}):
        state, edge, scenario = key
        opaque, glass = groups.get(key + ("0",)), groups.get(key + ("1",))
        for name, g in (("opaque", opaque), ("glass", glass)):
            if g:
                print(f"{state} {edge} {name:6}  app {show(g['app'], 3)}  WindowServer {show(g['ws'], 2)}")
        if not opaque or not glass or len(opaque["ws"]) < 3 or len(glass["ws"]) < 3:
            print(f"{state} {edge}: FAIL: fewer than 3 WindowServer samples of each, no verdict")
            failed = True
            continue
        o, gl = stats(opaque["ws"]), stats(glass["ws"])
        delta, spread = gl[0] - o[0], o[2] - o[1]
        ok = delta <= ws_limit and delta <= spread
        failed |= not ok
        print(f"{state} {edge}: WindowServer glass − opaque {delta:+.2f} points of a core "
              f"(limit {ws_limit}, opaque spread {spread:.2f})  {'ok' if ok else 'FAIL'}")

if baseline:
    now = [{"state": k[0], "edge": k[1], "scenario": k[2], "glass": None if k[3] == "-" else k[3],
            "app": v["app"], "ws": v["ws"]} for k, v in sorted(groups.items())]
    if not os.path.exists(baseline):
        os.makedirs(os.path.dirname(baseline) or ".", exist_ok=True)
        with open(baseline, "w") as f:
            json.dump({"version": 1, "date": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "ab": ab, "limit": float(limit),
                       "window": float(window), "measures": now}, f, indent=2)
            f.write("\n")
        print(f"baseline: stored in {baseline}")
    else:
        try:
            old = json.load(open(baseline))
            stored = {(m["state"], m["edge"], m["scenario"], m["glass"]): m for m in old["measures"]}
        except (OSError, ValueError, KeyError, TypeError) as e:
            print(f"baseline: FAIL: {baseline} can't be read ({e})")
            sys.exit(1)
        print(f"baseline: against {baseline} ({old.get('date', 'undated')})")
        for m in now:
            key = (m["state"], m["edge"], m["scenario"], m["glass"])
            name = " ".join(x for x in (m["state"], m["edge"], m["scenario"], m["glass"] and f"glass={m['glass']}") if x)
            was = stored.get(key)
            if not was:
                print(f"  {name}: not in the baseline")
                continue
            line = f"  {name}: app {statistics.median(m['app']):.3f}% (was {statistics.median(was['app']):.3f}%)"
            if m["ws"] and was["ws"]:
                ws_now, ws_was = statistics.median(m["ws"]), statistics.median(was["ws"])
                worse = ws_now - ws_was > ws_limit
                failed |= worse
                line += f"  WindowServer {ws_now:.2f}% (was {ws_was:.2f}%, {ws_now - ws_was:+.2f}){'  FAIL' if worse else ''}"
            print(line)

sys.exit(1 if failed else 0)
PY

exit $failed
