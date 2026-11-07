#!/usr/bin/env bash
# Client sweep: one server pinned to vCPU 0, the loader pinned to vCPU 2 (another physical core on the
# 4 vCPU runner), the client count stepped. Each level runs the planted 6 ms handler first: a level whose
# planted runs are not all caught has no valid p99. The clean runs are a distribution, not a pass or fail.
set -u
BIN=${BIN:?directory holding entity_serve and entity_load}
RUNS=${RUNS:-8}
LEVELS=${LEVELS:-"1 4 16 64 256"}
TICKS=192 SENDS=160 PORT=47321 SV=0 LD=2
HERE=$(cd "$(dirname "$0")/../.." && pwd)
PKT=$(sed -n 's/^#define XR_PACKET_SIZE \([0-9]*\).*/\1/p' "$HERE/datasources/entity-packet/xr_grid_entity_packet.h")
VIEW=$(sed -n 's/^#define ET_VIEW \([0-9]*\).*/\1/p' "$HERE/transports/csrc/entity_tick.h")
MAXU=$(sed -n 's/^#define ET_MAX_USERS \([0-9]*\).*/\1/p' "$HERE/transports/csrc/entity_tick.h")
T=$(mktemp -d)
fail=0
PINNED=0
command -v taskset >/dev/null && PINNED=1
pinned() { local cpu=$1; shift; if [ "$PINNED" = 1 ]; then taskset -c "$cpu" "$@"; else "$@"; fi; }
cpus_of() { sed -n 's/.* cpus=\([^ ]*\).*/\1/p' "$1" | head -1; }
bad() { echo "FAIL: $*"; fail=1; }
[ -n "$PKT" ] && [ -n "$VIEW" ] && [ -n "$MAXU" ] || { echo "FAIL: could not read the packet size, view or user cap from the sources"; exit 1; }

if [ "$PINNED" = 1 ]; then
  s0=$(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list)
  s2=$(cat /sys/devices/system/cpu/cpu2/topology/thread_siblings_list)
  [ "$s0" = 0-1 ] && [ "$s2" = 2-3 ] || { echo "FAIL: the sweep assumes siblings 0-1 and 2-3, found $s0 and $s2"; exit 1; }
elif [ "${ALLOW_UNPINNED:-0}" != 1 ]; then
  echo "FAIL: taskset is missing; set ALLOW_UNPINNED=1 to run without pinning"; exit 1
fi

once() {
  local n=$1 slow=$2
  pinned "$SV" "$BIN/entity_serve" S $PORT $TICKS "$slow" > "$T/s.out" &
  local ps=$!
  sleep 0.3
  pinned "$LD" "$BIN/entity_load" $SENDS "$n" $PORT > "$T/l.out"
  LRC=$?
  wait $ps; SRC=$?
  if [ "$PINNED" = 1 ]; then
    [ "$(cpus_of "$T/s.out")" = "$SV" ] && [ "$(cpus_of "$T/l.out")" = "$LD" ] || bad "pin not applied: wanted server=$SV load=$LD"
  fi
  [ "$LRC" = 0 ] || bad "the loader failed for $n clients (rc $LRC)"
}
line() { head -1 "$T/s.out" | cut -d' ' -f2,5-11; }

if [ "$PINNED" = 1 ]; then
  pinned 0 "$BIN/entity_serve" C 47330 2 0 > "$T/c.out"
  [ "$(cpus_of "$T/c.out")" != 2 ] || bad "control: a server pinned to 0 read back as 2"
  echo "control: a server pinned to 0 reads back as $(cpus_of "$T/c.out")"
fi
echo "packet $PKT bytes, view $VIEW entities, user cap $MAXU, server on $SV, loader on $LD"

for n in $LEVELS; do
  [ "$n" -le "$MAXU" ] || { bad "level $n is over the server's user cap $MAXU"; continue; }
  k=$n; [ "$k" -le "$VIEW" ] || k=$VIEW
  echo "== $n clients: $((n * PKT)) bytes in and $((n * k * PKT)) bytes out per tick ($n datagrams of $((k * PKT)) bytes)"
  caught=0
  for i in $(seq 1 "$RUNS"); do
    once "$n" 6000000
    echo "planted $i: $(line)"
    if [ "$SRC" = 1 ] && grep -q 'FAIL: p99 over the 4 ms budget' "$T/s.out"; then caught=$((caught + 1)); fi
  done
  [ "$caught" = "$RUNS" ] || bad "level $n: the planted defect was caught in $caught of $RUNS runs, so this level has no valid p99"
  over=0; p99s=""
  for i in $(seq 1 "$RUNS"); do
    once "$n" 0
    echo "clean $i: $(line)"
    if grep -q 'FAIL: no traffic' "$T/s.out"; then bad "level $n run $i: no traffic reached the server"; continue; fi
    grep -q 'FAIL: p99 over the 4 ms budget' "$T/s.out" && over=$((over + 1))
    p99s="$p99s $(head -1 "$T/s.out" | sed -n 's/.* p99=\([0-9]*\).*/\1/p')"
  done
  sorted=$(printf '%s\n' $p99s | sort -n)
  echo "level $n clients: planted caught $caught of $RUNS runs; clean p99 min=$(echo "$sorted" | head -1)ns max=$(echo "$sorted" | tail -1)ns; clean over the 4 ms budget in $over of $RUNS runs"
done
[ "$fail" = 0 ] && echo "sweep: ok" || echo "sweep: failing"
exit "$fail"
