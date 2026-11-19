#!/usr/bin/env bash
# Plan, apply or roll back an environment's Helm releases from CI. Runs inside the CodeBuild jobs of
# terraform/modules/aws/ci-deploy (see docs/selfhost-ci-deploy.md), from an unpacked deploy bundle:
#
#   <bundle>/infra/   this repository at the environment's pinned ref (charts, this script)
#   <bundle>/env/     the environment: deploy.json, values files, allow-drop.txt, replace-orphans.txt, plan-rbac.yaml
#
#   ci-deploy.sh plan     <bundle>   diff every release against what is live; refuse an unlisted drop
#   ci-deploy.sh apply    <bundle>   the same checks, then snapshot, upgrade, job and health checks
#   ci-deploy.sh rollback <bundle>   helm rollback ROLLBACK_RELEASE to ROLLBACK_REVISION, then health checks
#
# Environment: REPORT_DIR (reports, uploaded by the job), RUN_ID. apply: EXPECT_REVISIONS
# ("release=revision ..." from the reviewed plan; the apply refuses if anything was upgraded since).
# apply with no changes does nothing unless FORCE_UPGRADE=1. Secret values are never printed.
set -euo pipefail

MODE=${1:?usage: ci-deploy.sh plan|apply|rollback <bundle>}
B=$(cd "${2:?bundle dir}" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
CFG="$B/env/deploy.json"
REPORT_DIR=${REPORT_DIR:-$B/report}
RUN_ID=${RUN_ID:-local}
mkdir -p "$REPORT_DIR"
# Live release state (values, manifests with Secrets) and dry-run renders stay here, never in the report.
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
log(){ printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$REPORT_DIR/log.txt" >&2; }
die(){ log "ERROR: $*"; exit 1; }

[ -f "$CFG" ] || die "missing env/deploy.json"
jq -e '.releases | length > 0' "$CFG" >/dev/null || die "deploy.json: no releases"
case "$MODE" in plan|apply|rollback) ;; *) die "unknown mode $MODE" ;; esac

# Paths in deploy.json are relative to the bundle root and must stay inside it.
inside(){ local p; p=$(realpath -m "$B/$1"); [[ "$p" == "$B/"* ]] || die "path escapes the bundle: $1"; printf '%s' "$p"; }
# Checked here, in the main shell: inside() also runs in subshells, where die cannot stop the script.
while IFS= read -r p; do inside "$p" >/dev/null; done < <(jq -r '.releases[] | .chart, .values[]' "$CFG")
[ -z "$(jq -r '.releases[] | select(.chart == null or .namespace == null or .values == null) | .name' "$CFG")" ] ||
  die "deploy.json: every release needs name, namespace, chart and values"

releases(){ jq -r '.releases[].name' "$CFG"; }
# orphans <release>: the "<namespace>/<name>" Jobs replace-orphans.txt lists for this release. A listed Job exists
# without Helm ownership (made outside Helm) under a name the release now renders; the apply deletes it, only if
# it is still unowned and finished, so the upgrade re-creates it. Lines: job <release> <ns>/<name>  # why, who
orphans(){ local f="$B/env/replace-orphans.txt"; [ -f "$f" ] || return 0; sed 's/#.*//' "$f" | awk -v r="$1" '$1 == "job" && $2 == r { print $3 }'; }

replace_orphans(){ # <release> <namespace>: delete the orphan Jobs the plan reported for this release
  local r=$1 key ns name job="$WORK/orphan-job.json" f="$REPORT_DIR/orphans-$r.txt"
  [ -s "$f" ] || return 0
  while IFS= read -r key; do
    ns=${key%%/*}; name=${key#*/}
    kubectl get job "$name" -n "$ns" -o json --ignore-not-found > "$job" || return 1
    [ -s "$job" ] || { log "orphan $key: already gone"; continue; }
    jq -e --arg r "$r" '(.metadata.annotations["meta.helm.sh/release-name"] // "") != $r
      and ((.status.conditions // []) | any(.type == "Complete" and .status == "True"))' "$job" >/dev/null ||
      { log "orphan $key is now owned or unfinished; refusing to delete it"; return 1; }
    kubectl delete job "$name" -n "$ns" --wait=true >/dev/null || return 1
    log "orphan $key deleted (the upgrade re-creates it)"
  done < "$f"
}
rel(){ jq -r --arg n "$1" ".releases[] | select(.name == \$n) | $2" "$CFG"; }

# helm dependency build, local file:// dependencies first (sessions-pipeline before agent-relay).
declare -A BUILT=()
build_deps(){
  local chart=$1 _ repo
  [ -n "${BUILT[$chart]:-}" ] && return 0
  BUILT[$chart]=1
  [ -f "$chart/Chart.yaml" ] || die "not a chart: ${chart#"$B"/}"
  while IFS=$'\t' read -r _ repo; do
    case "$repo" in
      file://*) build_deps "$(realpath -m "$chart/${repo#file://}")" ;;
      http*://*) helm repo add "d$(printf %s "$repo" | cksum | cut -d' ' -f1)" "$repo" --force-update >/dev/null ;;
    esac
  done < <(python3 -c 'import sys, yaml
for d in yaml.safe_load(open(sys.argv[1])).get("dependencies") or []:
    print(d["name"] + "\t" + (d.get("repository") or ""))' "$chart/Chart.yaml")
  helm dependency build "$chart" >/dev/null || die "helm dependency build ${chart#"$B"/} failed"
}

helm_args(){ # release -> chart and values flags
  local r=$1 v
  printf '%s\0' "$(inside "$(rel "$r" .chart)")"
  printf '%s\0' --namespace "$(rel "$r" .namespace)"
  while IFS= read -r v; do printf '%s\0' -f "$(inside "$v")"; done < <(rel "$r" '.values[]')
}

live_revision(){ helm status "$1" -n "$2" -o json 2>/dev/null | jq -r '.version // empty'; }

# release_exists <release> <ns>: 0 exists, 1 not found; any other error (API down, access denied) stops the run.
release_exists(){
  local err
  if err=$(helm status "$1" -n "$2" 2>&1 >/dev/null); then return 0; fi
  [[ "$err" == *"release: not found"* ]] && return 1
  die "helm status $1 failed: $(printf '%s' "$err" | head -1)"
}

plan_release(){
  local r=$1 ns live new args=()
  ns=$(rel "$r" .namespace)
  while IFS= read -r -d '' a; do args+=("$a"); done < <(helm_args "$r")
  build_deps "${args[0]}"
  live="$WORK/live/$r"; mkdir -p "$live"
  # Called under ||, where set -e does not apply: every step checks its own result.
  if release_exists "$r" "$ns"; then
    helm get values "$r" -n "$ns" -o json > "$live/values.json" &&
      helm get manifest "$r" -n "$ns" > "$live/manifest.yaml" &&
      helm get hooks "$r" -n "$ns" > "$live/hooks.yaml" &&
      live_revision "$r" "$ns" > "$live/revision" || { log "reading live release $r failed"; return 1; }
    cp "$live/revision" "$REPORT_DIR/revision-$r"
  fi
  # server: render with the cluster's capabilities and lookups, as the upgrade will (nothing is applied).
  new="$WORK/new-$r.json"
  if [ -z "$(orphans "$r")" ]; then
    helm upgrade --install "$r" "${args[@]}" --dry-run=server -o json > "$new" ||
      { log "rendering $r failed"; return 1; }
  else
    # Listed orphans (replace-orphans.txt) would make the dry run fail on ownership. Take ownership in the dry run
    # only (nothing is written), then refuse unless every unowned live object it would take is a listed, finished Job.
    helm upgrade --install "$r" "${args[@]}" --dry-run=server --take-ownership -o json > "$new" ||
      { log "rendering $r failed"; return 1; }
    local live_objs="$WORK/orphan-live-$r.json" kind name ons
    : > "$live_objs"
    while IFS=$'\t' read -r kind name ons; do
      kubectl get "$kind" "$name" -n "$ons" -o json --ignore-not-found >> "$live_objs" ||
        { log "reading live $kind/$name failed"; return 1; }
    done < <(python3 "$HERE/ci_deploy_orphans.py" objects "$new" "$ns")
    python3 "$HERE/ci_deploy_orphans.py" check "$r" "$live_objs" "$B/env/replace-orphans.txt" "$REPORT_DIR/orphans-$r.txt" ||
      { log "plan $r: an object exists without Helm ownership and is not a listed orphan (see above)"; return 1; }
    [ ! -s "$REPORT_DIR/orphans-$r.txt" ] || log "plan $r: the apply replaces orphan Job(s): $(tr '\n' ' ' < "$REPORT_DIR/orphans-$r.txt")"
  fi
  python3 "$HERE/ci_deploy_plan.py" "$r" "$live" "$new" "$B/env/allow-drop.txt" "$REPORT_DIR/plan"
}

plan_all(){
  local r prc refused=0 summary="$REPORT_DIR/plan.md"
  : > "$REPORT_DIR/revisions"
  {
    echo "## Plan: $(jq -r '.environment // "environment"' "$CFG") (run $RUN_ID)"
    echo
    echo "| Release | Live revision | Changes | Values +/~/- | Resources +/~/- | Refused drops |"
    echo "|---|---|---|---|---|---|"
  } > "$summary"
  for r in $(releases); do
    log "plan $r"
    prc=0; plan_release "$r" || prc=$?
    case $prc in 0) ;; 3) refused=1 ;; *) die "plan failed for $r" ;; esac
    local j="$REPORT_DIR/plan/$r.json" rev
    rev=$(cat "$REPORT_DIR/revision-$r" 2>/dev/null || echo none)
    echo "$r=$rev" >> "$REPORT_DIR/revisions"
    jq -r --arg rev "$rev" '"| \(.release) | \($rev) | \(if .no_changes then "none" else "yes" end) | " +
      "\(.values.added|length)/\(.values.changed|length)/\(.values.dropped|length) | " +
      "\(.resources.added|length)/\(.resources.changed|length)/\(.resources.dropped|length) | " +
      "\((.refused.values + .refused.resources) | if length == 0 then "none" else join(", ") end) |"' "$j" >> "$summary"
  done
  cat "$REPORT_DIR"/plan/*.diff > "$REPORT_DIR/diff.txt" 2>/dev/null || true
  jq -s 'map({(.release): (.no_changes | not)}) | add' "$REPORT_DIR"/plan/*.json > "$REPORT_DIR/changes.json"
  [ $refused -eq 0 ] || { log "plan REFUSED: a live value or resource would be dropped (see plan.md)"; exit 3; }
}

snapshot(){
  local type id
  type=$(jq -r '.snapshot.type // "none"' "$CFG")
  id="$(printf '%s' "${CI_DEPLOY_NAME:-deploy}-${RUN_ID}" | tr -c 'A-Za-z0-9-' '-' | tr -s '-' | cut -c1-63 | sed 's/-*$//')"
  case "$type" in
    none) log "snapshot: none configured"; echo "none" > "$REPORT_DIR/snapshot" ;;
    rds)
      local db; db=$(jq -r '.snapshot.instance' "$CFG")
      log "snapshot: RDS $db -> $id"
      aws rds create-db-snapshot --db-instance-identifier "$db" --db-snapshot-identifier "$id" \
        --tags "Key=agent-relay/run,Value=$RUN_ID" >/dev/null
      aws rds wait db-snapshot-available --db-snapshot-identifier "$id"
      echo "rds:$id" > "$REPORT_DIR/snapshot"; log "snapshot: $id available" ;;
    pg_dump)
      # One custom-format dump per entry, streamed to S3; the URL is read from the cluster and never printed.
      local n i ns name key url dest ca
      n=$(jq '.snapshot.databases | length' "$CFG")
      [ "$n" -gt 0 ] || die "snapshot.databases is empty"
      : > "$REPORT_DIR/snapshot"
      for ((i = 0; i < n; i++)); do
        read -r name ns key < <(jq -r ".snapshot.databases[$i] | \"\(.label) \(.namespace) \(.secret)/\(.key)\"" "$CFG")
        url=$(kubectl -n "$ns" get secret "${key%%/*}" -o json | jq -r --arg k "${key#*/}" '.data[$k] // empty' | base64 -d)
        [ -n "$url" ] || die "snapshot $name: secret key ${key} is empty or missing"
        dest="s3://$CI_DEPLOY_BUCKET/snapshots/$RUN_ID/$name.dump"
        # Optional CA for sslmode=verify-full, from the ConfigMap the application itself trusts.
        unset PGSSLROOTCERT
        ca=$(jq -r ".snapshot.databases[$i].ca // empty | \"\\(.configMap)/\\(.key)\"" "$CFG")
        if [ -n "$ca" ]; then
          kubectl -n "$ns" get configmap "${ca%%/*}" -o json | jq -j --arg k "${ca#*/}" '.data[$k] // empty' > "$WORK/pg-ca-$name.crt"
          [ -s "$WORK/pg-ca-$name.crt" ] || die "snapshot $name: CA ConfigMap $ca is empty or missing"
          export PGSSLROOTCERT="$WORK/pg-ca-$name.crt"
          # libpq prefers a URL sslrootcert (often a pod-only path) over PGSSLROOTCERT: point it at this CA.
          url=$(printf '%s' "$url" | python3 -c 'import os, sys, urllib.parse as u
p = u.urlsplit(sys.stdin.read())
q = [(k, v) for k, v in u.parse_qsl(p.query, keep_blank_values=True) if k != "sslrootcert"]
if len(q) != len(u.parse_qsl(p.query, keep_blank_values=True)):
    q.append(("sslrootcert", os.environ["PGSSLROOTCERT"]))
sys.stdout.write(u.urlunsplit(p._replace(query=u.urlencode(q, quote_via=u.quote, safe="/"))))')
        fi
        log "snapshot: pg_dump $name -> $dest"
        pg_dump --format=custom --no-owner --no-privileges --dbname="$url" |
          aws s3 cp --only-show-errors - "$dest"   # the bucket's default customer key
        unset url
        echo "pg_dump:$dest" >> "$REPORT_DIR/snapshot"
      done ;;
    *) die "unknown snapshot type $type" ;;
  esac
}

health(){
  local url ok i code
  for url in $(jq -r '(.health // [])[]' "$CFG"); do
    ok=0
    for i in $(seq 1 "${HEALTH_TRIES:-30}"); do
      code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)
      if [[ "$code" == 2?? ]]; then ok=1; break; fi   # a redirect is not healthy
      sleep "${POLL_SECONDS:-10}"
    done
    [ $ok = 1 ] || die "health: $url did not return 2xx"
    log "health: $url ok"
  done
}

# record_jobs <release> <ns>: every Job of the release now in the cluster, whatever its age (a chart Job keeps its
# name while its inputs are unchanged, so a re-run sees the one an earlier upgrade created): name, Complete/Failed,
# completionTime on stderr and in state.jsonl, and the last JOB_LOG_LINES (40) lines of its log in jobs.txt.
# Lines that look like they carry a credential (a URL with userinfo, or password/secret/token followed by = or :)
# are replaced, never copied.
record_jobs(){
  local r=$1 ns=$2 name
  kubectl -n "$ns" get jobs -o json | jq -c --arg r "$r" '.items[]
    | select(.metadata.annotations["meta.helm.sh/release-name"] == $r or .metadata.labels["app.kubernetes.io/instance"] == $r)
    | {job: .metadata.name, created: .metadata.creationTimestamp, completed: .status.completionTime,
       state: (if ((.status.conditions // []) | any(.type == "Failed" and .status == "True")) then "Failed"
               elif ((.status.conditions // []) | any(.type == "Complete" and .status == "True")) then "Complete" else "Active" end)}' |
    while read -r j; do
      echo "$j"; name=$(jq -r .job <<<"$j")
      { echo "### job $name $(jq -r .state <<<"$j")"
        kubectl -n "$ns" logs "job/$name" --all-containers --tail="${JOB_LOG_LINES:-40}" 2>&1 |
          sed -E '/[A-Za-z][A-Za-z0-9+.-]*:\/\/[^/[:space:]]*@|([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn])[^[:space:]]*[=:]/c\[line withheld: may contain a credential]' || true
        echo; } >> "$REPORT_DIR/jobs.txt"
    done
}

record_state(){ # versions now running, for the run record
  local r ns
  for r in $(releases); do
    ns=$(rel "$r" .namespace)
    helm status "$r" -n "$ns" -o json | jq -c '{release: .name, revision: .version, status: .info.status, chart: (.chart.metadata.name + "-" + .chart.metadata.version), app: .chart.metadata.appVersion}'
    kubectl -n "$ns" get deploy,statefulset -l "app.kubernetes.io/instance=$r" -o json |
      jq -c '.items[] | {kind, name: .metadata.name, images: [.spec.template.spec.containers[].image]}'
    kubectl -n "$ns" get pods -l "app.kubernetes.io/instance=$r" -o json |
      jq -c '.items[] | select(.status.phase == "Running") | {pod: .metadata.name, ready: ((.status.conditions // []) | any(.type == "Ready" and .status == "True")),
        restarts: ([.status.containerStatuses[]?.restartCount] | add), imageIDs: [.status.containerStatuses[]?.imageID]}'
    record_jobs "$r" "$ns"
  done | tee "$REPORT_DIR/state.jsonl" >&2
}

# wait_release_jobs <release> <ns> <RFC3339 start> <timeout seconds>: helm --wait does not wait for plain Jobs
# (migrations). Wait until every Job of this release created since the upgrade started has succeeded; fail as
# soon as one fails, or at the timeout.
wait_release_jobs(){
  local r=$1 ns=$2 t=$3 deadline=$((SECONDS + $4)) jobs failed active
  while :; do
    jobs=$(kubectl -n "$ns" get jobs -o json | jq -c --arg t "$t" --arg r "$r" '[.items[]
      | select(.metadata.creationTimestamp >= $t)
      | select(.metadata.annotations["meta.helm.sh/release-name"] == $r or .metadata.labels["app.kubernetes.io/instance"] == $r)
      | {name: .metadata.name, failed: ((.status.conditions // []) | any(.type == "Failed" and .status == "True")),
         done: ((.status.conditions // []) | any(.type == "Complete" and .status == "True"))}]') || return 1
    failed=$(jq -r '[.[] | select(.failed) | .name] | join(" ")' <<<"$jobs")
    [ -z "$failed" ] || { log "jobs failed: $failed"; return 1; }
    active=$(jq -r '[.[] | select((.done or .failed) | not) | .name] | join(" ")' <<<"$jobs")
    if [ -z "$active" ]; then
      if [ "$(jq length <<<"$jobs")" = 0 ]; then log "no Jobs created by this upgrade"
      else jq -r '.[].name' <<<"$jobs" | while read -r j; do log "job $j: complete"; done; fi
      return 0
    fi
    [ $SECONDS -lt $deadline ] || { log "jobs still running at the timeout: $active"; return 1; }
    sleep "${POLL_SECONDS:-10}"
  done
}

# sync_secrets: copy each deploy.json "secrets" entry from AWS Secrets Manager into Kubernetes Secret keys, so
# Secret values live in one durable store and never pass through a laptop, git or a log. An entry with
# "generate": "base64url-32" is created in Secrets Manager the first time (32 random bytes, unpadded base64url).
# Only the listed key is written: server-side apply with one field manager per data key, so keys written by
# other mappings (or anyone else) are never removed. No type is sent, so an existing Secret keeps its type.
# Pods read a changed value on their next start (the Helm upgrade that first references it restarts them).
#   {"source": "<Secrets Manager name>", "generate": "base64url-32",
#    "targets": [{"namespace": "...", "name": "<Secret>", "key": "<data key>"}]}
# Kubernetes limits fieldManager to 128 characters; Secret keys may be 253.
field_manager(){
  if [ ${#1} -le 100 ]; then printf 'ci-deploy-secret-%s' "$1"
  else printf 'ci-deploy-secret-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-32)"; fi
}

sync_secrets(){
  local n i j m src gen ns name key val="$WORK/secret-value"
  n=$(jq '(.secrets // []) | length' "$CFG")
  for ((i = 0; i < n; i++)); do
    src=$(jq -r ".secrets[$i].source" "$CFG"); gen=$(jq -r ".secrets[$i].generate // empty" "$CFG")
    [[ "$src" =~ ^[A-Za-z0-9/_+=.@-]+$ ]] || die "secrets[$i].source is not a Secrets Manager name"
    # The value goes AWS JSON -> jq -> file, never through command substitution (it would strip trailing
    # newlines) or argv.
    if ! aws secretsmanager get-secret-value --secret-id "$src" --output json > "$WORK/sm.json" 2>"$WORK/sm.err"; then
      grep -q ResourceNotFoundException "$WORK/sm.err" || die "reading $src failed: $(head -c 200 "$WORK/sm.err")"
      [ "$gen" = base64url-32 ] || die "$src does not exist and has no generate rule"
      python3 -c 'import base64, os, sys; sys.stdout.write(base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode())' > "$WORK/new"
      aws secretsmanager create-secret --name "$src" ${CI_DEPLOY_SECRETS_KMS_KEY:+--kms-key-id "$CI_DEPLOY_SECRETS_KMS_KEY"} \
        --secret-string "file://$WORK/new" --tags "Key=agent-relay/generated-by,Value=ci-deploy" >/dev/null
      rm -f "$WORK/new"
      aws secretsmanager get-secret-value --secret-id "$src" --output json > "$WORK/sm.json"
      log "secrets: created $src"
    fi
    jq -j '.SecretString // empty' "$WORK/sm.json" > "$val"; rm -f "$WORK/sm.json"
    [ -s "$val" ] || die "$src has no string value"
    m=$(jq ".secrets[$i].targets | length" "$CFG")
    for ((j = 0; j < m; j++)); do
      read -r ns name key < <(jq -r ".secrets[$i].targets[$j] | \"\\(.namespace) \\(.name) \\(.key)\"" "$CFG")
      [[ "$key" =~ ^[A-Za-z0-9._-]+$ ]] || die "secrets[$i].targets[$j].key is not a Secret data key"
      # One field manager per data key: applying this key never relinquishes keys other mappings wrote.
      # No type: an existing Secret keeps its own (a new one is Opaque).
      jq -Rs --arg ns "$ns" --arg n "$name" --arg k "$key" \
        '{apiVersion: "v1", kind: "Secret", metadata: {name: $n, namespace: $ns}, data: {($k): (. | @base64)}}' < "$val" |
        kubectl apply --server-side --field-manager="$(field_manager "$key")" -f - >/dev/null || die "writing $ns/$name/$key failed"
      log "secrets: $src -> ${ns}/${name}[${key}]"
    done
    rm -f "$val"
  done
}

case "$MODE" in
  plan)
    plan_all
    if [ "$(jq '(.secrets // []) | length' "$CFG")" -gt 0 ]; then
      { echo; echo "Secrets synced from AWS Secrets Manager on apply (values never shown):"; echo
        jq -r '.secrets[] | "- `\(.source)` -> " + ([.targets[] | "`\(.namespace)/\(.name)[\(.key)]`"] | join(", "))' "$CFG"; } >> "$REPORT_DIR/plan.md"
    fi ;;
  apply)
    plan_all
    expect=${EXPECT_REVISIONS:?EXPECT_REVISIONS from the reviewed plan is required}
    now=$(tr '\n' ' ' < "$REPORT_DIR/revisions" | sed 's/ $//')
    [ "$now" = "$expect" ] || die "live revisions changed since the plan: planned [$expect], now [$now]. Re-run the plan."
    if [ "$(jq '[.[]] | any' "$REPORT_DIR/changes.json")" != true ] && [ "${FORCE_UPGRADE:-0}" != 1 ]; then
      log "apply: no changes; nothing to do"; record_state; health; exit 0
    fi
    snapshot
    sync_secrets
    if [ -f "$B/env/plan-rbac.yaml" ]; then kubectl apply -f "$B/env/plan-rbac.yaml" >/dev/null; log "plan RBAC applied"; fi
    for r in $(releases); do
      if [ "$(jq --arg r "$r" '.[$r]' "$REPORT_DIR/changes.json")" != true ] && [ "${FORCE_UPGRADE:-0}" != 1 ]; then
        log "apply $r: no changes, skipped"; continue
      fi
      args=(); while IFS= read -r -d '' a; do args+=("$a"); done < <(helm_args "$r")
      ns=$(rel "$r" .namespace); start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      log "apply $r (was revision $(live_revision "$r" "$ns"))"
      replace_orphans "$r" "$ns" || die "replacing orphan Jobs of $r failed (nothing upgraded)"
      if ! helm upgrade --install "$r" "${args[@]}" --wait --timeout "$(rel "$r" '.timeout // "20m"')" > "$REPORT_DIR/helm-$r.txt" 2>&1; then
        tail -20 "$REPORT_DIR/helm-$r.txt" >&2
        die "helm upgrade $r failed. Roll back: dispatch mode=rollback release=$r revision=<previous>"
      fi
      wait_release_jobs "$r" "$ns" "$start" "${JOB_TIMEOUT_SECONDS:-1800}" ||
        die "jobs of $r did not complete. Roll back: dispatch mode=rollback release=$r revision=<previous>"
      log "apply $r: now revision $(live_revision "$r" "$ns")"
    done
    record_state; health ;;
  rollback)
    r=${ROLLBACK_RELEASE:?}; rev=${ROLLBACK_REVISION:?}
    [[ "$rev" =~ ^[0-9]+$ ]] || die "ROLLBACK_REVISION must be a number"
    ns=$(rel "$r" .namespace); [ -n "$ns" ] || die "release $r is not in deploy.json"
    log "rollback $r from revision $(live_revision "$r" "$ns") to $rev"
    helm rollback "$r" "$rev" -n "$ns" --wait --timeout "$(rel "$r" '.timeout // "20m"')" > "$REPORT_DIR/helm-rollback.txt" 2>&1 ||
      { tail -20 "$REPORT_DIR/helm-rollback.txt" >&2; die "helm rollback failed"; }
    record_state; health ;;
esac
log "$MODE done"
