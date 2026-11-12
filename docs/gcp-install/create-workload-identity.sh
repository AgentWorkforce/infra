#!/usr/bin/env bash
# Optional: create the resource-level Workload Identity grants described in
# 2-SERVICE-ACCOUNTS.md with gcloud. Use it only if you did not run the
# Terraform in 0-START-HERE.md step 4 (which creates the same grants).
#
#   PROJECT_ID=<project id> BUCKET=<sessions bucket> \
#   TOPIC=<pipeline topic> SUBSCRIPTION=<pipeline subscription> \
#   DEAD_LETTER_TOPIC=<dead-letter topic> \
#   [NAMESPACE=agent-relay] [MIRROR_REPO=<location>/<repository>] \
#   [NODE_SA=<node service account email>] \
#     bash create-workload-identity.sh
#
# Needs gcloud. Safe to rerun: adding an existing binding is a no-op. It never
# changes project-level IAM.
set -euo pipefail
: "${PROJECT_ID:?set PROJECT_ID}" "${BUCKET:?set BUCKET}" "${TOPIC:?set TOPIC}"
: "${SUBSCRIPTION:?set SUBSCRIPTION}" "${DEAD_LETTER_TOPIC:?set DEAD_LETTER_TOPIC}"
NS="${NAMESPACE:-agent-relay}"
NUM="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
POOL="principal://iam.googleapis.com/projects/$NUM/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/$NS/sa"
PUBSUB_AGENT="serviceAccount:service-$NUM@gcp-sa-pubsub.iam.gserviceaccount.com"
q() { "$@" --project "$PROJECT_ID" --quiet >/dev/null; }

for sa in agent-relay-worker agent-relay-session-ingest-api agent-relay-read-api \
          agent-relay-search-indexer agent-relay-alleyoop; do
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
    --member "$POOL/$sa" --role roles/storage.objectUser --quiet >/dev/null
  echo "bucket: $sa"
done
for sa in agent-relay-worker agent-relay-session-ingest-api; do
  q gcloud pubsub topics add-iam-policy-binding "$TOPIC" --member "$POOL/$sa" --role roles/pubsub.publisher
  echo "topic publisher: $sa"
done
for sa in agent-relay-worker agent-relay-search-indexer; do
  q gcloud pubsub subscriptions add-iam-policy-binding "$SUBSCRIPTION" --member "$POOL/$sa" --role roles/pubsub.subscriber
  echo "subscription subscriber: $sa"
done
q gcloud pubsub topics add-iam-policy-binding "$DEAD_LETTER_TOPIC" --member "$PUBSUB_AGENT" --role roles/pubsub.publisher
q gcloud pubsub subscriptions add-iam-policy-binding "$SUBSCRIPTION" --member "$PUBSUB_AGENT" --role roles/pubsub.subscriber
echo "dead-letter: Pub/Sub service agent"

if [ -n "${MIRROR_REPO:-}" ] && [ -n "${NODE_SA:-}" ]; then
  q gcloud artifacts repositories add-iam-policy-binding "${MIRROR_REPO#*/}" \
    --location "${MIRROR_REPO%%/*}" --member "serviceAccount:$NODE_SA" --role roles/artifactregistry.reader
  echo "mirror reader: $NODE_SA"
fi
echo "done: 11 grants (plus the mirror reader if requested)"
