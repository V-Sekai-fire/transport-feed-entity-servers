# Timing profiles (samply)

Same seed, same k6 load (the challenge's bench/load.js), server pinned to CPU 0, k6 on CPUs 1-7, samply attached to the server for 20 s of the hold. 8-core arm64 VM, so Lean is compared with Rust only, never with the leaderboard.

```
cpus=8 server=0 load=1-7 vus=3000 ramp=10s hold=30s record=20s
```

Command: `podman run --rm --privileged -v <export>:/src:ro -v <out>:/out feed-lean bash /src/scripts/profile.sh` (needs perf_event_paranoid=-1 in the VM). Open a profile with `samply load <file>.profile.json.gz`.

k6 at this load (about 229 req/s, think-time bound, so latency here is not capacity):
- rust: avg 1.23 ms, p95 2.29 ms, p99 2.71 ms, 0 failed of 18317
- lean: avg 780 us, p95 1.66 ms, p99 2.37 ms, 0 failed of 18290

On-CPU samples of the busiest thread over the 20 s window (1 ms interval): rust 932, lean 2611, so Lean spends about 2.8x the CPU for the same request rate.

## Top self time
```
=== rust
samples on the busiest thread: 932  (1 ms interval, 20 s window)
531	57%	libc.so.6	syscall
50	5.4%	libc.so.6	pwrite
49	5.3%	feed-server	sqlite3BtreeTableMoveto
33	3.5%	feed-server	feed_server::serve
21	2.3%	libc.so.6	pread64
18	1.9%	feed-server	feed_server::Server::drain
18	1.9%	feed-server	feed_server::Server::run
16	1.7%	feed-server	pcache1Fetch
15	1.6%	feed-server	sqlite3VdbeExec
9	1%	feed-server	feed_server::json::Cur::esc
8	0.9%	feed-server	sqlite3_step
7	0.8%	feed-server	sqlite3BtreeIndexMoveto
=== lean
samples on the busiest thread: 2611  (1 ms interval, 20 s window)
519	19.9%	feed-server	io_uring_get_cqe
292	11.2%	feed-server	lean_alloc_small_object_core
206	7.9%	feed-server	mi_free
93	3.6%	feed-server	l_List_foldl___at___00Array_appendList_spec__0___redArg
74	2.8%	feed-server	l_List_toArrayAux___redArg
74	2.8%	feed-server	lean_dec_ref_cold
55	2.1%	libc.so.6	malloc
52	2%	feed-server	lean::lean_del_core_other(lean_object*, unsigned char, lean_object*)
52	2%	libc.so.6	pwrite
47	1.8%	feed-server	sqlite3BtreeTableMoveto
46	1.8%	feed-server	lp_iouring_x2dfeed_x2dserver_x2dlean_FeedServer_Json_escByte
43	1.6%	feed-server	mi_malloc
```
