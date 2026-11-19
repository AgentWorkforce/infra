#!/usr/bin/env bash
# For installs that bring their own Cloud SQL, bucket, Memorystore and Pub/Sub
# (1-BRING-YOUR-OWN.md): writes managed-values.json, the same non-secret
# overlay Terraform's chart_values output produces.
#
#   GCP_PROJECT_ID=<project id> REGION=<region> \
#   CLOUD_SQL_INSTANCE=<instance name> SESSIONS_BUCKET=<bucket> \
#   REDIS_INSTANCE=<memorystore instance> \
#   PUBSUB_TOPIC=<topic id> PUBSUB_SUBSCRIPTION=<subscription id> \
#     bash managed-values-byo.sh > managed-values.json
#
# Reads the instances with gcloud (no secrets). The Cloud SQL CA bundle is
# written exactly as cloud-sql-setup.sh writes it, so the caSha256 pins match.
# Needs gcloud, jq and sha256sum.
set -euo pipefail
: "${GCP_PROJECT_ID:?}" "${REGION:?}" "${CLOUD_SQL_INSTANCE:?}" "${SESSIONS_BUCKET:?}"
: "${REDIS_INSTANCE:?}" "${PUBSUB_TOPIC:?}" "${PUBSUB_SUBSCRIPTION:?}"
P="$GCP_PROJECT_ID"

ca="$(gcloud sql ssl server-ca-certs list --project "$P" --instance "$CLOUD_SQL_INSTANCE" --format=json --quiet | jq -er '.[].cert')"
ca_sha="$(printf '%s\n' "$ca" | sha256sum | cut -d' ' -f1)"
conn="$(gcloud sql instances describe "$CLOUD_SQL_INSTANCE" --project "$P" --format='value(connectionName)')"
redis="$(gcloud redis instances describe "$REDIS_INSTANCE" --region "$REGION" --project "$P" --format=json)"
[ "$(jq -r .transitEncryptionMode <<<"$redis")" = SERVER_AUTHENTICATION ] || { echo "Memorystore must use transit encryption SERVER_AUTHENTICATION" >&2; exit 1; }
[ "$(jq -r '.authEnabled // false' <<<"$redis")" = false ] || { echo "Memorystore AUTH must be off for this release" >&2; exit 1; }

jq -n --arg bucket "$SESSIONS_BUCKET" --arg region "$REGION" --arg conn "$conn" --arg sha "$ca_sha" \
  --arg topic "projects/$P/topics/${PUBSUB_TOPIC##*/}" --arg sub "projects/$P/subscriptions/${PUBSUB_SUBSCRIPTION##*/}" \
  --argjson redis "$redis" '
  def env: [
    {name:"CLOUD_SQL_CONNECTION_NAME", value:$conn},
    {name:"REDIS_HOST", value:$redis.host},
    {name:"REDIS_PORT", value:($redis.port|tostring)},
    {name:"REDIS_AUTH_ENABLED", value:"false"},
    {name:"REDIS_TRANSIT_ENCRYPTION", value:"SERVER_AUTHENTICATION"},
    {name:"REDIS_TLS_CA_PEM", value:$redis.serverCaCerts[0].cert},
    {name:"PUBSUB_TOPIC", value:$topic},
    {name:"PUBSUB_SUBSCRIPTION", value:$sub}];
  def ca: {enabled:true, configMap:"cloud-sql-ca", key:"ca.crt", sha256:$sha};
  def gcs: {provider:"gcs", bucket:$bucket, region:$region};
  {
    "relay-control": {postgresCa: {enabled:true, configMap:"cloud-sql-ca", key:"ca.crt"}},
    relaycast: {postgresCa: {enabled:true, configMap:"cloud-sql-ca", key:"ca.crt"}},
    "sessions-pipeline": {
      alleyoop: {extraEnv: env, postgresCa: ca},
      ingestEdge: {locker: gcs, postgres: {caConfigMap:"cloud-sql-ca", caKey:"ca.crt", caSha256:$sha}},
      searchIndexer: {extraEnv: env, locker: gcs,
        postgres: {tlsProfile:"custom-ca", caConfigMap:"cloud-sql-ca", caKey:"ca.crt", caSha256:$sha}},
      sessionReadApi: {
        extraEnv: [
          {name:"LOCKER_PROVIDER", value:"gcs"}, {name:"LOCKER_BUCKET", value:$bucket},
          {name:"LOCKER_REGION", value:$region}, {name:"PIPELINE_KEY_PREFIX", value:"96bulls"},
          {name:"PIPELINE_ORG_FROM_PREFIX", value:"true"}],
        postgres: {tlsProfile:"custom-ca"}, postgresCa: ca},
      worker: {extraEnv: env, locker: {bucket:$bucket, region:$region},
        migrations: {runtimeRole:"sessions_pipeline_runtime", runtimeRoleLogin:true}, postgresCa: ca}
    }
  }'
