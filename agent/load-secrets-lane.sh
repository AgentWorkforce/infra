#!/bin/bash
# infra-ops' lane step, run as root after the kit writes
# /run/agent-host/secrets.env (boot and every secrets refresh). Idempotent;
# a missing credential is skipped, never fatal, and no value is printed.
#  - GCP: the credential JSON to /run/agent-host/gcp-service-account.json
#    (root:agent 0640), gcloud signed in with it, its project as the default.
#    Either a workload identity config (external_account: keyless, the host
#    role impersonates the service account) or a service-account key.
#  - Aliases in secrets.env for the names other tools read: GOOGLE_APPLICATION_CREDENTIALS,
#    ARM_* (Terraform azurerm), POSTHOG_CLI_TOKEN / POSTHOG_CLI_HOST.
#  - Azure: az signed in as the service principal, its subscription the default.
set -uo pipefail
# shellcheck source=/dev/null
. /opt/agent-host/env
out=/run/agent-host/secrets.env
key=/run/agent-host/gcp-service-account.json
val() { sed -n "s/^$1=//p" "$out" | tail -1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "${GCP_SA_KEY_PARAM:-}" ] \
  && aws ssm get-parameter --region "$AWS_REGION" --with-decryption --name "$GCP_SA_KEY_PARAM" --query Parameter.Value --output text > "$tmp/gcp" 2>/dev/null \
  && jq -e '.type == "service_account" or .type == "external_account"' "$tmp/gcp" >/dev/null 2>&1; then
  install -m 0640 -o root -g agent "$tmp/gcp" "$key"
  project=$(jq -r '.project_id // .quota_project_id // empty' "$key")
  sudo -H -u agent env KEY="$key" PROJECT="$project" bash -c '
    gcloud auth login --cred-file="$KEY" --quiet >/dev/null 2>&1 || echo "load-secrets-lane: gcloud sign-in failed" >&2
    [ -z "$PROJECT" ] || gcloud config set project "$PROJECT" --quiet >/dev/null 2>&1' || true
else
  echo "load-secrets-lane: no GCP credential config; gcloud not signed in" >&2
fi

{
  [ -f "$key" ] && echo "GOOGLE_APPLICATION_CREDENTIALS=$key"
  [ -n "$(val AZURE_TENANT_ID)" ] && echo "ARM_TENANT_ID=$(val AZURE_TENANT_ID)"
  [ -n "$(val AZURE_CLIENT_ID)" ] && echo "ARM_CLIENT_ID=$(val AZURE_CLIENT_ID)"
  [ -n "$(val AZURE_CLIENT_SECRET)" ] && echo "ARM_CLIENT_SECRET=$(val AZURE_CLIENT_SECRET)"
  [ -n "$(val AZURE_SUBSCRIPTION_ID)" ] && echo "ARM_SUBSCRIPTION_ID=$(val AZURE_SUBSCRIPTION_ID)"
  [ -n "$(val POSTHOG_PERSONAL_API_KEY)" ] && echo "POSTHOG_CLI_TOKEN=$(val POSTHOG_PERSONAL_API_KEY)"
  [ -n "$(val POSTHOG_HOST)" ] && echo "POSTHOG_CLI_HOST=$(val POSTHOG_HOST)"
  true
} > "$tmp/aliases"
grep -v -E '^(GOOGLE_APPLICATION_CREDENTIALS|ARM_(TENANT|CLIENT|SUBSCRIPTION)_[A-Z_]*|POSTHOG_CLI_(TOKEN|HOST))=' "$out" > "$tmp/env" || true
cat "$tmp/aliases" >> "$tmp/env"
install -m 0600 -o agent -g agent "$tmp/env" "$out.new" && mv -f "$out.new" "$out"

if [ -n "$(val AZURE_CLIENT_SECRET)" ] && [ -n "$(val AZURE_TENANT_ID)" ] && [ -n "$(val AZURE_CLIENT_ID)" ]; then
  # az takes the secret only as an argument, so it is briefly in this host's
  # process list; only root and the agent user (which holds it anyway) run here.
  sudo -H -u agent env AZ_T="$(val AZURE_TENANT_ID)" AZ_C="$(val AZURE_CLIENT_ID)" AZ_S="$(val AZURE_CLIENT_SECRET)" AZ_SUB="$(val AZURE_SUBSCRIPTION_ID)" bash -c '
    az login --service-principal --tenant "$AZ_T" --username "$AZ_C" --password "$AZ_S" --output none >/dev/null 2>&1 || { echo "load-secrets-lane: az sign-in failed" >&2; exit 0; }
    [ -z "$AZ_SUB" ] || az account set --subscription "$AZ_SUB" >/dev/null 2>&1' || true
else
  echo "load-secrets-lane: no Azure service principal; az not signed in" >&2
fi
exit 0
