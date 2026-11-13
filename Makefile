.DEFAULT_GOAL := help
DEV_CONFIG ?= .kind/dev/config.json
DEV_PLAN ?=
DEV_COMPONENTS ?= all
ACCEPTANCE_CONFIG ?= .kind/acceptance/config.json
ACCEPTANCE_OUTPUT ?= .kind/acceptance/acceptance.json
ACCEPTANCE_KEY ?= .kind/acceptance/signing_key
ACCEPTANCE_SUITE ?= full
sh_quote = '$(subst ','"'"',$(1))'
PROFILE ?= core
PYTHON ?= python3
# Quote arbitrary PROFILE text as one shell argument before Python validates it.
profile_arg = '$(subst ','"'"',$(PROFILE))'

.PHONY: help kind-up kind-up-local-control kind-down kind-render kind-build-addons kind-build-control kind-proof kind-proof-core kind-proof-addons kind-reconcile-names
help:
	@echo "Fresh local stack: make local-up; one-time macOS trust: make local-trust; source loop: make dev"
	@echo "Clean Mac prerequisites: make local-tools (checkout-local pinned Kind, Helm and Python dependencies)"
	@echo "Kind-profile Desktop: make desktop-install (docs/local-desktop.md)"
	@echo "Qualification runner: make local-acceptance (docs/local-acceptance.md; API foundation available)"
	@echo "Code loop: make dev after one-time configure; optional make dev-plan (existing Kind; docs/kind-development.md)"
	@echo "Native core installer: docs/native-kind-core-lifecycle.md; delete an old single-phase cluster: make kind-down PROFILE=core|addons"
	@echo "Image builds: kind-build-control, kind-build-addons. Retired with the standalone RelayHistory server: kind-up, kind-render, kind-proof, kind-reconcile-names"

# The single-phase kind profile ran the removed standalone RelayHistory server.
# These targets refuse (before any state or cluster access) and point at
# make local-up and the native core installer.
kind-up kind-up-local-control kind-render kind-proof kind-proof-core kind-proof-addons kind-reconcile-names:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/stack.py up --profile $(profile_arg)

.PHONY: local-tools
local-tools:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/local_tools.py --prepare

.PHONY: desktop-install
desktop-install:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/desktop_install.py $(if $(DESKTOP_RUN),--run $(call sh_quote,$(DESKTOP_RUN))) $(if $(DESKTOP_ARTIFACT_DIR),--artifact-dir $(call sh_quote,$(DESKTOP_ARTIFACT_DIR)))

kind-down:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/stack.py down --profile $(profile_arg)
kind-build-control:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/stack.py build-control --profile $(profile_arg)

kind-build-addons:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/kind/stack.py build-addons --profile addons

.PHONY: dev dev-plan dev-test
dev-plan:
	$(call sh_quote,$(PYTHON)) ci/agent-relay/dev/dev.py plan --config $(call sh_quote,$(DEV_CONFIG)) $(if $(DEV_PLAN),--plan $(call sh_quote,$(DEV_PLAN))) --components $(call sh_quote,$(DEV_COMPONENTS))
dev:
	@if ! test -f $(call sh_quote,$(DEV_CONFIG)) && test -f .kind/local/cluster.json; then $(MAKE) local-dev-setup DEV_CONFIG=$(call sh_quote,$(DEV_CONFIG)); fi
	$(call sh_quote,$(PYTHON)) ci/agent-relay/dev/dev.py run --config $(call sh_quote,$(DEV_CONFIG)) $(if $(DEV_PLAN),--plan $(call sh_quote,$(DEV_PLAN))) --components $(call sh_quote,$(DEV_COMPONENTS))
dev-test:
	$(call sh_quote,$(PYTHON)) -m unittest discover -s ci/agent-relay/dev -p 'test_*.py'
	node --test ci/agent-relay/dev/test_frontend.mjs

.PHONY: local-up local-down
local-up: local-tools
	PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(CURDIR)/.kind/tools/venv/bin/python3) ci/agent-relay/kind/local_stack.py up
local-down: local-tools
	PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(CURDIR)/.kind/tools/venv/bin/python3) ci/agent-relay/kind/local_stack.py down

.PHONY: local-trust local-login local-llm-key
local-trust:
	sudo $(call sh_quote,$(PYTHON)) ci/agent-relay/kind/local_host_setup.py up
local-login: local-tools
	PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(CURDIR)/.kind/tools/venv/bin/python3) ci/agent-relay/kind/local_stack.py login
local-llm-key: local-tools
	@PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(CURDIR)/.kind/tools/venv/bin/python3) ci/agent-relay/kind/local_stack.py llm-key

.PHONY: local-postgres-cast-proof
local-postgres-cast-proof: local-tools
	@PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(CURDIR)/.kind/tools/venv/bin/python3) ci/agent-relay/kind/local_stack.py postgres-cast-proof

.PHONY: local-dev-setup
local-dev-setup: local-tools
	PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(CURDIR)/.kind/tools/venv/bin/python3) ci/agent-relay/kind/local_dev_setup.py --output $(call sh_quote,$(DEV_CONFIG))

.PHONY: local-acceptance local-acceptance-test
local-acceptance:
	@PATH=$(call sh_quote,$(CURDIR)/.kind/tools):"$$PATH" $(call sh_quote,$(PYTHON)) ci/agent-relay/kind/acceptance/run.py run --config $(call sh_quote,$(ACCEPTANCE_CONFIG)) --output $(call sh_quote,$(ACCEPTANCE_OUTPUT)) --key $(call sh_quote,$(ACCEPTANCE_KEY)) --suite $(call sh_quote,$(ACCEPTANCE_SUITE))
local-acceptance-test:
	$(call sh_quote,$(PYTHON)) -m unittest discover -s ci/agent-relay/kind/acceptance -p 'test_*.py' -v
