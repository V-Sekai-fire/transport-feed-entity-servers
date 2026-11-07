# CI reliability and latency spread, 2026-11-07

How many nines `transport-feed-entity-servers` CI (named `transport-iouring-feed-server` when the runs were collected) shows, and how its tick latency varies, set beside Discord's published figures. The scripts and raw data are in `study/`. Run them with `pixi exec -s python=3.12 python study/<script>.py` from inside `study/`. `collect.py`, `logs.py` and `spread.py` need `gh` and `bao-mint-github`.

## Conditions

- All 40 runs of `ci.yml` fall in one 2h28m window on 2026-11-07, on one runner image (kernel `7.0.0-1017-azure`), and cover 25 distinct head commits. `contract-entity-packet` has 15 runs from 2026-08-12 to 2026-11-07, all green.
- The tick numbers are loopback tick-to-send on GitHub runners. They include no store and no network.
- Discord has no uptime endpoint on its status page (it returned 404). Its availability is computed from incident durations in the last 90 days, counting each incident as a full outage and merging overlaps, so it is pessimistic. Its latency is the status page's "API Response Time" series, already averaged over 5 minutes, in units the page does not state.
- The run history gave no usable queue time: `run_started_at` equals `created_at` on every run.

## CI outcomes

- 5 of 25 commits went red, all from code defects and none from the runner: a missing `-lfdb_c` link, the same live-check assertion on two consecutive commits, a missing `sqlite-check` binary, and a `-Werror` format-truncation in a new header.
- No commit gave different outcomes on the same SHA. There were no reruns and no cancellations.
- 0 flakes in 25 commits bounds the flake rate at about 12% (rule of three, 95%), which is under one nine. The same count over the 15 `contract-entity-packet` runs bounds it at about 20%.
- All 39 `fdb-open` job runs got past the install steps, which pair up per commit, so about 25 independent trials.

## Tick latency

`spread.py` reads the `tick-budget` logs of the 13 successful jobs. Run it to reproduce.

- `entity_check`, 104 clean runs of 64 ticks (6,656 ticks, 0 overruns): p50 median 41 µs, p99 median 72 µs and at most 177 µs, p99/p50 median 1.6 and at worst 4.6. The p99 equals the maximum in 104 of 104 runs, because a 64-tick run has its 99th percentile at the last sample, so these p99 figures show no tail.
- Pinned-layout servers, 96 clean server runs of 192 ticks: p50 median 39 µs, p99 median 63 µs and at most 122 µs, max/p50 at worst 5.9. The worst single tick was 240 µs, 1.5% of the 15.6 ms period.
- Between runs the p50 itself moves by a standard deviation over mean of about 0.2, which is the VM effect.
- The planted 6 ms handler gave p99 of 6.03 to 6.46 ms over 152 samples, with no misses.
- 0 overruns in 6,656 ticks bounds the per-tick overrun rate at about 4.5e-4. Samples within a job share a VM, so the independent count is 13 jobs, which bounds a job-level stall at about 23%.

## Discord

`discord.py` reproduces these from `inc.json` and `m_*.json`.

- Availability over 90 days: 98.94% (1.97 nines) counting major and minor incidents on the whole service, 99.05% counting major only, 99.95% (3.3 nines) for the one incident tagged API or Gateway. Many incidents carry no component tag, so the last figure is probably generous.
- API Response Time: day view median 152, p99 481, max 529 (p99/p50 3.2, standard deviation over mean 0.29); week view median 147, p99 193; month view median 150, p99 194, p99/p50 1.3. The week and month views average more time per point and hide more of the tail.

## What this does and does not show

- No nines are demonstrated yet. Matching Discord's whole-service 2.0 nines needs about 300 clean independent runs, and its API and Gateway 3.3 nines about 6,000. Runs on one commit or one VM are not independent, so only different days and different runners count.
- Our median p99/p50 of 1.6 sits between Discord's month (1.3) and day (3.2) figures. Our worst runs reach 4 to 6 times the median, which Discord's 5-minute averages could not show, so the difference is not established.
- The absolute values are not comparable: Discord is an internet round trip of about 150 ms and ours is a loopback tick of tens of microseconds.
- The network rule that said not to probe or model the network was rescinded on 2026-11-07, so a real latency series between two hosts is now allowed. None has been taken.

## Errata

- The margin section of `logs.py` reads only the single-process `entity_check` runs. `spread.py` supersedes it and also reads the pinned-layout runs, after stripping the timestamp prefix from each log line.
- `collect.py` stores the run history as `runs.json`. `analyze.py` and `logs.py` read it.
