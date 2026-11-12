#!/bin/bash
# Films Fjord's own window (and only it) on a demo flag, and cuts the mp4s.
#
#   scripts/record-window.sh <out-name> -- <fjord flags…>
#   scripts/record-window.sh router-tour -- --window --record-seconds 20
#
# Builds, runs .build/debug/Fjord with the flags plus `--record`, waits for it to exit on its own (the demo calls
# WindowRecorder.finish(), or `--record-seconds N` ends it), then writes docs/design/router-v2/<out-name>.mp4 (first second
# trimmed, H.264, yuv420p, faststart, 60 fps) and <out-name>-half.mp4 (half speed). The raw .mov goes to $TMPDIR.
#
# macOS draws a sharing badge over the traffic lights of a window being captured. The app writes that corner as it was
# before the capture (<mov>.corner.png) and the cut lays it back over every frame, so the film shows the window as it is.
#
# Needs Screen Recording for the app this runs under (Terminal, Claude, the editor…): System Settings > Privacy & Security >
# Screen & System Audio Recording. The script never touches that setting.
set -euo pipefail
cd "$(dirname "$0")/.."

name="${1:-}"
if [ -z "$name" ] || [ "$name" = "--" ]; then
    echo "usage: $0 <out-name> -- <fjord flags…>" >&2
    exit 2
fi
shift
[ "${1:-}" = "--" ] && shift

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is not installed (brew install ffmpeg)." >&2
    exit 1
fi

out_dir="docs/design/router-v2"
mkdir -p "$out_dir"
mov="${TMPDIR:-/tmp}/fjord-record-$name-$$.mov"
corner="$mov.corner.png"
trap 'rm -f "$mov" "$corner"' EXIT

swift build

# Never kill the app from here (it closes the file when it ends itself); a hung run is for the owner to stop.
status=0
.build/debug/Fjord "$@" --record "$mov" || status=$?
if [ "$status" -ne 0 ]; then
    echo "Fjord exited with status $status; no video written." >&2
    exit "$status"
fi
if [ ! -s "$mov" ]; then
    echo "No recording was written." >&2
    exit 1
fi

# Frames arrive only when the picture changes: fps=60 makes the cut constant-rate. The first second (the window settling) is dropped.
encode=(-an -c:v libx264 -preset slow -crf 14 -pix_fmt yuv420p -movflags +faststart)
if [ -s "$corner" ]; then
    # The clean corner over the sharing badge, on every frame.
    inputs=(-hide_banner -loglevel error -y -ss 1 -i "$mov" -i "$corner")
    ffmpeg "${inputs[@]}" -filter_complex "[0:v]fps=60[v];[v][1:v]overlay=0:0" "${encode[@]}" "$out_dir/$name.mp4"
    ffmpeg "${inputs[@]}" -filter_complex "[0:v]fps=60,setpts=2.0*PTS[v];[v][1:v]overlay=0:0" -r 60 "${encode[@]}" "$out_dir/$name-half.mp4"
else
    inputs=(-hide_banner -loglevel error -y -ss 1 -i "$mov")
    ffmpeg "${inputs[@]}" -vf "fps=60" "${encode[@]}" "$out_dir/$name.mp4"
    ffmpeg "${inputs[@]}" -vf "fps=60,setpts=2.0*PTS" -r 60 "${encode[@]}" "$out_dir/$name-half.mp4"
fi
echo "Wrote $out_dir/$name.mp4 and $out_dir/$name-half.mp4"
