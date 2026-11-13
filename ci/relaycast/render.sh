#!/usr/bin/env bash
# Rendered-chart assertions for charts/relaycast runtime.backend=postgres
# (the contract in AgentWorkforce/relaycast docs/self-host-postgres.md). Offline.
# Usage: ci/relaycast/render.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHART="$ROOT/charts/relaycast"
V="$CHART/ci/postgres-values.yaml"
DIGEST=sha256:1307bd845031a7466e65ebaf08bc8b826e2837d90f58c9b5a6a1d673c62dad93
fail=0
err() { echo "::error::$*"; fail=1; }
render() { helm template ci "$CHART" --namespace ci -f "$V" "$@"; }
expect_refused() { # <label> <expected error> [helm args]
  local label=$1 expected=$2 out; shift 2
  if out=$(render "$@" 2>&1); then err "$label: rendered"; elif ! grep -Fq "$expected" <<<"$out"; then err "$label: wrong error: $out"; fi
}
is() { [ "$2" = "$3" ] || err "$1: expected '$3', got '$2'"; }

out=$(render)
job='select(.kind == "Job")'
dep='select(.kind == "Deployment")'
# One document each: yq's [...] yields an empty array for every unselected document.
job_doc=$(yq "$job" <<<"$out")
dep_doc=$(yq "$dep" <<<"$out")
pod=".spec.template.spec"
y() { yq "$1" <<<"$out"; }
jy() { yq "$1" <<<"$job_doc"; }
dy() { yq "$1" <<<"$dep_doc"; }

# Migration Job: plain, hash-named, owner URL only, not selected by the Service.
is "one Job" "$(jy ".metadata.name" | grep -c migrate)" 1
jy ".metadata.name" | grep -Eq '^ci-relaycast-migrate-[0-9a-f]{8}$' || err "Job name is not hash-suffixed"
is "no hooks" "$(jy ".metadata.annotations // {} | has(\"helm.sh/hook\")")" false
is "Job args" "$(jy ".spec.template.spec.containers[0].args | join(\" \")")" migrate
is "Job image" "$(jy ".spec.template.spec.containers[0].image")" "ghcr.io/agentworkforce/relaycast-self-host@$DIGEST"
is "Job URL file" "$(jy ".spec.template.spec.containers[0].env[] | select(.name == \"RELAYCAST_DATABASE_URL_FILE\") | .value")" /run/secrets/relaycast/database-owner-url
is "Job Secret keys" "$(jy "[.spec.template.spec.volumes[] | select(.name == \"secrets\") | .secret.items[].key] | join(\",\")")" database-owner-url
is "Job pod name label" "$(jy ".spec.template.metadata.labels[\"app.kubernetes.io/name\"]")" relaycast-migrate
is "Job own ServiceAccount" "$(jy ".spec.template.spec.serviceAccountName")" ci-relaycast-migrate
is "Job no token" "$(jy ".spec.template.spec.automountServiceAccountToken")" false
is "exit 64/65 not retried" "$(jy ".spec.podFailurePolicy.rules[0].onExitCodes.values | join(\",\")")" 64,65
old=$(render --kube-version 1.22.0 | yq "$job")
is "no podFailurePolicy before 1.26" "$(yq '.spec | has("podFailurePolicy")' <<<"$old")" false
[ "$(yq '.metadata.name' <<<"$old")" != "$(jy ".metadata.name")" ] || err "adding podFailurePolicy must rename the immutable Job"
for w in "jy .spec.template.spec.containers[0]" "dy $pod.containers[0]" "dy $pod.initContainers[0]"; do
  q=${w%% *}; path=${w#* }
  is "CA env ($path)" "$($q "$path | .env[] | select(.name == \"NODE_EXTRA_CA_CERTS\") | .value")" /etc/postgres-ca/ca.crt
  is "CA mount ($path)" "$($q "$path | .volumeMounts[] | select(.name == \"postgres-ca\") | .mountPath")" /etc/postgres-ca
done

# Server: runtime URL, no SQLite, gated on the migration, one replica, no backup.
is "server image" "$(dy "$pod | .containers[0].image")" "ghcr.io/agentworkforce/relaycast-self-host@$DIGEST"
is "server URL file" "$(dy "$pod | .containers[0].env[] | select(.name == \"RELAYCAST_DATABASE_URL_FILE\") | .value")" /run/secrets/relaycast/database-runtime-url
is "server base url" "$(dy "$pod | .containers[0].args | .[0] + \" \" + .[1]")" "--base-url https://relay.example.com"
is "server has no --db" "$(dy "$pod | [.containers[0].args[] | select(. == \"--db\")] | length")" 0
is "server has no SQLite path" "$(dy "$pod | [.containers[0].env[] | select(.name == \"RELAYCAST_DB_PATH\")] | length")" 0
is "no TTL" "$(dy "$pod | [.containers[0].env[] | select(.name == \"RELAYCAST_MESSAGE_TTL_DAYS\")] | length")" 0
is "no schema or role env" "$(dy "$pod | [.containers[0].env[] | select(.name | test(\"RELAYCAST_DATABASE_(SCHEMA|OWNER_ROLE|RUNTIME_ROLE)\"))] | length")" 0
is "server never gets the owner URL" "$(dy "$pod | [.volumes[] | select(.name == \"secrets\") | .secret.items[].key] | contains([\"database-owner-url\"])")" false
is "server keeps secrets" "$(dy "$pod | [.volumes[] | select(.name == \"secrets\") | .secret.items[].key] | contains([\"internal-secret\", \"workspace-bootstrap-secret\", \"database-runtime-url\"])")" true
is "init waits with verify-db" "$(dy "$pod | .initContainers[0].args[1] | contains(\"verify-db\")")" true
is "init uses runtime URL" "$(dy "$pod | .initContainers[0].env[] | select(.name == \"RELAYCAST_DATABASE_URL_FILE\") | .value")" /run/secrets/relaycast/database-runtime-url
is "replicas" "$(dy ".spec.replicas")" 1
is "PVC kept" "$(y 'select(.kind == "PersistentVolumeClaim") | .metadata.name')" ci-relaycast-data
is "/data still mounted" "$(dy "$pod | .containers[0].volumeMounts[] | select(.name == \"data\") | .mountPath")" /data
is "no CronJob" "$(y 'select(.kind == "CronJob") | .metadata.name' | grep -c . || true)" 0

# A changed pod template renames the Job.
a=$(jy ".metadata.name")
b=$(render --set postgresCa.key=rds.pem | yq "$job | .metadata.name")
c=$(render --set runtime.postgres.migrations.identitySalt=again | yq "$job | .metadata.name")
[ "$a" != "$b" ] || err "a pod template change did not rename the Job"
[ "$a" != "$c" ] || err "identitySalt did not rename the Job"

# The CA can come from a Secret.
s=$(render --set postgresCa.configMap= --set postgresCa.secret=ca-secret)
is "CA Secret" "$(yq "$job | .spec.template.spec.volumes[] | select(.name == \"postgres-ca\") | .secret.secretName" <<<"$s")" ca-secret

# Half-configured backends are refused.
expect_refused "no CA" "requires postgresCa.enabled=true" --set postgresCa.enabled=false --set postgresCa.configMap=
expect_refused "CA without source" "requires exactly one of" --set postgresCa.configMap=
expect_refused "CA with two sources" "requires exactly one of" --set postgresCa.secret=ca-secret
expect_refused "CA bad name" "Kubernetes object name" --set postgresCa.configMap=Bad_Name
expect_refused "CA bad key" "postgresCa.key must be" --set postgresCa.key=../x
expect_refused "no owner key" "requires secretKeys.databaseOwnerUrl" --set secretKeys.databaseOwnerUrl=
expect_refused "no runtime key" "requires secretKeys.databaseRuntimeUrl" --set secretKeys.databaseRuntimeUrl=
expect_refused "same URL key" "must be different keys" --set secretKeys.databaseRuntimeUrl=database-owner-url
expect_refused "URL key reused" "must not reuse a database URL key" --set secretKeys.internalSecret=database-owner-url
expect_refused "no Secret" "existingSecret is required" --set existingSecret=
expect_refused "two replicas" "replicaCount must be 1" --set replicaCount=2
expect_refused "SQLite backup" "backup.enabled is the SQLite backup" --set backup.enabled=true
expect_refused "message TTL" "retention.messageTtlDays is not supported" --set retention.messageTtlDays=30
expect_refused "bad digest" "runtime.postgres.image.digest must be" --set runtime.postgres.image.digest=sha256:abc
expect_refused "bad backoff" "backoffLimit must be" --set runtime.postgres.migrations.backoffLimit=-1
expect_refused "bad deadline" "activeDeadlineSeconds must be" --set runtime.postgres.migrations.activeDeadlineSeconds=0
for name in RELAYCAST_DATABASE_URL RELAYCAST_DATABASE_URL_FILE RELAYCAST_DATABASE_CA_FILE RELAYCAST_DATABASE_SCHEMA RELAYCAST_DATABASE_OWNER_ROLE RELAYCAST_DATABASE_RUNTIME_ROLE NODE_EXTRA_CA_CERTS PGSSLNEGOTIATION RELAYCAST_MESSAGE_TTL_DAYS; do
  expect_refused "$name via extraEnv" "$name is managed by structured chart values" --set-json "extraEnv=[{\"name\":\"$name\",\"value\":\"x\"}]"
done

# Other backends: no Postgres objects, and Postgres settings do not leak in.
d=$(helm template ci "$CHART" --namespace ci -f "$CHART/ci/default-values.yaml")
! grep -Eq 'RELAYCAST_DATABASE|NODE_EXTRA_CA_CERTS|postgres-ca|wait-for-migrations|-migrate' <<<"$d" || err "sqlite render carries Postgres objects"
sq() { helm template ci "$CHART" --namespace ci -f "$CHART/ci/default-values.yaml" "$@" 2>&1; }
if o=$(sq --set postgresCa.enabled=true --set postgresCa.configMap=x); then err "postgresCa on sqlite: rendered"; else grep -Fq "requires runtime.backend=postgres" <<<"$o" || err "postgresCa on sqlite: $o"; fi
if o=$(sq --set-json 'extraEnv=[{"name":"RELAYCAST_DATABASE_URL","value":"x"}]'); then err "database URL on sqlite: rendered"; else grep -Fq "set runtime.backend=postgres" <<<"$o" || err "database URL on sqlite: $o"; fi

# Managed analytics only changes the application pod. The database init and
# migration retain their own trust root and never see the collector credential.
! grep -Eq 'RELAYCAST_TELEMETRY_|analytics-producer|analytics-token' <<<"$d" || err "default render enables analytics"
analytics=(--set analytics.enabled=true --set-string analytics.deploymentId=kind_fixture
  --set-string analytics.collectorUrl=https://collector.ci.svc.cluster.local:8443/v1/events
  --set-string analytics.existingSecret=cast-analytics --set-string analytics.caConfigMap=collector-ca)
analytics_digest=sha256:ab9dd6781e68f09d5e2e686a17088f9ad533978ef13d974a47d6c212d8eedbde
cast=$(sq "${analytics[@]}" --set-string "image.digest=$analytics_digest" | yq "$dep")
pgcast=$(render "${analytics[@]}" --set-string "runtime.postgres.image.digest=$analytics_digest")
pgpod=$(yq "$dep" <<<"$pgcast")
is "SQLite analytics label" "$(yq '.spec.template.metadata.labels["agentworkforce.dev/analytics-producer"]' <<<"$cast")" true
is "SQLite analytics token projection" "$(yq "$pod.volumes[] | select(.name == \"analytics-token\") | .secret.secretName" <<<"$cast")" cast-analytics
is "SQLite analytics token file" "$(yq "$pod.containers[0].env[] | select(.name == \"RELAYCAST_TELEMETRY_COLLECTOR_TOKEN_FILE\") | .value" <<<"$cast")" /var/run/secrets/relaycast-analytics/token
is "Postgres analytics CA" "$(yq "$pod.containers[0].env[] | select(.name == \"NODE_EXTRA_CA_CERTS\") | .value" <<<"$pgpod")" /etc/relaycast-analytics-ca/ca.crt
is "Postgres explicit DB CA" "$(yq "$pod.containers[0].env[] | select(.name == \"RELAYCAST_DATABASE_CA_FILE\") | .value" <<<"$pgpod")" /etc/postgres-ca/ca.crt
is "Postgres init CA stays separate" "$(yq "$pod.initContainers[0].env[] | select(.name == \"NODE_EXTRA_CA_CERTS\") | .value" <<<"$pgpod")" /etc/postgres-ca/ca.crt
! yq "$job" <<<"$pgcast" | grep -Eq 'RELAYCAST_TELEMETRY_|analytics-token|analytics-ca' || err "migration Job carries analytics"
expect_refused "old PostgreSQL image" "immutable Relaycast image with collector support" "${analytics[@]}" \
  --set-string runtime.postgres.image.digest=sha256:84f59482cb82f3c50d38f45cfca7d004cffaa95652782dbfc93c179cc343ac59
expect_refused "non-TLS collector" "HTTPS DNS endpoint" "${analytics[@]}" --set-string analytics.collectorUrl=http://collector.ci.svc:8080/v1/events
expect_refused "collector userinfo" "HTTPS DNS endpoint" "${analytics[@]}" --set-string analytics.collectorUrl=https://user@collector.ci.svc:8443/v1/events
expect_refused "bad collector port" "port must be" "${analytics[@]}" --set-string analytics.collectorUrl=https://collector.ci.svc:65536/v1/events
expect_refused "reused credential secret" "separate from the Relaycast credential Secret" "${analytics[@]}" --set-string analytics.existingSecret=relaycast-secrets
expect_refused "invalid collector identity" "stable opaque installation ID" "${analytics[@]}" --set-string analytics.deploymentId=bad.identity
expect_refused "TLS override" "cannot override managed Relaycast analytics" "${analytics[@]}" --set-string "runtime.postgres.image.digest=$analytics_digest" --set-json 'extraEnv=[{"name":"NODE_TLS_REJECT_UNAUTHORIZED","value":"0"}]'


# Failover hardening (relaycast#667/#668): keepalive sysctls, split probes, heap, zone.
ka='.spec.template.spec.securityContext.sysctls // [] | map(.name + "=" + .value) | join(",")'
is "keepalive sysctls" "$(dy "$ka")" "net.ipv4.tcp_keepalive_intvl=5,net.ipv4.tcp_keepalive_probes=3"
is "no keepalive before 1.29" "$(render --kube-version 1.28.0 | yq "$dep" | yq "$ka")" ""
is "keepalive off" "$(render --set runtime.postgres.tcpKeepalive.enabled=false | yq "$dep" | yq "$ka")" ""
is "own sysctl kept" "$(render --set-json 'podSecurityContext.sysctls=[{"name":"net.ipv4.tcp_keepalive_probes","value":"4"}]' | yq "$dep" | yq "$ka")" "net.ipv4.tcp_keepalive_probes=4,net.ipv4.tcp_keepalive_intvl=5"
probes='[.spec.template.spec.containers[0] | (.startupProbe.httpGet.path, .livenessProbe.httpGet.path, .readinessProbe.httpGet.path)] | join(",")'
is "legacy probes" "$(dy "$probes")" "/health,/health,/health"
is "split probes" "$(render --set healthProbes=split | yq "$dep" | yq "$probes")" "/health/live,/health/live,/health/ready"
heap='.env[] | select(.name == "NODE_OPTIONS") | .value'
is "init heap" "$(dy "$pod.initContainers[0] | $heap")" "--max-old-space-size=768"
is "migrate heap" "$(jy ".spec.template.spec.containers[0] | $heap")" "--max-old-space-size=768"
is "heap from 1536Mi" "$(render --set resources.limits.memory=1536Mi | yq "$dep" | yq "$pod.initContainers[0] | $heap")" "--max-old-space-size=1152"
is "operator heap wins" "$(render --set-json 'extraEnv=[{"name":"NODE_OPTIONS","value":"--max-old-space-size=300"}]' | yq "$dep" | yq "[$pod.initContainers[0].env[] | select(.name == \"NODE_OPTIONS\")] | length")" 1
is "no heap without a limit" "$(render --set resources.limits=null | yq "$dep" | yq "[$pod.initContainers[0].env[] | select(.name == \"NODE_OPTIONS\")] | length")" 0
zone='.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0] | .key + "=" + .values[0]'
is "zone pin" "$(render --set-string persistence.zone=us-west-2a | yq "$dep" | yq "$zone")" "topology.kubernetes.io/zone=us-west-2a"
is "zone keeps podAntiAffinity" "$(render --set-string persistence.zone=us-west-2a --set-json 'affinity={"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[]}}' | yq "$dep" | yq '.spec.template.spec.affinity | has("podAntiAffinity")')" true
is "no zone, no affinity" "$(dy '.spec.template.spec | has("affinity")')" false
expect_refused "zone with nodeAffinity" "persistence.zone and affinity.nodeAffinity" --set-string persistence.zone=us-west-2a --set-json 'affinity={"nodeAffinity":{}}'

[ "$fail" = 0 ] && echo "relaycast postgres and analytics render: ok"
exit "$fail"
