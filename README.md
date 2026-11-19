# AgentWorkforce Infrastructure

Install Agent Relay in your own cloud account. This repository provides the infrastructure and application packages operators use to bring the services online.

## Get started

Start with the [Agent Relay getting-started guide](https://agentrelay.com/docs/getting-started). See the [repository guide](docs/repository-guide.md) for supported install paths, platform guides, requirements and releases.

## Local application development

For application development with the sibling Next app, editable dashboard and
Desktop hot reload, start with [`./dev.sh`](docs/dev-launcher.md). It checks
required sibling repositories and local Google OAuth configuration before
starting. Container readiness and full application E2E are reported separately.
