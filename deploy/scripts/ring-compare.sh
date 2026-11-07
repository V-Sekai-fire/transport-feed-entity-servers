#!/usr/bin/env bash
# Send path compared: plain sendto, io_uring, io_uring with SQPOLL. One server pinned to vCPU 0, the loader
# on vCPU 2, the SQPOLL kernel thread moved to vCPU 3. Receive stays on plain syscalls in every variant.
# Per level and variant: 8 planted 6 ms runs that must each fail the budget, then 8 clean runs interleaved
# across the variants so drift on the VM lands on all of them. Clean runs are a distribution, not a verdict.
set -u
BIN=${BIN:?directory holding entity_serve_ring and entity_load}
RUNS=${RUNS:-8}
LEVELS=${LEVELS:-"64 256"}
VARIANTS="plain ring sqpoll"
TICKS=192 SENDS=160 PORT=47321 SV=0 LD=2
T=$(mktemp -d)
fail=0
PINNED=0
command -v taskset >/dev/null && PINNED=1
pinned() { local cpu=$1; shift; if [ "$PINNED" = 1 ]; then taskset -c "$cpu" "$@"; else "$@"; fi; }
cpus_of() { sed -n 's/.* cpus=\([^ ]*\).*/\1/p' "$1" | head -1; }
bad() { echo "FAIL: $*"; fail=1; }
[ "$PINNED" = 1 ] || { echo "FAIL: taskset is missing"; exit 1; }

once() {
  local n=$1 slow=$2 be=$3
  pinned "$SV" "$BIN/entity_serve_ring" S $PORT $TICKS "$slow" "$be" > "$T/s.out" &
  local ps=$!
  sleep 0.3
  pinned "$LD" "$BIN/entity_load" $SENDS "$n" $PORT > "$T/l.out"
  [ $? = 0 ] || bad "the loader failed for $n clients"
  wait $ps; SRC=$?
  [ "$(cpus_of "$T/s.out")" = "$SV" ] && [ "$(cpus_of "$T/l.out")" = "$LD" ] || bad "pin not applied: wanted server=$SV load=$LD"
}
p99_of() { head -1 "$T/s.out" | sed -n 's/.* p99=\([0-9]*\)ns.*/\1/p'; }
sent_of() { head -1 "$T/s.out" | sed -n 's/.* datagrams_out=\([0-9]*\) .*/\1/p'; }

for n in $LEVELS; do
  echo "== $n clients"
  for be in $VARIANTS; do
    caught=0
    for i in $(seq 1 "$RUNS"); do
      once "$n" 6000000 "$be"
      if [ "$SRC" = 1 ] && grep -q 'FAIL: p99 over the 4 ms budget' "$T/s.out"; then caught=$((caught + 1)); fi
      echo "planted $be $i: p99=$(p99_of)ns datagrams_out=$(sent_of) $(sed -n 's/^backend=[a-z]* //p' "$T/s.out")"
    done
    eval "caught_$be=$caught"
    [ "$caught" = "$RUNS" ] || bad "level $n $be: the planted defect was caught in $caught of $RUNS runs, so this variant has no valid p99"
  done
  for be in $VARIANTS; do eval "v_$be="; eval "over_$be=0"; done
  for i in $(seq 1 "$RUNS"); do
    for be in $VARIANTS; do
      once "$n" 0 "$be"
      if grep -q 'FAIL: no traffic' "$T/s.out"; then bad "level $n $be run $i: no traffic"; continue; fi
      grep -q 'FAIL: p99 over the 4 ms budget' "$T/s.out" && eval "over_$be=\$((over_$be + 1))"
      eval "v_$be=\"\$v_$be $(p99_of)\""
      echo "clean $be $i: p99=$(p99_of)ns datagrams_out=$(sent_of) $(sed -n 's/^backend=[a-z]* //p' "$T/s.out")"
    done
  done
  for be in $VARIANTS; do
    eval "vals=\$v_$be"; eval "ov=\$over_$be"; eval "cg=\$caught_$be"
    s=$(printf '%s\n' $vals | sort -n)
    echo "level $n clients, $be: planted caught $cg of $RUNS runs; clean p99 min=$(echo "$s" | head -1)ns max=$(echo "$s" | tail -1)ns; clean over the 4 ms budget in $ov of $RUNS runs"
  done
done
[ "$fail" = 0 ] && echo "ring-compare: ok" || echo "ring-compare: failing"
exit "$fail"
