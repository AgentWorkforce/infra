# shellcheck shell=bash
# Sourced: the caller defines the variables this file reads.
# shellcheck disable=SC2154
# Relaycast PostgreSQL -> durable-actors migration, sourced by
# agent-relay-upgrade.sh for --relaycast-actors credentials|cutover. Design:
# docs/relaycast-postgres-to-actors-migration.md. Uses the caller's verified
# release ($chart, $manifest), render command ($render, $base), kubectl/helm
# arrays ($kube, $helmx), $work, $state_dir, $registry, say/die and wait_jobs.
#
#   credentials  (online) switch the PostgreSQL release to ar_ credentials with
#                the keyring the actors will use, then re-key every Relaycast
#                credential relay-control holds (relaycast-rekey). Legacy
#                credentials keep working for the engine's grace period.
#   cutover      (messaging down) preflight, quiesce, export, helm upgrade with
#                a Relaycast-only actors overlay, copy files, import, verify,
#                open. Refuses rather than drop anything; a rerun after a
#                failed import resumes it.
#
# Every step fails the run: no step's failure is ignored or retried silently.

rta_state() { printf '%s/relaycast-actors/%s-%s' "$state_dir" "$namespace" "$release"; }
# Atomically replace a state file with stdin, owner-only (0600 in a 0700
# directory): the STATE_DIR guard refuses anything wider on the next run.
rta_write() { # path < content
  local dir tmp; dir=$(dirname "$1")
  ( umask 077; mkdir -p "$dir" ); chmod 700 "$dir"
  tmp=$(mktemp "$dir/.rta.XXXXXX") || die "could not write $1"
  chmod 600 "$tmp"
  cat > "$tmp" || { rm -f "$tmp"; die "could not write $1"; }
  mv -f "$tmp" "$1" || { rm -f "$tmp"; die "could not write $1"; }
}
rta_mark() { : | rta_write "$1"; }
rta_live() { yq -r "$1 // \"\"" "$work/rta-live-values.yaml"; }
# sha256 of one Secret key's bytes ("" when absent); the value never leaves the pipe.
rta_secret_digest() { # namespace secret key
  kubectl ${context:+--context "$context"} -n "$1" get secret "$2" -o json 2>/dev/null \
    | jq -r --arg k "$3" '.data[$k] // empty' | { base64 -d 2>/dev/null || true; } | sha256sum | awk '{print $1}'
}
EMPTY_SHA=$(printf '' | sha256sum | awk '{print $1}')
# A release Deployment by its chart name label (fullnameOverride-safe).
rta_deploy() { # app.kubernetes.io/name
  "${kube[@]}" get deploy -l "app.kubernetes.io/instance=$release,app.kubernetes.io/name=$1" -o name
}

rta_check() { # plan-time guards, shared by both phases
  [ "$profile" = eks-rds-native ] || die "--relaycast-actors needs --profile eks-rds-native (Relaycast on RDS)"
  ! $first_install || die "--relaycast-actors migrates an existing release; it cannot be combined with --first-install"
  "${helmx[@]}" get values "$release" -a -o yaml > "$work/rta-live-values.yaml" \
    || die "could not read the deployed values of $release"
  live_chart=$("${helmx[@]}" list --filter "^${release}\$" -o json | jq -r '.[0].chart // empty')
  [ "$live_chart" = "agent-relay-$chart_version" ] \
    || die "--relaycast-actors runs on the deployed chart version (deployed $live_chart, release $chart_version): upgrade first, then migrate"
  rta_resume=false
  backend=$(rta_live .relaycast.runtime.backend)
  rta_golive=false
  if [ "$rta_phase" = cutover ] && [ "$backend" = durable-actors ] && [ -s "$(rta_state).run" ] && [ ! -e "$(rta_state).opened" ]; then
    rta_resume=true
    rta_run=$(cat "$(rta_state).run")
    if [ -e "$(rta_state).golive" ]; then
      rta_golive=true
      say "   go-live of cutover run $rta_run is recorded but unfinished: resuming it (opening every workspace); forward only"
    else
      say "   resuming cutover run $rta_run: Relaycast is on durable-actors and its import has not been opened"
    fi
  elif [ "$backend" != postgres ]; then
    die "Relaycast in $release is on runtime.backend=$backend, not postgres; nothing to migrate"
  fi
  rta_secret=$(rta_live .relaycast.existingSecret)
  [ -n "$rta_secret" ] || die "relaycast.existingSecret is not set in $release"
  rta_keyring_key=$(rta_live .relaycast.secretKeys.credentialKeyring); rta_keyring_key=${rta_keyring_key:-credential-keyring}
  [ "$(rta_secret_digest "$namespace" "$rta_secret" "$rta_keyring_key")" != "$EMPTY_SHA" ] \
    || die "Secret $rta_secret has no $rta_keyring_key key: create the credential keyring (the same one the actors will use) first"
  rta_relaycast=$(rta_deploy relaycast)
  [ "$(grep -c . <<<"$rta_relaycast")" = 1 ] || die "expected one Relaycast Deployment in release $release, found: ${rta_relaycast:-none}"
  rta_control=$(rta_deploy relay-control)
  [ "$(grep -c . <<<"$rta_control")" -le 1 ] || die "expected at most one relay-control Deployment, found: $rta_control"
}

rta_target_render() { "${render[@]}" "${base[@]}" "${rta_actor_files[@]}"; }

rta_check_cutover() {
  [ -f "$chart/values-eks-actors.yaml" ] || die "release $version does not ship values-eks-actors.yaml"
  [ "${#rta_actor_values[@]}" -gt 0 ] || die "cutover needs --actors-values <file>: your overrides for the actors profile (bucket, publicUrl, zone, mirrored images)"
  [ "$(rta_live .relaycast.credentials.format)" = ar ] \
    || die "Relaycast still issues legacy credentials: run --relaycast-actors credentials first"
  [ -s "$(rta_state).ar-since" ] || die "no record of the credentials phase under $state_dir (run --relaycast-actors credentials with this STATE_DIR)"
  # Only the Relaycast and durable-actors parts of the actors profile: the
  # profile also turns the rest of the suite off and moves Relayfile, which
  # this migration must not do.
  yq '{"relaycast": .relaycast, "durable-actors": .["durable-actors"]}' "$chart/values-eks-actors.yaml" > "$work/rta-actors-profile.yaml"
  rta_actor_files=(-f "$work/rta-actors-profile.yaml")
  for v in "${rta_actor_values[@]}"; do [ -f "$v" ] || die "actors values file not found: $v"; rta_actor_files+=(-f "$v"); done
  # Last, so nothing can change them: the install's Secret, keyring and
  # bootstrap secret (the routing tags and keyed workspace ids derive from
  # them), the retained data claim (files, export, rollback: see relaycast
  # persistence.retainForMigration), analytics off (the actor runtime has no
  # collector, relaycast#648), and the components this move needs.
  local bootstrap; bootstrap=$(rta_live .relaycast.secretKeys.bootstrapSecret); bootstrap=${bootstrap:-$(rta_live .relaycast.secretKeys.workspaceBootstrapSecret)}
  cat > "$work/rta-pinned.yaml" <<EOF
components: { relaycast: true, durableActors: true }
relaycast:
  existingSecret: $rta_secret
  secretKeys:
    credentialKeyring: $rta_keyring_key
    workspaceBootstrapSecret: "$bootstrap"
  credentials: { format: ar, authority: self }
  persistence: { retainForMigration: true }
  analytics: { enabled: false, collectorUrl: "", deploymentId: "", existingSecret: "", caConfigMap: "" }
EOF
  rta_actor_files+=(-f "$work/rta-pinned.yaml")
  rta_target_render > "$work/rta-target.yaml" || die "the actors values do not render"
  rta_target_checks
}

rta_target_checks() {
  local t="$work/rta-target.yaml"
  # Nothing running may disappear.
  "${kube[@]}" get deploy -l "$release_selector" -o json | jq -r '.items[].metadata.name' | sort -u > "$work/rta-live-deploys"
  yq -N -r 'select(.kind == "Deployment") | .metadata.name' "$t" | sort -u > "$work/rta-target-deploys"
  missing=$(comm -23 "$work/rta-live-deploys" "$work/rta-target-deploys")
  $rta_resume || [ -z "$missing" ] || die "the actors values would remove running components:
$missing"
  gw='select(.kind == "Deployment" and .metadata.labels["app.kubernetes.io/name"] == "relaycast")'
  [ "$(yq -N -r "$gw | .spec.template.spec.containers[0].name" "$t")" = gateway ] || die "the actors values do not put Relaycast on durable-actors"
  [ "$(yq -N -r "$gw | .spec.template.spec.volumes[] | select(.name == \"secrets\") | .secret.secretName" "$t")" = "$rta_secret" ] \
    && [ "$(yq -N -r "$gw | .spec.template.spec.volumes[] | select(.name == \"secrets\") | .secret.items[] | select(.path == \"credential-keyring\") | .key" "$t")" = "$rta_keyring_key" ] \
    || die "the actors gateway must read keyring $rta_secret/$rta_keyring_key, as the PostgreSQL release does: the routing tags come from it"
  # The durable-actors control plane and pool manager keep their state in RDS
  # and must verify its certificate (verify-full): a postgres-ca volume.
  cps='select(.kind == "Deployment" and (.metadata.name | test("-durable-actors(-pool-manager)?$")))'
  [ "$(yq -N -r "$cps | .metadata.name" "$t" | grep -c . || true)" -gt 0 ] || die "the actors values render no durable-actors control plane"
  without_ca=$(yq -N -r "$cps | select(([.spec.template.spec.volumes[]? | select(.name == \"postgres-ca\")] | length) == 0) | .metadata.name" "$t")
  [ -z "$without_ca" ] || die "these durable-actors Deployments would reach RDS without a CA bundle (verify-full TLS is required; no postgres-ca volume):
$without_ca"
  # Every image the cutover runs must be pullable after messaging stops: a
  # release image (mirrored above) or one already mirrored into $registry.
  yq -N -r '.. | select(tag == "!!map") | select(has("image")) | .image | select(tag == "!!str")' "$t" | sort -u > "$work/rta-target-images"
  rta_extra_images=$(comm -23 "$work/rta-target-images" "$work/expected-images.txt")
  outside=$( { grep -v "^${registry}/" <<<"$rta_extra_images"; grep "^${registry}/" <<<"$rta_extra_images" | grep -v '@sha256:[0-9a-f]\{64\}$'; } || true)
  [ -z "$outside" ] || die "the cutover would run images that are neither release images nor digest-pinned mirrors in $registry (mirror them and set repository + digest in --actors-values):
$outside"
  # The actors read the gateway's secrets from their own Secret in the sandbox
  # namespace: the same bytes, or keyed creates, file URLs and the internal
  # API break after the move.
  sandbox=$(yq -N -r "select(.kind == \"Role\" and .metadata.namespace != \"$namespace\") | .metadata.namespace" "$t" | head -1)
  refs=$(yq -N -r 'select(.kind == "Job") | .spec.template.spec.containers[].env[]? | select(.name == "DURABLE_ACTORS_SECRET_REFS") | .value' "$t" | head -1)
  [ -n "$sandbox" ] && [ -n "$refs" ] || die "could not find the actors' sandbox namespace or env Secret in the render"
  actor_digest() { local name d; for name in ${refs//,/ }; do d=$(rta_secret_digest "$sandbox" "$name" "$1"); [ "$d" = "$EMPTY_SHA" ] || { echo "$d"; return; }; done; echo "$EMPTY_SHA"; }
  gw_ref() { yq -N -r "$gw | .spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .valueFrom.secretKeyRef | .name + \" \" + .key" "$t" | head -1; }
  local ref
  ref=$(gw_ref RELAYCAST_FILE_SIGNING_SECRET)
  [ "$(rta_secret_digest "$namespace" ${ref})" = "$(actor_digest RELAYCAST_FILE_SIGNING_SECRET)" ] \
    || die "the actor env Secret ($sandbox: $refs) must hold RELAYCAST_FILE_SIGNING_SECRET with the gateway's bytes ($ref)"
  internal_key=$(rta_live .relaycast.secretKeys.internalSecret); internal_key=${internal_key:-internal-secret}
  [ "$(rta_secret_digest "$namespace" "$rta_secret" "$internal_key")" = "$(actor_digest RELAYCAST_INTERNAL_SECRET)" ] \
    || die "the actor env Secret ($sandbox: $refs) must hold RELAYCAST_INTERNAL_SECRET with the bytes of $rta_secret/$internal_key"
  ref=$(gw_ref RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET)
  if [ -n "$ref" ] && [ "$ref" != " " ]; then
    [ "$(rta_secret_digest "$namespace" ${ref})" = "$(actor_digest RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET)" ] \
      || die "the actor env Secret ($sandbox: $refs) must hold RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET with the gateway's bytes ($ref): keyed workspace ids derive from it"
  fi
  # relay-control's encryption key must be the one the re-key ran under, until
  # the re-key backups are purged: otherwise --undo cannot decrypt them.
  if [ -s "$(rta_state).control-key" ]; then
    now_key=$(rta_live '.["relay-control"].encryption.keyId'); prev_key=$(rta_live '.["relay-control"].encryption.previousKeyId')
    rec_key=$(cat "$(rta_state).control-key")
    [ "$now_key" = "$rec_key" ] || [ "$prev_key" = "$rec_key" ] \
      || die "relay-control's encryption key changed since the credentials phase ($rec_key): keep it (or as previousKeyId) until relaycast-rekey --purge"
  fi
}

rta_check_mirrored() { # every image the cutover adds beyond the release must exist in the registry
  local img
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    [ "$(crane digest "$img" 2>/dev/null)" = "${img##*@}" ] \
      || die "cutover image $img is not in $registry (or its digest differs): mirror it before the cutover; nothing was stopped"
  done <<<"$rta_extra_images"
  say "   every cutover image is present in $registry"
}

rta_render_step() { # step [extra helm args]: render one migration Job to $work/rta-<step>.yaml, echo its name
  local step=$1 files=(); shift
  case "$step" in files|import|verify|open) files=("${rta_actor_files[@]}") ;; esac
  "${render[@]}" "${base[@]}" "${files[@]}" --show-only charts/relaycast/templates/migration-job.yaml \
    --set relaycast.migration.enabled=true --set relaycast.migration.step="$step" \
    --set relaycast.migration.runId="$rta_run" "$@" > "$work/rta-$step.yaml" || return 1
  yq -N -r 'select(.kind == "Job") | .metadata.name' "$work/rta-$step.yaml"
}

rta_run_step() { # step [extra helm args]: apply one migration Job, wait, keep its log; fails the run on any failure
  local step=$1 job; shift
  job=$(rta_render_step "$step" "$@") || die "the $step Job does not render"
  [ -n "$job" ] || die "no $step Job rendered"
  "${kube[@]}" delete job "$job" --ignore-not-found >/dev/null || die "could not remove an earlier $step Job"
  "${kube[@]}" apply -f "$work/rta-$step.yaml" >/dev/null || die "could not create the $step Job"
  say "   $step: Job $job"
  if ! wait_jobs "$job"; then die "the $step Job failed (logs above)"; fi
  "${kube[@]}" logs "job/$job" --tail=-1 > "$work/rta-$step.log" 2>&1 || die "could not read the $step Job's logs"
  grep -v '^{' "$work/rta-$step.log" | sed 's/^/     /' | tail -40
}

rta_preflight() { # refuses unless every workspace can move whole (the Job's exit says so)
  local extra=()
  if $rta_reregister_legacy; then extra=(--set relaycast.migration.allowLegacy=true); fi
  rta_run_step preflight --set relaycast.migration.arSince="$(cat "$(rta_state).ar-since")" "${extra[@]}"
  grep '^{' "$work/rta-preflight.log" | jq -c '.' | sed 's/^/     /'
}

rta_scale_down() { # deployment...: to 0 replicas, and confirm their pods are gone
  local d sel
  for d in "$@"; do
    "${kube[@]}" scale "$d" --replicas=0 >/dev/null || die "could not scale $d to 0"
    sel=$("${kube[@]}" get "$d" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
    "${kube[@]}" wait --for=delete pod -l "$sel" --timeout=10m >/dev/null 2>&1 || true
    [ -z "$("${kube[@]}" get pod -l "$sel" -o name)" ] || die "$d still has pods after 10 minutes: the export must not race a writer"
  done
}

rta_credentials() {
  say "== R1. Switch $release's Relaycast to ar_ credentials (legacy ones keep working during the grace period)"
  # The earliest switch time stands: a retried phase must not hide principals
  # created between the first switch and the retry.
  [ -s "$(rta_state).ar-since" ] || date -u +%s | rta_write "$(rta_state).ar-since"
  [ -s "$(rta_state).control-key" ] || rta_live '.["relay-control"].encryption.keyId' | rta_write "$(rta_state).control-key"
  cat > "$work/rta-credentials.yaml" <<EOF
relaycast:
  credentials:
    format: ar
    authority: self
  secretKeys:
    credentialKeyring: $rta_keyring_key
EOF
  "${helmx[@]}" upgrade "$release" "$chart" "${base[@]}" -f "$work/rta-credentials.yaml" --wait --wait-for-jobs --timeout 15m
  "${kube[@]}" rollout status "$rta_relaycast" --timeout 10m
  if [ -n "$rta_control" ]; then
    say "== R2. Re-key the Relaycast credentials relay-control holds (relaycast-rekey)"
    # Its output is ids, kinds and counts only; kept for --undo / --purge.
    if ! "${kube[@]}" exec "$rta_control" -- node /app/node_modules/relay-control/dist/relaycast-rekey-cli.js > "$work/rta-rekey.jsonl"; then
      sed 's/^/     /' "$work/rta-rekey.jsonl"
      die "relaycast-rekey failed: rerun this phase (it skips credentials already re-keyed)"
    fi
    sed 's/^/     /' "$work/rta-rekey.jsonl"
    rekey_run=$(jq -r 'select(.event == "relaycast_rekey.summary") | .run_id // empty' "$work/rta-rekey.jsonl" 2>/dev/null | tail -1)
    [ -n "$rekey_run" ] || die "relaycast-rekey printed no run id: cannot record it for --undo / --purge"
    { if [ -f "$(rta_state).rekey-runs" ]; then cat "$(rta_state).rekey-runs"; fi; printf '%s\n' "$rekey_run"; } | rta_write "$(rta_state).rekey-runs"
    rta_write "$(rta_state).rekey-$rekey_run.jsonl" < "$work/rta-rekey.jsonl"
    say "   relaycast-rekey run $rekey_run recorded in $(rta_state).rekey-runs (for --undo / --purge)"
  fi
  say ""
  say "Credentials phase done. Add this to your values so later upgrades keep it:"
  sed 's/^/   /' "$work/rta-credentials.yaml"
  say "Keep relay-control's encryption key until relaycast-rekey --purge. Then run --relaycast-actors cutover (plan first)."
}

rta_cutover() {
  local control_replicas=0
  if [ -n "$rta_control" ]; then control_replicas=$("${kube[@]}" get "$rta_control" -o jsonpath='{.spec.replicas}'); fi
  rta_check_mirrored
  if ! $rta_resume; then
    say "== R1. Preflight (read-only)"
    rta_preflight
    say "== R2. Quiesce: relay-control and Relaycast to 0 replicas (messaging is down from here)"
    # shellcheck disable=SC2086
    rta_scale_down $rta_control $rta_relaycast
    say "== R3. Export from one snapshot (sealed, owner-only)"
    printf '%s\n' "$rta_run" | rta_write "$(rta_state).run"
    printf '%s\n' "${control_replicas:-1}" | rta_write "$(rta_state).control-replicas"
    rta_run_step export
    say "== R4. helm upgrade $release: Relaycast onto durable-actors (same chart $chart_version)"
    "${helmx[@]}" upgrade "$release" "$chart" "${base[@]}" "${rta_actor_files[@]}" --wait --wait-for-jobs --timeout 20m
    rta_relaycast=$(rta_deploy relaycast)
  fi
  control_replicas=$(cat "$(rta_state).control-replicas" 2>/dev/null || echo 1)
  # relay-control stays down until go-live; the gateway answers 503 for every
  # imported workspace until it is opened, so nothing can write meanwhile.
  # shellcheck disable=SC2086
  if [ -n "$rta_control" ]; then rta_scale_down $rta_control; fi
  if ! $rta_golive; then
    say "== R5. Copy files, then import every workspace (each verified by count and digest, closed until open)"
    rta_run_step files
    rta_run_step import
    "${kube[@]}" rollout status "$rta_relaycast" --timeout 10m
    say "== R6. Verify realtime through the gateway"
    rta_run_step verify
  fi
  # Go-live is recorded before the first workspace opens: from here the run
  # only goes forward (an opened workspace takes writes Postgres never sees), and
  # a rerun finishes opening the rest. Every workspace is verified (the import
  # step failed the run otherwise), so open only flips each to serving.
  rta_mark "$(rta_state).golive"
  say "== R7. Go live: go-live recorded for run $rta_run; opening every workspace"
  rta_run_step open
  rta_mark "$(rta_state).opened"
  if [ -n "$rta_control" ]; then
    "${kube[@]}" scale "$rta_control" --replicas="$control_replicas" >/dev/null
    "${kube[@]}" rollout status "$rta_control" --timeout 10m
  fi
  say "   every workspace imported, verified and open; realtime works; Relaycast serves from durable-actors"
  say ""
  say "Next (docs/relaycast-postgres-to-actors-migration.md, clean-up): put --actors-values and"
  sed 's/^/   /' "$work/rta-pinned.yaml"
  say "into your values; after go-live is confirmed, relaycast-rekey --purge <run> --confirm in relay-control,"
  say "then retire the export (/data/migration/$rta_run), persistence.retainForMigration and the PostgreSQL database."
}

rta_rollback_hint() {
  say "   Relaycast migration ($rta_phase, run ${rta_run:-none}): PostgreSQL is not written after the export, so it holds the pre-move state."
  say "   - before the helm upgrade: scale relay-control and Relaycast back up"
  if [ -e "$(rta_state).golive" ]; then
    say "   - GO-LIVE IS RECORDED for run ${rta_run}: do NOT roll back (opened workspaces may have taken writes)."
    say "     Rerun --relaycast-actors cutover: it resumes and opens the remaining workspaces."
    return
  fi
  say "   - after it, before go-live: helm rollback as above; nothing was served from the actors (503 until open)."
  say "     To retry instead, rerun --relaycast-actors cutover: it resumes this run's files, import, verify and open."
  say "     To empty a workspace's actor: relaycast-migrate abort --dir /data/migration/${rta_run:-<run>} --gateway <url> --workspace <id> (import Job image)"
  say "   - relay-control re-key: relaycast-rekey --undo <run id> in the relay-control pod"
}
