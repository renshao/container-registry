# Published reports

Curated benchmark results, kept permanently. Everything here has been reviewed
and released deliberately — this is not the harness's output directory.
`bench/reports/` is where runs actually land, and it is gitignored, because
most runs are scratch.

A report is promoted here when its numbers are worth citing. Promotion means
committing the rendered report **and the samples it was rendered from**, so a
reader can recompute any figure rather than take it on faith.

| Date | Report | Subject |
|------|--------|---------|
| 2026-09-06 | [Pull concurrency, 1→400 clients](2026-09-06-pull-concurrency/) | summ v0.1.0-rc.1 against distribution 3.1.1 on one EC2 instance |

## Layout

```
2026-09-06-pull-concurrency/
  index.html        the report, as published
  README.md         headline numbers, readable on GitHub without Pages
  data/
    <run>/
      run-meta.json         the flags that produced the run
      summary.md            rendered tables
      engines-selected.json resolved engine definitions
      terraform.json        infrastructure, secrets redacted
      images-effective.txt  the exact pull list, after servability checks
      report-*.json.gz      every individual pull
```

Directories are `YYYY-MM-DD-slug`, so they sort chronologically and never
collide. `index.html` rather than a descriptive filename is what lets GitHub
Pages serve the folder URL directly.

## Re-rendering a report from its data

The archived samples are live, not decorative. `--summary-only` reads
`report-*.json.gz` directly and touches no cloud resources:

```bash
./bench/concurrency.sh --summary-only docs/reports/2026-09-06-pull-concurrency/data/small-corpus
```

That regenerates `summary.md` byte-for-byte as it was rendered on the day of
the run — verified for both runs in the 2026-09-06 report. Use it to add a
percentile, change how a table reads, or check a figure someone has questioned.

`run-meta.json` is what makes this work: the sweep parameters are command-line
flags, so without it a re-render would print the script's *current* defaults in
place of what was actually run.

## Promoting a run

1. Run it, and keep the run directory from `bench/reports/`.
2. `mkdir -p docs/reports/<YYYY-MM-DD>-<slug>/data/<run>`
3. Copy `summary.md`, `run-meta.json`, `engines-selected.json`,
   `terraform.json` and `images-*.txt`; `gzip -9` the `report-*.json` files.
4. Confirm the round trip before committing — if `--summary-only` cannot
   reproduce the summary, the archive is incomplete:
   ```bash
   ./bench/concurrency.sh --summary-only docs/reports/<slug>/data/<run>
   ```
5. Write the report `README.md` and add a row to the table above.

Check `terraform.json` before committing. It is redacted by the harness, but it
is the one file here that ever holds infrastructure detail.
