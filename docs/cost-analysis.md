# Cost Analysis and Optimization

## Rough monthly infrastructure estimate (eu-west-2, on-demand list prices)

| Item                              | Qty | Unit cost/mo (approx) | Monthly total |
|-------------------------------------|-----|--------------------------|----------------|
| `r6i.xlarge` (es-data, on-demand)   | 3   | ~$225                    | ~$675          |
| `m6i.large` (es-master, on-demand)  | 3   | ~$70                     | ~$210          |
| `m6i.large` (general, spot ~60% off)| 3   | ~$28                     | ~$84           |
| EBS gp3, 1000Gi × 3 (data nodes)    | 3TB | ~$0.08/GB                | ~$240          |
| EBS gp3, 30Gi × 3 (master nodes)    | 90GB| ~$0.08/GB                | ~$7            |
| NAT Gateway (3, one per AZ)         | 3   | ~$32 + data processing    | ~$100+         |
| S3 snapshot storage (Standard→Glacier)| ~1-2TB steady state | mixed | ~$25–40 |
| EKS control plane                    | 1   | $73                      | $73            |
| **Estimated total**                 |     |                          | **~$1,400–1,450/mo** |

Treat this as an order-of-magnitude estimate, not a quote — actual EC2/EBS
pricing varies by exact instance generation and changes over time; verify
current rates before using this number in a real cost proposal.

## Where the cost actually is

The `es-data` node group dominates the bill (r6i.xlarge × 3, plus their
attached storage) — this is expected and correct for a memory/IO-heavy
stateful workload, but it's also the first place to look when optimizing.

## Optimization levers, roughly in order of impact

1. **ILM hot/warm/cold tiering** (already configured,
   the ILM policy embedded in `terraform/modules/logging-platform/scripts/es-bootstrap-remote.sh`): shrinking + force-merging + best-compression at
   day 3 is the single biggest lever, since it reduces the bytes that sit
   on the more expensive `es-data` node storage for the bulk of the
   30-day window.
2. **Snapshot lifecycle to Glacier** (`terraform/modules/logging-platform/s3.tf`,
   `aws_s3_bucket_lifecycle_configuration`): keeps the long-term DR copy
   an order of magnitude cheaper than hot ES storage, since it's rarely
   accessed.
3. **Spot for the general node pool**: Kibana, Filebeat, and the Order API
   all tolerate interruption (Kibana is stateless behind 2 replicas,
   Filebeat re-attaches on restart, the Order API has readiness/liveness
   probes and 3 replicas) — ~60-70% savings on that pool with negligible
   risk. **Never** put `es-master` or `es-data` on spot; a mid-eviction
   master-node loss risking quorum, or a data-node eviction racing a
   shard relocation, is not a trade worth making for the savings.
3. **Smaller shard sizes / correct primary shard count**: the ILM
   `rollover.max_primary_shard_size: 30gb` keeps shards from growing
   unbounded, which keeps merge/relocation costs (CPU, not just storage)
   in check.
4. **Right-sized replicas**: 1 replica is the minimum for HA and is
   already the floor here — going to 0 replicas would roughly halve
   storage cost but means losing a single data node loses data outright.
   Not recommended outside a genuinely disposable dev environment.
5. **Reserved Instances / Savings Plans** for the `es-master`/`es-data`
   pools once the sizing has been validated against real production
   traffic for a month or two — committing to reserved capacity before
   the sizing is confirmed risks paying for the wrong shape of node.

## What NOT to cut

- Don't drop to a single ES master node to save cost — losing quorum on a
  logging platform during an incident is exactly when you need it most.
- Don't skip the S3 snapshot lifecycle "to save on Glacier request costs" —
  the entire point of a DR strategy is that it works on the day you didn't
  plan for.
