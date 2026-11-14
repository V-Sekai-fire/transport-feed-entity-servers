# Tick budget on a GitHub Actions runner

The `tick-budget` job in `.github/workflows/ci.yml` builds `transports/csrc/entity_check.c` and runs the loopback check on an `ubuntu-24.04` hosted runner. It follows RFD66606-2442 (the metric) and RFD66606-2443 (the rung). Follow-up work is tracked in issue #7.

## What the job does

1. Prints `uname -r`, `nproc`, `lscpu -e` and every `thread_siblings_list`, then fails unless `nproc` is 4.
2. Builds the check with `cc -std=gnu99 -O2 -Wall -Wextra -Werror -pthread`.
3. Runs the planted 6 ms handler (`ENTITY_SLOW_NS=6000000`) 8 times. Every run must fail the 4 ms p99 budget.
4. Runs the clean check 8 times. Every run must pass, and each prints p50, p95, p99 and overruns.

The planted runs come first because of RFD66606-2427: a clean result counts only after the check has shown it can find the planted defect.

## What the numbers mean

- The check is loopback only. It measures the cost of the tick, not the network, and it is not a droplet measurement.
- A hosted runner is a shared virtual machine. One run is one sample, so read the 8 runs as a spread, with the runner conditions printed beside them.
- The first runs read the kernel as `7.0.0-1017-azure` and the thread siblings as `0-1` and `2-3`. The 4 vCPUs are 2 physical cores with SMT.

## Pinned layouts

`deploy/scripts/tick-layouts.sh` runs two `entity_serve` processes (ports 47321 and 47322, 192 ticks each) and one `entity_load` process that sends 160 packets from 4 sockets per port at 64 Hz. Each process is pinned to one vCPU with `taskset`, and the fourth vCPU is left alone. The script first checks that the thread siblings are `0-1` and `2-3`, because the layouts assume it.

| Layout | Server A | Server B | Loader | What it shows |
| --- | --- | --- | --- | --- |
| A, siblings share | 0 | 1 | 2 | the two servers share one physical core |
| B, siblings split | 0 | 2 | 1 | each server has its own core, the loader shares with A |

Each process prints its own `Cpus_allowed_list` from `/proc/self/status`, and the script fails if it differs from the vCPU it was pinned to. A control pins a server to vCPU 0 and requires that it does not read back as 1.

Per layout, the planted 6 ms handler goes on server B only, 8 times. Server B must fail the 4 ms budget and server A must pass, so a failure is attributed to the right process. Then 8 clean runs must pass on both servers. The p50, p95, p99 and max of every server in every run are printed, and the difference between the layouts is the finding. It is not a pass or fail by itself.

Without `taskset` the script stops, unless `ALLOW_UNPINNED=1` is set. That is for a desk without Linux, and the output then reads `cpus=n/a`.

## What it does not do

`taskset` keeps only our own processes on their vCPUs. It does not keep the kernel, interrupts or the runner agent off the unpinned vCPU, so no isolation is claimed. The numbers are loopback only and not a droplet measurement. Eight runs per layout on one runner is a spread, not a distribution across runners.

The original single-process check (`entity_check.c`) is unchanged and still runs unpinned in the first steps of the job.

## Client sweep

`deploy/scripts/client-sweep.sh` runs one `entity_serve` pinned to vCPU 0 and `entity_load` pinned to vCPU 2 (the other physical core), and steps the client count through 1, 4, 16, 64 and 256. 256 is the server's `ET_MAX_USERS`, so no level is over the server's cap. The loader's socket cap now follows `ET_MAX_USERS` too, so the top level is the tick and not the loader.

Per level it runs the planted 6 ms handler 8 times first. Every run must fail the 4 ms budget with the budget message, or the level has no valid p99 and the script fails. Then it runs 8 clean runs and prints p50, p95, p99 and overruns for each. A clean run over the budget is reported, not failed: where the clean p99 crosses 4 ms is the finding.

Bytes per tick are derived from the code, not measured: `XR_PACKET_SIZE` bytes in per client, and one datagram out per client of `min(clients, ET_VIEW)` packets. The script reads the packet size, view and user cap from the sources and prints them with each level.

The tick path holds entities in memory and does not touch the store, so the sweep can answer whether the tick itself binds. It cannot say whether the store binds.

Same caveats as above: loopback only, one runner, no isolation, not a droplet measurement, and eight runs per level is a spread, not a result.

### First run

Runner kernel `7.0.0-1017-azure`, `nproc` 4, siblings `0-1` and `2-3`. The control read a server pinned to 0 back as 0. Every level delivered all of its packets (`packets_in=` was 160 packets per client in every run), so the bytes in per tick are what arrived and not only what was sent. p99 is the spread over 8 runs, in microseconds.

| Clients | Bytes in per tick | Bytes out per tick | Planted caught | Planted p99 (run 1 and 8) | Clean p99 min to max | Clean over 4 ms |
| --- | --- | --- | --- | --- | --- | --- |
| 1 clients | 100 B | 100 B | 8 of 8 runs | 6022 µs, 6022 µs | 26 to 42 µs | 0 of 8 runs |
| 4 clients | 400 B | 1600 B | 8 of 8 runs | 6049 µs, 6050 µs | 57 to 66 µs | 0 of 8 runs |
| 16 clients | 1600 B | 19200 B | 8 of 8 runs | 6168 µs, 6140 µs | 171 to 207 µs | 0 of 8 runs |
| 64 clients | 6400 B | 76800 B | 8 of 8 runs | 6572 µs, 6586 µs | 656 to 689 µs | 0 of 8 runs |
| 256 clients | 25600 B | 307200 B | 8 of 8 runs | 7985 µs, 8041 µs | 2232 to 2396 µs | 0 of 8 runs |

What it shows: the clean p99 grows with the client count, about 4 times (ratio) for every 4 times the clients, and at the server's cap of 256 clients it is 2.2 to 2.4 ms, which is inside the 4 ms budget. No clean run went over the budget at any level. The planted p99 rises with the client count too, since the 6 ms handler adds to the tick's own work. The sweep stops at the server's `ET_MAX_USERS`, so it does not find where the clean p99 crosses 4 ms and says nothing about more than 256 clients.

The tick path does not touch the store, so none of these numbers say whether the store binds. Loopback, one runner, no isolation, not a droplet measurement.

## Units

Every number the harness prints carries its unit or a noun: latencies are `p50=126036ns`, counts are `packets_in=2560` and `datagrams_out=2768` (totals over the whole run, not bytes and not per tick), and the sweep summary puts `ns` on each value. A wrapper must not strip a unit, for example with `cut`. A parser that reads these lines must accept the suffix.

## io_uring probe

> Record only: `ring_probe.c` and its CI step were removed with the ring. The text below describes the job as it ran; the code is in git history before the unship commit.

`transports/csrc/ring_probe.c` runs first in `tick-budget`. It calls `io_uring_setup` directly (no liburing) and prints the `io_uring_disabled` setting, the `Seccomp:` line, the uid, and the result of three calls: a control with 0 entries, a plain ring of 8 entries, and an SQPOLL ring of 8 entries. A block is reported and does not fail the job. The job fails only if the control does not read back `EINVAL`, because then the probe is not reporting the kernel's answer.

First run, kernel `7.0.0-1017-azure`, uid 1001:

- `io_uring_disabled` was 0, which means io_uring is on for everyone.
- `Seccomp` was 0, which means no seccomp filter on the process.
- The control with 0 entries failed with `EINVAL`, as it must.
- The plain ring was created: 8 submission entries, 16 completion entries, features `0x3ffff`.
- The SQPOLL ring was created with the same sizes.

So the runner does not block io_uring, and the comparison against plain syscalls can run on it. That a ring can be created does not show that SQPOLL helps: with one vCPU per server it would poll on the tick's own core or take the spare, so it stays a separate labelled variant. One runner, one kernel, one run: a different runner image can answer differently, and every run of the job reprints the probe.

## Send path: plain, io_uring, io_uring with SQPOLL (removed)

> **Removed:** the io_uring and SQPOLL send paths, `ring_probe.c` and `ring-compare.sh` were unshipped from the entity server. The numbers below are the record that justified it: plain, ring and SQPOLL clean p99 ranges overlapped at 64 and 256 clients. The code is in git history before this commit; `study/ring-compare-run-1.txt` keeps the run output. The feed server's io_uring event loop is untouched.

`deploy/scripts/ring-compare.sh` ran `entity_serve_ring` three ways in run 1 and two ways in run 2 (`ring` was trimmed, see the last section); the script was then removed with the ring, at 64 and 256 clients: `plain` (one `sendto` per datagram), `ring` (one `sendmsg` per datagram queued on an io_uring, one submit, every completion reaped before the tick clock stops) and `sqpoll` (the same ring with SQPOLL, its kernel thread moved to vCPU 3, the spare). Server on vCPU 0, loader on vCPU 2. Per level and variant: 8 planted 6 ms runs that must each fail the budget, then 8 clean runs interleaved across the variants so drift on the VM lands on all three. The script fails any SQPOLL run whose kernel thread did not read back on vCPU 3.

**Only the send path differs.** Receive stays on plain syscalls in every variant, so the tick clock means the same for every variant. This is not a full ring server, and the numbers below say nothing about a ring receive path.

Run output: `study/ring-compare-run-1.txt`. Kernel `7.0.0-1017-azure`, `io_uring_disabled` 0, `Seccomp` 0.

| Clients | Variant | Planted caught | Clean p99 min, median, max (µs) | Clean over 4 ms |
| --- | --- | --- | --- | --- |
| 64 | plain | 8 of 8 runs | 456, 486, 532 | 0 of 8 runs |
| 64 | ring | 8 of 8 runs | 463, 524, 791 | 0 of 8 runs |
| 64 | sqpoll | 8 of 8 runs | 465, 498, 658 | 0 of 8 runs |
| 256 | plain | 8 of 8 runs | 1684, 1710, 1966 | 0 of 8 runs |
| 256 | ring | 8 of 8 runs | 1667, 1733, 2325 | 0 of 8 runs |
| 256 | sqpoll | 8 of 8 runs | 1717, 1773, 2823 | 0 of 8 runs |

The SQPOLL kernel thread read back on vCPU 3 in 32 of 32 SQPOLL runs. The first CI run found it in 4 of 32 runs, so the other 28 had the thread on the server's vCPU. That is why the script now forces the thread to exist with a NOP before looking, and fails a run that does not read back on vCPU 3.

What it shows: at both levels the clean p99 ranges of the three variants overlap, so this run finds no difference between them. The ring medians sit 38 µs (64 clients) and 23 µs (256 clients) above plain, inside the spread of 8 runs, and its maximum is the largest of the three at 256 clients after SQPOLL. At 256 clients plain makes 256 `sendto` calls per tick. Replacing them with one submit did not move the p99, so at this load the per-call syscall entry is not what the tick spends its time on. The copy of each 1200-byte datagram into the loopback receive path happens in the kernel either way.

What it does not show: a gain from a ring receive path, behaviour with more than 256 clients, or anything off loopback. One runner, 8 runs per variant and level, no isolation. In some plain and SQPOLL runs `datagrams_out` read above 44288 at 256 clients (44800 and 47104 in one run each) because the count follows when the loader's first packets reach the server, not the variant.

## Client sweep past 256: the latency wall

`ET_MAX_USERS` is now 4096 (about 11 MB of static data, still no heap in the tick). The `tick-wall` job runs `client-sweep.sh` at 256, 384, 512, 640, 768, 1024, 1536, 2048, 3072 and 4096 clients: 8 clean runs and 3 planted 6 ms runs per level, and it stops after 2 consecutive wall levels. A wall is reported, not failed. A level counts as a wall when a clean run goes over the 4 ms budget, a tick overruns its 15.6 ms slot, or `packets_in` falls below 160 per client. A level where the loader falls behind is loader-bound, and the sweep stops there because the server was not the limit.

The planted control changed. Once clean runs pass 4 ms, every planted run is over budget too, so "caught" stops meaning anything. The control is now the planted p50 sitting at least 5 ms above the clean p50 of the same level. It held at every level: 5.91, 5.95 and 5.99 ms.

Run output: `study/wall-sweep-run-1.txt`. Kernel `7.0.0-1017-azure`, 4 vCPUs, UDP receive buffer 1,048,576 bytes by default, 65,536 open descriptors.

| Clients | Bytes in per tick | Bytes out per tick | Clean p50 median (µs) | p50 per client (ns) | Clean p99 min to max (µs) | Clean over 4 ms | Overruns | Packets lost | Loader worst pass (µs) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 256 | 25,600 | 307,200 | 1673 | 6536 | 2280 to 3859 | 0 of 8 runs | 0 of 8 runs | 0 of 8 runs | 3129 |
| 384 | 38,400 | 460,800 | 2422 | 6307 | 3448 to 5161 | 1 of 8 runs | 0 of 8 runs | 0 of 8 runs | 4537 |
| 512 | 51,200 | 614,400 | 3191 | 6231 | 4593 to 4920 | 8 of 8 runs | 0 of 8 runs | 0 of 8 runs | 4916 |

**The wall is between 384 and 512 clients.** At 384 clients 7 of 8 clean p99 values sit between 3.4 and 3.7 ms and one reached 5.16 ms. At 512 clients every run is over, from 4.59 to 4.92 ms. The sweep stopped there on its own rule. The wall is in the tick's own work, not in the apparatus:

- No packet was lost at any level (`packets_in` equalled 160 per client), so the receive buffer did not bind before the tick did.
- No tick overran its 15.6 ms slot. Clean p50 at 512 clients is 3.2 ms, about 20 % of the slot, so the budget of 4 ms on p99 binds long before the slot does.
- The loader never fell behind (`slow_passes` was 0). Its worst send pass was 4.9 ms against a 15.6 ms tick.

**The cost per client did not rise.** The clean p50 per client went 6536, 6307, 6231 ns from 256 to 512 clients, which is flat to slightly falling. So up to 512 clients the tick is paying a per-client cost (receive, copy, 1200-byte `sendto`) and not the quadratic cost of the linear `find()` scan. The wall is p99 growing with p50 at about 1.4 to 1.5 times, not a new term appearing. The earlier fit of 10 µs plus 5 µs per client predicted a crossing near 600 to 700 clients. This run costs about 6.3 µs per client, so it crossed earlier. The first sweep's 256-client p50 was 1297 µs and this one's is 1673 µs, so that is runner variance: compare levels within one job, not across jobs.

What it does not show: where the slot overruns (the sweep stopped at 512 clients), a gain from any send variant at the wall, or anything off loopback. One runner, 8 runs per level, no isolation, tick cost only and not end-to-end latency. `rcvbuf_drops` read -1 in all 33 runs, meaning `SO_MEMINFO` was not available, so kernel drops on the server socket were not read. Loss is judged from `packets_in` alone.

### Trim: the `ring` variant

The plain io_uring variant (`ring`) is removed from `entity_serve` and `ring-compare.sh`. Reason: it is dominated. It never wins an axis in either record, and it adds a code path.

- CI run 1 (table above): ring median is above plain at 64 and 256 clients, and its maximum is second-worst at 256.
- Second 8-run set from iFire, same CI runner as run 1 (raw values in `study/ring-compare-run-2.py`), p99 mean (ns, std): 64 clients plain 666761 (15121), ring 699934 (39170), sqpoll 559967 (20859). 256 clients plain 2238279 (27614), ring 2260388 (45861), sqpoll 2166475 (193243).
- Spread-penalised budget, period / (1 + 4 cs) with cs = std / mean (a proxy: this std is across runs of the p99, not frame time, and the rule was set for 144 Hz). Factor 1+4cs at 64 clients: plain 1.09, ring 1.22, sqpoll 1.15. At 256 clients: plain 1.05, ring 1.08, sqpoll 1.36. So ring has the least headroom at 64, and sqpoll the least at 256.

Kept: `plain` (lowest spread, no extra core) and `sqpoll` (lowest mean at 64 clients, but costs vCPU 3 and has the widest spread at 256, so it is opt-in). The 256-client gap between sqpoll and plain (72 us) is inside sqpoll's spread at 8 runs; it is not shown. The ring-vs-plain gap is not statistically shown either (n = 8); the trim rests on dominance and cost, not on a proven slowdown. The recorded ring rows above stay as history. To re-measure ring, check out the commit before this one.

Later: `sqpoll` was removed too, and `plain` is now the only send path. The reasons are the rule above (it wins no axis that justifies a second code path) and RFD66606-2360, which ships one win64 build where io_uring cannot run. The tables in this file stay as the record of what was measured.

Frontier learning check (RFD66606-2427, the sense of a level from RFD66606-2309). A clean result counts only after its level caught the planted defect in each of the last eight runs. In run 2 all three variants caught it 8 of 8 at both levels (about 6.5 ms at 64 clients, 8.0 to 8.7 ms at 256), so regret 1[s >= 1] - s/n is 0 for every cell and the clean p99 values are valid. No cell is the frontier by that measure. The open question is a different one: the 256-client sqpoll against plain gap is inside sqpoll's spread. The next runs should go to that level, with more than 8 clean runs, before `sqpoll` is called faster there.

Run 2 and run 1 share a runner but disagree on level: plain at 64 clients is a median of 486 us in run 1 and a mean of 667 us in run 2. That 37% drift between runs on one runner is larger than any ring-against-plain gap in either run, which is why the trim rests on dominance and cost, not on a measured slowdown.

### Second run (CI rerun on the rebased branch)

The same job ran again on the branch after it was rebased onto `dev/entity-server` with #24. Run output: `study/wall-sweep-run-2.txt`. The sweep did not stop at 512 clients this time, because 384 clients had no over-budget run, so 512 and 640 were the two consecutive wall levels.

| Clients | Clean p50 median (µs) | p50 per client (ns) | Clean p99 min to max (µs) | Clean over 4 ms | Overruns | Packets lost |
| --- | --- | --- | --- | --- | --- | --- |
| 256 | 1659 | 6479 | 2273 to 2359 | 0 of 8 runs | 0 of 8 runs | 0 of 8 runs |
| 384 | 2409 | 6272 | 3449 to 3687 | 0 of 8 runs | 0 of 8 runs | 0 of 8 runs |
| 512 | 3163 | 6176 | 4631 to 4870 | 8 of 8 runs | 0 of 8 runs | 0 of 8 runs |
| 640 | 3949 | 6169 | 5768 to 5831 | 8 of 8 runs | 0 of 8 runs | 0 of 8 runs |

Both runs bracket the wall the same way: inside the budget at 256 clients, over it in every run at 512 clients, and 384 clients sits on the edge (1 of 8 runs over in run 1, 0 of 8 in run 2, with the worst clean p99 at 5161 µs in run 1 and 3687 µs in run 2). Treat the wall as "between 384 and 512 clients", not as a client count. The p50 per client keeps falling slightly through 640 clients (6479, 6272, 6176, 6169 ns), so the session scan in `find()` has not shown up as a quadratic term yet. The planted p50 stayed 5.91 to 6.01 ms above the clean p50 at every level, so the control discriminated past the wall. Still no packet lost and no overrun at 640 clients, where the clean p50 is 3.9 ms, about 25 % of the 15.6 ms slot.

## One server against two servers (a HORZ split)

`client-sweep.sh` takes `SERVERS=2`: each level splits evenly over two servers on vCPU 0 and 2 (separate physical cores), the loader on vCPU 3, the planted 6 ms handler on server 1 only. `tick-wall` runs 512, 640 and 1024 clients as one server and as two, level by level, 8 clean runs and 3 planted runs each, so runner drift lands on both. The loader sits on vCPU 3 in both modes. The earlier single-server sweeps had it on vCPU 2, the same physical core, so compare these rows with each other and not with the wall-sweep tables.

Run output: `study/two-servers-run-1.txt`. 64 Hz, 4 ms p99 budget, loopback, one runner. **No entity is shared between the servers, so there is no border traffic. This is the best case for a split.**

Clean p99 median (min to max), in µs:

| Clients | One server | Two servers: server 0 | Two servers: server 1 | Over 4 ms, one server | Over 4 ms, two servers |
| --- | --- | --- | --- | --- | --- |
| 512 | 4037 (3884 to 6219) | 1945 (1934 to 2118) | 2176 (2148 to 2293) | 4 of 8 runs | 0 of 8 runs |
| 640 | 4868 (4816 to 6125) | 2547 (2408 to 3890) | 2737 (2613 to 3683) | 8 of 8 runs | 0 of 8 runs |
| 1024 | 8439 (7518 to 15231) | 3858 (3749 to 3899) | 4164 (4013 to 4336) | 8 of 8 runs | 8 of 8 runs |

Clean p50 per client, in ns: one server 5134, 5116, 5350 at 512, 640, 1024 clients; server 0 5078, 5143, 5107; server 1 5172, 5224, 5207. Splitting did not change the cost per client.

Predictions written before the run, against the result:

- **Two servers at 640 clients, about 2.9 ms on each, 0 of 8 runs over: held.** Medians were 2.55 and 2.74 ms, 0 of 8 runs over.
- **Two servers at 512 clients, about 2.3 ms, 0 of 8 runs over: held.** Medians were 1.95 and 2.18 ms.
- **Two servers at 1024 clients, over in 8 of 8 runs (the negative control): held, by server 1 only.** Server 1 was over in every run (4.01 to 4.34 ms). Server 0 stayed under (3.75 to 3.90 ms), and the run counts as over because the slowest server was.
- **One server at 512 clients, over in 8 of 8 runs: missed.** It was over in 4 of 8 runs. Both earlier wall sweeps had 8 of 8. This runner cost 5.1 µs of p50 per client against 6.2 to 6.5 µs there, so the 512-client wall sat closer to 640 clients in this job. That is runner drift. It is why levels are compared inside one job.
- **Falsifier: p99 above 3.6 ms on a server at 640 clients, or a gap above 0.3 ms between servers: partly tripped.** 2 of 8 runs had one server above 3.6 ms (3.89 and 3.68 ms single-run p99), while the medians sit at 2.55 and 2.74 ms, so those are tail events and not a level shift. The gap between the servers' p99 medians was 0.19 ms at 640 clients, and 0.23 and 0.31 ms at 512 and 1024 clients, so it crossed 0.3 ms at 1024 clients.

**Server 1 is consistently slower than server 0**, by 1.5 to 2.0 % of p50 and 9 to 12 % of p99 median at all three levels. Server 1 runs on vCPU 2, whose SMT sibling vCPU 3 carries the loader, while server 0's sibling vCPU 1 is idle. That fits a cost from sharing a core with the loader. It is one placement and one run, so this does not isolate SMT from the loader's memory traffic. Swapping the two servers' vCPUs would test it.

**The planted defect on server 1 did not reach server 0.** Server 0's p50 median in the planted runs against its clean median: +11 µs at 512 clients, -14 µs at 640 and -21 µs at 1024, which is noise on either side of zero. The planted control held on server 1 at every level (its p50 sat 6.24, 6.30 and 6.29 ms above its clean p50). No tolerance was set on the server 0 figure; the numbers are reported.

What it shows: at 64 Hz on this VM, two 320-client cells are served at about half the p99 of one 640-client cell, with no loss, no overrun and the same cost per client. The 4 ms wall moves from 512 to 640 clients (one server) to between 640 and 1024 clients (two servers, where server 1 crosses first). At 1024 clients the single server also overran its slot in 1 of 8 runs and lost packets in 2 of 8 runs; the two-server run had neither.

What it does not show: any cost of a shared border (the open interest-grid and server-to-server boxes in #7), 144 Hz, or a split across hosts. Four vCPUs are shared by two servers and a loader, so a split onto real separate machines is not tested here.

### Second run (CI rerun on the branch rebased onto main)

Run output: `study/two-servers-run-2.txt`. Same job, same levels. This runner cost about 6.5 to 6.8 µs of p50 per client against 5.1 µs in the first run, so compare rows inside one run, not across the two.

Clean p99 median (min to max), in µs:

| Clients | One server | Two servers: server 0 | Two servers: server 1 | Over 4 ms, one server | Over 4 ms, two servers |
| --- | --- | --- | --- | --- | --- |
| 512 | 4869 (4816 to 5298) | 2396 (2373 to 2413) | 2873 (2832 to 2912) | 8 of 8 runs | 0 of 8 runs |
| 640 | 6092 (6038 to 6619) | 2988 (2949 to 3280) | 3603 (3389 to 3662) | 8 of 8 runs | 0 of 8 runs |
| 1024 | 9842 (9715 to 9977) | 4864 (4689 to 5444) | 5720 (5667 to 5790) | 8 of 8 runs | 8 of 8 runs |

- **One server at 512 clients was over in 8 of 8 runs.** The first run had 4 of 8. The prediction that missed in the first run holds in the second, so that miss was runner drift. Neither run says where inside 384 to 512 clients the wall sits.
- **Two servers at 640 clients stayed under 4 ms in 0 of 8 runs over.** The slower server's p99 median was 3.60 ms and its largest was 3.66 ms. That is close to the budget, and 4 of 8 runs had a server above 3.6 ms. The first run had 2 of 8.
- **The prediction of about 2.9 ms per server at 640 clients held for server 0 (2.99 ms) and not for server 1 (3.60 ms).**
- **Server 1 was slower than server 0 again, and by more.** The p99 medians differ by 0.48, 0.62 and 0.86 ms at 512, 640 and 1024 clients (first run: 0.23, 0.19 and 0.31 ms). The p50 medians differ by only 17, 16 and 63 µs (1.0, 0.8 and 1.9 %). So the gap is in the tail, not in the typical tick. The 0.3 ms gap falsifier was tripped at every level in this run.
- **The split still halves the tail.** At 640 clients the slowest server's p99 median is 3.60 ms against 6.09 ms for one server. The cost per client was the same in both modes within a run (6.5 to 6.8 µs).
- **The planted defect on server 1 did not move server 0.** Server 0's p50 median in the planted runs against its clean median: +0.7 µs at 512 clients, -8 µs at 640 and -30 µs at 1024. Server 1's planted p50 sat 6.34, 6.41 and 6.31 ms above its clean p50.

Server 1 runs on vCPU 2, whose SMT sibling vCPU 3 carries the loader. Server 0's sibling, vCPU 1, is idle. A tail gap that grows with the load fits sharing a core with the loader, and it is only a fit: both runs used one placement. Swapping the servers' vCPUs would separate the core from the process. Until then, read the two-server rows as "the slower server of a pair", and plan on about 0.5 to 0.9 ms of extra p99 for the server that shares a core.

## Send path attribution: the sendto calls against the rest of the tick

`entity_serve ... nosend` runs the full tick and skips the `sendto` calls (a control, not a send path). The `tick-nosend` job ran it at 256, 384, 512 and 640 clients with 8 clean runs and 3 planted 6 ms runs per level. The `tick-wall` job ran `plain` in the same CI run (42412589675). Raw output: `study/send-control-run-1.txt`. Kernel `7.0.0-1017-azure`, 4 vCPUs, server on vCPU 0, loader on vCPU 2.

| Clients | Clean p50 per client, plain (ns) | Clean p50 per client, nosend (ns) | Difference (ns) | Share in the sendto calls | Clean p99 min to max, plain (µs) | Clean p99 min to max, nosend (µs) | Clean over 4 ms, plain | Clean over 4 ms, nosend |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 256 | 6434 | 1478 | 4956 | 77 % | 2300 to 2389 | 437 to 486 | 0 of 8 runs | 0 of 8 runs |
| 384 | 6342 | 1545 | 4797 | 76 % | 3521 to 3620 | 645 to 711 | 0 of 8 runs | 0 of 8 runs |
| 512 | 6191 | 1562 | 4629 | 75 % | 4610 to 5300 | 886 to 1731 | 8 of 8 runs | 0 of 8 runs |
| 640 | 6149 | 1570 | 4579 | 74 % | 5761 to 7212 | 1134 to 1204 | 8 of 8 runs | 0 of 8 runs |

What it shows: about three quarters of the per-client cost is in the `sendto` calls, and the rest (receive plus the copy of a 1200-byte datagram) is about 1500 ns per client. With the sends skipped, no clean run went over 4 ms through 640 clients, so the wall found above is the send path. The planted 6 ms handler was caught in 3 of 3 runs at every nosend level, with the planted p50 5.99 to 6.01 ms above the clean p50, so the nosend levels are valid under the same rule as the sweep above. The 512-client nosend p99 maximum (1731 µs against a minimum of 886 µs) is one run, not a trend.

What it does not show:
- On loopback the sender runs the receiving socket's work inside `sendto`, so the 74 to 77 % share is an upper bound for a real network card.
- `plain` and `nosend` ran in different jobs, so on different runner VMs. The ring record above showed a 37 % drift between runs on one runner. The ratio is robust to that and the absolute nanoseconds are not.
- Under `nosend`, `datagrams_out` counts nothing real.
- One runner, 8 clean runs per level, no isolation, loopback only.

## Send path: plain against sendmmsg

A `sendmmsg` variant of `entity_serve` (Linux only) sent the tick's datagrams with one `sendmmsg` call per up to 1024 datagrams instead of one `sendto` each. It was trimmed and is not in the tree. The code is commit `3a0a6f6` on branch `dev/sendmmsg` (pull request 33, closed unmerged). The `tick-sendmmsg` job ran the plain sweep and then the sendmmsg sweep back to back in one job, so both ran on the same runner VM. They were not interleaved run by run. Levels 384, 512, 640 and 768 clients, 8 clean runs and 3 planted 6 ms runs per level. CI run 42413745711, kernel `7.0.0-1017-azure`, server on vCPU 0, loader on vCPU 2. Raw output: `study/sendmmsg-run-1.txt`.

| Clients | Clean p50 per client, plain (ns) | Clean p50 per client, sendmmsg (ns) | Gap (ns) | Clean p99 min to max, plain (µs) | Clean p99 min to max, sendmmsg (µs) | Clean over 4 ms, plain | Clean over 4 ms, sendmmsg |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 384 | 4534 | 4562 | +28 | 2458 to 5924 | 2473 to 5398 | 3 of 8 runs | 4 of 8 runs |
| 512 | 4580 | 4535 | -45 | 3289 to 6422 | 3234 to 5354 | 4 of 8 runs | 4 of 8 runs |
| 640 | 4544 | 4621 | +77 | 4051 to 7554 | 4109 to 6739 | 8 of 8 runs | 8 of 8 runs |
| 768 | 4583 | 4657 | +74 | 4762 to 7672 | 4845 to 10180 | 8 of 8 runs | 8 of 8 runs |

What it shows: `sendmmsg` saved nothing. The gap is between -1 % and +2 % of the per-client cost and changes sign, which is inside run-to-run spread. The wall did not move: both variants have clean runs over 4 ms at 384 and 512 clients and all 8 over at 640 and 768. The planted 6 ms handler was caught in 3 of 3 runs at every level in both sweeps. The prediction written in the pull request was a saving of 5 to 15 %, from syscall entry and exit alone. It was wrong in direction of effect, not in size: there is no saving to measure at 8 runs.

What that implies, together with the nosend control above: skipping the sends removes about 75 % of the per-client cost and batching them removes none. So the cost is not the syscall. It is the per-datagram work inside it: the UDP stack and, on loopback, the receiving socket's work.

What it does not show:
- On loopback the sender pays the receiver's work. On a real network card a batched send may behave differently.
- The two sweeps ran back to back, not interleaved, so drift inside the job is not spread across the variants.
- The plain figures here (about 4550 ns per client) sit 28 % below the `tick-wall` job's (about 6300 ns) from another runner VM. Only comparisons within one job are meaningful.
- Windows has no `sendmmsg`, and the shipped build is win64.
- One runner, 8 clean runs per level, no isolation.

Under the rule in the trim section above (a variant that wins no axis is trimmed), `sendmmsg` was trimmed. This section and `study/sendmmsg-run-1.txt` are the record.

### Which vCPU is slow: placement against send order

#29 left the server on vCPU 2 slower in the tail (p99 gap 0.19 to 0.86 ms, p50 gap under 2 %). Two explanations fit: server 1 shares a core with the loader (vCPU 2 and 3 are SMT siblings), or `entity_load` sends all of port 0 before port 1 in each pass so server 1's datagrams always arrive later. `tick-wall` ran the 2x2 at 640 clients in one job: the servers' vCPUs (`SERVER_CPUS`) against the loader's send order (`ENTITY_LOAD_ORDER`, blocked or interleave), ABBA order, 2 visits of 8 clean and 3 planted runs per cell, so 16 clean runs per cell. Loader on vCPU 3 throughout. Run output: `study/placement-order-run-1.txt`.

Clean runs, medians over 16 runs, in µs:

| Servers on vCPU | Send order | Server 0: p50, p99 | Server 1: p50, p99 | Server 1 minus server 0: p50, p99 |
| --- | --- | --- | --- | --- |
| 0 and 2 | blocked | 2155, 2995 | 2169, 3611 | +13, +616 |
| 0 and 2 | interleave | 2148, 3028 | 2200, 3615 | +52, +587 |
| 2 and 0 | blocked | 2250, 3631 | 2172, 3032 | -78, -600 |
| 2 and 0 | interleave | 2192, 3598 | 2114, 2967 | -77, -630 |

Pooled over all four cells (64 runs each): the server on vCPU 0 had a p99 median of 3021 µs and the server on vCPU 2 had 3611 µs, a gap of 590 µs. Pooled by sent-to position instead: server 0 had 3508 µs and server 1 had 3472 µs, a gap of 36 µs. No clean run was over the 4 ms budget in any visit. The planted p50 sat 5.94 to 6.53 ms above the clean p50 in every visit.

Predictions written before the run, against the result:

- **Core: the server on vCPU 2 is slower in all four cells by about 0.5 ms or more. Held.** Its p99 was 587 to 630 µs above the other server's in every cell.
- **Core: swapping the vCPUs moves the slow label to the other server. Held.** The sign of the gap flipped from +616 and +587 µs to -600 and -630 µs.
- **Send order: interleaving shrinks the gap to under 0.1 ms. Not seen.** The gap was 616 µs blocked and 587 µs interleaved with servers on 0 and 2, and -600 against -630 µs swapped.
- **Neither: the gap stays 0.2 ms or more in all four cells. Not the case for the order, but the gap did stay at 0.59 to 0.63 ms in all four.**

What it shows: the extra tail follows the vCPU, not the server index and not the loader's send order. The vCPU 2 penalty is about 0.6 ms of p99 at 640 clients, 590 µs pooled, and it is a tail effect: the p50 gap was 13 to 78 µs with mixed sign.

What it does not show:

- **Whether the interleave setting was applied in run 1.** The loader's `order=` field was not in the printed output of run 1, so that log cannot prove it. Run 2 below prints it and shows it applied.
- **Why vCPU 2 is slower.** Sharing a core with the loader on vCPU 3 fits, but vCPU 2 could differ from vCPU 0 for another reason. Moving the loader to vCPU 1, the sibling of vCPU 0, would separate the two: if the penalty moves to vCPU 0, it is the loader's core.

Planning figure: a server on the loader's core pays about 0.6 ms of extra p99 at 640 clients at 64 Hz. Keep the loader off the servers' cores on a real deployment, which this harness cannot show. One runner, loopback, no shared entities.

#### Second run (CI rerun after the loader's `order=` field was printed)

Run output: `study/placement-order-run-2.txt`. Same job, same 2x2, ABBA order, 16 clean runs per cell. Every one of the 22 loader lines in each cell read back the order that cell asked for, so the interleave setting reached the loader.

Clean runs, medians over 16 runs, in µs:

| Servers on vCPU | Send order | Server 0: p50, p99 | Server 1: p50, p99 | Server 1 minus server 0: p50, p99 |
| --- | --- | --- | --- | --- |
| 0 and 2 | blocked | 2198, 3059 | 2227, 3666 | +29, +606 |
| 0 and 2 | interleave | 2255, 3126 | 2291, 3700 | +35, +573 |
| 2 and 0 | blocked | 2339, 3677 | 2240, 3078 | -100, -599 |
| 2 and 0 | interleave | 2319, 3700 | 2239, 3052 | -80, -647 |

Pooled over all four cells (64 runs each): the server on vCPU 0 had a p99 median of 3074 µs and the server on vCPU 2 had 3687 µs, a gap of 613 µs. Pooled by sent-to position: server 0 had 3599 µs and server 1 had 3575 µs, a gap of 24 µs (server 0 slower this time). The planted p50 sat 5.96 to 6.44 ms above the clean p50 in every visit.

- **The result of run 1 holds.** The tail penalty follows the vCPU: about 0.6 ms of p99 on vCPU 2 in all four cells (573 to 647 µs), with the sign flipping when the servers swap. Interleaving the send order moved the gap by 33 µs at most (606 to 573 µs, and 599 to 647 µs), inside the spread between the two runs. So send order is not the cause.
- **This runner was slower than run 1.** The pooled p99 on vCPU 0 rose from 3021 to 3074 µs and on vCPU 2 from 3611 to 3687 µs. Compare cells inside one run.
- **Clean runs over the 4 ms budget: 5 of 64 runs in run 2 (visits to the cells with servers on 0 and 2: 2 of 8 runs twice; servers on 2 and 0, interleave: 1 of 8 runs), 0 of 64 runs in run 1.** The server on vCPU 2 is the one near the budget, with a p99 median of 3.69 ms at 640 clients, 0.31 ms below it. Treat 640 clients as the edge for the server that shares a core with the loader.

What it shows: at 640 clients the server on the loader's core pays about 0.6 ms of extra p99, which is 9 % of a 6.94 ms period at 144 Hz (unmeasured there). Not shown: whether the penalty comes from sharing the core's execution units or its caches with the loader, or from something specific to vCPU 2. Moving the loader to vCPU 1, the sibling of vCPU 0, would separate those: if the penalty moves to vCPU 0, it is the loader's core. One runner, 64 Hz, loopback, no shared entities.


## Receive through io_uring (2026-11-14)

The send paths were measured in the sections above and made no difference. The receive side was
not. On a Fly machine (performance-2x, Linux 6.12, `rmem_max` 212,992) the plain `recvfrom` loop
lost packets as clients rose, and the p99 of the tick looked fine while it did so, because a server
that receives half the packets does half the work.

`ENTITY_RECV=ring` receives through one multishot `recvmsg` into a provided-buffer ring (raw
syscalls, no liburing, no heap; `entity_tick.c`). Packets leave the socket as they arrive and the
tick only reaps completions. The plain path is the default and the fallback, and non-Linux builds
compile the ring out. The server and loader shared the machine over `::1`, 380 sends a client:

| Clients | Receive | Packets received | p50 | p99 | Drops |
| --- | --- | --- | --- | --- | --- |
| 256 | plain | 100% | 2.25 ms | 4.19 ms | 0 |
| 256 | ring | 100% | 1.82 ms | 2.91 ms | 0 |
| 512 | plain | 50.2% | 2.21 ms | 3.72 ms | 96,900 |
| 512 | ring | 100% | 4.08 ms | 5.85 ms | 0 |
| 1,024 | plain | 43.0% | 5.30 ms | 7.75 ms | 221,689 |
| 1,024 | ring | 100% | 10.67 ms | 28.04 ms | 0 |

So the score to quote is clients at p99 under 4 ms with every packet received. Plain receive gets
under 256; the ring holds 256 at 2.9 ms, and 512 with all packets takes 5.9 ms. The knee between 256
and 512 was not found. The p99 at 512 and 1,024 is higher with the ring because the server now does
all of the work it was sent. Same machine, loopback, two vCPUs shared with the loader: this is a
comparison of the two receive paths, not a capacity.
