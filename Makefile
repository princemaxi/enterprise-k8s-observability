.PHONY: help tf-init tf-plan tf-apply tf-destroy kubeconfig \
        status vault-root-token perf-test smoke-test clean

# ENV selects the Terraform environment (terraform/environments/$(ENV)).
# Defaults to dev deliberately — targeting prod always requires an
# explicit `make ENV=prod <target>`, never the bare default.
ENV ?= dev
TF_DIR := terraform/environments/$(ENV)

KIBANA_URL    ?= https://kibana.$(ENV).logging.qyonlimited.com
ORDER_API_URL ?= https://order-api.$(ENV).logging.qyonlimited.com

help: ## Show this help
	@echo "Current ENV=$(ENV) (override with: make ENV=dev|sit|prod <target>)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## --- The whole platform ---------------------------------------------------
## `terraform apply` alone brings up: VPC, EKS, every addon (ALB
## controller, ingress-nginx, cert-manager, external-dns, ECK operator),
## Vault (deployed, initialized, KMS-auto-unsealed), Elasticsearch,
## Kibana, Filebeat, the Order API (image built + pushed + deployed),
## Ingress/TLS, NetworkPolicies, and the ES bootstrap (ILM, snapshot repo,
## alerting). Nothing else in this Makefile is part of getting the
## platform live — everything below is verification/troubleshooting only.

tf-init: ## terraform init for $(ENV) (expects terraform/environments/$(ENV)/backend.hcl — copy from backend.hcl.example)
	cd $(TF_DIR) && terraform init -backend-config=backend.hcl

tf-plan: ## terraform plan for $(ENV)
	cd $(TF_DIR) && terraform plan -out=tfplan

tf-apply: ## terraform apply the last plan for $(ENV) — this is the whole platform
	cd $(TF_DIR) && terraform apply tfplan

tf-destroy: ## terraform destroy for $(ENV) (does NOT delete orphaned EBS volumes — see docs/terminal-walkthrough.md)
	cd $(TF_DIR) && terraform destroy

kubeconfig: ## Configure kubectl for manual troubleshooting — Terraform itself never depends on you having run this
	cd $(TF_DIR) && $$(terraform output -raw configure_kubectl)
	kubectl get nodes -L role

## --- Verification -----------------------------------------------------------

status: ## One-shot health check across every major component in $(ENV)
	@echo "--- Nodes ---"
	@kubectl get nodes -L role
	@echo "--- Elasticsearch / Kibana ---"
	@kubectl -n elastic-system get elasticsearch,kibana
	@echo "--- Vault ---"
	@kubectl -n vault get pods
	@echo "--- Order API ---"
	@kubectl -n applications get pods,ingress
	@echo "--- Ingress / Certificates ---"
	@kubectl -n elastic-system get certificate
	@kubectl -n applications get certificate

vault-root-token: ## Print the command to retrieve $(ENV)'s Vault root token (never printed automatically — see vault.tf)
	@echo "kubectl -n vault get secret vault-init -o jsonpath='{.data.root_token}' | base64 -d"

perf-test: ## Run the k6 load test against the Order API in $(ENV)
	k6 run --env BASE_URL=$(ORDER_API_URL) scripts/perf-test.js

smoke-test: ## Cluster health + doc count sanity check for $(ENV) (requires kubectl exec access — see docs/terminal-walkthrough.md)
	@ES_POD=$$(kubectl -n elastic-system get pods -l elasticsearch.k8s.elastic.co/statefulset-name=logging-es-master -o jsonpath='{.items[0].metadata.name}'); \
	ES_PASS=$$(kubectl -n elastic-system get secret logging-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d); \
	kubectl -n elastic-system exec "$$ES_POD" -- curl -sS --cacert /usr/share/elasticsearch/config/http-certs/ca.crt \
		-u "elastic:$$ES_PASS" "https://logging-es-http.elastic-system.svc:9200/_cluster/health?pretty"

clean: ## Remove local scratch files (does not touch the cluster or AWS resources)
	rm -f terraform/environments/*/tfplan
