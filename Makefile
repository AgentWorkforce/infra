.DEFAULT_GOAL := help
PROFILE ?= core
PYTHON ?= python3
# Quote arbitrary PROFILE text as one shell argument before Python validates it.
profile_arg = '$(subst ','"'"',$(PROFILE))'
cutover_arg = '$(subst ','"'"',$(CUTOVER_RECEIPT))'
control_archive_arg = '$(subst ','"'"',$(CONTROL_IMAGE_ARCHIVE))'

.PHONY: help kind-up kind-up-local-control kind-down kind-render kind-build-addons kind-build-control kind-proof kind-proof-core kind-proof-addons kind-reconcile-names
help:
	@echo "Local kind: make kind-render, kind-up, kind-proof, or kind-down PROFILE=core|addons"
	@echo "Build: kind-build-control, kind-up-local-control, kind-build-addons; proof aliases: kind-proof-core, kind-proof-addons"
	@echo "Provisioning requires an explicit target; kind readiness is not a full application proof."
	@echo "Completed naming cutover: kind-reconcile-names CUTOVER_RECEIPT=... CONTROL_IMAGE_ARCHIVE=..."

kind-up:
	$(PYTHON) ci/agent-relay/kind/stack.py up --profile $(profile_arg)
kind-up-local-control: kind-build-control
	$(MAKE) kind-up PROFILE=$(profile_arg)

kind-down:
	$(PYTHON) ci/agent-relay/kind/stack.py down --profile $(profile_arg)
kind-render:
	$(PYTHON) ci/agent-relay/kind/stack.py render --profile $(profile_arg)
kind-build-control:
	$(PYTHON) ci/agent-relay/kind/stack.py build-control --profile $(profile_arg)
kind-reconcile-names:
	$(PYTHON) ci/agent-relay/kind/stack.py reconcile-names --profile $(profile_arg) --cutover-receipt $(cutover_arg) --control-image-archive $(control_archive_arg)

kind-build-addons:
	$(PYTHON) ci/agent-relay/kind/stack.py build-addons --profile addons
kind-proof:
	$(PYTHON) ci/agent-relay/kind/proof.py --profile $(profile_arg)
kind-proof-core:
	$(MAKE) kind-proof PROFILE=core
kind-proof-addons:
	$(MAKE) kind-proof PROFILE=addons
