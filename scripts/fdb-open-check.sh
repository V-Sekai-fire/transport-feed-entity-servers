#!/usr/bin/env bash
# Cluster-free checks of the opt-in FDB open path. Each case must fail, and fail differently:
#  - "fdb:" with no reachable cluster must be refused with an open error, not crash or hang;
#  - the default path to a missing file must be refused with its own error;
#  - a built-in positive control: the default path still opens a real SQLite file.
set -u
cd "$(dirname "$0")/.."
bin=.lake/build/bin/sqlite-check
fail=0
out=$(WEFT_FDB_CLUSTER_FILE=/nonexistent timeout 60 "$bin" "fdb:x" 2>&1); rc=$?
case "$out" in *"open: open:"*) ;; *) echo "FAIL fdb: path was not refused as an open error (rc=$rc): $out"; fail=1;; esac
[ "$rc" -ne 0 ] || { echo "FAIL fdb: path with no cluster exited 0"; fail=1; }
out=$(timeout 60 "$bin" /nonexistent.db 2>&1); rc=$?
case "$out" in *"unable to open database file"*) ;; *) echo "FAIL default path error changed: $out"; fail=1;; esac
[ "$rc" -ne 0 ] || { echo "FAIL missing default db exited 0"; fail=1; }
tmp=$(mktemp -d); sqlite3 "$tmp/t.db" < reference/schema.sql
out=$(timeout 60 "$bin" "$tmp/t.db" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL positive control: real db did not open (rc=$rc): $out"; fail=1; }
rm -rf "$tmp"
[ "$fail" -eq 0 ] && echo "fdb-open-check: ok (3 cases)"
exit "$fail"
