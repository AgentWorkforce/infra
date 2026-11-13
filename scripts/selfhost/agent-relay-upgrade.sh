#!/usr/bin/env bash
# Install or upgrade a self-hosted Agent Relay install to a published release,
# pulled by the customer. Plan-only by default; nothing changes without --apply.
#
#   scripts/selfhost/agent-relay-upgrade.sh --version 2026.11.1 \
#     --registry <account>.dkr.ecr.<region>.amazonaws.com \
#     --profile eks-native --values <your values.yaml> [--values ...] \
#     [--db-instance <rds-instance-id>] [--context <kube-context>] \
#     [--namespace agent-relay] [--release agent-relay] [--prefix agent-relay] \
#     [--first-install] [--rds-setup] [--apply]
#   scripts/selfhost/agent-relay-upgrade.sh ... --profile eks-rds-native \
#     --relaycast-actors credentials|cutover [--actors-values <file>]... \
#     [--reregister-legacy] [--apply]
#
#   --profile P     the chart profile this install uses, so an upgrade never
#                   switches it. Required. One of:
#                     eks             values-eks.yaml (native History)
#                     eks-native      values-eks.yaml + values-eks-native.yaml
#                                     (an empty compatibility overlay: renders
#                                     the same as eks; kept for installs that
#                                     already name it)
#                     eks-rds-native  values-eks.yaml + values-eks-rds-native.yaml
#                                     (implies --rds-setup; needs a release
#                                     whose chart ships that file)
#   --first-install the release does not exist yet: run the documented first
#                   install (helm install, then the migration barrier) instead
#                   of helm upgrade. Refused when the release already exists;
#                   a plain upgrade is refused when it does not.
#   --relaycast-actors PHASE
#                   opt-in: move Relaycast from its PostgreSQL backend to
#                   durable-actors with every row and file
#                   (docs/relaycast-postgres-to-actors-migration.md), on the
#                   chart version already deployed, in two runs:
#                     credentials  switch Relaycast to ar_ credentials (the
#                                  keyring in relaycast.existingSecret) and
#                                  re-key what relay-control holds; online
#                     cutover      preflight, quiesce, export, helm upgrade with
#                                  values-eks-actors.yaml + --actors-values,
#                                  copy files, import and verify; messaging is
#                                  down meanwhile
#                   Both take the RDS snapshot first and refuse on any failed
#                   precondition (wrong backend or chart version, a component
#                   the actors values would remove, a control plane without an
#                   RDS CA bundle, missing files, legacy credentials).
#   --actors-values F  your overrides for values-eks-actors.yaml (cutover)
#   --reregister-legacy  cutover: accept that holders of never-upgraded legacy
#                   credentials re-register afterwards (their data still moves)
#   --rds-setup     this install's RDS databases are managed with
#                   scripts/selfhost/rds-setup.sh (next to this script). First
#                   install then runs "rds-setup.sh post" after the HoopDb
#                   migration and restarts the read API, ingest edge and search
#                   indexer; an upgrade runs "rds-setup.sh refresh-admin" and
#                   updates the agent-relay-secrets and search-indexer-owner
#                   Secrets from the rewritten files before helm upgrade.
#                   With --apply it needs AWS_REGION, RDS_HOST and
#                   RDS_ADMIN_SECRET_ARN in the environment, and STATE_DIR
#                   (default $HOME/.agent-relay-install) holding the files
#                   "rds-setup.sh pre" wrote.
#
# What it does:
#   1. Downloads release agent-relay-<version> from GitHub: the packaged chart
#      (dependencies included), release-manifest.json,
#      release-images.values.yaml and SHA256SUMS. It checks every checksum and
#      verifies the GitHub build attestations (gh attestation verify), bound to
#      the release workflow and the release tag.
#   2a. Upgrades only: a read-only census of the Sessions database (one pod
#      cloned from the deployed HoopDb migrate Job, deleted afterwards) decides
#      how the migration's adopt-or-create index steps run. Absent indexes on
#      populated tables with at most AGENT_RELAY_BLOCKING_INDEX_MAX_ROWS rows to
#      index (default 1000000) are built by the migration with a blocking
#      CREATE INDEX: this upgrade alone sets
#      sessions-pipeline.worker.migrations.allowBlockingIndexBuild, and the plan
#      prints the tables, rows and expected lock time. Above the limit, or with
#      an INVALID or drifted index, it refuses: prebuild CONCURRENTLY with the
#      packet it names, then re-run. Needs sessions-index-census.mjs next to
#      this script.
#   2. Renders the chart with your values plus the release image overlay and
#      checks that every image it would deploy is exactly a release image in
#      your mirror, then prints the image changes against what is running and
#      every rendered resource that differs from the deployed release. The
#      last plan line is "plan: changes=true" or "plan: changes=false".
#   3. Mirrors exactly the release's image digests into your ECR
#      (mirror-images-to-ecr.sh, next to this script).
#   With --apply, after you confirm:
#   4. Takes an RDS snapshot of --db-instance and waits for it.
#   5. Upgrade: [--rds-setup: refresh-admin], helm upgrade, then waits for this
#      release's migration Jobs and Deployments.
#      First install: helm install --no-hooks (no --wait), waits for the HoopDb
#      migrate Job, [--rds-setup: rds-setup.sh post and a restart of the read
#      API, ingest edge and search indexer], then waits for every Job in the
#      installed manifest (bounded; a failed Job fails with its logs) and the
#      Deployments.
#   On a failure it stops and prints the helm rollback command (the last
#   successfully deployed revision) and the snapshot id.
#
# Needs: gh, jq, yq, helm, kubectl, tar, sha256sum or shasum; with --apply
# also aws and crane (and openssl and curl with --rds-setup). Network:
# github.com, ghcr.io, your AWS account and your cluster. Credentials come
# from your normal AWS/kube/gh environment; this script takes none on its
# command line.
set -euo pipefail

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; }
die() { printf 'agent-relay-upgrade: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="${AGENT_RELAY_INFRA_REPO:-AgentWorkforce/infra}"
# The only workflow that signs release assets (.github/workflows/release-agent-relay.yml).
signer_workflow="$repo/.github/workflows/release-agent-relay.yml"
version="" registry="" profile="" db_instance="" context="" namespace="agent-relay" release="agent-relay"
prefix="agent-relay" apply=false assume_yes=false first_install=false rds_setup=false values=()
rta_phase="" rta_actor_values=() rta_reregister_legacy=false
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; version=$2; shift 2 ;;
    --registry) [ $# -ge 2 ] || die "--registry needs a value"; registry=$2; shift 2 ;;
    --profile) [ $# -ge 2 ] || die "--profile needs a value"; profile=$2; shift 2 ;;
    --values|-f) [ $# -ge 2 ] || die "$1 needs a value"; values+=("$2"); shift 2 ;;
    --db-instance) [ $# -ge 2 ] || die "--db-instance needs a value"; db_instance=$2; shift 2 ;;
    --context) [ $# -ge 2 ] || die "--context needs a value"; context=$2; shift 2 ;;
    --namespace) [ $# -ge 2 ] || die "--namespace needs a value"; namespace=$2; shift 2 ;;
    --release) [ $# -ge 2 ] || die "--release needs a value"; release=$2; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; prefix=$2; shift 2 ;;
    --first-install) first_install=true; shift ;;
    --rds-setup) rds_setup=true; shift ;;
    --relaycast-actors) [ $# -ge 2 ] || die "--relaycast-actors needs credentials or cutover"; rta_phase=$2; shift 2 ;;
    --actors-values) [ $# -ge 2 ] || die "--actors-values needs a value"; rta_actor_values+=("$2"); shift 2 ;;
    --reregister-legacy) rta_reregister_legacy=true; shift ;;
    --apply) apply=true; shift ;;
    --yes) assume_yes=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ "$version" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]] || die "--version must look like 2026.11.1"
[[ "$registry" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] || die "--registry must be an ECR registry host"
[[ "$release" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "--release must be a DNS-1123 label"
case "$profile" in
  eks) overlay_profile=eks; profile_files=(values-eks.yaml) ;;
  # values-eks.yaml is native on its own; values-eks-native.yaml is an empty
  # compatibility overlay, still layered so an install naming it never changes.
  eks-native) overlay_profile=eks; profile_files=(values-eks.yaml values-eks-native.yaml) ;;
  # values-eks-rds-native.yaml layers on values-eks.yaml in place of
  # values-eks-native.yaml; its databases are bootstrapped by rds-setup.sh.
  eks-rds-native) overlay_profile=eks; profile_files=(values-eks.yaml values-eks-rds-native.yaml); rds_setup=true ;;
  *) die "--profile must be eks, eks-native or eks-rds-native (the profile this install already uses)" ;;
esac
[ "${#values[@]}" -gt 0 ] || die "--values must point to your existing values file(s)"
case "$rta_phase" in
  "") [ "${#rta_actor_values[@]}" -eq 0 ] && ! $rta_reregister_legacy || die "--actors-values and --reregister-legacy need --relaycast-actors" ;;
  credentials|cutover)
    [ -f "$here/relaycast-to-actors.sh" ] || die "relaycast-to-actors.sh must sit next to this script"
    # shellcheck source=relaycast-to-actors.sh
    . "$here/relaycast-to-actors.sh"
    # Its state under STATE_DIR (and the work files) must stay owner-only:
    # the STATE_DIR guard above refuses anything wider on the next run.
    umask 077
    # A failure inside its functions must reach the ERR trap (rollback hint),
    # not end the run silently.
    set -o errtrace
    # shellcheck disable=SC2034  # read by relaycast-to-actors.sh
    rta_run="relaycast-actors-$(date -u +%Y%m%d%H%M%S)" rta_actor_files=() ;;
  *) die "--relaycast-actors must be credentials or cutover" ;;
esac
for v in "${values[@]}"; do [ -f "$v" ] || die "values file not found: $v"; done
if $apply && [ -z "$db_instance" ]; then die "--apply needs --db-instance so a snapshot is taken first"; fi
for tool in gh jq yq helm kubectl tar; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done
if $apply; then for tool in aws crane; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done; fi
[ -x "$here/mirror-images-to-ecr.sh" ] || die "mirror-images-to-ecr.sh must sit next to this script"
state_dir="${STATE_DIR:-${HOME:-}/.agent-relay-install}"
if $apply && $rds_setup; then
  [ -x "$here/rds-setup.sh" ] || die "rds-setup.sh must sit next to this script (--rds-setup)"
  for tool in openssl curl; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done
  for var in AWS_REGION RDS_HOST RDS_ADMIN_SECRET_ARN; do
    [ -n "${!var:-}" ] || die "--rds-setup needs $var in the environment (see rds-setup.sh)"
  done
  # STATE_DIR holds database passwords: refuse it if group or others can reach anything in it.
  [ -d "$state_dir" ] || die "STATE_DIR $state_dir does not exist: run 'rds-setup.sh pre' first (or set STATE_DIR)"
  open_perms=$(find "$state_dir" \( -perm -0001 -o -perm -0002 -o -perm -0004 -o -perm -0010 -o -perm -0020 -o -perm -0040 \) -print | head -3)
  [ -z "$open_perms" ] || die "STATE_DIR holds database passwords but is readable beyond its owner (want 0700 directories, 0600 files):
$open_perms"
  if $first_install; then
    for p in bulls96_read_api bulls96_session_ingest search_consumer_runtime; do
      [ -s "$state_dir/passwords/$p" ] || die "no rds-setup state under $state_dir: run 'rds-setup.sh pre' first (or set STATE_DIR)"
    done
  else
    for s in agent-relay-secrets search-indexer-owner; do
      [ -d "$state_dir/secret-files/$s" ] || die "no rds-setup credential files under $state_dir/secret-files: set STATE_DIR to the directory 'rds-setup.sh pre' used"
    done
  fi
fi
sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

kube=(kubectl -n "$namespace"); helmx=(helm -n "$namespace")
if [ -n "$context" ]; then kube+=(--context "$context"); helmx+=(--kube-context "$context"); fi
work=$(mktemp -d)
# The index census pod mounts the migration owner's database Secret: any exit
# (error, set -e, Ctrl-C, TERM) deletes it and its ConfigMap, idempotently.
census_name=""
index_census_cleanup() {
  [ -n "$census_name" ] || return 0
  "${kube[@]}" delete pod,configmap,secret "$census_name" --ignore-not-found --wait=true --timeout=30s >/dev/null 2>&1 || true
  census_name=""
}
trap 'index_census_cleanup; rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
tag="agent-relay-$version"; rel="$work/rel"
verify_attestation() {
  gh attestation verify "$1" --repo "$repo" --signer-workflow "$signer_workflow" \
    --source-ref "refs/tags/$tag" --deny-self-hosted-runners >/dev/null
}

# sessions_index_check: the Sessions adopt-or-create index steps (20261105044020,
# 044040, 047000, 058000). Each builds a missing index itself only on an empty
# table and refuses (SQLSTATE 55000) on a populated one, unless the migrate Job
# has HOOPDB_ALLOW_BLOCKING_INDEX_BUILD=true. That opt-in covers the whole
# migrate run, so the census covers every step the ledger has not recorded. A
# one-off pod cloned from the DEPLOYED migrate Job (same image, Secret, CA and
# ServiceAccount; no init containers) runs sessions-index-census.mjs in a READ
# ONLY transaction and is deleted afterwards. Then:
#   nothing absent on a populated table   -> nothing to set (adopt or build on empty)
#   rows to index <= index_max_rows       -> blocking build, this upgrade only
#   above it, or an INVALID/drifted index -> refuse: prebuild CONCURRENTLY, re-run
#   census unreadable                     -> refuse (fail closed)
index_max_rows="${AGENT_RELAY_BLOCKING_INDEX_MAX_ROWS:-1000000}"
# Rows per second one blocking CREATE INDEX builds, for the lock-time estimate
# (PostgreSQL 17 built 058000's indexes at about 1M rows/s on a 24-core host;
# the default assumes a 2-vCPU database is about 4x slower).
index_rows_per_second="${AGENT_RELAY_INDEX_BUILD_ROWS_PER_SECOND:-250000}"
census_timeout="${AGENT_RELAY_INDEX_CENSUS_TIMEOUT_SECONDS:-300}"
sessions_index_check() {
  local v job name pod_json phase deadline census decision n_build rows tables secs url_file=""
  [[ "$index_max_rows" =~ ^[0-9]+$ ]] || die "AGENT_RELAY_BLOCKING_INDEX_MAX_ROWS must be a whole number of rows"
  [[ "$index_rows_per_second" =~ ^[1-9][0-9]*$ ]] || die "AGENT_RELAY_INDEX_BUILD_ROWS_PER_SECOND must be a positive whole number"
  for v in "${values[@]}"; do
    case "$(yq -r '.["sessions-pipeline"].worker.migrations.allowBlockingIndexBuild // ""' "$v" 2>/dev/null || true)" in
      ""|false) ;;
      *) die "$v sets sessions-pipeline.worker.migrations.allowBlockingIndexBuild: remove it; this upgrader sets it for one upgrade from its index census" ;;
    esac
  done
  say "== 2a. Sessions index steps: read-only census of the HoopDb database"
  job=$("${helmx[@]}" get manifest "$release" \
    | yq -o=json -I=0 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate")') \
    || die "could not read the deployed manifest of $release"
  if [ -z "$job" ]; then
    say "   the deployed release has no HoopDb migrate Job to clone: no census"
    index_census_skipped=true; return 0
  fi
  [[ "$job" != *$'\n'* ]] || die "the deployed release has more than one HoopDb migrate Job"
  jq -e '.spec.template.spec.containers[0].image | strings' <<<"$job" >/dev/null \
    || die "the deployed HoopDb migrate Job has no container to clone for the index census"
  [ -f "$here/sessions-index-census.mjs" ] || die "sessions-index-census.mjs must sit next to this script"
  # RDS rotates the admin password that the migration owner URL carries. With
  # --rds-setup and its inputs, refresh it first (rds-setup.sh refresh-admin
  # reads Secrets Manager and rewrites only STATE_DIR files) and give the census
  # that URL through a temporary Secret, so a rotation never blocks the plan.
  if $rds_setup && [ -n "${AWS_REGION:-}" ] && [ -n "${RDS_HOST:-}" ] && [ -n "${RDS_ADMIN_SECRET_ARN:-}" ] \
    && [ -d "$state_dir/secret-files/agent-relay-secrets" ] \
    && jq -e '[.spec.template.spec.containers[0].env[]? | select(.name == "HOOPDB_URL") | .valueFrom.secretKeyRef
        | select(.name == "agent-relay-secrets" and .key == "HOOPDB_MIGRATION_URL")] | length == 1' <<<"$job" >/dev/null; then
    say "   refreshing the RDS admin credential (rds-setup.sh refresh-admin) for the census"
    env NAMESPACE="$namespace" KUBE_CONTEXT="$context" STATE_DIR="$state_dir" "$here/rds-setup.sh" refresh-admin >/dev/null \
      || die "rds-setup.sh refresh-admin failed, so the census has no current database credential; nothing was changed"
    url_file="$state_dir/secret-files/agent-relay-secrets/HOOPDB_MIGRATION_URL"
    [ -s "$url_file" ] || die "rds-setup.sh refresh-admin did not write agent-relay-secrets/HOOPDB_MIGRATION_URL; nothing was changed"
  fi
  name="$release-index-census-$(date -u +%Y%m%d%H%M%S)"
  say "   one read-only pod, $name, cloned from the deployed migrate Job; deleted afterwards"
  # From here any exit deletes the pod and ConfigMap (the EXIT trap).
  census_name=$name
  "${kube[@]}" create configmap "$name" --from-file=sessions-index-census.mjs="$here/sessions-index-census.mjs" \
    --dry-run=client -o yaml | "${kube[@]}" apply -f - >/dev/null || die "could not create the index census ConfigMap"
  if [ -n "$url_file" ]; then
    # The value goes from the 0600 state file into the Secret; never argv or logs.
    "${kube[@]}" create secret generic "$name" --from-file=HOOPDB_URL="$url_file" \
      --dry-run=client -o yaml | "${kube[@]}" apply -f - >/dev/null || die "could not create the index census credential Secret"
  fi
  pod_json=$(jq --arg name "$name" --arg ns "$namespace" --arg limit "$index_max_rows" --argjson deadline "$census_timeout" \
      --argjson fresh "$([ -n "$url_file" ] && echo true || echo false)" '
    .spec.template as $t
    | { apiVersion: "v1", kind: "Pod",
        metadata: { name: $name, namespace: $ns,
          labels: (($t.metadata.labels // {}) + { "agent-relay.dev/index-census": "true" }) },
        spec: ($t.spec
          | del(.initContainers)
          | .restartPolicy = "Never"
          | .activeDeadlineSeconds = $deadline
          | .volumes = ((.volumes // []) + [{ name: "index-census", configMap: { name: $name } }])
          | .containers = [ .containers[0]
              | .name = "census"
              | .command = ["bun", "/index-census/sessions-index-census.mjs"]
              | del(.args, .livenessProbe, .readinessProbe, .startupProbe, .ports)
              | .env = ([(.env // [])[] | select(.name != "INDEX_CENSUS_LIMIT")
                  | if $fresh and .name == "HOOPDB_URL" then { name: "HOOPDB_URL", valueFrom: { secretKeyRef: { name: $name, key: "HOOPDB_URL" } } } else . end]
                  + [{ name: "INDEX_CENSUS_LIMIT", value: $limit }])
              | .volumeMounts = ((.volumeMounts // []) + [{ name: "index-census", mountPath: "/index-census", readOnly: true }]) ]) }' <<<"$job")
  if ! "${kube[@]}" apply -f - <<<"$pod_json" >/dev/null; then index_census_cleanup; die "could not start the index census pod"; fi
  deadline=$(( $(date +%s) + census_timeout + 60 ))
  while :; do
    phase=$("${kube[@]}" get pod "$name" -o json 2>/dev/null | jq -r '.status.phase // "Pending"' || echo Pending)
    case "$phase" in Succeeded|Failed) break ;; esac
    if [ "$(date +%s)" -ge "$deadline" ]; then phase=timeout; break; fi
    sleep "${AGENT_RELAY_JOB_POLL_SECONDS:-5}"
  done
  census=$("${kube[@]}" logs "pod/$name" -c census 2>/dev/null | grep -E '^INDEX_CENSUS(_ERROR)? ' | tail -1 || true)
  index_census_cleanup
  case "$census" in
    "INDEX_CENSUS "*) census=${census#INDEX_CENSUS } ;;
    "INDEX_CENSUS_ERROR 28P01 "*) die "the index census could not log in to the Sessions database (${census#INDEX_CENSUS_ERROR }); nothing was changed. If the RDS admin password rotated, refresh the admin inputs first (rds-setup.sh refresh-admin, then update the agent-relay-secrets Secret, or pass --rds-setup with its environment so this upgrader does it), then re-run" ;;
    "INDEX_CENSUS_ERROR "*) die "the index census failed (${census#INDEX_CENSUS_ERROR }); nothing was changed. Fix that and re-run" ;;
    *) die "the index census pod ended $phase without a result; nothing was changed (kubectl -n $namespace describe pod $name, before it is gone)" ;;
  esac
  decision=$(jq -c '
    [.steps[] | select(.applied | not) as $s | .indexes[] | . + { step: $s.step, packet: $s.packet }] as $ix
    | { pending: [.steps[] | select(.applied | not) | .step | sub("^upstream:"; "")],
        refused: [$ix[] | select(.state == "mismatch" or .state == "not_ready")],
        build: [$ix[] | select(.state == "absent" and .table_exists and ((.rows // 0) > 0))],
        empty: [$ix[] | select(.state == "absent" and ((.table_exists | not) or ((.rows // 0) == 0)))],
        adopted: [$ix[] | select(.state == "adoptable")],
        counts: [$ix[] | select(.state == "absent" and .table_exists) | .rows] }
    | .rows = ([.build[].rows] | add // 0)
    | .packets = ([.build[], .refused[] | .packet] | unique)' <<<"$census") \
    || die "the index census result could not be read; nothing was changed"
  if [ "$(jq '.pending | length' <<<"$decision")" -eq 0 ]; then
    say "   every adopt-or-create index step is already applied: nothing to build"; return 0
  fi
  say "   pending steps: $(jq -r '.pending | join(", ")' <<<"$decision")"
  say "   $(jq -r '"\(.adopted | length) index(es) prebuilt and adopted, \(.empty | length) built on empty tables, \(.build | length) absent on populated tables"' <<<"$decision")"
  jq -r '.build[] | "     sessions.\(.name) on \(.table): \(.rows) rows\(if .exact then "" else " (at least; estimate \(.estimate))" end)"' <<<"$decision"
  # Rows to index count a table once per absent index: each build scans it again.
  jq -r '.build | group_by(.table)[] | select(length > 1)
    | "     \(.[0].table) gets \(length) indexes: \(length) x \(.[0].rows) = \(length * .[0].rows) rows to index"' <<<"$decision"
  if [ "$(jq '.refused | length' <<<"$decision")" -gt 0 ]; then
    jq -r '.refused[] | "     sessions.\(.name) on \(.table): \(if .state == "not_ready" then "INVALID or still building (check pg_stat_progress_create_index before any DROP INDEX CONCURRENTLY)" else "exists but is not the declared index; reconcile it by hand" end)"' <<<"$decision"
    die "refusing: an index the Sessions migration would adopt is not usable (above). Follow \"Failed or cancelled builds\" in the packet ($(jq -r '.packets | join("; ")' <<<"$decision"), Sessions repository), then re-run. Nothing was changed."
  fi
  n_build=$(jq '.build | length' <<<"$decision"); rows=$(jq '.rows' <<<"$decision")
  # Every count must be a whole number of rows (fail closed on anything else).
  jq -e '.counts | all(type == "number" and . >= 0 and . == floor and . < 1e15)' <<<"$decision" >/dev/null \
    && [[ "$rows" =~ ^[0-9]+$ ]] \
    || die "the index census returned a row count that is not a whole number ($(jq -c '.counts' <<<"$decision")); nothing was changed"
  if [ "$n_build" -eq 0 ]; then
    say "   path: no blocking build; the migration adopts or builds every index itself"; return 0
  fi
  if [ "$rows" -gt "$index_max_rows" ]; then
    die "refusing: $n_build index(es) are absent on populated tables with $rows rows to index, above the blocking-build limit of $index_max_rows rows (AGENT_RELAY_BLOCKING_INDEX_MAX_ROWS). Prebuild them with CREATE INDEX CONCURRENTLY first, following $(jq -r '.packets | join("; ")' <<<"$decision") in the Sessions repository, then re-run: the migration adopts each prebuilt index without locking its table. Nothing was changed."
  fi
  tables=$(jq -r '[.build[].table] | unique | join(", ")' <<<"$decision")
  secs=$(( (rows + index_rows_per_second - 1) / index_rows_per_second )); [ "$secs" -ge 1 ] || secs=1
  say "   path: blocking build for this upgrade. $rows rows to index is within the limit of $index_max_rows,"
  say "         so this upgrade's migrate Job gets HOOPDB_ALLOW_BLOCKING_INDEX_BUILD=true (the next upgrade drops it)."
  say "         Expected lock: about ${secs}s of SHARE lock on $tables during the migration: reads continue, writes to those tables wait."
  printf 'sessions-pipeline:\n  worker:\n    migrations:\n      allowBlockingIndexBuild: true\n' > "$work/blocking-index.values.yaml"
  index_values=(-f "$work/blocking-index.values.yaml")
}

say "== 1. Download and verify release $tag"
gh release download "$tag" -R "$repo" -D "$rel" \
  -p release-manifest.json -p release-images.values.yaml -p SHA256SUMS -p '*.tgz' >/dev/null \
  || die "could not download release $tag from $repo"
verify_attestation "$rel/SHA256SUMS" || die "attestation verification failed for SHA256SUMS"
manifest="$rel/release-manifest.json"
chart_version=$(jq -r '.chart.version // empty' "$manifest" 2>/dev/null || true)
[[ "$chart_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || die "manifest chart version invalid"
package="agent-relay-${chart_version}.tgz"
for f in release-manifest.json release-images.values.yaml "$package"; do
  [ -f "$rel/$f" ] || die "release is missing $f"
  want=$(awk -v f="$f" '{n=$2; sub(/^\*/,"",n)} n==f {print $1; exit}' "$rel/SHA256SUMS")
  [ -n "$want" ] || die "$f is not covered by SHA256SUMS"
  [ "$(sha256_of "$rel/$f")" = "$want" ] || die "checksum mismatch for $f"
done
for f in release-manifest.json release-images.values.yaml; do
  verify_attestation "$rel/$f" || die "attestation verification failed for $f"
done
[ "$(jq -r .schema "$manifest")" = 1 ] || die "unsupported manifest schema"
[ "$(jq -r .version "$manifest")" = "$version" ] || die "manifest version does not match $version"
[ "$(jq -r '.valuesOverlayProfile // empty' "$manifest")" = "$overlay_profile" ] \
  || die "release image overlay is not for the selected profile"
commit=$(jq -r .infraCommit "$manifest"); [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "manifest infraCommit invalid"
jq -e '.images|length>0 and all(.[]; (.ref|test("^[a-z0-9.-]+/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$")))' "$manifest" >/dev/null \
  || die "manifest images must all be pinned by digest"
mkdir "$work/chart"; tar -xzf "$rel/$package" -C "$work/chart"
chart="$work/chart/agent-relay"
[ -f "$chart/Chart.yaml" ] || die "release chart package has no agent-relay chart"
[ "$(yq -r .version "$chart/Chart.yaml")" = "$chart_version" ] || die "packaged chart version does not match the release ($chart_version)"
for f in "${profile_files[@]}"; do
  [ -f "$chart/$f" ] || die "release $version (chart $chart_version) does not ship $f, so it cannot serve --profile $profile; choose a release that includes it"
done
say "   verified: version $version, infra $commit, chart $chart_version, $(jq '.images|length' "$manifest") images"

say "== 2. Render and check images"
release_selector="app.kubernetes.io/instance=$release"
releases=$("${helmx[@]}" list --all --filter "^${release}\$" -o json) \
  || die "could not list Helm releases in $namespace, so whether $release exists is unknown"
existing=$(jq -r --arg r "$release" '[.[]? | select(.name == $r) | .status] | first // empty' <<<"${releases:-[]}")
if $first_install && [ -n "$existing" ]; then
  die "release $release already exists in $namespace (status $existing); --first-install is only for a new install"
fi
if ! $first_install && [ -z "$existing" ]; then
  die "release $release does not exist in $namespace; use --first-install for a new install"
fi
# Sessions adopt-or-create index steps (plain upgrades only). Decides, from a
# read-only census, whether this upgrade's HoopDb migrate Job may build missing
# indexes with a blocking CREATE INDEX (worker.migrations.allowBlockingIndexBuild,
# set for this upgrade only) or must wait for a CONCURRENTLY prebuild.
index_values=() index_census_skipped=false
if ! $first_install && [ -z "$rta_phase" ]; then sessions_index_check; fi
overlay="$work/release-images.values.yaml"
# Overlay repositories are __IMAGE_MIRROR_ROOT__/<source host>/<source path>, exactly where
# mirror-images-to-ecr.sh copies each image.
sed "s#__IMAGE_MIRROR_ROOT__#${registry}/${prefix}#g" "$rel/release-images.values.yaml" > "$overlay"
if grep -q '__IMAGE_' "$overlay"; then die "overlay still has an unreplaced placeholder"; fi
base=()
for f in "${profile_files[@]}"; do base+=(-f "$chart/$f"); done
for v in "${values[@]}"; do base+=(-f "$v"); done
base+=(-f "$overlay")
# Last, so the census decision wins: present only on the blocking path.
base+=(${index_values[@]+"${index_values[@]}"})
render=(helm template "$release" "$chart" -n "$namespace")
if ! $first_install; then render+=(--is-upgrade); fi
# Render with the cluster's real capabilities, as helm install/upgrade will:
# templates gated on .Capabilities.KubeVersion or .Capabilities.APIVersions
# (podFailurePolicy, VPA, PDB) would otherwise differ from the deployed release.
server_version=$("${kube[@]}" version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty' || true)
[[ "$server_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "could not read the cluster's Kubernetes version (kubectl version)"
api_versions=$("${kube[@]}" api-versions) || die "could not list the cluster's API versions (kubectl api-versions)"
render+=(--kube-version "$server_version")
while IFS= read -r av; do [ -z "$av" ] || render+=(--api-versions "$av"); done <<<"$api_versions"
"${render[@]}" "${base[@]}" > "$work/new.yaml"
yq -N -r '.. | select(tag == "!!map") | select(has("image") or has("imageName")) | (.image // .imageName) | select(tag == "!!str")' \
  "$work/new.yaml" | sort -u > "$work/new-images.txt"
jq -r --arg root "${registry}/${prefix}" '.images[].ref | "\($root)/\(.)"' "$manifest" | sort -u > "$work/expected-images.txt"
unexpected=$(comm -23 "$work/new-images.txt" "$work/expected-images.txt")
[ -z "$unexpected" ] || die "the render would deploy images that are not this release's mirrored images:
$unexpected"
[ -s "$work/new-images.txt" ] || die "the render contains no images"
if $index_census_skipped && [ -n "$(yq -N -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .metadata.name' "$work/new.yaml")" ]; then
  say "   NOTE: this upgrade adds a HoopDb migrate Job that the deployed release did not have, so no index census ran."
  say "         If the Sessions database is populated, that Job refuses (read-only, before any write) any index it"
  say "         would have to build on a populated table; prebuild those CONCURRENTLY with the packet it names, then re-run."
fi
if ! $rds_setup; then
  db_mode=""
  for f in "${profile_files[@]/#/$chart/}" "${values[@]}"; do
    m=$(yq -r '.["sessions-pipeline"].worker.migrations.databaseMode // ""' "$f" 2>/dev/null || true)
    [ -z "$m" ] || db_mode=$m
  done
  if [ "$db_mode" = rds ]; then
    say "   NOTE: these values select databaseMode rds. If the databases were bootstrapped with"
    say "         rds-setup.sh, add --rds-setup (post on first install, refresh-admin on upgrade)."
  fi
fi
"${kube[@]}" get deploy,statefulset,job,cronjob -l "$release_selector" -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.jobTemplate.spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | sort -u > "$work/live-images.txt" || true
say "   images added (+) / removed (-) against what is running:"
changes=$(diff "$work/live-images.txt" "$work/new-images.txt" | grep -E '^[<>]' | sed 's/^</   -/;s/^>/   +/' || true)
if [ -n "$changes" ]; then say "$changes"; else say "   (no image changes)"; fi
current_rev=$("${helmx[@]}" history "$release" -o json 2>/dev/null | jq -r '[.[]|select(.status=="deployed")]|last.revision // empty' || true)

# One line per rendered resource: "<kind>/<namespace>/<name><TAB><canonical JSON>".
normalize() {
  yq -o=json -I=0 'sort_keys(..)' "$1" \
    | jq -r 'select(type == "object" and .kind != null) | "\(.kind)/\(.metadata.namespace // "")/\(.metadata.name)\t\(tojson)"' \
    | LC_ALL=C sort
}
if $first_install; then
  say "   first install: every rendered resource is new"
  plan_changes=true
else
  { "${helmx[@]}" get manifest "$release"; printf '\n---\n'; "${helmx[@]}" get hooks "$release"; } > "$work/live.yaml" \
    || die "could not read the deployed manifest of $release"
  normalize "$work/live.yaml" > "$work/live.tsv"; normalize "$work/new.yaml" > "$work/new.tsv"
  cut -f1 "$work/live.tsv" > "$work/live.keys"; cut -f1 "$work/new.tsv" > "$work/new.keys"
  LC_ALL=C comm -3 "$work/live.tsv" "$work/new.tsv" | awk -F'\t' '{print ($1 == "" ? $2 : $1)}' \
    | LC_ALL=C sort -u > "$work/diff.keys"
  say "   rendered resources changed (~) / added (+) / removed (-) against the deployed release:"
  if [ -s "$work/diff.keys" ]; then
    awk 'FILENAME == ARGV[1] {l[$0] = 1; next} FILENAME == ARGV[2] {n[$0] = 1; next}
         {print (($0 in l) && ($0 in n) ? "   ~ " : ($0 in n) ? "   + " : "   - ") $0}' \
      "$work/live.keys" "$work/new.keys" "$work/diff.keys"
    plan_changes=true
  else
    say "   (no manifest changes)"
    plan_changes=false
  fi
fi
say "plan: changes=$plan_changes"
if [ -n "$rta_phase" ]; then
  say "== 2b. Relaycast to durable-actors ($rta_phase): preconditions"
  rta_check
  if [ "$rta_phase" = cutover ]; then rta_check_cutover; fi
  say "   preconditions hold (Relaycast on PostgreSQL in $release, chart $chart_version)"
fi

say "== 3. Mirror release images into $registry"
jq -r '.images[].ref | "---\nimage: \(.)"' "$manifest" > "$work/release-images.rendered.yaml"
mirror=("$here/mirror-images-to-ecr.sh" --registry "$registry" --prefix "$prefix" \
  --rendered "$work/release-images.rendered.yaml" --out "$work/mirror.tsv")
if $apply; then "${mirror[@]}" --apply; else "${mirror[@]}"; fi

if ! $apply; then
  say ""; say "Plan only. Re-run with --apply --db-instance <id> to snapshot and $($first_install && echo install || echo upgrade)."
  exit 0
fi
if [ -n "$rta_phase" ]; then action="Run the Relaycast durable-actors $rta_phase phase on"
elif $first_install; then action="Install new release"; else action="Upgrade release"; fi
if ! $assume_yes; then
  printf '%s %s in %s to %s? Type the version to continue: ' "$action" "$release" "$namespace" "$version"
  read -r answer; [ "$answer" = "$version" ] || die "not confirmed; nothing changed"
fi
if $rds_setup && ! $first_install; then
  "${kube[@]}" get secret agent-relay-secrets search-indexer-owner -o name >/dev/null \
    || die "--rds-setup upgrade needs the agent-relay-secrets and search-indexer-owner Secrets in $namespace; nothing changed"
fi

say "== 4. RDS snapshot of $db_instance"
snapshot="agent-relay-pre-${version//./-}-$(date -u +%Y%m%d%H%M%S)"
aws rds create-db-snapshot --db-instance-identifier "$db_instance" --db-snapshot-identifier "$snapshot" >/dev/null
aws rds wait db-snapshot-available --db-snapshot-identifier "$snapshot"
say "   snapshot $snapshot is available"

rollback_hint() {
  say ""; say "$($first_install && echo INSTALL || echo UPGRADE) FAILED. Nothing further was changed."
  if [ -n "$current_rev" ]; then
    say "   roll back the release:  helm -n $namespace ${context:+--kube-context $context }rollback $release $current_rev"
  elif $first_install; then
    say "   the new release has no earlier revision; inspect its Jobs and Pods before retrying"
  fi
  say "   database snapshot:      $snapshot (restore only if a migration damaged data)"
  if [ -n "$rta_phase" ]; then rta_rollback_hint; fi
  exit 1
}
trap 'rollback_hint' ERR
# A Relaycast migration refusal after the snapshot also prints the rollback
# for the phase it reached.
if [ -n "$rta_phase" ]; then die() { printf 'agent-relay-upgrade: %s\n' "$*" >&2; rollback_hint; }; fi

# rds-setup.sh reads its inputs from the environment (never argv).
rds_env=(env NAMESPACE="$namespace" KUBE_CONTEXT="$context" STATE_DIR="$state_dir")
# wait_jobs NAME...: poll each Job until it completes; a Job that fails (its
# Failed condition) or is still unfinished at the deadline fails the run with
# its name and the last lines of its logs. Jobs confirmed complete are
# remembered and skipped later, because ttlSecondsAfterFinished may delete a
# finished Job (a NotFound after it was seen complete counts as complete). A
# Job that is NotFound from the start is waited for until the deadline; one
# that disappears before its outcome was seen fails at once.
job_timeout="${AGENT_RELAY_JOB_TIMEOUT_SECONDS:-1200}" job_poll="${AGENT_RELAY_JOB_POLL_SECONDS:-10}"
completed_jobs=" "
wait_jobs() {
  local job state deadline seen json
  deadline=$(( $(date +%s) + job_timeout ))
  for job in "$@"; do
    case "$completed_jobs" in *" $job "*) say "   Job $job already completed"; continue ;; esac
    seen=false
    while :; do
      if json=$("${kube[@]}" get job "$job" -o json 2>"$work/job.err"); then
        seen=true
        state=$(jq -r '
          if ((.status.succeeded // 0) > 0) or any(.status.conditions[]?; .type == "Complete" and .status == "True") then "complete"
          elif any(.status.conditions[]?; .type == "Failed" and .status == "True") then "failed"
          else "running" end' <<<"$json") || state=running
      elif grep -q NotFound "$work/job.err"; then
        if $seen; then state="removed before its outcome was seen"; break; fi
        state=missing
      else
        state=running  # a transient API error retries until the deadline
      fi
      [ "$state" = running ] || [ "$state" = missing ] || break
      if [ "$(date +%s)" -ge "$deadline" ]; then
        if [ "$state" = missing ]; then state="timeout; the Job was never found"; else state=timeout; fi
        break
      fi
      sleep "$job_poll"
    done
    if [ "$state" != complete ]; then
      say "   Job $job did not complete ($state); last logs:"
      "${kube[@]}" logs "job/$job" --all-containers --tail=50 2>&1 | sed 's/^/     /' || true
      return 1
    fi
    completed_jobs="$completed_jobs$job "
    say "   Job $job completed"
  done
}
mirrored_ref() { jq -r --arg n "$1" --arg root "${registry}/${prefix}" '[.images[] | select(.name == $n) | "\($root)/\(.ref)"] | first // empty' "$manifest"; }

if [ -n "$rta_phase" ]; then
  if [ "$rta_phase" = credentials ]; then rta_credentials; else rta_cutover; fi
elif $first_install; then
  say "== 5. helm install $release at $version"
  "${helmx[@]}" install "$release" "$chart" "${base[@]}" --create-namespace --no-hooks --timeout 20m
  migration_job=$("${helmx[@]}" get manifest "$release" \
    | yq -N -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .metadata.name')
  if [ -n "$migration_job" ]; then
    [[ "$migration_job" != *$'\n'* ]] || { say "   expected exactly one current HoopDb migrate Job"; false; }
    say "   waiting for HoopDb migrate Job $migration_job"
    wait_jobs "$migration_job"
  elif $rds_setup; then
    say "   the release renders no HoopDb migrate Job, so rds-setup.sh post has no migration evidence"; false
  fi
  if $rds_setup; then
    say "== 6. rds-setup.sh post, then restart the read API, ingest edge and search indexer"
    services_image=$(mirrored_ref sessions-pipeline)
    [ -n "$services_image" ] || { say "   the release manifest has no sessions-pipeline image"; false; }
    psql_image=$(mirrored_ref sessions-migration-postgresql)
    rds_env+=(RELEASE="$release" MIGRATION_JOB="$migration_job" SERVICES_IMAGE="$services_image")
    if [ -n "$psql_image" ]; then rds_env+=(PSQL_IMAGE="$psql_image"); fi
    "${rds_env[@]}" "$here/rds-setup.sh" post
    "${kube[@]}" rollout restart "deployment/$release-read-api" "deployment/$release-ingest-edge" \
      "deployment/$release-search-indexer"
  fi
  # --no-hooks and no --wait: nothing has waited for the release's other Jobs
  # (bootstraps, other migrations). Every Job in the installed manifest must
  # complete before the install is reported.
  job_names=$("${helmx[@]}" get manifest "$release" | yq -N -r 'select(.kind == "Job") | .metadata.name')
  release_jobs=()
  while IFS= read -r j; do [ -z "$j" ] || release_jobs+=("$j"); done <<<"$job_names"
  if [ "${#release_jobs[@]}" -gt 0 ]; then
    say "   waiting for every Job in the release: ${release_jobs[*]}"
    wait_jobs "${release_jobs[@]}"
  fi
else
  if $rds_setup; then
    say "== 5. rds-setup.sh refresh-admin, then update the admin-derived Secret keys"
    "${rds_env[@]}" "$here/rds-setup.sh" refresh-admin
    for pair in agent-relay-secrets:HOOPDB_MIGRATION_URL search-indexer-owner:RELAYHISTORY_PIPELINE_CONSUMER_SECRET; do
      s=${pair%%:*}; k=${pair#*:}; src="$state_dir/secret-files/$s/$k"
      [ -s "$src" ] || { say "   refresh-admin did not write $s/$k"; false; }
      # A merge patch replaces only this key; the value goes through a 0600 file, never argv.
      ( umask 077; printf '{"data":{"%s":"%s"}}' "$k" "$(base64 < "$src" | tr -d '\n')" > "$work/patch.json" )
      "${kube[@]}" patch secret "$s" --type merge --patch-file "$work/patch.json" >/dev/null
      rm -f "$work/patch.json"
      say "   updated Secret $s key $k"
    done
  fi
  say "== $($rds_setup && echo 6 || echo 5). helm upgrade $release to $version"
  "${helmx[@]}" upgrade "$release" "$chart" "${base[@]}" --wait --wait-for-jobs --timeout 15m
fi
"${kube[@]}" get deploy -l "$release_selector" -o name | while read -r d; do "${kube[@]}" rollout status "$d" --timeout 20m; done
failed=$("${kube[@]}" get jobs -l "$release_selector" -o json | jq -r '[.items[]|select((.status.failed // 0) > 0 and (.status.succeeded // 0) == 0)|.metadata.name]|join(",")')
[ -z "$failed" ] || { say "   failed Jobs: $failed"; false; }
trap - ERR
if [ -n "$rta_phase" ]; then
  say ""; say "Relaycast durable-actors $rta_phase phase done in $release (chart $chart_version). Snapshot kept: $snapshot"
elif $first_install; then
  say ""; say "Installed $release at $version (infra $commit, chart $chart_version). Snapshot kept: $snapshot"
else
  say ""; say "Upgraded $release to $version (infra $commit, chart $chart_version). Snapshot kept: $snapshot"
fi
