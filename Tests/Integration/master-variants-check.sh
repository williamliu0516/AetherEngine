#!/bin/bash
# Serves each file in a fixture folder with `aetherctl serve --native-subs 0` (DV files with --force-dv, so a
# display without DV still gets the DV master) and runs master-variants-check.swift against the session's
# masters. A file named *-subs.* is expected to expose a legible option. See README.md for the fixtures.
#
# Run:   Tests/Integration/master-variants-check.sh <fixture dir>     (after `swift build`)
set -u
DIR=${1:?usage: master-variants-check.sh <fixture dir>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CTL=$ROOT/.build/debug/aetherctl
CHECK=$ROOT/Tests/Integration/master-variants-check.swift
LOGS=$(mktemp -d)
status=0
for f in "$DIR"/*.mkv; do
  name=$(basename "$f" .mkv)
  flags=(--native-subs 0)
  case $name in *DoVi*) flags+=(--force-dv) ;; esac
  expect=0
  case $name in *-subs) expect=1 ;; esac
  "$CTL" serve "${flags[@]}" "$f" > "$LOGS/$name.log" 2>&1 &
  pid=$!
  url=
  for _ in $(seq 1 100); do
    url=$(grep -A1 '=== PLAYBACK URL ===' "$LOGS/$name.log" | tail -1 | grep '^http')
    [ -n "$url" ] && break
    kill -0 $pid 2>/dev/null || break
    sleep 0.2
  done
  echo "== $name"
  if [ -z "$url" ]; then
    echo "  FAIL: no playback URL (log: $LOGS/$name.log)"
    status=1
  else
    swift "$CHECK" "${url%/*}/" "$expect" 20 || status=1
  fi
  kill -INT $pid 2>/dev/null
  wait $pid 2>/dev/null
done
echo "logs: $LOGS"
exit $status
