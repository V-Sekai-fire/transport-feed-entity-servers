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
