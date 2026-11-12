#!/usr/bin/env bash
# Client sweep: one server pinned to vCPU 0, the loader pinned to vCPU 2 (another physical core on the
# 4 vCPU runner), the client count stepped. SERVERS=2 splits each level evenly over two servers (a HORZ cell
# split): servers on vCPU 0 and 2 (separate physical cores), the loader on vCPU 3 unless LD says otherwise, the
# planted defect on the last server only. No entity is shared between the servers, so there is no border traffic. Each level runs the planted 6 ms handler: a level whose planted
# runs are not all caught, or whose planted p50 does not sit at least 5 ms above the clean p50, has no valid
# result. Clean runs are a distribution. A wall is reported, not failed: it is the finding.
# Wall at a level: a clean run over the 4 ms budget, a tick over its slot (overruns), or packets lost.
# A level where the loader fell behind is loader-bound: the server was not the limit, so the sweep stops.
set -u
BIN=${BIN:?directory holding entity_serve and entity_load}
RUNS=${RUNS:-8}
PLANTED=${PLANTED:-$RUNS}
STOP_AFTER=${STOP_AFTER:-0}
BACKEND=${BACKEND:-plain} # plain, or nosend: the same tick with the sendto calls skipped (a control)
LEVELS=${LEVELS:-"1 4 16 64 256"}
SERVERS=${SERVERS:-1}
TICKS=192 SENDS=160 PORT=47321 MIN_DELTA_NS=5000000
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
num() { local v; v=$(fld "$1" "$2"); echo "${v:-0}"; }
median() { sort -n | awk '{a[NR]=$1} END {if (NR) print a[int((NR+1)/2)]}'; }
minmax() { sort -n | awk 'NR==1{lo=$1} {hi=$1} END {print lo, hi}'; }
bad() { echo "FAIL: $*"; fail=1; }
[ -n "$PKT" ] && [ -n "$VIEW" ] && [ -n "$MAXU" ] || { echo "FAIL: could not read the packet size, view or user cap from the sources"; exit 1; }

ulimit -n "$(ulimit -Hn)" 2>/dev/null
echo "open files limit $(ulimit -n) descriptors; udp receive buffer default $(cat /proc/sys/net/core/rmem_default 2>/dev/null || echo n/a) bytes, max $(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo n/a) bytes; ephemeral ports $(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo n/a)"

. "$(dirname "$0")/cpu-pairs.sh"
SIB0=1 OC=2 SIBOC=3
if [ "$PINNED" = 1 ]; then
  cpu_pairs || exit 1
elif [ "${ALLOW_UNPINNED:-0}" != 1 ]; then
  echo "FAIL: taskset is missing; set ALLOW_UNPINNED=1 to run without pinning"; exit 1
fi
# Servers on vCPU 0 and OC (separate physical cores); the loader on OC, or on OC's sibling with two servers.
# SERVER_CPUS="<OC> 0" swaps the servers' vCPUs; ENTITY_LOAD_ORDER=interleave makes the loader alternate between the servers in each pass
read -r -a SVC <<< "${SERVER_CPUS:-0 $OC}"
case "$SERVERS" in
  1) LD=${LD:-$OC} ;;
  2) LD=${LD:-$SIBOC} ;;
  *) echo "FAIL: SERVERS must be 1 or 2, got $SERVERS"; exit 1 ;;
esac
LAST=$((SERVERS - 1))
for ((j = 0; j < SERVERS; j++)); do
  [ "$LD" != "${SVC[$j]}" ] || { echo "FAIL: the loader and server $j are both on vCPU $LD"; exit 1; }
done

once() {
  local n=$1 slow=$2 per=$(($1 / SERVERS)) j sl ports=""
  PIDS=()
  for ((j = 0; j < SERVERS; j++)); do
    sl=0; [ "$j" = "$LAST" ] && sl=$slow
    pinned "${SVC[$j]}" "$BIN/entity_serve" "S$j" $((PORT + j)) $TICKS "$sl" "$BACKEND" > "$T/s$j.out" &
    PIDS[$j]=$!
    ports="$ports $((PORT + j))"
  done
  sleep 0.3
  pinned "$LD" "$BIN/entity_load" $SENDS "$per" $ports > "$T/l.out" 2> "$T/l.err"
  LRC=$?
  for ((j = 0; j < SERVERS; j++)); do wait "${PIDS[$j]}"; SRC[$j]=$?; done
  if [ "$PINNED" = 1 ]; then
    for ((j = 0; j < SERVERS; j++)); do
      [ "$(cpus_of "$T/s$j.out")" = "${SVC[$j]}" ] || bad "pin not applied: wanted server $j=${SVC[$j]}"
    done
    [ "$(cpus_of "$T/l.out")" = "$LD" ] || bad "pin not applied: wanted load=$LD"
  fi
  [ "$LRC" = 0 ] || bad "the loader failed for $n clients (rc $LRC): $(head -1 "$T/l.err")"
}
line() {
  local j
  for ((j = 0; j < SERVERS; j++)); do echo "   server $j: $(head -1 "$T/s$j.out" | cut -d' ' -f2,5-12)"; done
  echo "   loader: $(head -1 "$T/l.out" | cut -d' ' -f3,5-7)"
}

if [ "$PINNED" = 1 ]; then
  pinned 0 "$BIN/entity_serve" C 47330 2 0 > "$T/c.out"
  [ "$(cpus_of "$T/c.out")" != "$OC" ] || bad "control: a server pinned to 0 read back as $OC"
  echo "control: a server pinned to 0 reads back as $(cpus_of "$T/c.out")"
fi
echo "packet $PKT bytes, view $VIEW entities, user cap $MAXU clients, $SERVERS server(s) on vCPU ${SVC[*]:0:$SERVERS}, loader on $LD"

walls=0
for n in $LEVELS; do
  [ "$n" -le "$MAXU" ] || { bad "level $n is over the user cap $MAXU"; continue; }
  [ $((n % SERVERS)) = 0 ] || { bad "level $n does not divide over $SERVERS servers"; continue; }
  per=$((n / SERVERS)); k=$per; [ "$k" -le "$VIEW" ] || k=$VIEW
  want=$((SENDS * per))
  echo "== $n clients over $SERVERS server(s), $per clients each: $((per * PKT)) bytes in and $((per * k * PKT)) bytes out per tick on each server ($per datagrams of $((k * PKT)) bytes)"
  caught=0; ppl=""; ppa=""
  for i in $(seq 1 "$PLANTED"); do
    once "$n" 6000000
    echo "planted $i:"; line
    if [ "${SRC[$LAST]}" = 1 ] && grep -q 'FAIL: p99 over the 4 ms budget' "$T/s$LAST.out"; then caught=$((caught + 1)); fi
    ppl="$ppl $(num "$T/s$LAST.out" p50)"; ppa="$ppa $(num "$T/s0.out" p50)"
  done
  [ "$caught" = "$PLANTED" ] || bad "level $n: the planted defect was caught in $caught of $PLANTED runs on server $LAST, so this level has no valid p99"
  over=0; ovr=0; lost=0; slowp=0; fab=""
  P50=(); P99=()
  for ((j = 0; j < SERVERS; j++)); do P50[$j]=""; P99[$j]=""; done
  for i in $(seq 1 "$RUNS"); do
    once "$n" 0
    echo "clean $i:"; line
    nt=0
    for ((j = 0; j < SERVERS; j++)); do
      if grep -q 'FAIL: no traffic' "$T/s$j.out"; then bad "level $n run $i: no traffic reached server $j"; nt=1; fi
    done
    [ "$nt" = 0 ] || continue
    ao=0; av=0; al=0; mx=0
    for ((j = 0; j < SERVERS; j++)); do
      grep -q 'FAIL: p99 over the 4 ms budget' "$T/s$j.out" && ao=1
      [ "$(num "$T/s$j.out" overruns)" -gt 0 ] && av=1
      [ "$(num "$T/s$j.out" packets_in)" -lt "$want" ] && al=1
      p=$(num "$T/s$j.out" p99)
      P99[$j]="${P99[$j]} $p"; P50[$j]="${P50[$j]} $(num "$T/s$j.out" p50)"
      [ "$p" -gt "$mx" ] && mx=$p
    done
    over=$((over + ao)); ovr=$((ovr + av)); lost=$((lost + al)); fab="$fab $mx"
    [ "$(num "$T/l.out" slow_passes)" -gt 0 ] && slowp=$((slowp + 1))
  done
  c50=()
  for ((j = 0; j < SERVERS; j++)); do c50[$j]=$(printf '%s\n' ${P50[$j]} | median); done
  p50p=$(printf '%s\n' $ppl | median)
  delta=$(( ${p50p:-0} - ${c50[$LAST]:-0} ))
  [ "$delta" -ge "$MIN_DELTA_NS" ] || bad "level $n: planted p50 is only ${delta}ns above clean p50 on server $LAST, so the planted control does not discriminate"
  echo "level $n clients over $SERVERS server(s): planted caught $caught of $PLANTED runs on server $LAST, its planted p50 above its clean p50 by ${delta}ns; clean over the 4 ms budget in $over of $RUNS runs, with overruns in $ovr of $RUNS runs, with fewer than $want packets in on a server in $lost of $RUNS runs, loader behind in $slowp of $RUNS runs"
  for ((j = 0; j < SERVERS; j++)); do
    set -- $(printf '%s\n' ${P99[$j]} | minmax)
    echo "  server $j: clean p50 median=${c50[$j]}ns ($((${c50[$j]:-0} / per))ns per client) p99 min=${1}ns max=${2}ns"
  done
  set -- $(printf '%s\n' $fab | minmax)
  echo "  slowest server in each run: clean p99 min=${1}ns max=${2}ns"
  if [ "$SERVERS" -gt 1 ]; then
    pa=$(printf '%s\n' $ppa | median)
    echo "  server 0 in the planted runs (defect on server $LAST only): p50 median=${pa}ns against ${c50[0]}ns in the clean runs, difference $(( ${pa:-0} - ${c50[0]:-0} ))ns"
  fi
  if [ "$slowp" -gt 0 ]; then echo "level $n clients: loader-bound, the loader fell behind in $slowp of $RUNS runs, so the server was not the limit here; stopping"; break; fi
  if [ "$over" -gt 0 ] || [ "$ovr" -gt 0 ] || [ "$lost" -gt 0 ]; then
    walls=$((walls + 1)); echo "level $n clients: WALL (over budget in $over, overruns in $ovr, packet loss in $lost of $RUNS runs)"
  else walls=0; fi
  if [ "$STOP_AFTER" -gt 0 ] && [ "$walls" -ge "$STOP_AFTER" ]; then echo "stopping after $walls consecutive wall levels"; break; fi
done
[ "$fail" = 0 ] && echo "sweep: ok" || echo "sweep: failing"
exit "$fail"
