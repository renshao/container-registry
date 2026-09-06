# Registry pull performance under concurrency — 20260906-092504

One VM, one engine running at a time, same local NVMe, same image list in
the same order. Concurrency is swept; everything else is held still.

| Setting | Value |
|---------|-------|
| Provider | aws |
| Registry VM | m6idn.2xlarge |
| Corpus | `images-concurrency.txt` — 25 images served by every engine |
| Concurrency sweep | 1,8,25,50,100,200 |
| Pulls per point | 5× concurrency, clamped to [150, 1000] |
| Blob fanout per pull | 3 |
| Image order | round-robin over the corpus |
| Repeats | 1 |
| Engines | summ v0.1.0-rc.1 (release binary), distribution (filesystem) |

## summ v0.1.0-rc.1 (release binary)

| Concurrency | Pulls ok/fail | Aggregate MB/s | Pulls/s | p50 ms | p90 ms | p95 ms | p99 ms | max ms | Registry CPU % | Engine CPU % |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 150/0 | 1176.58 | 4.24 | 140.63 | 437.47 | 857.27 | 1252 | 3333.04 | 8.18 | 6.68 |
| 8 | 150/0 | 2942.61 | 10.62 | 208.69 | 2028.8 | 4022.65 | 5532.03 | 5773.86 | 35.62 | 31.48 |
| 25 | 150/0 | 3393.33 | 12.24 | 1050.92 | 5041.32 | 6205.01 | 7294.66 | 11613.73 | 45.59 | 40.32 |
| 50 | 250/0 | 4470.13 | 16.13 | 1577.54 | 6356.53 | 8293.7 | 12871.2 | 15392.64 | 66.31 | 59.99 |
| 100 | 500/0 | 4712.88 | 17 | 3119.88 | 12130.8 | 16006.77 | 27369.2 | 29371.61 | 73.11 | 65.69 |
| 200 | 1000/0 | 4712.62 | 17 | 6871.44 | 23139.59 | 31790.22 | 53366.1 | 57884.73 | 72.67 | 64.09 |

> Registry CPU % is the whole 8-vCPU machine (100% = one core saturated,
> 800% = all eight). Engine CPU % is the registry process alone, so the
> gap between the two is kernel time spent on its behalf — network stack
> and page cache.

## distribution (filesystem)

| Concurrency | Pulls ok/fail | Aggregate MB/s | Pulls/s | p50 ms | p90 ms | p95 ms | p99 ms | max ms | Registry CPU % | Engine CPU % |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 150/0 | 1354.72 | 4.89 | 99.5 | 460.2 | 852.63 | 1218.51 | 3336.25 | 10.38 | 9.42 |
| 8 | 150/0 | 2955.19 | 10.66 | 203.62 | 2038.27 | 3937.81 | 5435.58 | 6734 | 35.42 | 31.21 |
| 25 | 150/0 | 3393.25 | 12.24 | 817.81 | 4925.15 | 6403.18 | 7668.15 | 12015.41 | 45.18 | 40.35 |
| 50 | 250/0 | 4292.93 | 15.49 | 1607 | 6595.47 | 7929.94 | 14225.63 | 15550.49 | 59.51 | 53.56 |
| 100 | 500/0 | 4705.36 | 16.97 | 3515.26 | 11915.73 | 17538.17 | 25447.53 | 29214.04 | 66.65 | 58.88 |
| 200 | 1000/0 | 4713 | 17 | 6619.32 | 22810.17 | 32638.14 | 52924.48 | 56623.7 | 68.56 | 60.34 |

> Registry CPU % is the whole 8-vCPU machine (100% = one core saturated,
> 800% = all eight). Engine CPU % is the registry process alone, so the
> gap between the two is kernel time spent on its behalf — network stack
> and page cache.

## Head to head

Every point, with `summ-release` as the reference. Each ratio is stated so
that **above 1.00× means `summ-release` is ahead** on that metric: throughput is
summ-release ÷ that row, latency is that row ÷ summ-release. So `2.00×` in a latency
column means that engine took twice as long as summ-release at that concurrency.

| Concurrency | Engine | Aggregate MB/s | vs summ-release | p50 ms | vs summ-release | p99 ms | vs summ-release |
|---|---|---|---|---|---|---|---|
| 1 | **summ-release** | 1176.58 | — | 140.63 | — | 1252 | — |
| 1 | distribution | 1354.72 | 0.87× | 99.5 | 0.71× | 1218.51 | 0.97× |
| 8 | **summ-release** | 2942.61 | — | 208.69 | — | 5532.03 | — |
| 8 | distribution | 2955.19 | 1× | 203.62 | 0.98× | 5435.58 | 0.98× |
| 25 | **summ-release** | 3393.33 | — | 1050.92 | — | 7294.66 | — |
| 25 | distribution | 3393.25 | 1× | 817.81 | 0.78× | 7668.15 | 1.05× |
| 50 | **summ-release** | 4470.13 | — | 1577.54 | — | 12871.2 | — |
| 50 | distribution | 4292.93 | 1.04× | 1607 | 1.02× | 14225.63 | 1.11× |
| 100 | **summ-release** | 4712.88 | — | 3119.88 | — | 27369.2 | — |
| 100 | distribution | 4705.36 | 1× | 3515.26 | 1.13× | 25447.53 | 0.93× |
| 200 | **summ-release** | 4712.62 | — | 6871.44 | — | 53366.1 | — |
| 200 | distribution | 4713 | 1× | 6619.32 | 0.96× | 52924.48 | 0.99× |

## How to read this

- **Aggregate MB/s** is the honest headline: total bytes delivered ÷ wall
  clock. Per-pull throughput rises and falls with concurrency for
  arithmetic reasons; this does not.
- **p99 against p50** is where a registry's concurrency behaviour shows.
  Both rising together is queueing, which is expected once the link is
  full. p99 pulling away from p50 is contention inside the server.
- **Failures are not a footnote.** A point with a non-zero fail count is
  not a faster point; read the failure column before the latency columns.
- Every point starts with the engine restarted and the page cache dropped,
  so the first pulls of each point are genuinely cold. The corpus is
  smaller than RAM, so later pulls in a long point are served warm — this
  measures the request path, not the disk.
