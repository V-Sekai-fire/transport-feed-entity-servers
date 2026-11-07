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

## What it does not do

The target layout is two server processes with one vCPU each, one vCPU for the load generator and one spare for the OS and the runner agent. The job does not pin or isolate anything yet. The check is a single process with four client threads, so the layout needs a change to the harness first. Pinning must account for the sibling pairs above, and `taskset` keeps only our own processes on their vCPUs, not the kernel, interrupts or the runner agent.
