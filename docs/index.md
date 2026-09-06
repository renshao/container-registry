# summ-bench

A container registry implementation benchmark. It provisions a cloud VM,
installs several registry implementations on it, mirrors an identical image
corpus into each, then pulls from one implementation at a time and compares
them.

The comparison axis is the **registry software**. Every engine runs on the same
VM, against the same local NVMe, one at a time, over a byte-identical image
list — so a difference in the numbers is a difference in the registry.

## Published reports

- **[Pull performance under concurrency](reports/2026-09-06-pull-concurrency/)**
  — 6 September 2026. summ v0.1.0-rc.1 from 1 to 400 concurrent pullers on a
  single EC2 instance, against distribution 3.1.1. summ holds the network's
  line rate flat from 25 concurrent clients to 400, on under three-quarters of
  one CPU core, with zero failures in 45,400 pulls.

Every report ships with the per-pull samples behind it, so any figure can be
recomputed rather than taken on faith. See
[the report index](https://github.com/summcr/summ-bench/tree/main/docs/reports)
for how that works.

## Source

[github.com/summcr/summ-bench](https://github.com/summcr/summ-bench)
