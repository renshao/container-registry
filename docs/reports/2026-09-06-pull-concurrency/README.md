# Pull performance under concurrency — summ v0.1.0-rc.1

**6 September 2026** · [Read the report](index.html) ·
[published copy](https://claude.ai/code/artifact/768e3dbb-759a-43df-ab18-ac564bba003d)

> GitHub renders committed HTML as source. Read `index.html` through GitHub
> Pages, or open it locally; the tables below carry the headline either way.

How summ v0.1.0-rc.1 behaves as simultaneous pullers pile up, from 1 client to
400, on a single EC2 instance, with distribution 3.1.1 as the reference.

## Result

summ never became the bottleneck. It reached **37.4 Gbps of measured egress —
line rate for the instance — at 25 concurrent pullers and held it through 50,
100, 200 and 400**, on 0.72 of one core out of eight, with zero failed pulls in
45,400. distribution never reached line rate on the same machine and moved
away from it as concurrency rose.

The ceiling this test found belongs to the network card. summ's own limit is
above what an m6idn.2xlarge can express.

| Concurrency | summ MB/s | distribution MB/s | summ p50 | distribution p50 | summ CPU | distribution CPU |
|---|---|---|---|---|---|---|
| 25 | **4648** | 3985 | **65 ms** | 78 ms | 0.47 | 0.71 |
| 50 | **4660** | 3896 | **128 ms** | 161 ms | 0.52 | 0.71 |
| 100 | **4701** | 3827 | **215 ms** | 331 ms | 0.61 | 0.73 |
| 200 | **4715** | 3642 | **495 ms** | 728 ms | 0.67 | 0.80 |
| 400 | **4714** | 3471 | **1051 ms** | 1562 ms | 0.72 | 0.84 |

<sub>Small-image corpus. CPU is cores, of eight. Full tables, the mixed-corpus
sweep and the caveats are in the report.</sub>

## Where summ looks worse

summ's tail is proportionally wider than distribution's above 50 concurrent
clients — p99÷p50 of 3.2–4.8× against 1.8–2.3×. At 100 concurrent,
distribution's p99 is better in absolute terms: 599 ms against 1025 ms. summ is
carrying 23% more bytes per second at the same nominal concurrency, which is
context rather than an excuse; the pattern holds at 100, 200 and 400.

## Setup

| | |
|---|---|
| Registry host | `m6idn.2xlarge` — 8 vCPU, 32 GiB, 474 GB NVMe, 40 Gbps |
| Load generator | `c6in.4xlarge` — 25 Gbps, double the registry, so the client never constrains |
| Region | `ap-southeast-2` |
| summ | v0.1.0-rc.1, release tarball, checksum-verified |
| distribution | 3.1.1, release binary |
| Both | native under systemd, no containers, same local NVMe, one running at a time |

Each measurement point restarts the engine and drops the page cache first, so
none inherits the previous one's warm state. The pull list is verified servable
by every engine before the sweep, and pulled round-robin — grouped ordering
would make 400 "concurrent" pulls into 400 pulls of the same image.

## What it does not establish

- **summ's actual ceiling.** It saturated the NIC with seven cores idle.
- **Disk behaviour.** Corpora are 7.3 GB and 78 MB against 32 GiB of RAM. Caches
  are dropped before each point, but a long point ends up serving warm. This
  measures the request path.
- **Statistical confidence.** One pass per point, no repeats. Treat differences
  under ~5% as noise.
- **Push throughput.** Measured incidentally during setup and not comparable
  across engines — the first engine populated also absorbs the upstream fetch.

## Data

`data/mixed-corpus/` and `data/small-corpus/` hold every individual pull,
gzipped. To recompute anything:

```bash
./bench/concurrency.sh --summary-only docs/reports/2026-09-06-pull-concurrency/data/small-corpus
```

Both directories reproduce their `summary.md` byte-for-byte as rendered on the
day of the run.

Runs `20260906-092504` (mixed) and `20260906-093259` (small). All AWS resources
were destroyed at completion.
