#!/usr/bin/env bash
# Render only: checks every MCP/OAuth route, Chief ordering and Azure parity.
set -euo pipefail
cd "$(dirname "$0")/../../.."
python3 ci/agent-relay/test_ingress_routes.py Routes.test_eks_with_chief_and_flows Routes.test_azure
