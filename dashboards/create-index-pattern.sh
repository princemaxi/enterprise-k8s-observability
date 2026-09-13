#!/usr/bin/env bash
# Creates the app-logs-* index pattern (data view) in Kibana via its
# Saved Objects API, so dashboard-building starts from a known-good state
# instead of relying on someone clicking through the UI correctly.
set -euo pipefail

KIBANA_URL="${KIBANA_URL:?export KIBANA_URL, e.g. https://kibana.logging.qyonlimited.com}"
ES_PASS="${ES_PASS:?Set ES_PASS to the elastic user password}"

curl -sS -X POST "${KIBANA_URL}/api/data_views/data_view" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -u "elastic:${ES_PASS}" \
  -d '{
    "data_view": {
      "title": "app-logs-*",
      "name": "Application Logs",
      "timeFieldName": "@timestamp"
    }
  }'

echo
echo "==> Index pattern created. Open Kibana -> Analytics -> Discover to confirm data is flowing."
