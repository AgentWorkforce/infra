# Sourced by every step. Everything lives under $W; nothing touches ~/.kube/config.
W="${W:-$HOME/cfgrds-test}"
INFRA="${INFRA:-$W/infra}"
export KUBECONFIG="$W/kubeconfig"
export CLUSTER=cfgrds-test KCTX=kind-cfgrds-test
export RDS_HOST=cfgrds-test.cabc123xyz45.us-west-2.rds.amazonaws.com
export AWS_REGION=us-west-2
export PATH="$W/shims:$W/bin:$PATH"
export SHIM_DIR="$W/shims" SM_DIR="$W/secretsmanager" TEST_CA="$W/certs/ca.crt"
mkdir -p "$SM_DIR"
[[ -s "$W/master.pw" ]] || openssl rand -hex 16 > "$W/master.pw"
MASTER_PW="$(cat "$W/master.pw")"
k() { kubectl --context "$KCTX" -n agent-relay "$@"; }
# Docker over SSH: the Desktop credential helper needs the keychain; public pulls don't.
export DOCKER_HOST="unix://$HOME/.docker/run/docker.sock"
export DOCKER_CONFIG="$W/docker-config"
mkdir -p "$DOCKER_CONFIG"; echo '{"credsStore":"cfgrds"}' > "$DOCKER_CONFIG/config.json"
export PG_MAJOR="${PG_MAJOR:-16}"
