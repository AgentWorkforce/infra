.DEFAULT_GOAL := help
PROFILE ?= core
PYTHON ?= python3

.PHONY: help kind-up kind-up-local-control kind-down kind-render kind-build-addons kind-build-control kind-proof kind-proof-core kind-proof-addons
help:
	@echo "Local kind: make kind-render, kind-up, kind-proof, or kind-down PROFILE=core|addons"
	@echo "Provisioning requires an explicit target; kind readiness is not a full application proof."

kind-up:
	$(PYTHON) ci/agent-relay/kind/stack.py up --profile $(PROFILE)
kind-up-local-control: kind-build-control
	$(MAKE) kind-up PROFILE=$(PROFILE)

kind-down:
	$(PYTHON) ci/agent-relay/kind/stack.py down --profile $(PROFILE)
kind-render:
	$(PYTHON) ci/agent-relay/kind/stack.py render --profile $(PROFILE)
kind-build-control:
	$(PYTHON) ci/agent-relay/kind/stack.py build-control --profile $(PROFILE)

kind-build-addons:
	$(PYTHON) ci/agent-relay/kind/stack.py build-addons --profile addons
kind-proof:
	$(PYTHON) ci/agent-relay/kind/proof.py --profile $(PROFILE)
kind-proof-core:
	$(MAKE) kind-proof PROFILE=core
kind-proof-addons:
	$(MAKE) kind-proof PROFILE=addons
