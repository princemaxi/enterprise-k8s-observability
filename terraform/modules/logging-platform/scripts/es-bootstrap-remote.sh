#!/usr/bin/env bash
# Runs INSIDE an Elasticsearch pod (via kubectl exec, driven by
# es-bootstrap.sh) — curling the real internal service hostname directly,
# no port-forward needed since this already runs inside the cluster's own
# pod network. Uses the CA cert path Elastic's own documentation
# specifies for exactly this scenario: config/http-certs/ca.crt.
#
# Expects these env vars already set by the caller: ES_PASS,
# SNAPSHOT_BUCKET, AWS_REGION, SLM_EXPIRE_AFTER, ALERT_EMAIL, NAMESPACE.
set -euo pipefail

ES_URL="https://logging-es-http.${NAMESPACE}.svc:9200"
CA_CERT="/usr/share/elasticsearch/config/http-certs/ca.crt"

curl_es() {
  curl -sS --cacert "$CA_CERT" -u "elastic:${ES_PASS}" "$@"
}

echo "==> Applying ILM policy: app-logs-policy"
curl_es -X PUT "${ES_URL}/_ilm/policy/app-logs-policy" \
  -H 'Content-Type: application/json' \
  -d '{
    "policy": {
      "phases": {
        "hot": {
          "min_age": "0ms",
          "actions": {
            "rollover": { "max_primary_shard_size": "30gb", "max_age": "1d" },
            "set_priority": { "priority": 100 }
          }
        },
        "warm": {
          "min_age": "3d",
          "actions": {
            "shrink": { "number_of_shards": 1 },
            "forcemerge": { "max_num_segments": 1 },
            "set_priority": { "priority": 50 }
          }
        },
        "cold": {
          "min_age": "10d",
          "actions": { "set_priority": { "priority": 0 } }
        },
        "delete": {
          "min_age": "30d",
          "actions": { "delete": {} }
        }
      }
    }
  }'
echo

echo "==> Applying index template: app-logs-template"
curl_es -X PUT "${ES_URL}/_index_template/app-logs-template" \
  -H 'Content-Type: application/json' \
  -d '{
    "index_patterns": ["app-logs-*"],
    "template": {
      "settings": {
        "number_of_shards": 3,
        "number_of_replicas": 1,
        "index.lifecycle.name": "app-logs-policy",
        "index.lifecycle.rollover_alias": "app-logs"
      },
      "mappings": {
        "properties": {
          "@timestamp":       { "type": "date" },
          "service":          { "type": "keyword" },
          "environment":      { "type": "keyword" },
          "version":          { "type": "keyword" },
          "hostname":         { "type": "keyword" },
          "level":            { "type": "keyword" },
          "message":          { "type": "text" },
          "trace_id":         { "type": "keyword" },
          "request_id":       { "type": "keyword" },
          "correlation_id":   { "type": "keyword" },
          "user":             { "type": "keyword" },
          "client_ip":        { "type": "ip" },
          "user_agent":       { "type": "keyword", "ignore_above": 512 },
          "http.status_code": { "type": "integer" },
          "http.method":      { "type": "keyword" },
          "http.path":        { "type": "keyword" },
          "http.response_size": { "type": "integer" },
          "duration_ms":      { "type": "float" },
          "business":         { "type": "object", "dynamic": true },
          "stack_trace":      { "type": "text" }
        }
      }
    }
  }'
echo

echo "==> Ensuring bootstrap index + write alias exist (idempotent — skips if already created)"
if curl_es -s -o /dev/null -w '%{http_code}' "${ES_URL}/app-logs-000001" | grep -q '^2'; then
  echo "    already exists — skipping"
else
  curl_es -X PUT "${ES_URL}/app-logs-000001" \
    -H 'Content-Type: application/json' \
    -d '{"aliases": {"app-logs": {"is_write_index": true}}}'
  echo
fi

echo "==> Registering S3 snapshot repository: ${SNAPSHOT_BUCKET}"
# Credentials come from the ES keystore (spec.secureSettings), populated
# by Terraform from a scoped IAM user — not IRSA/Pod-Identity. See
# terraform/modules/infrastructure/aws-resources.tf for why.
curl_es -X PUT "${ES_URL}/_snapshot/s3_repository" \
  -H 'Content-Type: application/json' \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "'"${SNAPSHOT_BUCKET}"'",
      "region": "'"${AWS_REGION}"'",
      "server_side_encryption": true
    }
  }'
echo

echo "==> Creating SLM policy: nightly snapshot at 01:30, expire after ${SLM_EXPIRE_AFTER}"
curl_es -X PUT "${ES_URL}/_slm/policy/nightly-snapshots" \
  -H 'Content-Type: application/json' \
  -d '{
    "schedule": "0 30 1 * * ?",
    "name": "<nightly-snap-{now/d}>",
    "repository": "s3_repository",
    "config": { "indices": ["app-logs-*"], "include_global_state": false },
    "retention": {
      "expire_after": "'"${SLM_EXPIRE_AFTER}"'",
      "min_count": 5,
      "max_count": 30
    }
  }'
echo

echo "==> Installing Watcher alert: high_error_rate (>50 ERROR/CRITICAL in 5 min)"
curl_es -X PUT "${ES_URL}/_watcher/watch/high_error_rate" \
  -H 'Content-Type: application/json' \
  -d '{
    "trigger": { "schedule": { "interval": "1m" } },
    "input": {
      "search": {
        "request": {
          "indices": ["app-logs-*"],
          "body": {
            "query": {
              "bool": {
                "filter": [
                  { "terms": { "level": ["ERROR", "CRITICAL"] } },
                  { "range": { "@timestamp": { "gte": "now-5m" } } }
                ]
              }
            }
          }
        }
      }
    },
    "condition": { "compare": { "ctx.payload.hits.total": { "gt": 50 } } },
    "actions": {
      "notify_email": {
        "email": {
          "to": ["'"${ALERT_EMAIL}"'"],
          "subject": "[ALERT] High error rate: {{ctx.payload.hits.total}} ERROR/CRITICAL logs in 5 minutes",
          "body": "app-logs-* has recorded {{ctx.payload.hits.total}} ERROR or CRITICAL log entries in the last 5 minutes."
        }
      }
    }
  }'
echo

echo "==> Elasticsearch bootstrap complete."
