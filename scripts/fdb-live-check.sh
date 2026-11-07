#!/usr/bin/env bash
# Live check of the fdb: open path against a running FoundationDB (WEFT_FDB_CLUSTER_FILE).
# The expected lines come from the same two runs on a plain SQLite file:
#   run 1 on a new name: the like is new and the post gets id 1
#   run 2 on that name:  the like exists (false) and the post gets id 2  -> data survived a reopen
#   run 1 on another name: id 1 again                                   -> names are isolated
set -u
cd "$(dirname "$0")/.."
bin=.lake/build/bin/sqlite-check
base="${1:-live-$$}"
fail=0
run() { timeout 120 "$bin" "fdb:$1" 2>&1; }
expect() { # name, output, line
  case "$2" in *"$3"*) ;; *) echo "FAIL $1: missing '$3'"; echo "$2" | tail -15; fail=1;; esac
}
o1=$(run "$base-a"); expect "run 1 like" "$o1" "like(2,1) new: Except.ok true"; expect "run 1 insert" "$o1" "insert: id=1 "
o2=$(run "$base-a"); expect "run 2 like (reopen)" "$o2" "like(2,1) new: Except.ok false"; expect "run 2 insert (reopen)" "$o2" "insert: id=2 "
o3=$(run "$base-b"); expect "other name starts fresh" "$o3" "insert: id=1 "
[ "$fail" -eq 0 ] && echo "fdb-live-check: ok (3 runs)"
exit "$fail"
