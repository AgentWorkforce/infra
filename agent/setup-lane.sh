#!/bin/bash
# infra-ops' lane setup, run as root at the end of the kit's setup.sh (first
# boot, and again by every hot update). Idempotent. The kit already installs
# the AWS CLI, Node, gh and Claude Code.
#  - gcloud (with kubectl and the GKE auth plugin) and az, from their vendors'
#    apt repositories.
#  - terraform and helm at the versions this repo's CI pins.
#  - wrangler and posthog-cli from npm, pinned.
#  - The agent user's AWS config: the default profile assumes the admin role
#    (AWS_ADMIN_ROLE_ARN); profile "instance" is the host role alone.
set -euo pipefail
# shellcheck source=/dev/null
. /opt/agent-host/env

TERRAFORM_VERSION=1.16.7
HELM_VERSION=v4.3.1
WRANGLER_VERSION=4.161.0
POSTHOG_CLI_VERSION=0.20.0

export DEBIAN_FRONTEND=noninteractive
install -d -m 0755 /etc/apt/keyrings
add_repo() {
  local name=$1 key_url=$2 line=$3
  [ -f "/etc/apt/sources.list.d/$name.list" ] && return 0
  curl -fsSL "$key_url" | gpg --dearmor --yes -o "/etc/apt/keyrings/$name.gpg"
  echo "deb [signed-by=/etc/apt/keyrings/$name.gpg] $line" > "/etc/apt/sources.list.d/$name.list"
}
add_repo google-cloud-sdk https://packages.cloud.google.com/apt/doc/apt-key.gpg "https://packages.cloud.google.com/apt cloud-sdk main"
# shellcheck source=/dev/null
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
add_repo azure-cli https://packages.microsoft.com/keys/microsoft.asc "https://packages.microsoft.com/repos/azure-cli/ $codename main"
need=()
for pkg in google-cloud-cli kubectl google-cloud-cli-gke-gcloud-auth-plugin azure-cli; do
  dpkg -s "$pkg" >/dev/null 2>&1 || need+=("$pkg")
done
if [ ${#need[@]} -gt 0 ]; then
  apt-get update -q
  apt-get install -y -q "${need[@]}"
fi

if ! terraform version 2>/dev/null | grep -qx "Terraform v$TERRAFORM_VERSION"; then
  tmp=$(mktemp -d)
  curl -fsSL "https://releases.hashicorp.com/terraform/$TERRAFORM_VERSION/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o "$tmp/tf.zip"
  unzip -q -o "$tmp/tf.zip" terraform -d "$tmp" && install -m 0755 "$tmp/terraform" /usr/local/bin/terraform
  rm -rf "$tmp"
fi
if ! helm version --template '{{.Version}}' 2>/dev/null | grep -qx "$HELM_VERSION"; then
  tmp=$(mktemp -d)
  curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" | tar -xz -C "$tmp"
  install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "$tmp"
fi
npm_pin() {
  local pkg=$1 version=$2
  [ "$(npm ls -g --depth=0 --json "$pkg" 2>/dev/null | jq -r --arg p "$pkg" '.dependencies[$p].version // empty')" = "$version" ] \
    || npm install -g --no-audit --no-fund "$pkg@$version"
}
npm_pin wrangler "$WRANGLER_VERSION"
npm_pin @posthog/cli "$POSTHOG_CLI_VERSION"

# Written as the agent user: root never writes into a path the agent controls.
if [ -n "${AWS_ADMIN_ROLE_ARN:-}" ]; then
  sudo -H -u agent env ROLE="$AWS_ADMIN_ROLE_ARN" REGION="$AWS_REGION" bash -c '
    umask 077; mkdir -p ~/.aws
    printf "[default]\nrole_arn = %s\ncredential_source = Ec2InstanceMetadata\nrole_session_name = layered-infra-ops\nregion = %s\n\n[profile instance]\nregion = %s\n" \
      "$ROLE" "$REGION" "$REGION" > ~/.aws/config.new && mv -f ~/.aws/config.new ~/.aws/config'
fi
