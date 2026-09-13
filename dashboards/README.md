# Kibana Dashboards

Dashboards are built against the `app-logs-*` index pattern
(`@timestamp` as the time field) created by `create-index-pattern.sh`.
Three dashboards, matching the brief:

## 1. Cluster Health

- **Total Logs** — count over time (Line chart, `@timestamp` histogram)
- **Error Rate** — `(count where level:ERROR OR level:CRITICAL) / count`,
  as a percentage metric with a threshold color band
- **Requests/sec** — count of `http.status_code: *` bucketed per second/minute
- **Top Pods** — terms aggregation on `kubernetes.pod.name`, Top 10 table
- **CPU** — if `kube-prometheus-stack` metrics are federated into the same
  Kibana via the Elasticsearch exporter, otherwise link out to Grafana
  (this stack focuses on logs, not metrics — see "Relationship to
  kube-prometheus-stack" below)

## 2. Application Dashboard

- **HTTP Status Codes** — terms aggregation on `http.status_code`, pie or
  bar chart, makes 4xx/5xx spikes immediately visible
- **Response Time** — average/p95 of `duration_ms`, line chart over time
- **Error Trend** — `level: ERROR OR CRITICAL` count over time, same time
  axis as Total Logs for easy visual correlation
- **Login Failures** — saved search filtered to
  `message: "login failed"`, plus a metric counting them per hour
- **Payment Failures** — saved search filtered to
  `message: "payment gateway timeout" OR message: "invalid payment amount"`

## 3. Kubernetes Dashboard

- **Namespace** — terms aggregation on `kubernetes.namespace`
- **Pod Restarts** — requires `kubernetes.container.restarts` field; add a
  Filebeat `add_kubernetes_metadata` processor field if not already present
- **Container Errors** — `level: ERROR` count grouped by
  `kubernetes.container.name`
- **Failed Deployments** — this is a Kubernetes-events concern, not an
  application-log concern; ship `kubectl` events via a second Filebeat
  input (`kubernetes` module) if this panel is required, rather than
  trying to infer it from application logs.

## Bootstrapping via the Kibana Saved Objects API

Building visualizations by hand in the UI is fine for a one-off, but
scripting the index pattern creation makes the environment reproducible:

```bash
./create-index-pattern.sh
```

Then build the visualizations/dashboards in the Kibana UI (Visualize →
Lens is the fastest path for the metrics above) and export them:

```
Stack Management → Saved Objects → select all dashboard objects → Export
```

Commit the resulting `.ndjson` file here (e.g. `dashboards-export.ndjson`)
so the dashboards can be re-imported into a fresh cluster with:

```bash
curl -X POST "$KIBANA_URL/api/saved_objects/_import" \
  -H "kbn-xsrf: true" -u elastic:$ES_PASS \
  --form file=@dashboards-export.ndjson
```

## Relationship to kube-prometheus-stack

This project is a **logging** platform, not a metrics platform — CPU,
memory, pod restart counts, and infrastructure alerting are already
covered by `kube-prometheus-stack` on the tooling cluster. Rather than
duplicating that with Elasticsearch (which is a poor fit for
high-cardinality time-series metrics), the Cluster Health dashboard's CPU
panel is intentionally a link-out. Keep metrics in Prometheus/Grafana and
logs in Kibana; correlate them by `trace_id` / pod name / timestamp when
debugging, rather than merging the two systems.
