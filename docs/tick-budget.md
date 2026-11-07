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

`transports/csrc/ring_probe.c` runs first in `tick-budget`. It calls `io_uring_setup` directly (no liburing) and prints the `io_uring_disabled` setting, the `Seccomp:` line, the uid, and the result of three calls: a control with 0 entries, a plain ring of 8 entries, and an SQPOLL ring of 8 entries. A block is reported and does not fail the job. The job fails only if the control does not read back `EINVAL`, because then the probe is not reporting the kernel's answer.

First run, kernel `7.0.0-1017-azure`, uid 1001:

- `io_uring_disabled` was 0, which means io_uring is on for everyone.
- `Seccomp` was 0, which means no seccomp filter on the process.
- The control with 0 entries failed with `EINVAL`, as it must.
- The plain ring was created: 8 submission entries, 16 completion entries, features `0x3ffff`.
- The SQPOLL ring was created with the same sizes.

So the runner does not block io_uring, and the comparison against plain syscalls can run on it. That a ring can be created does not show that SQPOLL helps: with one vCPU per server it would poll on the tick's own core or take the spare, so it stays a separate labelled variant. One runner, one kernel, one run: a different runner image can answer differently, and every run of the job reprints the probe.

## Send path: plain, io_uring, io_uring with SQPOLL

`deploy/scripts/ring-compare.sh` runs `entity_serve_ring` three ways at 64 and 256 clients: `plain` (one `sendto` per datagram), `ring` (one `sendmsg` per datagram queued on an io_uring, one submit, every completion reaped before the tick clock stops) and `sqpoll` (the same ring with SQPOLL, its kernel thread moved to vCPU 3, the spare). Server on vCPU 0, loader on vCPU 2. Per level and variant: 8 planted 6 ms runs that must each fail the budget, then 8 clean runs interleaved across the variants so drift on the VM lands on all three. The script fails any SQPOLL run whose kernel thread did not read back on vCPU 3.

**Only the send path differs.** Receive stays on plain syscalls in every variant, so the tick clock means the same for all three. This is not a full ring server, and the numbers below say nothing about a ring receive path.

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

