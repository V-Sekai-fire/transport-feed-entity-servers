#!/usr/bin/env bash
# Client sweep: one server pinned to vCPU 0, the loader pinned to vCPU 2 (another physical core on the
# 4 vCPU runner), the client count stepped. Each level runs the planted 6 ms handler: a level whose planted
# runs are not all caught, or whose planted p50 does not sit at least 5 ms above the clean p50, has no valid
# result. Clean runs are a distribution. A wall is reported, not failed: it is the finding.
# Wall at a level: a clean run over the 4 ms budget, a tick over its slot (overruns), or packets lost.
# A level where the loader fell behind is loader-bound: the server was not the limit, so the sweep stops.
set -u
BIN=${BIN:?directory holding entity_serve and entity_load}
RUNS=${RUNS:-8}
PLANTED=${PLANTED:-$RUNS}
STOP_AFTER=${STOP_AFTER:-0}
LEVELS=${LEVELS:-"1 4 16 64 256"}
TICKS=192 SENDS=160 PORT=47321 SV=0 LD=2 MIN_DELTA_NS=5000000
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
fld() { head -1 "$1" | sed -n "s/.* $2=\(-\{0,1\}[0-9]*\).*/\1/p"; }
median() { sort -n | awk '{a[NR]=$1} END {if (NR) print a[int((NR+1)/2)]}'; }
minmax() { sort -n | awk 'NR==1{lo=$1} {hi=$1} END {print lo, hi}'; }
bad() { echo "FAIL: $*"; fail=1; }
[ -n "$PKT" ] && [ -n "$VIEW" ] && [ -n "$MAXU" ] || { echo "FAIL: could not read the packet size, view or user cap from the sources"; exit 1; }

ulimit -n "$(ulimit -Hn)" 2>/dev/null
echo "open files limit $(ulimit -n) descriptors; udp receive buffer default $(cat /proc/sys/net/core/rmem_default 2>/dev/null || echo n/a) bytes, max $(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo n/a) bytes; ephemeral ports $(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo n/a)"

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
  pinned "$LD" "$BIN/entity_load" $SENDS "$n" $PORT > "$T/l.out" 2> "$T/l.err"
  LRC=$?
  wait $ps; SRC=$?
  if [ "$PINNED" = 1 ]; then
    [ "$(cpus_of "$T/s.out")" = "$SV" ] && [ "$(cpus_of "$T/l.out")" = "$LD" ] || bad "pin not applied: wanted server=$SV load=$LD"
  fi
  [ "$LRC" = 0 ] || bad "the loader failed for $n clients (rc $LRC): $(head -1 "$T/l.err")"
}
line() { head -1 "$T/s.out" | cut -d' ' -f2,5-12; echo "   loader: $(head -1 "$T/l.out" | cut -d' ' -f5-7)"; }

if [ "$PINNED" = 1 ]; then
  pinned 0 "$BIN/entity_serve" C 47330 2 0 > "$T/c.out"
  [ "$(cpus_of "$T/c.out")" != 2 ] || bad "control: a server pinned to 0 read back as 2"
  echo "control: a server pinned to 0 reads back as $(cpus_of "$T/c.out")"
fi
echo "packet $PKT bytes, view $VIEW entities, user cap $MAXU clients, server on $SV, loader on $LD"

walls=0
for n in $LEVELS; do
  [ "$n" -le "$MAXU" ] || { bad "level $n is over the server's user cap $MAXU"; continue; }
  k=$n; [ "$k" -le "$VIEW" ] || k=$VIEW
  want=$((SENDS * n))
  echo "== $n clients: $((n * PKT)) bytes in and $((n * k * PKT)) bytes out per tick ($n datagrams of $((k * PKT)) bytes)"
  caught=0; pp50=""
  for i in $(seq 1 "$PLANTED"); do
    once "$n" 6000000
    echo "planted $i: $(line)"
    if [ "$SRC" = 1 ] && grep -q 'FAIL: p99 over the 4 ms budget' "$T/s.out"; then caught=$((caught + 1)); fi
    pp50="$pp50 $(fld "$T/s.out" p50 | tr -d 'n')"
  done
  [ "$caught" = "$PLANTED" ] || bad "level $n: the planted defect was caught in $caught of $PLANTED runs, so this level has no valid p99"
  over=0; ovr=0; lost=0; slowp=0; p99s=""; p50s=""
  for i in $(seq 1 "$RUNS"); do
    once "$n" 0
    echo "clean $i: $(line)"
    if grep -q 'FAIL: no traffic' "$T/s.out"; then bad "level $n run $i: no traffic reached the server"; continue; fi
    grep -q 'FAIL: p99 over the 4 ms budget' "$T/s.out" && over=$((over + 1))
    [ "$(fld "$T/s.out" overruns)" -gt 0 ] && ovr=$((ovr + 1))
    [ "$(fld "$T/s.out" packets_in)" -lt "$want" ] && lost=$((lost + 1))
    [ "$(fld "$T/l.out" slow_passes)" -gt 0 ] && slowp=$((slowp + 1))
    p99s="$p99s $(fld "$T/s.out" p99)"; p50s="$p50s $(fld "$T/s.out" p50)"
  done
  c50=$(printf '%s\n' $p50s | median); p50p=$(printf '%s\n' $pp50 | median)
  delta=$(( ${p50p:-0} - ${c50:-0} ))
  [ "$delta" -ge "$MIN_DELTA_NS" ] || bad "level $n: planted p50 is only ${delta}ns above clean p50, so the planted control does not discriminate"
  set -- $(printf '%s\n' $p99s | minmax)
  echo "level $n clients: planted caught $caught of $PLANTED runs, planted p50 above clean p50 by ${delta}ns; clean p50 median=${c50}ns ($((c50 / n))ns per client) p99 min=${1}ns max=${2}ns; clean over the 4 ms budget in $over of $RUNS runs, with overruns in $ovr of $RUNS runs, with fewer than $want packets in in $lost of $RUNS runs, loader behind in $slowp of $RUNS runs"
  if [ "$slowp" -gt 0 ]; then echo "level $n clients: loader-bound, the loader fell behind in $slowp of $RUNS runs, so the server was not the limit here; stopping"; break; fi
  if [ "$over" -gt 0 ] || [ "$ovr" -gt 0 ] || [ "$lost" -gt 0 ]; then
    walls=$((walls + 1)); echo "level $n clients: WALL (over budget in $over, overruns in $ovr, packet loss in $lost of $RUNS runs)"
  else walls=0; fi
  if [ "$STOP_AFTER" -gt 0 ] && [ "$walls" -ge "$STOP_AFTER" ]; then echo "stopping after $walls consecutive wall levels"; break; fi
done
[ "$fail" = 0 ] && echo "sweep: ok" || echo "sweep: failing"
exit "$fail"
