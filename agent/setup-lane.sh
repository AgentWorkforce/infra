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

# The AWS credential broker (agent/broker, DESIGN.md), when credentialBroker
# is on (the env file names CRED_BROKER_ROLE_ARN) and broker.ref pins a commit:
#  - code: exactly that commit of AgentWorkforce/infra, fetched by git (which
#    checks every object against the commit hash), installed root-owned and
#    read-only under /opt/aws-cred-broker/<sha>, "current" pointing at it;
#  - runs as the system user credbroker. Its home /var/lib/aws-cred-broker
#    (0700) holds the state, the audit log, file deliveries and the only AWS
#    profile for the broker role, so the agent user can't edit the
#    allowlist, claims or audit log;
#  - the agent user may run /usr/local/libexec/aws-cred-broker as credbroker
#    (sudoers) only with the subcommands request, refuse, sweep and
#    verify-audit, and nothing else; /usr/local/bin/aws-cred-broker wraps
#    that. Not approve: the lead would be passing the approver's identity
#    itself, so approvals stay off until the Relay listener verifies senders.
BROKER_HOME=/var/lib/aws-cred-broker
broker_ref=$(tr -d '[:space:]' < /opt/agent-host/broker.ref 2>/dev/null || true)
if [ -n "${CRED_BROKER_ROLE_ARN:-}" ] && printf '%s' "$broker_ref" | grep -qxE '[0-9a-f]{40}'; then
  id credbroker >/dev/null 2>&1 || useradd --system --home-dir "$BROKER_HOME" --create-home --shell /usr/sbin/nologin credbroker
  install -d -m 0700 -o credbroker -g credbroker "$BROKER_HOME" "$BROKER_HOME/state" "$BROKER_HOME/creds" "$BROKER_HOME/.aws"
  # A failed fetch (GitHub down, a bad ref) never fails the rest of the lane
  # setup: it is reported and the previously installed version stays current.
  install_broker() {
    local ref=$1 tmp dest="/opt/aws-cred-broker/$1"
    [ -f "$dest/src/cli.ts" ] && return 0
    tmp=$(mktemp -d)
    git -c init.defaultBranch=main init -q "$tmp/repo" || { rm -rf "$tmp"; return 1; }
    git -C "$tmp/repo" fetch -q --depth 1 https://github.com/AgentWorkforce/infra.git "$ref" || { rm -rf "$tmp"; return 1; }
    [ "$(git -C "$tmp/repo" rev-parse FETCH_HEAD)" = "$ref" ] || { rm -rf "$tmp"; return 1; }
    mkdir -p "$tmp/out"
    git -C "$tmp/repo" archive FETCH_HEAD agent/broker/src agent/broker/allowlist.json | tar -x -C "$tmp/out" || { rm -rf "$tmp"; return 1; }
    if ! { install -d -m 0755 -o root -g root /opt/aws-cred-broker "$dest.new" "$dest.new/src" &&
      install -m 0644 -o root -g root "$tmp/out/agent/broker/allowlist.json" "$dest.new/allowlist.json" &&
      install -m 0644 -o root -g root "$tmp/out/agent/broker/src/"*.ts "$dest.new/src/" &&
      rm -rf "$dest" && mv -T "$dest.new" "$dest"; }; then
      rm -rf "$tmp" "$dest.new"
      return 1
    fi
    rm -rf "$tmp"
  }
  if install_broker "$broker_ref"; then
    ln -sfn "/opt/aws-cred-broker/$broker_ref" /opt/aws-cred-broker/current.new && mv -Tf /opt/aws-cred-broker/current.new /opt/aws-cred-broker/current
  else
    echo "setup-lane: could not install the credential broker at $broker_ref; keeping the current version" >&2
  fi
  install -d -m 0755 -o root -g root /usr/local/libexec
  node_bin=$(command -v node)
  {
    printf '#!/bin/bash\n# Runs the AWS credential broker as credbroker (setup-lane.sh). Generated; do not edit.\nset -euo pipefail\n'
    printf 'export HOME=%s AWS_CONFIG_FILE=%s/.aws/config AWS_REGION=%s AWS_PAGER=\n' "$BROKER_HOME" "$BROKER_HOME" "$AWS_REGION"
    printf 'export BROKER_STATE_DIR=%s/state BROKER_DELIVERY_DIR=%s/creds BROKER_AWS_PROFILE=aws-cred-broker\n' "$BROKER_HOME" "$BROKER_HOME"
    printf 'exec %s --experimental-strip-types --no-warnings /opt/aws-cred-broker/current/src/cli.ts "$@"\n' "$node_bin"
  } > /usr/local/libexec/aws-cred-broker.new
  install -m 0755 -o root -g root /usr/local/libexec/aws-cred-broker.new /usr/local/libexec/aws-cred-broker && rm -f /usr/local/libexec/aws-cred-broker.new
  printf '#!/bin/bash\nexec sudo -n -u credbroker /usr/local/libexec/aws-cred-broker "$@"\n' > /usr/local/bin/aws-cred-broker.new
  install -m 0755 -o root -g root /usr/local/bin/aws-cred-broker.new /usr/local/bin/aws-cred-broker && rm -f /usr/local/bin/aws-cred-broker.new
  b=/usr/local/libexec/aws-cred-broker
  printf 'agent ALL=(credbroker) NOPASSWD: %s request *, %s refuse *, %s sweep, %s verify-audit\n' "$b" "$b" "$b" "$b" > /etc/sudoers.d/aws-cred-broker.new
  if visudo -cf /etc/sudoers.d/aws-cred-broker.new >/dev/null; then
    install -m 0440 -o root -g root /etc/sudoers.d/aws-cred-broker.new /etc/sudoers.d/aws-cred-broker
  fi
  rm -f /etc/sudoers.d/aws-cred-broker.new
  sudo -H -u credbroker env ROLE="$CRED_BROKER_ROLE_ARN" REGION="$AWS_REGION" bash -c '
    umask 077
    printf "[profile aws-cred-broker]\nrole_arn = %s\ncredential_source = Ec2InstanceMetadata\nrole_session_name = layered-infra-ops-cred-broker\nregion = %s\n" \
      "$ROLE" "$REGION" > ~/.aws/config.new && mv -f ~/.aws/config.new ~/.aws/config'
fi
