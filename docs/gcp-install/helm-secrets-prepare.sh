#!/usr/bin/env bash
# For teams using the helm-secrets plugin: turn the install's generated secret
# files into one values file you can encrypt with SOPS, plus a tiny chart that
# creates the five Kubernetes Secrets from it.
#
#   bash helm-secrets-prepare.sh                     # after cloud-sql-setup.sh pre
#   VALS_GCPSM=<project id> bash helm-secrets-prepare.sh
#
# Writes, in the current folder:
#   agent-relay-secrets-chart/   the chart (5 Secrets, nothing else)
#   secrets.yaml                 PLAINTEXT values: encrypt it, then delete it
# With VALS_GCPSM=<project id>, each value goes to Google Secret Manager instead
# (secret agent-relay--<Secret>--<key>, a new version on rerun), and
# secrets.yaml holds only vals references (ref+gcpsecrets://...), no secret
# values. Needs gcloud for that, with secretmanager.secrets.create and
# secretmanager.versions.add on the project.
# Needs python3 (standard library only) and openssl.
set -euo pipefail
SRC="${SECRET_FILES:-${STATE_DIR:-$HOME/.agent-relay-install}/secret-files}"
[ -d "$SRC/agent-relay-secrets" ] || { echo "no $SRC/agent-relay-secrets: run cloud-sql-setup.sh pre first" >&2; exit 1; }

# The generated keys from 0-START-HERE.md step 10, created here if missing.
S="$SRC"
( umask 077
for k in selfhost-bootstrap-token selfhost-setup-key relaycast-internal-secret \
         relaycast-workspace-bootstrap-secret relaycontrol-introspect-secret session-read-api-secret \
         selfhost-encryption-key; do
  [ -s "$S/agent-relay-secrets/$k" ] || openssl rand -hex 32 | tr -d '\n' > "$S/agent-relay-secrets/$k"
done
[ -s "$S/agent-relay-secrets/SUMMARY_MASTER_KEYS" ] || printf 'k1:%s' "$(openssl rand -hex 32)" > "$S/agent-relay-secrets/SUMMARY_MASTER_KEYS"
cp "$S/agent-relay-secrets/relaycontrol-introspect-secret" "$S/agent-relay-ingest-edge-runtime/introspect-secret" )

mkdir -p agent-relay-secrets-chart/templates
cat > agent-relay-secrets-chart/Chart.yaml <<'EOF'
apiVersion: v2
name: agent-relay-secrets
description: The Kubernetes Secrets the agent-relay chart references by name.
version: 0.1.0
EOF
cat > agent-relay-secrets-chart/templates/secrets.yaml <<'EOF'
{{- range $name, $data := .Values.secrets }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ $name }}
type: Opaque
data:
{{- range $key, $value := $data }}
  {{ $key }}: {{ $value | b64enc | quote }}
{{- end }}
{{- end }}
EOF

NAMES="agent-relay-secrets agent-relay-read-api agent-relay-ingest-edge-runtime search-indexer-runtime search-indexer-owner"

if [ -n "${VALS_GCPSM:-}" ]; then
  P="$VALS_GCPSM"
  n_values=0
  for n in $NAMES; do
    for f in "$SRC/$n"/*; do
      [ -f "$f" ] || continue
      id="agent-relay--$n--$(basename "$f")"
      gcloud secrets describe "$id" --project "$P" >/dev/null 2>&1 || \
        gcloud secrets create "$id" --project "$P" --replication-policy automatic \
          --labels app=agent-relay --quiet >/dev/null
      gcloud secrets versions add "$id" --project "$P" --data-file "$f" --quiet >/dev/null
      n_values=$((n_values + 1))
    done
  done
  python3 - "$SRC" "$P" > secrets.yaml <<'EOF'
import json, os, sys
src, project = sys.argv[1:3]
names = ["agent-relay-secrets", "agent-relay-read-api", "agent-relay-ingest-edge-runtime",
         "search-indexer-runtime", "search-indexer-owner"]
out = {}
for n in names:
    d = os.path.join(src, n)
    out[n] = {k: "ref+gcpsecrets://%s/agent-relay--%s--%s?version=latest" % (project, n, k)
              for k in sorted(os.listdir(d)) if os.path.isfile(os.path.join(d, k)) and not k.startswith(".")}
print(json.dumps({"secrets": out}, indent=1))
EOF
  echo "stored $n_values values in Secret Manager (project $P) and wrote vals references to secrets.yaml"
  echo "Next: helm secrets --backend vals upgrade --install agent-relay-secrets ./agent-relay-secrets-chart -n agent-relay -f secrets.yaml"
  exit 0
fi

( umask 077
python3 - "$SRC" > secrets.yaml <<'EOF'
import json, os, sys
src = sys.argv[1]
names = ["agent-relay-secrets", "agent-relay-read-api", "agent-relay-ingest-edge-runtime",
         "search-indexer-runtime", "search-indexer-owner"]
out = {}
for n in names:
    d = os.path.join(src, n)
    out[n] = {k: open(os.path.join(d, k)).read() for k in sorted(os.listdir(d))
              if os.path.isfile(os.path.join(d, k)) and not k.startswith(".")}
# JSON is valid YAML; one key per line keeps SOPS diffs readable.
print(json.dumps({"secrets": out}, indent=1))
EOF
)
echo "wrote agent-relay-secrets-chart/ and secrets.yaml ($(grep -c '": "' secrets.yaml) values)"
echo "Next: sops -e secrets.yaml > secrets.enc.yaml && rm secrets.yaml   (e.g. sops --gcp-kms <key resource id>)"
