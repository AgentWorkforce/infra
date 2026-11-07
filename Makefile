PROFILE ?= core
PYTHON ?= python3

.PHONY: kind-up kind-down kind-render kind-build-addons kind-proof kind-proof-core kind-proof-addons
kind-up:
	$(PYTHON) ci/agent-relay/kind/stack.py up --profile $(PROFILE)
kind-down:
	$(PYTHON) ci/agent-relay/kind/stack.py down --profile $(PROFILE)
kind-render:
	$(PYTHON) ci/agent-relay/kind/stack.py render --profile $(PROFILE)
kind-build-addons:
	$(PYTHON) ci/agent-relay/kind/stack.py build-addons --profile addons
kind-proof:
	$(PYTHON) ci/agent-relay/kind/proof.py --profile $(PROFILE)
kind-proof-core:
	$(MAKE) kind-proof PROFILE=core
kind-proof-addons:
	$(MAKE) kind-proof PROFILE=addons
