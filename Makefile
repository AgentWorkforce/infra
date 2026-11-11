.DEFAULT_GOAL := help
DEV_CONFIG ?= .kind/dev/config.json
DEV_PLAN ?=
DEV_COMPONENTS ?= all
sh_quote = '$(subst ','"'"',$(1))'
PROFILE ?= core
PYTHON ?= python3
# Quote arbitrary PROFILE text as one shell argument before Python validates it.
profile_arg = '$(subst ','"'"',$(PROFILE))'
cutover_arg = '$(subst ','"'"',$(CUTOVER_RECEIPT))'
control_archive_arg = '$(subst ','"'"',$(CONTROL_IMAGE_ARCHIVE))'

.PHONY: help kind-up kind-up-local-control kind-down kind-render kind-build-addons kind-build-control kind-proof kind-proof-core kind-proof-addons kind-reconcile-names
help:
	@echo "Fresh local stack: make local-up; one-time macOS trust: make local-trust; source loop: make dev"
	@echo "Clean Mac prerequisites: make local-tools (checkout-local pinned Kind, Helm and Python dependencies)"
	@echo "Code loop: make dev after one-time configure; optional make dev-plan (existing Kind; docs/kind-development.md)"
	@echo "Local kind: make kind-render, kind-up, kind-proof, or kind-down PROFILE=core|addons"
	@echo "Build: kind-build-control, kind-up-local-control, kind-build-addons; proof aliases: kind-proof-core, kind-proof-addons"
	@echo "Provisioning requires an explicit target; kind readiness is not a full application proof."
	@echo "Completed naming cutover: kind-reconcile-names CUTOVER_RECEIPT=... CONTROL_IMAGE_ARCHIVE=..."

kind-up:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/stack.py up --profile $(profile_arg)

.PHONY: local-tools
local-tools:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/local_tools.py --prepare

.PHONY: local-up local-down
local-up: local-tools
	PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(CURDIR)/.kind/tools/venv/bin/python3) ci/agent-relay/kind/local_stack.py up
local-down: local-tools
	PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(CURDIR)/.kind/tools/venv/bin/python3) ci/agent-relay/kind/local_stack.py down

.PHONY: local-trust local-login
local-trust:
	sudo $(call sh_quote,$(PYTHON)) ci/agent-relay/kind/local_host_setup.py up
local-login: local-tools
	PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(CURDIR)/.kind/tools/venv/bin/python3) ci/agent-relay/kind/local_stack.py login

.PHONY: local-dev-setup
local-dev-setup: local-tools
	PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(CURDIR)/.kind/tools/venv/bin/python3) ci/agent-relay/kind/local_dev_setup.py --output $(call sh_quote,$(DEV_CONFIG))
kind-up-local-control: kind-build-control
	$(MAKE) kind-up PROFILE=$(profile_arg)

kind-down:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/stack.py down --profile $(profile_arg)
kind-render:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/stack.py render --profile $(profile_arg)
kind-build-control:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/stack.py build-control --profile $(profile_arg)
kind-reconcile-names:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/stack.py reconcile-names --profile $(profile_arg) --cutover-receipt $(cutover_arg) --control-image-archive $(control_archive_arg)

kind-build-addons:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/stack.py build-addons --profile addons
kind-proof:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/proof.py --profile $(profile_arg)
kind-proof-core:
	$(MAKE) kind-proof PROFILE=core
kind-proof-addons:
	$(MAKE) kind-proof PROFILE=addons

.PHONY: dev dev-plan dev-test
dev-plan:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/dev/dev.py plan --config $(call sh_quote,$(DEV_CONFIG)) $(if $(DEV_PLAN),--plan $(call sh_quote,$(DEV_PLAN))) --components $(call sh_quote,$(DEV_COMPONENTS))
dev:
	@if ! test -f $(call sh_quote,$(DEV_CONFIG)) && test -f .kind/local/cluster.json; then $(MAKE) local-dev-setup DEV_CONFIG=$(call sh_quote,$(DEV_CONFIG)); fi
	$(call sh_quote,$(PYTHON)) ci/agent-relay/dev/dev.py run --config $(call sh_quote,$(DEV_CONFIG)) $(if $(DEV_PLAN),--plan $(call sh_quote,$(DEV_PLAN))) --components $(call sh_quote,$(DEV_COMPONENTS))
dev-test:
	$(call sh_quote,$(PYTHON)) -m unittest discover -s ci/agent-relay/dev -p 'test_*.py'
	node --test ci/agent-relay/dev/test_frontend.mjs
