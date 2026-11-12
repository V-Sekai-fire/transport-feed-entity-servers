#!/usr/bin/env bash
# Two servers and one loader pinned to single vCPUs on the 4 vCPU runner, in two labelled layouts.
set -u
BIN=${BIN:?directory holding entity_serve and entity_load}
RUNS=${RUNS:-8}
TICKS=192 SENDS=160 PER=4 PA=47321 PB=47322
T=$(mktemp -d)
fail=0
PINNED=0
command -v taskset >/dev/null && PINNED=1

pinned() {
  local cpu=$1; shift
  if [ "$PINNED" = 1 ]; then taskset -c "$cpu" "$@"; else "$@"; fi
}
cpus_of() { sed -n 's/.* cpus=\([^ ]*\).*/\1/p' "$1" | head -1; }
bad() { echo "FAIL: $*"; fail=1; }

. "$(dirname "$0")/cpu-pairs.sh"
SIB0=1 OC=2 SIBOC=3
if [ "$PINNED" = 1 ]; then
  cpu_pairs || exit 1
elif [ "${ALLOW_UNPINNED:-0}" != 1 ]; then
  echo "FAIL: taskset is missing; set ALLOW_UNPINNED=1 to run without pinning"; exit 1
fi

once() {
  local sa=$1 sb=$2 ld=$3 slow=$4
  pinned "$sa" "$BIN/entity_serve" A $PA $TICKS 0 > "$T/a.out" &
  local pa=$!
  pinned "$sb" "$BIN/entity_serve" B $PB $TICKS "$slow" > "$T/b.out" &
  local pb=$!
  sleep 0.3
  pinned "$ld" "$BIN/entity_load" $SENDS $PER $PA $PB > "$T/l.out"
  wait $pa; RA=$?
  wait $pb; RB=$?
  if [ "$PINNED" = 1 ]; then
    [ "$(cpus_of "$T/a.out")" = "$sa" ] && [ "$(cpus_of "$T/b.out")" = "$sb" ] && [ "$(cpus_of "$T/l.out")" = "$ld" ] \
      || bad "pin not applied: wanted A=$sa B=$sb load=$ld"
  fi
}

layout() {
  local name=$1 sa=$2 sb=$3 ld=$4 i
  echo "== layout $name: server A on $sa, server B on $sb, loader on $ld"
  for i in $(seq 1 "$RUNS"); do
    once "$sa" "$sb" "$ld" 6000000
    echo "planted $i: $(head -1 "$T/a.out" | cut -d' ' -f1,2,8-11) | $(head -1 "$T/b.out" | cut -d' ' -f1,2,8-11)"
    [ "$RA" = 0 ] && [ "$RB" = 1 ] && grep -q 'FAIL: p99 over the 4 ms budget' "$T/b.out" \
      || bad "layout $name run $i: the planted server B was not the only one to fail (A=$RA B=$RB)"
  done
  for i in $(seq 1 "$RUNS"); do
    once "$sa" "$sb" "$ld" 0
    echo "clean $i: $(head -1 "$T/a.out" | cut -d' ' -f1,2,8-11) | $(head -1 "$T/b.out" | cut -d' ' -f1,2,8-11)"
    [ "$RA" = 0 ] && [ "$RB" = 0 ] || bad "layout $name run $i: a clean server failed (A=$RA B=$RB)"
  done
}

if [ "$PINNED" = 1 ]; then
  pinned 0 "$BIN/entity_serve" C 47330 2 0 > "$T/c.out"
  [ "$(cpus_of "$T/c.out")" != "$SIB0" ] || bad "control: a server pinned to 0 read back as $SIB0"
  echo "control: a server pinned to 0 reads back as $(cpus_of "$T/c.out")"
fi
layout A-siblings-share 0 "$SIB0" "$OC"
layout B-siblings-split 0 "$OC" "$SIB0"
[ "$fail" = 0 ] && echo "layouts: ok" || echo "layouts: failing"
exit "$fail"
