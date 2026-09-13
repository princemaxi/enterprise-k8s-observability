# Capacity Planning

## Assumptions

| Variable                    | Value            | Source                                                      |
|-------------------------------|-------------------|---------------------------------------------------------------|
| Peak ingest rate               | 1,000 logs/sec    | Target load for the Order API under `scripts/perf-test.js`  |
| Average log size (raw JSON)   | 1 KB              | Measured from `app/app.py`'s `JsonFormatter` output          |
| Retention (hot searchable)    | 30 days           | ILM `delete` phase, the ILM policy embedded in `terraform/modules/logging-platform/scripts/es-bootstrap-remote.sh`                     |
| Replica count                 | 1                 | `app-logs-template` index settings                             |
| Index overhead (inverted index, doc values, etc.) | ~1.25x raw | Typical Elasticsearch overhead for text + keyword fields |

## Daily raw volume

```
1,000 logs/sec × 86,400 sec/day = 86,400,000 logs/day
86,400,000 logs × 1 KB          = 86,400,000 KB/day ≈ 82.4 GB/day (raw)
```

## Accounting for replicas and index overhead

Raw log volume isn't what actually lands on disk. Two multipliers apply:

- **1 replica** doubles stored bytes (primary + replica shard).
- **Indexing overhead** (~1.25x) from Elasticsearch's inverted index and
  doc-values structures on top of the raw JSON.

```
82.4 GB/day × 1.25 (index overhead) × 2 (1 replica) ≈ 206 GB/day
```

## 30-day retention, before compression

```
206 GB/day × 30 days ≈ 6.2 TB
```

## Accounting for ILM warm-phase compression

The ILM policy (the ILM policy embedded in `terraform/modules/logging-platform/scripts/es-bootstrap-remote.sh`) shrinks and force-merges indices into
the warm phase at day 3 with `best_compression`. In practice this typically
recovers 30–40% of stored size on log-shaped data (repetitive keyword
fields, similar message structures):

```
6.2 TB × 0.65 (assume 35% reduction) ≈ 4.0 TB effective steady-state
```

## What was actually provisioned

`terraform/modules/logging-platform/templates/elasticsearch.yaml.tpl` provisions 3 data nodes ×
1000Gi = **3 TB** of `es-gp3` storage — deliberately below the ~4 TB
steady-state estimate above. This is not a rounding error; it's a starting
point with two supporting decisions:

1. `allowVolumeExpansion: true` on the `es-gp3` StorageClass, so volumes can
   grow without a data migration.
2. The `es-data` node group's `max_size` allows scaling from 3 to 9 nodes.
   If Kibana's Cluster Health dashboard shows disk watermark warnings
   (Elasticsearch defaults: 85% high watermark) or ILM struggling to keep
   the hot phase under `max_primary_shard_size: 30gb`, the response is to
   add data nodes, not firefight retention.

Treat the 3 TB figure as **"provisioned for the assumed load, with a
monitored path to scale"** — not a guarantee that fits every traffic
pattern. Document actual observed daily volume from
`GET _cat/indices/app-logs-*?v&h=index,store.size` after a week of real
traffic and revisit this document with the real number.

## Sizing the compute (not just storage)

- **Data nodes** (`r6i.xlarge`, 4 vCPU / 32 GiB): heap capped at 4 GiB
  (`-Xms4g -Xmx4g`), i.e. 50% of container memory limit — the other 50% is
  left for the OS page cache, which Elasticsearch relies on heavily for
  read performance. Never raise heap past ~50% of available memory or past
  the ~31 GiB compressed-oops ceiling.
- **Master nodes** (`m6i.large`, 2 vCPU / 8 GiB): masters don't hold data,
  so heap is capped at 2 GiB. Oversizing master nodes is pure waste; the
  job is cluster-state management and quorum, not indexing.

## Retention and cost interaction

See `docs/cost-analysis.md` for how the 30-day ILM policy and S3 snapshot
lifecycle (Glacier at 30 days, expire at 365) were chosen jointly to keep
"searchable now" and "recoverable later" as two separate, appropriately
priced tiers instead of paying hot-tier storage prices for year-old logs.
