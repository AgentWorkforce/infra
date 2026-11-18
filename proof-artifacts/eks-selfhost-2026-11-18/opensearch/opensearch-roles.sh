#!/usr/bin/env bash
# Reusable; reads AWS creds at run time (never printed). Requires facts.env sourced, kubectl working, admin role session.
source /home/agent/state/eks-proof/run/facts.env
HOST=$OPENSEARCH_ENDPOINT
trap 'kill $PF 2>/dev/null; kubectl -n default delete pod os-relay --ignore-not-found >/dev/null' EXIT
kubectl -n default run os-relay --image=alpine/socat:1.8.0.3 --restart=Never --labels=owner=$TAG_OWNER,purpose=$TAG_PURPOSE -- TCP-LISTEN:9443,fork,reuseaddr "TCP:$HOST:443"
kubectl -n default wait --for=condition=Ready pod/os-relay --timeout=2m
kubectl -n default port-forward pod/os-relay 9443:9443 >/dev/null & PF=$!; sleep 3
eval "$(aws configure export-credentials --format env)"
os() { # prints body then HTTP status line (body never contains creds)
  curl -sS --aws-sigv4 "aws:amz:$AWS_REGION:es" --connect-to "$HOST:443:127.0.0.1:9443" \
   -K <(printf 'user = "%s:%s"\nheader = "x-amz-security-token: %s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "${AWS_SESSION_TOKEN:-}") \
   -H 'Content-Type: application/json' -w '\nHTTP_STATUS=%{http_code}\n' -X "$1" "https://$HOST$2" ${3:+-d "$3"}; }
echo "## whoami"; os GET /_plugins/_security/whoami
echo "## authinfo"; os GET /_plugins/_security/authinfo
echo "## PUT role indexer"; os PUT /_plugins/_security/api/roles/relayhistory_indexer '{"cluster_permissions":["cluster_monitor","indices:data/write/bulk"],"index_permissions":[{"index_patterns":["relayhistory-*"],"allowed_actions":["write","create_index","indices:data/write/bulk*","indices:monitor/settings/get","indices:admin/mapping/put","indices:data/read/search*","indices:data/read/scroll*","indices:data/read/mget*","indices:data/write/delete/byquery","indices:admin/refresh*","indices:admin/get"]}]}'
echo "## PUT mapping indexer"; os PUT /_plugins/_security/api/rolesmapping/relayhistory_indexer "{\"backend_roles\":[\"$INDEXER_ROLE_ARN\"]}"
echo "## PUT role reader"; os PUT /_plugins/_security/api/roles/relayhistory_reader '{"cluster_permissions":["cluster_composite_ops_ro"],"index_permissions":[{"index_patterns":["relayhistory-*"],"allowed_actions":["read"]}]}'
echo "## PUT mapping reader"; os PUT /_plugins/_security/api/rolesmapping/relayhistory_reader "{\"backend_roles\":[\"$READER_ROLE_ARN\"]}"
echo "## GET mapping indexer"; os GET /_plugins/_security/api/rolesmapping/relayhistory_indexer
echo "## GET mapping reader"; os GET /_plugins/_security/api/rolesmapping/relayhistory_reader
