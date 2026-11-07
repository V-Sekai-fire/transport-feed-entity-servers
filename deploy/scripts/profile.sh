#!/usr/bin/env bash
# Timing profiles: the Rust oracle and the Lean port, same seed, same k6 load (the challenge's bench/load.js),
# server pinned to CPU 0, load generator on the other CPUs, samply attached to the server for the hold.
# Run in the privileged container (perf_event_paranoid must allow sampling). Output: /out/profiles.
# This VM is arm64, so numbers compare Lean to Rust only, never to the leaderboard.
set -u
export LC_ALL=C
S=twelve-dollar-challenge
VUS=${VUS:-3000}; RAMP=${RAMP:-10s}; HOLD=${HOLD:-30s}; REC=${REC:-20}
OUT=/out/profiles; mkdir -p $OUT
mkdir -p /w && cd /src && tar cf - --exclude=.lake --exclude=.git --exclude=target . | tar xf - -C /w && cd /w
bash deploy/scripts/fetch-sqlite.sh
lake build feed-server 2>&1 | grep -E "^error|Build" | head -3
(cd datasources/reference && CARGO_PROFILE_RELEASE_DEBUG=line-tables-only RUSTFLAGS="-C force-frame-pointers=yes" bash build.sh 2>&1 | tail -1)
git clone -q --depth 1 https://github.com/arjaythedev/twelve-dollar-server-challenge.git /c
(cd /c && bash seed/make-seed.sh >/dev/null 2>&1)
NCPU=$(nproc); LOADCPUS="1-$((NCPU-1))"
echo "cpus=$NCPU server=0 load=$LOADCPUS vus=$VUS ramp=$RAMP hold=$HOLD record=${REC}s" | tee $OUT/params.txt
run() { # name, binary
  local name=$1 bin=$2 db=/tmp/$1.db
  cp /c/seed/feed.db $db
  SQLITE_PATH=$db JWT_SECRET=$S HOST=127.0.0.1 PORT=3000 taskset -c 0 $bin 2>/tmp/$name.err &
  local pid=$!; sleep 3
  taskset -c $LOADCPUS k6 run -e VUS=$VUS -e RAMP_UP=$RAMP -e DURATION=$HOLD -e TOKENS=/c/seed/tokens.json \
      /c/bench/load.js > $OUT/$name.k6.txt 2>&1 &
  local kpid=$!
  sleep 12
  timeout -s INT $REC samply record --save-only --no-open --unstable-presymbolicate -p $pid -o $OUT/$name.profile.json.gz > $OUT/$name.samply.txt 2>&1
  wait $kpid
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  echo "== $name"; grep -E "http_req_duration|http_reqs|http_req_failed|checks" $OUT/$name.k6.txt | head -6
  ls -la $OUT/$name.profile.json.gz* 2>&1 | cut -c1-120
}
run rust /w/datasources/reference/target/release/feed-server
run lean /w/.lake/build/bin/feed-server
chmod -R a+rwX /out 2>/dev/null; true
