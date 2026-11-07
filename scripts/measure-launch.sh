#!/usr/bin/env bash
# Measures launch to first image on screen and memory at rest, for each image given.
#
#   scripts/measure-launch.sh [--runs N] [--bare] [--strict] image-file ...
#
# Builds the release app, then launches it N times per image (default 5) with the launch probe
# on, which prints `launch_to_first_frame_ms` when the first image reaches the screen and
# `footprint_mb` after the app has settled (3 seconds; right after the first frame the figure
# reads high, because graphics memory that is about to be released still counts). That is the
# figure Activity Monitor shows as "Memory". Prints the median of each and marks any that miss
# their target: 300 ms to first frame, 80 MB for the bare app.
#
# "Bare app" means one small image alone in its folder: the 80 MB target applies to that case
# only. With a big image or a folder of photos the figure includes the decode cache (the image
# on screen plus the neighbours the app has preloaded), which has its own budget, so such a row
# is shown for information and not marked "over". Pass --bare, with small images that are alone
# in their folders, to check the 80 MB target: then a value above it is "over".
#
# Exit status: 1 if any image has no usable measurement or a run failed (FAILED, or fewer
# samples than runs: an app that fails to show its image half the time is not healthy). With
# --strict, also 1 if any launch time is over 300 ms, or any --bare memory is over 80 MB.
# Otherwise 0.
#
# Windows open briefly on screen while this runs. Run it on an otherwise idle Mac, and
# disregard the first run after a fresh build: it pays for cold caches.
set -euo pipefail
caller="$PWD"   # relative image paths are relative to where the script was run
cd "$(dirname "$0")/.."

runs=5
strict=0
bare=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) runs="${2:?--runs needs a number}"; shift 2 ;;
    --strict) strict=1; shift ;;
    --bare) bare=1; shift ;;
    *) break ;;
  esac
done
if [[ $# -eq 0 ]]; then
  echo "usage: $0 [--runs N] [--bare] [--strict] image-file ..." >&2
  exit 64
fi

swift build -c release --product NooVeu >/dev/null
app=.build/release/NooVeu

# The lower median of the numbers on standard input, or nothing if there are none.
# (Portable: macOS awk has no asort, and grep exits non-zero when nothing matches.)
median() { { grep -E '^[0-9.]+$' || true; } | sort -n | awk '{ a[NR] = $1 } END { if (NR) print a[int((NR + 1) / 2)] }'; }
# How many numbers are on standard input.
count() { awk '/^[0-9.]+$/ { n++ } END { print n + 0 }'; }

failed=0
over=0

printf '%-44s %16s %18s\n' "image" "launch (ms)" "memory (MB)"
for argument in "$@"; do
  case "$argument" in /*) image="$argument" ;; *) image="$caller/$argument" ;; esac
  name="$(basename "$image")"
  if [[ ! -f "$image" ]]; then
    printf '%-44s %16s %18s\n' "$name" "FAILED" "FAILED"
    echo "  note: $name: no such file" >&2
    failed=1
    continue
  fi
  if (( bare )) && [[ "$(find "$(dirname "$image")" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l | tr -d ' ')" != "1" ]]; then
    echo "  note: $name: not alone in its folder, so this is not the bare app" >&2
  fi

  launches=""; footprints=""
  for ((i = 0; i < runs; i++)); do
    output="$(NOOVEU_LAUNCH_PROBE=1 "$app" "$image" 2>&1 || true)"
    launch="$(sed -n 's/^launch_to_first_frame_ms=//p' <<<"$output" | tail -1)"
    footprint="$(sed -n 's/^footprint_mb=//p' <<<"$output" | tail -1)"
    launches+="$launch"$'\n'
    footprints+="$footprint"$'\n'
  done

  launch_ok="$(count <<<"$launches")"
  footprint_ok="$(count <<<"$footprints")"
  launch_cell="$(median <<<"$launches")"
  footprint_cell="$(median <<<"$footprints")"

  if [[ -z "$launch_cell" ]]; then
    launch_cell="FAILED"; failed=1
  elif awk -v v="$launch_cell" 'BEGIN { exit !(v + 0 > 300) }'; then
    launch_cell+=" over"; over=1
  fi
  if [[ -z "$footprint_cell" ]]; then
    footprint_cell="FAILED"; failed=1
  elif awk -v v="$footprint_cell" 'BEGIN { exit !(v + 0 > 80) }'; then
    if (( bare )); then footprint_cell+=" over"; over=1; else footprint_cell+=" (cache incl.)"; fi
  fi

  printf '%-44s %16s %18s\n' "$name" "$launch_cell" "$footprint_cell"
  # A median over the runs that worked would hide a flaky launch: any lost run fails the script.
  if (( launch_ok < runs || footprint_ok < runs )); then
    echo "  note: $name: only $launch_ok launch and $footprint_ok memory samples out of $runs runs" >&2
    failed=1
  fi
done
echo "targets: launch <= 300 ms; memory <= 80 MB for the bare app (a small image alone in its folder)"

if (( failed )); then exit 1; fi
if (( strict && over )); then exit 1; fi
exit 0
