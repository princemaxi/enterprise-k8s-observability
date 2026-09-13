#!/usr/bin/env bash
# Called by null_resource.wait_for_elasticsearch. Polls the Elasticsearch
# CR's own status.health field until it reports "green" (or times out).
# kubectl accepting the CR just means the API server stored it — the ECK
# operator still needs to actually schedule StatefulSet pods and have
# them join the cluster, which takes real time and can fail in ways a
# plain `kubectl apply` success doesn't surface.
set -euo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME env var required}"
: "${AWS_REGION:?AWS_REGION env var required}"
: "${NAMESPACE:?NAMESPACE env var required}"

echo "==> Configuring kubectl for ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

echo "==> Waiting for Elasticsearch to report green (up to 20 minutes)"
for i in $(seq 1 120); do
  health=$(kubectl -n "${NAMESPACE}" get elasticsearch logging -o jsonpath='{.status.health}' 2>/dev/null || echo "")
  if [ "$health" = "green" ]; then
    echo "==> Elasticsearch is green"
    exit 0
  fi
  echo "    health=${health:-<not yet reported>} — waiting (attempt ${i}/120)"
  sleep 10
done

echo "ERROR: Elasticsearch did not report green within 20 minutes." >&2
echo "Check: kubectl -n ${NAMESPACE} get elasticsearch,pods" >&2
echo "       kubectl -n ${NAMESPACE} describe pod -l elasticsearch.k8s.elastic.co/cluster-name=logging" >&2
exit 1
