# Registry pull performance under concurrency — 20260906-093259

One VM, one engine running at a time, same local NVMe, same image list in
the same order. Concurrency is swept; everything else is held still.

| Setting | Value |
|---------|-------|
| Provider | aws |
| Registry VM | m6idn.2xlarge |
| Corpus | `images-concurrency-small.txt` — 6 images served by every engine |
| Concurrency sweep | 25,50,100,200,400 |
| Pulls per point | 25× concurrency, clamped to [1500, 10000] |
| Blob fanout per pull | 3 |
| Image order | round-robin over the corpus |
| Repeats | 1 |
| Engines | summ v0.1.0-rc.1 (release binary), distribution (filesystem) |

## summ v0.1.0-rc.1 (release binary)

| Concurrency | Pulls ok/fail | Aggregate MB/s | Pulls/s | p50 ms | p90 ms | p95 ms | p99 ms | max ms | Registry CPU % | Engine CPU % |
|---|---|---|---|---|---|---|---|---|---|---|
| 25 | 1500/0 | 4647.68 | 360.98 | 65.05 | 100.98 | 111.49 | 132.27 | 164.17 | 54.39 | 47.06 |
| 50 | 1500/0 | 4659.7 | 361.91 | 127.76 | 257.95 | 287.37 | 348.76 | 406.72 | 59.12 | 51.86 |
| 100 | 2500/0 | 4701.12 | 365.27 | 215 | 562.86 | 699.33 | 1008.03 | 2274.69 | 67.3 | 60.59 |
| 200 | 5000/0 | 4714.88 | 366.31 | 494.86 | 1039.1 | 1195.39 | 1614.25 | 2758.93 | 73.54 | 67 |
| 400 | 10000/0 | 4713.8 | 366.15 | 1051.03 | 1976.29 | 2364.35 | 3316.67 | 5377.94 | 79.39 | 72.45 |

> Registry CPU % is the whole 8-vCPU machine (100% = one core saturated,
> 800% = all eight). Engine CPU % is the registry process alone, so the
> gap between the two is kernel time spent on its behalf — network stack
> and page cache.

## distribution (filesystem)

| Concurrency | Pulls ok/fail | Aggregate MB/s | Pulls/s | p50 ms | p90 ms | p95 ms | p99 ms | max ms | Registry CPU % | Engine CPU % |
|---|---|---|---|---|---|---|---|---|---|---|
| 25 | 1500/0 | 3984.61 | 309.48 | 78.13 | 129.43 | 145.62 | 175.87 | 268.61 | 75.46 | 71.24 |
| 50 | 1500/0 | 3896.1 | 302.6 | 160.99 | 252.34 | 279.18 | 367.82 | 505.09 | 74.64 | 70.78 |
| 100 | 2500/0 | 3826.97 | 297.35 | 331.21 | 475.73 | 519.16 | 598.89 | 700.08 | 75.76 | 72.82 |
| 200 | 5000/0 | 3641.7 | 282.93 | 728.01 | 1169.12 | 1238.77 | 1601.91 | 2022.89 | 83.35 | 79.98 |
| 400 | 10000/0 | 3471.45 | 269.65 | 1561.69 | 2500.9 | 2630.83 | 3370.35 | 4378.78 | 86.88 | 83.86 |

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
| 25 | **summ-release** | 4647.68 | — | 65.05 | — | 132.27 | — |
| 25 | distribution | 3984.61 | 1.17× | 78.13 | 1.2× | 175.87 | 1.33× |
| 50 | **summ-release** | 4659.7 | — | 127.76 | — | 348.76 | — |
| 50 | distribution | 3896.1 | 1.2× | 160.99 | 1.26× | 367.82 | 1.05× |
| 100 | **summ-release** | 4701.12 | — | 215 | — | 1008.03 | — |
| 100 | distribution | 3826.97 | 1.23× | 331.21 | 1.54× | 598.89 | 0.59× |
| 200 | **summ-release** | 4714.88 | — | 494.86 | — | 1614.25 | — |
| 200 | distribution | 3641.7 | 1.29× | 728.01 | 1.47× | 1601.91 | 0.99× |
| 400 | **summ-release** | 4713.8 | — | 1051.03 | — | 3316.67 | — |
| 400 | distribution | 3471.45 | 1.36× | 1561.69 | 1.49× | 3370.35 | 1.02× |

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
