ENV_DIR ?= infra/environments/dev
TF      := terraform -chdir=$(ENV_DIR)

.PHONY: help fmt validate lint scan test init plan apply destroy seed e2e dlq-drill replay-drill

help: ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-13s %s\n", $$1, $$2}'

fmt: ## Format all Terraform
	terraform fmt -recursive

validate: ## Validate the dev environment (no backend)
	$(TF) init -backend=false -input=false >/dev/null && $(TF) validate

lint: ## tflint + ruff
	tflint --init && tflint --recursive --config "$(CURDIR)/.tflint.hcl"
	ruff check src tests

scan: ## checkov IaC scan + bandit
	checkov --config-file .checkov.yaml -d .
	bandit -r src -q

test: ## Unit tests (no AWS needed)
	python3 -m unittest discover -s tests -v

init: ## Init with backend.hcl
	$(TF) init -backend-config=backend.hcl

plan: ## Plan
	$(TF) plan -out=tfplan

apply: ## Apply the saved plan
	$(TF) apply tfplan

destroy: ## Destroy (set deletion_protection = false and apply first)
	$(TF) destroy

seed: ## Create demo employee/manager/HR users: make seed PREFIX=you DOMAIN=example.com
	./scripts/seed-users.sh $(PREFIX) $(DOMAIN)

e2e: ## Full business flow: submit -> approve -> ledger -> payroll -> CSV
	./scripts/e2e-test.sh

dlq-drill: ## Poison message -> DLQ -> alarm (~6 min)
	./scripts/dlq-drill.sh

replay-drill: ## Replay archived events; totals must not change
	./scripts/replay-drill.sh
